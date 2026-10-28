# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The push to the Rex clients. After a launch makes a slot, and after a sweep or finish tears one down, each Mac in
# AGENT_SLOT_REX_CLIENTS is asked over ssh to run `agent-slot-rex restore --by push`, so its tabs follow the server with
# no key press. A push runs in the background and never changes the verb's result or exit code. A Mac that is asleep or
# off the network is given up on after the connect timeout; its follow loop restores once it is back. The Mac whose
# helper ran the verb names itself in AGENT_SLOT_REX_CLIENT and is skipped, since that helper reconciles right after.
#
# Each client gets one JSON line in $AS_STATE_DIR/push.log: when the push began, the verb and the slots it made or tore
# down, the client, the result, ssh's exit code, how long the push took, and the last line ssh printed when it failed.
# The result is one of:
#
#   restored        ssh reached the Mac and its restore succeeded
#   restore-failed  ssh reached the Mac and its restore failed
#   unreachable     ssh did not reach the Mac (exit 255)
#   timed-out       the push outlived AGENT_SLOT_PUSH_TIMEOUT seconds
#   skipped         the Mac's own helper ran the verb
#
# A verb nothing waits on, such as the timer's sweep or a release's finish, sets AGENT_SLOT_PUSH_WAIT=1 and waits for
# its pushes before it exits, since systemd ends whatever a oneshot unit leaves running.

# The Mac's shell expands the tilde.
# shellcheck disable=SC2088
PUSH_REMOTE='~/.local/bin/agent-slot-rex restore --by push --output json'

PUSH_PIDS=()

# Usage: push_clients <verb> <key...>
push_clients() {
  local verb=$1 client clients
  shift
  read -r -a clients <<<"$AS_REX_CLIENTS"
  for client in "${clients[@]}"; do
    if [[ $client == "${AGENT_SLOT_REX_CLIENT:-}" ]]; then
      _push_log "$(contract_now)" "$verb" "$client" skipped null 0 '' "$@"
      continue
    fi
    _push_one "$verb" "$client" "$@" </dev/null >/dev/null 2>&1 &
    PUSH_PIDS+=("$!")
  done
  [[ ${AGENT_SLOT_PUSH_WAIT:-0} != 1 ]] || contract_on_exit push_wait
}

push_wait() {
  ((${#PUSH_PIDS[@]} == 0)) || wait "${PUSH_PIDS[@]}" 2>/dev/null || true
}

# Usage: _push_one <verb> <client> <key...>; runs in the background, after the verb may already have exited.
_push_one() {
  local verb=$1 client=$2 at start err status=0 result detail
  shift 2
  CONTRACT_NOISE=/dev/null
  at=$(contract_now) start=$(contract_ms)
  err=$(mktemp)
  timeout --kill-after=2 "$AS_PUSH_TIMEOUT" "${AS_SSH:-ssh}" -n -o BatchMode=yes \
    -o ConnectTimeout="$AS_PUSH_CONNECT_TIMEOUT" "$client" "$PUSH_REMOTE" </dev/null >/dev/null 2>"$err" || status=$?
  detail=$(grep . "$err" | tail -1 | cut -c 1-200 || true)
  rm -f "$err"
  case $status in
    0) result=restored detail='' ;;
    255) result=unreachable ;;
    124 | 137) result=timed-out ;;
    *) result=restore-failed ;;
  esac
  _push_log "$at" "$verb" "$client" "$result" "$status" "$(($(contract_ms) - start))" "$detail" "$@"
}

# Usage: _push_log <at> <verb> <client> <result> <exit|null> <ms> <detail> <key...>
_push_log() {
  local at=$1 verb=$2 client=$3 result=$4 code=$5 ms=$6 detail=$7 line
  shift 7
  line=$(printf '%s\n' "$@" | contract_json -R -s -c --arg at "$at" --arg verb "$verb" --arg client "$client" \
    --arg result "$result" --argjson exit "$code" --argjson ms "$ms" --arg detail "$detail" '
    {at: $at, verb: $verb, keys: split("\n") | map(select(. != "")), client: $client, result: $result,
     exit: $exit, ms: $ms, detail: (if $detail == "" then null else $detail end)}') || return 0
  contract_log_line "$AS_STATE_DIR/push.log" "$line"
}
