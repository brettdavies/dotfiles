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

@test "every reason agent-slot-rex can emit is in the closed set" {
  local reason known missing=()
  known=$(bash -c 'source "$1"; contract_reasons' _ "$REPO/scripts/agent-slot/lib/contract.sh")
  while read -r reason; do
    grep -qxF "$reason" <<<"$known" || missing+=("$reason")
  done < <(grep -rhoE '^[^#]*(contract_error_json|contract_fail|doctor_finding (error|warning)) [a-z][a-z-]+' \
    "$REPO/scripts/agent-slot-rex" | awk '{ print $NF }' | sort -u)
  [ "${#missing[@]}" -eq 0 ] || {
    echo "not in CONTRACT_REASONS: ${missing[*]}"
    false
  }
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

@test "the README's table of purge failures is exactly the codes a teardown's purge reports" {
  local expected
  expected=$(shell_value "$REPO/scripts/agent-slot/lib/purge.sh" PURGE_CODES | tr -s ' \n' '\n' | grep . | sort)
  [ -n "$expected" ]
  diff <(echo "$expected") <(table_codes '#### Purge failures')
}

@test "a purge failure's docs link names the README section that holds the table of purge failures" {
  run grep -c '^#### Purge failures$' "$README"
  [ "$output" = 1 ]
  run bash -c 'source "$1/contract.sh" && source "$1/purge.sh" && printf %s "$PURGE_DOCS"' _ \
    "$REPO/scripts/agent-slot/lib"
  [ "$output" = https://github.com/brettdavies/dotfiles/blob/main/README.md#purge-failures ]
}

@test "the README names no helper verb or trigger that no longer exists" {
  run grep -nE 'agent-slot-rex follow|--by reconnect|follow\.log|AGENT_SLOT_REX_(TICK|WAKE_GAP|POLL_INTERVAL)' "$README" \
    "$REPO/BOOTSTRAP.md" "$REPO/AGENTS.md" "$REPO/CONCEPTS.md"
  [ "$status" -eq 1 ] || {
    echo "$output"
    false
  }
}

@test "the README's paragraph on bypass mode names the helper's asking verbs and slot agents' reach into Rex tabs" {
  awk '/^Each slot.s Claude starts and resumes with `--dangerously-skip-permissions`/,/^$/' "$README" >"$BATS_TEST_TMPDIR/p"
  grep -q 'rex send-key' "$BATS_TEST_TMPDIR/p"
  grep -q 'rex send`' "$BATS_TEST_TMPDIR/p"
  grep -q 'agent-slot-rex finish' "$BATS_TEST_TMPDIR/p"
  grep -q 'agent-slot-rex sweep' "$BATS_TEST_TMPDIR/p"
}

@test "the README names a prime's key, in the section that holds what a prime is" {
  grep -q '^#### Primes$' "$README"
  grep -qF '<repo>/prime' "$README"
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
