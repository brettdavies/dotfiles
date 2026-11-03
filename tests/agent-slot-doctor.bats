#!/usr/bin/env bats
# agent-slot doctor: launch prerequisites on the Linux server, version drift, and launch times from the ledger.
#
# Run: bats tests/agent-slot-doctor.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  export AGENT_SLOT_VERIFIED_VERSIONS=$T/verified-versions
  printf '# test\nclaude 2.1.310\nrex 0.0.1\n' >"$AGENT_SLOT_VERIFIED_VERSIONS"
}

# ledger_line JSON: appends one ledger line.
ledger_line() {
  printf '%s\n' "$1" >>"$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}

@test "with every prerequisite in place doctor reports no findings and exits 0" {
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e '.ok == true and .findings == [] and .verified_versions.claude == "2.1.310"' <<<"$output"
}

@test "a missing git-crypt key is reported with its next step, and every other check still runs" {
  rm "$AGENT_SLOT_GIT_CRYPT_KEY" "$AGENT_SLOT_TMUX_CONF"
  stub gh 'exit 1'
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 1 ]
  jaq -e '.ok == false' <<<"$output"
  jaq -e '[.findings[].reason] | sort == ["gh-auth-missing", "git-crypt-key-missing", "slots-config-missing"]' \
    <<<"$output"
  jaq -e '.findings[] | select(.reason == "git-crypt-key-missing") | .severity == "error" and .exit_code == 78
    and (.next_step.command | type == "string") and .next_step.action == "fix-config"' <<<"$output"
  jaq -e '.launch_times.target_s == 30' <<<"$output"
}

@test "every finding has the error envelope's shape" {
  rm "$AGENT_SLOT_GIT_CRYPT_KEY"
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  local finding
  while IFS= read -r finding; do
    assert_error_shape "$finding"
  done < <(jaq -c '.findings[]' <<<"$output")
}

@test "a Claude version absent from verified-versions warns and still exits 0" {
  export CLAUDE_STUB_VERSION=9.9.9
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e '.ok == true and .findings[0].reason == "version-unverified" and .findings[0].severity == "warning"
    and .findings[0].value == "9.9.9"' <<<"$output"
}

@test "a missing binary is a dependency-missing finding naming it" {
  export AGENT_SLOT_TRASH=$T/no-trash
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 1 ]
  jaq -e '.findings[] | select(.reason == "dependency-missing") | .value == "trash"' <<<"$output"
}

@test "an inactive prune timer is reported" {
  stub systemctl 'echo disabled; exit 1'
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  jaq -e '.findings[0].reason == "prune-timer-inactive"' <<<"$output"
}

@test "an inactive sweep timer is reported, with the command that enables it" {
  stub systemctl '[ "$3" = agent-slot-sweep.timer ] && { echo disabled; exit 1; }; echo enabled'
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  jaq -e '[.findings[].reason] == ["sweep-timer-inactive"]
    and .findings[0].next_step.command == "systemctl --user enable --now agent-slot-sweep.timer"' <<<"$output"
}

@test "from a shell with no XDG_RUNTIME_DIR, as in a slot, the timers are read from the user's own manager" {
  stub systemctl '[ "${XDG_RUNTIME_DIR-}" = "/run/user/$(id -u)" ] || { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
echo enabled'
  run --separate-stderr env -u XDG_RUNTIME_DIR "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e '.findings == []' <<<"$output"
}

@test "settings that never accepted bypass permissions mode are a warning naming the claude package deploy" {
  local settings
  for settings in '{}' '{"skipDangerousModePermissionPrompt": false}' ''; do
    rm -f "$AGENT_SLOT_CLAUDE_SETTINGS"
    [ -z "$settings" ] || printf '%s\n' "$settings" >"$AGENT_SLOT_CLAUDE_SETTINGS"
    run --separate-stderr "$AGENT_SLOT" doctor --output json
    [ "$status" -eq 0 ]
    jaq -e --arg p "$AGENT_SLOT_CLAUDE_SETTINGS" '.ok == true and (.findings | length == 1) and (.findings[0]
      | .reason == "bypass-mode-unaccepted" and .value == $p and .severity == "warning"
        and .next_step.command == "cd ~/dotfiles && scripts/stow-deploy claude"
        and .next_step.action == "fix-config")' <<<"$output"
  done
}

@test "an untrusted next slot path is a warning naming agent-slot warm" {
  slot repoa 1
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e --arg p "$AGENT_SLOT_ROOT/repoa/2" '.findings[0] | .reason == "slot-path-untrusted" and .value == $p
    and .next_step.command == "agent-slot warm repoa" and .severity == "warning"' <<<"$output"
  jaq -n --arg p "$AGENT_SLOT_ROOT/repoa/2" '{projects: {($p): {hasTrustDialogAccepted: true}}}' \
    >"$AGENT_SLOT_CLAUDE_STATE"
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  jaq -e '.findings == []' <<<"$output"
}

@test "a repo with every slot taken gets no trust warning, since no next slot can be launched" {
  export AGENT_SLOT_MAX_PER_REPO=2
  slot repoa 1
  slot repoa 2
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e '.findings == []' <<<"$output"
}

@test "a repo whose prime checkout is untrusted is a warning naming the prime, with no command to run" {
  prime repoa
  slot repoa 1
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e --arg p "$AGENT_SLOT_DEV/repoa" '.findings[0] | .reason == "slot-path-untrusted" and .value == $p
    and .next_step.command == null and .severity == "warning"' <<<"$output"
}

# solutions_worktree REPO NAME: a worktree of the corpus at origin/main under REPO's slot solutions directory; prints its
# path.
solutions_worktree() {
  local wt=$AGENT_SLOT_ROOT/$1/.solutions/$2
  mkdir -p "${wt%/*}"
  git -C "$AGENT_SLOT_SOLUTIONS" worktree add -q --detach "$wt" refs/remotes/origin/main
  printf '%s' "$wt"
}

@test "a solutions worktree under the slot root whose slot is gone is a warning with what it holds" {
  local wt
  wt=$(solutions_worktree repoa 3-abc123)
  echo draft >"$wt/a.md"
  echo draft >"$wt/b.md"
  git -C "$wt" add b.md
  git -C "$wt" commit -q -m b
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e --arg wt "$wt" '.ok == true and ([.findings[] | select(.reason == "solutions-worktree-orphaned")] | length == 1)
    and (.findings[] | select(.reason == "solutions-worktree-orphaned") | .severity == "warning"
      and .value == "\($wt) 1 1" and .next_step.command == "git -C \($wt) status")' <<<"$output"
}

@test "a live slot's solutions worktree and one outside the slot root are not reported" {
  local wt
  wt=$(solutions_worktree repoa 1-abc123)
  slot repoa 1 "{\"solutions_worktree\": \"$wt\"}"
  echo draft >"$wt/a.md"
  git -C "$AGENT_SLOT_SOLUTIONS" worktree add -q --detach "$T/scratch-wt" refs/remotes/origin/main
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e 'all(.findings[]; .reason != "solutions-worktree-orphaned")' <<<"$output"
}

@test "a shared solutions repo that is a plain directory, or has no origin/main, is solutions-corpus-missing" {
  git -C "$AGENT_SLOT_SOLUTIONS" update-ref -d refs/remotes/origin/main
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 1 ]
  jaq -e '.findings[] | select(.reason == "solutions-corpus-missing") | .severity == "error"
    and (.message | contains("origin/main"))' <<<"$output"
  rm -rf "$AGENT_SLOT_SOLUTIONS"
  mkdir -p "$AGENT_SLOT_SOLUTIONS"
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 1 ]
  jaq -e 'any(.findings[]; .reason == "solutions-corpus-missing")' <<<"$output"
}

@test "launch times give the median and p90 over measured launches, leaving out unready and skewed ones" {
  local i
  for i in 1 2 3 4 5; do
    ledger_line "{\"event\":\"launch\",\"request_id\":\"r$i\",\"requested_at\":1000}"
    ledger_line "{\"event\":\"ready\",\"request_id\":\"r$i\",\"ready_at\":$((1000 + i * 4))}"
  done
  ledger_line '{"event":"launch","request_id":"never","requested_at":2000}'
  ledger_line '{"event":"launch","request_id":"skew","requested_at":3000}'
  ledger_line '{"event":"ready","request_id":"skew","ready_at":2990}'
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e '.launch_times | .launches == 7 and .measured == 5 and .median_s == 12 and .p90_s == 20
    and .not_ready == ["never"] and .skewed == 1' <<<"$output"
  run "$AGENT_SLOT" doctor
  [[ "$output" == *"launch times: median 12 s, p90 20 s over 5 launches (target 30 s), 1 not ready"* ]]
}

@test "launch times cover only the last 20 launches" {
  local i
  for i in $(seq 1 25); do
    ledger_line "{\"event\":\"launch\",\"request_id\":\"r$i\",\"requested_at\":0}"
    ledger_line "{\"event\":\"ready\",\"request_id\":\"r$i\",\"ready_at\":$i}"
  done
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  jaq -e '.launch_times | .launches == 20 and .measured == 20 and .median_s == 15.5' <<<"$output"
}

@test "key to ready splits a key's launches into the tab's wait, the server's phases, and Claude's start" {
  local i
  for i in 1 2 3; do
    ledger_line "$(jaq -n -c --argjson i "$i" '{event: "launch", request_id: "k\($i)", opened_at: 1000, shown_at: 1002.5,
      requested_at: 1003, started_at: 1003.25, made_at: (1006 + $i),
      phases: {clone: 1, setup: 1, trust: $i, tmux: 0.5, claude: 0}}')"
    ledger_line "{\"event\":\"ready\",\"request_id\":\"k$i\",\"ready_at\":$((1007 + i))}"
  done
  ledger_line '{"event":"launch","request_id":"agent","requested_at":1000,"phases":{"clone":1}}'
  ledger_line '{"event":"ready","request_id":"agent","ready_at":1005}'
  ledger_line '{"event":"launch","request_id":"waiting","opened_at":2000,"requested_at":2001}'
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  [ "$status" -eq 0 ]
  jaq -e '.key_to_ready | .launches == 4 and .measured == 3 and .not_ready == ["waiting"]
    and .median_s == 9 and .p90_s == 10
    and .phases == {app_shows_tab: 2.5, helper: 0.5, prep: 0.25, clone: 1, setup: 1, trust: 2, tmux: 0.5,
      claude: 0, claude_start: 1}' <<<"$output"
  jaq -e '.launch_times.measured == 4' <<<"$output"
  run "$AGENT_SLOT" doctor
  [[ "$output" == *"key to ready: median 9 s, p90 10 s over 3 key presses; median phases (s): app shows tab 2.5, helper 0.5, prep 0.25, clone 1, setup 1, trust 2, tmux 0.5, claude 0, claude start 1"* ]]
}

@test "a key's launch with no shown time counts the helper from the tab's opening" {
  ledger_line '{"event":"launch","request_id":"k","opened_at":1000,"requested_at":1000.5,"started_at":1000.5,"made_at":1002,"phases":{"clone":1}}'
  ledger_line '{"event":"ready","request_id":"k","ready_at":1003}'
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  jaq -e '.key_to_ready | .measured == 1 and .median_s == 3 and .phases.app_shows_tab == null
    and .phases.helper == 0.5' <<<"$output"
}

@test "with no key's launch in the ledger, key to ready says none measured yet" {
  run --separate-stderr "$AGENT_SLOT" doctor --output json
  jaq -e '.key_to_ready | .launches == 0 and .measured == 0 and .median_s == null' <<<"$output"
  run "$AGENT_SLOT" doctor
  [[ "$output" == *"key to ready: no key press measured yet"* ]]
}
