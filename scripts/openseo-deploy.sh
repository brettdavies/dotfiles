#!/usr/bin/env bash
# OpenSEO's standalone Docker stack on the Linux server, or with --host nas the NAS's Unraid Compose Manager stack, behind
# the tailnet service svc:openseo: config/openseo/compose.yaml (upstream's file, byte for byte) at the image digest in
# config/openseo/openseo.pin, with secrets rendered from 1Password. The docker verbs (up, down, create-admin) are the
# operator's; agents run `status`. Runbook: docs/runbooks/openseo.md.
# Usage: scripts/openseo-deploy.sh --help
# shellcheck disable=SC1090,SC1091,SC2034 # the libraries read these globals; shellcheck follows no sourced file

set -euo pipefail
umask 077

OS_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OS_PIN=$OS_REPO/config/openseo/openseo.pin
OS_COMPOSE_FILE=$OS_REPO/config/openseo/compose.yaml
OP_SKILL="${OP_SKILL:-$HOME/.claude/skills/1password/scripts}"

# 1Password secrets-dev items, read by UUID. An item whose env var is set to the empty string renders its keys empty.
OS_STORAGE_ITEM=tdkhy4vi4ijxryxihwb4xdjowy      # OpenSEO - Storage Secret (openseo)
OS_ADMIN_ITEM=hwacawam6ghon7c4tlxswldzye        # OpenSEO - Admin Login (openseo)
OS_DATAFORSEO_ITEM=${OPENSEO_DATAFORSEO_ITEM-lx26y32x6zcxkfiahuvis6yv2m}   # DataForSEO API Key
OS_GOOGLE_ITEM=${OPENSEO_GOOGLE_ITEM-ws3ujqnvak5jvhnikn3zwh4sxi}           # OpenSEO - Google OAuth Client (openseo)
OS_OPENROUTER_ITEM=${OPENSEO_OPENROUTER_ITEM-3pyrzbnoefzfsvbdquhh3w5fei}   # OpenRouter API Key - OpenSEO
OS_OPENROUTER_MODEL=anthropic/claude-sonnet-5.5

for lib in errors gate nas stack pin env serve compose status help; do
  source "$OS_REPO/scripts/openseo/lib/$lib.sh"
done
trap 'rm -f "${OS_TMP:-}"' EXIT

[ "${1:-}" != --host ] || { os_use_host "${2:-}"; shift 2; }
verb=${1:-}
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      if [ "$#" -lt 2 ] || { [ "$2" != json ] && [ "$2" != text ]; }; then
        os_fail usage "--output takes json or text" "$OS_DEPLOY --help" "${2:-}"
      fi
      OS_OUTPUT=$2
      shift 2
      ;;
    --host)
      os_use_host "${2:-}"
      shift 2
      ;;
    -h | --help)
      verb=--help
      shift
      ;;
    *)
      os_fail usage "unexpected argument $(os_mask "$1"); options follow the verb" "$OS_DEPLOY --help" "$1"
      ;;
  esac
done

case "$verb" in
  -h | --help | help)
    os_help
    exit 0
    ;;
  render | up | down | serve | status | create-admin) ;;
  *)
    os_fail usage "unknown or missing verb $(os_mask "$verb")" "$OS_DEPLOY --help" "$verb"
    ;;
esac
[ "$OS_OUTPUT" = text ] || [ "$verb" = status ] || os_fail usage "--output json is for status only" "$OS_DEPLOY --help" "$verb"

[ "$OS_HOST" = local ] || os_nas_preflight "$verb"
"os_${verb//-/_}"
