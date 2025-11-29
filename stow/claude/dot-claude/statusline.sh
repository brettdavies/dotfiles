#!/usr/bin/env bash

# Read JSON input from Claude Code
input=$(cat)

# Extract basic info
model=$(echo "$input" | jq -r '.model.display_name // .model.id')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
session_start=$(echo "$input" | jq -r '.session.started_at // empty')

# Session duration and token percentage
session_time=""
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
exceeds_200k=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')

if [ "$duration_ms" -gt 0 ]; then
    # Convert ms to seconds
    elapsed=$((duration_ms / 1000))
    hours=$((elapsed / 3600))
    minutes=$(((elapsed % 3600) / 60))

    # Calculate % of 5-hour window remaining
    five_hours=$((5 * 3600))
    percent_used=$((elapsed * 100 / five_hours))
    percent_left=$((100 - percent_used))

    if [ $percent_left -lt 0 ]; then
        percent_left=0
    fi

    # Color code based on time remaining
    if [ $percent_left -gt 50 ]; then
        time_color="\033[0;32m"  # green
    elif [ $percent_left -gt 20 ]; then
        time_color="\033[0;33m"  # yellow
    else
        time_color="\033[0;31m"  # red
    fi

    # Add warning if exceeds 200k tokens
    token_warning=""
    if [ "$exceeds_200k" = "true" ]; then
        token_warning=" \033[0;31m⚠️\033[0m"
    fi

    session_time=$(printf "${time_color}⏱️  %dh %dm (%d%%)\033[0m" "$hours" "$minutes" "$percent_left")
fi

# Token usage - only show if exceeds 200k
token_info=""
if [ "$exceeds_200k" = "true" ]; then
    token_info="\033[0;31m⚠️ >200k\033[0m"
fi

# Active model (shortened)
model_short=$(echo "$model" | sed 's/Claude //' | sed 's/Sonnet/S/' | sed 's/Opus/O/' | sed 's/Haiku/H/')
model_info=$(printf "\033[0;35m🤖 %s\033[0m" "$model_short")

# Active environment - check for virtualenv, node, etc.
env_info=""
if [ -n "$VIRTUAL_ENV" ]; then
    venv_name=$(basename "$VIRTUAL_ENV")
    python_ver=$(python3 --version 2>&1 | cut -d' ' -f2 | cut -d'.' -f1,2)
    env_info=$(printf "\033[0;36m🐍 py%s (%s)\033[0m" "$python_ver" "$venv_name")
elif command -v node >/dev/null 2>&1; then
    node_ver=$(node --version | sed 's/v//')
    env_info=$(printf "\033[0;36m⬢ node %s\033[0m" "$node_ver")
fi

# Project status - check last exit code from history if available
project_status="\033[0;32m✓\033[0m"

# Background jobs count (check for common dev server ports and show port:process)
bg_jobs=""
declare -a job_info
# Check for processes on common dev ports
for port in 3000 3001 5173 8000 8080 8081 9000; do  # 5000 commented out
    # Get process name for this port
    proc_name=$(lsof -i :$port -sTCP:LISTEN -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//' || echo "")
    if [ -n "$proc_name" ]; then
        # Extract just the command name
        cmd=$(lsof -i :$port -sTCP:LISTEN -c '' 2>/dev/null | awk 'NR==2 {print $1}')
        if [ -n "$cmd" ]; then
            job_info+=("$port:$cmd")
        else
            job_info+=("$port")
        fi
    fi
done

if [ ${#job_info[@]} -gt 0 ]; then
    jobs_list=$(IFS=' '; echo "${job_info[*]}")
    bg_jobs=$(printf "\033[0;33m🔧 %s\033[0m" "$jobs_list")
fi

# Swift version
swift_info=""
if command -v swift >/dev/null 2>&1; then
    swift_ver=$(swift --version 2>&1 | head -1 | grep -o 'Swift version [0-9.]*' | cut -d' ' -f3 | cut -d'.' -f1,2)
    if [ -n "$swift_ver" ]; then
        swift_info=$(printf "\033[0;35m🔶 %s\033[0m" "$swift_ver")
    fi
fi

# iOS device connections
device_info=""
if command -v xcrun >/dev/null 2>&1; then
    device_count=$(xcrun xctrace list devices 2>/dev/null | grep -c "^[^=].*([0-9A-F-]\{36\})$" || echo "0")
    # Subtract simulators - count only physical devices
    physical_devices=$(xcrun xctrace list devices 2>/dev/null | grep -v "Simulator" | grep -c "^[^=].*([0-9A-F-]\{36\})$" || echo "0")
    if [ "$physical_devices" -gt 0 ]; then
        device_info=$(printf "\033[0;32m📲 %d\033[0m" "$physical_devices")
    fi
fi

# iOS development indicators
ios_info=""
# Check if Xcode is running
if pgrep -x "Xcode" > /dev/null 2>&1; then
    ios_indicators=""

    # Check for iOS Simulator
    if pgrep -x "Simulator" > /dev/null 2>&1; then
        ios_indicators="${ios_indicators}📱"
    fi

    # Check for running builds (xcodebuild processes)
    if pgrep -x "xcodebuild" > /dev/null 2>&1; then
        ios_indicators="${ios_indicators}🔨"
    fi

    # Show Xcode with any additional indicators
    if [ -n "$ios_indicators" ]; then
        ios_info=$(printf "\033[0;36m🍎 %s\033[0m" "$ios_indicators")
    else
        ios_info="\033[0;36m🍎\033[0m"
    fi
fi

# Assemble status line
output="$session_time"
[ -n "$token_info" ] && output="$output | $token_info"
[ -n "$model_info" ] && output="$output | $model_info"
[ -n "$env_info" ] && output="$output | $env_info"
[ -n "$swift_info" ] && output="$output | $swift_info"
[ -n "$device_info" ] && output="$output | $device_info"
[ -n "$ios_info" ] && output="$output | $ios_info"
[ -n "$project_status" ] && output="$output | $project_status"
[ -n "$bg_jobs" ] && output="$output | $bg_jobs"

echo -e "$output"
