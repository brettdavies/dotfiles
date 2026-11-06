# The OpenSEO bind gate, sourced by scripts/openseo-deploy.sh and scripts/tailscale-serve-setup.sh. It defines the port,
# service name, and env file paths once, prints nothing, and needs no other library, so the setup script sources it
# alone; callers report from OS_GATE. Needs curl, jq, and tailscale on PATH.
# shellcheck disable=SC2034 # globals are shared through the sourcing script

OS_PORT=8946
OS_SERVICE=svc:openseo
OS_ENV_DIR=${OPENSEO_ENV_DIR:-$HOME/.config/openseo}
OS_LOCAL_ENV=$OS_ENV_DIR/local.env
OS_LOOPBACK=http://127.0.0.1:$OS_PORT
OS_CURL_MAX=5

os_get() {
  curl -sf --max-time "$OS_CURL_MAX" "$1" 2>/dev/null | jq -r "$2" 2>/dev/null || :
}

# os_health BASE_URL sets OS_HEALTH to the status of /api/health, empty when nothing answers.
os_health() {
  OS_HEALTH=$(os_get "$1/api/health" '.status // empty')
}

# The type test is deliberate: `// empty` would turn false into nothing.
os_first_account() {
  OS_FIRST=$(os_get "$OS_LOOPBACK/api/sign-up-status" '.firstAccount | if type == "boolean" then tostring else empty end')
}

os_suffix() {
  OS_SUFFIX=$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // empty' 2>/dev/null) || OS_SUFFIX=
  [[ $OS_SUFFIX =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# The service name anywhere in the serve config means a binding exists. grep -q in a pipe could end it early (SIGPIPE).
os_bound() {
  local out
  out=$(tailscale serve status --json 2>/dev/null) || return 1
  [[ $out == *"\"$OS_SERVICE\""* ]]
}

# Proof that the control plane lists this host for the service, which the exit code of `serve` is not.
os_advertised() {
  tailscale status --json 2>/dev/null \
    | jq -e --arg s "$OS_SERVICE" '[.Self.CapMap["service-host"][]? | keys[]] | index($s) != null' >/dev/null 2>&1
}

# os_publish returns 1 when the bind fails and 2 when the control plane does not list the service.
os_publish() {
  tailscale serve --service="$OS_SERVICE" --https=443 --yes "$OS_LOOPBACK" || return 1
  os_advertised || return 2
}

# os_gate_check sets OS_GATE to ok, unhealthy (OS_HEALTH holds the answer), or first-account-open.
os_gate_check() {
  os_health "$OS_LOOPBACK"
  OS_GATE=unhealthy
  [ "$OS_HEALTH" = ok ] || return 1
  os_first_account
  case "$OS_FIRST" in
    false) OS_GATE=ok ;;
    true) OS_GATE=first-account-open ;;
    *) OS_HEALTH='no answer from /api/sign-up-status' ;;
  esac
  [ "$OS_GATE" = ok ]
}

# A bound service stays bound when its stack restarts, so a stack that lets its first visitor become administrator
# has its binding turned off (OS_UNBOUND=1), or OS_GATE=unbind-failed.
os_gate() {
  OS_UNBOUND=0
  os_gate_check && return 0
  if [ "$OS_GATE" = first-account-open ] && os_bound; then
    if tailscale serve --service="$OS_SERVICE" --https=443 off >/dev/null; then OS_UNBOUND=1; else OS_GATE=unbind-failed; fi
  fi
  return 1
}
