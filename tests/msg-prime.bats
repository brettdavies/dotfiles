#!/usr/bin/env bats
# Tests for stow/local/dot-local/bin/msg-prime, which tells a Mac session
# whether a repo's prime on the Linux server can take a message and has a
# headless Claude there deliver it.
#
# Run: bats tests/msg-prime.bats
#
# `ssh`, `timeout`, and `tmux` are stubs in a PATH-prepended directory, so
# nothing reaches a server and no real session is read or messaged. The `ssh`
# stub refuses any host but AGENT_SLOT_REX_SERVER, runs the state probe's
# remote command in a real `zsh -fc` against the stub `tmux`, and answers the
# send call from the knobs below, recording the prompt it received on stdin.
# Knobs:
#   PANE_FILE   the pane `tmux capture-pane` prints; unset means no session
#   SEND_REPLY  what the headless Claude prints on stdout
#   SEND_ERR    what the send call prints on stderr, as ssh does when it fails
#   SEND_EXIT   exit status of the send call
# run-tests: parallel

SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/msg-prime"

bats_require_minimum_version 1.5.0

setup_file() {
  STUBS="$BATS_FILE_TMPDIR/stubs"
  PANES="$BATS_FILE_TMPDIR/panes"
  mkdir -p "$STUBS" "$PANES"

  cat >"$STUBS/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

  cat >"$STUBS/ssh" <<'EOF'
#!/usr/bin/env bash
host=$3 remote=$4
printf '%s\n' "$host" >>"$SSH_HOSTS"
[[ $host == "$AGENT_SLOT_REX_SERVER" ]] || { echo "ssh stub: unexpected host $host" >&2; exit 97; }
[[ $remote != *has-session* ]] || exec zsh -fc "$remote"
cat >"$PROMPT"
[[ -z ${SEND_ERR:-} ]] || printf '%s\n' "$SEND_ERR" >&2
printf '%s' "${SEND_REPLY:-}"
exit "${SEND_EXIT:-0}"
EOF

  cat >"$STUBS/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMUX_CALLS"
case $3 in
  has-session) [[ -n ${PANE_FILE:-} ]] ;;
  capture-pane) cat "$PANE_FILE" ;;
esac
EOF
  chmod 555 "$STUBS"/*

  printf '%s\n' \
    '● Done. The suite is green.' \
    '' \
    '╭──────────────────────────────╮' \
    '│ >                            │' \
    '╰──────────────────────────────╯' \
    '  ? for shortcuts' >"$PANES/idle"

  printf '%s\n' \
    '● Reading the config.' \
    '' \
    '✢ Transfiguring… (1m 2s · ↓ 2.0k tokens)' \
    '' \
    '╭──────────────────────────────╮' \
    '│ >                            │' \
    '╰──────────────────────────────╯' \
    '  esc to interrupt' >"$PANES/working"

  printf '%s\n' \
    '✢ Transfiguring… (1m 2s · ↓ 2.0k tokens)' \
    '' \
    ' Do you want to proceed?' \
    ' ❯ 1. Yes' \
    '   2. No' \
    '' \
    ' Esc to cancel' >"$PANES/question"
}

setup() {
  export AGENT_SLOT_REX_SERVER="linux-server.invalid"
  export SSH_HOSTS="$BATS_TEST_TMPDIR/ssh-hosts.log"
  export TMUX_CALLS="$BATS_TEST_TMPDIR/tmux-calls.log"
  export PROMPT="$BATS_TEST_TMPDIR/prompt.txt"
  export SEND_REPLY=SENT
  : >"$SSH_HOSTS"
  : >"$TMUX_CALLS"
  PATH="$BATS_FILE_TMPDIR/stubs:$PATH"
}

@test "a call without exactly two arguments prints the usage and exits 2" {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ $stderr == "usage: msg-prime <repo> <message>"* ]]

  run --separate-stderr "$SCRIPT" widgets
  [ "$status" -eq 2 ]

  run --separate-stderr "$SCRIPT" widgets hello extra
  [ "$status" -eq 2 ]
  [ ! -s "$SSH_HOSTS" ]
}

@test "an empty or blank message exits 2 without reaching the server" {
  run --separate-stderr "$SCRIPT" widgets ""
  [ "$status" -eq 2 ]
  [[ $stderr == "msg-prime: the message is empty."* ]]

  run --separate-stderr "$SCRIPT" widgets $' \t\n '
  [ "$status" -eq 2 ]

  run --separate-stderr "$SCRIPT" widgets - <<<"   "
  [ "$status" -eq 2 ]
  [ ! -s "$SSH_HOSTS" ]
}

@test "a repo name outside letters, digits, dot, underscore and hyphen exits 2 without reaching the server" {
  for repo in "two words" "a;b" "a'b" '$(id)' 'a/b' ""; do
    run --separate-stderr "$SCRIPT" "$repo" hello
    [ "$status" -eq 2 ]
    [[ $stderr == "msg-prime: '$repo' is not a repo name. List them with: ssh $AGENT_SLOT_REX_SERVER 'agent-slot repos'" ]]
  done
  [ ! -s "$SSH_HOSTS" ]
}

@test "a repo with no prime session exits 3, names the command that starts it, and sends nothing" {
  run --separate-stderr "$SCRIPT" widgets hello
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$stderr" = "msg-prime: no widgets-prime session on the Linux server. Start it with: ssh $AGENT_SLOT_REX_SERVER 'agent-slot prime widgets'" ]
  grep -q -- '-t =widgets-prime' "$TMUX_CALLS"
  [ ! -e "$PROMPT" ]
}

@test "an idle prime is reported idle and gets the message" {
  PANE_FILE="$BATS_FILE_TMPDIR/panes/idle" run "$SCRIPT" widgets hello
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "widgets-prime is idle: it takes the message now." ]
  [ "${lines[1]}" = "Sent to widgets-prime." ]
  grep -q -- '-t =widgets-prime:' "$TMUX_CALLS"
  [ -e "$PROMPT" ]
}

@test "a prime mid-turn is reported working and still gets the message" {
  PANE_FILE="$BATS_FILE_TMPDIR/panes/working" run "$SCRIPT" widgets hello
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "widgets-prime is busy: it is mid-turn. The message will wait in its inbox until the turn ends." ]
  [ "${lines[1]}" = "Sent to widgets-prime." ]
  [ -e "$PROMPT" ]
}

@test "a prime holding a question is reported as such, even mid-turn, and still gets the message" {
  PANE_FILE="$BATS_FILE_TMPDIR/panes/question" run "$SCRIPT" widgets hello
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "widgets-prime is busy: it has a question or permission prompt open. The message will wait in its inbox until it can take it." ]
  [ "${lines[1]}" = "Sent to widgets-prime." ]
  [ -e "$PROMPT" ]
}

@test "a SENT reply reports the send, and the message reaches the headless Claude verbatim" {
  msg=$'line one with "quotes" and $HOME and `ticks`\n\nline three'
  PANE_FILE="$BATS_FILE_TMPDIR/panes/idle" run "$SCRIPT" widgets - <<<"$msg"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "Sent to widgets-prime." ]
  [[ $(<"$PROMPT") == *"session named exactly widgets-prime."* ]]
  [[ $(<"$PROMPT") == *"-----BEGIN MESSAGE-----"$'\n'"$msg"$'\n'"-----END MESSAGE-----" ]]
}

@test "a reply that is not SENT exits 1 and shows the reply" {
  PANE_FILE="$BATS_FILE_TMPDIR/panes/idle" SEND_REPLY="FAILED: no session named widgets-prime" run --separate-stderr "$SCRIPT" widgets hello
  [ "$status" -eq 1 ]
  [ "$stderr" = "msg-prime: the send to widgets-prime failed: FAILED: no session named widgets-prime" ]
}

@test "a send call that dies with an ssh error exits 1 and shows the error" {
  PANE_FILE="$BATS_FILE_TMPDIR/panes/idle" SEND_REPLY="" SEND_ERR="ssh: connect to host linux-server.invalid port 22: Connection refused" SEND_EXIT=255 run --separate-stderr "$SCRIPT" widgets hello
  [ "$status" -eq 1 ]
  [ "$stderr" = "msg-prime: the send to widgets-prime failed: ssh: connect to host linux-server.invalid port 22: Connection refused" ]
}
