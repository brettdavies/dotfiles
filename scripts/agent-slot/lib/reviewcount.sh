# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The review-round count both stow/claude/dot-claude/slot-review-cap.sh (which appends a `review-round` ledger line per
# allowed ce-code-review call) and `agent-slot grant-review` (which appends a `review-grant` line) read: a slot's rounds
# on a branch, since the slot was made, against REVIEW_CAP plus its grants.

REVIEW_CAP=2

# Usage: review_count <event> <repo> <n> <branch> <since>
# Prints the ledger lines of one event for a slot's branch with a ts at or after <since>. The ledger is read line by
# line, so a line that is not JSON counts for nothing and stops nothing.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
review_count() {
  [[ -r $AS_LEDGER ]] || {
    printf 0
    return 0
  }
  contract_json -R -s -r --arg e "$1" --arg repo "$2" --argjson n "$3" --arg b "$4" --arg since "$5" \
    '[split("\n")[] | fromjson? | select(type == "object" and .event == $e and .repo == $repo and .slot == $n
      and .branch == $b and .ts >= $since)] | length' "$AS_LEDGER"
}
