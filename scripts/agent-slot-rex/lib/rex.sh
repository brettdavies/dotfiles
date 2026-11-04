# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Every call to the rex CLI, and the process lookup that tells whether a pane's attach loop is running.
#
# Rex sets REX_BIN_DIR, REX_SESSION, and REX_BLOCK in every terminal it opens. A command Rex starts at load, a timer, or
# a shell over ssh has none of them, so the CLI is also looked for where the rex package installs it. Each call is
# bounded, reads no stdin, names its session by ID, and passes --autostart=false: a Rex server this helper started would
# carry the caller's environment, an agent's included, into everything it runs.

AR_REX=
REX_OUT=
REX_ERR=
REX_SID=
REX_NEW_SESSION='' REX_NEW_WINDOW='' REX_NEW_BLOCK=''
REX_SERVER_PID='' REX_SERVER_INSTANCE='' REX_SERVER_VERSION='' REX_SERVER_STARTED=''

# A reconcile pass sets REX_PIN to the server instance it planned against, and every tab change below then first checks
# that the instance still answers. A Rex restart takes about 0.1 s, so a pass could otherwise plan against one server
# and make its changes on the next, before that one's start-up step has run rexurrect, which would then restore a
# second session beside each repo's. A change by ID cannot reach another instance, since IDs differ per instance;
# `rex new` and a session found by its label can. The first check that fails sets REX_PIN_LOST to the error that says
# why, and every later change is skipped.
REX_PIN='' REX_PIN_LOST=''

# Rex refuses a window label longer than 128 characters, so every tab label is cut to fit, ending in an ellipsis. jq
# counts characters, where bash's ${#} counts bytes in the C locale, and `·` is two bytes but one character. A label
# that fits passes through unchanged, so cutting one twice gives the same label.
#
# A tab's label starts with its position in its session, "<n>: ", which only the tab-number watcher
# (stow/rex/dot-config/rex/tab-numbers.lua) writes. This helper matches and labels a tab by the rest, keeps the number
# the tab has when it relabels one, and cuts the rest, never the number, to fit. REX_NUMBER_PREFIX is that number as a
# pattern, the same text as the watcher's NUMBER_PREFIX.
REX_NUMBER_PREFIX='^[0-9]+: '
REX_LABEL_DEF='def rex_label_within($n): if length <= $n then . else .[:$n - 1] | sub(" +$"; "") + "…" end;
def rex_label: rex_label_within(128);
def rex_number: (capture("(?<n>'"$REX_NUMBER_PREFIX"')").n // "");
def rex_unnumbered: if test("'"$REX_NUMBER_PREFIX"'") then sub("'"$REX_NUMBER_PREFIX"'"; "") | rex_unnumbered else . end;'

# Usage: rex_label <label>; prints the label cut to Rex's limit.
rex_label() {
  contract_json -n -r --arg l "$1" "$REX_LABEL_DEF"'$l | rex_label'
}

# Sets AR_REX to the rex CLI: REX_BIN_DIR's, else the first of AR_REX_PATHS that exists.
rex_find() {
  local candidate candidates=()
  AR_REX=
  IFS=: read -r -a candidates <<<"$AR_REX_PATHS"
  for candidate in "${REX_BIN_DIR:+$REX_BIN_DIR/rex}" "${candidates[@]}"; do
    if [[ -n $candidate && -x $candidate ]]; then
      AR_REX=$candidate
      return 0
    fi
  done
  return 1
}

# Usage: rex_run <args...>; sets REX_OUT and REX_ERR, and returns rex's status (127 when there is no rex).
rex_run() {
  local out err status=0
  REX_OUT='' REX_ERR=''
  [[ -n $AR_REX ]] || return 127
  out=$(mktemp) err=$(mktemp)
  timeout --kill-after=2 20 "$AR_REX" --autostart=false "$@" </dev/null >"$out" 2>"$err" || status=$?
  REX_OUT=$(<"$out")
  REX_ERR=$(<"$err")
  rm -f "$out" "$err"
  return "$status"
}

# Prints the dependency-missing error for a host with no rex CLI where the helper looks.
rex_missing_error() {
  contract_error_json dependency-missing "the rex CLI is not in REX_BIN_DIR or at any of: ${AR_REX_PATHS//:/, }" \
    --value "${REX_BIN_DIR:-}" --command "sudo apt-get install rex"
}

# Usage: rex_or_fail <args...>; rex_run, ending the command with rex-failed (or dependency-missing) on failure.
rex_or_fail() {
  local status=0
  rex_run "$@" || status=$?
  ((status != 0)) || return 0
  contract_use_tools rex
  ((status != 127)) || [[ -n $AR_REX ]] || ar_fail "$(rex_missing_error)"
  ar_fail "$(contract_error_json rex-failed "rex $1 exited $status: $(rex_error_line)" \
    --value "$*" --command "$(contract_quote rex --autostart=false "$@")")"
}

# The line of REX_ERR that says why rex failed: its Error: line, since rex ends with a pointer to --help, else its last
# line that is not empty.
rex_error_line() {
  grep -m1 -i '^error:' <<<"$REX_ERR" || grep . <<<"$REX_ERR" | tail -1 || true
}

# Usage: rex_session_label <session-id>; sets REX_OUT to the session's label, or '' when it has none.
rex_session_label() {
  rex_or_fail session inspect "$1" --json
  REX_OUT=$(contract_json -r '.label // ""' <<<"$REX_OUT")
}

# Usage: rex_session_find <label>; sets REX_SID to the ID of the first session with that label, or ''.
rex_session_find() {
  rex_or_fail ls --json
  REX_SID=$(contract_json -r --arg l "$1" '[.sessions[] | select(.label == $l)][0].session_id // ""' <<<"$REX_OUT")
}

# Usage: rex_window_of <session-id> <block-id>; sets REX_OUT to the ID of the window holding the block, or ''.
rex_window_of() {
  rex_or_fail session inspect "$1" --json
  REX_OUT=$(contract_json -r --arg b "$2" \
    '[.windows[] | select([.layers[]?.blocks[]?.block_id] | index($b))][0].window_id // ""' <<<"$REX_OUT")
}

# True while no server instance is pinned, or the pinned one still answers; otherwise sets REX_PIN_LOST, once, and
# returns 1.
rex_pinned() {
  [[ -n $REX_PIN ]] || return 0
  [[ -z $REX_PIN_LOST ]] || return 1
  if ! rex_server_status; then
    REX_PIN_LOST=$(contract_error_json rex-server-down "the Rex server this pass planned against (instance $REX_PIN) \
stopped answering partway through ($(rex_error_line)), so the pass made no further tab change" \
      --value "$REX_PIN" --command "systemctl --user start $AR_REX_UNIT")
  elif [[ $REX_SERVER_INSTANCE != "$REX_PIN" ]]; then
    REX_PIN_LOST=$(contract_error_json rex-server-restarted "the Rex server restarted partway through this pass: it \
planned against instance $REX_PIN and instance $REX_SERVER_INSTANCE now answers, so it made no further tab change; \
the new instance's start-up step reconciles its tabs" --value "$REX_SERVER_INSTANCE" --command "agent-slot-rex restore")
  else
    return 0
  fi
  return 1
}

# Usage: rex_open_tab <session-label> <tab-label> <command...>
# Opens a tab running the command in the session with that label, creating the session when there is none, and never
# takes focus. Sets REX_NEW_SESSION, REX_NEW_WINDOW, and REX_NEW_BLOCK, which stay empty when rex_pinned refuses.
rex_open_tab() {
  local session=$1 label
  REX_NEW_SESSION='' REX_NEW_WINDOW='' REX_NEW_BLOCK=''
  label=$(rex_label "$2")
  shift 2
  rex_session_find "$session"
  rex_pinned || return 0
  if [[ -n $REX_SID ]]; then
    rex_or_fail window new -s "$REX_SID" "$label" --focus=false --json -- "$@"
    REX_NEW_SESSION=$REX_SID
    REX_NEW_WINDOW=$(contract_json -r '.window_id' <<<"$REX_OUT")
    REX_NEW_BLOCK=$(contract_json -r '.block_ids[0]' <<<"$REX_OUT")
  else
    rex_or_fail new "$session" --window "$label" --json -- "$@"
    REX_NEW_SESSION=$(contract_json -r '.session_id' <<<"$REX_OUT")
    REX_NEW_WINDOW=$(contract_json -r '.initial_windows[0].window_id' <<<"$REX_OUT")
    REX_NEW_BLOCK=$(contract_json -r '.initial_windows[0].block_ids[0]' <<<"$REX_OUT")
  fi
}

# Usage: rex_move_first <session-id> <window-id>
rex_move_first() {
  rex_pinned || return 0
  rex_or_fail window move -s "$1" "$2" --index 1
}

# Usage: rex_rename <session-id> <window-id> <label>
rex_rename() {
  local label
  rex_pinned || return 0
  label=$(rex_label "$3")
  rex_or_fail window rename -s "$1" "$2" "$label"
}

# Usage: rex_close <session-id> <window-id>; a tab that is already gone, with its session or without, counts as closed.
rex_close() {
  rex_pinned || return 0
  rex_run window close -s "$1" "$2" && return 0
  rex_window_gone "$1" "$2" && return 0
  rex_or_fail window close -s "$1" "$2"
}

# Usage: rex_window_gone <session-id> <window-id>; true when Rex answers and the session or the window is no more.
rex_window_gone() {
  rex_run ls --json || return 1
  if contract_json -e --arg s "$1" '[.sessions[].session_id] | index($s) == null' <<<"$REX_OUT" >/dev/null; then
    return 0
  fi
  rex_run session inspect "$1" --json || return 1
  contract_json -e --arg w "$2" '[.windows[].window_id] | index($w) == null' <<<"$REX_OUT" >/dev/null
}

# Usage: rex_send <session-id> <block-id> <text>; types the text into the block's terminal.
rex_send() {
  rex_pinned || return 0
  rex_or_fail send -s "$1" -b "$2" "$3"
}

# Usage: rex_layout <session-id> <block-id> <key>
# Adds the slot's files and git panes around its Claude pane, through agent-slots.lua's agent_slot_layout.
rex_layout() {
  rex_pinned || return 0
  rex_or_fail "do" agent_slot_layout -s "$1" -b "$2" "key=$3" "block=$2"
}

# Usage: rex_kill <session-id>; ends the session and every tab in it, or returns rex's status.
rex_kill() { rex_run kill "$1"; }

# Usage: rex_actions; sets REX_OUT to the server's actions as JSON, or returns rex's status.
rex_actions() { rex_run actions --json; }

# Sets REX_SERVER_PID, REX_SERVER_INSTANCE, REX_SERVER_VERSION, and REX_SERVER_STARTED (an ISO 8601 time) from
# `rex server status`, or returns rex's status when no Rex server answers. A server still loading its config answers
# nothing.
rex_server_status() {
  rex_run server status || return
  REX_SERVER_PID=$(awk '$1 == "pid:" { print $2 }' <<<"$REX_OUT")
  REX_SERVER_INSTANCE=$(awk '$1 == "instance:" { print $2 }' <<<"$REX_OUT")
  REX_SERVER_VERSION=$(awk '$1 == "version:" { print $2 }' <<<"$REX_OUT")
  REX_SERVER_STARTED=$(awk '$1 == "started:" { print $2 }' <<<"$REX_OUT")
}

# Usage: rex_version; sets REX_OUT to the CLI's rex_version, or returns rex's status.
rex_version() {
  rex_run version --json || return
  REX_OUT=$(contract_json -r '.rex_version // ""' <<<"$REX_OUT")
}

# Sets REX_HELPER_CMD to the command line of every running agent-slot-rex process, by PID.
declare -gA REX_HELPER_CMD=()
rex_helper_processes() {
  local pid line
  REX_HELPER_CMD=()
  while read -r pid line; do
    [[ -n $pid ]] || continue
    REX_HELPER_CMD[$pid]=$line
  done < <("$AR_PS" -A -o pid= -o command= 2>/dev/null | grep 'agent-slot-rex' || true)
}

# Usage: rex_block_pid <session-id> <block-id>; sets REX_OUT to the PID of the process Rex started in the block.
rex_block_pid() {
  rex_run block call -s "$1" -b "$2" process || return
  REX_OUT=$(contract_json -r '.child.pid // ""' <<<"$REX_OUT")
}

# Usage: rex_helper_block <session-label> <verb>
# Sets REX_SID to the session with that label and REX_OUT to its first block whose own process is
# `agent-slot-rex <verb>`, each '' when there is none.
rex_helper_block() {
  local block blocks
  rex_session_find "$1"
  REX_OUT=''
  [[ -n $REX_SID ]] || return 0
  rex_or_fail session inspect "$REX_SID" --json
  blocks=$(contract_json -r '.windows[].layers[]?.blocks[]?.block_id' <<<"$REX_OUT")
  rex_helper_processes
  for block in $blocks; do
    rex_block_pid "$REX_SID" "$block" || continue
    if [[ ${REX_HELPER_CMD[${REX_OUT:-none}]:-} == *"agent-slot-rex $2" ]]; then
      REX_OUT=$block
      return 0
    fi
  done
  REX_OUT=''
}

# Sets REX_BLOCK_TTY to the terminal of every process, by PID.
declare -gA REX_BLOCK_TTY=()
rex_block_terminals() {
  local pid tty
  REX_BLOCK_TTY=()
  while read -r pid tty; do
    [[ -n $pid ]] || continue
    REX_BLOCK_TTY[$pid]=$tty
  done < <("$AR_PS" -A -o pid= -o tty= 2>/dev/null || true)
}

# Usage: rex_snapshot
# Sets REX_TABS to every window of every session, as [{session_id, session, window_id, label, commands, ttys}], where
# commands holds the command line of each block's own process that is this helper, and ttys the terminal of each block's
# own process. A block's own process is the one Rex started in it, so a helper typed into a shell there does not count.
# ps is read after the last block's PID, so a pane whose process starts while the snapshot runs counts as running.
REX_TABS='[]'
rex_snapshot() {
  local sid info rows='' wid label block pid i
  local -a row_heads=() row_pids=()
  rex_or_fail ls --json
  local sessions=$REX_OUT
  while read -r sid; do
    [[ -n $sid ]] || continue
    rex_run session inspect "$sid" --json || continue
    info=$REX_OUT
    while IFS=$'\t' read -r wid label block; do
      pid=
      if [[ -n $block ]] && rex_block_pid "$sid" "$block"; then
        pid=$REX_OUT
      fi
      row_heads+=("$(printf '%s\t%s\t%s' "$sid" "$wid" "$label")")
      row_pids+=("$pid")
    done < <(contract_json -r '.windows[] | .window_id as $w | .label as $l
      | ([.layers[]?.blocks[]?.block_id] | if length == 0 then [""] else . end)[] | [$w, $l, .] | @tsv' <<<"$info")
  done < <(contract_json -r '.sessions[].session_id' <<<"$sessions")
  rex_helper_processes
  rex_block_terminals
  for i in "${!row_heads[@]}"; do
    rows+=${row_heads[i]}$'\t'${REX_HELPER_CMD[${row_pids[i]:-none}]:-}$'\t'${REX_BLOCK_TTY[${row_pids[i]:-none}]:-}$'\n'
  done
  REX_TABS=$(contract_json -R -s -c --argjson sessions "$sessions" '
    ($sessions.sessions | map({(.session_id): .label}) | add // {}) as $names
    | split("\n") | map(select(. != "") | split("\t"))
    | group_by(.[0] + "\t" + .[1])
    | map({session_id: .[0][0], session: $names[.[0][0]], window_id: .[0][1], label: .[0][2],
           commands: map(.[3] // "" | select(. != "")),
           ttys: map(.[4] // "" | select(. != "" and . != "?"))})' <<<"$rows")
}
