# An error is "ERROR: <reason from OS_REASONS>: <message>", any cause: lines, and a final fix: line holding the command
# to run or what a person must supply. OS_VALUE, OS_CAUSE, and OS_ACTION (run-command, ask-operator, supply-input, or
# none) refine it. With --output json the same error is one JSON object; its command is null for supply-input.
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
        command: (if $command == "" or $action == "supply-input" then null else $command end),
        docs: (if $reason == "ok" then null else $docs end)},
      checks: ($checks + (if $reason == "ok" then [] else [{name: $reason, ok: false, detail: $message}] end)),
      notes: $notes}'
}

# os_fail REASON MESSAGE FIX [VALUE]: exits 1, or 2 for a usage error. Without jq the JSON mode prints a fixed object.
os_fail() {
  local code=1
  [ "$1" != usage ] || code=2
  [ "$#" -lt 4 ] || OS_VALUE=$(os_mask "$4")
  if [ "$OS_OUTPUT" = json ]; then
    if command -v jq >/dev/null 2>&1; then
      os_envelope "$1" "$code" "$2" "$3"
      exit "$code"
    fi
    printf '{"reason":"%s","exit_code":%s,"message":"jq is not on PATH, so the message is on stderr","next_step":{"action":"supply-input","command":null,"docs":"%s#%s"}}\n' \
      "$1" "$code" "$OS_RUNBOOK_URL" "$1"
  fi
  printf 'ERROR: %s: %s\n' "$1" "$2" >&2
  [ -z "$OS_CAUSE" ] || sed '/./!d; s/^/cause: /' <<<"$OS_CAUSE" >&2
  printf 'fix: %s\n' "$3" >&2
  exit "$code"
}

# The same, for an error only a person can resolve: its JSON next_step carries no command.
os_fail_input() {
  OS_ACTION=supply-input
  os_fail "$@"
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

# os_unhealthy TAIL: the failure for a stack whose gate endpoint did not answer as a running stack does.
os_unhealthy() {
  os_fail unhealthy "OpenSEO answered $OS_LOOPBACK$OS_ASKED with '${OS_HEALTH:-no answer}', so it is stopped, still starting, or failing a check; $1" "$OS_DEPLOY up" "$OS_HEALTH"
}

# os_unbind_failed TAIL: the binding is still on and `off` failed; OS_CAUSE holds tailscale's message.
os_unbind_failed() {
  os_fail unbind-failed "turning off the $OS_SERVICE binding failed; $1" "tailscale serve --service=$OS_SERVICE --https=443 off"
}

os_need_suffix() {
  os_suffix && return 0
  OS_CAUSE=$(tailscale status 2>&1 | head -n 3 | cut -c1-200 || :)
  os_fail_input tailscale-unavailable "tailscale status --json gave no MagicDNS suffix; log this host in to the tailnet; nothing changed; safe to rerun" "tailscale status, then tailscale up if it is logged out"
}

os_need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 && continue
    case $tool in
      jq | curl) os_fail tool-missing "$tool is not on PATH; nothing changed" "brew install $tool" "$tool" ;;
      *) os_fail_input tool-missing "$tool is not on PATH; nothing changed" "install $tool as BOOTSTRAP.md describes" "$tool" ;;
    esac
  done
}
