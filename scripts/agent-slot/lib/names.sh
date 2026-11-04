# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Slot names both machines share: the <repo>/<N> key and the tmux session names agent-slot creates and agent-slot-rex
# attaches to. Both dispatchers source this file, so a slot is never named one way on the server and another on the Mac.

# Unanchored, so they can sit inside a larger pattern.
SLOT_REPO_PATTERN='[A-Za-z0-9._-]+'
SLOT_KEY_PATTERN="$SLOT_REPO_PATTERN/[0-9]+"

# What a prime has where a slot has a number: its key is <repo>/prime, and slot_session names its sessions from it. Slot
# verbs take SLOT_KEY_PATTERN, which this never matches, so nothing that ends a slot can name a prime.
SLOT_PRIME=prime

# The repo whose slots share main: the vault takes no branches or PRs, keeps a whitelist .gitignore, and holds the
# operator's private notes.
VAULT_REPO=obsidian-vault

# A slot's three sessions, by kind.
SLOT_SESSION_KINDS=(claude files git)

slot_key() { printf '%s/%s' "$1" "$2"; }

# The tmux server an operator's own sessions run on. Calls name it, since a slot pane's TMUX points at the slot server.
TMUX_DEFAULT_SOCKET=default

# Usage: tmux_name <name>; prints the name as tmux stores it, which holds no `.` or `:`.
tmux_name() { printf '%s' "${1//[.:]/_}"; }

# Usage: slot_session <repo> <n> [claude | files | git]; the Claude session has no kind suffix.
slot_session() {
  local name
  name=$(tmux_name "$1")-$2
  [[ ${3:-claude} == claude ]] || name+=-$3
  printf '%s' "$name"
}

# Usage: slot_session_is_claude <session name>; true for a slot's Claude session, the one slot_session names with no
# kind suffix.
slot_session_is_claude() { [[ $1 =~ -[0-9]+$ ]]; }

# Usage: slot_session_is_prime <session name>; true for a prime's Claude session.
slot_session_is_prime() { [[ $1 == *-"$SLOT_PRIME" ]]; }

# Usage: prime_claude_name <repo>; prints the name a prime's Claude runs under, which other sessions message it by.
prime_claude_name() { printf '%s-%s' "$1" "$SLOT_PRIME"; }

# Usage: prime_display_name <repo> <map file>; prints the name in the map's <repo><TAB><name> line, else the repo's own.
prime_display_name() {
  local name
  name=$(awk -F '\t' -v repo="$1" '!/^#/ && NF == 2 && $1 == repo { print $2; exit }' "$2")
  printf '%s' "${name:-$1}"
}

# The format prime_old_sessions reads, from `tmux -L default list-panes -a`.
PRIME_OLD_PANES_FORMAT=$'#{session_name}\t#{pane_current_command}'

# Reads panes in PRIME_OLD_PANES_FORMAT and prints each session holding a Claude, which can run under a bare version
# number, its versioned binary's name. A session with no Claude is not a prime: every tmuxinator project left a blank
# pane, and continuum restores a session with shells only.
prime_old_sessions() {
  awk -F '\t' '$2 == "claude" || $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $1 }' | sort -u
}

# Usage: slot_parse_key <repo>/<n>; sets SLOT_REPO and SLOT_N, or fails with usage.
SLOT_REPO='' SLOT_N=''
slot_parse_key() {
  if [[ $1 =~ ^($SLOT_REPO_PATTERN)/([0-9]+)$ ]]; then
    SLOT_REPO=${BASH_REMATCH[1]} SLOT_N=${BASH_REMATCH[2]}
  elif [[ $1 =~ ^($SLOT_REPO_PATTERN)/$SLOT_PRIME$ ]]; then
    usage_fail "$1 is a prime, not a slot; agent-slot prime ${BASH_REMATCH[1]} starts it, and nothing here ends it" "$1"
  else
    usage_fail "a slot is named <repo>/<N>, such as dotfiles/2" "$1"
  fi
}

# Usage: slot_parse_attach_key <repo>/<n | prime>; sets SLOT_REPO and SLOT_N, or fails with usage.
slot_parse_attach_key() {
  if [[ $1 =~ ^($SLOT_REPO_PATTERN)/([0-9]+|$SLOT_PRIME)$ ]]; then
    SLOT_REPO=${BASH_REMATCH[1]} SLOT_N=${BASH_REMATCH[2]}
  else
    usage_fail "a pane holds a slot, <repo>/<N>, or a prime, <repo>/prime" "$1"
  fi
}
