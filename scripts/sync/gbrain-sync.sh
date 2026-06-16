#!/bin/bash
# gbrain-sync — incremental sync across all registered sources + embed backfill.
# Cadence: every 15 min per docs/guides/cron-schedule.md (gbrain repo).
# Invoked by gbrain-sync.service (stow/gbrain/dot-config/systemd/user/gbrain-sync.service).
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

# 1. Sync all sources in parallel (postgres pool capped via --parallel).
"$GBRAIN_BIN" sync --all --parallel 4

# 2. Backfill any embeddings the sync deferred or that previously failed.
exec "$GBRAIN_BIN" embed --stale
