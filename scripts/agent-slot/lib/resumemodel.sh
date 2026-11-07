# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# resume --model: a live slot's model switches through the command line of a restarted Claude. The record takes the new
# model first, so every start after it, this one's included, runs on it. An idle Claude is then ended and the pane's
# shell is typed the line sessions_command builds, which resumes the same conversation by session ID, so a Sonnet slot
# gets its Opus advisor and the SessionStart hook gives the new session the current slot rules. An agent that is
# mid-turn, waiting on a prompt, or unreadable is never ended: resume refuses before it changes anything.
#
# Claude's own /model command is never used. It also writes the model into ~/.claude/settings.json, which makes it the
# default of every new session on the host, and it asks for a confirmation a pane cannot give.

RESUME_KEY='' RESUME_MODEL='' RESUME_PREVIOUS='' RESUME_RESTART=0 RESUME_RESTARTED=false

# Usage: resume_parse_args <args...>; sets RESUME_KEY to the one slot and RESUME_MODEL to the --model given, or to ''.
# The flag may come before or after the slot.
resume_parse_args() {
  local -a rest=()
  RESUME_MODEL=''
  local given=0
  while (($#)); do
    case $1 in
      --model)
        (($# >= 2)) && [[ -n $2 ]] || usage_fail "--model needs a value: ${SESSIONS_MODELS// / or }" "$1"
        ((given == 0)) || usage_fail "resume takes one --model" "$1"
        given=1
        RESUME_MODEL=$2
        model_check "$2" resume
        shift 2
        ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        rest+=("$1")
        shift
        ;;
    esac
  done
  ((${#rest[@]} == 1)) || usage_fail "resume takes one slot, <repo>/<N>" "${rest[*]}"
  RESUME_KEY=${rest[0]}
}

# Usage: resume_model_switch <repo> <n>; with RECORD the slot's record, under the slot's lock.
# With no --model, or the model the slot already runs, it does nothing and asks Claude nothing, so a call whose answer
# was lost can be repeated. Otherwise it refuses with agent-busy unless the agent is idle or absent. Then it writes the
# new model to the record and, for an idle agent, restarts its Claude. It sets RESUME_PREVIOUS and RESUME_RESTARTED.
resume_model_switch() {
  local repo=$1 n=$2 key
  RESUME_PREVIOUS=$(contract_json -r '.model // "opus"' <<<"$RECORD")
  RESUME_RESTART=0 RESUME_RESTARTED=false
  [[ -n $RESUME_MODEL && $RESUME_MODEL != "$RESUME_PREVIOUS" ]] || return 0
  key=$(slot_key "$repo" "$n")
  agentstate_load
  agentstate_of "$repo" "$n"
  case $AGENT_STATE in
    idle) RESUME_RESTART=1 ;;
    absent) ;;
    *) _resume_model_refuse_state "$key" ;;
  esac
  [[ $RESUME_RESTART == 0 ]] || _resume_model_leave_mode "$repo" "$n"
  record_update "$repo" "$n" --arg model "$RESUME_MODEL" '.model = $model'
  record_read "$repo" "$n"
  [[ $RESUME_RESTART == 1 ]] || return 0
  _resume_model_restart "$repo" "$n"
}

# Usage: _resume_model_leave_mode <repo> <n>; takes the slot's Claude pane out of any tmux mode. A pane the operator has
# scrolled back in is in copy mode, which takes the keys meant for the shell. It runs while the old Claude is still alive
# and before the record changes, so a tmux that fails here has changed nothing and the same command can run again.
_resume_model_leave_mode() {
  local name out
  name=$(slot_session "$1" "$2")
  slot_tmux out 5 copy-mode -q -t "=$name:" && return 0
  ((BOUNDED_STATUS != 124)) || tmux_unresponsive
  contract_use_tools tmux
  contract_fail tmux-failed "could not take the pane of $name out of copy mode, so its Claude was not ended and nothing \
changed" --value "$name" --command "agent-slot resume $(slot_key "$1" "$2") --model $RESUME_MODEL" --log "$BOUNDED_LOG"
}

# Usage: resume_model_fields <prune-json>; prints the JSON with the fields a --model resume adds.
resume_model_fields() {
  contract_json -c --arg model "$RESUME_MODEL" --arg previous "$RESUME_PREVIOUS" --argjson restarted "$RESUME_RESTARTED" \
    '. + {model: $model, previous_model: $previous, restarted: $restarted}' <<<"$1"
}

# Usage: _resume_model_refuse_state <key>; fails with agent-busy for the agent state agentstate_of found, which is the
# error's value. Only a busy agent ends by itself, so only that one says retry: a waiting or unreadable agent needs a
# person to act first.
_resume_model_refuse_state() {
  local key=$1 message action=ask-operator
  local idle="run this again once the agent is idle; agent-slot list --output json shows each slot's .agent"
  if [[ $AGENT_STATE == unknown ]]; then
    message="the state of the agent of $key could not be read ($AGENT_DETAIL); settle that, then $idle"
  elif [[ $AGENT_STATE == waiting ]]; then
    message="the agent of $key is waiting at a prompt or a question that only a person answers; once it is answered, $idle"
  else
    action=retry
    message="the agent of $key is busy, so ending it to switch models would interrupt it; $idle"
  fi
  _resume_model_fail "$key" "$message" "$AGENT_STATE" "$action"
}

# Usage: _resume_model_refuse <key> [<jobs>]; _resume_model_refuse_state plus two cases for a caller that must not end
# the agent's Claude. <jobs> holds the "<pid> <command>" lines of an idle agent's Bash tool commands: value is those
# lines, as release's background-jobs-running gives them, and the action is retry, since they end by themselves. A
# caller that descends from the agent's Claude is refused in every state, with value own-agent and ask-operator, since
# ending that Claude would end the caller and only another session can act.
_resume_model_refuse() {
  local key=$1 jobs=${2:-}
  if [[ -n $jobs ]]; then
    _resume_model_fail "$key" "the agent of $key is idle but its Claude runs \
$(_check_plural "$(grep -c . <<<"$jobs")" "background job") (PID $(cut -d' ' -f1 <<<"$jobs" | paste -sd ' ' -); value \
names each command), which ending it would kill; wait for them to finish, or ask the slot's agent or the operator to \
stop them. Running this again changes nothing while they run" "$jobs" retry
  elif agentstate_inside_agent; then
    _resume_model_fail "$key" "this resume runs inside the slot's own agent, so ending that agent would end the resume; \
run it from another session once the agent is idle" own-agent ask-operator
  fi
  _resume_model_refuse_state "$key"
}

# Usage: _resume_model_fail <key> <message> <value> <action>; fails with agent-busy, whose next step is the command that
# repeats the call: the one the caller set in AGENT_BUSY_COMMAND, else resume --model.
_resume_model_fail() {
  contract_fail agent-busy "$2" --value "$3" --action "$4" \
    --command "${AGENT_BUSY_COMMAND:-agent-slot resume $1 --model $RESUME_MODEL}"
}

# Usage: _resume_model_restart <repo> <n>; ends the slot's Claude and everything it started, then types the new line into
# its pane, which is back at the shell once the processes are gone. A type that fails leaves a pane with no Claude in
# it, which a resume never starts again, since it skips a session that exists. So the session is dropped, and the next
# resume, with or without --model, creates it on the new model.
_resume_model_restart() {
  local repo=$1 n=$2 name key line out status log reason why next command
  name=$(slot_session "$repo" "$n")
  key=$(slot_key "$repo" "$n")
  line=$(sessions_command "$repo" "$n" claude resume)
  _teardown_stop_agent
  if slot_tmux out 10 send-keys -t "=$name:" -l "$line" && slot_tmux out 10 send-keys -t "=$name:" Enter; then
    RESUME_RESTARTED=true
    return 0
  fi
  status=$BOUNDED_STATUS log=$BOUNDED_LOG
  reason=tmux-failed why="could not type the new line into it"
  if ((status == 124)); then
    reason=tmux-unresponsive why="tmux did not answer while the new line was typed into it"
  fi
  command="agent-slot resume $key" next="the session was dropped, so $command creates it again"
  if ! slot_tmux out 10 kill-session -t "=$name"; then
    command=$(contract_quote "$AS_TMUX" -L "$AS_TMUX_SOCKET" kill-session -t "=$name")
    next="the session could not be dropped either: run $command, then agent-slot resume $key"
  fi
  contract_use_tools tmux
  contract_fail "$reason" "ended the Claude in $name, but $why; the record names $RESUME_MODEL, and $next" \
    --value "$name" --side-effects partial --command "$command" --log "$log"
}
