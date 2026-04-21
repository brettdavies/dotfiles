#!/usr/bin/env bats
# Tests for the opendataloader-pdf stow package and enable script.
#
# Static assertions only — cold-start + idle-exit + re-activation live in
# the manual smoke checklist below (run on the dev host before closing
# the work). Dev host coverage of shared-package wiring lives in
# tests/stow-deploy-packages.bats.
#
# Run: bats tests/opendataloader-pdf.bats
#
# ---------------------------------------------------------------------------
# Manual smoke checklist (run on the dev host, one-time, after shipping):
#
#   [ ] Cold start      bash scripts/opendataloader-pdf-enable.sh
#                       curl /health < 15 s on first connect post-enable.
#   [ ] Conversion      curl -X POST -F "files=@test.pdf" /v1/convert/file
#                       returns 200 with JSON body.
#   [ ] Idle-exit       no requests for 60 s + 10 s; ss shows systemd
#                       (not python) as listener owner.
#   [ ] Re-activation   next curl /health triggers cold start + succeeds.
#   [ ] VRAM reclaim    nvidia-smi shows 0 MiB for launcher PID between
#                       idle-exits.
#   [ ] Concurrent      two parallel curl POSTs both complete (upstream
#                       threading.Lock serializes docling.convert).
#   [ ] Teardown        systemctl --user disable --now opendataloader-pdf.socket
#                       cleanly stops everything, no orphans.
#   [ ] mc-pdf e2e      run mc-pdf on a known OCR-required PDF; output
#                       matches pre-migration behavior.
# ---------------------------------------------------------------------------

REPO_ROOT="$BATS_TEST_DIRNAME/.."
PKG_DIR="$REPO_ROOT/stow/opendataloader-pdf"
SOCKET_UNIT="$PKG_DIR/dot-config/systemd/user/opendataloader-pdf.socket"
SERVICE_UNIT="$PKG_DIR/dot-config/systemd/user/opendataloader-pdf.service"
LAUNCHER_SH="$PKG_DIR/dot-local/bin/opendataloader-pdf-hybrid-sa"
LAUNCHER_PY="$PKG_DIR/dot-local/bin/opendataloader-pdf-hybrid-sa.py"
ENABLE_SCRIPT="$REPO_ROOT/scripts/opendataloader-pdf-enable.sh"

# ---------------------------------------------------------------------------
# Package layout
# ---------------------------------------------------------------------------

@test "socket unit file exists" {
  [ -f "$SOCKET_UNIT" ]
}

@test "service unit file exists" {
  [ -f "$SERVICE_UNIT" ]
}

@test "launcher sh wrapper exists and is executable" {
  [ -f "$LAUNCHER_SH" ]
  [ -x "$LAUNCHER_SH" ]
}

@test "launcher python module exists and is executable" {
  [ -f "$LAUNCHER_PY" ]
  [ -x "$LAUNCHER_PY" ]
}

@test "enable script exists and is executable" {
  [ -f "$ENABLE_SCRIPT" ]
  [ -x "$ENABLE_SCRIPT" ]
}

# ---------------------------------------------------------------------------
# Socket unit contents
# ---------------------------------------------------------------------------

@test "socket unit listens on 127.0.0.1:5002" {
  grep -q '^ListenStream=127.0.0.1:5002$' "$SOCKET_UNIT"
}

@test "socket unit uses Accept=no (single-listener model)" {
  grep -q '^Accept=no$' "$SOCKET_UNIT"
}

@test "socket unit has [Install] WantedBy=sockets.target" {
  grep -q '^WantedBy=sockets.target$' "$SOCKET_UNIT"
}

# ---------------------------------------------------------------------------
# Service unit contents
# ---------------------------------------------------------------------------

@test "service ExecStart invokes launcher with --force-ocr and --idle-timeout" {
  grep -q '^ExecStart=%h/.local/bin/opendataloader-pdf-hybrid-sa ' "$SERVICE_UNIT"
  grep -q 'ExecStart=.* --force-ocr ' "$SERVICE_UNIT"
  grep -q 'ExecStart=.* --idle-timeout [0-9]' "$SERVICE_UNIT"
}

@test "service requires + orders after socket" {
  grep -q '^Requires=opendataloader-pdf.socket$' "$SERVICE_UNIT"
  grep -q '^After=opendataloader-pdf.socket$' "$SERVICE_UNIT"
}

@test "service hardening: NoNewPrivileges + PrivateTmp" {
  grep -q '^NoNewPrivileges=true$' "$SERVICE_UNIT"
  grep -q '^PrivateTmp=true$' "$SERVICE_UNIT"
}

# ---------------------------------------------------------------------------
# Launcher shape
# ---------------------------------------------------------------------------

@test "launcher sh wrapper uses HOME (no hardcoded user path)" {
  grep -q '"\$HOME/.local/share/uv/tools/opendataloader-pdf/bin/python"' "$LAUNCHER_SH"
  ! grep -q '/home/[a-z]*/' "$LAUNCHER_SH"
}

@test "launcher python module defines IdleWatchdog and honors LISTEN_FDS" {
  grep -q '^class IdleWatchdog' "$LAUNCHER_PY"
  grep -q 'LISTEN_FDS' "$LAUNCHER_PY"
  grep -q 'LISTEN_PID' "$LAUNCHER_PY"
}

@test "launcher python module exposes --idle-timeout flag" {
  grep -q -- "--idle-timeout" "$LAUNCHER_PY"
  grep -q 'default=60' "$LAUNCHER_PY"
}

# ---------------------------------------------------------------------------
# Enable script shape
# ---------------------------------------------------------------------------

@test "enable script references the socket unit" {
  grep -q 'opendataloader-pdf.socket' "$ENABLE_SCRIPT"
}

@test "enable script has a /health smoke curl" {
  # curl invocation and the /health URL may be on separate continuation lines
  grep -qE '\bcurl\b' "$ENABLE_SCRIPT"
  grep -q '/health' "$ENABLE_SCRIPT"
}

@test "enable script has a Linux-only gate" {
  grep -q 'uname -s' "$ENABLE_SCRIPT"
  grep -q 'Linux-only' "$ENABLE_SCRIPT"
}

# ---------------------------------------------------------------------------
# Best-effort: launcher --help lists --idle-timeout (only if uv-tool installed)
# ---------------------------------------------------------------------------

@test "launcher --help advertises --idle-timeout flag (requires uv-tool)" {
  TOOL_PY="$HOME/.local/share/uv/tools/opendataloader-pdf/bin/python"
  if [ ! -x "$TOOL_PY" ]; then
    skip "uv-tool opendataloader-pdf not installed on this host"
  fi
  output=$("$TOOL_PY" "$LAUNCHER_PY" --help 2>&1)
  [[ "$output" == *"--idle-timeout"* ]]
}
