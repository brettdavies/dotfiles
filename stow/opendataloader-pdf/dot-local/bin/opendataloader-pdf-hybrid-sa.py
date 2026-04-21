"""Socket-activation-aware launcher for opendataloader-pdf-hybrid.

Two behaviors beyond upstream's hybrid_server.main():

1. LISTEN_FDS dispatch — when systemd passes a listening socket via
   LISTEN_FDS/LISTEN_PID env vars, the launcher hands FD 3 to
   uvicorn.Config(fd=...) instead of binding host/port itself.
2. Idle-exit watchdog — an asyncio task polls every 5 seconds and trips
   uvicorn's should_exit flag once the process has been idle for
   --idle-timeout seconds with no in-flight requests. systemd's socket
   unit retains its own copy of the listener, so the next connect
   re-activates the service.

Invoked by the sh wrapper (opendataloader-pdf-hybrid-sa) via the uv-tool
venv Python. The wrapper owns interpreter path resolution; this module
stays free of hardcoded system paths.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager

from opendataloader_pdf.hybrid_server import (
    DEFAULT_HOST,
    DEFAULT_PORT,
    _check_dependencies,
    _get_loop_setting,
    create_app,
)

logger = logging.getLogger("odl-hybrid-sa")

WATCHDOG_POLL_SECONDS = 5.0
SD_LISTEN_FDS_START = 3


class IdleWatchdog:
    """Counts in-flight requests, records last activity, trips server.should_exit on idle."""

    def __init__(self, idle_timeout: float) -> None:
        self.idle_timeout = idle_timeout
        self._in_flight = 0
        self._last_activity = time.monotonic()
        self._lock = asyncio.Lock()

    async def enter(self) -> None:
        async with self._lock:
            self._in_flight += 1

    async def exit(self) -> None:
        async with self._lock:
            self._in_flight = max(0, self._in_flight - 1)
            self._last_activity = time.monotonic()

    async def run(self, server) -> None:
        """Background poll loop. Exits when the watchdog trips or the task is cancelled."""
        if self.idle_timeout <= 0:
            logger.info("idle-exit disabled (--idle-timeout=%.0f)", self.idle_timeout)
            return
        logger.info(
            "idle-exit armed: timeout=%.0fs poll=%.1fs",
            self.idle_timeout,
            WATCHDOG_POLL_SECONDS,
        )
        try:
            while not server.should_exit:
                await asyncio.sleep(WATCHDOG_POLL_SECONDS)
                async with self._lock:
                    if self._in_flight > 0:
                        continue
                    idle_for = time.monotonic() - self._last_activity
                    if idle_for >= self.idle_timeout:
                        logger.info(
                            "idle for %.1fs with no in-flight requests; shutting down",
                            idle_for,
                        )
                        server.should_exit = True
                        return
        except asyncio.CancelledError:
            return


def _wire_watchdog(app, watchdog: IdleWatchdog, server) -> None:
    """Wrap the app's lifespan to spawn the watchdog task; install tracking middleware."""
    original_lifespan = app.router.lifespan_context

    @asynccontextmanager
    async def wrapped(app_):
        async with original_lifespan(app_):
            task = asyncio.create_task(watchdog.run(server))
            try:
                yield
            finally:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

    app.router.lifespan_context = wrapped

    @app.middleware("http")
    async def track_activity(request, call_next):
        await watchdog.enter()
        try:
            return await call_next(request)
        finally:
            await watchdog.exit()


def _resolve_socket_fd() -> int | None:
    """Return SD_LISTEN_FDS_START (3) when systemd passed us a listening socket."""
    listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    listen_pid = int(os.environ.get("LISTEN_PID", "0"))
    if listen_fds > 0 and listen_pid == os.getpid():
        return SD_LISTEN_FDS_START
    return None


def main() -> int:
    _check_dependencies()
    import uvicorn

    parser = argparse.ArgumentParser(
        description="Socket-activation-aware launcher for opendataloader-pdf-hybrid",
    )
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help=f"Bind host when standalone (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"Bind port when standalone (default: {DEFAULT_PORT})")
    parser.add_argument("--force-ocr", action="store_true",
                        help="Force full-page OCR on all pages")
    parser.add_argument("--log-level", default="info",
                        choices=["debug", "info", "warning", "error"])
    parser.add_argument("--idle-timeout", type=float, default=60.0,
                        help="Seconds of idleness before self-shutdown (0 disables, default: 60)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )

    app = create_app(force_ocr=args.force_ocr)
    watchdog = IdleWatchdog(args.idle_timeout)

    fd = _resolve_socket_fd()
    if fd is not None:
        logger.info("socket-activated: using passed FD %d", fd)
        config = uvicorn.Config(
            app, fd=fd, log_level=args.log_level, loop=_get_loop_setting(),
        )
    else:
        logger.info("standalone: binding %s:%d", args.host, args.port)
        config = uvicorn.Config(
            app, host=args.host, port=args.port,
            log_level=args.log_level, loop=_get_loop_setting(),
        )

    server = uvicorn.Server(config)
    _wire_watchdog(app, watchdog, server)
    server.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
