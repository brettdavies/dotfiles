# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The start-up step's re-attach of the prime tabs rexurrect restores. rexurrect brings a prime tab back under its label
# and in its place, but as plain shells, so the tab no longer counts as the prime (prime_tab_open) and the next
# new-agent key would open a second prime tab beside it. Once per server instance, after rexurrect and before the
# reconcile, the step takes each repo of the prime map, and each other repo with a Rex session, whose session has no tab
# holding its prime, and looks at the first tab whose label past its number is the prime's name. When that tab is one pane
# whose shell sits at its prompt, it types the prime command, the one an old-style prime's tab runs, unless no old-style
# session holds a Claude, which gets nothing typed. When it is three panes whose shells each sit at a prompt, it starts
# the prime and replaces the tab through reconcile's own open, since no typed command can make plain shells into the
# layout. Any other tab is left alone.
#
# Each repo's check runs in a subshell of its own, so a rex call that fails there costs that repo alone and the step
# still reaches its reconcile. A restart seen partway ends the walk and leaves REX_PIN_LOST set.
#
# PRIME_REATTACHED holds each repo's outcome as {repo, prime, outcome, session_id, window_id}, the outcome being
# reattached, unconfirmed (typed, but no client of the prime showed within AR_PRIME_WAIT), reopened (replaced by a new
# tab, whose ID is not the one kept here), already-open, no-session, no-tab, not-idle, prime-not-running,
# rex-server-restarted, rex-server-down, or the reason of the error that stopped the repo's check. It stays null in every
# pass that does not re-attach.

PRIME_REATTACHED=null

# Ctrl-E, then Ctrl-U: to the line's end, then kill back to its start, in zsh's and bash's emacs keymaps. rexurrect
# 0.3.0 types a restored block's last command at its prompt without running it, and the prime command must replace it
# rather than land after it. The command's leading space keeps it out of the shell's history (HIST_IGNORE_SPACE in
# stow/zsh/dot-zshrc).
REATTACH_CLEAR_LINE=$'\005\025'

REATTACH_SHELLS='^-?(sh|bash|zsh|dash|ksh|mksh|tcsh|csh|fish)$'

# The field separator of a repo's result line: not whitespace, unlike a tab, so `read` keeps an empty field in place.
REATTACH_SEP=$'\x1f'

# Usage: reattach_shell_idle <session-id> <block-id>; true when the block's own process is a shell at its prompt: its
# terminal's foreground process is that process, and its command line is a shell given options alone. A script runs
# in its terminal's foreground just as an idle shell does, the helper itself included: a prime tab's helper holds its
# tmux client in its own process group, so typing there would land in the prime session.
reattach_shell_idle() {
  local pid word
  local -a words=()
  rex_or_fail block call -s "$1" -b "$2" process
  pid=$(contract_json -r '.child.pid as $p | select($p != null and .foreground.pid == $p) | $p' <<<"$REX_OUT")
  [[ -n $pid ]] || return 1
  read -r -a words < <("$AR_PS" -o args= -p "$pid" 2>/dev/null) || true
  ((${#words[@]} > 0)) && [[ ${words[0]##*/} =~ $REATTACH_SHELLS ]] || return 1
  for word in "${words[@]:1}"; do
    [[ $word == -* ]] || return 1
  done
}

# Usage: reattach_reopen <repo> <prime> <window-id> <block...>
# Sets REATTACH_OUTCOME and REATTACH_NOTE for a restored tab of several panes: replaced when every pane is a shell at its
# prompt and the prime runs on the slot server, else left as it is. A new tab opens before the old one closes, the order
# reconcile uses, so the session is never left empty.
REATTACH_OUTCOME='' REATTACH_NOTE=''
reattach_reopen() {
  local repo=$1 prime=$2 wid=$3 sid=$REX_SID block
  shift 3
  REATTACH_OUTCOME=not-idle
  for block in "$@"; do
    reattach_shell_idle "$sid" "$block" || return 0
  done
  if ! server_call 180 prime "$repo"; then
    REATTACH_OUTCOME=$(contract_json -r '.reason' <<<"$AR_ERROR")
    REATTACH_NOTE=$(contract_json -r '.message' <<<"$AR_ERROR")
    return 0
  fi
  [[ $(contract_json -r '.server' <<<"$SERVER_OUT") == slots ]] || return 0
  reconcile_open_tab "$repo" "$(slot_key "$repo" "$SLOT_PRIME")" "$prime" slots
  rex_close "$sid" "$wid"
  REATTACH_OUTCOME=reopened
  [[ -z $REX_PIN_LOST ]] || REATTACH_OUTCOME=$(contract_json -r '.reason' <<<"$REX_PIN_LOST")
}

# Usage: reattach_repo <repo> <prime>
# Prints the repo's outcome, session ID, window ID, and the tab's label or what stopped it, joined by REATTACH_SEP, and
# types the prime command into its restored prime tab where the outcome is `sent`. It can end its shell through ar_fail,
# so it runs only in reattach_primes's subshell.
reattach_repo() {
  local repo=$1 prime=$2 outcome wid='' blocks='' label='' sid
  local -a panes=()
  rex_session_find "$repo"
  sid=$REX_SID
  if [[ -z $REX_SID ]]; then
    outcome=no-session
  elif prime_tab_open "$REX_SID" "$repo" "$prime"; then
    outcome=already-open
  else
    rex_or_fail session inspect "$REX_SID" --json
    IFS=$REATTACH_SEP read -r wid blocks label < <(contract_json -r --arg p "$prime" --arg sep "$REATTACH_SEP" \
      "$REX_LABEL_DEF"'first(.windows[] | select((.label // "") | rex_unnumbered == $p))
      | [.window_id, ([.layers[]?.blocks[]?.block_id] | join(" ")), .label] | join($sep)' <<<"$REX_OUT") \
      || true
    read -r -a panes <<<"$blocks"
    if [[ -z $wid ]]; then
      outcome=no-tab
    elif ((${#panes[@]} == 3)); then
      reattach_reopen "$repo" "$prime" "$wid" "${panes[@]}"
      outcome=$REATTACH_OUTCOME
      label=${REATTACH_NOTE:-$label}
    elif ! prime_old_running "$prime"; then
      outcome='prime-not-running'
    elif ((${#panes[@]} != 1)) || ! reattach_shell_idle "$sid" "${panes[0]}"; then
      outcome=not-idle
    else
      rex_send "$sid" "${panes[0]}" "$REATTACH_CLEAR_LINE exec $(contract_quote "$AR_SELF" prime "$repo")"$'\r'
      outcome=sent
      [[ -z $REX_PIN_LOST ]] || outcome=$(contract_json -r '.reason' <<<"$REX_PIN_LOST")
    fi
  fi
  printf '%s\n' "$outcome$REATTACH_SEP$sid$REATTACH_SEP$wid$REATTACH_SEP$label"
}

# Prints what the step walks, one `<repo><TAB><name>` line each: the prime map's lines, then each other repo the server
# lists with a Rex session, under its own name. A repos call that fails leaves the map's lines.
reattach_walk() {
  local mapped name
  awk -F '\t' '!/^#/ && NF == 2 && !seen[$1]++' "$AR_PRIMES"
  mapped=$(awk -F '\t' '!/^#/ && NF == 2 { print $1 }' "$AR_PRIMES")
  server_call 30 repos || return 0
  rex_run ls --json || return 0
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    grep -qxF -- "$name" <<<"$mapped" || printf '%s\t%s\n' "$name" "$name"
  done < <(contract_json -r --argjson rex "$REX_OUT" '([$rex.sessions[].label]) as $labels
    | .repos[]?.name | select(. as $n | $labels | index($n) != null)' <<<"$SERVER_OUT" || true)
}

# Usage: reattach_log <repo> <prime> <outcome> <tab label, or the error's message>
reattach_log() {
  local what
  case $3 in
    reattached) what="tab $4 holds the prime again" ;;
    reopened) what="tab $4 was three plain shells, so a new tab holds the prime in its place" ;;
    unconfirmed) what="typed the prime command into tab $4, but no client showed within $AR_PRIME_WAIT s" ;;
    already-open) what='a tab of the session holds it' ;;
    no-session) what="no Rex session is named $1" ;;
    no-tab) what="no tab of the session is labelled $2" ;;
    not-idle) what="tab $4 is not one pane or three at shell prompts holding this prime, so it is left alone" ;;
    prime-not-running) what="no session named $2 on the default tmux server holds a Claude, so tab $4 stays a shell; \
$(contract_quote "$AR_SELF" prime "$1") in that tab starts the prime" ;;
    *) what=$4 ;;
  esac
  startup_log "prime $1 ($2): $3: $what"
}

# Usage: reattach_wait <outcomes-array-name> <sessions-array-name> <repos-array-name> <primes-array-name>
# Turns each `sent` outcome into reattached once a tab of its session holds a client of the prime, polling until none
# is left or AR_PRIME_WAIT seconds pass, and the rest into unconfirmed.
reattach_wait() {
  local -n outcomes_=$1 sessions_=$2 repos_=$3 primes_=$4
  local deadline=$((SECONDS + AR_PRIME_WAIT)) i waiting
  while true; do
    waiting=0
    for i in "${!outcomes_[@]}"; do
      [[ ${outcomes_[i]} == sent ]] || continue
      if (JOURNAL_BY='' && prime_tab_open "${sessions_[i]}" "${repos_[i]}" "${primes_[i]}") >/dev/null 2>&1; then
        outcomes_[i]=reattached
      else
        waiting=1
      fi
    done
    ((waiting == 1 && SECONDS < deadline)) || break
    sleep 0.25
  done
  for i in "${!outcomes_[@]}"; do
    [[ ${outcomes_[i]} != sent ]] || outcomes_[i]=unconfirmed
  done
}

# Re-attaches each repo's restored prime tab, and sets PRIME_REATTACHED and JOURNAL_PRIMES.
reattach_primes() {
  local repo prime out err line outcome sid wid label rows='' i
  local -a repos=() primes=() outcomes=() sids=() wids=() notes=()
  PRIME_REATTACHED='[]' JOURNAL_PRIMES='[]'
  if [[ ! -r $AR_PRIMES ]]; then
    startup_log "primes: the prime map $AR_PRIMES is not readable, so no prime tab is reattached"
    return 0
  fi
  out=$(mktemp) err=$(mktemp)
  REX_PIN=$REX_SERVER_INSTANCE REX_PIN_LOST=''
  while IFS=$'\t' read -r repo prime; do
    # In the background, since a subshell whose status is tested runs with errexit off.
    (
      JOURNAL_BY='' CONTRACT_OUTPUT=json
      reattach_repo "$repo" "$prime"
    ) >"$out" 2>"$err" </dev/null &
    wait "$!" || true
    outcome='' sid='' wid='' label=''
    IFS=$REATTACH_SEP read -r outcome sid wid label <"$out" || true
    if [[ -z $outcome ]]; then
      line=$(grep '^{' "$err" | tail -1 || true)
      outcome=$(contract_json -r '.reason // empty' <<<"$line" 2>/dev/null || true)
      label=$(contract_json -r '.message // empty' <<<"$line" 2>/dev/null || true)
      outcome=${outcome:-script-error} label=${label:-the check stopped unexpectedly}
      sid='' wid=''
    fi
    repos+=("$repo") primes+=("$prime") outcomes+=("$outcome") sids+=("$sid") wids+=("$wid") notes+=("$label")
    [[ $outcome != rex-server-restarted && $outcome != rex-server-down ]] || break
  done < <(reattach_walk)
  rm -f "$out" "$err"
  [[ " ${outcomes[*]} " != *" rex-server-restarted "* && " ${outcomes[*]} " != *" rex-server-down "* ]] \
    || rex_pinned || true
  REX_PIN=''
  [[ -n $REX_PIN_LOST ]] || reattach_wait outcomes sids repos primes
  for i in "${!outcomes[@]}"; do
    reattach_log "${repos[i]}" "${primes[i]}" "${outcomes[i]}" "${notes[i]}"
    rows+=$(printf '%s\t%s\t%s\t%s\t%s' "${repos[i]}" "${primes[i]}" "${outcomes[i]}" "${sids[i]}" "${wids[i]}")$'\n'
  done
  PRIME_REATTACHED=$(contract_json -R -s -c 'split("\n") | map(select(. != "") | split("\t")
    | {repo: .[0], prime: .[1], outcome: .[2], session_id: (.[3] | if . == "" then null else . end),
       window_id: (.[4] | if . == "" then null else . end)})' <<<"$rows")
  JOURNAL_PRIMES=$PRIME_REATTACHED
}
