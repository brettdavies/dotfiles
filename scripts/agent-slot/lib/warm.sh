# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# agent-slot warm: trusting slot paths in Claude before their first launch, so no launch spends time on the trust step.
# agent-slot-warm.timer runs `warm --all` every ten minutes over every repo `repos` lists, so a repo cloned under the
# dev root is warmed within ten minutes of its prime being trusted. Claude keeps a path's trust after its clone is gone,
# so a pass over paths that are all trusted already changes nothing.

# Usage: warm_paths <repo> <count>
# Trusts slot paths 1..count ahead of time, creating each empty directory first, when the repo's prime checkout
# (REPO_PRIME) is trusted. A path that holds a clone or a claim is left alone. Sets WARM_RESULTS to one JSON object
# per path.
WARM_RESULTS=()
warm_paths() {
  local repo=$1 count=$2 n path result prime_trusted=0
  WARM_RESULTS=()
  ! trust_known "$REPO_PRIME" || prime_trusted=1
  for ((n = 1; n <= count; n++)); do
    path=$(slot_path "$repo" "$n")
    if slot_taken "$repo" "$n"; then
      result=in-use
    elif trust_known "$path"; then
      result=already-trusted
    elif ((prime_trusted == 0)); then
      result='prime-untrusted'
    else
      mkdir -p "$path"
      if trust_accept "$path"; then result=trusted; else result=unrecognized; fi
    fi
    WARM_RESULTS+=("$(contract_json -n -c --arg p "$path" --arg k "$(slot_key "$repo" "$n")" --arg r "$result" \
      --arg log "${TRUST_LOG:-}" '{key: $k, path: $p, result: $r} + (if $r == "unrecognized" then {log: $log} else {} end)')")
  done
}

WARM_REPO='' WARM_COUNT='' WARM_ALL=0
warm_parse_args() {
  while (($#)); do
    case $1 in
      --count)
        [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || usage_fail "--count takes a positive number" "${2:-}"
        WARM_COUNT=$2
        shift 2
        ;;
      --all)
        WARM_ALL=1
        shift
        ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        [[ -z $WARM_REPO ]] || usage_fail "warm takes one repo" "$1"
        WARM_REPO=$1
        shift
        ;;
    esac
  done
  ((WARM_ALL == 0 || ${#WARM_REPO} == 0)) || usage_fail "warm takes a repo or --all, not both" "$WARM_REPO"
  ((WARM_ALL == 1 || ${#WARM_REPO} > 0)) || usage_fail "warm needs a repo or --all; agent-slot repos lists them"
}

# Usage: warm_status <text>
# Under systemd, sets the running unit's status text, which `systemctl status` shows and the failed-units notice at
# session start names a failed unit by. The unit needs NotifyAccess=all, since systemd-notify is not its main process.
warm_status() {
  local out
  [[ -n ${NOTIFY_SOCKET:-} && -n $AS_SYSTEMD_NOTIFY ]] || return 0
  bounded out notify 5 "$AS_SYSTEMD_NOTIFY" --status="$1" || rm -f "$BOUNDED_LOG"
}

# Usage: warm_count_repos <n>; prints "<n> repo" or "<n> repos".
warm_count_repos() {
  if (($1 == 1)); then printf '1 repo'; else printf '%s repos' "$1"; fi
}

# Usage: warm_fail_untrusted <first prime> <repo>...
warm_fail_untrusted() {
  local prime=$1 count names each=each
  shift
  count=$(warm_count_repos "$#")
  names=$(printf '%s, ' "$@")
  names=${names%, }
  (($# > 1)) || each=its
  warm_status "prime untrusted in Claude for $count: $names; run claude once in $each prime"
  contract_fail prime-untrusted "Claude does not trust the prime checkout of $count, so their slot paths cannot be \
trusted: $names. Open Claude once in each prime and accept its trust dialog; the next warm trusts the paths." \
    --value "$*" --command "cd $(contract_quote "$prime") && claude"
}

cmd_warm() {
  local count=${WARM_COUNT:-$AS_MAX_PER_REPO} entry name prime json bad first_untrusted=''
  local -a entries=() rows=() untrusted=()
  require_tools tmux claude
  if ((WARM_ALL == 0)); then
    repo_prime "$WARM_REPO"
    entries=("$WARM_REPO"$'\t'"$REPO_PRIME")
  else
    mapfile -t entries < <(repo_primes | cut -f1,2)
  fi
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r name prime <<<"$entry"
    REPO_PRIME=$prime
    warm_paths "$name" "$count"
    rows+=("$(printf '%s\n' "${WARM_RESULTS[@]}" | contract_json -s -c --arg r "$name" --arg p "$prime" \
      '{repo: $r, prime: $p, paths: .}')")
    trust_known "$prime" || { untrusted+=("$name") && first_untrusted=${first_untrusted:-$prime}; }
  done
  json=$(printf '%s\n' "${rows[@]}" | contract_json -s -c 'if length == 0 then {repos: []} else {repos: .} end')
  bad=$(contract_json -c '[.repos[].paths[] | select(.result == "unrecognized")][0] // empty' <<<"$json")
  if [[ -n $bad ]]; then
    warm_status "Claude showed a screen other than its trust dialog at $(contract_json -r .path <<<"$bad")"
    contract_fail trust-dialog-unrecognized \
      "Claude showed a screen at $(contract_json -r .path <<<"$bad") that is not its trust dialog for that path, so \
the path was left untrusted" --value "$(contract_json -r .path <<<"$bad")" \
      --command "cd $(contract_json -r .path <<<"$bad") && claude" --side-effects partial \
      --log "$(contract_json -r .log <<<"$bad")"
  fi
  if ((WARM_ALL == 0)); then
    contract_ok "$(contract_json -c '{paths: .repos[0].paths}' <<<"$json")" '.paths[] | "\(.key)\t\(.result)"'
    return
  fi
  ((${#untrusted[@]} == 0)) || warm_fail_untrusted "$first_untrusted" "${untrusted[@]}"
  warm_status "all slot paths of $(warm_count_repos "${#entries[@]}") trusted in Claude"
  contract_ok "$json" '(.repos[].paths[] | select(.result == "trusted") | "\(.key)\ttrusted"),
    "warm: every slot path of \(.repos | length) repos is trusted in Claude"'
}
