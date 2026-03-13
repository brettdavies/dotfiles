#!/usr/bin/env bash

# Read JSON input from Claude Code
input=$(cat)

# Extract Claude Code context
model=$(echo "$input" | jq -r '.model.display_name // .model.id')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
output_style=$(echo "$input" | jq -r '.output_style.name // empty')

# Context window usage
context_remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

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
        git_color="\033[0;32m"  # green (clean)
    else
        git_color="\033[0;33m"  # yellow (changes)
    fi

    if [ -n "$git_status_str" ]; then
        git_info=$(printf "${git_color}%s %s\033[0m" "$branch" "$git_status_str")
    else
        git_info=$(printf "${git_color}%s\033[0m" "$branch")
    fi
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
        context_color="\033[0;32m"  # green
    elif [ "$pct_int" -ge 30 ]; then
        context_color="\033[0;33m"  # yellow
    else
        context_color="\033[0;31m"  # red
    fi
    context_info=$(printf "${context_color}%.0f%%\033[0m" "$context_remaining_pct")
fi

# Assemble status line
# Format: user:hostname | directory | git | model | style | context
# Note: 5-hour usage window data not available via Claude Code JSON input
output="\033[0;34m${user_host}\033[0m"
output="$output | \033[0;37m${current_dir}\033[0m"
[ -n "$git_info" ] && output="$output | $git_info"
[ -n "$model_info" ] && output="$output | $model_info"
[ -n "$style_info" ] && output="$output | $style_info"
[ -n "$context_info" ] && output="$output | ctx:$context_info"

echo -e "$output"
