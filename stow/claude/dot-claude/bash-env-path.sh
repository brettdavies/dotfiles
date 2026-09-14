#!/usr/bin/env bash
# Claude Code SessionStart hook.
#
# The Bash tool runs a non-interactive `bash -c` that sources no shell rc, so
# keg-only Homebrew Ruby stays behind /usr/bin and `bundle` resolves to macOS
# system Bundler 1.x (below the supply-chain cooldown floor). CLAUDE_ENV_FILE is
# the only Claude-level seam — Claude runs its contents before each Bash command
# — so append the repo's canonical PATH promotion rather than duplicating it.
#
# Fresh sessions only: a resumed session (claude --resume) writes the hook env
# file under the startup session id but reads it under the resumed id, so it is
# never sourced (anthropics/claude-code#24775). SessionStart can fire more than
# once per session (startup, compact), so guard against a duplicate append.
set -eu

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

# shellcheck disable=SC2016  # $HOME stays literal here; it expands when Claude sources CLAUDE_ENV_FILE
_line='[ -f "$HOME/dotfiles/config/shell/local-paths.sh" ] && . "$HOME/dotfiles/config/shell/local-paths.sh" || true'
if ! grep -qF "$_line" "$CLAUDE_ENV_FILE" 2>/dev/null; then
  printf '%s\n' "$_line" >>"$CLAUDE_ENV_FILE"
fi
exit 0
