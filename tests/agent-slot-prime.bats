#!/usr/bin/env bats
# A repo's prime: the slot-shaped set of tmux sessions that runs in the repo's own checkout. Its names and its map, then
# the verb that starts it.
#
# Run: bats tests/agent-slot-prime.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  export AGENT_SLOT_CLAUDE_PROJECTS=$T/projects
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS"
  NAMES=$BATS_TEST_DIRNAME/../scripts/agent-slot/lib/names.sh
  MAP=$BATS_TEST_DIRNAME/../config/agent-slot-rex/primes.tsv
  prime repoa
}

# names EXPRESSION: runs a shell expression with the names library loaded.
names() {
  bash -c 'source "$1"; eval "$2"' _ "$NAMES" "$1"
}

# --- names and the map ------------------------------------------------------------------------------------------------

@test "a prime's three sessions come from the same naming a slot's do, sanitized the same way" {
  run names 'slot_session repoa prime; echo; slot_session repoa prime files; echo; slot_session repoa prime git; echo
    slot_session a.b prime'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = repoa-prime ]
  [ "${lines[1]}" = repoa-prime-files ]
  [ "${lines[2]}" = repoa-prime-git ]
  [ "${lines[3]}" = a_b-prime ]
}

@test "a prime's Claude session is told from a slot's by name, whatever digits the repo's name holds" {
  local is_prime is_slot
  for is_prime in x-prime foo-2-prime; do
    run names "slot_session_is_prime $is_prime"
    [ "$status" -eq 0 ]
    run names "slot_session_is_claude $is_prime"
    [ "$status" -ne 0 ]
  done
  for is_slot in x-prime-1 foo-2; do
    run names "slot_session_is_prime $is_slot"
    [ "$status" -ne 0 ]
    run names "slot_session_is_claude $is_slot"
    [ "$status" -eq 0 ]
  done
  run names "slot_session_is_prime x-prime-files"
  [ "$status" -ne 0 ]
}

@test "a repo's display name comes from the map, else from the repo's own name" {
  printf '# a comment\nxurl-rs\tXR CLI\nbroken line with no tab\n#qmd\tcommented out\n' >"$T/map"
  run names "prime_display_name xurl-rs '$T/map'; echo; prime_display_name qmd '$T/map'; echo
    prime_display_name broken '$T/map'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'XR CLI' ]
  [ "${lines[1]}" = qmd ]
  [ "${lines[2]}" = broken ]
}

@test "the map names each repo once, with two fields and a name tmux can hold" {
  local repos
  run awk -F '\t' '!/^#/ && NF != 2' "$MAP"
  [ -z "$output" ]
  repos=$(awk -F '\t' '!/^#/ { print $1 }' "$MAP")
  [ -n "$repos" ]
  [ -z "$(sort <<<"$repos" | uniq -d)" ]
  run awk -F '\t' '!/^#/ && $2 ~ /[.:]/' "$MAP"
  [ -z "$output" ]
}

@test "the map carries the display name of each session that runs today under a name other than its repo's" {
  run names "prime_display_name home-media-server '$MAP'; echo; prime_display_name dot-github '$MAP'; echo
    prime_display_name streams-control '$MAP'; echo; prime_display_name gbrain '$MAP'; echo
    prime_display_name obsidian-vault '$MAP'; echo; prime_display_name qmd '$MAP'"
  [ "${lines[0]}" = 'Home Media Server' ]
  [ "${lines[1]}" = _github ]
  [ "${lines[2]}" = 'Streams Control' ]
  [ "${lines[3]}" = GBrain ]
  [ "${lines[4]}" = Vault ]
  [ "${lines[5]}" = qmd ]
}

@test "an old session counts as holding a Claude only when a pane runs one, under its name or its version" {
  run names "printf 'A\tzsh\nA\tclaude\nB\t2.1.318\nC\tzsh\nC\tlazygit\nD\t2.1\nA\tyazi\n' | prime_old_sessions"
  [ "$status" -eq 0 ]
  [ "$output" = $'A\nB' ]
}

@test "a slot verb given a prime's key says it is a prime and names the verb that starts it" {
  run --separate-stderr "$AGENT_SLOT" resume repoa/prime --output json
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "repoa/prime"
    and (.message | contains("agent-slot prime repoa"))' <<<"$stderr"
}
