# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# The release: a slot's agent hands its own teardown upstream as its last step. A slot cannot delete itself from inside,
# since its agent is mid-turn and the slot is that agent's working directory, so release deletes nothing. It refuses
# until this slot's Claude sessions have run both closing skills, records the request in the slot's record and the
# ledger, and starts `agent-slot finish <key> --yes --when-idle` in a session of its own. That finish runs from /, with
# the slot pane's tmux variables and every inherited descriptor dropped, so it sits outside the slot's process tree and
# holds nothing under the slot. It waits for the agent to go idle, then runs the same fail-closed finish the operator
# does. A slot whose task has not finished stays requested, and the automatic sweep tears it down once it has.
#
# The automatic sweep (`sweep --yes --auto`, which agent-slot-sweep.timer runs) tears down only a slot its agent
# released or the operator finished, so no slot disappears before its learnings are recorded. A finished slot that is
# neither keeps its clone: an idle agent is typed its closing steps once, and a slot whose agent is gone, or that its
# agent did not release after those steps, joins the needs-you list as not-released.
#
# teardown.log in the state directory gets one JSON line per release request, per finish --yes, and per sweep --yes
# pass: what ran it, the slots it tore down, and why it kept or refused the rest.

RELEASE_SKILLS='ce-compound ce-compound-refresh'
RELEASE_COMPOUND='/compound-engineering:ce-compound mode:non-interactive depth:full <the finding, from this session only>'
RELEASE_REFRESH='/compound-engineering:ce-compound-refresh <scope> mode:non-interactive'
RELEASE_COMMAND='agent-slot release --output json'
# One line, since tmux types it into the agent's prompt and an Enter submits it.
RELEASE_CLOSING="Your task has finished, so close it out now, in this order: run $RELEASE_COMPOUND once per finding \
from this session, and once even when none qualifies; then run $RELEASE_REFRESH across every refresh opportunity those \
runs surfaced, or scoped to the area you touched; then run $RELEASE_COMMAND; then report what you did and stop."
RELEASE_FOUND=()
RELEASE_MISSING=()
RELEASE_PID=
RELEASE_AUTO=

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

  pid=$(contract_json -r '.release.runner_pid // ""' <<<"$RECORD")
  if [[ -n $pid ]] && release_runner_alive "$pid" "$key"; then
    contract_ok "$(contract_json -c --arg key "$key" --argjson skills "$skills" \
      '{key: $key, requested_at: .release.requested_at, runner_pid: .release.runner_pid, skills: $skills,
        already_requested: true}' <<<"$RECORD")" '"\(.key): already released; its teardown (pid \(.runner_pid)) waits"'
    return
  fi
  requested=$(contract_now)
  record_update "$repo" "$n" --arg at "$requested" '.release = {requested_at: $at, session_id: .session_id}' \
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

# Usage: release_send_closing <repo> <n>; types the closing steps into the slot's Claude session and records when.
release_send_closing() {
  local name out
  name=$(slot_session "$1" "$2")
  slot_tmux out 10 send-keys -t "=$name:" -l "$RELEASE_CLOSING" || return 1
  slot_tmux out 10 send-keys -t "=$name:" Enter || return 1
  record_update "$1" "$2" --arg at "$(contract_now)" '.closing_sent_at = $at'
}

# Usage: release_auto_gate <repo> <n>; for the automatic sweep, after check_slot. Keeps a slot check would let go when
# neither its agent released it nor the operator finished it, setting RELEASE_AUTO to closing-sent or not-released.
release_auto_gate() {
  local repo=$1 n=$2 sent why blocker
  RELEASE_AUTO=
  [[ $(contract_json -r .teardown <<<"$CHECK_VERDICT") == true ]] || return 0
  ! contract_json -e '.release != null or .finished_by_operator == true' <<<"$RECORD" >/dev/null || return 0
  sent=$(contract_json -r '.closing_sent_at // ""' <<<"$RECORD")
  if [[ $AGENT_STATE == idle && -z $sent ]] && release_send_closing "$repo" "$n"; then
    RELEASE_AUTO=closing-sent
    CHECK_VERDICT=$(contract_json -c '.teardown = false' <<<"$CHECK_VERDICT")
    return 0
  fi
  if [[ $AGENT_STATE == absent ]]; then
    why="its agent is gone, so nothing will release it; finish it with agent-slot finish $(slot_key "$repo" "$n") --yes"
  elif [[ -n $sent ]]; then
    why="its agent was sent the closing steps at $sent and has not released it"
  else
    why="its closing steps could not be typed into its Claude session"
  fi
  CHECK_BLOCKERS=()
  _check_block not-released "the task has finished, but $why"
  blocker=${CHECK_BLOCKERS[0]}
  RELEASE_AUTO=not-released
  CHECK_VERDICT=$(contract_json -c --argjson b "$blocker" \
    '.teardown = false | .blockers += [$b] | .needs_you += [$b]' <<<"$CHECK_VERDICT")
}
