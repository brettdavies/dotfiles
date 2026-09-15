#!/usr/bin/env bash
set -euo pipefail

# Apply the cswap auto-switch settings this fleet depends on.
#
# The rotation check runs as a systemd timer (stow/cswap) on Linux and a
# LaunchAgent (stow/launchagent) on macOS. Neither carries the trip point as a
# flag: `cswap config set` writes settings that apply to every invocation, so a
# hand-run `cswap auto --once` during debugging behaves the same as a tick.
# Flags in the unit would make the two diverge silently.
#
# Three keys are pinned:
#
#   autoswitch.threshold              99     switch while the account can still
#                                            serve, not once it is spent
#   autoswitch.hysteresisPct          2      a 99 trip point is only reachable
#                                            if the margin is below the gap to
#                                            the next account; at the shipped 10
#                                            a peer between 89 and 99 is refused
#   autoswitch.includeApiKeyAccounts  false  already the default, pinned because
#                                            flipping it starts metered spend on
#                                            an unattended host
#
# And one is held unset:
#
#   autoswitch.model   Per-model weekly windows join the account-wide 5h and 7d
#                      windows in gating an account, and the worst window wins
#                      outright. There is no fallback: once a counted window
#                      reads 100% on every account, the engine reports
#                      all-exhausted and waits, and it never re-decides on the
#                      account-wide windows alone. Fable is the only scoped
#                      window these accounts report, and it is not the model the
#                      work runs on, so counting it parks rotation on a limit
#                      that does not bind while real weekly headroom goes unused.
#
# The cooldown and poll interval are deliberately left alone, so a harmless
# upstream default change is inherited rather than frozen here.
#
# Usage: scripts/cswap-autoswitch-deploy.sh
#
#   CSWAP_BIN   binary to configure (default: cswap on PATH). `cswap config set`
#               writes to a root the tool resolves internally and takes no path
#               flag, so this override is the only seam that keeps the test
#               suite off a real installation.
#
# Exit 0 on success, including when every key already holds its target state;
# 1 when the binary is missing.

EXIT_FAILURE=1
EXIT_USAGE=2

CSWAP_BIN="${CSWAP_BIN:-cswap}"

usage() {
  echo "usage: $0" >&2
  exit "$EXIT_USAGE"
}

[ "$#" -eq 0 ] || usage

if ! command -v "$CSWAP_BIN" >/dev/null 2>&1; then
  echo "FATAL: cswap not found (looked for '$CSWAP_BIN')." >&2
  echo "       Install it with: uv tool install claude-swap" >&2
  exit "$EXIT_FAILURE"
fi

# Key/value pairs to pin, applied in order.
KEYS=(
  autoswitch.threshold
  autoswitch.hysteresisPct
  autoswitch.includeApiKeyAccounts
)
VALUES=(99 2 false)

# Keys held at their shipped default.
UNSET_KEYS=(autoswitch.model)

# `cswap config` prints "key value" once a setting is pinned and "key value
# (default)" while it is still inherited. Both fields matter: a key sitting at a
# value that happens to equal the shipped default is still unpinned, and an
# upstream change to that default would move it silently. Emitted as one
# tab-separated row so a missing marker stays an empty field.
current_row() {
  "$CSWAP_BIN" config 2>/dev/null | awk -v k="$1" '$1 == k { print $2 "\t" $3; exit }'
}

changed=0

for i in "${!KEYS[@]}"; do
  key="${KEYS[$i]}"
  want="${VALUES[$i]}"
  row="$(current_row "$key")"
  have="${row%%$'\t'*}"
  source="${row#*$'\t'}"

  if [ "$have" = "$want" ] && [ "$source" != "(default)" ]; then
    echo "ok       $key already pinned at $want"
    continue
  fi

  "$CSWAP_BIN" config set "$key" "$want" >/dev/null
  if [ "$have" = "$want" ]; then
    echo "pin      $key $want (was inherited from the default)"
  else
    echo "set      $key ${have:-unset} -> $want"
  fi
  changed=$((changed + 1))
done

for key in "${UNSET_KEYS[@]}"; do
  row="$(current_row "$key")"
  source="${row#*$'\t'}"

  if [ "$source" = "(default)" ]; then
    echo "ok       $key already at its default"
    continue
  fi

  "$CSWAP_BIN" config unset "$key" >/dev/null
  echo "unset    $key ${row%%$'\t'*} -> default"
  changed=$((changed + 1))
done

if [ "$changed" -eq 0 ]; then
  echo "cswap auto-switch settings already current; nothing changed."
else
  echo "cswap auto-switch settings applied; $changed changed."
fi
