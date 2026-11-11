# shellcheck shell=bash
# The scope-grant lines both stow/claude/dot-claude/slot-scope-guard.sh (which lets the paths a grant's pathspec matches
# through) and `agent-slot grant-scope` (which appends one and counts them) read: a slot's grants, since the slot was
# made.

# Usage: scope_grants <repo> <n> <since>; prints the pathspec of each scope-grant ledger line for the slot with a ts at
# or after <since>, one per line. The ledger is read line by line, so a line that is not JSON grants nothing.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
scope_grants() {
  [[ -r $AS_LEDGER ]] || return 0
  contract_json -R -s -r --arg repo "$1" --argjson n "$2" --arg since "$3" \
    '[split("\n")[] | fromjson? | select(type == "object" and .event == "scope-grant" and .repo == $repo
      and .slot == $n and .ts >= $since and (.pathspec | type == "string")) | .pathspec] | .[]' "$AS_LEDGER"
}
