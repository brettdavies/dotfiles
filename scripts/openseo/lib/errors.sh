# An error is "ERROR: <reason from OS_REASONS>: <message>", any cause: lines, and a final fix: line holding the command
# to run or what a person must supply. OS_VALUE, OS_CAUSE, and OS_ACTION (run-command or supply-input) refine it. With
# --output json the same error is one JSON object.
# shellcheck disable=SC2034,SC2088 # globals are shared through the sourcing script; the tilde stays literal

OS_DEPLOY='~/dotfiles/scripts/openseo-deploy.sh'
OS_RUNBOOK_URL='https://github.com/brettdavies/dotfiles/blob/dev/docs/runbooks/openseo.md'
OS_REASONS='usage tool-missing unsupported-host pin-invalid pin-mismatch item-unreadable value-unsafe
  storage-key-changed tailscale-unavailable env-missing pull-failed up-failed init-failed stop-failed unhealthy
  first-account-open account-exists create-admin-failed bind-failed unbind-failed service-not-advertised
  address-unreachable'
OS_OUTPUT=text OS_ACTION=run-command OS_VALUE='' OS_CAUSE=''
OS_CHECKS='[]' OS_NOTES='[]'

os_mask() {
  local LC_ALL=C v="${1//[^A-Za-z0-9._:\/@=+~ -]/?}"
  printf '%s' "${v:0:120}"
}

os_envelope() {
  jq -n --arg reason "$1" --argjson code "$2" --arg message "$3" --arg command "$4" --arg action "$OS_ACTION" \
    --arg value "$OS_VALUE" --arg cause "$OS_CAUSE" --arg docs "$OS_RUNBOOK_URL#$1" \
    --argjson checks "$OS_CHECKS" --argjson notes "$OS_NOTES" \
    '{reason: $reason, exit_code: $code, message: $message, value: (if $value == "" then null else $value end),
      cause: (if $cause == "" then null else $cause end),
      next_step: {action: $action,
        command: (if $command == "" or $action != "run-command" then null else $command end),
        docs: (if $reason == "ok" then null else $docs end)},
      checks: $checks, notes: $notes}'
}

# os_fail REASON MESSAGE FIX: exits 1, or 2 for a usage error.
os_fail() {
  local code=1 line
  [ "$1" != usage ] || code=2
  if [ "$OS_OUTPUT" = json ]; then
    os_envelope "$1" "$code" "$2" "$3"
    exit "$code"
  fi
  printf 'ERROR: %s: %s\n' "$1" "$2" >&2
  while IFS= read -r line; do
    [ -z "$line" ] || printf 'cause: %s\n' "$line" >&2
  done <<<"$OS_CAUSE"
  printf 'fix: %s\n' "$3" >&2
  exit "$code"
}

os_note() {
  if [ "$OS_OUTPUT" = json ]; then
    OS_NOTES=$(jq -c --arg n "$1" '. + [$n]' <<<"$OS_NOTES")
  else
    printf 'NOTE: %s\n' "$1" >&2
  fi
}

# os_try COMMAND... replays the command's stderr and keeps its last lines in OS_CAUSE when it fails.
os_try() {
  local rc=0 err
  err=$(mktemp)
  "$@" 2>"$err" || rc=$?
  cat "$err" >&2
  OS_CAUSE=
  [ "$rc" -eq 0 ] || OS_CAUSE=$(tail -n 5 "$err" | cut -c1-200)
  rm -f "$err"
  return "$rc"
}

# os_unhealthy TAIL: the failure for a stack whose /api/health did not answer ok.
os_unhealthy() {
  OS_VALUE=$OS_HEALTH
  os_fail unhealthy "OpenSEO answered $OS_LOOPBACK/api/health with '${OS_HEALTH:-no answer}'; $1" "$OS_DEPLOY up"
}

os_need_suffix() {
  os_suffix || os_fail tailscale-unavailable "tailscale status --json gave no MagicDNS suffix; nothing changed; safe to rerun" "tailscale up"
}

os_need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || {
      OS_VALUE=$tool
      os_fail tool-missing "$tool is not on PATH; nothing changed" "brew install $tool"
    }
  done
}
