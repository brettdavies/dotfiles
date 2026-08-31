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
# `run !` below asserts a command fails. Bats keeps pre-1.5 `run` semantics
# until a suite opts in, so the declaration is what enables the flag form
# rather than a newer bats: 1.14 still warns BW02 without it.
bats_require_minimum_version 1.5.0
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
#   [ ] CLI routing     qmd query "test" with QMD_REMOTE_URL set routes through
#                       the daemon; unsetting QMD_REMOTE_URL falls back to local
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
# Linux-only artifacts (systemd units + ollama helper) live in stow/local/
# alongside nightly-autocommit, not in stow/qmd. The stow/qmd package now
# holds only the OS-aware wrapper. See docs/solutions/architecture-patterns/
# cross-platform-stow-package-gating-2026-05-17.md.
LOCAL_PKG_DIR="$REPO_ROOT/stow/local"
SERVE_UNIT="$LOCAL_PKG_DIR/dot-config/systemd/user/qmd-serve.service"
EMBED_UNIT="$LOCAL_PKG_DIR/dot-config/systemd/user/qmd-embed.service"
UPDATE_UNIT="$LOCAL_PKG_DIR/dot-config/systemd/user/qmd-update.service"
CLEANUP_UNIT="$LOCAL_PKG_DIR/dot-config/systemd/user/qmd-cleanup.service"
EMBED_TIMER="$LOCAL_PKG_DIR/dot-config/systemd/user/qmd-embed.timer"
UPDATE_TIMER="$LOCAL_PKG_DIR/dot-config/systemd/user/qmd-update.timer"
CLEANUP_TIMER="$LOCAL_PKG_DIR/dot-config/systemd/user/qmd-cleanup.timer"
WRAPPER_SH="$PKG_DIR/dot-local/bin/qmd"
OLLAMA_UNLOAD_SH="$LOCAL_PKG_DIR/dot-local/bin/qmd-ollama-unload-all"
GPU_VERIFY_SH="$LOCAL_PKG_DIR/dot-local/bin/qmd-gpu-verify"
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

@test "qmd-cleanup.service file exists" {
  [ -f "$CLEANUP_UNIT" ]
}

@test "qmd-cleanup.timer file exists" {
  [ -f "$CLEANUP_TIMER" ]
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
  run ! grep -q '/home/[a-z]*/' "$WRAPPER_SH"
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

@test "qmd-serve ExecStart invokes qmd serve with low-vram mode" {
  grep -qE '^ExecStart=\S*/qmd serve ' "$SERVE_UNIT"
  grep -q 'ExecStart=.* --port 7832 ' "$SERVE_UNIT"
  grep -q 'ExecStart=.* --bind 127.0.0.1 ' "$SERVE_UNIT"
  grep -q 'ExecStart=.* --low-vram' "$SERVE_UNIT"
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
  grep -qE '^ExecStart=%h/\.local/bin/qmd embed( |$)' "$EMBED_UNIT"
}

@test "qmd-embed pins the CUDA GPU backend" {
  # Without NODE_LLAMA_CPP_GPU=cuda, node-llama-cpp prefers the Vulkan prebuilt
  # (which breaks across NVIDIA driver branches) and falls back to CPU, so
  # embedding runs on CPU despite the ExecStartPre freeing GPU VRAM for it.
  grep -q '^Environment=NODE_LLAMA_CPP_GPU=cuda$' "$EMBED_UNIT"
}

@test "qmd-embed caps per-batch work for VRAM safety" {
  # The box shares one GPU with Ollama (qmd-serve runs --low-vram); uncapped GPU
  # batches can exhaust VRAM and trigger a ggml/CUDA abort.
  grep -qE '^ExecStart=.*--max-docs-per-batch [0-9]+' "$EMBED_UNIT"
  grep -qE '^ExecStart=.*--max-batch-mb [0-9]+' "$EMBED_UNIT"
}

@test "qmd-embed ExecStart line has no hardcoded /home/<user>/ path" {
  # Environment=PATH=... intentionally contains /home/... entries for the
  # Ollama-unload ExecStartPre's bare `curl`; the invariant we guard is that
  # the ExecStart lines themselves resolve via %h, not a hardcoded user path.
  run bash -c "grep -E '^ExecStart(Pre|Post)?=' '$EMBED_UNIT' | grep -q '/home/[a-z]*/'"
  [ "$status" -ne 0 ]
}

@test "qmd-embed ExecStartPre delegates to qmd-ollama-unload-all helper" {
  # The unload step must call the dynamic-discovery helper script. Hardcoding
  # a model name in the unit (the prior bug) either no-oped or, worse, loaded
  # the wrong model just to unload it once the env-pinned model changed.
  grep -q '^ExecStartPre=%h/.local/bin/qmd-ollama-unload-all$' "$EMBED_UNIT"
  run ! grep -qE '^ExecStartPre=.*(curl|api/generate|--data|-d ).*model' "$EMBED_UNIT"
}

@test "qmd-ollama-unload-all helper exists and is executable" {
  [ -f "$OLLAMA_UNLOAD_SH" ]
  [ -x "$OLLAMA_UNLOAD_SH" ]
}

@test "qmd-ollama-unload-all uses dynamic discovery (ollama ps + ollama stop)" {
  grep -q 'ollama ps' "$OLLAMA_UNLOAD_SH"
  grep -q 'ollama stop' "$OLLAMA_UNLOAD_SH"
}

@test "qmd-ollama-unload-all gates unload on free VRAM (MIN_FREE_MIB threshold)" {
  # The unload must be conditional, not unconditional. Stomping a pinned
  # Ollama model on every embed cycle when there's plenty of headroom is
  # wasteful. The threshold is configurable via env var for tuning.
  grep -q 'MIN_FREE_MIB' "$OLLAMA_UNLOAD_SH"
  grep -q 'nvidia-smi' "$OLLAMA_UNLOAD_SH"
  grep -q 'memory.free' "$OLLAMA_UNLOAD_SH"
}

@test "qmd-ollama-unload-all default threshold leaves headroom for embed model" {
  # Embedding model peaks around ~700 MB VRAM with batch KV cache; default
  # threshold should be at least 2x that to absorb noise without false
  # triggers, but not so high that it stomps Ollama on a normally-loaded
  # 24 GB GPU.
  default_mib=$(grep -oE 'MIN_FREE_MIB:=[0-9]+' "$OLLAMA_UNLOAD_SH" | cut -d= -f2)
  [ -n "$default_mib" ]
  [ "$default_mib" -ge 1500 ]
  [ "$default_mib" -le 4096 ]
}

@test "qmd-ollama-unload-all skips unload when nvidia-smi is absent or fails" {
  # No-GPU host (CPU-only) and nvidia-smi-error paths must both bail without
  # touching Ollama — otherwise CPU embed gets a needless side effect.
  grep -q 'command -v nvidia-smi' "$OLLAMA_UNLOAD_SH"
}

@test "qmd-ollama-unload-all has no hardcoded model names" {
  # Whitelist: no concrete model name (regex covers vendor:tag patterns and
  # bare GGUF model strings). Comments may describe behavior abstractly but
  # must not pin a specific model.
  run ! grep -qE '"[a-z0-9._-]+:[0-9a-z._-]+"' "$OLLAMA_UNLOAD_SH"
  run ! grep -qE "'[a-z0-9._-]+:[0-9a-z._-]+'" "$OLLAMA_UNLOAD_SH"
}

@test "qmd-ollama-unload-all always exits 0 (callers proceed even on failure)" {
  grep -q '^exit 0$' "$OLLAMA_UNLOAD_SH"
}

@test "qmd-ollama-unload-all passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$OLLAMA_UNLOAD_SH"
  [ "$status" -eq 0 ]
}

@test "qmd-embed hardening: NoNewPrivileges + PrivateTmp" {
  grep -q '^NoNewPrivileges=true$' "$EMBED_UNIT"
  grep -q '^PrivateTmp=true$' "$EMBED_UNIT"
}

# ---------------------------------------------------------------------------
# qmd-gpu-verify contents
# ---------------------------------------------------------------------------

@test "qmd-gpu-verify exists and is executable" {
  [ -f "$GPU_VERIFY_SH" ]
  [ -x "$GPU_VERIFY_SH" ]
}

@test "qmd-gpu-verify checks the live process env, not just the unit file" {
  # The CUDA pin can be present in qmd-serve.service yet absent from the
  # running daemon (edited unit without daemon-reload + restart). Reading
  # /proc/<pid>/environ is what makes the check end to end.
  grep -q '/proc/\$pid/environ' "$GPU_VERIFY_SH"
  grep -q 'NODE_LLAMA_CPP_GPU=cuda' "$GPU_VERIFY_SH"
}

@test "qmd-gpu-verify uses VRAM residency as the GPU signal" {
  # A CPU-fallback process holds zero VRAM; GPU utilization % sits near zero
  # even on a healthy low-vram daemon, so compute-apps residency is the
  # signal, not dmon/utilization.
  grep -q 'query-compute-apps' "$GPU_VERIFY_SH"
}

@test "qmd-gpu-verify degrades gracefully on macOS" {
  # No NVIDIA GPU and no systemd on Darwin: check the launchd agent and
  # point at powermetrics (Metal GPU work is invisible to %CPU).
  grep -q 'launchctl print' "$GPU_VERIFY_SH"
  grep -q 'powermetrics' "$GPU_VERIFY_SH"
}

@test "qmd-gpu-verify exits nonzero with named failures" {
  grep -q 'failures+=' "$GPU_VERIFY_SH"
  grep -q 'exit 1' "$GPU_VERIFY_SH"
}

@test "qmd-gpu-verify passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$GPU_VERIFY_SH"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# qmd-update.service contents
# ---------------------------------------------------------------------------

@test "qmd-update ExecStart uses %h/.local/bin/qmd for both cleanup and update" {
  grep -q 'ExecStart=/bin/sh -c .*%h/.local/bin/qmd cleanup' "$UPDATE_UNIT"
  grep -q 'ExecStart=/bin/sh -c .*%h/.local/bin/qmd update' "$UPDATE_UNIT"
}

@test "qmd-update has no hardcoded /home/<user>/ path" {
  # /home/linuxbrew/ is Homebrew's standard install prefix on Linux —
  # not a user homedir, and legitimate to reference in unit files.
  # Reject any other /home/<name>/ pattern (e.g. /home/brett/).
  hardcoded=$(grep -oE '/home/[a-z]+/' "$UPDATE_UNIT" 2>/dev/null \
    | grep -vxE '/home/linuxbrew/' || true)
  [ -z "$hardcoded" ]
}

@test "qmd-update sets Environment=PATH for brew tool resolution" {
  # PR #74 added Environment=PATH=... to user units after a deployed-server
  # audit found that systemd's minimal inherited PATH couldn't resolve brew
  # tools (rg, etc.). Same class of bug as cron PATH issues. The PATH must
  # include /home/linuxbrew/.linuxbrew/bin first.
  grep -q '^Environment=PATH=/home/linuxbrew/\.linuxbrew/bin:' "$UPDATE_UNIT"
}

@test "qmd-update hardening: NoNewPrivileges + PrivateTmp" {
  grep -q '^NoNewPrivileges=true$' "$UPDATE_UNIT"
  grep -q '^PrivateTmp=true$' "$UPDATE_UNIT"
}

# ---------------------------------------------------------------------------
# qmd-cleanup.service contents
# ---------------------------------------------------------------------------

@test "qmd-cleanup ExecStart invokes %h/.local/bin/qmd cleanup" {
  grep -q 'ExecStart=/bin/sh -c .*%h/.local/bin/qmd cleanup' "$CLEANUP_UNIT"
}

@test "qmd-cleanup has no hardcoded /home/<user>/ path" {
  # /home/linuxbrew/ is Homebrew's standard install prefix on Linux —
  # not a user homedir, and legitimate to reference in unit files
  # (Environment=PATH added in PR #74 for brew tool resolution).
  # Reject any other /home/<name>/ pattern (e.g. /home/brett/).
  hardcoded=$(grep -oE '/home/[a-z]+/' "$CLEANUP_UNIT" 2>/dev/null \
    | grep -vxE '/home/linuxbrew/' || true)
  [ -z "$hardcoded" ]
}

@test "qmd-cleanup has Type=oneshot" {
  grep -q '^Type=oneshot$' "$CLEANUP_UNIT"
}

@test "qmd-cleanup hardening: NoNewPrivileges + PrivateTmp" {
  grep -q '^NoNewPrivileges=true$' "$CLEANUP_UNIT"
  grep -q '^PrivateTmp=true$' "$CLEANUP_UNIT"
}

# ---------------------------------------------------------------------------
# qmd-cleanup.timer contents — nightly base + randomized fuzz so the cleanup
# fires inside a low-activity window without correlating with anything else
# scheduled on the same wall clock.
# ---------------------------------------------------------------------------

@test "qmd-cleanup.timer fires nightly via OnCalendar" {
  grep -qE '^OnCalendar=\*-\*-\* [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$CLEANUP_TIMER"
}

@test "qmd-cleanup.timer randomizes fire time (RandomizedDelaySec set)" {
  grep -qE '^RandomizedDelaySec=' "$CLEANUP_TIMER"
}

@test "qmd-cleanup.timer is persistent (catches up after downtime)" {
  grep -q '^Persistent=true$' "$CLEANUP_TIMER"
}

@test "qmd-cleanup.timer install: WantedBy=timers.target" {
  grep -q '^WantedBy=timers.target$' "$CLEANUP_TIMER"
}

# ---------------------------------------------------------------------------
# config/shell/qmd.sh
# ---------------------------------------------------------------------------

@test "config/shell/qmd.sh exports QMD_REMOTE_URL on port 7832 (matches service)" {
  grep -q '^export QMD_REMOTE_URL=http://127.0.0.1:7832$' "$SHELL_ENV"
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
