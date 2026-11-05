#!/usr/bin/env bats
# agent-slot grant-review: the operator's grant of one more review round for the PR on a slot's current branch. The
# hook that counts rounds is tested in tests/slot-review-cap.bats.
#
# Run: bats tests/agent-slot-review-grant.bats

# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot

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
  git -C "$SLOT" symbolic-ref HEAD refs/heads/feat/one
}

# operator ARG...: agent-slot ARG... --output json from the operator's shell, outside any slot and slot tmux.
operator() {
  run --separate-stderr env -u TMUX -u TMUX_PANE bash -c 'cd "$1" && shift && exec "$@" --output json' _ "$T" \
    "$AGENT_SLOT" "$@"
}

@test "grant-review appends one review-grant line for the slot's current branch" {
  operator grant-review repo/1
  [ "$status" -eq 0 ]
  jaq -e '.ok == true and .verb == "grant-review" and .key == "repo/1" and .branch == "feat/one"' <<<"$output"
  [ "$(jaq -s -c 'map(select(.event == "review-grant")) | length' "$LEDGER")" -eq 1 ]
  jaq -e 'select(.event == "review-grant") | .repo == "repo" and .slot == 1 and .branch == "feat/one"' "$LEDGER"
}

@test "each grant adds a round: two grants are two lines" {
  operator grant-review repo/1
  operator grant-review repo/1
  [ "$(jaq -s -c 'map(select(.event == "review-grant")) | length' "$LEDGER")" -eq 2 ]
}

@test "grant-review run from inside the slot is refused, since only the operator grants" {
  run --separate-stderr bash -c 'cd "$1" && shift && exec "$@" --output json' _ "$SLOT" "$AGENT_SLOT" grant-review repo/1
  [ "$status" -eq 1 ]
  jaq -e '.reason == "review-grant-from-slot" and .next_step.action == "ask-operator"' <<<"$stderr"
  [ ! -e "$LEDGER" ]
}

@test "grant-review run from the slot's tmux server is refused" {
  TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0" run --separate-stderr bash -c 'cd "$1" && shift && exec "$@" --output json' _ \
    "$T" "$AGENT_SLOT" grant-review repo/1
  [ "$status" -eq 1 ]
  jaq -e '.reason == "review-grant-from-slot" and (.value | endswith("'"$AGENT_SLOT_TMUX_SOCKET"'"))' <<<"$stderr"
  [ ! -e "$LEDGER" ]
}

@test "grant-review of a slot with no commit and no branch is refused with slot-head-missing" {
  trash "$SLOT/.git"
  printf '{}\n' >"$AGENT_SLOT_ROOT/repo/.1.claim.json"
  operator grant-review repo/1
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-head-missing"' <<<"$stderr"
}

@test "grant-review of a slot that does not exist is refused with slot-not-found" {
  operator grant-review repo/9
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-not-found" and .value == "repo/9"' <<<"$stderr"
}

@test "grant-review needs one slot named <repo>/<N>" {
  operator grant-review
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
  operator grant-review repo
  [ "$status" -eq 2 ]
}

@test "grant-review has help with its returns line and an example" {
  run "$AGENT_SLOT" grant-review --help
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "usage: agent-slot grant-review <repo>/<N>"* ]]
  [[ $output == *$'\nreturns: '* ]]
  [[ $output == *"example: agent-slot grant-review"* ]]
}
