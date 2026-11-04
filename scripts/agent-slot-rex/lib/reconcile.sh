# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Reconcile: one Rex tab per live slot and per running prime, in the session named after its repo, used by restore and
# sweep.
#
# A tab is keyed to a slot when its label, past its number, starts with <repo>/<N> in the session named <repo>, or when
# one of its blocks
# runs `agent-slot-rex attach <repo>/<N>` in any session. A tab elsewhere whose label merely looks like a key is the
# operator's, and is left alone. A keyed tab is present when its Claude pane's attach loop runs. Reconcile resumes
# dormant slots, opens a tab for each live slot without a present one, relabels present tabs, and closes keyed tabs
# whose slot is gone, whose loop has stopped, or that duplicate a present tab. Every server call returns before any tab
# changes, and an unreachable server changes none.
#
# A prime's tab is only ever opened. SLOT_KEY_PATTERN never matches <repo>/prime, so no tab is keyed to a prime, and a
# prime's tab that an operator renamed, duplicated, or left is theirs. A prime no tab in any Rex session holds gets one
# first in its repo's session: three panes for a prime on the slot server, and one pane on an old-style session, which
# the tab attaches to and nothing here changes. A tab holds a prime as prime_tab_open says, in any Rex session, or through
# the prime command as its own process, which is all a tab this pass's predecessor just opened shows until its client
# attaches.
#
# After a Rex restart, rexurrect brings slot tabs back under their labels but as plain shells, since it saves no command
# for their panes, so the start-up step's reconcile finds them keyed and not running, opens fresh tabs, and closes
# rexurrect's.
#
# A pass pins the server instance it planned against (REX_PIN in rex.sh), and checks it before every tab change and once
# after the last. When another instance answers, or none does, the pass makes no further change and ends as skipped
# with rex-server-restarted or rex-server-down, journaling the part of its plan it carried out; a restore asked for by
# hand fails with that error instead. A pass with nothing to change asks for no instance beyond its gate's.
#
# Every pass but the start-up step first goes through reconcile_gate: a Rex server must answer, and the start-up step
# must have recorded its instance, unless the server has outlived AR_STARTUP_LIMIT, when the pass records rexurrect as
# skipped and goes on. A pass that a timer, a push, or a teardown ran logs why it changed nothing and exits 0; a restore
# asked for by hand reports the same outcome as an error. A timer pass never waits for the lock, since the next one
# comes a minute later; a push waits, so a launch right behind another pass still gets its tab within seconds. The gate
# runs again once the lock is held, since the pass ahead may have recorded the start-up step, or the server may have
# restarted, while this one waited.

RECONCILE_SLOTS='[]'
RECONCILE_PRIMES='[]'
RECONCILE_RESUMED=()
RECONCILE_RESULT='{}'
RECONCILE_SKIP=''
RECONCILE_PAST_LIMIT=0
RECONCILE_APPLIED='{"open":[],"rename":[],"close":[]}'

# The label a slot's tab carries: its key, the label_name list gives it, else its task or branch for a server whose
# dotfiles are older than this Mac's, whether Claude is still waiting on the folder trust dialog, and the first thing
# that keeps it from being torn down. Rex's limit cuts it from the end, so the key a tab is matched by stays in front,
# and cuts it the same way each pass, so a relabelled tab is not relabelled again.
RECONCILE_LABEL="$REX_LABEL_DEF"'def tab_rest:
  (.key
   + ((.label_name // .task // .branch) as $name | if $name then " · \($name)" else "" end)
   + ((.agent // "") as $agent
      | if .trust_prompt_expected == true and (["idle", "busy", "waiting"] | index($agent)) == null
        then " · trust needed" else "" end)
   + (if ((.needs_you // []) | length) > 0 then " · needs you: \(.needs_you[0].message)" else "" end));
def tab_label: tab_rest | rex_label;'

# keyed: a tab from rex_snapshot, with the key of the slot it belongs to (null when none) and whether its Claude pane's
# attach loop runs. $key is SLOT_KEY_PATTERN, and rex_unnumbered comes from REX_LABEL_DEF.
RECONCILE_KEYED='def keyed:
  . as $tab
  | (((.label // "") | rex_unnumbered | capture("^(?<k>" + $key + ")( |$)").k
      | select(split("/")[0] == $tab.session)) // null) as $by_label
  | (first(.commands[] | capture("agent-slot-rex attach (?<k>" + $key + ") (claude|files|git)").k)
     // $by_label) as $key
  | . + {key: $key,
         running: ($key != null and (any(.commands[]; contains("agent-slot-rex attach \($key) claude"))
           or ($by_label == $key and any(.commands[]; contains("agent-slot-rex launch"))))) };'

# Sets RECONCILE_SLOTS to the server's slots, after resuming the dormant ones. A dormant slot whose resume finds it gone
# is dropped; any other resume failure leaves it to its panes' attach loops.
reconcile_fetch() {
  local key gone=()
  server_call_or_fail 60 list
  RECONCILE_SLOTS=$(contract_json -c '.slots | arrays' <<<"$SERVER_OUT" || true)
  [[ -n $RECONCILE_SLOTS ]] || ar_fail "$(contract_error_json script-error "agent-slot list printed no slots array" \
    --value "${SERVER_OUT:0:200}" --command "agent-slot list --output json")"
  RECONCILE_PRIMES=$(contract_json -c '.primes // []' <<<"$SERVER_OUT")
  RECONCILE_RESUMED=()
  while read -r key; do
    [[ -n $key ]] || continue
    if server_call "$AR_RESUME_BOUND" resume "$key"; then
      RECONCILE_RESUMED+=("$key")
    elif server_timed_out; then
      ar_fail "$AR_ERROR"
    elif [[ $(contract_json -r '.reason' <<<"$AR_ERROR") == slot-not-found ]]; then
      gone+=("$key")
    fi
  done < <(contract_json -r '.[] | select(.state == "dormant") | .key' <<<"$RECONCILE_SLOTS")
  RECONCILE_SLOTS=$(printf '%s\n' "${gone[@]}" | contract_json -R -s -c --argjson slots "$RECONCILE_SLOTS" '
    (split("\n") | map(select(. != ""))) as $gone | $slots | map(select(.key as $k | $gone | index($k) | not))')
}

# Adds to each of RECONCILE_PRIMES the terminals of its tmux clients, which only an old-style prime is known by, from one
# read per old-style prime.
reconcile_prime_clients() {
  local prime session clients rows=()
  while IFS= read -r prime; do
    [[ -n $prime ]] || continue
    clients=
    if [[ $(contract_json -r '.server' <<<"$prime") == "$TMUX_DEFAULT_SOCKET" ]]; then
      session=$(contract_json -r '.session' <<<"$prime")
      clients=$(prime_old_clients "$session")
    fi
    rows+=("$(contract_json -c --arg clients "$clients" '. + {clients: ($clients | split("\n") | map(select(. != "")))}' \
      <<<"$prime")")
  done < <(contract_json -c '.[]' <<<"$RECONCILE_PRIMES")
  RECONCILE_PRIMES=$(printf '%s\n' "${rows[@]}" | contract_json -s -c 'map(select(. != null))')
}

# Usage: reconcile_plan <tabs-json> <slots-json> <primes-json>; prints {open, rename, close}.
reconcile_plan() {
  contract_json -n -c --argjson tabs "$1" --argjson slots "$2" --argjson primes "$3" --arg key "$SLOT_KEY_PATTERN" \
    "$RECONCILE_LABEL$RECONCILE_KEYED"'
    def holds($p): . as $tab
      | any(.commands[]; endswith("agent-slot-rex attach \($p.key) claude") or endswith("agent-slot-rex prime \($p.repo)"))
        or ((.label // "") | rex_unnumbered) == $p.label and any($tab.commands[]; contains("agent-slot-rex launch"))
        or any(.ttys[]; . as $tty | $p.clients | index("/dev/\($tty)") != null);
    ($slots | map({(.key): .}) | add // {}) as $by_key
    | ($slots | map(select(.state == "active" or .state == "dormant"))) as $live
    | [$tabs[] | keyed | select(.key != null)] as $keyed
    | [$keyed[] | select($by_key[.key] == null) | . + {why: "slot is gone"}] as $gone
    | [$keyed[] | select($by_key[.key] != null)] | group_by(.key)
    | map((first(.[] | select(.running)) // null) as $keep
          | {keep: $keep,
             close: [.[] | select(. != $keep)
                     | . + {why: (if $keep == null then "attach loop is not running" else "duplicate tab" end)}]})
    | ([.[].keep | select(. != null)]) as $kept
    | {open: ([$live[] | select(.key as $k | $kept | map(.key) | index($k) | not) | {key, repo, label: tab_label}]
              + [$primes[] | . as $p | select(any($tabs[]; holds($p)) | not) | {key, repo, label, server}]),
       rename: [$kept[] | ((.label // "") | rex_number) as $n
                | ($n + ($by_key[.key] | tab_rest | rex_label_within(128 - ($n | length)))) as $want
                | select(.label != $want)
                | {session_id, window_id, key, label: $want}],
       close: ($gone + [.[].close[]] | map({session_id, window_id, key, label, why}))}'
}

# Opens the planned tabs, then relabels, then closes, so a repo's session is never left empty mid-way, and checks the
# pinned instance once more after the last change. Sets RECONCILE_APPLIED to the part of the plan it carried out before
# rex_pinned refused a change, the whole plan when none was refused.
reconcile_apply() {
  local plan=$1 key repo label server sid wid opened=0 renamed=0 closed=0
  while IFS=$'\x1f' read -r key repo label server; do
    [[ -n $key && -z $REX_PIN_LOST ]] || continue
    reconcile_open_tab "$repo" "$key" "$label" "$server"
    [[ -z $REX_NEW_WINDOW ]] || opened=$((opened + 1))
  done < <(contract_json -r '.open[] | [.key, .repo, .label, .server // ""] | join("\u001f")' <<<"$plan")
  while IFS=$'\t' read -r sid wid label; do
    [[ -n $sid && -z $REX_PIN_LOST ]] || continue
    rex_rename "$sid" "$wid" "$label"
    [[ -n $REX_PIN_LOST ]] || renamed=$((renamed + 1))
  done < <(contract_json -r '.rename[] | [.session_id, .window_id, .label] | @tsv' <<<"$plan")
  while IFS=$'\t' read -r sid wid; do
    [[ -n $sid && -z $REX_PIN_LOST ]] || continue
    rex_close "$sid" "$wid"
    [[ -n $REX_PIN_LOST ]] || closed=$((closed + 1))
  done < <(contract_json -r '.close[] | [.session_id, .window_id] | @tsv' <<<"$plan")
  ((opened + renamed + closed == 0)) || rex_pinned || true
  RECONCILE_APPLIED=$(contract_json -c --argjson o "$opened" --argjson r "$renamed" --argjson c "$closed" \
    '{open: .open[:$o], rename: .rename[:$r], close: .close[:$c]}' <<<"$plan")
}

# Usage: reconcile_open_tab <repo> <key> <label> [slots | default]
# A slot's tab, or with the server it runs on a prime's, in the dev layout: Claude top right, files on the left, git below,
# each pane an attach loop. A prime's tab goes first in its session, and an old-style one is the one pane that holds it.
reconcile_open_tab() {
  if [[ ${4:-} == "$TMUX_DEFAULT_SOCKET" ]]; then
    rex_open_tab "$1" "$3" "$AR_SELF" prime "$1"
  else
    rex_open_tab "$1" "$3" "$AR_SELF" attach "$2" claude
    rex_layout "$REX_NEW_SESSION" "$REX_NEW_BLOCK" "$2"
  fi
  [[ -z ${4:-} ]] || rex_move_first "$REX_NEW_SESSION" "$REX_NEW_WINDOW"
}

# Usage: reconcile_gate <by>; true when the pass goes on. Otherwise sets RECONCILE_SKIP to the error object that says
# why it changes nothing; a restore asked for by hand fails with it instead.
reconcile_gate() {
  local by=$1 error='' age limit_at
  RECONCILE_SKIP='' RECONCILE_PAST_LIMIT=0
  if ! rex_server_status; then
    if [[ -z $AR_REX ]]; then
      error=$(rex_missing_error)
    else
      error=$(contract_error_json rex-server-down "no Rex server answers on this host ($(rex_error_line))" \
        --value "$AR_REX_UNIT" --command "systemctl --user start $AR_REX_UNIT")
    fi
  elif [[ -z $(startup_record_outcome "$REX_SERVER_INSTANCE") ]]; then
    read -r age limit_at < <(contract_json -n -r --arg s "$REX_SERVER_STARTED" --argjson l "$AR_STARTUP_LIMIT" \
      '$s | fromdateiso8601 | "\(now - . | floor) \(. + $l | todateiso8601)"' || true) || true
    if [[ ${age:-} =~ ^-?[0-9]+$ ]] && ((age < AR_STARTUP_LIMIT)); then
      error=$(contract_error_json startup-pending "the Rex server started at $REX_SERVER_STARTED and its start-up \
step has not yet restored the operator's tabs; until it records this instance, passes reconcile only from $limit_at" \
        --value "$REX_SERVER_INSTANCE" --command "agent-slot-rex restore")
    else
      RECONCILE_PAST_LIMIT=1
    fi
  fi
  [[ -n $error ]] || return 0
  [[ $by != restore ]] || ar_fail "$error"
  RECONCILE_SKIP=$error
  return 1
}

# Usage: reconcile_take_lock <by>; the lock as the pass waits for it, or 1 with RECONCILE_SKIP set when a timer or push
# pass gives up on it.
reconcile_take_lock() {
  local wait
  case $1 in
    poll) wait=0 ;;
    push) wait=$AR_LOCK_WAIT ;;
    *)
      lock_acquire
      return 0
      ;;
  esac
  lock_take "$wait" && return 0
  RECONCILE_SKIP=$(contract_error_json reconcile-busy "another agent-slot-rex (pid ${AR_LOCK_OWNER:-unknown}) holds \
the reconcile lock" --value "$AR_LOCK" --command "agent-slot-rex restore")
  return 1
}

# Ends a pass that changed nothing on purpose: logs why and sets RECONCILE_RESULT to say so.
reconcile_skipped() {
  JOURNAL_SKIPPED=$(contract_json -r '.reason' <<<"$RECONCILE_SKIP")
  journal_end
  lock_release
  RECONCILE_RESULT=$(contract_json -c '{skipped: {reason, message}, slots: null, resumed: [], opened: [],
    relabeled: [], closed: [], needs_you: []}' <<<"$RECONCILE_SKIP")
}

# Usage: reconcile <restore|restore-at-start|push|poll|sweep|finish>, naming what ran the pass for the
# reconcile log.
# Sets RECONCILE_RESULT to what reconcile found and changed, or why it changed nothing. It holds the reconcile lock from
# the slot list to the last tab change.
reconcile() {
  local by=$1 plan
  journal_begin "$by"
  if [[ $by != restore-at-start ]]; then
    if ! reconcile_gate "$by" || ! reconcile_take_lock "$by" || ! reconcile_gate "$by"; then
      reconcile_skipped
      return 0
    fi
    if ((RECONCILE_PAST_LIMIT == 1)); then
      JOURNAL_REXURRECT=skipped
      startup_record_write "$REX_SERVER_INSTANCE" skipped
    fi
  fi
  REX_PIN=$REX_SERVER_INSTANCE REX_PIN_LOST=''
  reconcile_fetch
  reconcile_prime_clients
  rex_snapshot
  plan=$(reconcile_plan "$REX_TABS" "$RECONCILE_SLOTS" "$RECONCILE_PRIMES")
  JOURNAL_PLAN=$plan
  reconcile_apply "$plan"
  REX_PIN=''
  plan=$RECONCILE_APPLIED JOURNAL_PLAN=$RECONCILE_APPLIED
  if [[ -n $REX_PIN_LOST ]]; then
    [[ $by != restore ]] || ar_fail "$REX_PIN_LOST"
    JOURNAL_SKIPPED=$(contract_json -r '.reason' <<<"$REX_PIN_LOST")
  fi
  journal_end
  lock_release
  RECONCILE_RESULT=$(printf '%s\n' "${RECONCILE_RESUMED[@]}" | contract_json -R -s -c --argjson plan "$plan" \
    --argjson slots "$RECONCILE_SLOTS" --arg lost "$REX_PIN_LOST" '
    {skipped: (if $lost == "" then null else $lost | fromjson | {reason, message} end),
     slots: ($slots | length), resumed: split("\n") | map(select(. != "")),
     opened: [$plan.open[].key], relabeled: [$plan.rename[] | {key, label}],
     closed: [$plan.close[] | {key, label, why}],
     needs_you: [$slots[] | select((.needs_you // []) | length > 0)
                 | {key, label: (.key + " · needs you: " + .needs_you[0].message), needs_you}]}')
}

RECONCILE_TEXT='
  (if .resumed != [] then "resumed: \(.resumed | join(", "))" else empty end),
  (.opened[] | "opened: \(.)"),
  (.relabeled[] | "relabeled: \(.label)"),
  (.closed[] | "closed: \(.label) (\(.why))"),
  if .skipped then "tabs not reconciled: \(.skipped.message)" else "\(.slots) slot(s) on the server; tabs match" end'

# A tab shows its result until the operator has read it: in text mode with a terminal attached, an error waits for q.
reconcile_hold_on_error() {
  if [[ $CONTRACT_OUTPUT == text && -t 0 ]]; then AR_HOLD=1; fi
}

# Usage: cmd_restore [push|poll]; without one, a restore asked for by hand.
cmd_restore() {
  contract_use_tools rex agent-slot
  reconcile_hold_on_error
  reconcile "${1:-restore}"
  contract_ok "$RECONCILE_RESULT" "$RECONCILE_TEXT"
}

cmd_restore_tab() {
  rex_open_tab "$AR_CONTROL" restore "$AR_SELF" restore
  contract_ok "$(contract_json -n -c --arg s "$REX_NEW_SESSION" --arg w "$REX_NEW_WINDOW" \
    '{session_id: $s, window_id: $w}')" '"restoring agent tabs in a tab of the agent-slots session"'
}

# The server's sweep --yes tears down every finished slot that check passes, ahead of reconcile, so a torn-down slot's
# tab closes in the same pass; the server records each kept slot's blockers, which list then reports. The Mac side
# tears nothing down itself. Sets SWEEP_TORN_DOWN to the slots it tore down, as a JSON array.
SWEEP_TORN_DOWN='[]'
sweep_teardown() {
  server_call_or_fail 300 sweep --yes
  SWEEP_TORN_DOWN=$(contract_json -c '.torn_down // [] | arrays' <<<"$SERVER_OUT" || true)
  [[ -n $SWEEP_TORN_DOWN ]] || SWEEP_TORN_DOWN='[]'
}

cmd_sweep() {
  local count
  contract_use_tools rex agent-slot
  [[ $CONTRACT_OUTPUT != text ]] || AR_HOLD=1 AR_AGAIN=sweep
  sweep_teardown
  [[ $SWEEP_TORN_DOWN == '[]' ]] \
    || AR_DONE="agent-slot sweep tore down $(contract_json -r 'join(", ")' <<<"$SWEEP_TORN_DOWN")"
  reconcile sweep
  RECONCILE_RESULT=$(contract_json -c --argjson t "$SWEEP_TORN_DOWN" '. + {torn_down: $t}' <<<"$RECONCILE_RESULT")
  contract_ok "$RECONCILE_RESULT" '(.torn_down[] | "torn down: \(.)"), '"$RECONCILE_TEXT"'
    , (if .skipped then empty elif .needs_you == [] then "nothing needs you"
       else "needs you:", (.needs_you[] | "  \(.label)") end)'
  count=$(contract_json '.needs_you | length' <<<"$RECONCILE_RESULT")
  if ((count > 0 && AR_HOLD == 1)); then
    ar_hold
  elif ar_again_pending; then
    ar_again
  fi
}
