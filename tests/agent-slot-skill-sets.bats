#!/usr/bin/env bats
# The skill sets as they ship. A set turns skills on in one slot through settings.local.json, which outranks the user
# file, so a name the user file does not turn off is on in every session already and the set is dead weight, and a set
# whose names have drifted from that file turns on nothing a launch would not have had. Launching with --skills is
# covered by tests/agent-slot-launch.bats.
#
# Run: bats tests/agent-slot-skill-sets.bats
# run-tests: parallel

SETS=$BATS_TEST_DIRNAME/../config/agent-slot/skill-sets
SETTINGS=$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json

# names_of FILE: the skill names a set file holds, one per line.
names_of() {
  sed 's/#.*//' "$1" | tr -s ' \t\n' '\n' | grep . || true
}

@test "the sets directory holds at least one set, and each holds at least one name" {
  local file count=0
  for file in "$SETS"/*; do
    [ -f "$file" ]
    [ -n "$(names_of "$file")" ] || {
      echo "$file holds no names"
      false
    }
    count=$((count + 1))
  done
  ((count > 0))
}

@test "every name in every set file is off in the user-level settings.json" {
  local file name checked=0
  for file in "$SETS"/*; do
    while read -r name; do
      jaq -e --arg n "$name" '.skillOverrides[$n] == "off"' "$SETTINGS" >/dev/null || {
        echo "$(basename "$file"): $name is not off in stow/claude/dot-claude/settings.json"
        false
      }
      checked=$((checked + 1))
    done < <(names_of "$file")
  done
  ((checked > 0))
}

@test "every set file is named a word that launch --skills takes" {
  local file
  for file in "$SETS"/*; do
    [[ ${file##*/} =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
      echo "${file##*/} is not a lowercase word of letters, digits, and -, so launch --skills refuses it"
      false
    }
  done
}
