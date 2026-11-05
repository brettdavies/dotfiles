#!/usr/bin/env bats
# The trusted owner list as it ships. The shared agent-slot setup sets AGENT_SLOT_TRUSTED_OWNERS before every launch, so
# no other suite reads config/agent-slot/trusted-owners, and a broken list would pass them all in both directions: a
# parsing slip can trust an account named after a word in the file's comment header, and a wrong path makes every head
# on a trusted owner's repo foreign.
#
# Run: bats tests/agent-slot-owners.bats
# run-tests: parallel

setup() {
  unset AGENT_SLOT_TRUSTED_OWNERS
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../scripts/agent-slot/lib/owners.sh"
}

@test "the shipped list trusts its owners, in any case" {
  owner_trusted brettdavies
  owner_trusted BrettDavies
  owner_trusted meum-id
}

@test "the shipped list trusts nobody else" {
  run owner_trusted some-other-owner
  [ "$status" -eq 1 ]
  run owner_trusted ''
  [ "$status" -eq 1 ]
}

@test "no word from the file's comment header is an owner" {
  local word count=0
  for word in $(sed -n 's/^#//p' "$OWNERS_FILE" | tr -c 'A-Za-z0-9-' ' '); do
    count=$((count + 1))
    run owner_trusted "$word"
    [ "$status" -eq 1 ]
  done
  ((count > 5))
}

@test "a missing file trusts nobody" {
  OWNERS_FILE=$BATS_TEST_TMPDIR/no-such-file
  run owner_trusted brettdavies
  [ "$status" -eq 1 ]
}

@test "an empty override trusts nobody, not even a shipped owner" {
  AGENT_SLOT_TRUSTED_OWNERS='' run owner_trusted brettdavies
  [ "$status" -eq 1 ]
}

@test "an override replaces the list" {
  AGENT_SLOT_TRUSTED_OWNERS='someone' run owner_trusted brettdavies
  [ "$status" -eq 1 ]
  AGENT_SLOT_TRUSTED_OWNERS='someone' run owner_trusted someone
  [ "$status" -eq 0 ]
}
