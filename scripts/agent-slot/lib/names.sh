# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Slot names both machines share: the <repo>/<N> key and the tmux session names agent-slot creates and agent-slot-rex
# attaches to. Both dispatchers source this file, so a slot is never named one way on the server and another on the Mac.

# Unanchored, so they can sit inside a larger pattern.
SLOT_REPO_PATTERN='[A-Za-z0-9._-]+'
SLOT_KEY_PATTERN="$SLOT_REPO_PATTERN/[0-9]+"

# A slot's three sessions, by kind.
SLOT_SESSION_KINDS=(claude files git)

slot_key() { printf '%s/%s' "$1" "$2"; }

# Usage: slot_session <repo> <n> [claude | files | git]; tmux session names cannot hold `.` or `:`, and the Claude
# session has no kind suffix.
slot_session() {
  local name="${1//[.:]/_}-$2"
  [[ ${3:-claude} == claude ]] || name+=-$3
  printf '%s' "$name"
}

# Usage: slot_session_is_claude <session name>; true for a slot's Claude session, the one slot_session names with no
# kind suffix.
slot_session_is_claude() { [[ $1 =~ -[0-9]+$ ]]; }

# Usage: slot_parse_key <repo>/<n>; sets SLOT_REPO and SLOT_N, or fails with usage.
SLOT_REPO='' SLOT_N=''
slot_parse_key() {
  if [[ $1 =~ ^($SLOT_REPO_PATTERN)/([0-9]+)$ ]]; then
    SLOT_REPO=${BASH_REMATCH[1]} SLOT_N=${BASH_REMATCH[2]}
  else
    usage_fail "a slot is named <repo>/<N>, such as dotfiles/2" "$1"
  fi
}
