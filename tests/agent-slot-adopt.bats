#!/usr/bin/env bats
# agent-slot adopt: a PR or issue attached to a live slot, which names a slot that has no name and renames the slot's
# Claude session when its agent is idle.
#
# Run: bats tests/agent-slot-adopt.bats
#
# repoa/1 is task_slot_setup's slot (tests/lib/agent-slot.bash), and gh answers from gh_item's fixtures.

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
}

teardown() {
  stop_spawned
  assert_no_leaks
}

# agent STATUS: the slot's Claude, as claude agents reports it.
agent() {
  jaq -n -c --arg cwd "$SLOT" --arg s "$1" '[{pid: 1, cwd: $cwd, status: $s, sessionId: "s1"}]' \
    >"$STUBS/claude-agents.json"
}

adopt() {
  run --separate-stderr "$AGENT_SLOT" adopt "$@" --output json
}

has() { jaq -e "$1" "$SLOT/.git/agent-slot.json" >/dev/null; }

@test "adopt names a slot that has no name from the item and logs it, typing nothing to a busy agent" {
  gh_item issue 12 "Fix the widget"
  agent busy
  adopt repoa/1 --issue 12
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.key == "repoa/1" and .name == "repoa-issue12-fix-the-widget" and .renamed == false
    and .items == [{kind: "issue", repo: "origins/repoa", number: 12, title: "Fix the widget"}]' <<<"$output"
  has '.name == "repoa-issue12-fix-the-widget" and .task == "t1" and .prs == [] and .named_as == null
    and .items == [{kind: "issue", repo: "origins/repoa", number: 12, title: "Fix the widget"}]'
  jaq -e -s 'last | .event == "adopt" and .repo == "repoa" and .slot == 1 and .session_id == "s1"
    and .item == {kind: "issue", repo: "origins/repoa", number: 12, title: "Fix the widget"}
    and .name == "repoa-issue12-fix-the-widget"' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  [ ! -e "$STUBS/typed-repoa-1" ]
}

@test "adopt renames an idle agent's session once, and an agent waiting on a dialog is never typed to" {
  gh_item issue 12 "Fix the widget"
  agent waiting
  adopt repoa/1 --issue 12
  [ "$status" -eq 0 ]
  jaq -e '.renamed == false' <<<"$output"
  [ ! -e "$STUBS/typed-repoa-1" ]
  agent idle
  adopt repoa/1 --issue 12
  [ "$status" -eq 0 ]
  jaq -e '.renamed == true and (.items | length) == 1' <<<"$output"
  [ "$(cat "$STUBS/typed-repoa-1")" = "/rename repoa-issue12-fix-the-widget" ]
  has '.named_as == "repoa-issue12-fix-the-widget"'
  : >"$STUBS/typed-repoa-1"
  adopt repoa/1 --issue 12
  [ "$status" -eq 0 ]
  jaq -e '.renamed == false' <<<"$output"
  [ ! -s "$STUBS/typed-repoa-1" ]
}

@test "a PR of another repo, such as the upstream of a fork origin, leaves .prs alone; one of origin's joins it" {
  git -C "$SLOT" remote set-url origin https://github.com/me/repoa.git
  gh_item pr 12 "Upstream fix"
  gh_item pr 13 "Fork fix"
  agent busy
  adopt repoa/1 --pr up/repoa#12
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  has '.prs == [] and .name == "repoa-pr12-upstream-fix"
    and .items == [{kind: "pr", repo: "up/repoa", number: 12, title: "Upstream fix"}]'
  adopt repoa/1 --pr 13
  [ "$status" -eq 0 ]
  jaq -e '.name == "repoa-pr12-upstream-fix" and ([.items[].repo] == ["up/repoa", "me/repoa"])' <<<"$output"
  has '.prs == [13] and .name == "repoa-pr12-upstream-fix"'
}

@test "adopt on a slot that does not exist fails with slot-not-found before GitHub is asked" {
  adopt repoa/9 --issue 12
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "slot-not-found" and .value == "repoa/9" and .next_step.command == "agent-slot list"' <<<"$stderr"
  run ! grep -qE '^gh (api|pr) ' "$CALLS"
}

@test "adopt takes one slot and exactly one of --pr or --issue" {
  local args
  for args in 'repoa/1' 'repoa/1 --pr 1 --issue 2' '--issue 2' 'repoa/1 repoa/2 --issue 2' 'repoa/1 --pr'; do
    # shellcheck disable=SC2086 # each case is a word list
    adopt $args
    [ "$status" -eq 2 ] || {
      echo "$args: $status $stderr"
      false
    }
    jaq -e '.reason == "usage" and .verb == "adopt"' <<<"$stderr"
  done
}

@test "adopt's help names the fields it returns, name and items among them, and an example" {
  run "$AGENT_SLOT" adopt --help
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "usage: agent-slot adopt <repo>/<N> (--pr <ref> | --issue <ref>)"* ]]
  [[ $output == *$'\nreturns: '*name*items* ]]
  [[ $output == *"example: agent-slot adopt "* ]]
}
