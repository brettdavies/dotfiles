# shellcheck shell=bash
# Enable background tasks for Claude Code
export ENABLE_BACKGROUND_TASKS=1

# Enable maintaining project working directory
export CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=1

# compound-engineering reads this as its review-provider allowlist; a value naming no provider skips every external
# model, so its reviews stay in-process.
export CROSS_MODEL_PEERS=none
