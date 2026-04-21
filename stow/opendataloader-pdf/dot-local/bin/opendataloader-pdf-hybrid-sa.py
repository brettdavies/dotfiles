"""Placeholder launcher — Unit 1 of the socket-activation rollout.

Unit 2 replaces this with LISTEN_FDS dispatch + asyncio idle-exit watchdog.
For now, this simply delegates to upstream's main() so the stow deploy path
is testable end-to-end before the real launcher logic lands.
"""

from opendataloader_pdf.hybrid_server import main


if __name__ == "__main__":
    main()
