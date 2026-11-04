# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The start-up step and its record. When the Linux server's Rex server loads its config, it starts
# `agent-slot-rex restore --at-start`, detached. The step takes the reconcile lock at once, waits a bounded time for the
# server to answer (it answers nothing while it loads), runs rexurrect's restore of the operator's own tabs once per
# server instance, records that instance as started, and then reconciles slot tabs with dormant slots resumed.
# rexurrect goes first because it decides which sessions to restore by ID: a reconcile that made a repo's session first
# would get a second one beside it. Its snapshot keeps a slot tab's label but not its command, so the reconcile that
# follows closes the plain shells it restores in place of slot tabs and opens fresh ones. A pass that began on the
# server this one replaced can still have opened slot tabs here before the step took the lock, so right before
# rexurrect the step kills every session of this instance that holds nothing but slot tabs; the reconcile after
# rexurrect opens them again. A session that also holds any other tab is left alone.
#
# rexurrect brings the operator's prime tabs back as plain shells too, so on a new instance the step then re-attaches
# them (reattach.sh), before the reconcile: a prime tab is the operator's working tab, which should not wait on slot
# resumes, and a reconcile that fails ends the step, which would leave every prime detached. Neither changes the
# other's tabs: the reconcile changes only tabs keyed to a slot, opens a tab only for a prime no tab holds, and no prime
# is labelled like a slot key. A config reload's step re-attaches nothing, since there a prime-labelled shell is a prime the operator
# detached. A restart seen while it re-attaches ends the step as skipped, with no reconcile, since the new instance's
# step runs its own.
#
# The record, $AR_STARTUP_RECORD, is {instance, rexurrect, at}: the `instance:` UUID `rex server status` prints, so a
# pid reused after a reboot never matches an old record, and rexurrect's outcome there: done, failed, stopped (it
# outlived its bound), or skipped (it is not installed, or a pass reconciled past the start-up limit first). Until the
# running instance has a record, every other pass changes nothing (reconcile_gate). It is written before the reconcile,
# so a reconcile that fails still leaves the next timer pass free to repair the tabs.

STARTUP_REXURRECT=

# Usage: startup_record_outcome <instance>; prints rexurrect's outcome recorded for that instance, or nothing.
startup_record_outcome() {
  [[ -r $AR_STARTUP_RECORD ]] || return 0
  contract_json -r --arg i "$1" 'select(.instance == $i) | .rexurrect // empty' "$AR_STARTUP_RECORD" || true
}

# Usage: startup_record_write <instance> <done|failed|stopped|skipped>
startup_record_write() {
  local tmp
  mkdir -p "$AR_STATE"
  tmp=$(mktemp "$AR_STATE/startup.json.XXXXXX")
  contract_json -n -c --arg i "$1" --arg r "$2" --arg at "$(contract_now)" '{instance: $i, rexurrect: $r, at: $at}' \
    >"$tmp"
  mv -f "$tmp" "$AR_STARTUP_RECORD"
}

startup_log() {
  printf '%s %s\n' "$(contract_now)" "$*"
}

# Waits up to AR_STARTUP_WAIT seconds for the Rex server to answer, then fails with rex-server-down.
startup_wait_server() {
  local deadline=$((SECONDS + AR_STARTUP_WAIT))
  until rex_server_status; do
    [[ -n $AR_REX ]] || rex_or_fail server status
    if ((SECONDS >= deadline)); then
      startup_log "gave up: no Rex server answered within $AR_STARTUP_WAIT s"
      ar_fail "$(contract_error_json rex-server-down "no Rex server answered within $AR_STARTUP_WAIT s of the \
start-up step ($(rex_error_line))" --value "$AR_REX_UNIT" --command "agent-slot-rex restore")"
    fi
    sleep "$((AR_RETRY < 1 ? 1 : AR_RETRY))"
  done
}

# Kills each session of the running server whose every tab is a slot tab, logging each one and any kill that fails.
startup_kill_slot_sessions() {
  local sid label
  rex_snapshot
  while IFS=$'\t' read -r sid label; do
    [[ -n $sid ]] || continue
    if rex_kill "$sid"; then
      startup_log "killed session $label ($sid) before rexurrect: it holds only slot tabs, opened before this step ran"
    else
      startup_log "could not kill session $label ($sid) before rexurrect: $(rex_error_line)"
    fi
  done < <(contract_json -r --arg key "$SLOT_KEY_PATTERN" "$REX_LABEL_DEF$RECONCILE_KEYED"'
    group_by(.session_id)[] | select(all(.[]; keyed | .key != null)) | [.[0].session_id, .[0].session // ""] | @tsv' \
    <<<"$REX_TABS")
}

# Runs rexurrect's restore into the running server under AR_REXURRECT_BOUND, and sets STARTUP_REXURRECT to its outcome.
# rexurrect returns only after watching for the blank session Rex.app opens, 30 s by default, so the bound covers that
# watch as well as the restore.
startup_rexurrect() {
  local status=0
  if [[ ! -x $AR_REXURRECT ]]; then
    STARTUP_REXURRECT=skipped
    startup_log "rexurrect: skipped, not installed at $AR_REXURRECT"
    return 0
  fi
  startup_kill_slot_sessions
  startup_log "rexurrect auto-restore --server-pid $REX_SERVER_PID, for up to $AR_REXURRECT_BOUND s"
  timeout --kill-after=2 "$AR_REXURRECT_BOUND" "$AR_REXURRECT" auto-restore --server-pid "$REX_SERVER_PID" \
    </dev/null || status=$?
  case $status in
    0) STARTUP_REXURRECT="done" ;;
    124 | 137) STARTUP_REXURRECT=stopped ;;
    *) STARTUP_REXURRECT=failed ;;
  esac
  startup_log "rexurrect: $STARTUP_REXURRECT (exit $status)"
}

# At Rex start nothing watches this command, so it writes to its own log. `rex config check` runs init.lua too, so the
# step goes on only when its parent is a Rex server; Rex keeps its server-only variables out of a child's environment,
# so the parent is the one sign.
cmd_restore_at_start() {
  local parent outcome
  mkdir -p "$AR_STATE"
  exec </dev/null >>"$AR_STATE/restore.log" 2>&1
  parent=$("$AR_PS" -o command= -p "$PPID" 2>/dev/null || true)
  if [[ $parent != *"rex server run"* ]]; then
    startup_log "start-up step skipped: not started by a Rex server (parent: ${parent:-gone})"
    CONTRACT_EMITTED=1
    return 0
  fi
  contract_use_tools rex agent-slot
  journal_begin restore-at-start
  lock_acquire
  startup_log "start-up step; waiting up to $AR_STARTUP_WAIT s for the Rex server to answer"
  startup_wait_server
  outcome=$(startup_record_outcome "$REX_SERVER_INSTANCE")
  if [[ -n $outcome ]]; then
    startup_log "instance $REX_SERVER_INSTANCE is already recorded (rexurrect: $outcome); reconciling only"
  else
    startup_rexurrect
    JOURNAL_REXURRECT=$STARTUP_REXURRECT
    startup_record_write "$REX_SERVER_INSTANCE" "$STARTUP_REXURRECT"
    reattach_primes
  fi
  if [[ -n $REX_PIN_LOST ]]; then
    RECONCILE_SKIP=$REX_PIN_LOST
    reconcile_skipped
  else
    reconcile restore-at-start
  fi
  RECONCILE_RESULT=$(contract_json -c --argjson p "$PRIME_REATTACHED" '. + {primes: $p}' <<<"$RECONCILE_RESULT")
  contract_ok "$RECONCILE_RESULT" "$RECONCILE_TEXT"
}
