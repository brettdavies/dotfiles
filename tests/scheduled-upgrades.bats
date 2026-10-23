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
  export STUB_BREW_PREFIX="$BATS_TEST_TMPDIR/prefix"
  cat >"$STUBS/uv" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo "uv 0.11.20" ;;
  "tool list")
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
      echo "uv 0.11.20"
    else
      [ -n "${STUB_BREW_LIST_FAIL-}" ] && { echo "Error: list failed" >&2; exit 1; }
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
  # Never reaches the live user manager: Type is oneshot for box-bisync and simple otherwise, and a restart of the
  # unit named in STUB_RESTART_FAIL fails.
  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
  "--user show -p Type --value box-bisync.service") echo oneshot ;;
  "--user show -p Type --value "*) echo simple ;;
  "--user try-restart ${STUB_RESTART_FAIL-}") exit 1 ;;
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
  run env -u DOTFILES_SHELL_DIR STUB_BREW_LIST_FAIL=1 PATH="$STUBS:$PATH" bash "$BREW_JOB"
  [ "$status" -eq 0 ]
  _assert_run_log brew-upgrade
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "warning"
    and (.line | startswith("Warning: listing installed versions failed before the upgrade")))' | grep -q .
  [ "$(printf '%s' "$END" | jaq -c '[.outcome, .reason, .warnings, .changes]')" = '["success","ok",2,null]' ]
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
  run env STUB_RESTART_FAIL=qmd-serve.service PATH="$STUBS:$PATH" bash -c '
    . "$1/run-log.sh"; . "$1/stale-procs.sh"
    RUN_JOB=brew-upgrade RUN_ID=x RUN_HOST="\"h\"" RUN_LOG_JOURNALD=0 RUN_WARNINGS=0
    stale_procs_restart "$2" /opt/brew
    printf "%s\n%s\n" "$RUN_WARNINGS" "$RUN_STALE"' _ "$REPO_ROOT/scripts/upgrade/lib" "$PROC"
  [ "$status" -eq 0 ]
  [ "$(grep try-restart "$SYSTEMCTL_LOG" | sort)" = "$(printf '%s\n' '--user try-restart caddy.service' '--user try-restart qmd-serve.service')" ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jaq -c 'map([.unit, .action, .pids])')" = \
    '[["box-bisync.service","left-running",[105]],["brew-upgrade.service","left-running",[108]],["caddy.service","restarted",[101]],["qmd-serve.service","restart-failed",[102]],["session-c1.scope","left-running",[103,104]],["web.service","left-running",[109]]]' ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 5 ]
  printf '%s\n' "$output" | jaq -c 'select(.event == "output" and .level == "info"
    and .line == "restarted caddy.service, which was running the removed /opt/brew/Cellar/caddy/2/bin/caddy")' | grep -q .
}

@test "brew job reports a process still running a binary the upgrade removed" {
  [ -d /proc/self/fd ] || skip "the scan reads /proc"
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  bin="$STUB_BREW_PREFIX/Cellar/napper/1/bin/napper"
  mkdir -p "${bin%/*}"
  cp "$(command -v sleep)" "$bin"
  "$bin" 30 &
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
  echo kept >"$logs/brew-upgrade.error.log"
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
  [ "$(cat "$logs/brew-upgrade.error.log")" = kept ]
  [ ! -e "$logs/brew-upgrade.error.log.1" ]
  run env PATH="$STUBS:$PATH" "$wrapper" brew.sh
  [ "$(jaq -r 'select(.event == "run.start") | .job' "$logs/brew-upgrade.jsonl" | wc -l)" -eq 2 ]
  [ "$(wc -c <"$logs/brew-upgrade.jsonl.1")" -eq 1048577 ]
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
  grep -qx 'After=network-online.target brew-upgrade.service' "$UNITS/uv-tools-upgrade.service"
  grep -qx 'OnCalendar=\*-\*-\* 04:00:00' "$UNITS/brew-upgrade.timer"
  grep -qx 'OnCalendar=\*-\*-\* 04:30:00' "$UNITS/uv-tools-upgrade.timer"
  _agent_runs_daily_at brew 4 0
  _agent_runs_daily_at uv-tools 4 30
}
