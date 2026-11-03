# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The push to this host's Rex layer. After a launch makes a slot, and after a sweep or finish tears one down, agent-slot
# runs the Rex helper's `agent-slot-rex restore --by push`, so the slot's tab opens or closes in this host's Rex server
# with no key press and no client connected. A push runs in the background and never changes the verb's result or exit
# code. Without the helper at AGENT_SLOT_REX_HELPER it does nothing, and the helper's pass changes nothing when no Rex
# server answers. A verb the helper ran itself names it in AGENT_SLOT_REX_CLIENT and is not pushed, since that helper
# reconciles right after. The helper gets the user manager's runtime directory, which a shell in a slot's tmux session
# lacks and the rex CLI finds the server's socket by.
#
# Each push gets one JSON line in $AS_STATE_DIR/push.log: when the push began, the verb and the slots it made or tore
# down, the result, the helper's exit code, how long the push took, and a detail. The result is one of:
#
#   restored        the helper's restore ran its pass
#   deferred        the helper's pass changed nothing on purpose, and detail names why: rex-server-down,
#                   startup-pending, or reconcile-busy; the start-up step or the next timer pass reconciles instead
#   restore-failed  the helper's restore failed; detail is the last line it printed
#   timed-out       the push outlived AGENT_SLOT_PUSH_TIMEOUT seconds
#   skipped         the helper ran the verb
#
# A verb nothing waits on, such as the timer's sweep or a release's finish, sets AGENT_SLOT_PUSH_WAIT=1 and waits for
# its push before it exits, since systemd ends whatever a oneshot unit leaves running.

PUSH_PIDS=()

# Usage: push_restore <verb> <key...>
push_restore() {
  local verb=$1
  shift
  if [[ -n ${AGENT_SLOT_REX_CLIENT:-} ]]; then
    _push_log "$(contract_now)" "$verb" skipped null 0 '' "$@"
    return 0
  fi
  [[ -x $AS_REX_HELPER ]] || return 0
  _push_one "$verb" "$@" </dev/null >/dev/null 2>&1 &
  PUSH_PIDS+=("$!")
  [[ ${AGENT_SLOT_PUSH_WAIT:-0} != 1 ]] || contract_on_exit push_wait
}

push_wait() {
  ((${#PUSH_PIDS[@]} == 0)) || wait "${PUSH_PIDS[@]}" 2>/dev/null || true
}

# Usage: _push_one <verb> <key...>; runs in the background, after the verb may already have exited.
_push_one() {
  local verb=$1 at start out err status=0 result detail=''
  shift
  CONTRACT_NOISE=/dev/null
  at=$(contract_now) start=$(contract_ms)
  out=$(mktemp) err=$(mktemp)
  timeout --kill-after=2 "$AS_PUSH_TIMEOUT" /usr/bin/env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID}" \
    "$AS_REX_HELPER" restore --by push --output json </dev/null >"$out" 2>"$err" || status=$?
  case $status in
    0)
      result=restored
      detail=$(contract_json -r '.skipped.reason // empty' "$out" || true)
      [[ -z $detail ]] || result=deferred
      ;;
    124 | 137) result=timed-out ;;
    *) result=restore-failed detail=$(grep . "$err" | tail -1 | cut -c 1-200 || true) ;;
  esac
  rm -f "$out" "$err"
  _push_log "$at" "$verb" "$result" "$status" "$(($(contract_ms) - start))" "$detail" "$@"
}

# Usage: _push_log <at> <verb> <result> <exit|null> <ms> <detail> <key...>
_push_log() {
  local at=$1 verb=$2 result=$3 code=$4 ms=$5 detail=$6 line
  shift 6
  line=$(printf '%s\n' "$@" | contract_json -R -s -c --arg at "$at" --arg verb "$verb" --arg result "$result" \
    --argjson exit "$code" --argjson ms "$ms" --arg detail "$detail" '
    {at: $at, verb: $verb, keys: split("\n") | map(select(. != "")), result: $result, exit: $exit, ms: $ms,
     detail: (if $detail == "" then null else $detail end)}') || return 0
  contract_log_line "$AS_STATE_DIR/push.log" "$line"
}
