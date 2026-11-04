# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# prime: holding a repo's prime in a tab. A prime runs on the slot server, three sessions a tab shows as a slot's are, or
# old-style, as one session on the default tmux server named by the prime map (AR_PRIMES, `<repo><TAB><name>` lines),
# until that session is closed. A repo's name in a tab is the map's, else the repo's own. A session on the default server
# holding no Claude is no prime.

PRIME_LABEL=

# Usage: prime_of <repo>; sets PRIME_LABEL to the name the repo's prime goes by.
prime_of() {
  [[ -r $AR_PRIMES ]] || ar_fail "$(contract_error_json dependency-missing "the prime map $AR_PRIMES is not readable" \
    --value "$AR_PRIMES" --command "git -C $(contract_quote "${AR_HOME%/*/*}") status config/agent-slot-rex")"
  PRIME_LABEL=$(prime_display_name "$1" "$AR_PRIMES")
}

# Usage: prime_old_running <label>; true when the session of that name on the default tmux server holds a Claude. A
# server that does not answer counts as none, since agent-slot prime, which every start goes through, refuses then.
prime_old_running() {
  local panes held
  panes=$(timeout --kill-after=2 10 "$AR_TMUX" -u -L "$TMUX_DEFAULT_SOCKET" list-panes -a -F "$PRIME_OLD_PANES_FORMAT" \
    </dev/null 2>/dev/null) || return 1
  held=$(prime_old_sessions <<<"$panes")
  grep -qxF -- "$(tmux_name "$1")" <<<"$held"
}

# Usage: prime_old_clients <label>; prints the terminals of the tmux clients of that session on the default server. A read
# that fails prints none: the caller then opens a tab, which costs a tab at worst.
prime_old_clients() {
  timeout --kill-after=2 10 "$AR_TMUX" -L "$TMUX_DEFAULT_SOCKET" list-clients -t "=$(tmux_name "$1")" -F '#{client_tty}' \
    </dev/null 2>/dev/null || true
}

# Usage: prime_tab_open <rex-session-id> <repo> <label> [<window to leave out>]
# True when a tab of the Rex session holds the repo's prime: a block's own process is the attach loop of its Claude pane,
# which stays true while the loop waits after a detach; a tmux client of its old-style session runs on a block's terminal;
# or another window carries its label while its own process is this helper's launch, as a key's tab does before it asks
# the server to start anything. A tab's label alone plays no part, so neither a rename nor a number fools it.
prime_tab_open() {
  local sid=$1 repo=$2 label=$3 own_window=${4:-} clients='' rows window title block pid command tty
  if prime_old_running "$label"; then
    clients=$(prime_old_clients "$label")
  fi
  rex_or_fail session inspect "$sid" --json
  rows=$(contract_json -r "$REX_LABEL_DEF"'(.windows // [])[] | .window_id as $w | ((.label // "") | rex_unnumbered) as $l
    | .layers[]?.blocks[]?.block_id | [$w, $l, .] | @tsv' <<<"$REX_OUT")
  rex_helper_processes
  [[ -z $clients ]] || rex_block_terminals
  while IFS=$'\t' read -r window title block; do
    [[ -n $block ]] || continue
    rex_block_pid "$sid" "$block" || continue
    pid=${REX_OUT:-0}
    [[ $pid != 0 ]] || continue
    command=${REX_HELPER_CMD[$pid]:-}
    [[ $command != *"agent-slot-rex attach $repo/$SLOT_PRIME claude" ]] || return 0
    if [[ $window != "$own_window" && $title == "$label" && $command == *"agent-slot-rex launch"* ]]; then
      return 0
    fi
    [[ -n $clients ]] || continue
    tty=${REX_BLOCK_TTY[$pid]:-}
    [[ -n $tty && $tty != '?' ]] || continue
    ! grep -qxF "/dev/$tty" <<<"$clients" || return 0
  done <<<"$rows"
  return 1
}

# Usage: cmd_prime <repo>
# Holds this pane on the repo's prime, from $HOME, so the client holds no checkout. An old-style session is attached to
# until the client ends, and the pane then becomes a login shell, so a detach leaves the tab open. Anything else becomes
# the attach loop of the prime's Claude pane, which starts the prime if it is not running.
cmd_prime() {
  prime_of "$1"
  contract_use_tools tmux
  cd "$HOME" || exit "$EXIT_GENERAL"
  if prime_old_running "$PRIME_LABEL"; then
    "$AR_TMUX" -L "$TMUX_DEFAULT_SOCKET" attach -t "=$(tmux_name "$PRIME_LABEL")" || true
    exec "$AR_LOGIN_SHELL" -l
  fi
  exec "$AR_SELF" attach "$(slot_key "$1" "$SLOT_PRIME")" claude
}
