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

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export UV_LOG="$BATS_TEST_TMPDIR/uv.log" BREW_LOG="$BATS_TEST_TMPDIR/brew.log" SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  export STUB_BREW_PREFIX="$BATS_TEST_TMPDIR/prefix" UPGRADE_RESTART_SETTLE_SECS=0
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
    if [ -n "${STUB_BREW_TTY-}" ] && [ "$1" = update ]; then stty -echo </dev/tty && stty echo </dev/tty; fi
    if [ -n "${STUB_BREW_IGNORE_TERM-}" ] && [ "$1" = update ]; then trap '' TERM; fi
    if [ -n "${STUB_BREW_SLOW-}" ] && [ "$1" = update ]; then sleep "$STUB_BREW_SLOW"; fi
    ;;
esac
EOF
  # Never reaches the live user manager. Type is oneshot for box-bisync, empty for gone.service and simple otherwise;
  # the unit named in STUB_TRANSIENT is transient, STUB_UNREACHABLE's lookup fails as if the bus were down, and
  # STUB_LOOPING gets a new InvocationID at every look, as systemd's own restarts give it. A restart of
  # STUB_RESTART_FAIL fails, STUB_INACTIVE is not active after its restart, and STUB_RESTART_KILLS or STUB_SHOW_KILLS
  # kills the scanning shell (SCAN_PID) at that step.
  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
unit=${*##* }
case "$*" in
  "--user show -p Type -p Transient "*)
    [ "$unit" = "${STUB_SHOW_KILLS-}" ] && kill -TERM "${SCAN_PID:-$PPID}"
    [ "$unit" = "${STUB_UNREACHABLE-}" ] && { echo "Failed to connect to bus" >&2; exit 1; }
    case $unit in box-bisync.service) type=oneshot ;; gone.service) type= ;; *) type=simple ;; esac
    transient=no
    [ "$unit" = "${STUB_TRANSIENT-}" ] && transient=yes
    printf 'Type=%s\nTransient=%s\n' "$type" "$transient"
    ;;
  "--user show -p InvocationID --value "*)
    [ "$unit" = "${STUB_INVOCATION_FAIL-}" ] && exit 1
    if [ "$unit" = "${STUB_LOOPING-}" ]; then
      n=$(($(cat "$SYSTEMCTL_LOG.inv" 2>/dev/null || echo 0) + 1))
      echo "$n" >"$SYSTEMCTL_LOG.inv"
      echo "inv-$n"
    else
      echo inv-1
    fi
    ;;
  "--user try-restart ${STUB_RESTART_FAIL-}") exit 1 ;;
  "--user try-restart ${STUB_RESTART_KILLS-}") kill -TERM "${SCAN_PID:-$PPID}" ;;
  "--user is-active --quiet ${STUB_INACTIVE-}") exit 3 ;;
esac
EOF
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
  [ "$(printf '%s\n' "$output" | head -n 1 | jaq -r .settings.UPGRADE_RESTART_SETTLE_SECS)" = 0 ]
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

@test "on macOS the brew job leaves stale_processes unchecked" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  darwin="$BATS_TEST_TMPDIR/darwin"
  mkdir -p "$darwin" "$BATS_TEST_TMPDIR/bu-only"
  printf '#!/bin/sh\n[ "$1" = -s ] && echo Darwin || /usr/bin/env uname "$@"\n' >"$darwin/uname"
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

@test "processes on a removed Homebrew binary: long-running user services restart, the rest are reported" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  find / -maxdepth 0 -printf '' 2>/dev/null || skip "the scan lists /proc with GNU find's -printf"
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
  _fake_proc 114 "$P/Cellar/flaky/1/bin/flaky (deleted)" "$US/flaky.service"
  _fake_proc 115 "$P/Cellar/batch/1/bin/batch (deleted)" "$US/batch.service"
  _fake_proc 116 "$P/Cellar/loopy/1/bin/loopy (deleted)" "$US/loopy.service"
  _fake_proc 117 "$P/Cellar/lost/1/bin/lost (deleted)" "$US/lost.service"
  _fake_proc 118 "$P/Cellar/lost/1/bin/lost-helper (deleted)" "$US/lost.service"
  run env STUB_RESTART_FAIL=qmd-serve.service STUB_INACTIVE=flaky.service STUB_TRANSIENT=batch.service \
    STUB_LOOPING=loopy.service STUB_UNREACHABLE=lost.service PATH="$STUBS:$PATH" bash -c '
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(grep try-restart "$SYSTEMCTL_LOG" | sort)" = \
    "$(printf '%s\n' caddy flaky loopy qmd-serve | sed 's/.*/--user try-restart &.service/')" ]
  [ "$(grep -c -- '--user show -p Type -p Transient lost.service' "$SYSTEMCTL_LOG")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c 'map([.unit, .action, .pids])')" = \
    '[["batch.service","left-running",[115]],["box-bisync.service","left-running",[105]],["brew-upgrade.service","left-running",[108]],["caddy.service","restarted",[101]],["caddy.service","restarted",[110]],["flaky.service","restart-failed",[114]],["gone.service","left-running",[113]],["loopy.service","restart-failed",[116]],["lost.service","restart-failed",[117]],["lost.service","restart-failed",[118]],["qmd-serve.service","restart-failed",[102]],["session-c1.scope","left-running",[103,104]],["unknown","left-running",[112]],["unknown","left-running",[111]],["web.service","left-running",[109]]]' ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -r 'map(select(.unit == "unknown") | .exe) | sort | join(" ")')" = \
    "/opt/brew/Cellar/gone/1/bin/gone /opt/brew/Cellar/root/1/bin/root" ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 4 ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line ==
    "Warning: cannot reach the user manager to restart lost.service; it still runs the removed /opt/brew/Cellar/lost/1/bin/lost")' |
    grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info" and .line ==
    "lost.service (pid 118) still runs the removed /opt/brew/Cellar/lost/1/bin/lost-helper; restart it to load the upgrade")' |
    grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line ==
    "Warning: restarting loopy.service onto the upgrade failed; check systemctl --user status loopy.service")' | grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info" and .line ==
    "session-c1.scope (pid 103 104) still runs the removed /opt/brew/Cellar/lazygit/1/bin/lazygit; restart it to load the upgrade")' |
    grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line ==
    "Warning: restarting flaky.service onto the upgrade failed; check systemctl --user status flaky.service")' | grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line ==
    "Warning: restarting qmd-serve.service onto the upgrade failed; check systemctl --user status qmd-serve.service")' | grep -q .
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info"
    and .line == "restarted caddy.service, which was running the removed /opt/brew/Cellar/caddy/2/bin/caddy")' | grep -q .
}

@test "a run killed mid-scan exits 143 and its run.end lists every unit it reached" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  PROC="$BATS_TEST_TMPDIR/proc" US=/user.slice/user-1000.slice/user@1000.service/app.slice
  _fake_proc 201 "/opt/brew/Cellar/a/1/bin/a (deleted)" "$US/a.service"
  _fake_proc 202 "/opt/brew/Cellar/b/1/bin/b (deleted)" "$US/b.service"
  scan='. "$1/run-log.sh"; . "$1/stale-procs.sh"
    export SCAN_PID=$$
    run_log_start brew-upgrade bu test
    stale_procs_restart "$2" /opt/brew
    RUN_STATUS=0
    run_log_complete'
  run env STUB_RESTART_KILLS=b.service PATH="$STUBS:$PATH" bash -c "$scan" _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 143 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c '[.exit_code, .reason, (.stale_processes | map([.unit, .action]))]')" = \
    '[143,"script-error",[["a.service","restarted"],["b.service","restart-failed"]]]' ]
  run env STUB_SHOW_KILLS=b.service PATH="$STUBS:$PATH" bash -c "$scan" _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 143 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c '.stale_processes | map([.unit, .action])')" = \
    '[["a.service","restarted"],["b.service","left-running"]]' ]
}

@test "an interrupted run exits 130 and says so in run.end" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run bash -c '. "$1/run-log.sh"; run_log_start brew-upgrade bu test; kill -INT $$; exit 0' _ "$REPO_ROOT/scripts/upgrade/lib"
  [ "$status" -eq 130 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c '[.event, .exit_code, .reason]')" = '["run.end",130,"script-error"]' ]
}

@test "a restart waits the settle time before checking the unit stayed up, and a bad setting falls back to 3" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  PROC="$BATS_TEST_TMPDIR/proc"
  _fake_proc 201 "/opt/brew/Cellar/caddy/2/bin/caddy (deleted)" /user.slice/user-1000.slice/user@1000.service/app.slice/caddy.service
  waits="$BATS_TEST_TMPDIR/waits"
  mkdir -p "$waits"
  printf '#!/bin/sh\nprintf "sleep %%s\\n" "$*" >>"$SYSTEMCTL_LOG"\n' >"$waits/sleep"
  chmod +x "$waits/sleep"
  scan='. "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0
    stale_procs_restart "$2" /opt/brew'
  run env -u UPGRADE_RESTART_SETTLE_SECS PATH="$waits:$STUBS:$PATH" bash -c "$scan" _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(grep -E -e '^--user (try-restart|is-active|show -p InvocationID)' -e '^sleep' "$SYSTEMCTL_LOG")" = \
    "$(printf '%s\n' '--user try-restart caddy.service' '--user show -p InvocationID --value caddy.service' 'sleep 3' \
      '--user is-active --quiet caddy.service' '--user show -p InvocationID --value caddy.service')" ]
  : >"$SYSTEMCTL_LOG"
  run env UPGRADE_RESTART_SETTLE_SECS=soon PATH="$waits:$STUBS:$PATH" bash -c "$scan" _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  grep -qx 'sleep 3' "$SYSTEMCTL_LOG"
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning" and .line ==
    "Warning: UPGRADE_RESTART_SETTLE_SECS=soon is not a whole number of seconds; waiting 3 after each restart")' | grep -q .
}

@test "a scan that cannot read its parent's executable reports stale processes as unchecked" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  PROC="$BATS_TEST_TMPDIR/proc"
  _fake_proc 101 "/opt/brew/Cellar/caddy/2/bin/caddy (deleted)" /user.slice/user-1000.slice/user@1000.service/app.slice/caddy.service
  run env PATH="$STUBS:$PATH" bash -c '
    mkdir -p "$2/$PPID/exe"
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0 RUN_STALE=null
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n 1)" = null ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 1 ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning"
    and (.line | startswith("Warning: cannot read the executable of the job'"'"'s parent")))' | grep -q .
  [ ! -e "$SYSTEMCTL_LOG" ]
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

@test "the launchd wrapper appends to the job's logs and rotates one past 1 MiB" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  export UPGRADE_LOG_DIR="$BATS_TEST_TMPDIR/Logs"
  logs=$UPGRADE_LOG_DIR
  mkdir -p "$logs"
  head -c 1048577 /dev/zero | tr '\0' x >"$logs/brew-upgrade.jsonl"
  head -c 1048577 /dev/zero | tr '\0' y >"$logs/brew-upgrade.error.log"
  wrapper="$REPO_ROOT/scripts/upgrade/launchd-run.sh"
  # Only shell-functions, for bu: the other helpers would act on the real $HOME.
  mkdir -p "$BATS_TEST_TMPDIR/bu-only"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$BATS_TEST_TMPDIR/bu-only/"
  export DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only"
  run env PATH="$STUBS:$PATH" "$wrapper" brew.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -c <"$logs/brew-upgrade.jsonl.1")" -eq 1048577 ]
  [ "$(head -n 1 "$logs/brew-upgrade.jsonl" | jaq -r .event)" = run.start ]
  [ "$(tail -n 1 "$logs/brew-upgrade.jsonl" | jaq -r .reason)" = ok ]
  [ "$(wc -c <"$logs/brew-upgrade.error.log.1")" -eq 1048577 ]
  [ ! -s "$logs/brew-upgrade.error.log" ]
  run env PATH="$STUBS:$PATH" "$wrapper" brew.sh
  [ "$(jaq -r 'select(.event == "run.start") | .job' "$logs/brew-upgrade.jsonl" | wc -l)" -eq 2 ]
  [ "$(wc -c <"$logs/brew-upgrade.jsonl.1")" -eq 1048577 ]
}

@test "the launchd wrapper passes SIGTERM to the job's process group, so the job still ends its log" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  logs="$BATS_TEST_TMPDIR/Logs"
  mkdir -p "$logs" "$BATS_TEST_TMPDIR/bu-only"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$BATS_TEST_TMPDIR/bu-only/"
  log="$logs/brew-upgrade.jsonl"
  # launchd signals the job process alone; perl gives the wrapper its own process group, as launchd and a terminal do,
  # and the default SIGINT a terminal leaves it (a background job here would start with SIGINT ignored).
  # $3 is the signal and $4 its target: the job alone (launchd's TERM) or its whole group (a terminal's Ctrl-C).
  stop='perl -e "\$SIG{INT} = q(DEFAULT); setpgrp; exec @ARGV" "$1" brew.sh &
    job=$!
    for _ in $(seq 100); do grep -q "\"level\":\"warning\"" "$2" 2>/dev/null && break; sleep 0.1; done
    started=$SECONDS
    if [ "$4" = group ]; then kill "-$3" -- "-$job"; else kill "-$3" "$job"; fi
    wait "$job"
    status=$?
    elapsed=$((SECONDS - started))
    for _ in $(seq 20); do [ "$(pgrep -fx "sleep 29" | wc -l)" -eq 0 ] && break; sleep 0.1; done
    echo "elapsed=$elapsed left=$(pgrep -fx "sleep 29" | wc -l | tr -d " ")"
    exit "$status"'
  for how in "TERM job" "INT group"; do
    : >"$log"
    # shellcheck disable=SC2086 # $how is the signal and the target, two words
    run --separate-stderr env UPGRADE_LOG_DIR="$logs" DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" STUB_BREW_SLOW=29 PATH="$STUBS:$PATH" \
      bash -c "$stop" _ "$REPO_ROOT/scripts/upgrade/launchd-run.sh" "$log" $how
    [ "$status" -eq 143 ]
    elapsed=${output#elapsed=}
    [ "${elapsed%% *}" -lt 10 ]
    [ "${output##*left=}" -eq 0 ]
    [ "$(tail -n 1 "$log" | jaq -c '[.event, .exit_code, .reason, .warnings]')" = '["run.end",143,"script-error",1]' ]
  done
}

@test "a launchd wrapper outside its own process group still stops the job promptly and nothing else" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  logs="$BATS_TEST_TMPDIR/Logs"
  mkdir -p "$logs" "$BATS_TEST_TMPDIR/bu-only"
  ln -s "$REPO_ROOT/config/shell/shell-functions" "$BATS_TEST_TMPDIR/bu-only/"
  log="$logs/brew-upgrade.jsonl"
  # The wrapper shares this shell's process group, so a group-wide TERM would reach the bystander too.
  run --separate-stderr env UPGRADE_LOG_DIR="$logs" DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" STUB_BREW_SLOW=29 PATH="$STUBS:$PATH" bash -c '
    perl -e "sleep 90" &
    bystander=$!
    "$1" brew.sh &
    job=$!
    for _ in $(seq 100); do grep -q "\"level\":\"warning\"" "$2" 2>/dev/null && break; sleep 0.1; done
    started=$SECONDS
    kill -TERM "$job"
    wait "$job"
    status=$?
    alive=no
    kill -0 "$bystander" 2>/dev/null && alive=yes
    kill "$bystander"
    echo "bystander=$alive elapsed=$((SECONDS - started))"
    exit "$status"' _ "$REPO_ROOT/scripts/upgrade/launchd-run.sh" "$log"
  [ "$status" -eq 143 ]
  [ "${output%% *}" = bystander=yes ]
  [ "${output##*elapsed=}" -lt 10 ]
  [ "$(tail -n 1 "$log" | jaq -c '[.event, .exit_code]')" = '["run.end",143]' ]
}

_wrapper_env() {
  logs="$BATS_TEST_TMPDIR/Logs"
  log="$logs/brew-upgrade.jsonl"
  mkdir -p "$logs" "$BATS_TEST_TMPDIR/bu-only"
  ln -sf "$REPO_ROOT/config/shell/shell-functions" "$BATS_TEST_TMPDIR/bu-only/"
}

@test "without perl the launchd wrapper still runs the job and notes the reduced stop handling" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  _wrapper_env
  run env UPGRADE_LOG_DIR="$logs" UPGRADE_PERL=/nonexistent/perl DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" \
    PATH="$STUBS:$PATH" "$REPO_ROOT/scripts/upgrade/launchd-run.sh" brew.sh
  [ "$status" -eq 0 ]
  grep -q '^launchd-run: perl not found' "$logs/brew-upgrade.error.log"
  [ "$(tail -n 1 "$log" | jaq -c '[.event, .reason]')" = '["run.end","ok"]' ]
}

@test "run by hand from a terminal, the launchd wrapper keeps the job in the foreground" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  script -qec true /dev/null >/dev/null 2>&1 || skip "needs util-linux script for a pseudo-terminal"
  command -v timeout >/dev/null 2>&1 || skip "timeout not available"
  _wrapper_env
  # The update touches the terminal, as a sudo password prompt does; a background process group would be stopped.
  run timeout 20 script -qec "env UPGRADE_LOG_DIR='$logs' DOTFILES_SHELL_DIR='$BATS_TEST_TMPDIR/bu-only' STUB_BREW_TTY=1 \
    PATH='$STUBS:$PATH' '$REPO_ROOT/scripts/upgrade/launchd-run.sh' brew.sh" /dev/null
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$log" | jaq -c '[.event, .reason]')" = '["run.end","ok"]' ]
}

@test "a stop before the job has its own process group still ends the run" {
  _wrapper_env
  # perl that takes its time to start, so the stop lands before setpgrp.
  printf '#!/bin/sh\nsleep 5\nexec perl "$@"\n' >"$BATS_TEST_TMPDIR/slow-perl"
  chmod +x "$BATS_TEST_TMPDIR/slow-perl"
  run --separate-stderr env UPGRADE_LOG_DIR="$logs" UPGRADE_PERL="$BATS_TEST_TMPDIR/slow-perl" PATH="$STUBS:$PATH" bash -c '
    perl -e "\$SIG{INT} = q(DEFAULT); setpgrp; exec @ARGV" "$1" brew.sh &
    job=$!
    sleep 1
    started=$SECONDS
    kill -TERM "$job"
    wait "$job"
    status=$?
    echo "elapsed=$((SECONDS - started))"
    exit "$status"' _ "$REPO_ROOT/scripts/upgrade/launchd-run.sh"
  [ "$status" -eq 143 ]
  [ "${output#elapsed=}" -lt 4 ]
  [ ! -s "$log" ]
}

@test "the launchd wrapper runs a job whose path has a space" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  _wrapper_env
  dir="$BATS_TEST_TMPDIR/with space/upgrade"
  mkdir -p "$dir"
  cp -R "$REPO_ROOT/scripts/upgrade/." "$dir/"
  run env UPGRADE_LOG_DIR="$logs" DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" PATH="$STUBS:$PATH" \
    "$dir/launchd-run.sh" brew.sh
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$log" | jaq -c '[.event, .reason]')" = '["run.end","ok"]' ]
}

# Runs the wrapper in its own process group, stops it, and sets stop_status, elapsed and left (tools still running).
_stop_wrapper() { # <env-assignment>...
  stop_status=0
  stop_report=$(env "$@" bash -c '
    perl -e "\$SIG{INT} = q(DEFAULT); setpgrp; exec @ARGV" "$1" brew.sh &
    job=$!
    for _ in $(seq 100); do grep -q "\"level\":\"warning\"" "$2" 2>/dev/null && break; sleep 0.1; done
    started=$SECONDS
    kill -TERM "$job"
    wait "$job"
    status=$?
    elapsed=$((SECONDS - started))
    for _ in $(seq 20); do [ "$(pgrep -fx "sleep 29" | wc -l)" -eq 0 ] && break; sleep 0.1; done
    echo "elapsed=$elapsed left=$(pgrep -fx "sleep 29" | wc -l | tr -d " ")"
    exit "$status"' _ "$REPO_ROOT/scripts/upgrade/launchd-run.sh" "$log" 2>/dev/null) || stop_status=$?
  elapsed=${stop_report#elapsed=}
  elapsed=${elapsed%% *}
  left=${stop_report##*left=}
}

@test "a stop leaves no tool behind in the job's process group, even one that ignores SIGTERM" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  _wrapper_env
  # The whole stop, including the wrapper letting go of its output, ends within seconds: no helper outlives it.
  t0=$SECONDS
  _stop_wrapper UPGRADE_LOG_DIR="$logs" DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" STUB_BREW_SLOW=29 \
    STUB_BREW_IGNORE_TERM=1 PATH="$STUBS:$PATH"
  [ $((SECONDS - t0)) -lt 6 ]
  [ "$stop_status" -eq 143 ]
  [ "$elapsed" -lt 5 ]
  [ "$left" -eq 0 ]
  [ "$(tail -n 1 "$log" | jaq -c '[.event, .exit_code]')" = '["run.end",143]' ]
}

@test "a job that ignores SIGTERM itself is killed 10 seconds after a stop" {
  _wrapper_env
  # A perl that starts the job with SIGTERM ignored, so neither the job nor its tools can be stopped by it.
  printf '#!/bin/sh\nexec perl -e '"'"'$SIG{TERM} = "IGNORE"; exec { "perl" } "perl", @ARGV'"'"' -- "$@"\n' \
    >"$BATS_TEST_TMPDIR/deaf-perl"
  chmod +x "$BATS_TEST_TMPDIR/deaf-perl"
  _stop_wrapper UPGRADE_LOG_DIR="$logs" UPGRADE_PERL="$BATS_TEST_TMPDIR/deaf-perl" \
    DOTFILES_SHELL_DIR="$BATS_TEST_TMPDIR/bu-only" STUB_BREW_SLOW=29 PATH="$STUBS:$PATH"
  [ "$stop_status" -eq 137 ]
  [ "$elapsed" -ge 9 ]
  [ "$elapsed" -lt 15 ]
  [ "$left" -eq 0 ]
}

@test "a failed InvocationID lookup after a restart does not abort the scan" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  PROC="$BATS_TEST_TMPDIR/proc" US=/user.slice/user-1000.slice/user@1000.service/app.slice
  _fake_proc 201 "/opt/brew/Cellar/a/1/bin/a (deleted)" "$US/a.service"
  _fake_proc 202 "/opt/brew/Cellar/b/1/bin/b (deleted)" "$US/b.service"
  run env STUB_INVOCATION_FAIL=a.service PATH="$STUBS:$PATH" bash -c '
    set -euo pipefail
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0
    stale_procs_restart "$2" /opt/brew
    printf "%s\n" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c 'map([.unit, .action])')" = '[["a.service","restarted"],["b.service","restarted"]]' ]
}

_agent_runs_daily_at() {
  local plist="$AGENTS/com.user.$1-upgrade.plist"
  grep -qF "exec \"\$HOME/dotfiles/scripts/upgrade/launchd-run.sh\" $1.sh</string>" "$plist"
  grep -A1 '<key>Hour</key>' "$plist" | grep -qF "<integer>$2</integer>"
  grep -A1 '<key>Minute</key>' "$plist" | grep -qF "<integer>$3</integer>"
}

@test "systemd and launchd run the upgrade scripts, brew daily at 04:00 and uv at 04:30" {
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
  _agent_runs_daily_at brew 4 0
  _agent_runs_daily_at uv-tools 4 30
}
