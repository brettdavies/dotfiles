# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# The slot maker: a fresh slot of a repo, cloned, set up like the prime checkout, and running its sessions.
#
# It claims the lowest free slot number under the repo lock, then holds that slot's lock from the claim to its commit
# point: the slot's three tmux sessions exist and its record says active. Any failure before that point rolls the slot
# back on the way out, and nothing after the sessions start can fail but the record's state update, so a rollback never
# discards an agent's turn. A maker that was killed leaves a setting-up record, which the next one rolls back once it
# can take that slot's lock without waiting, which it can only after the owner died.

SLOT_ARMED=
SLOT_MADE='' SLOT_MADE_TRUST=false SLOT_MADE_PHASES=null

# Usage: slot_rollback <repo> <n>
# Removes a slot whose setup never finished: its tmux sessions, its clone, and its claim. The caller holds the slot
# lock.
slot_rollback() {
  local repo=$1 n=$2 path kind out real
  path=$(slot_path "$repo" "$n")
  for kind in "${SLOT_SESSION_KINDS[@]}"; do
    slot_tmux out 5 kill-session -t "=$(slot_session "$repo" "$n" "$kind")" || true
  done
  if [[ -e $path ]]; then
    real=$(realpath -m "$path")
    [[ $real == "$AS_ROOT_REAL"/*/* ]] || return 1
    bounded out trash 60 "$AS_TRASH" "$path" || return 1
  fi
  rm -f "$(slot_claim_file "$repo" "$n")"
}

_slot_rollback_on_exit() {
  [[ -n $SLOT_ARMED ]] || return 0
  slot_rollback "${SLOT_ARMED%/*}" "${SLOT_ARMED##*/}"
}

# Rolls back every setting-up slot of the repo whose maker has died. The caller holds the repo lock.
slot_reclaim_abandoned() {
  local repo=$1 n
  while read -r n; do
    if [[ -z $n ]] || ! record_read "$repo" "$n"; then continue; fi
    [[ $(contract_json -r '.state // ""' <<<"$RECORD") == setting-up ]] || continue
    record_lock_slot "$repo" "$n" --nowait || continue
    if ! record_read "$repo" "$n" || [[ $(contract_json -r '.state // ""' <<<"$RECORD") == setting-up ]]; then
      slot_rollback "$repo" "$n" || true
    fi
    record_unlock_slot "$repo" "$n"
  done < <(slot_numbers "$repo")
}

_slot_us() { printf '%s' "${EPOCHREALTIME/./}"; }

# Usage: slot_prompt_file <slot path>; prints where a slot keeps the first message it was made with.
slot_prompt_file() { printf '%s/.git/agent-slot-prompt.md' "$1"; }

# Usage: slot_make <repo> <event> <command> <seed> <prompt file> <launch | resume> [<head step>]
# Makes a slot of the repo whose prime repo_prime set, from under the repo lock the caller holds and releases here. The
# record is a setting-up record with a fresh session ID and the JSON object <seed> merged over it; <prompt file>, when
# not empty, is copied into the slot as Claude's first message; and the sessions start in the given mode. The head
# step, a function given the slot's path, runs right after the base checkout, so the tree it leaves is the one parity
# unlocks and scans. The <event> ledger line, the Rex push, and SLOT_MADE (the slot number), SLOT_MADE_TRUST, and
# SLOT_MADE_PHASES follow. <command> is the verb's command line without --request-id, which an error's next step
# retries with the seed's request ID.
slot_make() {
  local repo=$1 event=$2 command=$3 seed=$4 prompt=$5 mode=$6 head=${7:-} retry n live max=$AS_MAX_PER_REPO initial
  local path prompt_copy out trust=false filter t_start t_clone t_setup t_trust t_tmux t_claude phases request
  request=$(contract_json -r '.request_id // ""' <<<"$seed")
  retry=$command${request:+ --request-id $request}
  live=$(slot_numbers "$repo" | grep -c . || true)
  if ((live >= max)); then
    contract_fail slot-limit-reached "$repo already has $live live slots, the limit per repo" \
      --value "$(slot_numbers "$repo" | sed "s|^|$repo/|" | paste -sd ' ')" \
      --command "AGENT_SLOT_MAX_PER_REPO=$((max + 1)) $command"
  fi
  n=1
  while slot_taken "$repo" "$n"; do n=$((n + 1)); done
  record_lock_slot "$repo" "$n" --nowait \
    || contract_fail slot-busy "$(slot_key "$repo" "$n") is locked by another process" --value "$(slot_key "$repo" "$n")" \
      --command "$retry"
  path=$(slot_path "$repo" "$n")
  initial=$(contract_json -n -c --arg repo "$repo" --argjson n "$n" --arg prime "$REPO_PRIME" --argjson seed "$seed" \
    --arg session "$(cat /proc/sys/kernel/random/uuid)" --arg now "$(contract_now)" \
    '{repo: $repo, slot: $n, state: "setting-up", task: null, request_id: null, requested_at: null, prime: $prime,
      base: null, session_id: $session, transcript: null, prompt_file: null, prs: [], finished_by_operator: false,
      created_at: $now} + $seed')
  record_write "$repo" "$n" "$initial"
  SLOT_ARMED=$repo/$n
  contract_on_exit _slot_rollback_on_exit
  record_unlock_repo "$repo"

  t_start=$(_slot_us)
  contract_use_tools git
  # A partial prime lacks blobs its refs reach, so origin's thin pack can hold deltas against bases the reference cannot
  # supply. Cloning with the prime's own filter leaves those blobs out of the pack, as they are out of the prime.
  filter=$(git -C "$REPO_PRIME" config --get remote.origin.partialclonefilter || true)
  if ! bounded out clone 900 /usr/bin/env GIT_SSH_COMMAND='ssh -o BatchMode=yes' GIT_TERMINAL_PROMPT=0 \
    git clone -q --reference-if-able "$REPO_PRIME" --dissociate ${filter:+"--filter=$filter"} "$REPO_ORIGIN" "$path"; then
    contract_fail clone-failed "git clone of $REPO_ORIGIN failed" --value "$REPO_ORIGIN" --side-effects none \
      --command "$retry" --log "$BOUNDED_LOG"
  fi
  record_write "$repo" "$n" "$initial"
  t_clone=$(_slot_us)

  contract_use_tools git git-crypt
  parity_base "$path"
  # In a partial clone the checkout fetches the base's blobs from origin, so it is bounded as the clone is.
  if [[ $(git -C "$path" symbolic-ref --short HEAD) != "$PARITY_BASE" ]] \
    && ! bounded out checkout 900 /usr/bin/env GIT_SSH_COMMAND='ssh -o BatchMode=yes' GIT_TERMINAL_PROMPT=0 \
      git -C "$path" checkout -q -B "$PARITY_BASE" "origin/$PARITY_BASE"; then
    contract_fail clone-failed "checking out $PARITY_BASE in the new clone failed" --value "$PARITY_BASE" \
      --side-effects none --command "$retry" --log "$BOUNDED_LOG"
  fi
  [[ -z $head ]] || "$head" "$path"
  parity_git_crypt "$path"
  parity_hooks "$REPO_PRIME" "$path"
  parity_solutions "$path"
  parity_claude_settings "$REPO_PRIME" "$path"
  parity_siblings "$repo" "$path"
  prompt_copy=$(slot_prompt_file "$path")
  if [[ -n $prompt ]]; then
    cp "$prompt" "$prompt_copy"
  fi
  record_update "$repo" "$n" --arg base "$PARITY_BASE" --argjson prompt "$([[ -n $prompt ]] && echo true || echo false)" \
    --arg file "$prompt_copy" '.base = $base | .prompt_file = (if $prompt then $file else null end)'
  t_setup=$(_slot_us)

  contract_use_tools tmux claude
  if ! trust_known "$path" && ! { trust_known "$REPO_PRIME" && trust_accept "$path"; }; then
    trust=true
    record_update "$repo" "$n" '.trust_prompt_expected = true'
  fi
  t_trust=$(_slot_us)

  record_read "$repo" "$n"
  sessions_start "$repo" "$n" "$mode"
  t_tmux=$(_slot_us)
  record_update "$repo" "$n" '.state = "active"'
  SLOT_ARMED=
  record_unlock_slot "$repo" "$n"
  t_claude=$(_slot_us)

  phases=$(contract_json -n -c --argjson a "$t_start" --argjson b "$t_clone" --argjson c "$t_setup" \
    --argjson d "$t_trust" --argjson e "$t_tmux" --argjson f "$t_claude" \
    '{clone: (($b - $a) / 1000000), setup: (($c - $b) / 1000000), trust: (($d - $c) / 1000000),
      tmux: (($e - $d) / 1000000), claude: (($f - $e) / 1000000)}')
  record_read "$repo" "$n"
  ledger_append "$event" "$(contract_json -c --argjson phases "$phases" --argjson trust "$trust" --arg path "$path" \
    '{request_id, requested_at, repo, slot, path: $path, task, session_id, created: true,
      trust_prompt_expected: $trust, phases: $phases, items: (.items // []), name}' <<<"$RECORD")"
  push_clients "$event" "$(slot_key "$repo" "$n")"
  SLOT_MADE=$n SLOT_MADE_TRUST=$trust SLOT_MADE_PHASES=$phases
}
