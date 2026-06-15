#!/bin/bash
# gbrain-dream — nightly maintenance cycle across all sources.
# Cadence: nightly at 2 AM per docs/guides/cron-schedule.md (gbrain repo).
# Runs lint, backlinks, extract, extract_facts, consolidate, propose_takes,
# recompute_emotional_weight, and any other phases the active schema pack
# declares. Invoked by gbrain-dream.service.
set -euo pipefail

# Load shell env so API keys (LITELLM_API_KEY, etc.) and proxy endpoints
# (LITELLM_BASE_URL) reach gbrain. Per dotfiles/AGENTS.md § "Shell Config
# Chain", non-interactive shells must source .profile (which sources
# config/shell/*.sh + ~/.secrets). The interactive-only .zshrc / .bashrc
# chains are intentionally skipped here.
#
# Wrapped in set +e because config/shell/caches.sh uses
# `[ ! -d X ] && mkdir -p X` patterns whose conditional returns 1 when X
# exists; under the script's outer `set -e` that propagates as a fatal exit.
set +e
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
set -e

GBRAIN_BIN="/home/brett/.cache/bun/bin/gbrain"

exec "$GBRAIN_BIN" dream
