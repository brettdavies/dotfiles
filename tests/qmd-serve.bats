#!/usr/bin/env bats
# Tests for the qmd stow package (qmd-serve, qmd-embed, qmd-update) and the
# qmd-serve enable script.
#
# Static assertions only — live daemon behavior (sequential VRAM cycling,
# reboot persistence, CLI routing) lives in the manual smoke checklist below
# (run on the dev host after shipping). Dev host coverage of shared-package
# wiring lives in tests/stow-deploy-packages.bats.
#
# Run: bats tests/qmd-serve.bats
#
# ---------------------------------------------------------------------------
# Manual smoke checklist (run on the dev host, one-time, after shipping):
#
#   [ ] Cold start      bash scripts/qmd-serve-enable.sh
#                       curl /health < 10 s, returns JSON with "ok":true.
#   [ ] Sequential VRAM submit embed + rerank + generate queries back-to-back;
#                       nvidia-smi shows one model resident at a time, peak
#                       ~2.6 GB (not ~5.4 GB).
#   [ ] Reboot persist  sudo reboot; after login,
#                         systemctl --user is-active qmd-serve.service
#                       returns "active" and /health responds.
#   [ ] qmd-embed OK    systemctl --user start qmd-embed.service completes
#                       without OOM; nvidia-smi shows no VRAM exhaustion
#                       after Ollama-unload ExecStartPre fires.
#   [ ] CLI routing     qmd query "test" with QMD_SERVER set routes through
#                       the daemon; unsetting QMD_SERVER falls back to local
#                       mode (slower, loads model in-process).
#   [ ] CLI resolution  command -v qmd resolves to ~/.local/bin/qmd (stow
#                       wrapper wins on current PATH order). qmd-serve keeps
#                       using /home/brett/.bun/bin/qmd via its absolute
#                       ExecStart — both point at the same fork binary.
#   [ ] Teardown        systemctl --user disable --now qmd-serve.service
#                       cleanly stops everything, no orphans on :7832.
# ---------------------------------------------------------------------------

REPO_ROOT="$BATS_TEST_DIRNAME/.."
PKG_DIR="$REPO_ROOT/stow/qmd"
SERVE_UNIT="$PKG_DIR/dot-config/systemd/user/qmd-serve.service"
EMBED_UNIT="$PKG_DIR/dot-config/systemd/user/qmd-embed.service"
UPDATE_UNIT="$PKG_DIR/dot-config/systemd/user/qmd-update.service"
EMBED_TIMER="$PKG_DIR/dot-config/systemd/user/qmd-embed.timer"
UPDATE_TIMER="$PKG_DIR/dot-config/systemd/user/qmd-update.timer"
WRAPPER_SH="$PKG_DIR/dot-local/bin/qmd"
ENABLE_SCRIPT="$REPO_ROOT/scripts/qmd-serve-enable.sh"
SHELL_ENV="$REPO_ROOT/config/shell/qmd.sh"

# ---------------------------------------------------------------------------
# Package layout
# ---------------------------------------------------------------------------

@test "qmd-serve.service file exists" {
  [ -f "$SERVE_UNIT" ]
}

@test "qmd-embed.service file exists" {
  [ -f "$EMBED_UNIT" ]
}

@test "qmd-update.service file exists" {
  [ -f "$UPDATE_UNIT" ]
}

@test "qmd-embed.timer file exists" {
  [ -f "$EMBED_TIMER" ]
}

@test "qmd-update.timer file exists" {
  [ -f "$UPDATE_TIMER" ]
}

@test "qmd wrapper sh exists and is executable" {
  [ -f "$WRAPPER_SH" ]
  [ -x "$WRAPPER_SH" ]
}

@test "qmd-serve-enable.sh exists and is executable" {
  [ -f "$ENABLE_SCRIPT" ]
  [ -x "$ENABLE_SCRIPT" ]
}

@test "config/shell/qmd.sh exists" {
  [ -f "$SHELL_ENV" ]
}

# ---------------------------------------------------------------------------
# Wrapper shape
# ---------------------------------------------------------------------------

@test "qmd wrapper uses HOME (no hardcoded user path)" {
  grep -q '"\$HOME/dev/qmd/qmd"' "$WRAPPER_SH"
  ! grep -q '/home/[a-z]*/' "$WRAPPER_SH"
}

@test "qmd wrapper shebang is #!/bin/sh" {
  head -n1 "$WRAPPER_SH" | grep -q '^#!/bin/sh$'
}

# ---------------------------------------------------------------------------
# qmd-serve.service contents
#
# ExecStart uses the absolute /home/brett/.bun/bin/qmd path on purpose — the
# service is pinned to a specific file so it stays invariant to PATH-ordering
# changes tracked in todo 015 (dedupe local-paths.sh prepends). Interactive
# qmd still resolves via the stow wrapper at ~/.local/bin/qmd.
# ---------------------------------------------------------------------------

@test "qmd-serve ExecStart invokes qmd serve with sequential mode" {
  grep -qE '^ExecStart=\S*/qmd serve ' "$SERVE_UNIT"
  grep -q 'ExecStart=.* --port 7832 ' "$SERVE_UNIT"
  grep -q 'ExecStart=.* --bind 127.0.0.1 ' "$SERVE_UNIT"
  grep -q 'ExecStart=.* --sequential' "$SERVE_UNIT"
}

@test "qmd-serve has Type=simple" {
  grep -q '^Type=simple$' "$SERVE_UNIT"
}

@test "qmd-serve restart policy: on-failure with numeric RestartSec" {
  grep -q '^Restart=on-failure$' "$SERVE_UNIT"
  grep -qE '^RestartSec=[0-9]+' "$SERVE_UNIT"
}

@test "qmd-serve hardening: NoNewPrivileges + PrivateTmp" {
  grep -q '^NoNewPrivileges=true$' "$SERVE_UNIT"
  grep -q '^PrivateTmp=true$' "$SERVE_UNIT"
}

@test "qmd-serve install: WantedBy=default.target (autostart on login)" {
  grep -q '^WantedBy=default.target$' "$SERVE_UNIT"
}

# ---------------------------------------------------------------------------
# qmd-embed.service contents
# ---------------------------------------------------------------------------

@test "qmd-embed ExecStart uses %h/.local/bin/qmd embed" {
  grep -q '^ExecStart=%h/.local/bin/qmd embed$' "$EMBED_UNIT"
}

@test "qmd-embed ExecStart line has no hardcoded /home/<user>/ path" {
  # Environment=PATH=... intentionally contains /home/... entries for the
  # Ollama-unload ExecStartPre's bare `curl`; the invariant we guard is that
  # the ExecStart lines themselves resolve via %h, not a hardcoded user path.
  ! grep -E '^ExecStart(Pre|Post)?=' "$EMBED_UNIT" | grep -q '/home/[a-z]*/'
}

@test "qmd-embed retains Ollama-unload ExecStartPre (intentional; Ollama is a separate process)" {
  grep -q '^ExecStartPre=' "$EMBED_UNIT"
  grep -q '11434' "$EMBED_UNIT"
  grep -q 'qwen3-coder:30b' "$EMBED_UNIT"
}

@test "qmd-embed hardening: NoNewPrivileges + PrivateTmp" {
  grep -q '^NoNewPrivileges=true$' "$EMBED_UNIT"
  grep -q '^PrivateTmp=true$' "$EMBED_UNIT"
}

# ---------------------------------------------------------------------------
# qmd-update.service contents
# ---------------------------------------------------------------------------

@test "qmd-update ExecStart uses %h/.local/bin/qmd for both cleanup and update" {
  grep -q 'ExecStart=/bin/sh -c .*%h/.local/bin/qmd cleanup' "$UPDATE_UNIT"
  grep -q 'ExecStart=/bin/sh -c .*%h/.local/bin/qmd update' "$UPDATE_UNIT"
}

@test "qmd-update has no hardcoded /home/<user>/ path" {
  ! grep -q '/home/[a-z]*/' "$UPDATE_UNIT"
}

@test "qmd-update has no Environment=PATH=... (absolute paths suffice)" {
  ! grep -q '^Environment=PATH=' "$UPDATE_UNIT"
}

@test "qmd-update hardening: NoNewPrivileges + PrivateTmp" {
  grep -q '^NoNewPrivileges=true$' "$UPDATE_UNIT"
  grep -q '^PrivateTmp=true$' "$UPDATE_UNIT"
}

# ---------------------------------------------------------------------------
# config/shell/qmd.sh
# ---------------------------------------------------------------------------

@test "config/shell/qmd.sh exports QMD_SERVER on port 7832 (matches service)" {
  grep -q '^export QMD_SERVER=http://127.0.0.1:7832$' "$SHELL_ENV"
}

# ---------------------------------------------------------------------------
# Enable script shape
# ---------------------------------------------------------------------------

@test "enable script references qmd-serve.service" {
  grep -q 'qmd-serve.service' "$ENABLE_SCRIPT"
}

@test "enable script has a /health smoke curl with --max-time" {
  grep -qE '\bcurl\b' "$ENABLE_SCRIPT"
  grep -q '/health' "$ENABLE_SCRIPT"
  grep -q -- '--max-time' "$ENABLE_SCRIPT"
}

@test "enable script has a Linux-only gate" {
  grep -q 'uname -s' "$ENABLE_SCRIPT"
  grep -q 'Linux-only' "$ENABLE_SCRIPT"
}

@test "enable script documents why ~/.bun/bin/qmd is NOT removed" {
  # The shadow-removal step is intentionally omitted — the qmd-serve.service
  # unit ExecStart's directly from /home/brett/.bun/bin/qmd, so deleting the
  # symlink would break the daemon. todo 015 owns the follow-up PATH cleanup.
  grep -q 'NOT removed' "$ENABLE_SCRIPT"
  grep -q 'todo 015' "$ENABLE_SCRIPT"
}

@test "enable script uses the configured port (7832)" {
  grep -q 'PORT=7832' "$ENABLE_SCRIPT"
}

@test "enable script passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$ENABLE_SCRIPT"
  [ "$status" -eq 0 ]
}
