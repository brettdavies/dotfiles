# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# prime: a repo's prime tab, the tab of its Rex session that holds a tmux client of the repo's prime session on the
# default tmux server. The prime map (AR_PRIMES) names each repo's prime session, one `<repo><TAB><session>` line each.

PRIME_SESSION=

# Usage: prime_of <repo>; sets PRIME_SESSION to the repo's prime session, or returns 1 when the map names none.
prime_of() {
  [[ -r $AR_PRIMES ]] || ar_fail "$(contract_error_json dependency-missing "the prime map $AR_PRIMES is not readable" \
    --value "$AR_PRIMES" --command "git -C $(contract_quote "${AR_HOME%/*/*}") status config/agent-slot-rex")"
  PRIME_SESSION=$(awk -F '\t' -v repo="$1" '!/^#/ && NF == 2 && $1 == repo { print $2; exit }' "$AR_PRIMES")
  [[ -n $PRIME_SESSION ]]
}

# Usage: prime_running <session>; true when the default tmux server has the session.
prime_running() {
  timeout --kill-after=2 10 "$AR_TMUX" has-session -t "=$1" </dev/null >/dev/null 2>&1
}

# Usage: prime_tab_open <rex-session-id> <prime-session>
# True when a tmux client of the prime session runs in a tab of the Rex session: the client's terminal is the terminal
# of a block's own process. A tab's label and position play no part, so neither a rename nor a number fools it, and a
# tab whose client detached no longer counts.
prime_tab_open() {
  local clients block tty
  clients=$(timeout --kill-after=2 10 "$AR_TMUX" list-clients -t "=$2" -F '#{client_tty}' </dev/null 2>/dev/null) \
    || return 1
  [[ -n $clients ]] || return 1
  rex_or_fail session inspect "$1" --json
  for block in $(contract_json -r '(.windows // [])[].layers[]?.blocks[]?.block_id' <<<"$REX_OUT"); do
    rex_block_pid "$1" "$block" || continue
    [[ ${REX_OUT:-0} != 0 ]] || continue
    tty=$("$AR_PS" -o tty= -p "$REX_OUT" 2>/dev/null) || continue
    tty=${tty//[[:space:]]/}
    [[ -n $tty && $tty != '?' ]] || continue
    grep -qxF "/dev/$tty" <<<"$clients" && return 0
  done
  return 1
}

# Usage: cmd_prime <repo>
# Attaches to the repo's prime session from $HOME, so the client holds no checkout, and becomes a login shell once the
# client ends, so a detach leaves the tab open.
cmd_prime() {
  prime_of "$1" || usage_fail "the prime map $AR_PRIMES names no prime session for $1" "$1"
  contract_use_tools tmux
  cd "$HOME" || exit "$EXIT_GENERAL"
  "$AR_TMUX" attach -t "=$PRIME_SESSION" || true
  exec "$AR_LOGIN_SHELL" -l
}
