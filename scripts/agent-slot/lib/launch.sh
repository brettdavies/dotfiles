# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# launch and resume.
#
# launch claims the lowest free slot number under the repo lock, then holds that slot's lock from the claim to its
# commit point: the slot's three tmux sessions exist and its record says active. Any failure before that point rolls
# the slot back on the way out. A launch that was killed leaves a setting-up record, which the next launch rolls back
# once it can take that slot's lock without waiting, which it can only after the owner died.

TASK_PATTERN='^[A-Za-z0-9][A-Za-z0-9_/-]{0,63}$'
TASK_RULE='a task name uses letters, digits, -, _, and /, starts with a letter or digit, and is at most 64 characters'
REQUEST_PATTERN='^[A-Za-z0-9._-]{1,128}$'

LAUNCH_REPO='' LAUNCH_TASK='' LAUNCH_REQUEST='' LAUNCH_PROMPT='' LAUNCH_REQUESTED_AT=''
LAUNCH_ARMED=

# Usage: launch_parse_args <args...>; sets the LAUNCH_* inputs, refusing bad ones before anything is touched.
launch_parse_args() {
  LAUNCH_REQUESTED_AT=''
  while (($#)); do
    case $1 in
      --task | --request-id | --prompt-file | --requested-at)
        (($# >= 2)) || usage_fail "$1 needs a value" "$1"
        case $1 in
          --task) LAUNCH_TASK=$2 ;;
          --request-id) LAUNCH_REQUEST=$2 ;;
          --prompt-file) LAUNCH_PROMPT=$2 ;;
          --requested-at) LAUNCH_REQUESTED_AT=$2 ;;
        esac
        shift 2
        ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        [[ -z $LAUNCH_REPO ]] || usage_fail "launch takes one repo" "$1"
        LAUNCH_REPO=$1
        shift
        ;;
    esac
  done
  [[ -n $LAUNCH_REPO ]] || usage_fail "launch needs a repo; agent-slot repos lists them"
  [[ -z $LAUNCH_TASK || $LAUNCH_TASK =~ $TASK_PATTERN ]] \
    || contract_fail invalid-task-name "$TASK_RULE" --value "$LAUNCH_TASK" --command "agent-slot launch --help"
  [[ -z $LAUNCH_REQUEST || $LAUNCH_REQUEST =~ $REQUEST_PATTERN ]] \
    || usage_fail "a request ID uses letters, digits, ., _, and -, up to 128 characters" "$LAUNCH_REQUEST"
  if [[ -n $LAUNCH_PROMPT ]]; then
    [[ -f $LAUNCH_PROMPT && -r $LAUNCH_PROMPT ]] \
      || contract_fail prompt-file-unreadable "the first-message file cannot be read" --value "$LAUNCH_PROMPT" \
        --command "agent-slot launch --help"
    LAUNCH_PROMPT=$(realpath "$LAUNCH_PROMPT")
  fi
  [[ -n $LAUNCH_REQUESTED_AT ]] || LAUNCH_REQUESTED_AT=$(date +%s.%N)
  [[ $LAUNCH_REQUESTED_AT =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    || usage_fail "--requested-at takes seconds since the epoch" "$LAUNCH_REQUESTED_AT"
}

# Usage: slot_rollback <repo> <n>
# Removes a slot whose setup never finished: its tmux sessions, its clone, and its claim. The caller holds the slot
# lock.
slot_rollback() {
  local repo=$1 n=$2 path base suffix out real
  path=$(slot_path "$repo" "$n")
  base=$(slot_session "$repo" "$n")
  for suffix in '' -files -git; do
    slot_tmux out 5 kill-session -t "=$base$suffix" || true
  done
  if [[ -e $path ]]; then
    real=$(realpath -m "$path")
    [[ $real == "$AS_ROOT_REAL"/*/* ]] || return 1
    bounded out trash 60 "$AS_TRASH" "$path" || return 1
  fi
  rm -f "$(slot_claim_file "$repo" "$n")"
}

_launch_rollback_on_exit() {
  [[ -n $LAUNCH_ARMED ]] || return 0
  slot_rollback "${LAUNCH_ARMED%/*}" "${LAUNCH_ARMED##*/}"
}

# Rolls back every setting-up slot of the repo whose launch has died. The caller holds the repo lock.
launch_reclaim_abandoned() {
  local repo=$1 n
  while read -r n; do
    if [[ -z $n ]] || ! record_read "$repo" "$n"; then continue; fi
    [[ $(contract_json -r '.state // ""' <<<"$RECORD") == setting-up ]] || continue
    record_lock_slot "$repo" "$n" --nowait || continue
    slot_rollback "$repo" "$n" || true
    record_unlock_slot "$repo" "$n"
  done < <(slot_numbers "$repo")
}

# Sets LAUNCH_EXISTING to the slot holding this request ID, or this task when one was given; returns 1 when none does.
LAUNCH_EXISTING=
launch_find_existing() {
  local repo=$1 n request task state
  LAUNCH_EXISTING=
  while read -r n; do
    if [[ -z $n ]] || ! record_read "$repo" "$n"; then continue; fi
    request=$(contract_json -r '.request_id // ""' <<<"$RECORD")
    task=$(contract_json -r '.task // ""' <<<"$RECORD")
    state=$(contract_json -r '.state // ""' <<<"$RECORD")
    if [[ -n $LAUNCH_REQUEST && $request == "$LAUNCH_REQUEST" ]] \
      || [[ -n $LAUNCH_TASK && $task == "$LAUNCH_TASK" && $state != tearing-down ]]; then
      LAUNCH_EXISTING=$n
      return 0
    fi
  done < <(slot_numbers "$repo")
  return 1
}

# Usage: launch_output <repo> <n> <created> [<trust-prompt-expected> <phases-json>]
launch_output() {
  local repo=$1 n=$2 created=$3 trust=${4:-false} phases=${5:-null}
  record_read "$repo" "$n" || RECORD='{}'
  contract_ok "$(contract_json -c --arg key "$(slot_key "$repo" "$n")" --arg path "$(slot_path "$repo" "$n")" \
    --argjson created "$created" --argjson trust "$trust" --argjson phases "$phases" --arg docs "$CONTRACT_DOCS" \
    --argjson missing "$(printf '%s\n' "${PARITY_MISSING_SIBLINGS[@]}" | contract_json -R -s -c 'split("\n") | map(select(. != ""))')" \
    '{created: $created, key: $key, repo: .repo, slot: .slot, path: $path, state: .state, task: .task,
      request_id: .request_id, session_id: .session_id, base: .base, trust_prompt_expected: $trust,
      missing_siblings: $missing, phases: $phases,
      next_step: {action: "run", command: "agent-slot-rex restore", docs: $docs,
                  note: "Rex opens this slot'"'"'s tab at the operator'"'"'s next launch or restore"}}' <<<"$RECORD")" '
    "\(.key) \(if .created then "is ready" else "already holds this request" end) at \(.path)" +
      (if .task then " (\(.task))" else "" end) +
      (if .trust_prompt_expected then "; Claude will ask to trust the folder" else "" end)'
}

_launch_us() { printf '%s' "${EPOCHREALTIME/./}"; }

cmd_launch() {
  local repo=$LAUNCH_REPO n live max=$AS_MAX_PER_REPO record path prompt_copy out trust=false
  local t_start t_clone t_setup t_trust t_tmux t_claude phases
  require_tools tmux claude trash
  repo_prime "$repo"

  mkdir -p "$AS_ROOT/$repo"
  record_lock_repo "$repo" 60 \
    || contract_fail slot-busy "another launch on $repo held its lock for 60 s" --value "$repo" \
      --command "agent-slot launch $repo${LAUNCH_REQUEST:+ --request-id $LAUNCH_REQUEST}"
  launch_reclaim_abandoned "$repo"
  if launch_find_existing "$repo"; then
    record_unlock_repo "$repo"
    launch_output "$repo" "$LAUNCH_EXISTING" false
    return
  fi
  live=$(slot_numbers "$repo" | grep -c . || true)
  if ((live >= max)); then
    contract_fail slot-limit-reached "$repo already has $live live slots, the limit per repo" \
      --value "$(slot_numbers "$repo" | sed "s|^|$repo/|" | paste -sd ' ')" \
      --command "AGENT_SLOT_MAX_PER_REPO=$((max + 1)) agent-slot launch $repo"
  fi
  n=1
  while slot_taken "$repo" "$n"; do n=$((n + 1)); done
  record_lock_slot "$repo" "$n" --nowait \
    || contract_fail slot-busy "$(slot_key "$repo" "$n") is locked by another process" --value "$(slot_key "$repo" "$n")" \
      --command "agent-slot launch $repo${LAUNCH_REQUEST:+ --request-id $LAUNCH_REQUEST}"
  path=$(slot_path "$repo" "$n")
  record=$(contract_json -n -c --arg repo "$repo" --argjson n "$n" --arg prime "$REPO_PRIME" \
    --arg task "$LAUNCH_TASK" --arg request "$LAUNCH_REQUEST" --argjson requested "$LAUNCH_REQUESTED_AT" \
    --arg session "$(cat /proc/sys/kernel/random/uuid)" --arg now "$(contract_now)" \
    '{repo: $repo, slot: $n, state: "setting-up", task: (if $task == "" then null else $task end),
      request_id: (if $request == "" then null else $request end), requested_at: $requested, prime: $prime,
      base: null, session_id: $session, transcript: null, prompt_file: null, prs: [], finished_by_operator: false,
      created_at: $now}')
  record_write "$repo" "$n" "$record"
  LAUNCH_ARMED=$repo/$n
  contract_on_exit _launch_rollback_on_exit
  record_unlock_repo "$repo"

  t_start=$(_launch_us)
  contract_use_tools git
  if ! bounded out clone 900 /usr/bin/env GIT_SSH_COMMAND='ssh -o BatchMode=yes' GIT_TERMINAL_PROMPT=0 \
    git clone -q --reference-if-able "$REPO_PRIME" --dissociate "$REPO_ORIGIN" "$path"; then
    contract_fail clone-failed "git clone of $REPO_ORIGIN failed" --value "$REPO_ORIGIN" --side-effects none \
      --command "agent-slot launch $repo${LAUNCH_REQUEST:+ --request-id $LAUNCH_REQUEST}" --log "$BOUNDED_LOG"
  fi
  record_write "$repo" "$n" "$record"
  t_clone=$(_launch_us)

  contract_use_tools git git-crypt
  parity_checkout_base "$path"
  parity_git_crypt "$path"
  parity_hooks "$REPO_PRIME" "$path"
  parity_solutions "$path"
  parity_claude_settings "$REPO_PRIME" "$path"
  parity_siblings "$repo" "$path"
  prompt_copy=$path/.git/agent-slot-prompt.md
  if [[ -n $LAUNCH_PROMPT ]]; then
    cp "$LAUNCH_PROMPT" "$prompt_copy"
  fi
  record_update "$repo" "$n" --arg base "$PARITY_BASE" --argjson prompt "$([[ -n $LAUNCH_PROMPT ]] && echo true || echo false)" \
    --arg file "$prompt_copy" '.base = $base | .prompt_file = (if $prompt then $file else null end)'
  t_setup=$(_launch_us)

  contract_use_tools tmux claude
  if ! trust_known "$path" && ! trust_accept "$path"; then
    trust=true
    record_update "$repo" "$n" '.trust_prompt_expected = true'
  fi
  t_trust=$(_launch_us)

  record_read "$repo" "$n"
  sessions_start "$repo" "$n" launch
  t_tmux=$(_launch_us)
  record_update "$repo" "$n" '.state = "active"'
  LAUNCH_ARMED=
  record_unlock_slot "$repo" "$n"
  t_claude=$(_launch_us)

  phases=$(contract_json -n -c --argjson a "$t_start" --argjson b "$t_clone" --argjson c "$t_setup" \
    --argjson d "$t_trust" --argjson e "$t_tmux" --argjson f "$t_claude" \
    '{clone: (($b - $a) / 1000000), setup: (($c - $b) / 1000000), trust: (($d - $c) / 1000000),
      tmux: (($e - $d) / 1000000), claude: (($f - $e) / 1000000)}')
  record_read "$repo" "$n"
  ledger_append launch "$(contract_json -c --argjson phases "$phases" --argjson trust "$trust" --arg path "$path" \
    '{request_id, requested_at, repo, slot, path: $path, task, session_id, created: true,
      trust_prompt_expected: $trust, phases: $phases}' <<<"$RECORD")"
  launch_output "$repo" "$n" true "$trust" "$phases"
}

# Usage: slot_parse_key <repo>/<n>; sets SLOT_REPO and SLOT_N, or fails with usage.
SLOT_REPO='' SLOT_N=''
slot_parse_key() {
  if [[ $1 =~ ^([A-Za-z0-9._-]+)/([0-9]+)$ ]]; then
    SLOT_REPO=${BASH_REMATCH[1]} SLOT_N=${BASH_REMATCH[2]}
  else
    usage_fail "a slot is named <repo>/<N>, such as dotfiles/2" "$1"
  fi
}

cmd_resume() {
  local repo n state
  slot_parse_key "$1"
  repo=$SLOT_REPO n=$SLOT_N
  require_tools tmux claude
  slot_taken "$repo" "$n" \
    || contract_fail slot-not-found "$1 holds no slot" --value "$1" --command "agent-slot list"
  record_lock_slot "$repo" "$n" --wait "$AS_LOCK_WAIT" \
    || contract_fail slot-busy "$1 stayed locked for $AS_LOCK_WAIT s" --value "$1" --command "agent-slot resume $1"
  record_read "$repo" "$n" || contract_fail slot-not-found "$1 has no record" --value "$1" --command "agent-slot list"
  state=$(contract_json -r '.state // ""' <<<"$RECORD")
  [[ $state == active ]] || contract_fail slot-busy "$1 is $state" --value "$1" --command "agent-slot resume $1"
  sessions_start "$repo" "$n" resume
  record_unlock_slot "$repo" "$n"
  contract_ok "$(printf '%s\n' "${SESSIONS_CREATED[@]}" | contract_json -R -s -c --arg key "$1" \
    '{key: $key, started: split("\n") | map(select(. != ""))}')" \
    '"\(.key): " + (if (.started | length) == 0 then "every session was already running" else "started \(.started | join(", "))" end)'
}
