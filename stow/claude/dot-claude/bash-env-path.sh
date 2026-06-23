#!/usr/bin/env bash
# Claude Code SessionStart / CwdChanged hook.
#
# The Bash tool runs a non-interactive `bash -c` that sources no shell rc, so
# keg-only Homebrew Ruby stays behind /usr/bin and `bundle` resolves to macOS
# system Bundler 1.x (below the supply-chain cooldown floor). CLAUDE_ENV_FILE is
# the only Claude-level seam — Claude runs its contents before each Bash command
# — so append the repo's canonical PATH promotion rather than duplicating it.
#
# The env file is shared across this session's hook events, so guard against
# appending the source line more than once.
set -eu

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

# shellcheck disable=SC2016  # $HOME stays literal here; it expands when Claude sources CLAUDE_ENV_FILE
_line='[ -f "$HOME/dotfiles/config/shell/local-paths.sh" ] && . "$HOME/dotfiles/config/shell/local-paths.sh" || true'
if ! grep -qF "$_line" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    printf '%s\n' "$_line" >> "$CLAUDE_ENV_FILE"
fi
exit 0
