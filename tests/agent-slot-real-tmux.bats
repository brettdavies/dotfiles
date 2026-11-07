#!/usr/bin/env bats
# What a stub cannot vouch for: how real tmux prints the reads the prime code parses. tmux prints a tab in a -F format as
# `_` to a client it does not take for UTF-8: one started outside tmux with no UTF-8 locale. These run as such a client,
# which any caller without a locale is, such as a macOS LaunchAgent.
#
# Each test's tmux servers live under its own socket directory. The wrapper maps the `default` socket to a scratch one, so
# nothing here reads or starts anything on a live server, and it swallows send-keys, so a pane never starts a real Claude.
#
# Run: bats tests/agent-slot-real-tmux.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
}

setup() {
  agent_slot_setup
  REAL_TMUX=$(command -v tmux)
  export AGENT_SLOT_TMUX_SOCKET=scratch-slots
  cat >"$T/tmux" <<EOF
#!/usr/bin/env bash
export TMUX_TMPDIR='$T/sockets'
case " \$* " in
  *" send-keys "*) printf '%s\n' "\$*" >>'$T/typed'; exit 0 ;;
esac
args=()
for arg in "\$@"; do
  [ "\$arg" != default ] || arg=scratch-default
  args+=("\$arg")
done
exec '$REAL_TMUX' "\${args[@]}"
EOF
  chmod +x "$T/tmux"
  mkdir -p "$T/sockets"
  export AGENT_SLOT_TMUX=$T/tmux
  cp "$(command -v perl)" "$T/claude"
  prime repoa
  printf 'repoa\tRepo A\n' >"$AGENT_SLOT_PRIMES"
}

teardown() {
  TMUX_TMPDIR=$T/sockets "$REAL_TMUX" -L scratch-default kill-server 2>/dev/null || true
  TMUX_TMPDIR=$T/sockets "$REAL_TMUX" -L scratch-slots kill-server 2>/dev/null || true
  stop_spawned
  assert_no_leaks
}

# no_locale COMMAND...: runs the command with no locale set and outside tmux, since tmux takes a client started inside tmux
# for UTF-8 whatever the locale says.
no_locale() {
  env -u LANG -u LC_ALL -u LC_CTYPE -u TMUX "$@"
}

# holding_claude SOCKET SESSION [DIR]: a session on the scratch socket whose pane's program is named claude, once tmux says
# so.
holding_claude() {
  "$T/tmux" -L "$1" -f /dev/null new-session -d -s "$2" -c "${3:-$T}" "$T/claude" -e 'sleep 30'
  for _ in {1..100}; do
    [[ $("$T/tmux" -u -L "$1" list-panes -a -F '#{pane_current_command}') == *claude* ]] && return 0
    sleep 0.1
  done
  echo "the pane of $2 never ran claude" >&2
  return 1
}

@test "a tab prints as a tab only to a client that says UTF-8, which is why the reads pass -u" {
  holding_claude scratch-default 'Repo A'
  run no_locale "$T/tmux" -L scratch-default list-panes -a -F $'#{session_name}\t#{pane_current_command}'
  [ "$output" = 'Repo A_claude' ]
  run no_locale "$T/tmux" -u -L scratch-default list-panes -a -F $'#{session_name}\t#{pane_current_command}'
  [ "$output" = $'Repo A\tclaude' ]
}

@test "with no locale, agent-slot prime finds the old-style session and starts nothing" {
  holding_claude scratch-default 'Repo A'
  run --separate-stderr no_locale "$AGENT_SLOT" prime repoa --output json
  [ "$status" -eq 0 ]
  jaq -e '.server == "default" and .session == "Repo A" and .started == []' <<<"$output"
  [ ! -e "$T/typed" ]
}

@test "with no locale, list reports the prime on the slot server and the old-style one" {
  prime repob
  printf 'repob\tRepo B\n' >>"$AGENT_SLOT_PRIMES"
  holding_claude scratch-default 'Repo B'
  holding_claude scratch-slots repoa-prime "$AGENT_SLOT_DEV/repoa"
  run --separate-stderr no_locale "$AGENT_SLOT" list --output json
  [ "$status" -eq 0 ]
  jaq -e '(.primes | sort_by(.repo)) == [
    {key: "repoa/prime", repo: "repoa", server: "slots", session: "repoa-prime", label: "Repo A"},
    {key: "repob/prime", repo: "repob", server: "default", session: "Repo B", label: "Repo B"}]' <<<"$output"
}

@test "with no locale, the helper's prime command finds the old-style session" {
  holding_claude scratch-default 'Repo A'
  stub login-shell 'exit 0'
  stub self 'exit 0'
  run no_locale AGENT_SLOT_REX_TMUX="$T/tmux" AGENT_SLOT_REX_PRIMES="$AGENT_SLOT_PRIMES" \
    AGENT_SLOT_REX_LOGIN_SHELL="$STUBS/login-shell" AGENT_SLOT_REX_SELF="$STUBS/self" \
    AGENT_SLOT_REX_STATE_DIR="$T/rex-state" "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/agent-slot-rex" prime repoa
  grep -q '^login-shell -l$' "$CALLS"
  run ! grep -q '^self ' "$CALLS"
}
