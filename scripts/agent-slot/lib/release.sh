# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# The release: a slot's agent hands its own teardown upstream as its last step. A slot cannot delete itself from inside,
# since its agent is mid-turn and the slot is that agent's working directory, so release deletes nothing. It refuses
# until this slot's Claude sessions have run both closing skills, and while the slot's Claude still runs a Bash tool
# command other than release's own: Claude Code lists a session with a live background shell as busy, so a job left
# running holds the teardown back for as long as it runs. Then it records the request in the slot's record and the
# ledger, and starts `agent-slot finish <key> --yes --when-idle` in a session of its own. That finish runs from /, with
# the slot pane's tmux variables and every inherited descriptor dropped, so it sits outside the slot's process tree and
# holds nothing under the slot. It waits for the agent to go idle, then runs the same fail-closed finish the operator
# does. A slot whose task has not finished stays requested, and the automatic sweep tears it down once it has.
#
# An agent still waiting on something, such as CI or a release chain, does not stop it to pass release's check: it runs
# `release --not-yet WHY` instead, which releases nothing and records why for the automatic sweep (autosweep.sh).
#
# teardown.log in the state directory gets one JSON line per release request, refusal, and --not-yet, per finish --yes,
# and per sweep --yes pass: what ran it, the slots it tore down, and why it kept or refused the rest.

RELEASE_SKILLS='ce-compound ce-compound-refresh'
RELEASE_COMPOUND='/compound-engineering:ce-compound mode:non-interactive depth:full <the finding, from this session only>'
RELEASE_REFRESH='/compound-engineering:ce-compound-refresh <scope> mode:non-interactive'
RELEASE_COMMAND='agent-slot release --output json'
RELEASE_NOT_YET="agent-slot release --not-yet '<why>' --output json"
RELEASE_CLEANUP="delete the scratch files you made (local config, test output, tool logs), and commit and PR anything \
that is real work"
RELEASE_WAITING="If you are still waiting on something, such as CI or a release chain, never stop it to pass release's \
check: say what with $RELEASE_NOT_YET, and release when it is done."
# One line, since tmux types it into the agent's prompt and an Enter submits it.
RELEASE_CLOSING="Your task has finished, so close it out now, in this order: run $RELEASE_COMPOUND once per finding \
from this session, and once even when none qualifies; then run $RELEASE_REFRESH across every refresh opportunity those \
runs surfaced, or scoped to the area you touched; then $RELEASE_CLEANUP; then stop every background job you no \
longer need; then run $RELEASE_COMMAND; then report what you did and stop. $RELEASE_WAITING"
RELEASE_FOUND=()
RELEASE_MISSING=()
RELEASE_PID=

# Usage: teardown_log <event> <json-object>; one line in teardown.log.
teardown_log() {
  local line
  line=$(contract_json -c --arg at "$(contract_now)" --arg event "$1" '{at: $at, event: $event} + .' <<<"$2") \
    || return 0
  contract_log_line "$AS_STATE_DIR/teardown.log" "$line"
}

# Usage: release_transcripts <repo> <n>; prints the transcript of every Claude session this slot's task has had: the
# ledger's session lines since the slot was made, and the record's own.
release_transcripts() {
  local since
  since=$(contract_json -r '.created_at // ""' <<<"$RECORD")
  {
    [[ ! -r $AS_LEDGER ]] || contract_json -r --arg repo "$1" --argjson n "$2" --arg since "$since" '
      select(.event == "session" and .repo == $repo and .slot == $n and .ts >= $since) | .transcript // empty' \
      "$AS_LEDGER"
    contract_json -r '.transcript // empty' <<<"$RECORD"
  } | sort -u
}

# Usage: release_skills_in <transcript>; prints the name of each skill the session ran, without its plugin prefix: a
# Skill tool call of the agent's, or a slash command typed as a prompt. Text inside a tool's result never counts, so a
# session that read a file quoting a skill's name is not taken for one that ran it.
release_skills_in() {
  contract_json -r -R '(fromjson? // empty)
    | if .type == "assistant" then
        (.message.content[]? | select(type == "object" and .type == "tool_use" and .name == "Skill")
         | .input.skill // empty)
      elif .type == "user" and (.message.content | type) == "string" then
        (.message.content | capture("<command-name>/?(?<s>[^<]+)</command-name>") | .s)
      else empty end
    | sub("^.*:"; "")' "$1" || true
}

# Usage: release_gate <repo> <n>; sets RELEASE_FOUND and RELEASE_MISSING from RELEASE_SKILLS.
release_gate() {
  local transcript skill found=''
  while read -r transcript; do
    [[ -n $transcript && -r $transcript ]] || continue
    found+=$'\n'$(release_skills_in "$transcript")
  done < <(release_transcripts "$1" "$2")
  RELEASE_FOUND=() RELEASE_MISSING=()
  for skill in $RELEASE_SKILLS; do
    if grep -qxF "$skill" <<<"$found"; then RELEASE_FOUND+=("$skill"); else RELEASE_MISSING+=("$skill"); fi
  done
}

# Usage: release_jobs_gate <key>; after agentstate_of, refuses while the slot's Claude still runs a Bash tool command
# other than the one release runs in, naming each.
release_jobs_gate() {
  local jobs count
  jobs=$(agentstate_jobs)
  [[ -n $jobs ]] || return 0
  count=$(grep -c . <<<"$jobs")
  teardown_log release "$(contract_json -R -s -c --arg key "$1" '{key: $key, result: "refused",
    reason: "background-jobs-running", jobs: (split("\n") | map(select(. != "")
      | capture("^(?<pid>[0-9]+) (?<command>.*)$") | .pid |= tonumber))}' <<<"$jobs")"
  contract_fail background-jobs-running "this slot's Claude still runs $(_check_plural "$count" "background job") \
(PID $(cut -d' ' -f1 <<<"$jobs" | paste -sd ' '); value names each command). Stop each one you no longer need, then \
run $RELEASE_COMMAND again. If you are still waiting on one, leave it running and do not release yet: say what with \
$RELEASE_NOT_YET, and release once it is done" --value "$jobs" --command "$RELEASE_COMMAND"
}

# Usage: release_not_yet <repo> <n> <key>; records RELEASE_WHY as the reason the slot is not ready to release.
release_not_yet() {
  local at why=${RELEASE_WHY//[$'\n\t']/ }
  at=$(contract_now)
  record_update "$1" "$2" --arg why "$why" --arg at "$at" '.not_yet = {why: $why, at: $at}' \
    || contract_fail slot-busy "$3 stayed locked, so why it is not ready was not recorded" --value "$3" \
      --command "$RELEASE_NOT_YET"
  teardown_log release "$(contract_json -n -c --arg key "$3" --arg why "$why" \
    '{key: $key, result: "not-yet", why: $why}')"
  contract_ok "$(contract_json -n -c --arg key "$3" --arg why "$why" --arg at "$at" \
    '{key: $key, not_yet: {why: $why, at: $at}}')" \
    '"\(.key): not released, since \(.not_yet.why); the automatic sweep reminds you later rather than listing the slot"'
}

# Usage: release_runner_alive <pid> <key>; true while that PID is the finish a release of the slot started.
release_runner_alive() {
  [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null \
    && tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -qF "finish $2 --yes --when-idle"
}

# Usage: release_start_runner <key>; sets RELEASE_PID. In a shell without job control a background job does not lead
# its process group, so setsid makes the job itself a session leader, and $! is the finish's own PID.
release_start_runner() {
  local key=$1 log fd
  log=$AS_LOG_DIR/release-${key//\//-}.log
  mkdir -p "$AS_LOG_DIR"
  (
    cd /
    for fd in /proc/"$BASHPID"/fd/*; do
      fd=${fd##*/}
      ((fd <= 2)) || eval "exec $fd>&-" 2>/dev/null || true
    done
    exec env -u TMUX -u TMUX_PANE AGENT_SLOT_PUSH_WAIT=1 setsid "$AS_HOME/agent-slot" finish "$key" --yes --when-idle \
      --output json
  ) </dev/null >>"$log" 2>&1 &
  RELEASE_PID=$!
}

cmd_release() {
  local at repo n key requested pid skills
  at=$(slot_at "$PWD") || at=''
  [[ -z $at ]] || read -r repo n <<<"$at"
  if [[ -z $at ]] || ! record_read "$repo" "$n"; then
    contract_fail not-in-slot "$PWD is not inside a slot under $AS_ROOT; release runs from inside the slot it releases" \
      --value "$PWD" --command "agent-slot whoami"
  fi
  key=$(slot_key "$repo" "$n")
  if [[ -n ${RELEASE_WHY:-} ]]; then
    release_not_yet "$repo" "$n" "$key"
    return
  fi
  command -v setsid >/dev/null || contract_fail dependency-missing "setsid is not installed on this server" \
    --value setsid --command "sudo apt-get install util-linux"
  release_gate "$repo" "$n"
  skills=$(printf '%s\n' "${RELEASE_FOUND[@]}" | contract_json -R -s -c 'split("\n") | map(select(. != ""))')
  if ((${#RELEASE_MISSING[@]} > 0)); then
    teardown_log release "$(printf '%s\n' "${RELEASE_MISSING[@]}" | contract_json -R -s -c --arg key "$key" \
      '{key: $key, result: "refused", reason: "compound-not-run", missing: split("\n") | map(select(. != ""))}')"
    contract_fail compound-not-run "this slot's Claude session has not run ${RELEASE_MISSING[*]}; close out by running \
$RELEASE_COMPOUND once per finding, then $RELEASE_REFRESH, then $RELEASE_COMMAND" --value "${RELEASE_MISSING[*]}" \
      --command "$([[ ${RELEASE_MISSING[0]} == ce-compound ]] && printf '%s' "$RELEASE_COMPOUND" \
        || printf '%s' "$RELEASE_REFRESH")"
  fi
  agentstate_load
  agentstate_of "$repo" "$n"
  release_jobs_gate "$key"

  pid=$(contract_json -r '.release.runner_pid // ""' <<<"$RECORD")
  if [[ -n $pid ]] && release_runner_alive "$pid" "$key"; then
    contract_ok "$(contract_json -c --arg key "$key" --argjson skills "$skills" \
      '{key: $key, requested_at: .release.requested_at, runner_pid: .release.runner_pid, skills: $skills,
        already_requested: true}' <<<"$RECORD")" '"\(.key): already released; its teardown (pid \(.runner_pid)) waits"'
    return
  fi
  requested=$(contract_now)
  record_update "$repo" "$n" --arg at "$requested" \
    '.release = {requested_at: $at, session_id: .session_id} | del(.not_yet)' \
    || contract_fail slot-busy "$key stayed locked, so its release was not recorded" --value "$key" \
      --command "$RELEASE_COMMAND"
  ledger_append release "$(contract_json -c --argjson skills "$skills" \
    '{repo, slot, task, session_id, transcript, skills: $skills}' <<<"$RECORD")"
  release_start_runner "$key"
  record_update "$repo" "$n" --argjson pid "$RELEASE_PID" '.release.runner_pid = $pid' || true
  teardown_log release "$(contract_json -n -c --arg key "$key" --argjson pid "$RELEASE_PID" \
    '{key: $key, result: "requested", runner_pid: $pid}')"
  contract_ok "$(contract_json -n -c --arg key "$key" --arg at "$requested" --argjson pid "$RELEASE_PID" \
    --argjson skills "$skills" '{key: $key, requested_at: $at, runner_pid: $pid, skills: $skills,
      already_requested: false}')" \
    '"\(.key): released; it is torn down once you are idle and its task has finished, unless something in it would be lost"'
}

# Usage: release_wait_idle <repo> <n>; waits up to AS_RELEASE_WAIT seconds for the slot's agent to be idle or absent,
# setting RELEASE_WAITED to the seconds it waited. Returns 1 when the agent is still busy, waiting, or unknown.
RELEASE_WAITED=0
release_wait_idle() {
  local start=$SECONDS
  while true; do
    agentstate_load
    agentstate_of "$1" "$2"
    RELEASE_WAITED=$((SECONDS - start))
    [[ $AGENT_STATE != idle && $AGENT_STATE != absent ]] || return 0
    ((RELEASE_WAITED < AS_RELEASE_WAIT)) || return 1
    sleep "$AS_RELEASE_POLL"
  done
}
