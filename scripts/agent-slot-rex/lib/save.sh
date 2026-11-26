# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The save verb, which agent-slot-save.timer runs every 2 minutes and rex-server.service runs as it stops: `rexurrect
# save` of the operator's own tabs, but
# only in a Rex server the start-up step has restored them into. rexurrect's save first restores into any server
# instance it has not recorded as restored into, and by then the start-up step's reconcile has opened every repo
# session, so a save there would make a second copy of each one. The start-up record is the gate: rexurrect done there,
# or failed with the instance named in rexurrect's restored-instances file, since a restore whose every attempt failed
# leaves it unnamed. Any other record (rexurrect stopped at its bound, or skipped) or none yet pauses the save: it
# changes nothing, says why under skipped as save-paused, and exits 0. Each run appends its line to $AR_STATE/save.log.

SAVE_SKIP=''
SAVE_OUTCOME=''

# Usage: save_instance_listed <instance>; true when rexurrect's restored-instances file names the instance, whether or
# not it marks a failed restore there.
save_instance_listed() {
  local file=$AR_REXURRECT_STATE/restored-instances
  [[ -r $file ]] || return 1
  awk -v i="$1" '$1 == i { found = 1 } END { exit !found }' "$file"
}

# Leaves SAVE_SKIP empty when the save may run, or sets it to the error object that says why it changes nothing.
save_gate() {
  SAVE_SKIP='' SAVE_OUTCOME=''
  if ! rex_server_status; then
    SAVE_SKIP=$(rex_down_error)
    return 0
  fi
  SAVE_OUTCOME=$(startup_record_outcome "$REX_SERVER_INSTANCE")
  case $SAVE_OUTCOME in
    done) return 0 ;;
    failed) if save_instance_listed "$REX_SERVER_INSTANCE"; then return 0; fi ;;
  esac
  if [[ -z $SAVE_OUTCOME ]]; then
    SAVE_SKIP=$(contract_error_json save-paused "the start-up step has not yet restored the operator's tabs into the \
Rex server started at $REX_SERVER_STARTED; the next save tries again" --value "$REX_SERVER_INSTANCE" \
      --command "agent-slot-rex save")
  else
    SAVE_SKIP=$(contract_error_json save-paused "the start-up step recorded rexurrect's restore into this Rex server as \
$SAVE_OUTCOME, so a save could restore the operator's tabs beside the ones already open; restarting \
$AR_REX_UNIT runs the step again" --value "$REX_SERVER_INSTANCE" --command "systemctl --user restart $AR_REX_UNIT")
  fi
}

cmd_save() {
  local out status=0
  contract_use_tools rex
  JOURNAL_LOG=$AR_STATE/save.log
  journal_begin save
  save_gate
  if [[ -n $SAVE_SKIP ]]; then
    JOURNAL_SKIPPED=$(contract_json -r '.reason' <<<"$SAVE_SKIP")
    journal_end
    contract_ok "$(contract_json -c --arg i "$REX_SERVER_INSTANCE" --arg o "$SAVE_OUTCOME" '
      def orNull: if . == "" then null else . end;
      {saved: false, instance: ($i | orNull), rexurrect: ($o | orNull), skipped: {reason, message}}' \
      <<<"$SAVE_SKIP")" '"save paused (\(.skipped.reason)): \(.skipped.message)"'
    return 0
  fi
  out=$("$AR_REXURRECT" save </dev/null 2>&1) || status=$?
  if ((status != 0)); then
    ar_fail "$(contract_error_json rexurrect-failed "rexurrect save exited $status: $(tail -n 1 <<<"$out"); \
rexurrect.log in $AR_REXURRECT_STATE holds each failure" --value "$AR_REXURRECT" --command "agent-slot-rex save")"
  fi
  journal_end
  contract_ok "$(contract_json -n -c --arg i "$REX_SERVER_INSTANCE" --arg o "$SAVE_OUTCOME" \
    '{saved: true, instance: $i, rexurrect: $o, skipped: null}')" \
    '"saved the operator'"'"'s own tabs in Rex server instance \(.instance)"'
}
