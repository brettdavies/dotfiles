#!/usr/bin/env bash

# Session context hook for Claude Code
# Enumerates available CLI tools at session start

echo '=== Session Context ==='
echo "Current datetime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ''

echo '--- Homebrew CLI tools ---'
brew list --formula

echo ''
echo '--- Python CLI tools (pipx) ---'
out=$(pipx list --short 2>/dev/null)
if [ -n "$out" ]; then
    echo "$out"
else
    echo '(none)'
fi

echo ''
echo '--- Python CLI tools (uv) ---'
out=$(uv tool list 2>/dev/null)
if [ -n "$out" ]; then
    echo "$out"
else
    echo '(none)'
fi

echo ''
echo '--- Global Bun packages ---'
out=$(bun pm ls -g 2>/dev/null)
if [ -n "$out" ]; then
    echo "$out"
else
    echo '(none)'
fi
