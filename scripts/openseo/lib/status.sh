# The status verb: whether OpenSEO is up, without docker or sudo. Read-only: it never binds or unbinds.
# shellcheck disable=SC2034 # globals are shared through the script that sources this file

os_check() {
  OS_CHECKS=$(jq -c --arg n "$1" --arg d "$2" '. + [{name: $n, ok: true, detail: $d}]' <<<"$OS_CHECKS")
}

os_status() {
  local addr image
  os_need curl jq tailscale
  os_need_suffix
  addr=https://openseo.$OS_SUFFIX
  if [ -f "$OS_LOCAL_ENV" ]; then
    os_gate_check || :
    case "$OS_GATE" in
      first-account-open)
        ! os_bound || os_fail first-account-open "OpenSEO has no account yet and $OS_SERVICE is still bound, so its first visitor would become administrator; nothing changed" "$OS_DEPLOY serve"
        os_fail first-account-open "OpenSEO has no account yet, so $OS_SERVICE is correctly unbound; nothing changed" "$OS_DEPLOY create-admin"
        ;;
      unhealthy) os_unhealthy "the stack is stopped or still starting; nothing changed; safe to rerun" ;;
    esac
    os_check loopback "$OS_LOOPBACK/api/health ok and an account exists"
    os_advertised || os_fail service-not-advertised "the control plane does not list $OS_SERVICE for this host (nothing changed; safe to rerun)" "$OS_DEPLOY serve"
    os_check service "$OS_SERVICE is listed in CapMap service-host"
  fi
  os_health "$addr"
  if [ "$OS_HEALTH" = ok ]; then
    os_check address "$addr/api/health ok"
  elif [ -f "$OS_LOCAL_ENV" ]; then
    os_note "this host cannot reach its own service address $addr; its loopback and service checks pass, and other hosts can still reach it"
  else
    os_fail address-unreachable "$addr/api/health refused (nothing changed; safe to rerun)" "$OS_DEPLOY serve   # on the host that runs OpenSEO"
  fi
  if [ -f "$OS_LOCAL_ENV" ]; then
    pin_load "$OS_PIN"
    image=$(os_env_get "$OS_LOCAL_ENV" OPENSEO_IMAGE)
    [ "$image" = "$PIN_IMAGE" ] || os_note "the tracked pin $PIN_TAG differs from this host's image; apply it with: $OS_DEPLOY update"
  fi
  if [ "$OS_OUTPUT" = json ]; then
    OS_ACTION=none
    os_envelope ok 0 "OpenSEO is up at $addr" ""
  else
    echo "OK: OpenSEO is up at $addr"
    jq -r '.[] | "  ok: \(.name): \(.detail)"' <<<"$OS_CHECKS"
  fi
}
