#!/usr/bin/env bats
# The README's agent slot reference stays equal to the code: its table of reasons is exactly the closed set every
# error's next_step.docs links to, its table of blockers is exactly the codes check reports, and it names every verb
# both dispatchers accept.
#
# Run: bats tests/agent-slot-docs.bats

REPO="$BATS_TEST_DIRNAME/.."
README="$REPO/README.md"

# table_codes HEADING: the backticked first-column values of the table under that README heading.
table_codes() {
  awk -v h="$1" '
    $0 == h { inside = 1; next }
    inside && /^#/ { exit }
    inside && /^\| `/ { split($0, cell, "`"); print cell[2] }' "$README" | sort
}

# verbs_of FILE: the verbs in the file's VERBS='...' line.
verbs_of() {
  sed -n "s/^VERBS='\(.*\)'\$/\1/p" "$1"
}

# shell_value FILE NAME: a single-quoted shell assignment's value, as the file defines it.
shell_value() {
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${!2}"' _ "$1" "$2"
}

@test "the README's table of reasons is exactly the closed set in contract.sh" {
  local code expected
  expected=$(bash -c 'source "$1"; contract_reasons' _ "$REPO/scripts/agent-slot/lib/contract.sh" | sort)
  code=$(table_codes '#### agent-slot reasons')
  [ -n "$code" ]
  diff <(echo "$expected") <(echo "$code")
}

@test "every error's docs link names the README section that holds the table" {
  run grep -c '^#### agent-slot reasons$' "$README"
  [ "$output" = 1 ]
  grep -q 'CONTRACT_DOCS=https://github.com/brettdavies/dotfiles/blob/main/README.md#agent-slot-reasons' \
    "$REPO/scripts/agent-slot/lib/contract.sh"
}

@test "the README's table of teardown blockers is exactly the codes check reports" {
  local expected
  expected=$(shell_value "$REPO/scripts/agent-slot/lib/check.sh" CHECK_CODES | tr -s ' \n' '\n' | grep . | sort)
  diff <(echo "$expected") <(table_codes '#### Teardown blockers')
}

@test "a blocker's docs link names the README section that holds the table of blockers" {
  run grep -c '^#### Teardown blockers$' "$README"
  [ "$output" = 1 ]
  run bash -c 'source "$1/contract.sh" && source "$1/check.sh" && printf %s "$CHECK_DOCS"' _ \
    "$REPO/scripts/agent-slot/lib"
  [ "$output" = https://github.com/brettdavies/dotfiles/blob/main/README.md#teardown-blockers ]
}

@test "the README names every verb agent-slot and agent-slot-rex accept" {
  local verb missing=()
  for verb in $(verbs_of "$REPO/scripts/agent-slot/lib/help.sh"); do
    grep -qE "agent-slot $verb\b" "$README" || missing+=("agent-slot $verb")
  done
  for verb in $(verbs_of "$REPO/scripts/agent-slot-rex/lib/help.sh"); do
    grep -qE "agent-slot-rex $verb\b" "$README" || missing+=("agent-slot-rex $verb")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    echo "not named in README.md: ${missing[*]}"
    false
  }
}
