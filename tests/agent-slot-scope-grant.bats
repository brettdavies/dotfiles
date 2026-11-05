#!/usr/bin/env bats
# agent-slot grant-scope: the operator's grant of one more path a slot's PR may change, typed at a terminal. The hook
# that honours a grant is tested in tests/slot-scope-guard.bats.
#
# Run: bats tests/agent-slot-scope-grant.bats
#
# A person's terminal is a pseudo-terminal that tests/lib/with-tty.py types the confirmation into. Every other run is
# started with setsid, which leaves it no controlling terminal, as an agent's Bash tool has none.

# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot

WITH_TTY="$BATS_TEST_DIRNAME/lib/with-tty.py"

setup_file() {
  load lib/platform
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  agent_slot_setup
  SLOT=$AGENT_SLOT_ROOT/repo/1
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
  slot repo 1
  git -C "$SLOT" commit -q --allow-empty -m seed
  git -C "$SLOT" update-ref refs/remotes/origin/main HEAD
  git -C "$SLOT" checkout -q -b feat/one
  mkdir -p "$SLOT/docs"
  printf 'a\n' >"$SLOT/docs/a.md"
  printf 'b\n' >"$SLOT/docs/b.md"
  printf 'r\n' >"$SLOT/README.md"
  git -C "$SLOT" add docs README.md
  git -C "$SLOT" commit -q -m change
}

# at_terminal LINE ARG...: agent-slot ARG... --output json from the operator's shell, outside any slot and slot tmux,
# with a terminal that holds LINE as the typed answer. Sets status, output, stderr, and tty, what the verb wrote to the
# terminal.
at_terminal() {
  local line=$1
  shift
  tty=$(python3 -I "$WITH_TTY" "$line" env -u TMUX -u TMUX_PANE bash -c \
    'cd "$1" && shift && exec "$@" --output json >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"' _ "$T" \
    "$AGENT_SLOT" "$@") && status=0 || status=$?
  output=$(cat "$T/out")
  stderr=$(cat "$T/err")
}

# without_terminal ARG...: the same, from a session that has no terminal.
without_terminal() {
  run --separate-stderr env -u TMUX -u TMUX_PANE setsid -w bash -c 'cd "$1" && shift && exec "$@" --output json' _ "$T" \
    "$AGENT_SLOT" "$@"
}

grant_lines() { jaq -c 'select(.event == "scope-grant")' "$LEDGER" 2>/dev/null || true; }

@test "typing the slot's key at a terminal appends one scope-grant line for the slot" {
  at_terminal repo/1 grant-scope repo/1 'docs/*.md'
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.ok == true and .verb == "grant-scope" and .key == "repo/1" and .pathspec == "docs/*.md" and .grants == 1' \
    <<<"$output"
  [ "$(grant_lines | wc -l)" -eq 1 ]
  jaq -e '.repo == "repo" and .slot == 1 and .pathspec == "docs/*.md"' <<<"$(grant_lines)"
}

@test "the prompt lists the changed paths the pathspec covers and counts the ones it leaves out" {
  at_terminal repo/1 grant-scope repo/1 'docs/*.md'
  [[ $tty == *"docs/a.md"* && $tty == *"docs/b.md"* ]]
  [[ $tty != *"README.md"* ]]
  [[ $tty == *"1 other changed path stays outside it"* ]]
  [[ $tty == *"Type the slot key, repo/1, to grant it:"* ]]
}

@test "a pathspec that covers none of the paths the branch changed is refused before the terminal is asked" {
  without_terminal grant-scope repo/1 'dcos/*.md'
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "dcos/*.md" and (.message | contains("covers none of the 3 paths"))' <<<"$stderr"
  [ ! -e "$LEDGER" ]
}

@test "an exclude pathspec is refused, since it takes coverage away" {
  local spec
  for spec in ':!docs/a.md' ':^docs/a.md' ':(exclude)docs/a.md'; do
    without_terminal grant-scope repo/1 "$spec"
    [ "$status" -eq 2 ] || {
      echo "accepted: $spec"
      false
    }
    jaq -e '.reason == "usage" and (.message | contains("exclude"))' <<<"$stderr"
  done
}

@test "git's own reason for rejecting a pathspec is in the message" {
  without_terminal grant-scope repo/1 ':(nonsense)x'
  jaq -e '.message | contains("nonsense")' <<<"$stderr"
}

@test "an end of input at the terminal is reported as no answer, not as a wrong one" {
  at_terminal $'\x04' grant-scope repo/1 'docs/*'
  [ "$status" -eq 1 ]
  jaq -e '.reason == "grant-not-confirmed" and (.message | contains("no answer was typed within 120 s"))' <<<"$stderr"
  [ ! -e "$LEDGER" ]
}

@test "the refusals tell the operator where to run the verb" {
  without_terminal grant-scope repo/1 'docs/*'
  jaq -e '.message | contains("from a terminal window on this host, outside any Claude session")' <<<"$stderr"
  python3 -I "$WITH_TTY" repo/1 bash -c 'cd "$1" && shift && exec "$@" --output json >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"' \
    _ "$SLOT" "$AGENT_SLOT" grant-scope repo/1 'docs/*' >/dev/null || true
  jaq -e '.message | contains("from a shell outside the slot directory and off the slot tmux server")' <"$T/err"
}

@test "each grant is its own line, counted for its own slot" {
  slot repo 2
  at_terminal repo/1 grant-scope repo/1 docs/a.md
  at_terminal repo/1 grant-scope repo/1 docs/b.md
  jaq -e '.grants == 2' <<<"$output"
  at_terminal repo/2 grant-scope repo/2 'c/*'
  jaq -e '.key == "repo/2" and .grants == 1' <<<"$output"
  [ "$(grant_lines | wc -l)" -eq 3 ]
}

@test "any answer but the slot's key is refused and grants nothing" {
  local answer
  for answer in yes y '' repo/2 "repo/1 "; do
    at_terminal "$answer" grant-scope repo/1 'docs/*'
    [ "$status" -eq 1 ]
    jaq -e '.reason == "grant-not-confirmed" and .next_step.action == "rerun"' <<<"$stderr"
  done
  [ ! -e "$LEDGER" ]
}

@test "with no terminal the grant is refused with grant-needs-terminal, so neither a slot nor a coordinating session grants" {
  without_terminal grant-scope repo/1 'docs/*'
  [ "$status" -eq 1 ]
  jaq -e '.reason == "grant-needs-terminal" and .next_step.action == "ask-operator"
    and (.next_step.command | startswith("agent-slot grant-scope repo/1"))' <<<"$stderr"
  [ ! -e "$LEDGER" ]
}

@test "run from inside the slot it is refused even at a terminal, since only the operator grants" {
  python3 -I "$WITH_TTY" repo/1 bash -c 'cd "$1" && shift && exec "$@" --output json >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"' \
    _ "$SLOT" "$AGENT_SLOT" grant-scope repo/1 'docs/*' && status=0 || status=$?
  [ "$status" -eq 1 ]
  jaq -e '.reason == "scope-grant-from-slot" and .next_step.action == "ask-operator"' <"$T/err"
  [ ! -e "$LEDGER" ]
}

@test "run from the slot's tmux server it is refused even at a terminal" {
  python3 -I "$WITH_TTY" repo/1 env "TMUX=$T/$AGENT_SLOT_TMUX_SOCKET,4242,0" bash -c \
    'cd "$1" && shift && exec "$@" --output json >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"' _ "$T" "$AGENT_SLOT" \
    grant-scope repo/1 'docs/*' && status=0 || status=$?
  [ "$status" -eq 1 ]
  jaq -e '.reason == "scope-grant-from-slot" and (.value | endswith("'"$AGENT_SLOT_TMUX_SOCKET"'"))' <"$T/err"
  [ ! -e "$LEDGER" ]
}

@test "a slot that does not exist is refused with slot-not-found" {
  at_terminal repo/9 grant-scope repo/9 'docs/*'
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-not-found" and .value == "repo/9"' <<<"$stderr"
}

@test "a pathspec git rejects, or an empty one, is refused before the terminal is asked" {
  without_terminal grant-scope repo/1 ':(nonsense)x'
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == ":(nonsense)x"' <<<"$stderr"
  without_terminal grant-scope repo/1 ''
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
}

@test "grant-scope needs a slot named <repo>/<N> and one pathspec" {
  without_terminal grant-scope
  [ "$status" -eq 2 ]
  without_terminal grant-scope repo/1
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
  without_terminal grant-scope repo/1 a b
  [ "$status" -eq 2 ]
}

@test "grant-scope has help with its returns line and an example" {
  run "$AGENT_SLOT" grant-scope --help
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "usage: agent-slot grant-scope <repo>/<N> <pathspec>"* ]]
  [[ $output == *"grant-needs-terminal"* ]]
  [[ $output == *$'\nreturns: '* ]]
  [[ $output == *"example: agent-slot grant-scope"* ]]
}
