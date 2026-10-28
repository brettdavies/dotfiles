# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# follow: the loop Rex starts at load that keeps this Mac's tabs following the server between keys. The server pushes a
# restore after each launch and teardown; this loop catches what a push missed, such as a push sent while the Mac slept
# or a task's branch that changed its label. Every AR_TICK seconds it checks that the Rex server it serves still runs
# and that it still holds the follow lock, then runs a restore when one is due:
#
#   reconnect  once the server answers after a sleep of the Mac, a wall-clock gap of more than AR_WAKE_GAP seconds
#              across one tick, or after a call that could not reach it; until it answers, each tick probes it
#   poll       once AR_POLL_INTERVAL seconds have passed since the last restore
#
# Each restore is a process of its own, so it takes the reconcile lock and writes its reconcile log line as any restore
# does. The loop's own events go to $AR_STATE/follow.log, one JSON line each: start, a wake, the server going and coming
# back, and why the loop ended.
#
# One loop runs per Rex server. The follow lock, $AR_STATE/follow.pid, holds the loop's PID and its Rex server's PID. A
# start whose lock names a live loop of the same Rex server exits; any other start takes the lock over. A loop that
# finds the lock naming another loop exits, so after a Rex restart the old server's loop leaves within one tick.

FOLLOW_LOCK=
FOLLOW_REX_PID=
# 0 when the last call reached the server, 1 when that is unknown after a wake, 2 when the server could not be reached.
FOLLOW_DOWN=0
FOLLOW_DOWN_AT=0
FOLLOW_END=

# Usage: follow_log <event> [json-object]; one line in the follow log.
follow_log() {
  local line more='{}'
  (($# < 2)) || more=$2
  line=$(contract_json -n -c --arg at "$(contract_now)" --arg event "$1" --argjson pid "$$" --argjson more "$more" \
    '{at: $at, event: $event, pid: $pid} + $more') || return 0
  contract_log_line "$AR_STATE/follow.log" "$line"
}

follow_now() { printf '%(%s)T' -1; }

# Takes the follow lock, or returns 1 when a live loop of the same Rex server holds it.
follow_claim() {
  local pid rex
  FOLLOW_LOCK=$AR_STATE/follow.pid
  if read -r pid rex 2>/dev/null <"$FOLLOW_LOCK" && [[ $rex == "$FOLLOW_REX_PID" && $pid != "$$" ]] \
    && lock_owner_alive "$pid"; then
    follow_log already-following "{\"holder\": $pid}"
    return 1
  fi
  printf '%s %s\n' "$$" "$FOLLOW_REX_PID" >"$FOLLOW_LOCK.$$"
  mv -f "$FOLLOW_LOCK.$$" "$FOLLOW_LOCK"
  contract_on_exit follow_release
}

follow_mine() { [[ $(cat "$FOLLOW_LOCK" 2>/dev/null) == "$$ $FOLLOW_REX_PID" ]]; }

follow_release() {
  [[ -z $FOLLOW_END ]] || follow_log "$FOLLOW_END"
  [[ -n $FOLLOW_END ]] || follow_log stopped "$(contract_json -n -c --arg at "${CONTRACT_LAST_FAILURE:-unknown}" \
    '{failed_at: $at}' || echo '{}')"
  ! follow_mine || rm -f "$FOLLOW_LOCK"
}

follow_rex_alive() {
  [[ $("$AR_PS" -o command= -p "$FOLLOW_REX_PID" 2>/dev/null || true) == *"rex server run"* ]]
}

# Usage: follow_unreachable <what> <detail>; records that the server could not be reached, once per outage.
follow_unreachable() {
  ((FOLLOW_DOWN != 2)) || return 0
  FOLLOW_DOWN=2 FOLLOW_DOWN_AT=$(follow_now)
  follow_log unreachable "$(contract_json -n -c --arg after "$1" --arg detail "$2" '{after: $after, detail: $detail}')"
}

# Probes the server's ssh; returns 0 once it answers. A failed probe's log is dropped, since the follow log records the
# outage once and a probe runs every tick until it ends.
follow_probe() {
  if server_ssh 10 probe true; then
    ((FOLLOW_DOWN != 2)) || follow_log reachable "{\"down_s\": $(($(follow_now) - FOLLOW_DOWN_AT))}"
    FOLLOW_DOWN=0
    return 0
  fi
  rm -f "$SERVER_LOG"
  follow_unreachable probe "$(server_ssh_line)"
  return 1
}

# Usage: follow_restore <poll|reconnect>
follow_restore() {
  local err status=0 envelope
  err=$(mktemp)
  "$AR_SELF" restore --by "$1" --output json </dev/null >/dev/null 2>"$err" || status=$?
  if ((status != 0)); then
    envelope=$(grep '^{' "$err" | tail -1 || true)
    if [[ $(contract_json -r '.reason // ""' <<<"$envelope" || true) == server-unreachable ]]; then
      follow_unreachable "$1" "$(contract_json -r '.message // ""' <<<"$envelope" || true)"
    fi
  fi
  rm -f "$err"
}

follow_loop() {
  local before after last_pass by
  last_pass=$(follow_now)
  while true; do
    before=$(follow_now)
    sleep "$AR_TICK"
    after=$(follow_now)
    if ! follow_mine; then
      FOLLOW_END=superseded
      return 0
    fi
    if ! follow_rex_alive; then
      FOLLOW_END='rex-gone'
      return 0
    fi
    if ((after - before > AR_WAKE_GAP)); then
      follow_log wake "{\"gap_s\": $((after - before))}"
      ((FOLLOW_DOWN == 2)) || FOLLOW_DOWN=1
    fi
    if ((FOLLOW_DOWN != 0)); then
      follow_probe || continue
      by=reconnect
    elif ((after - last_pass >= AR_POLL_INTERVAL)); then
      by=poll
    else
      continue
    fi
    follow_restore "$by"
    last_pass=$(follow_now)
  done
}

# Rex starts this at load, with no terminal and nothing watching, so it prints nothing and logs to the follow log. As
# with the restore at Rex start, it runs only when a Rex server started it, which `rex config check` does not.
cmd_follow() {
  local parent
  mkdir -p "$AR_STATE"
  exec </dev/null >/dev/null 2>&1
  CONTRACT_EMITTED=1
  parent=$("$AR_PS" -o command= -p "$PPID" 2>/dev/null || true)
  if [[ $parent != *"rex server run"* ]]; then
    follow_log skipped "$(contract_json -n -c --arg p "${parent:-gone}" '{parent: $p}')"
    return 0
  fi
  if ! [[ $AR_POLL_INTERVAL =~ ^[0-9]+$ && $AR_WAKE_GAP =~ ^[0-9]+$ && $AR_TICK =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    follow_log config-invalid "$(contract_json -n -c --arg i "$AR_POLL_INTERVAL" --arg t "$AR_TICK" \
      --arg g "$AR_WAKE_GAP" '{interval: $i, tick: $t, wake_gap: $g}')"
    return "$EXIT_CONFIG"
  fi
  FOLLOW_REX_PID=$PPID
  follow_claim || return 0
  follow_log start "$(contract_json -n -c --argjson rex "$FOLLOW_REX_PID" --argjson interval "$AR_POLL_INTERVAL" \
    --arg tick "$AR_TICK" --argjson gap "$AR_WAKE_GAP" \
    '{rex_pid: $rex, interval: $interval, tick: ($tick | tonumber), wake_gap: $gap}')"
  follow_loop
}
