# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Every call to the rex CLI, and the process lookup that tells whether a pane's attach loop is running.
#
# Rex sets REX_BIN_DIR, REX_SESSION, and REX_BLOCK in every terminal it opens. A command Rex starts at load, or a shell
# over ssh, has none of them, so the CLI is also looked for where the app installs it. Each call is bounded, reads no
# stdin, and names its session by ID.

AR_REX=
REX_OUT=
REX_ERR=
REX_SID=
REX_NEW_SESSION='' REX_NEW_WINDOW='' REX_NEW_BLOCK=''

REX_APP_PATHS="/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex:\
$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

# Sets AR_REX to the rex CLI: REX_BIN_DIR's, else the first of AGENT_SLOT_REX_APP_PATHS (colon-separated; the app's
# install paths when unset) that exists.
rex_find() {
  local candidate candidates=()
  AR_REX=
  IFS=: read -r -a candidates <<<"${AGENT_SLOT_REX_APP_PATHS-$REX_APP_PATHS}"
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
  timeout --kill-after=2 20 "$AR_REX" "$@" </dev/null >"$out" 2>"$err" || status=$?
  REX_OUT=$(<"$out")
  REX_ERR=$(<"$err")
  rm -f "$out" "$err"
  return "$status"
}

# Usage: rex_or_fail <args...>; rex_run, ending the command with rex-failed (or dependency-missing) on failure.
rex_or_fail() {
  local status=0
  rex_run "$@" || status=$?
  ((status != 0)) || return 0
  contract_use_tools rex
  if ((status == 127)) && [[ -z $AR_REX ]]; then
    ar_fail "$(contract_error_json dependency-missing "the rex CLI is not in REX_BIN_DIR or the Rex app" \
      --value "${REX_BIN_DIR:-}" --command "open -a 'Rex Beta'")"
  fi
  ar_fail "$(contract_error_json rex-failed "rex $1 exited $status: $(grep . <<<"$REX_ERR" | tail -1 || true)" \
    --value "$*" --command "$(contract_quote rex "$@")")"
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

# Usage: rex_open_tab <session-label> <tab-label> <command...>
# Opens a tab running the command in the session with that label, creating the session when there is none, and never
# takes focus. Sets REX_NEW_SESSION, REX_NEW_WINDOW, and REX_NEW_BLOCK.
rex_open_tab() {
  local session=$1 label=$2
  shift 2
  rex_session_find "$session"
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

# Usage: rex_rename <session-id> <window-id> <label>
rex_rename() { rex_or_fail window rename -s "$1" "$2" "$3"; }

# Usage: rex_close <session-id> <window-id>
rex_close() { rex_or_fail window close -s "$1" "$2"; }

# Usage: rex_focus <session-id> <window-id>
rex_focus() { rex_or_fail focus -s "$1" "$2"; }

# Usage: rex_layout <session-id> <block-id> <key>
# Adds the slot's files and git panes around its Claude pane, through agent-slots.lua's agent_slot_layout.
rex_layout() { rex_or_fail "do" agent_slot_layout -s "$1" -b "$2" "key=$3" "block=$2"; }

# Usage: rex_actions; sets REX_OUT to the server's actions as JSON, or returns rex's status.
rex_actions() { rex_run actions --json; }

# Usage: rex_version; sets REX_OUT to the CLI's rex_version, or returns rex's status.
rex_version() {
  rex_run version --json || return
  REX_OUT=$(contract_json -r '.rex_version // ""' <<<"$REX_OUT")
}

# Usage: rex_snapshot
# Sets REX_TABS to every window of every session, as [{session_id, session, window_id, label, commands}], where
# commands holds the command line of each block's own process that is this helper. A block's own process is the one
# Rex started in it, so a helper typed into a shell there does not count.
REX_TABS='[]'
rex_snapshot() {
  local sid info rows='' wid label block pid line
  local -A helper_cmd=()
  rex_or_fail ls --json
  local sessions=$REX_OUT
  while read -r pid line; do
    [[ -n $pid ]] || continue
    helper_cmd[$pid]=$line
  done < <("$AR_PS" -A -o pid= -o command= 2>/dev/null | grep 'agent-slot-rex' || true)
  while read -r sid; do
    [[ -n $sid ]] || continue
    rex_run session inspect "$sid" --json || continue
    info=$REX_OUT
    while IFS=$'\t' read -r wid label block; do
      pid=
      if [[ -n $block ]] && rex_run block call -s "$sid" -b "$block" process; then
        pid=$(contract_json -r '.child.pid // ""' <<<"$REX_OUT")
      fi
      rows+=$(printf '%s\t%s\t%s\t%s' "$sid" "$wid" "$label" "${helper_cmd[${pid:-none}]:-}")$'\n'
    done < <(contract_json -r '.windows[] | .window_id as $w | .label as $l
      | ([.layers[]?.blocks[]?.block_id] | if length == 0 then [""] else . end)[] | [$w, $l, .] | @tsv' <<<"$info")
  done < <(contract_json -r '.sessions[].session_id' <<<"$sessions")
  REX_TABS=$(contract_json -R -s -c --argjson sessions "$sessions" '
    ($sessions.sessions | map({(.session_id): .label}) | add // {}) as $names
    | split("\n") | map(select(. != "") | split("\t"))
    | group_by(.[0] + "\t" + .[1])
    | map({session_id: .[0][0], session: $names[.[0][0]], window_id: .[0][1], label: .[0][2],
           commands: map(.[3] // "" | select(. != ""))})' <<<"$rows")
}
