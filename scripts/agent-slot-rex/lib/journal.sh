# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The reconcile log: one JSON line per reconcile pass in $AR_STATE/reconcile.log, written whatever ran the pass and
# however it ended: when it began, what ran it, the plan's opens, renames, and closes (null when it stopped before
# planning), and ok or the error that stopped it. Past JOURNAL_MAX bytes the log moves to reconcile.log.1, replacing the
# one there, so the two hold about twice that at most.

JOURNAL_MAX=1048576
JOURNAL_BY=''
JOURNAL_AT=''
JOURNAL_PLAN=null

# Usage: journal_begin <restore|restore-at-start|sweep|finish>
journal_begin() {
  JOURNAL_BY=$1 JOURNAL_AT=$(contract_now) JOURNAL_PLAN=null
  contract_on_exit journal_exit
}

# Usage: journal_end [error-json]; writes the pass's line, ok without an error, and ends the pass. Does nothing when no
# pass is under way, and never fails the command.
journal_end() {
  local log=$AR_STATE/reconcile.log line
  [[ -n $JOURNAL_BY ]] || return 0
  line=$(contract_json -n -c --arg at "$JOURNAL_AT" --arg by "$JOURNAL_BY" --argjson pid "$$" \
    --argjson plan "$JOURNAL_PLAN" --argjson error "${1:-null}" '{at: $at, by: $by, pid: $pid, ok: ($error == null),
      plan: $plan, error: (if $error == null then null else $error | {reason, message, log} end)}') || line=''
  JOURNAL_BY=''
  [[ -n $line ]] || return 0
  {
    mkdir -p "$AR_STATE"
    if [[ -f $log ]] && (($(wc -c <"$log") > JOURNAL_MAX)); then
      mv -f "$log" "$log.1"
    fi
    printf '%s\n' "$line" >>"$log"
  } 2>/dev/null || true
}

# At exit, a pass still under way stopped without an error object of its own.
journal_exit() {
  [[ -n $JOURNAL_BY ]] || return 0
  journal_end "$(contract_json -n -c --arg m "stopped unexpectedly${CONTRACT_LAST_FAILURE:+ at $CONTRACT_LAST_FAILURE}" \
    '{reason: "script-error", message: $m, log: null}')"
}
