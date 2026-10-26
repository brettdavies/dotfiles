# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# doctor: the Mac's launch prerequisites, then the server's own doctor through the ssh alias.
#
# Each finding is an error object (contract_error_json) plus a severity and the host it is about. A missing
# prerequisite never stops the other checks, and an unreachable server still leaves every Mac check reported. Each
# server finding's next step is rewritten to run through the alias, so it can be pasted on the Mac. A Rex version that
# differs from scripts/agent-slot/verified-versions only warns. Exit 1 when any finding is an error.

DOCTOR_FINDINGS=()

# Usage: doctor_finding <error | warning> <reason> <message> [contract_error_json options]
doctor_finding() {
  local severity=$1
  shift
  DOCTOR_FINDINGS+=("$(contract_error_json "$@" \
    | contract_json -c --arg s "$severity" '. + {severity: $s, host: "mac"}')")
}

doctor_check_rex() {
  local verified
  if [[ -z $AR_REX ]]; then
    doctor_finding error dependency-missing "the rex CLI is not in REX_BIN_DIR or the Rex app" \
      --value "${REX_BIN_DIR:-}" --command "open -a 'Rex Beta'"
    return
  fi
  if ! rex_actions; then
    doctor_finding error rex-failed "rex actions --json exited non-zero, so the Rex server did not answer" \
      --value "$AR_REX" --command "$(contract_quote "$AR_REX" actions --json)"
  elif ! contract_json -e '[.actions[]?.name] | index("agent_slot_new") != null' <<<"$REX_OUT" >/dev/null; then
    doctor_finding error rex-action-unregistered \
      "Rex has not loaded agent-slots.lua: agent_slot_new is not among its actions" --value agent_slot_new \
      --command "cd ~/dotfiles && scripts/stow-deploy rex"
  fi
  rex_version || return 0
  verified=$(awk '!/^[[:space:]]*#/ && $1 == "rex" { print $2 }' "$AR_VERIFIED" 2>/dev/null || true)
  [[ -n $REX_OUT && $REX_OUT != "$verified" ]] || return 0
  doctor_finding warning version-unverified \
    "Rex $REX_OUT differs from the version the two-machine checklist last ran on (${verified:-none})" \
    --value "$REX_OUT" --command "run the two-machine checklist, then update scripts/agent-slot/verified-versions"
}

doctor_check_tools() {
  local tool hint
  for tool in "$AR_SSH" timeout; do
    command -v "$tool" >/dev/null && continue
    case $tool in
      timeout) hint='brew install coreutils' ;;
      *) hint='brew install openssh' ;;
    esac
    doctor_finding error dependency-missing "$tool is not on PATH ($PATH)" --value "$tool" --command "$hint"
  done
}

# Sets DOCTOR_SERVER to the server's doctor output with each next step run through the alias, or adds the finding
# that says why it could not run.
DOCTOR_SERVER='{}'
doctor_check_server() {
  local findings
  server_ssh 120 doctor "$AR_REMOTE doctor --output json" || true
  if contract_json -e '.findings | type == "array"' <<<"$SERVER_OUT" >/dev/null 2>&1; then
    DOCTOR_SERVER=$(contract_json -c --arg alias "$AR_SERVER" --arg q "'" '
      .findings |= map(. + {host: "server"}
        | if .next_step.command != null
          then .next_step.command = "ssh \($alias) " + $q + (.next_step.command | gsub($q; $q + "\\" + $q + $q)) + $q
          else . end)' <<<"$SERVER_OUT")
    findings=$(contract_json -c '.findings[]' <<<"$DOCTOR_SERVER")
    [[ -z $findings ]] || mapfile -t -O "${#DOCTOR_FINDINGS[@]}" DOCTOR_FINDINGS <<<"$findings"
    return
  fi
  server_error 120 doctor
  DOCTOR_FINDINGS+=("$(contract_json -c '. + {severity: "error", host: "server"}' <<<"$AR_ERROR")")
}

cmd_doctor() {
  local findings errors
  contract_use_tools rex ssh
  doctor_check_rex
  doctor_check_tools
  doctor_check_server
  findings=$(printf '%s\n' "${DOCTOR_FINDINGS[@]}" | contract_json -s -c 'map(select(. != null))')
  errors=$(contract_json '[.[] | select(.severity == "error")] | length' <<<"$findings")
  contract_ok "$(contract_json -n -c --argjson f "$findings" --argjson e "$errors" --argjson s "$DOCTOR_SERVER" \
    --arg server "$AR_SERVER" --arg rex "$AR_REX" '{ok: ($e == 0), server: $server,
      rex: (if $rex == "" then null else $rex end), findings: $f, launch_times: ($s.launch_times // null),
      verified_versions: ($s.verified_versions // null)}')" '
    (.findings[] | "\(.severity | ascii_upcase)\t\(.host): \(.reason): \(.message)" +
      (if .next_step.command then "\n\tnext: \(.next_step.command)" else "" end)),
    (.launch_times | if . == null then empty
     elif .measured == 0 then "launch times: none measured yet (target \(.target_s) s)"
     else "launch times: median \(.median_s) s, p90 \(.p90_s) s over \(.measured) launches (target \(.target_s) s)"
     end),
    (if .ok then "doctor: no errors"
     else "doctor: \([.findings[] | select(.severity == "error")] | length) error(s)" end)'
  ((errors == 0)) || exit "$EXIT_GENERAL"
}
