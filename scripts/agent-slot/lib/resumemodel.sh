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
        (($# >= 2)) && [[ -n $2 ]] || usage_fail "--model needs a value: opus or sonnet" "$1"
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
# was lost can be repeated. Otherwise it refuses with agent-busy unless the agent is idle or absent, and an idle agent's
# Claude must run no Bash tool command either, since ending it would kill that command. Then it writes the new model to
# the record and, for an idle agent, restarts its Claude. It sets RESUME_PREVIOUS and RESUME_RESTARTED.
resume_model_switch() {
  local repo=$1 n=$2 key jobs
  RESUME_PREVIOUS=$(contract_json -r '.model // "opus"' <<<"$RECORD")
  RESUME_RESTART=0 RESUME_RESTARTED=false
  [[ -n $RESUME_MODEL && $RESUME_MODEL != "$RESUME_PREVIOUS" ]] || return 0
  key=$(slot_key "$repo" "$n")
  agentstate_load
  agentstate_of "$repo" "$n"
  ! agentstate_inside_agent || _resume_model_refuse "$key"
  case $AGENT_STATE in
    idle)
      jobs=$(agentstate_jobs)
      [[ -z $jobs ]] || _resume_model_refuse "$key" "$jobs"
      RESUME_RESTART=1
      ;;
    absent) ;;
    *) _resume_model_refuse "$key" ;;
  esac
  record_update "$repo" "$n" --arg model "$RESUME_MODEL" '.model = $model'
  record_read "$repo" "$n"
  [[ $RESUME_RESTART == 1 ]] || return 0
  _resume_model_restart "$repo" "$n"
}

# Usage: resume_model_fields <prune-json>; prints the JSON with the fields a --model resume adds.
resume_model_fields() {
  contract_json -c --arg model "$RESUME_MODEL" --arg previous "$RESUME_PREVIOUS" --argjson restarted "$RESUME_RESTARTED" \
    '. + {model: $model, previous_model: $previous, restarted: $restarted}' <<<"$1"
}

# Usage: _resume_model_refuse <key> [<jobs>]; fails with agent-busy for the agent state agentstate_of found, or, with the
# "<pid> <command>" lines of an idle agent's Bash tool commands, for those. value is the state, or jobs for the latter.
# Only a busy agent or running jobs end by themselves, so only those say retry: a waiting or unreadable agent, and the
# slot's own agent, need a person or another session to act first. A resume that descends from the agent's Claude is
# refused in every state, since ending that Claude would end the resume itself.
_resume_model_refuse() {
  local key=$1 jobs=${2:-} message value=$AGENT_STATE action=ask-operator
  local idle="run this again once the agent is idle; agent-slot list --output json shows each slot's .agent"
  if [[ -n $jobs ]]; then
    value=jobs action=retry
    message="the agent of $key is idle but its Claude runs $(_check_plural "$(grep -c . <<<"$jobs")" "background job") \
(PID $(cut -d' ' -f1 <<<"$jobs" | paste -sd ' ' -)), which ending it would kill; stop them or wait for them, then $idle"
  elif agentstate_inside_agent; then
    message="this resume runs inside the slot's own agent, so ending that agent would end the resume; run it from \
another session once the agent is idle"
  elif [[ $AGENT_STATE == unknown ]]; then
    message="the state of the agent of $key could not be read ($AGENT_DETAIL); settle that, then $idle"
  elif [[ $AGENT_STATE == waiting ]]; then
    message="the agent of $key is waiting at a prompt or a question that only a person answers; once it is answered, $idle"
  else
    action=retry
    message="the agent of $key is busy, so ending it to switch models would interrupt it; $idle"
  fi
  contract_fail agent-busy "$message" --value "$value" --action "$action" \
    --command "agent-slot resume $key --model $RESUME_MODEL"
}

# Usage: _resume_model_restart <repo> <n>; ends the slot's Claude and everything it started, then types the new line into
# its pane, which is back at the shell once the processes are gone. A type that fails leaves a pane with no Claude in it,
# which a resume never starts again, since it skips a session that exists. So the session is dropped, and the next
# resume, with or without --model, creates it on the new model.
_resume_model_restart() {
  local repo=$1 n=$2 name line out status log
  name=$(slot_session "$repo" "$n")
  line=$(sessions_command "$repo" "$n" claude resume)
  _teardown_stop_agent
  if slot_tmux out 10 send-keys -t "=$name:" -l "$line" && slot_tmux out 10 send-keys -t "=$name:" Enter; then
    RESUME_RESTARTED=true
    return 0
  fi
  status=$BOUNDED_STATUS log=$BOUNDED_LOG
  slot_tmux out 10 kill-session -t "=$name" || true
  BOUNDED_STATUS=$status BOUNDED_LOG=$log
  ((BOUNDED_STATUS != 124)) || tmux_unresponsive partial
  contract_use_tools tmux
  contract_fail tmux-failed "ended the Claude in $name, but could not type the new line into it; the record names \
$RESUME_MODEL, and the session was dropped, so agent-slot resume $(slot_key "$repo" "$n") creates it again" \
    --value "$name" --side-effects partial --command "agent-slot resume $(slot_key "$repo" "$n")" --log "$BOUNDED_LOG"
}
