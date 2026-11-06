# shellcheck shell=bash disable=SC2016,SC2034,SC2153 # jaq programs in single quotes; the sourced files share its globals
# retask: a live slot takes a new task in a new Claude session, so one conversation never carries two tasks. Follow-up
# work on the same task stays in the session; only a new task comes here. The agent must be idle or absent and the old
# task's work pushed, so nothing is lost by ending it. The clone goes back to the base with the old local branches gone,
# which keeps the push guard's view of "this session's branch" true. The old session stays on the record and in a retask
# ledger line that a reopen reads as it reads a teardown, so the old task can still be picked up.
#
# The record takes the new session ID first. A resume of an ID with no saved conversation starts Claude as a launch
# does, with the brief, so resume --model's restart starts the new session and a failed type recovers by a plain resume.

RETASK_KEY='' RETASK_TASK='' RETASK_ISSUE='' RETASK_PROMPT=''
# What an old task can leave in a clone that a new task's checkout would strand. An open PR is not here: its work is on
# origin, and a reopen brings its session back.
RETASK_BLOCKERS='["uncommitted-changes", "untracked-files", "stash-present", "unpushed-commits", "commits-without-pr",
  "local-only-files", "solutions-unpublished", "git-state-unknown"]'

# Usage: retask_parse_args <args...>; sets the RETASK_* inputs and LAUNCH_SCOPE, refusing bad ones before anything runs.
retask_parse_args() {
  local -a rest=()
  while (($#)); do
    case $1 in
      --task | --issue | --prompt-file)
        (($# >= 2)) && [[ -n $2 ]] || usage_fail "$1 needs a value" "$1"
        case $1 in
          --task) RETASK_TASK=$2 ;;
          --issue) RETASK_ISSUE=$2 ;;
          --prompt-file) RETASK_PROMPT=$2 ;;
        esac
        shift 2
        ;;
      --pr) usage_fail "retask takes no --pr: work on a PR starts with agent-slot launch --pr, which checks its head out" "$1" ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        rest+=("$1")
        shift
        ;;
    esac
  done
  ((${#rest[@]} == 1)) || usage_fail "retask takes one slot, <repo>/<N>" "${rest[*]}"
  RETASK_KEY=${rest[0]}
  [[ -n $RETASK_TASK || -n $RETASK_ISSUE ]] \
    || usage_fail "retask needs --task <name> or --issue <ref>, so the new session is named for its work"
  [[ -n $RETASK_PROMPT ]] || usage_fail "retask needs --prompt-file: the new session starts from a brief"
  [[ -z $RETASK_TASK || $RETASK_TASK =~ $TASK_PATTERN ]] \
    || contract_fail invalid-task-name "$TASK_RULE" --value "$RETASK_TASK" --command "agent-slot retask --help"
  [[ -f $RETASK_PROMPT && -r $RETASK_PROMPT ]] \
    || contract_fail prompt-file-unreadable "the first-message file cannot be read" --value "$RETASK_PROMPT" \
      --command "agent-slot retask --help"
  RETASK_PROMPT=$(realpath "$RETASK_PROMPT")
  launch_brief_check "$RETASK_PROMPT"
  LAUNCH_SCOPE=$(launch_brief_scope "$RETASK_PROMPT")
}

# The line that repeats this call, for an error's next step.
_retask_command() {
  local -a cmd=(agent-slot retask "$RETASK_KEY")
  [[ -z $RETASK_TASK ]] || cmd+=(--task "$RETASK_TASK")
  [[ -z $RETASK_ISSUE ]] || cmd+=(--issue "$RETASK_ISSUE")
  contract_quote "${cmd[@]}" --prompt-file "$RETASK_PROMPT"
}

# Usage: _retask_refuse_unfinished <repo> <n>; refuses with slot-work-unfinished when the check finds anything of
# RETASK_BLOCKERS in the slot. value holds the codes, and the check's own output says what each one is.
_retask_refuse_unfinished() {
  local found
  check_slot "$1" "$2"
  ((${#CHECK_BLOCKERS[@]} > 0)) || return 0
  found=$(printf '%s\n' "${CHECK_BLOCKERS[@]}" | contract_json -r -s --argjson codes "$RETASK_BLOCKERS" \
    '[.[].code] as $all | ($all - ($all - $codes)) | unique | join(" ")')
  [[ -n $found ]] || return 0
  contract_fail slot-work-unfinished "$RETASK_KEY still holds the old task's work, which a new task's checkout would \
strand: $found. Push it or drop it, or send this brief to a new slot with agent-slot launch" --value "$found" \
    --command "agent-slot check $RETASK_KEY --output json"
}

# Usage: _retask_checkout <path> <base>; puts the clone on origin's base and drops the old local branches. The check has
# already found each one pushed, and the retask ledger line names them. Fails before the record or Claude changes.
_retask_checkout() {
  local path=$1 base=$2 out branch
  contract_use_tools git
  if ! bounded out fetch 300 "${AS_GIT_REMOTE[@]}" git -C "$path" fetch -q origin "$base" \
    || ! bounded out checkout 900 "${AS_GIT_REMOTE[@]}" git -C "$path" checkout -q -B "$base" "origin/$base"; then
    contract_fail slot-checkout-failed "could not put $RETASK_KEY on origin/$base, so its Claude was not ended and \
nothing changed" --value "$base" --command "$(_retask_command)" --log "$BOUNDED_LOG"
  fi
  while IFS= read -r branch; do
    [[ -z $branch || $branch == "$base" ]] || git -C "$path" branch -q -D "$branch"
  done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/heads)
}

# Usage: cmd_retask; gives the slot RETASK_KEY names the new task. See the header for the order and why.
cmd_retask() {
  local repo n key path origin base session name items='[]' item now previous transcript branches copy
  require_tools tmux claude gh
  slot_parse_key "$RETASK_KEY"
  repo=$SLOT_REPO n=$SLOT_N key=$RETASK_KEY
  slot_taken "$repo" "$n" \
    || contract_fail slot-not-found "$key holds no slot" --value "$key" --command "agent-slot list"
  path=$(slot_path "$repo" "$n")
  name=$RETASK_TASK
  if [[ -n $RETASK_ISSUE ]]; then
    origin=$(git -C "$path" config --get remote.origin.url || true)
    item_parse_ref issue "$RETASK_ISSUE" "$origin"
    item_resolve
    item=$(contract_json -c '{kind, repo, number, title}' <<<"$ITEM")
    items="[$item]"
    name=$(item_name "$item")
    [[ -n $RETASK_TASK ]] || RETASK_TASK=$name
  fi
  check_inputs_load
  agentstate_load
  record_lock_slot "$repo" "$n" --wait 10 \
    || contract_fail slot-busy "another agent-slot process held $key for 10 s, so nothing changed" --value "$key" \
      --command "$(_retask_command)"
  record_read "$repo" "$n" \
    || contract_fail slot-not-found "$key has no record" --value "$key" --command "agent-slot list"
  REPO_PRIME=$(contract_json -r '.prime' <<<"$RECORD")
  launch_scope_check
  base=$(contract_json -r '.base // empty' <<<"$RECORD")
  AGENT_BUSY_COMMAND=$(_retask_command)
  agentstate_of "$repo" "$n"
  ! agentstate_inside_agent || _resume_model_refuse "$key"
  case $AGENT_STATE in
    idle | absent) ;;
    *) _resume_model_refuse "$key" ;;
  esac
  if [[ $AGENT_STATE == idle ]]; then
    local jobs
    jobs=$(agentstate_jobs)
    [[ -z $jobs ]] || _resume_model_refuse "$key" "$jobs"
  fi
  _retask_refuse_unfinished "$repo" "$n"
  # check_slot reads the record again under its own view; this retask works from the one the lock holds.
  record_read "$repo" "$n"
  branches=$(_teardown_branches "$path" "$base")
  transcript=$(sessions_record_transcript)
  previous=$RECORD
  [[ $AGENT_STATE != idle ]] || _resume_model_leave_mode "$repo" "$n"
  _retask_checkout "$path" "$base"

  copy=$(slot_prompt_file "$path")
  cp -- "$RETASK_PROMPT" "$copy"
  session=$(cat /proc/sys/kernel/random/uuid)
  now=$(contract_now)
  record_update "$repo" "$n" --arg session "$session" --arg task "$RETASK_TASK" --arg name "$name" --arg now "$now" \
    --arg prompt "$copy" --argjson items "$items" --argjson scope "$LAUNCH_SCOPE" '
    .prior_sessions = ((.prior_sessions // [])
      + [{session_id, task, name, prs, items: (.items // []), ended_at: $now}])
    | del(.release, .not_yet, .reminded_at, .closing_sent_at, .cleanup_sent_at)
    | . + {session_id: $session, task: $task, name: $name, named_as: $name, items: $items, prs: [], scope: $scope,
        prompt_file: $prompt, transcript: null, request_id: null, finished_by_operator: false, task_started_at: $now}'
  record_read "$repo" "$n"
  ledger_append retask "$(contract_json -c --argjson branches "$branches" --arg transcript "$transcript" \
    --arg next "$session" '
    {repo, slot, task, session_id, transcript: (if $transcript == "" then null else $transcript end), prs, request_id,
     items: (.items // []), name, head: null, branches: $branches, trash_entry: null, next_session_id: $next}' \
    <<<"$previous")"

  RESUME_MODEL=$(contract_json -r '.model // "opus"' <<<"$RECORD")
  _resume_model_restart "$repo" "$n"
  record_unlock_slot "$repo" "$n"
  contract_ok "$(contract_json -c --arg key "$key" --arg previous "$(contract_json -r '.session_id' <<<"$previous")" \
    '{key: $key, task, name, session_id, previous_session_id: $previous, items}' <<<"$RECORD")" '
    "\(.key): started a new session for \(.name), replacing \(.previous_session_id)"'
}
