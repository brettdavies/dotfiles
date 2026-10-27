# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Reconcile: one Rex tab per live slot, in the session named after its repo, used by restore and sweep.
#
# A tab is keyed to a slot when its label starts with <repo>/<N> in the session named <repo>, or when one of its blocks
# runs `agent-slot-rex attach <repo>/<N>` in any session. A tab elsewhere whose label merely looks like a key is the
# operator's, and is left alone. A keyed tab is present when its Claude pane's attach loop runs. Reconcile resumes
# dormant slots, opens a tab for each live slot without a present one, relabels present tabs, and closes keyed tabs
# whose slot is gone, whose loop has stopped, or that duplicate a present tab. Every server call returns before any tab
# changes, and an unreachable server changes none.
#
# After a Rex restart, rexurrect brings slot tabs back under their labels but as plain shells, since it saves no command
# for their panes, so the restore at start finds them keyed and not running, opens fresh tabs, and closes rexurrect's.

RECONCILE_SLOTS='[]'
RECONCILE_RESUMED=()
RECONCILE_RESULT='{}'

# The label a slot's tab carries: its key, its task or branch, whether Claude is still waiting on the folder trust
# dialog, and the first thing that keeps it from being torn down.
RECONCILE_LABEL='def tab_label:
  .key
  + (if (.task // .branch) then " · \(.task // .branch)" else "" end)
  + ((.agent // "") as $agent
     | if .trust_prompt_expected == true and (["idle", "busy", "waiting"] | index($agent)) == null
       then " · trust needed" else "" end)
  + (if ((.needs_you // []) | length) > 0 then " · needs you: \(.needs_you[0].message)" else "" end);'

# Sets RECONCILE_SLOTS to the server's slots, after resuming the dormant ones. A dormant slot whose resume finds it gone
# is dropped; any other resume failure leaves it to its panes' attach loops.
reconcile_fetch() {
  local key gone=()
  server_call_or_fail 60 list
  RECONCILE_SLOTS=$(contract_json -c '.slots | arrays' <<<"$SERVER_OUT" || true)
  [[ -n $RECONCILE_SLOTS ]] || ar_fail "$(contract_error_json script-error \
    "agent-slot list on $AR_SERVER printed no slots array" --value "${SERVER_OUT:0:200}" \
    --command "ssh $AR_SERVER '$AR_REMOTE list --output json'")"
  RECONCILE_RESUMED=()
  while read -r key; do
    [[ -n $key ]] || continue
    if server_call 60 resume "$key"; then
      RECONCILE_RESUMED+=("$key")
    elif ((SERVER_STATUS == 255 || SERVER_STATUS == 124)); then
      ar_fail "$AR_ERROR"
    elif [[ $(contract_json -r '.reason' <<<"$AR_ERROR") == slot-not-found ]]; then
      gone+=("$key")
    fi
  done < <(contract_json -r '.[] | select(.state == "dormant") | .key' <<<"$RECONCILE_SLOTS")
  RECONCILE_SLOTS=$(printf '%s\n' "${gone[@]}" | contract_json -R -s -c --argjson slots "$RECONCILE_SLOTS" '
    (split("\n") | map(select(. != ""))) as $gone | $slots | map(select(.key as $k | $gone | index($k) | not))')
}

# Usage: reconcile_plan <tabs-json> <slots-json>; prints {open, rename, close}.
reconcile_plan() {
  contract_json -n -c --argjson tabs "$1" --argjson slots "$2" --arg key "$SLOT_KEY_PATTERN" "$RECONCILE_LABEL"'
    def keyed:
      . as $tab
      | (((.label // "") | capture("^(?<k>" + $key + ")( |$)").k
          | select(split("/")[0] == $tab.session)) // null) as $by_label
      | (first(.commands[] | capture("agent-slot-rex attach (?<k>" + $key + ") (claude|files|git)").k)
         // $by_label) as $key
      | . + {key: $key,
             running: ($key != null and (any(.commands[]; contains("agent-slot-rex attach \($key) claude"))
               or ($by_label == $key and any(.commands[]; contains("agent-slot-rex launch"))))) };
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
    | {open: [$live[] | select(.key as $k | $kept | map(.key) | index($k) | not)
              | {key, repo, label: tab_label}],
       rename: [$kept[] | ($by_key[.key] | tab_label) as $want | select(.label != $want)
                | {session_id, window_id, key, label: $want}],
       close: ($gone + [.[].close[]] | map({session_id, window_id, key, label, why}))}'
}

# Opens the planned tabs, then relabels, then closes, so a repo's session is never left empty mid-way.
reconcile_apply() {
  local plan=$1 key repo label sid wid
  while IFS=$'\t' read -r key repo label; do
    [[ -n $key ]] || continue
    reconcile_open_tab "$repo" "$key" "$label"
  done < <(contract_json -r '.open[] | [.key, .repo, .label] | @tsv' <<<"$plan")
  while IFS=$'\t' read -r sid wid label; do
    [[ -n $sid ]] || continue
    rex_rename "$sid" "$wid" "$label"
  done < <(contract_json -r '.rename[] | [.session_id, .window_id, .label] | @tsv' <<<"$plan")
  while IFS=$'\t' read -r sid wid; do
    [[ -n $sid ]] || continue
    rex_close "$sid" "$wid"
  done < <(contract_json -r '.close[] | [.session_id, .window_id] | @tsv' <<<"$plan")
}

# Usage: reconcile_open_tab <repo> <key> <label>
# A slot's tab in the dev layout: Claude top right, files on the left, git below, each pane an attach loop.
reconcile_open_tab() {
  rex_open_tab "$1" "$3" "$AR_SELF" attach "$2" claude
  rex_layout "$REX_NEW_SESSION" "$REX_NEW_BLOCK" "$2"
}

# Sets RECONCILE_RESULT to what reconcile found and changed.
reconcile() {
  local plan
  reconcile_fetch
  rex_snapshot
  plan=$(reconcile_plan "$REX_TABS" "$RECONCILE_SLOTS")
  reconcile_apply "$plan"
  RECONCILE_RESULT=$(printf '%s\n' "${RECONCILE_RESUMED[@]}" | contract_json -R -s -c --argjson plan "$plan" \
    --argjson slots "$RECONCILE_SLOTS" '
    {slots: ($slots | length), resumed: split("\n") | map(select(. != "")),
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
  "\(.slots) slot(s) on the server; tabs match"'

# A tab shows its result until the operator has read it: in text mode with a terminal attached, an error waits for q.
reconcile_hold_on_error() {
  if [[ $CONTRACT_OUTPUT == text && -t 0 ]]; then AR_HOLD=1; fi
}

cmd_restore() {
  contract_use_tools rex ssh
  reconcile_hold_on_error
  reconcile
  contract_ok "$RECONCILE_RESULT" "$RECONCILE_TEXT"
}

cmd_restore_tab() {
  rex_open_tab "$AR_CONTROL" restore "$AR_SELF" restore
  contract_ok "$(contract_json -n -c --arg s "$REX_NEW_SESSION" --arg w "$REX_NEW_WINDOW" \
    '{session_id: $s, window_id: $w}')" '"restoring agent tabs in a tab of the agent-slots session"'
}

# At Rex start nothing watches this command, so it writes to its own log, and waits for the server's ssh to answer
# rather than reporting a network that a wake has not brought back yet. `rex config check` runs init.lua too, so the
# restore goes on only when its parent is a Rex server; Rex keeps its server-only variables out of a child's
# environment, so the parent is the one sign.
cmd_restore_at_start() {
  local deadline remaining parent
  mkdir -p "$AR_STATE"
  exec </dev/null >>"$AR_STATE/restore.log" 2>&1
  parent=$("$AR_PS" -o command= -p "$PPID" 2>/dev/null || true)
  if [[ $parent != *"rex server run"* ]]; then
    printf '%s restore at Rex start skipped: not started by a Rex server (parent: %s)\n' "$(contract_now)" \
      "${parent:-gone}"
    CONTRACT_EMITTED=1
    return 0
  fi
  printf '%s restore at Rex start; waiting up to %s s for %s\n' "$(contract_now)" "$AR_RESTORE_WAIT" "$AR_SERVER"
  deadline=$((SECONDS + AR_RESTORE_WAIT))
  until server_ssh "$(restore_probe_bound "$deadline")" probe true; do
    if ((SECONDS >= deadline)); then
      printf '%s gave up: %s did not answer ssh within %s s\n' "$(contract_now)" "$AR_SERVER" "$AR_RESTORE_WAIT"
      ar_fail "$(contract_error_json server-unreachable "$AR_SERVER did not answer ssh within $AR_RESTORE_WAIT s \
(last try: exit $SERVER_STATUS${SERVER_STDERR:+, $(server_ssh_line)})" --value "$AR_SERVER" \
        --command "agent-slot-rex restore" --log "$SERVER_LOG")"
    fi
    rm -f "$SERVER_LOG"
    remaining=$((deadline - SECONDS))
    sleep "$((AR_RETRY < 1 ? 1 : (AR_RETRY < remaining ? AR_RETRY : remaining)))"
  done
  cmd_restore
}

# Usage: restore_probe_bound <deadline>; the seconds one probe may take: at most 15, and never past the deadline.
restore_probe_bound() {
  local remaining=$(($1 - SECONDS))
  ((remaining <= 15)) || remaining=15
  ((remaining >= 1)) || remaining=1
  printf '%s' "$remaining"
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
  contract_use_tools rex ssh
  [[ $CONTRACT_OUTPUT != text ]] || AR_HOLD=1 AR_AGAIN=sweep
  sweep_teardown
  reconcile
  RECONCILE_RESULT=$(contract_json -c --argjson t "$SWEEP_TORN_DOWN" '. + {torn_down: $t}' <<<"$RECONCILE_RESULT")
  contract_ok "$RECONCILE_RESULT" '(.torn_down[] | "torn down: \(.)"), '"$RECONCILE_TEXT"'
    , (if .needs_you == [] then "nothing needs you" else "needs you:", (.needs_you[] | "  \(.label)") end)'
  count=$(contract_json '.needs_you | length' <<<"$RECONCILE_RESULT")
  if ((count > 0 && AR_HOLD == 1)); then
    ar_hold
  elif ar_again_pending; then
    ar_again
  fi
}
