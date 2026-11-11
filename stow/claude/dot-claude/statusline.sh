#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

# Read JSON input from Claude Code
input=$(cat)

# Extract Claude Code context
model=$(echo "$input" | jq -r '.model.display_name // .model.id')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
output_style=$(echo "$input" | jq -r '.output_style.name // empty')

# Context window usage
context_remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# A prime's Claude keeps its <repo>-prime title, so the work it is on shows in the line instead, named as session-title.sh
# names a generic session, with the branch in place of the PR's title, which the payload does not carry: the open PR's
# label, else the branch's, and nothing on a base branch or a detached head.
# Usage: prime_task <branch> <cwd>; prints the label, or nothing. Any failure leaves the line without one.
prime_task() {
  local as_home lib repo pr top origin
  as_home=$(readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot") || return 0
  # shellcheck source=/dev/null
  source "$as_home/lib/worktitle.sh" || return 0
  worktitle_base_branch "$1" "$2" && return 0
  for lib in env contract names record bounded read launch items; do
    # shellcheck source=/dev/null
    source "$as_home/lib/$lib.sh" || return 0
  done
  agent_slot_env "$as_home" || return 0
  top=$(git -C "$2" rev-parse --show-toplevel) || return 0
  origin=$(git -C "$top" config --get remote.origin.url 2>/dev/null || true)
  worktitle_is_prime "$top" "$origin" || return 0
  IFS=$'\037' read -r repo pr < <(echo "$input" | jq -r '[(.workspace.repo | if . then "\(.owner)/\(.name)" else "" end),
    (.pr.number // "" | tostring)] | join("\u001f")') || true
  [ -n "$repo" ] || repo=${top##*/}
  worktitle_name "$repo" "$1" "$pr" "$1"
}

# Get user:hostname (trim domain suffix like .lan, .local)
user_host="$(whoami):$(hostname -s)"

# Get current directory (shortened for display)
current_dir="${cwd/#"$HOME"/\~}"
# If path is too long, show only last 3 components
if [ ${#current_dir} -gt 40 ]; then
  current_dir="...$(echo "$current_dir" | awk -F/ '{print "/"$(NF-2)"/"$(NF-1)"/"$NF}')"
fi

# Git information (skip optional locks for speed)
git_info=""
if command -v git >/dev/null 2>&1 && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  # Get branch name
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || echo "detached")

  # Get git status indicators
  git_status=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)

  # Count changes
  staged=$(echo "$git_status" | grep -c "^[MADRCU]" || echo "0")
  unstaged=$(echo "$git_status" | grep -c "^.[MD]" || echo "0")
  untracked=$(echo "$git_status" | grep -c "^??" || echo "0")

  # Build git status string
  git_status_str=""
  [ "$staged" -gt 0 ] && git_status_str="${git_status_str}+${staged}"
  [ "$unstaged" -gt 0 ] && git_status_str="${git_status_str}!${unstaged}"
  [ "$untracked" -gt 0 ] && git_status_str="${git_status_str}?${untracked}"

  # Color code based on status
  if [ -z "$git_status_str" ]; then
    git_color="\033[0;32m" # green (clean)
  else
    git_color="\033[0;33m" # yellow (changes)
  fi

  if [ -n "$git_status_str" ]; then
    git_info=$(printf "${git_color}%s %s\033[0m" "$branch" "$git_status_str")
  else
    git_info=$(printf "${git_color}%s\033[0m" "$branch")
  fi
fi

# Task: only a prime's Claude, named <repo>-prime, in a prime checkout, shows one
task_info=""
if [ -n "${branch:-}" ] && [ "$branch" != "detached" ] && [[ "$(echo "$input" | jq -r '.session_name // empty')" == *-prime ]]; then
  task=$(prime_task "$branch" "$cwd" 2>/dev/null)
  [ -n "$task" ] && task_info=$(printf "\033[0;36mtask:%s\033[0m" "$task")
fi

# Model info (shortened)
model_short=$(echo "$model" | sed 's/Claude //' | sed 's/Sonnet/S/' | sed 's/Opus/O/' | sed 's/Haiku/H/')
model_info=$(printf "\033[0;35m%s\033[0m" "$model_short")

# Output style
style_info=""
if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
  style_info=$(printf "\033[0;36m%s\033[0m" "$output_style")
fi

# Context window usage
context_info=""
if [ -n "$context_remaining_pct" ] && [ "$context_remaining_pct" != "null" ]; then
  # Truncate to integer for shell arithmetic (no bc dependency)
  pct_int=${context_remaining_pct%.*}
  pct_int=${pct_int:-0}
  if [ "$pct_int" -ge 70 ]; then
    context_color="\033[0;32m" # green
  elif [ "$pct_int" -ge 30 ]; then
    context_color="\033[0;33m" # yellow
  else
    context_color="\033[0;31m" # red
  fi
  context_info=$(printf "${context_color}%.0f%%\033[0m" "$context_remaining_pct")
fi

# Assemble status line
# Format: user:hostname | directory | git | task | model | style | context
# Note: 5-hour usage window data not available via Claude Code JSON input
output="\033[0;34m${user_host}\033[0m"
output="$output | \033[0;37m${current_dir}\033[0m"
[ -n "$git_info" ] && output="$output | $git_info"
[ -n "$task_info" ] && output="$output | $task_info"
[ -n "$model_info" ] && output="$output | $model_info"
[ -n "$style_info" ] && output="$output | $style_info"
[ -n "$context_info" ] && output="$output | ctx:$context_info"

echo -e "$output"
