# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# A slot's three tmux sessions on the slot server, each a login shell rooted at the slot with its program typed in:
#
#   <repo>-<N>        claude in bypass permissions mode, started with the slot's session ID, the slot's name (else its
#                     task) when it has one, and the first message read from a file by the shell itself, so the prompt
#                     never passes through tmux or quoting
#   <repo>-<N>-files  yazi, through the `y` shell function when it exists
#   <repo>-<N>-git    lazygit
#
# A typed command leaves the shell behind when the program exits, so a pane outlives its program. Sessions start from
# an empty environment: a tmux server started from inside a Claude session would otherwise inherit its child-session
# marker, and every Claude in the slot would then save no transcript. They start from /, so the server a first session
# starts never holds a slot as its working directory. That first session starts the server in a transient user scope of
# its own, so the server and its agents outlive whatever asked for them.
#
# Bypass permissions mode still stops on ask rules, deny rules, and hooks, and on Claude's trust dialog for an untrusted
# path. It starts without its own warning only when ~/.claude/settings.json accepts it (agent-slot doctor checks).

SESSIONS_CLAUDE='claude --dangerously-skip-permissions'
# Every slot's Claude runs at this effort, set on its command line so no settings file decides it.
SESSIONS_EFFORT=xhigh
# The models a slot can run on, by the name launch and reopen take. A Sonnet slot starts with Opus as its advisor.
# The advisor stays off in a session whose telemetry opt-outs (DISABLE_TELEMETRY, DO_NOT_TRACK) stop Claude Code's
# feature flags, and CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL=1 turns it on for that one process with the opt-outs
# still set.
SESSIONS_MODELS='opus sonnet'
SESSIONS_ADVISOR=opus
SESSIONS_ADVISOR_ENV=CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL=1
SESSIONS_CREATED=()

# Usage: sessions_model_id <model>; prints the Claude model ID for one of SESSIONS_MODELS, or returns 1.
sessions_model_id() {
  case $1 in
    opus) printf '%s' claude-opus-5-5 ;;
    sonnet) printf '%s' claude-sonnet-5-5 ;;
    *) return 1 ;;
  esac
}

# Usage: sessions_claude <model>; prints the start of a slot's claude command line for the model: the bypass flag,
# the model ID, the effort, and for Sonnet the advisor, behind the variable that turns it on.
sessions_claude() {
  local id
  id=$(sessions_model_id "$1") || id=$(sessions_model_id opus)
  if [[ $1 == sonnet ]]; then
    printf '%s %s --model %s --effort %s --advisor %s' "$SESSIONS_ADVISOR_ENV" "$SESSIONS_CLAUDE" "$id" \
      "$SESSIONS_EFFORT" "$SESSIONS_ADVISOR"
  else
    printf '%s --model %s --effort %s' "$SESSIONS_CLAUDE" "$id" "$SESSIONS_EFFORT"
  fi
}

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
  [[ -n $(sessions_transcript_find "$id") ]]
}

# Usage: sessions_transcript_find <session id>; prints the path of the session's transcript in any of Claude's project
# directories, or nothing. Claude names a project directory after its working directory in a form that cannot be read
# back, so a transcript is found by its session ID alone. An ID that is not plain hex and dashes is not searched for.
sessions_transcript_find() {
  [[ $1 =~ ^[0-9A-Fa-f-]+$ ]] || return 0
  find "$AS_CLAUDE_PROJECTS" -mindepth 2 -maxdepth 2 -name "$1.jsonl" -print -quit 2>/dev/null || true
}

# Usage: sessions_transcript_of <session id> [<path>]; prints the session's transcript: <path> when it is a file, else
# the one sessions_transcript_find finds, else <path>. A conversation resumed from another working directory, as a
# reopen does, goes on in the file it started in, under the project directory of the slot it started in, while Claude
# Code's SessionStart payload names one under the new working directory's.
sessions_transcript_of() {
  local found
  if [[ -n ${2:-} && -f $2 ]]; then
    printf '%s' "$2"
    return 0
  fi
  found=$(sessions_transcript_find "$1")
  printf '%s' "${found:-${2:-}}"
}

# Usage: sessions_record_transcript; prints the transcript of the session in RECORD, as sessions_transcript_of finds it.
sessions_record_transcript() {
  sessions_transcript_of "$(contract_json -r '.session_id // ""' <<<"$RECORD")" \
    "$(contract_json -r '.transcript // ""' <<<"$RECORD")"
}

# Usage: sessions_command <repo> <n> <claude | files | git> [launch | resume | reopen]
# Prints the line typed into a session, from the record in RECORD. The slot's own agent can write that record, so every
# value from it is shell-quoted. A resume or reopen whose conversation was never saved starts Claude as a launch does.
# In every mode, Claude's session takes the slot's name, else its task, so a resumed session carries the record's name,
# and runs on the record's model through sessions_claude; a record with no model runs on Opus.
# The first message goes with a launch and a reopen only: a resume brings back a slot that already had it.
sessions_command() {
  local repo=$1 n=$2 kind=$3 mode=${4:-launch} cmd name prompt claude
  case $kind in
    files) printf '%s' 'command -v y >/dev/null && y || yazi' ;;
    git) printf '%s' 'lazygit' ;;
    claude)
      name=$(contract_json -r '.name // .task // ""' <<<"$RECORD")
      claude=$(sessions_claude "$(contract_json -r '.model // "opus"' <<<"$RECORD")")
      prompt=$(contract_json -r '.prompt_file // ""' <<<"$RECORD")
      if [[ $mode != launch ]] && _sessions_conversation_saved; then
        printf -v cmd '%s --resume %q' "$claude" "$(contract_json -r '.session_id' <<<"$RECORD")"
        [[ $mode == reopen ]] || prompt=''
      else
        printf -v cmd '%s --session-id %q' "$claude" "$(contract_json -r '.session_id' <<<"$RECORD")"
      fi
      [[ -z $name ]] || printf -v cmd '%s -n %q' "$cmd" "$name"
      # After --, so a brief whose first character is a dash is the message, not an option.
      [[ -z $prompt ]] || printf -v cmd '%s -- "$(cat %q)"' "$cmd" "$prompt"
      printf '%s' "$cmd"
      ;;
  esac
}

# Usage: sessions_start <repo> <n> <launch | resume | reopen>
# Creates each of the slot's sessions that does not exist yet and types its program in, reading the record from
# RECORD. Sets SESSIONS_CREATED to the sessions it made. The caller holds the slot lock, so two calls never race to
# create the same session.
sessions_start() {
  local repo=$1 n=$2 mode=$3 path kind name shell out
  local -a start
  path=$(slot_path "$repo" "$n")
  shell=$(_sessions_shell)
  SESSIONS_CREATED=()
  slot_sessions_or_fail
  for kind in "${SLOT_SESSION_KINDS[@]}"; do
    name=$(slot_session "$repo" "$n" "$kind")
    grep -qxF "$name" <<<"$SLOT_SESSIONS" && continue
    start=(/usr/bin/env -i -C / HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL="$shell" TERM=xterm-256color
      LANG="${LANG:-C.UTF-8}" PATH="$PATH"
      "$AS_TMUX" -L "$AS_TMUX_SOCKET" -f "$AS_TMUX_CONF" new-session -d -s "$name" -c "$path" "$shell" -l)
    if [[ -n $SLOT_SESSIONS || ${#SESSIONS_CREATED[@]} -gt 0 ]] || ! _sessions_scoped "${start[@]}"; then
      bounded out tmux 10 "${start[@]}" || _sessions_fail "$repo" "$n" "$name"
    fi
    slot_tmux out 10 send-keys -t "=$name:" -l "$(sessions_command "$repo" "$n" "$kind" "$mode")" \
      || _sessions_fail "$repo" "$n" "$name"
    slot_tmux out 10 send-keys -t "=$name:" Enter || _sessions_fail "$repo" "$n" "$name"
    SESSIONS_CREATED+=("$name")
  done
}

# Usage: _sessions_scoped <command...>
# Runs the command that starts the slot server inside a transient user scope. systemd ends every process in a unit's
# cgroup with the unit, so a server started from a timer run or from the Rex server's service would otherwise take the
# agents with it. systemd-run wraps the empty environment rather than running inside it, since it needs the runtime
# directory and bus address, and a caller without a runtime directory, such as any shell in a slot, gets the user's.
# Each start names a scope of its own: a scope lasts while any process in it does, and the slot server's orphaned login
# shells keep an old one alive. Fails when systemd-run is missing or fails, and the caller then starts the server
# directly.
_sessions_scoped() {
  local out stamp
  [[ -n $AS_SYSTEMD_RUN ]] || return 1
  printf -v stamp '%(%s)T' -1
  bounded out systemd-run 10 /usr/bin/env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID}" "$AS_SYSTEMD_RUN" \
    --user --scope --collect --quiet --unit="agent-slots-tmux-$$-$stamp" -- "$@"
}

_sessions_fail() {
  ((BOUNDED_STATUS != 124)) || tmux_unresponsive partial
  contract_use_tools tmux
  contract_fail tmux-failed "could not start the tmux session $3" --value "$3" --side-effects partial \
    --command "agent-slot resume $(slot_key "$1" "$2")" --log "$BOUNDED_LOG"
}
