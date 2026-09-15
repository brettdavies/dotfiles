#!/usr/bin/env bats
# Shape guards for the cswap auto-switch deployment: the stow/cswap units, the
# settings deploy script, and their registration in scripts/stow-deploy.
#
# Every assertion reads committed files or drives the deploy script against a
# stub binary on a sandboxed PATH, so the suite passes on macOS without a cswap
# unit deployed and never touches a real installation's settings.
#
# Run: bats tests/cswap-autoswitch.bats

REPO="$BATS_TEST_DIRNAME/.."
SERVICE="$REPO/stow/cswap/dot-config/systemd/user/cswap-auto.service"
TIMER="$REPO/stow/cswap/dot-config/systemd/user/cswap-auto.timer"
DEPLOY="$REPO/scripts/cswap-autoswitch-deploy.sh"
STOW_DEPLOY="$REPO/scripts/stow-deploy"
LINT_SHELL="$REPO/scripts/lint-shell"

# A stand-in for cswap that keeps its settings in $STATE. It answers `config`
# with the same "key value (source)" rows the real tool prints and records each
# `config set` so a test can assert on the calls.
make_stub() {
  cat > "$BIN/cswap" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state="$CSWAP_STUB_STATE"
calls="$CSWAP_STUB_CALLS"

if [ ! -s "$state" ]; then
  cat > "$state" <<'DEFAULTS'
autoswitch.threshold 90 (default)
autoswitch.hysteresisPct 10 (default)
autoswitch.includeApiKeyAccounts false (default)
autoswitch.model (none) (default)
DEFAULTS
fi

case "${1:-}" in
  config)
    if [ "${2:-}" = "set" ]; then
      echo "$3 $4" >> "$calls"
      tmp="$(mktemp)"
      # A pinned setting loses the "(default)" marker, as the real tool does.
      awk -v k="$3" -v v="$4" '$1 == k { print k, v; next } { print }' "$state" > "$tmp"
      mv "$tmp" "$state"
      exit 0
    fi
    cat "$state"
    ;;
  *) exit 64 ;;
esac
STUB
  chmod +x "$BIN/cswap"
}

setup() {
  WORK="$(mktemp -d)"
  BIN="$WORK/bin"
  mkdir -p "$BIN"
  export CSWAP_STUB_STATE="$WORK/state"
  export CSWAP_STUB_CALLS="$WORK/calls"
  : > "$CSWAP_STUB_STATE"
  : > "$CSWAP_STUB_CALLS"
  make_stub
  PATH="$BIN:$PATH"
  export PATH
}

teardown() {
  rm -rf "$WORK"
}

# --- Unit shape ---

@test "the timer runs minutely and catches up after downtime" {
  grep -q '^OnCalendar=minutely$' "$TIMER"
  grep -q '^Persistent=true$' "$TIMER"
  grep -q '^WantedBy=timers.target$' "$TIMER"
}

@test "the service is oneshot and declares no Restart directive" {
  grep -q '^Type=oneshot$' "$SERVICE"
  run grep -q '^Restart=' "$SERVICE"
  [ "$status" -ne 0 ]
}

@test "the service accepts the nothing-to-do and hold exit codes as success" {
  # `auto --once` exits 2 when there is nothing to do and 3 when every account
  # is spent. Without this every routine tick would register as a failed unit.
  grep -q '^SuccessExitStatus=2 3$' "$SERVICE"
}

@test "the service carries no trip point or model flag" {
  # KTD2: settings live in the persisted config so a hand-run tick matches a
  # scheduled one. A flag here would make them diverge silently.
  run grep -E -- '--threshold|--model' "$SERVICE"
  [ "$status" -ne 0 ]
}

@test "no committed cswap file carries a username" {
  # Scoped to the whole file, not just ExecStart: a PATH or WorkingDirectory
  # directive is where a home path would land next.
  for f in "$SERVICE" "$TIMER" "$DEPLOY"; do
    run grep -E '/(home|Users)/[a-z]' "$f"
    if [ "$status" -eq 0 ]; then
      # /home/linuxbrew is a fixed prefix, not a user's home.
      remaining="$(grep -E -o '/(home|Users)/[a-z][a-z0-9_-]*' "$f" | grep -v '^/home/linuxbrew$' || true)"
      [ -z "$remaining" ] || {
        echo "$(basename "$f") carries a home path: $remaining" >&2
        return 1
      }
    fi
  done
}

# --- Deploy registration ---

@test "cswap is in SHARED_PACKAGES" {
  shared=$(grep '^SHARED_PACKAGES=' "$STOW_DEPLOY" | sed 's/.*(\(.*\))/\1/')
  [[ " $shared " == *" cswap "* ]]
}

@test "cswap is guarded Linux-only so a macOS deploy skips it" {
  # Matches wherever cswap sits in the guard's alternation, so reordering the
  # list or appending another Linux-only package does not fail this test.
  run grep -E '\| *cswap *[|)]' "$STOW_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "the deploy script is executable and enumerated as a lint target" {
  [ -x "$DEPLOY" ]
  grep -q 'scripts/cswap-autoswitch-deploy.sh' "$LINT_SHELL"
  # Present in both _is_target and _all_targets, or lint skips it silently.
  [ "$(grep -c 'scripts/cswap-autoswitch-deploy.sh' "$LINT_SHELL")" -ge 2 ]
}

# --- Settings the script applies ---

@test "the trip point and anti-flap margin are set so the proactive path is reachable" {
  run "$DEPLOY"
  [ "$status" -eq 0 ]
  grep -q '^autoswitch.threshold 99$' "$CSWAP_STUB_CALLS"
  grep -q '^autoswitch.hysteresisPct 2$' "$CSWAP_STUB_CALLS"
}

@test "the per-model trigger is set to all, not a named model" {
  run "$DEPLOY"
  [ "$status" -eq 0 ]
  grep -q '^autoswitch.model all$' "$CSWAP_STUB_CALLS"
  run grep -E '^autoswitch\.model (Fable|Opus|Sonnet|Haiku)' "$CSWAP_STUB_CALLS"
  [ "$status" -ne 0 ]
}

@test "the API-key exclusion is pinned rather than inherited" {
  run "$DEPLOY"
  [ "$status" -eq 0 ]
  grep -q '^autoswitch.includeApiKeyAccounts false$' "$CSWAP_STUB_CALLS"
}

@test "a second run changes nothing and says so" {
  run "$DEPLOY"
  [ "$status" -eq 0 ]
  first="$(sort "$CSWAP_STUB_STATE")"

  : > "$CSWAP_STUB_CALLS"
  run "$DEPLOY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing changed"* ]]
  [ ! -s "$CSWAP_STUB_CALLS" ]
  [ "$(sort "$CSWAP_STUB_STATE")" = "$first" ]
}

@test "a missing binary fails loudly instead of applying nothing quietly" {
  rm -f "$BIN/cswap"
  CSWAP_BIN="$BIN/cswap" run "$DEPLOY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cswap not found"* ]]
}
