# shellcheck shell=bash
# The GitHub owners whose repositories count as the operator's own: AGENT_SLOT_TRUSTED_OWNERS when it is set, even empty,
# which trusts nobody; else config/agent-slot/trusted-owners. A file that cannot be read trusts nobody.

OWNERS_FILE=${BASH_SOURCE[0]%/*}/../../../config/agent-slot/trusted-owners

# Usage: owners_list; prints the trusted owners on one line, separated by spaces.
owners_list() {
  if [[ -n ${AGENT_SLOT_TRUSTED_OWNERS+set} ]]; then
    printf '%s\n' "$AGENT_SLOT_TRUSTED_OWNERS"
  else
    sed 's/#.*//' "$OWNERS_FILE" 2>/dev/null | tr -s ' \n' ' ' || true
  fi
}

# Usage: owner_trusted <owner>; true when the owner is on the list, matched in any case, as GitHub matches it.
owner_trusted() {
  local owner candidate
  local -a owners
  owner=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ -n $owner ]] || return 1
  read -r -a owners <<<"$(owners_list | tr '[:upper:]' '[:lower:]')"
  for candidate in ${owners[@]+"${owners[@]}"}; do
    [[ $candidate != "$owner" ]] || return 0
  done
  return 1
}
