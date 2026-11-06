# shellcheck disable=SC2034,SC2153 # globals are shared through the script that sources this file

OS_BOUND=0

os_serve() {
  local rc=0
  OS_BOUND=0
  os_require_env
  os_need curl jq tailscale
  os_gate || :
  case "$OS_GATE" in
    ok) ;;
    first-account-open)
      [ "$OS_UNBOUND" != 1 ] || os_note "svc:openseo was bound while OpenSEO let its first visitor become administrator; its binding is now off"
      os_note "OpenSEO has no account yet, so svc:openseo stays unbound; run: $OS_DEPLOY create-admin"
      return 0
      ;;
    unbind-failed)
      os_fail unbind-failed "OpenSEO lets its first visitor become administrator while $OS_SERVICE is bound, and turning the binding off failed" \
        "tailscale serve --service=$OS_SERVICE --https=443 off"
      ;;
    *) os_unhealthy "$OS_SERVICE was left as it was; safe to rerun" ;;
  esac
  echo "==> service serve: $OS_SERVICE -> $OS_LOOPBACK"
  os_try os_publish || rc=$?
  case "$rc" in
    0) ;;
    1) os_fail bind-failed "tailscale serve could not bind $OS_SERVICE; safe to rerun" "$OS_DEPLOY serve" ;;
    *)
      OS_ACTION=supply-input
      os_fail service-not-advertised "$OS_SERVICE is bound but the control plane does not list this host for it; the service is not defined, granted, or approved" \
        "define $OS_SERVICE and approve this host (docs/runbooks/openseo.md#service-not-advertised), then $OS_DEPLOY serve"
      ;;
  esac
  OS_BOUND=1
  echo "==> bound: $(os_env_get "$OS_LOCAL_ENV" BETTER_AUTH_URL)"
}
