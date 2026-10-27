# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# agent-slot doctor: every launch prerequisite on the Linux server, and launch times against the 30-second target.
#
# Each finding is an error object (contract_error_json) plus a severity. A missing prerequisite never stops the other
# checks. Versions that differ from scripts/agent-slot/verified-versions only warn. Exit 1 when any finding is an
# error.

DOCTOR_FINDINGS=()
DOCTOR_TARGET_S=30

# Usage: doctor_finding <error | warning> <reason> <message> [contract_error_json options]
doctor_finding() {
  local severity=$1
  shift
  DOCTOR_FINDINGS+=("$(contract_error_json "$@" | contract_json -c --arg s "$severity" '. + {severity: $s}')")
}

_doctor_install_hint() {
  case $1 in
    claude) echo 'curl -fsSL https://claude.ai/install.sh | bash' ;;
    timeout) echo 'brew install coreutils' ;;
    trash) echo 'brew install trash-cli' ;;
    jq) echo 'brew install jaq' ;;
    *) echo "brew install $1" ;;
  esac
}

# Prints "<tool> <version>" lines from the verified-versions file.
doctor_verified() {
  [[ -r $AS_VERIFIED_VERSIONS ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$AS_VERIFIED_VERSIONS"
}

doctor_check_tools() {
  local tool
  for tool in tmux claude gh git-crypt git flock timeout trash; do
    [[ -n ${AS_TOOL[$tool]:-} ]] && continue
    doctor_finding error dependency-missing "$tool is not on the pinned PATH ($PATH)" --value "$tool" \
      --command "$(_doctor_install_hint "$tool")"
  done
}

doctor_check_config() {
  local out
  if [[ -n ${AS_TOOL[gh]:-} ]] && ! bounded out gh-auth 15 "${AS_TOOL[gh]}" auth status; then
    doctor_finding error gh-auth-missing "gh is not signed in, so PR state cannot be read" --command "gh auth login" \
      --log "$BOUNDED_LOG"
  fi
  [[ -r $AS_GIT_CRYPT_KEY ]] || doctor_finding error git-crypt-key-missing \
    "no git-crypt key at $AS_GIT_CRYPT_KEY, so slots of git-crypt repos cannot be unlocked" --value "$AS_GIT_CRYPT_KEY" \
    --command "op document get 'git-crypt key' --vault secrets-dev --out-file $AS_GIT_CRYPT_KEY"
  [[ -d $AS_SOLUTIONS ]] || doctor_finding error solutions-corpus-missing \
    "the shared solutions repo is missing at $AS_SOLUTIONS, so no slot can get its docs/solutions link" \
    --value "$AS_SOLUTIONS" --command "git clone git@github.com:brettdavies/solutions-docs.git $AS_SOLUTIONS"
  [[ -r $AS_TMUX_CONF ]] || doctor_finding error slots-config-missing \
    "$AS_TMUX_CONF is missing, so the slot tmux server would load the default config" --value "$AS_TMUX_CONF" \
    --command "cd ~/dotfiles && scripts/stow-deploy tmux"
  if [[ -n $AS_SYSTEMCTL ]] \
    && [[ $("$AS_SYSTEMCTL" --user is-enabled tmux-prune-orphans-slots.timer 2>/dev/null) != enabled ]]; then
    doctor_finding error prune-timer-inactive "the slot server's orphan-client prune timer is not enabled" \
      --value tmux-prune-orphans-slots.timer --command "systemctl --user enable --now tmux-prune-orphans-slots.timer"
  fi
}

doctor_check_trust() {
  local repo n=1 prime
  while read -r repo; do
    [[ -n $repo ]] || continue
    n=1
    while slot_taken "$repo" "$n"; do n=$((n + 1)); done
    trust_known "$(slot_path "$repo" "$n")" && continue
    prime=$(repo_primes | awk -F '\t' -v r="$repo" '$1 == r { print $2 }')
    if [[ -n $prime ]] && ! trust_known "$prime"; then
      doctor_finding warning slot-path-untrusted \
        "$repo's prime $prime is not trusted in Claude, so its slots start at trust needed; open Claude there once" \
        --value "$prime"
      continue
    fi
    doctor_finding warning slot-path-untrusted \
      "$(slot_key "$repo" "$n") is not trusted in Claude yet, so its first launch spends time on the trust step" \
      --value "$(slot_path "$repo" "$n")" --command "agent-slot warm $repo"
  done < <(slot_repos)
}

doctor_check_versions() {
  local installed verified message
  [[ -n ${AS_TOOL[claude]:-} ]] || return 0
  installed=$(bounded_version claude)
  verified=$(doctor_verified | awk '$1 == "claude" { print $2 }')
  [[ -n $installed && $installed != "$verified" ]] || return 0
  message="Claude Code $installed differs from the version the two-machine checklist last ran on (${verified:-none});"
  message+=" run the checklist, then update scripts/agent-slot/verified-versions"
  doctor_finding warning version-unverified "$message" --value "$installed"
}

bounded_version() {
  local out
  bounded out "$1-version" 10 "${AS_TOOL[$1]}" --version || return 0
  awk 'NR == 1 { print $1 }' <<<"$out"
}

# Launch times over the last 20 launches, from the ledger's launch lines joined to their ready lines by request ID.
# A negative duration is clock skew between the two machines and is left out.
doctor_launch_times() {
  [[ -r $AS_LEDGER ]] || {
    contract_json -n -c --argjson t "$DOCTOR_TARGET_S" '{launches: 0, measured: 0, not_ready: [], skewed: 0,
      median_s: null, p90_s: null, target_s: $t}'
    return
  }
  tail -n 4000 "$AS_LEDGER" | contract_json -s -c --argjson t "$DOCTOR_TARGET_S" '
    (map(select(.event == "ready")) | map({key: .request_id, value: .ready_at}) | from_entries) as $ready
    | (map(select(.event == "launch" and (.request_id // "") != "")) | .[-20:]) as $launches
    | [$launches[] | {request_id, requested_at, ready_at: $ready[.request_id]}] as $rows
    | [$rows[] | select(.ready_at != null and .requested_at != null) | .ready_at - .requested_at] as $all
    | ($all | map(select(. >= 0)) | sort) as $d
    | ($d | length) as $n
    | {launches: ($launches | length), measured: $n,
       not_ready: [$rows[] | select(.ready_at == null) | .request_id],
       skewed: ($all | map(select(. < 0)) | length),
       median_s: (if $n == 0 then null elif $n % 2 == 1 then $d[($n - 1) / 2 | floor]
                  else ($d[$n / 2 - 1 | floor] + $d[$n / 2 | floor]) / 2 end),
       p90_s: (if $n == 0 then null else $d[($n * 0.9 | ceil) - 1 | floor] end),
       target_s: $t}'
}

cmd_doctor() {
  local findings times errors
  contract_use_tools tmux claude gh git-crypt
  doctor_check_tools
  doctor_check_config
  doctor_check_trust
  doctor_check_versions
  times=$(doctor_launch_times)
  findings=$(printf '%s\n' "${DOCTOR_FINDINGS[@]}" | contract_json -s -c 'map(select(. != null))')
  errors=$(contract_json '[.[] | select(.severity == "error")] | length' <<<"$findings")
  contract_ok "$(contract_json -n -c --argjson f "$findings" --argjson t "$times" --argjson e "$errors" \
    --arg verified "$(doctor_verified)" '{ok: ($e == 0), findings: $f, launch_times: $t,
      verified_versions: ($verified | split("\n") | map(select(. != "") | split(" ")) | map({(.[0]): .[1]}) | add)}')" '
    (.findings[] | "\(.severity | ascii_upcase)\t\(.reason): \(.message)" +
      (if .next_step.command then "\n\tnext: \(.next_step.command)" else "" end)),
    (.launch_times | if .measured == 0 then "launch times: none measured yet (target \(.target_s) s)"
     else "launch times: median \(.median_s) s, p90 \(.p90_s) s over \(.measured) launches (target \(.target_s) s)"
     end + (if (.not_ready | length) > 0 then ", \(.not_ready | length) not ready" else "" end)),
    (if .ok then "doctor: no errors" else "doctor: \([.findings[] | select(.severity == "error")] | length) error(s)" end)'
  ((errors == 0)) || exit "$EXIT_GENERAL"
}
