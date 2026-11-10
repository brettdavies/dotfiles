#!/usr/bin/env bats
# The scheduled upgrade jobs: scripts/upgrade/uv-tools.sh upgrades every uv tool and scripts/upgrade/brew.sh runs the
# `bu` shell function. launchd and systemd start both without reading a startup file, so each script loads
# config/shell itself, and the uv job refuses to run when that leaves the release cooldown unset. Both write the JSON
# Lines run log that scripts/upgrade/lib/run-log.sh defines.
#
# Run: bats tests/scheduled-upgrades.bats

bats_require_minimum_version 1.5.0

REPO_ROOT="$BATS_TEST_DIRNAME/.."
UV_JOB="$REPO_ROOT/scripts/upgrade/uv-tools.sh"
BREW_JOB="$REPO_ROOT/scripts/upgrade/brew.sh"
UNITS="$REPO_ROOT/stow/local/dot-config/systemd/user"
AGENTS="$REPO_ROOT/stow/launchagent/Library/LaunchAgents"

load lib/processes

teardown() {
  stop_spawned
  assert_no_leaks
}

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export UV_LOG="$BATS_TEST_TMPDIR/uv.log" BREW_LOG="$BATS_TEST_TMPDIR/brew.log" SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  export STUB_BREW_PREFIX="$BATS_TEST_TMPDIR/prefix"
  cat >"$STUBS/uv" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo "uv 0.11.20" ;;
  "tool list")
    [ -n "${STUB_UV_LIST_FAIL-}" ] && { echo "error: list failed" >&2; exit 1; }
    if [ -e "$UV_LOG" ]; then echo "claude-swap v0.27.2"; else echo "claude-swap v0.26.0"; fi
    printf '%s\n' "- cswap" "ty v0.0.1"
    ;;
  *)
    printf '%s|%s\n' "$*" "${UV_EXCLUDE_NEWER-}" >>"$UV_LOG"
    [ -n "${STUB_UV_FAIL-}" ] && { echo "error: upgrade failed" >&2; exit 2; }
    echo "Updated claude-swap v0.26.0 -> v0.27.2"
    ;;
esac
EOF
  cat >"$STUBS/brew" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$*" "${HOMEBREW_NO_ANALYTICS-}" >>"$BREW_LOG"
case "$*" in
  --version) echo "Homebrew 5.0.0" ;;
  --prefix) echo "$STUB_BREW_PREFIX" ;;
  "list --versions")
    if grep -q '^upgrade' "$BREW_LOG"; then
      case "${STUB_BREW_LIST_FAIL-}" in after | both) echo "Error: list failed" >&2; exit 1 ;; esac
      echo "uv 0.11.20"
    else
      case "${STUB_BREW_LIST_FAIL-}" in before | both) echo "Error: list failed" >&2; exit 1 ;; esac
      echo "uv 0.11.19"
    fi
    echo "ghostty 1.2.0"
    ;;
  *)
    [ "${STUB_BREW_FAIL-}" = "$1" ] && { echo "Error: $1 failed" >&2; exit 1; }
    echo "==> $1"
    if [ "$1" = update ]; then printf 'Warning: "x\\y"\tz\n' >&2; fi
    ;;
esac
EOF
  # Never reaches the live user manager: Type is oneshot for box-bisync, unanswered for gone.service and simple
  # otherwise, transient.service is transient, and a restart of the unit named in STUB_RESTART_FAIL fails. The unit in
  # STUB_RESTART_DIES is not active after its restart, the one in STUB_RESTART_LOOPS answers each InvocationID lookup
  # with a new value, and the one in STUB_LOOKUP_FAIL fails that lookup.
  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
  "--user show -p Transient --value transient.service") echo yes ;;
  "--user show -p Type --value box-bisync.service") echo oneshot ;;
  "--user show -p Type --value gone.service") ;;
  "--user show -p Type --value "*) echo simple ;;
  "--user try-restart ${STUB_RESTART_FAIL-}") exit 1 ;;
  "--user is-active --quiet ${STUB_RESTART_DIES-}") exit 3 ;;
  "--user show -p InvocationID --value ${STUB_RESTART_LOOPS-}") wc -l <"$SYSTEMCTL_LOG" ;;
  "--user show -p InvocationID --value ${STUB_LOOKUP_FAIL-}") exit 1 ;;
esac
EOF
  # The daily gate's connectivity probe always answers, so no test reaches the network.
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/curl"
  # Records whether bu had finished (its cleanup step logged) when ya ran, and fails on STUB_YA_FAIL.
  export YA_LOG="$BATS_TEST_TMPDIR/ya.log"
  cat >"$STUBS/ya" <<'EOF'
#!/bin/sh
after=no
grep -q '^cleanup' "$BREW_LOG" 2>/dev/null && after=yes
printf '%s|after-bu=%s\n' "$*" "$after" >>"$YA_LOG"
echo "Deploying package \`git.yazi\`"
[ -n "${STUB_YA_FAIL-}" ] && { echo "Error: failed to fetch yazi-rs/plugins" >&2; exit 1; }
echo "Done!"
EOF
  # The pins are proven on the stub yazi's version, so a run bumps nothing unless a test changes the stamp; the bump
  # stub logs that it ran, prints a line of progress, and prints STUB_PINS_OUT as its outcome.
  export YAZI_PINS_STATE_DIR="$BATS_TEST_TMPDIR/state" PINS_LOG="$BATS_TEST_TMPDIR/pins.log"
  mkdir -p "$YAZI_PINS_STATE_DIR"
  echo 26.10.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  printf '#!/bin/sh\nprintf "Yazi\\n    Version: 26.10.1 (Homebrew 2026-10-30)\\n"\n' >"$STUBS/yazi"
  cat >"$STUBS/yazi-pins" <<'EOF'
#!/bin/sh
echo ran >>"$PINS_LOG"
echo "yazi-pins: checking the candidates" >&2
printf '%s\n' "${STUB_PINS_OUT-}"
EOF
  export YAZI_PINS_CMD="$STUBS/yazi-pins"
  chmod +x "$STUBS"/*
}

# Every line is one JSON object carrying the fields an agent filters on, and the last is the run's run.end.
_assert_run_log() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  bad=$(printf '%s\n' "$output" | jaq -c --arg job "$1" 'select(.schema != "dotfiles.upgrade/1"
    or (.ts | test("^[0-9-]+T[0-9:]+Z$") | not) or .event == null or .job != $job or .run_id == "" or .host == "")')
  [ -z "$bad" ]
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -r .event)" = run.start ]
  END=$(printf '%s\n' "$output" | tail -n 1)
  [ "$(printf '%s' "$END" | jaq -r .event)" = run.end ]
}

@test "uv job upgrades nothing when the shell helpers leave the release cooldown unset" {
  mkdir -p "$BATS_TEST_TMPDIR/no-helpers"
  run env -u UV_EXCLUDE_NEWER DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/no-helpers" PATH="$STUBS:$PATH" bash "$UV_JOB"
  [ "$status" -eq 1 ]
  [ ! -e "$UV_LOG" ]
  _assert_run_log uv-tools-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .exit_code, .reason, .next_step.action]')" = \
    '["failure",1,"cooldown-unset","inspect-config"]' ]
}

@test "uv job upgrades every tool under the cooldown supply-chain.sh sets and logs what changed" {
  expected=$(env -u UV_EXCLUDE_NEWER bash -c '. "$1"; printf %s "$UV_EXCLUDE_NEWER"' _ "$REPO_ROOT/config/shell/supply-chain.sh")
  [ -n "$expected" ]
  run env -u UV_EXCLUDE_NEWER -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$UV_JOB"
  [ "$status" -eq 0 ]
  [ "$(cat "$UV_LOG")" = "tool upgrade --all|$expected" ]
  _assert_run_log uv-tools-upgrade
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -r '.settings.UV_EXCLUDE_NEWER')" = "$expected" ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info"
    and .line == "Updated claude-swap v0.26.0 -> v0.27.2")' | grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .exit_code, .reason, .changes, .next_step.action]')" = \
    '["success",0,"ok",[{"name":"claude-swap","from":"0.26.0","to":"0.27.2"}],"none"]' ]
}

@test "bu upgrades greedily, and --no-greedy leaves self-updating casks alone" {
  run env PATH="$STUBS:$PATH" bash -c '. "$1"; bu' _ "$REPO_ROOT/config/shell/shell-functions"
  [ "$status" -eq 0 ]
  [ "$(cut -d'|' -f1 "$BREW_LOG")" = "$(printf 'update\nupgrade --greedy -y\ncleanup')" ]
  : >"$BREW_LOG"
  run env PATH="$STUBS:$PATH" bash -c '. "$1"; bu --no-greedy' _ "$REPO_ROOT/config/shell/shell-functions"
  [ "$status" -eq 0 ]
  [ "$(cut -d'|' -f1 "$BREW_LOG")" = "$(printf 'update\nupgrade -y\ncleanup')" ]
}

@test "brew job runs bu --no-greedy with the shell's Homebrew settings and logs what changed" {
  run env BREW_LOG="$BATS_TEST_TMPDIR/bu.log" PATH="$STUBS:$PATH" \
    bash -c '. "$1"; bu --no-greedy' _ "$REPO_ROOT/config/shell/shell-functions"
  [ "$status" -eq 0 ]
  grep -q '^upgrade -y|' "$BATS_TEST_TMPDIR/bu.log"
  run env -u HOMEBREW_NO_ANALYTICS -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line == "Warning: \"x\\y\" z")' |
    grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .reason, .warnings, .changes]')" = \
    '["success","ok",1,[{"name":"uv","from":"0.11.19","to":"0.11.20"}]]' ]
  [ "$(cut -d'|' -f1 "$BREW_LOG" | grep -v -e '^list ' -e '^--version' -e '^--prefix')" = \
    "$(cut -d'|' -f1 "$BATS_TEST_TMPDIR/bu.log")" ]
  run grep -v '|1$' "$BREW_LOG"
  [ "$status" -eq 1 ]
}

@test "whatever a shell helper prints while loading goes to stderr, keeping the run log JSON" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  helpers="$BATS_TEST_TMPDIR/noisy-helpers"
  mkdir -p "$helpers"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$helpers/"
  printf '%s\n' 'echo "stow: usage"' 'export HOMEBREW_NO_ANALYTICS=1' >"$helpers/noisy.sh"
  run --separate-stderr env DOTFILES_SHELL_DIR="$helpers" PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ "$stderr" = "stow: usage" ]
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -r .settings.HOMEBREW_NO_ANALYTICS)" = 1 ]
}

@test "brew job reports a failed bu with its first error and how to rerun it" {
  run env -u DOTFILES_SHELL_DIR STUB_BREW_FAIL=update PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 1 ]
  _assert_run_log brew-upgrade
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "error" and .line == "Error: update failed")' | grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .exit_code, .reason, .errors, .first_error, .next_step.action]')" = \
    '["failure",1,"upgrade-failed",1,"Error: update failed","rerun"]' ]
  [[ "$(printf '%s' "$END" | jaq -r .next_step.command)" == *scripts/upgrade/brew.sh ]]
}

@test "a failed version listing reports changes as unknown rather than every package as new" {
  for side in before after both; do
    : >"$BREW_LOG"
    run env -u DOTFILES_SHELL_DIR STUB_BREW_LIST_FAIL=$side PATH="$STUBS:$PATH" bash "$BREW_JOB"
    [ "$status" -eq 0 ]
    _assert_run_log brew-upgrade
    case $side in
      before) expected="before the upgrade" ;;
      after) expected="after the upgrade" ;;
      both) expected="before the upgrade and after the upgrade" ;;
    esac
    printf '%s\n' "$output" | jaq -c --arg l "Warning: listing installed versions failed $expected; changes are not reported" \
      'select(.event == "output" and .level == "warning" and .line == $l)' | grep -q .
    [ "$(printf '%s' "$END" | jaq -c '[.outcome, .reason, .warnings, .changes]')" = '["success","ok",2,null]' ]
  done
  run env -u DOTFILES_SHELL_DIR STUB_UV_LIST_FAIL=1 PATH="$STUBS:$PATH" bash "$UV_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log uv-tools-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .reason, .warnings, .changes]')" = '["success","ok",1,null]' ]
}

@test "brew job installs the yazi packages package.toml pins once bu has finished, discarding what an older pin left, logging ya's lines as info" {
  run env -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ "$(cat "$YA_LOG")" = "pkg install --discard|after-bu=yes" ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info" and .line == "Deploying package `git.yazi`")' |
    grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .warnings, .errors]')" = '["success",1,0]' ]
}

@test "a failed ya pkg install is one warning with the rerun command, and the brew run still succeeds" {
  run env -u DOTFILES_SHELL_DIR STUB_YA_FAIL=1 PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  printf '%s\n' "$output" | jaq -c --arg l "Warning: ya pkg install exited 1; installed yazi packages may not match package.toml. Rerun: ya pkg install --discard" \
    'select(.event == "output" and .level == "warning" and .line == $l)' | grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info" and .line == "Error: failed to fetch yazi-rs/plugins")' |
    grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .reason, .warnings, .errors]')" = '["success","ok",2,0]' ]
}

@test "run.end carries yazi_pins as null when the run did not bump the pins" {
  run env -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[has("yazi_pins"), .yazi_pins]')" = '[true,null]' ]
  run env -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$UV_JOB"
  _assert_run_log uv-tools-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[has("yazi_pins"), .yazi_pins]')" = '[true,null]' ]
}

PINS_BUMPED='{"outcome":"bumped","reason":"pr-merged","exit_code":0,"message":"merged","value":null,"yazi_version":"26.10.1","pr":"https://github.com/o/r/pull/7","host_update":null,"next_step":{"action":"none","command":null,"docs":null}}'
PINS_WAITING='{"outcome":"waiting","reason":"cooldown","exit_code":75,"message":"wait","value":null,"yazi_version":"26.10.1","pr":null,"host_update":null,"next_step":{"action":"rerun","command":"x","docs":null}}'

@test "a Linux run whose yazi differs from the version the pins were proven on runs the bump and records its outcome" {
  echo 26.9.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  run env -u DOTFILES_SHELL_DIR STUB_PINS_OUT="$PINS_BUMPED" PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ "$(cat "$PINS_LOG")" = ran ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info" and .line == "yazi-pins: checking the candidates")' |
    grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .warnings, .yazi_pins.outcome, .yazi_pins.pr]')" = \
    '["success",1,"bumped","https://github.com/o/r/pull/7"]' ]
}

@test "a missing stamp runs the bump, and a matching one skips it" {
  rm -f "$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  run env -u DOTFILES_SHELL_DIR STUB_PINS_OUT="$PINS_BUMPED" PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  [ "$(cat "$PINS_LOG")" = ran ]
  : >"$PINS_LOG"
  echo 26.10.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  run env -u DOTFILES_SHELL_DIR STUB_PINS_OUT="$PINS_BUMPED" PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ ! -s "$PINS_LOG" ]
  [ "$(printf '%s' "$END" | jaq -c .yazi_pins)" = null ]
}

@test "a bump that waits is one warning naming its outcome, and the run still succeeds" {
  echo 26.9.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  run env -u DOTFILES_SHELL_DIR STUB_PINS_OUT="$PINS_WAITING" PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  printf '%s\n' "$output" | jaq -c --arg l "Warning: the yazi pin bump ended waiting (cooldown); run.end yazi_pins holds the next step" \
    'select(.event == "output" and .level == "warning" and .line == $l)' | grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .warnings, .yazi_pins.outcome]')" = '["success",2,"waiting"]' ]
}

@test "a bump that prints no outcome object is recorded as failed with reason bad-output" {
  echo 26.9.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  run env -u DOTFILES_SHELL_DIR STUB_PINS_OUT="not json" PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[.yazi_pins.outcome, .yazi_pins.reason, .yazi_pins.next_step.action]')" = \
    '["failed","bad-output","rerun"]' ]
  [[ "$(printf '%s' "$END" | jaq -r .yazi_pins.next_step.command)" == *scripts/upgrade/yazi-pins.sh ]]
}

@test "a brew job that dies during the bump reports the bump as script-error" {
  echo 26.9.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  printf '#!/bin/sh\ncase "$*" in *yazi-pins-log*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v mktemp)" >"$STUBS/mktemp"
  chmod +x "$STUBS/mktemp"
  run env -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -ne 0 ]
  _assert_run_log brew-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[.reason, .yazi_pins.outcome, .yazi_pins.reason, .yazi_pins.yazi_version]')" = \
    '["script-error","failed","script-error","26.10.1"]' ]
}

@test "on macOS the brew job never runs the bump" {
  darwin="$BATS_TEST_TMPDIR/darwin"
  mkdir -p "$darwin" "$BATS_TEST_TMPDIR/bu-only"
  printf '#!/bin/sh\n[ "$1" = -s ] && echo Darwin || exec %s "$@"\n' "$(command -v uname)" >"$darwin/uname"
  chmod +x "$darwin/uname"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$BATS_TEST_TMPDIR/bu-only/"
  echo 26.9.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"
  run env DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" STUB_PINS_OUT="$PINS_BUMPED" PATH="$darwin:$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ ! -e "$PINS_LOG" ]
  [ "$(printf '%s' "$END" | jaq -c .yazi_pins)" = null ]
}

@test "on macOS the brew job leaves stale_processes unchecked" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  darwin="$BATS_TEST_TMPDIR/darwin"
  mkdir -p "$darwin" "$BATS_TEST_TMPDIR/bu-only"
  printf '#!/bin/sh\n[ "$1" = -s ] && echo Darwin || exec %s "$@"\n' "$(command -v uname)" >"$darwin/uname"
  chmod +x "$darwin/uname"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$BATS_TEST_TMPDIR/bu-only/"
  run env DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" PATH="$darwin:$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -r .os)" = Darwin ]
  [ "$(printf '%s' "$END" | jaq -c .stale_processes)" = null ]
  run grep -q '^--prefix' "$BREW_LOG"
  [ "$status" -eq 1 ]
}

@test "uv job reports a failed upgrade with an absolute rerun of its own script" {
  run env -u DOTFILES_SHELL_DIR STUB_UV_FAIL=1 PATH="$STUBS:$PATH" \
    bash -c 'cd "$1" && exec bash scripts/upgrade/uv-tools.sh' _ "$REPO_ROOT"
  [ "$status" -eq 2 ]
  _assert_run_log uv-tools-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .exit_code, .reason, .first_error, .next_step.action]')" = \
    '["failure",2,"upgrade-failed","error: upgrade failed","rerun"]' ]
  [[ "$(printf '%s' "$END" | jaq -r .next_step.command)" == /*/scripts/upgrade/uv-tools.sh ]]
}

@test "a job that dies mid-run still ends its log with a failure run.end" {
  printf '#!/bin/sh\nexit 1\n' >"$STUBS/mktemp"
  chmod +x "$STUBS/mktemp"
  run env -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$UV_JOB"
  [ "$status" -ne 0 ]
  _assert_run_log uv-tools-upgrade
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .reason, .changes, .next_step.action]')" = \
    '["failure","script-error",null,"rerun"]' ]
}

@test "run.start names what started the run" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run env -u DOTFILES_SHELL_DIR INVOCATION_ID=0123abcd PATH="$STUBS:$PATH" bash "$UV_JOB"
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -c '[.trigger, .run_id]')" = '["systemd","0123abcd"]' ]
  run env -u DOTFILES_SHELL_DIR -u INVOCATION_ID XPC_SERVICE_NAME=com.user.uv-tools-upgrade PATH="$STUBS:$PATH" \
    bash "$UV_JOB"
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -r .trigger)" = launchd ]
  run env -u DOTFILES_SHELL_DIR -u INVOCATION_ID XPC_SERVICE_NAME=application.com.mitchellh.ghostty.1 \
    PATH="$STUBS:$PATH" bash "$UV_JOB"
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -r .trigger)" = manual ]
}

@test "the run log lists added and removed packages with null on the missing side" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run bash -c '. "$1"; run_log_changes "$(printf "kept 1\nbumped 1\ngone 2")" "$(printf "kept 1\nbumped 2\nnew 3")"' \
    _ "$REPO_ROOT/scripts/upgrade/lib/run-log.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jaq -c 'sort_by(.name)')" = \
    '[{"name":"bumped","from":"1","to":"2"},{"name":"gone","from":"2","to":null},{"name":"new","from":null,"to":"3"}]' ]
}

# A fake /proc: <pid> <executable readlink> <cgroup path>.
_fake_proc() {
  mkdir -p "$PROC/$1"
  ln -s "$2" "$PROC/$1/exe"
  printf '0::%s\n' "$3" >"$PROC/$1/cgroup"
}

# The status lines that make a fake process one of the user's with the given capabilities, the kind a probe that reads
# other processes would pick: <pid> <owner uid> <permitted capability mask>.
_fake_status() {
  printf 'Uid:\t%s\t%s\t%s\t%s\nCapPrm:\t%s\n' "$2" "$2" "$2" "$2" "$3" >"$PROC/$1/status"
}

@test "processes on a removed Homebrew binary: long-running user services restart, the rest are reported" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  find / -maxdepth 0 -printf '' 2>/dev/null || skip "the scan lists /proc with GNU find's -printf"
  _stub_settle_sleep
  PROC="$BATS_TEST_TMPDIR/proc" P=/opt/brew US=/user.slice/user-1000.slice/user@1000.service/app.slice
  mkdir -p "$PROC/self"
  printf '0::%s\n' "$US/brew-upgrade.service" >"$PROC/self/cgroup"
  _fake_proc 101 "$P/Cellar/caddy/2/bin/caddy (deleted)" "$US/caddy.service"
  _fake_proc 102 "$P/Cellar/bun/1/bin/bun (deleted)" "$US/qmd-serve.service"
  _fake_proc 103 "$P/Cellar/lazygit/1/bin/lazygit (deleted)" /user.slice/user-1000.slice/session-c1.scope
  _fake_proc 104 "$P/Cellar/lazygit/1/bin/lazygit (deleted)" /user.slice/user-1000.slice/session-c1.scope
  _fake_proc 105 "$P/Cellar/rclone/1/bin/rclone (deleted)" "$US/box-bisync.service"
  _fake_proc 106 "$P/Cellar/caddy/3/bin/caddy" "$US/other.service"
  _fake_proc 107 "/usr/bin/foo (deleted)" "$US/foo.service"
  _fake_proc 108 "$P/Cellar/bash/5/bin/bash (deleted)" "$US/brew-upgrade.service"
  _fake_proc 109 "$P/Cellar/caddy/2/bin/caddy (deleted)" /system.slice/web.service
  _fake_proc 110 "$P/Cellar/node/1/bin/node (deleted)" "$US/caddy.service"
  _fake_proc 111 "$P/Cellar/root/1/bin/root (deleted)" /
  mkdir -p "$PROC/112"
  ln -s "$P/Cellar/gone/1/bin/gone (deleted)" "$PROC/112/exe"
  _fake_proc 113 "$P/Cellar/old/1/bin/old (deleted)" "$US/gone.service"
  run env STUB_RESTART_FAIL=qmd-serve.service PATH="$STUBS:$PATH" bash -c '
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(grep try-restart "$SYSTEMCTL_LOG" | sort)" = "$(printf '%s\n' '--user try-restart caddy.service' '--user try-restart qmd-serve.service')" ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c 'map([.unit, .action, .pids])')" = \
    '[["box-bisync.service","left-running",[105]],["brew-upgrade.service","left-running",[108]],["caddy.service","restarted",[101]],["caddy.service","restarted",[110]],["gone.service","left-running",[113]],["qmd-serve.service","restart-failed",[102]],["session-c1.scope","left-running",[103,104]],["unknown","left-running",[112]],["unknown","left-running",[111]],["web.service","left-running",[109]]]' ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -r 'map(select(.unit == "unknown") | .exe) | sort | join(" ")')" = \
    "/opt/brew/Cellar/gone/1/bin/gone /opt/brew/Cellar/root/1/bin/root" ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 8 ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line ==
    "Warning: restarting qmd-serve.service onto the upgrade failed or did not stay up; check systemctl --user status qmd-serve.service")' | grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info"
    and .line == "restarted caddy.service, which was running the removed /opt/brew/Cellar/caddy/2/bin/caddy")' | grep -q .
}

# Outside a user namespace, a process may still refuse its executable link to the job: the user manager, the job's
# parent under systemd, holds CAP_WAKE_ALARM, and a process that is not dumpable refuses it to everyone. Neither may
# stop the scan.
@test "processes whose executables do not read, the job's parent among them, do not stop the scan" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  find / -maxdepth 0 -printf '' 2>/dev/null || skip "the scan lists /proc with GNU find's -printf"
  PROC="$BATS_TEST_TMPDIR/proc" US=/user.slice/user-1000.slice/user@1000.service
  mkdir -p "$PROC/self"
  printf '0::%s\n' "$US/app.slice/brew-upgrade.service" >"$PROC/self/cgroup"
  printf '%10s %10s %10s\n' 0 0 4294967295 >"$PROC/self/uid_map"
  _fake_proc 101 "/opt/brew/Cellar/bash/5/bin/bash (deleted)" "$US/app.slice/brew-upgrade.service"
  _fake_status 101 "$(id -u)" 0000000000000000
  mkdir -p "$PROC/102/exe"
  printf '0::%s\n' "$US/app.slice/agent.service" >"$PROC/102/cgroup"
  _fake_status 102 "$(id -u)" 0000000000000000
  run env PATH="$STUBS:$PATH" bash -c '
    mkdir -p "$2/$PPID/exe"
    printf "0::%s\n" "$3/init.scope" >"$2/$PPID/cgroup"
    printf "Uid:\t%s\t%s\t%s\t%s\nCapPrm:\t0000000800000000\n" "$4" "$4" "$4" "$4" >"$2/$PPID/status"
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0 RUN_STALE=null
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC" "$US" "$(id -u)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c 'map([.unit, .action, .pids])')" = '[["brew-upgrade.service","left-running",[101]]]' ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 1 ]
  [ ! -e "$SYSTEMCTL_LOG" ] || ! grep -q try-restart "$SYSTEMCTL_LOG"
}

# The one-uid map is what the user manager gives a unit that carries PrivateTmp=. Every process outside the namespace
# reads blank there, so even a stale process the fixture leaves readable must not be reported.
@test "a scan inside a nested user namespace reports stale processes as unchecked" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  PROC="$BATS_TEST_TMPDIR/proc" US=/user.slice/user-1000.slice/user@1000.service/app.slice
  mkdir -p "$PROC/self"
  printf '0::%s\n' "$US/brew-upgrade.service" >"$PROC/self/cgroup"
  printf '%10s %10s %10s\n' 1000 1000 1 >"$PROC/self/uid_map"
  _fake_proc 101 "/opt/brew/Cellar/caddy/2/bin/caddy (deleted)" "$US/caddy.service"
  run env PATH="$STUBS:$PATH" bash -c '
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0 RUN_STALE=null
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n 1)" = null ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 1 ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning"
    and (.line | startswith("Warning: the job runs in a user namespace")))' | grep -q .
  [ ! -e "$SYSTEMCTL_LOG" ]
}

# Logs the settle wait beside the systemctl calls, so a test can check their order and does not wait it out.
_stub_settle_sleep() {
  printf '#!/bin/sh\nprintf "sleep %%s\\n" "$*" >>"$SYSTEMCTL_LOG"\n' >"$STUBS/sleep"
  chmod +x "$STUBS/sleep"
}

# Under set -e as in brew.sh, so a failed lookup that stopped the scan would lose the units sorted after it.
@test "a restart counts only if the unit is still up on the same invocation 3 s later" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  find / -maxdepth 0 -printf '' 2>/dev/null || skip "the scan lists /proc with GNU find's -printf"
  _stub_settle_sleep
  PROC="$BATS_TEST_TMPDIR/proc" US=/user.slice/user-1000.slice/user@1000.service/app.slice
  mkdir -p "$PROC/self"
  printf '0::%s\n' "$US/brew-upgrade.service" >"$PROC/self/cgroup"
  _fake_proc 101 "/opt/brew/Cellar/a/1/bin/a (deleted)" "$US/caddy.service"
  _fake_proc 102 "/opt/brew/Cellar/b/1/bin/b (deleted)" "$US/dies.service"
  _fake_proc 103 "/opt/brew/Cellar/c/1/bin/c (deleted)" "$US/loops.service"
  _fake_proc 104 "/opt/brew/Cellar/d/1/bin/d (deleted)" "$US/noid.service"
  _fake_proc 105 "/opt/brew/Cellar/e/1/bin/e (deleted)" "$US/zed.service"
  run env STUB_RESTART_DIES=dies.service STUB_RESTART_LOOPS=loops.service STUB_LOOKUP_FAIL=noid.service \
    PATH="$STUBS:$PATH" bash -c '
    set -euo pipefail
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c 'map([.unit, .action])')" = \
    '[["caddy.service","restarted"],["dies.service","restart-failed"],["loops.service","restart-failed"],["noid.service","restarted"],["zed.service","restarted"]]' ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 2 ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line ==
    "Warning: restarting dies.service onto the upgrade failed or did not stay up; check systemctl --user status dies.service")' | grep -q .
  [ "$(sed -n '/try-restart caddy.service/,$p' "$SYSTEMCTL_LOG" | head -n 5)" = "$(printf '%s\n' \
    '--user try-restart caddy.service' '--user show -p InvocationID --value caddy.service' 'sleep 3' \
    '--user is-active --quiet caddy.service' '--user show -p InvocationID --value caddy.service')" ]
}

@test "a transient service stays running, since a restart would rerun its command" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  find / -maxdepth 0 -printf '' 2>/dev/null || skip "the scan lists /proc with GNU find's -printf"
  PROC="$BATS_TEST_TMPDIR/proc" US=/user.slice/user-1000.slice/user@1000.service/app.slice
  mkdir -p "$PROC/self"
  printf '0::%s\n' "$US/brew-upgrade.service" >"$PROC/self/cgroup"
  _fake_proc 101 "/opt/brew/Cellar/a/1/bin/a (deleted)" "$US/transient.service"
  run env PATH="$STUBS:$PATH" bash -c '
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c 'map([.unit, .action])')" = '[["transient.service","left-running"]]' ]
  [ -z "$(grep try-restart "$SYSTEMCTL_LOG" || true)" ]
}

# A tool that logs an error and a warning and then outlives a SIGTERM, standing in for one that is slow to exit, as what
# both jobs' upgrade commands run. It logs one more warning once TOOL_RESUME exists. The job's temp files land in
# SUMMARY_DIR. The uv job runs its tool directly in the capture's pipeline, so a TERM trap would wait on the tool there,
# and run.end would arrive too late to pass. The brew job runs it below a function's subshell, which dies on the signal.
_stalled_tool_fixture() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  export LAUNCHD_LOG_DIR="$BATS_TEST_TMPDIR/Logs" UPGRADE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export SUMMARY_DIR="$BATS_TEST_TMPDIR/summaries" DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only"
  export TOOL_RESUME="$BATS_TEST_TMPDIR/tool-resume" UV_EXCLUDE_NEWER=2026-01-01
  mkdir -p "$LAUNCHD_LOG_DIR" "$SUMMARY_DIR" "$DOTFILES_SHELL_DIR"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$DOTFILES_SHELL_DIR/"
  cat >"$STUBS/stalled-tool" <<'EOF'
#!/bin/sh
trap '' TERM
echo "Error: a mirror failed"
echo "Warning: a slow mirror"
until [ -e "$TOOL_RESUME" ]; do sleep 0.1; done
echo "Warning: after the stop"
exec sleep 30
EOF
  cat >"$STUBS/brew" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "Homebrew 5.0.0" ;;
  list) echo "uv 0.11.19" ;;
  upgrade) exec stalled-tool ;;
  *) echo "==> $1" ;;
esac
EOF
  cat >"$STUBS/uv" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo "uv 0.11.20" ;;
  "tool list") echo "claude-swap v0.26.0" ;;
  *) exec stalled-tool ;;
esac
EOF
  printf '#!/bin/sh\nf="$SUMMARY_DIR/summary.$$"\n: >"$f"\necho "$f"\n' >"$STUBS/mktemp"
  chmod +x "$STUBS"/*
}

# Usage: _wait_for_log <pattern>; fails when the run log does not show the pattern within 30 s.
_wait_for_log() {
  local deadline=$((SECONDS + 30))
  until grep -qs "$1" "$log" || ((SECONDS > deadline)); do sleep 0.1; done
  grep -q "$1" "$log"
}

# What a stop has to leave, however the signals arrived: run.end while the tool still runs, and the counts the job had
# logged. exit_code reads 1, as run-log.sh documents. The tool then logs one more line, which only a reader that outlived
# the stop would write after run.end.
_assert_stop_ended_log() {
  local deadline=$((SECONDS + 10))
  until grep -qs '"event":"run.end"' "$log" || ((SECONDS > deadline)); do sleep 0.1; done
  [ "$(jaq -c 'select(.event == "run.end") | [.outcome, .exit_code, .reason, .errors, .warnings, .first_error]' "$log")" = \
    '["failure",1,"script-error",1,1,"Error: a mirror failed"]' ]
  kill -0 -- "-$job"
  [ -z "$(ls -A "$SUMMARY_DIR")" ]
  : >"$TOOL_RESUME"
  sleep 1
  [ "$(tail -n 1 "$log" | jaq -r .event)" = run.end ]
}

# launchd's stop of a job, through the agent's real chain: a SIGTERM to its main process alone, which is the daily gate
# because the wrapper execs it, then once that has exited a SIGTERM to the rest of its process group. launchd.plist(5)
# documents that sweep under AbandonProcessGroup without naming its signal; launchd's public source names it (job_reap,
# core.c:3623, `killpg2(j->p, SIGTERM)`). Measured with a scratch agent through this chain and the uv job on macOS 27.0:
# `launchctl bootout` gave the tool one SIGTERM within 10 ms and no SIGKILL in the next 8 s, the gate and the job were gone
# within 0.2 s, and the log ended in one run.end with these counts.
_assert_launchd_stop_ends_log() { # <job> <script>
  log=$LAUNCHD_LOG_DIR/$1.jsonl
  spawn env PATH="$STUBS:$PATH" "$REPO_ROOT/scripts/launchd-run.sh" "$1.jsonl" \
    "$REPO_ROOT/scripts/upgrade/daily-gate.sh" "$1" "$2" >/dev/null 2>&1 3>&-
  job=$!
  _wait_for_log 'a slow mirror'

  kill -TERM "$job"
  wait "$job" || true
  kill -TERM -- "-$job"
  _assert_stop_ended_log
  [ ! -e "$UPGRADE_STATE_DIR/$1.last-success" ]
}

# systemd's stop of a unit, which its start timeout also uses: one SIGTERM to every process in the unit at once, with no
# wrapper and no gate. Measured with a transient user unit stopped during the brew job's pin bump: the stop took 0.09 s and
# reached the real timeout in its own process group, the journal held one run.end at priority 3 with these counts, and the
# manager read code=killed, status=15/TERM.
_assert_systemd_stop_ends_log() { # <script>
  log=$BATS_TEST_TMPDIR/journal.jsonl
  spawn env PATH="$STUBS:$PATH" "$1" >"$log" 2>/dev/null 3>&-
  job=$!
  _wait_for_log 'a slow mirror'

  kill -TERM -- "-$job"
  _assert_stop_ended_log
}

@test "a launchd stop ends the brew job's log at once with the counts so far, even while a tool ignores SIGTERM" {
  _stalled_tool_fixture
  _assert_launchd_stop_ends_log brew-upgrade "$BREW_JOB"
}

@test "a launchd stop ends the uv job's log at once with the counts so far, even while a tool ignores SIGTERM" {
  _stalled_tool_fixture
  _assert_launchd_stop_ends_log uv-tools-upgrade "$UV_JOB"
}

@test "a systemd stop ends the brew job's log at once with the counts so far, even while a tool ignores SIGTERM" {
  _stalled_tool_fixture
  _assert_systemd_stop_ends_log "$BREW_JOB"
}

@test "a systemd stop ends the uv job's log at once with the counts so far, even while a tool ignores SIGTERM" {
  _stalled_tool_fixture
  _assert_systemd_stop_ends_log "$UV_JOB"
}

@test "a line logged after a kill does not bring the removed summary file back" {
  _stalled_tool_fixture
  log=$LAUNCHD_LOG_DIR/brew-upgrade.jsonl
  spawn env PATH="$STUBS:$PATH" "$REPO_ROOT/scripts/launchd-run.sh" brew-upgrade.jsonl "$BREW_JOB" >/dev/null 2>&1 3>&-
  job=$!
  _wait_for_log 'a slow mirror'

  kill -TERM "$job"
  wait "$job" || true
  _wait_for_log '"event":"run.end"'
  [ -z "$(ls -A "$SUMMARY_DIR")" ]

  : >"$TOOL_RESUME"
  _wait_for_log 'after the stop'
  [ -z "$(ls -A "$SUMMARY_DIR")" ]
}

# The upgrade finishes here and the bump is what stalls. The timeout stub keeps the bump in the job's process group,
# which the real timeout leaves, so the test can stop all of it.
@test "a kill during the pin bump logs the bump's stderr and leaves no temp file" {
  _stalled_tool_fixture
  export BUMP_STARTED="$BATS_TEST_TMPDIR/bump-started" YAZI_PINS_CMD="$STUBS/stalled-bump"
  log=$BATS_TEST_TMPDIR/journal.jsonl
  linux="$BATS_TEST_TMPDIR/linux"
  mkdir -p "$linux"
  printf '#!/bin/sh\n[ "$1" = -s ] && echo Linux || exec %s "$@"\n' "$(command -v uname)" >"$linux/uname"
  printf '#!/bin/sh\necho "==> upgraded"\n' >"$STUBS/stalled-tool"
  printf '#!/bin/sh\nshift\nexec "$@"\n' >"$STUBS/timeout"
  printf '#!/bin/sh\necho "yazi-pins: checking" >&2\n: >"$BUMP_STARTED"\nexec sleep 30\n' >"$STUBS/stalled-bump"
  chmod +x "$STUBS"/* "$linux/uname"
  echo 26.9.1 >"$YAZI_PINS_STATE_DIR/yazi-pins-proven"

  spawn env PATH="$linux:$STUBS:$PATH" "$BREW_JOB" >"$log" 2>/dev/null 3>&-
  job=$!
  deadline=$((SECONDS + 30))
  until [ -e "$BUMP_STARTED" ] || ((SECONDS > deadline)); do sleep 0.1; done
  [ -e "$BUMP_STARTED" ]

  kill -TERM -- "-$job"
  wait "$job" || true
  _wait_for_log '"event":"run.end"'
  [ "$(jaq -c 'select(.event == "run.end") | [.reason, .yazi_pins.reason]' "$log")" = '["script-error","script-error"]' ]
  [ "$(tail -n 1 "$log" | jaq -r .event)" = run.end ]
  jaq -c 'select(.event == "output" and .level == "info" and .line == "yazi-pins: checking")' "$log" | grep -q .
  [ -z "$(ls -A "$SUMMARY_DIR")" ]
}

@test "brew job reports a process still running a binary the upgrade removed" {
  [ -d /proc/self/fd ] || skip "the scan reads /proc"
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  bin="$STUB_BREW_PREFIX/Cellar/napper/1/bin/napper"
  mkdir -p "${bin%/*}"
  # perl runs under any name, and its sleep is a builtin, so the deleted copy stays the running executable. A
  # multicall coreutils such as uutils (Ubuntu 26.04's) refuses to run as a renamed copy.
  cp "$(command -v perl)" "$bin"
  "$bin" -e 'sleep 30' &
  napper=$!
  # The fork returns before the child execs the copy, and an exec that comes after the rm finds no file to run.
  n=0
  until [ "$(readlink "/proc/$napper/exe" 2>/dev/null)" = "$bin" ] || ((n++ > 50)); do sleep 0.1; done
  [ "$(readlink "/proc/$napper/exe" 2>/dev/null)" = "$bin" ] || {
    kill "$napper" 2>/dev/null || true
    echo "pid $napper was not running $bin within 5 s of starting it" >&2
    return 1
  }
  rm "$bin"
  run env -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$BREW_JOB"
  kill "$napper"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  [ "$(printf '%s' "$END" | jaq -c --argjson pid "$napper" '[.stale_processes[] | select(.pids == [$pid]) | [.exe, .action]]')" = \
    "[[\"$bin\",\"left-running\"]]" ]
  [ ! -e "$SYSTEMCTL_LOG" ] || ! grep -q try-restart "$SYSTEMCTL_LOG"
  run env -u DOTFILES_SHELL_DIR PATH="$STUBS:$PATH" bash "$UV_JOB"
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c .stale_processes)" = null ]
}

@test "under journald each line carries the syslog priority of its level" {
  [ -d /proc/self/fd ] || skip "journald runs only on Linux"
  out="$BATS_TEST_TMPDIR/journal"
  : >"$out"
  stream=$(stat -L -c '%d:%i' "$out")
  env -u DOTFILES_SHELL_DIR JOURNAL_STREAM="$stream" STUB_BREW_FAIL=update PATH="$STUBS:$PATH" \
    bash "$BREW_JOB" >"$out" || true
  [ "$(head -n 1 "$out" | cut -c1-3)" = "<6>" ]
  grep -q '^<3>{.*"line":"Error: update failed"' "$out"
  [ "$(tail -n 1 "$out" | cut -c1-3)" = "<3>" ]
}

@test "the brew agent's command runs bu through the daily gate, logs JSON Lines, and skips a second fire that day" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  export LAUNCHD_LOG_DIR="$BATS_TEST_TMPDIR/Logs" UPGRADE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  logs=$LAUNCHD_LOG_DIR
  mkdir -p "$logs"
  # Only shell-functions, for bu: the other helpers would act on the real $HOME.
  mkdir -p "$BATS_TEST_TMPDIR/bu-only"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$BATS_TEST_TMPDIR/bu-only/"
  export DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only"
  agent=("$REPO_ROOT/scripts/launchd-run.sh" brew-upgrade.jsonl
    "$REPO_ROOT/scripts/upgrade/daily-gate.sh" brew-upgrade "$REPO_ROOT/scripts/upgrade/brew.sh")
  run env PATH="$STUBS:$PATH" "${agent[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head -n 1 "$logs/brew-upgrade.jsonl" | jaq -r .event)" = run.start ]
  [ "$(tail -n 1 "$logs/brew-upgrade.jsonl" | jaq -r .reason)" = ok ]
  [ ! -s "$logs/brew-upgrade.error.log" ]
  [ -f "$UPGRADE_STATE_DIR/brew-upgrade.last-success" ]
  logged=$(wc -l <"$logs/brew-upgrade.jsonl")
  run env PATH="$STUBS:$PATH" "${agent[@]}"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$logs/brew-upgrade.jsonl")" -eq "$logged" ]
  [ ! -s "$logs/brew-upgrade.error.log" ]
}

_agent_tries_hourly_at() {
  local plist="$AGENTS/com.user.$1-upgrade.plist"
  grep -qF "exec \"\$HOME/dotfiles/scripts/launchd-run.sh\" $1-upgrade.jsonl \"\$HOME/dotfiles/scripts/upgrade/daily-gate.sh\" $1-upgrade \"\$HOME/dotfiles/scripts/upgrade/$1.sh\"</string>" "$plist"
  if grep -q '<key>Hour</key>' "$plist"; then return 1; fi
  grep -A1 '<key>Minute</key>' "$plist" | grep -qF "<integer>$2</integer>"
}

@test "systemd runs the upgrade scripts daily at 04:00 and 04:30, and launchd tries them hourly at :00 and :30" {
  grep -qx 'ExecStart=%h/dotfiles/scripts/upgrade/brew.sh' "$UNITS/brew-upgrade.service"
  grep -qx 'ExecStart=%h/dotfiles/scripts/upgrade/uv-tools.sh' "$UNITS/uv-tools-upgrade.service"
  grep -qx 'SyslogIdentifier=brew-upgrade' "$UNITS/brew-upgrade.service"
  grep -qx 'SyslogIdentifier=uv-tools-upgrade' "$UNITS/uv-tools-upgrade.service"
  grep -qx 'TimeoutStartSec=2h' "$UNITS/brew-upgrade.service"
  grep -qx 'TimeoutStartSec=1h' "$UNITS/uv-tools-upgrade.service"
  # PrivateTmp= puts a user unit in a user namespace, where the stale-process scan reads every other process as blank.
  run grep -q '^PrivateTmp=' "$UNITS/brew-upgrade.service"
  [ "$status" -eq 1 ]
  grep -qx 'After=network-online.target brew-upgrade.service' "$UNITS/uv-tools-upgrade.service"
  grep -qx 'OnCalendar=\*-\*-\* 04:00:00' "$UNITS/brew-upgrade.timer"
  grep -qx 'OnCalendar=\*-\*-\* 04:30:00' "$UNITS/uv-tools-upgrade.timer"
  _agent_tries_hourly_at brew 0
  _agent_tries_hourly_at uv-tools 30
}
