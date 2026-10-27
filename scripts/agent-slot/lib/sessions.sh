# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# A slot's three tmux sessions on the slot server, each a login shell rooted at the slot with its program typed in:
#
#   <repo>-<N>        claude in bypass permissions mode, started with the slot's session ID, the task name when one was
#                     given, and the first message read from a file by the shell itself, so the prompt never passes
#                     through tmux or quoting
#   <repo>-<N>-files  yazi, through the `y` shell function when it exists
#   <repo>-<N>-git    lazygit
#
# A typed command leaves the shell behind when the program exits, so a pane outlives its program. Sessions start from
# an empty environment: a tmux server started from inside a Claude session would otherwise inherit its child-session
# marker, and every Claude in the slot would then save no transcript. They start from /, so the server a first session
# starts never holds a slot as its working directory.
#
# Bypass permissions mode still stops on ask rules, deny rules, and hooks, and on Claude's trust dialog for an untrusted
# path. It starts without its own warning only when ~/.claude/settings.json accepts it (agent-slot doctor checks).

SESSIONS_CLAUDE='claude --dangerously-skip-permissions'
SESSIONS_CREATED=()

# The login shell a session runs: the account's own, from the password database.
_sessions_shell() {
  local shell
  shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || true)
  printf '%s' "${shell:-/bin/bash}"
}

# True when Claude has saved the conversation with the record's session ID. Claude writes nothing until the first
# message, so the agent of a slot launched without one has no conversation to resume. An ID that is not plain hex and
# dashes is not searched for and counts as saved.
_sessions_conversation_saved() {
  local id
  id=$(contract_json -r '.session_id' <<<"$RECORD")
  [[ $id =~ ^[0-9A-Fa-f-]+$ ]] || return 0
  [[ -n $(find "$AS_CLAUDE_PROJECTS" -mindepth 2 -maxdepth 2 -name "$id.jsonl" -print -quit 2>/dev/null) ]]
}

# Usage: sessions_command <repo> <n> <claude | files | git> [launch | resume]
# Prints the line typed into a session, from the record in RECORD. The slot's own agent can write that record, so every
# value from it is shell-quoted. A resume whose conversation was never saved starts Claude as a launch does.
sessions_command() {
  local repo=$1 n=$2 kind=$3 mode=${4:-launch} cmd task prompt
  case $kind in
    files) printf '%s' 'command -v y >/dev/null && y || yazi' ;;
    git) printf '%s' 'lazygit' ;;
    claude)
      if [[ $mode == resume ]] && _sessions_conversation_saved; then
        printf '%s --resume %q' "$SESSIONS_CLAUDE" "$(contract_json -r '.session_id' <<<"$RECORD")"
        return
      fi
      printf -v cmd '%s --session-id %q' "$SESSIONS_CLAUDE" "$(contract_json -r '.session_id' <<<"$RECORD")"
      task=$(contract_json -r '.task // ""' <<<"$RECORD")
      [[ -z $task ]] || printf -v cmd '%s -n %q' "$cmd" "$task"
      prompt=$(contract_json -r '.prompt_file // ""' <<<"$RECORD")
      [[ -z $prompt ]] || printf -v cmd '%s "$(cat %q)"' "$cmd" "$prompt"
      printf '%s' "$cmd"
      ;;
  esac
}

# Usage: sessions_start <repo> <n> <launch | resume>
# Creates each of the slot's sessions that does not exist yet and types its program in, reading the record from
# RECORD. Sets SESSIONS_CREATED to the sessions it made. The caller holds the slot lock, so two calls never race to
# create the same session.
sessions_start() {
  local repo=$1 n=$2 mode=$3 path kind name shell out
  path=$(slot_path "$repo" "$n")
  shell=$(_sessions_shell)
  SESSIONS_CREATED=()
  slot_sessions_or_fail
  for kind in "${SLOT_SESSION_KINDS[@]}"; do
    name=$(slot_session "$repo" "$n" "$kind")
    grep -qxF "$name" <<<"$SLOT_SESSIONS" && continue
    bounded out tmux 10 /usr/bin/env -i -C / HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL="$shell" TERM=xterm-256color \
      LANG="${LANG:-C.UTF-8}" PATH="$PATH" \
      "$AS_TMUX" -L "$AS_TMUX_SOCKET" -f "$AS_TMUX_CONF" new-session -d -s "$name" -c "$path" "$shell" -l \
      || _sessions_fail "$repo" "$n" "$name"
    slot_tmux out 10 send-keys -t "=$name:" -l "$(sessions_command "$repo" "$n" "$kind" "$mode")" \
      || _sessions_fail "$repo" "$n" "$name"
    slot_tmux out 10 send-keys -t "=$name:" Enter || _sessions_fail "$repo" "$n" "$name"
    SESSIONS_CREATED+=("$name")
  done
}

_sessions_fail() {
  ((BOUNDED_STATUS != 124)) || tmux_unresponsive partial
  contract_use_tools tmux
  contract_fail tmux-failed "could not start the tmux session $3" --value "$3" --side-effects partial \
    --command "agent-slot resume $(slot_key "$1" "$2")" --log "$BOUNDED_LOG"
}
