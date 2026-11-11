# The OpenSEO bind gate, sourced by scripts/openseo-deploy.sh and scripts/tailscale-serve-setup.sh. It defines the port,
# service name, and env file paths once, prints nothing, and needs no other library, so the setup script sources it
# alone; callers report from OS_GATE. Needs curl, jq, and tailscale on PATH.
# shellcheck disable=SC2034 # globals are shared through the sourcing script

OS_PORT=8946
OS_SERVICE=svc:openseo
OS_ENV_DIR=${OPENSEO_ENV_DIR:-$HOME/.config/openseo}
OS_LOCAL_ENV=$OS_ENV_DIR/local.env
OS_ENV_SHOWN=${OS_LOCAL_ENV/#$HOME/\~}
OS_LOOPBACK=http://127.0.0.1:$OS_PORT
OS_CURL_MAX=5
OS_ADVERTISE_WAIT=${OPENSEO_ADVERTISE_WAIT:-15}

os_here() { "$@"; }

# Runs a command on the host that runs OpenSEO: this one, or the NAS over ssh under --host nas (scripts/openseo/lib/nas.sh).
os_on_host() {
  if [ "${OS_HOST:-local}" = nas ]; then os_nas_ssh "$@"; else "$@"; fi
}

# os_get URL JQ_FILTER [RUNNER]: RUNNER defaults to os_on_host; os_here reads from this host whatever OS_HOST is.
os_get() {
  "${3:-os_on_host}" curl -sf --max-time "$OS_CURL_MAX" "$1" 2>/dev/null | jq -r "$2" 2>/dev/null || :
}

# os_health BASE_URL [RUNNER] sets OS_HEALTH to the status of /api/health, empty when nothing answers. The answer is a
# status word, so anything else in it is replaced before it reaches a message.
os_health() {
  OS_HEALTH=$(os_get "$1/api/health" '.status // empty' "${2:-}")
  OS_HEALTH=${OS_HEALTH//[^A-Za-z0-9._ -]/?}
  OS_HEALTH=${OS_HEALTH:0:40}
}

# The type test is deliberate: `// empty` would turn false into nothing.
os_first_account() {
  OS_FIRST=$(os_get "$OS_LOOPBACK/api/sign-up-status" '.firstAccount | if type == "boolean" then tostring else empty end')
}

os_suffix() {
  OS_SUFFIX=$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // empty' 2>/dev/null) || OS_SUFFIX=
  [[ $OS_SUFFIX =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Returns 0 when the serve config names the service, 1 when it does not, and 2 when the config cannot be read. The
# service name anywhere in it means a binding exists. grep -q in a pipe could end it early (SIGPIPE).
os_bound() {
  local out
  out=$(os_on_host tailscale serve status --json 2>/dev/null) || return 2
  [[ $out == *"\"$OS_SERVICE\""* ]]
}

# Proof that the control plane lists this host for the service, which the exit code of `serve` is not.
os_advertised() {
  os_on_host tailscale status --json 2>/dev/null \
    | jq -e --arg s "$OS_SERVICE" '[.Self.CapMap["service-host"][]? | keys[]] | index($s) != null' >/dev/null 2>&1
}

# os_publish returns 1 when the bind fails and 2 when the control plane does not list the service within the wait.
os_publish() {
  local i
  os_on_host tailscale serve --service="$OS_SERVICE" --https=443 --yes "$OS_LOOPBACK" || return 1
  for ((i = 0; i < OS_ADVERTISE_WAIT; i++)); do
    os_advertised && return 0
    sleep 1
  done
  return 2
}

# Turns the binding off unless it is certainly absent: a config that cannot be read counts as bound. OS_UNBOUND=1 when
# it ran `off` successfully; a failure leaves tailscale's message in OS_CAUSE.
os_unbind() {
  OS_UNBOUND=0
  os_bound || [ "$?" -ne 1 ] || return 0
  if OS_CAUSE=$(os_on_host tailscale serve --service="$OS_SERVICE" --https=443 off 2>&1 >/dev/null); then
    OS_UNBOUND=1 OS_CAUSE=
  else
    return 1
  fi
}

# os_gate_check sets OS_GATE to ok, unhealthy, or first-account-open. OS_ASKED names the endpoint behind an unhealthy
# answer and OS_HEALTH holds what it said.
os_gate_check() {
  OS_ASKED=/api/health OS_GATE=unhealthy
  os_health "$OS_LOOPBACK"
  [ "$OS_HEALTH" = ok ] || return 1
  os_first_account
  case "$OS_FIRST" in
    false) OS_GATE=ok ;;
    true) OS_GATE=first-account-open ;;
    *) OS_ASKED=/api/sign-up-status OS_HEALTH='nothing usable' ;;
  esac
  [ "$OS_GATE" = ok ]
}

# A bound service stays bound when its stack restarts, so a stack that lets its first visitor become administrator
# has its binding turned off (OS_UNBOUND=1), or OS_GATE=unbind-failed.
os_gate() {
  OS_UNBOUND=0
  os_gate_check && return 0
  [ "$OS_GATE" != first-account-open ] || os_unbind || OS_GATE=unbind-failed
  return 1
}
