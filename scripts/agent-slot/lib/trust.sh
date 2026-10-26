# shellcheck shell=bash
# Claude's workspace trust for slot paths.
#
# Claude keys trust on the path and records it as hasTrustDialogAccepted in its app-state file. That key is not a
# supported interface, so it is only ever read here, and a missing or unreadable entry counts as untrusted.

# Usage: trust_known <path>; true when Claude's app-state file marks the path's realpath trusted.
trust_known() {
  local real
  real=$(realpath -m "$1")
  [[ -r $AS_CLAUDE_STATE ]] || return 1
  [[ $(contract_json -r --arg p "$real" '.projects[$p].hasTrustDialogAccepted // false' "$AS_CLAUDE_STATE" \
    2>/dev/null) == true ]]
}
