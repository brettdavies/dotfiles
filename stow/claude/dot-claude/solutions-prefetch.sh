#!/usr/bin/env bash
# UserPromptSubmit hook: on a debugging-flavored prompt, remind the agent to
# query docs/solutions BEFORE investigating. Reminder-only (no qmd run): a raw
# prompt/log is a noisy query, and qmd returns confident-but-wrong
# nearest-neighbors with no "no match" signal — so the agent runs a FOCUSED
# `qmd query` with its own phrasing, which retrieves far better.
#
# Closes the gap where /investigate's own history search (gstack-learnings-search)
# queries the gstack brain, not the shared docs/solutions corpus.
#
# Triggers are tuned for RECALL: a miss repeats the failure we're preventing; a
# false fire is one harmless reminder line. The only words held back are ones
# common in ordinary prose (lowercase "error"/"exception", bare "fail",
# standalone numbers) — caught only in unambiguous shapes (ALL-CAPS ERROR,
# PascalCase *Error/*Exception, "Error:" prefix, "NNN error/status").
#
# Fail-open + zero latency (two greps, no subprocess to qmd).
set -uo pipefail

input=$(cat)
prompt=$(printf '%s' "$input" | jaq -r '.prompt // ""' 2>/dev/null || true)
[ -z "$prompt" ] && exit 0

# A) Debug intent + failure state + "it worked before" (case-insensitive).
#    `.?` stands in for an apostrophe (avoids single-quote escaping).
CONV='used to work|was working|worked (before|yesterday|fine|earlier|until)|stopped working|no longer work|why .{0,40}(broke|broken|fail|crash|hang|wrong|not work)|root cause|debug this|investigate this|\brepro\b|reproduce|\bregression\b|stack ?trace|traceback|\bbroken\b|not working|doesn.?t work|won.?t work|isn.?t working|won.?t (start|build|launch|connect|load|run|compile|boot)|fails? to (start|build|launch|connect|load|run|compile|parse|boot)|crash(ed|es|ing)?|\bhang(s|ing|ed)?\b|\bstuck\b|freez(e|es|ing)|\bfrozen\b|deadlock|\bflaky\b|intermittent|timed out|times out|\btimeout\b|getting an error|throw(s|ing)? an (error|exception)|can.?t (connect|find|reach|load|start)|connection refused|\bfailed\b|\bfailing\b'

# B) Log / error artifacts (case-sensitive, so lowercase prose "error"/"exception"
#    and "failover"/"fail-safe" do NOT match).
LOG='\bFATAL\b|\bERROR\b|\bException\b|\bTraceback\b|\b[A-Z][A-Za-z]{2,}(Error|Exception)\b|\bSIG(SEGV|ABRT|BUS|TERM|KILL)\b|panic:|\berrno\b|\b(EADDRINUSE|ECONNREFUSED|ENOENT|EACCES|EPERM|ETIMEDOUT)\b|Segmentation fault|core dumped|\bOOM(Killed)?\b|out of memory|stack overflow|[Pp]ermission denied|[0-9]{3} (error|status|response)|[Ee]rror:'

if printf '%s' "$prompt" | grep -qiE "$CONV" || printf '%s' "$prompt" | grep -qE "$LOG"; then
  # shellcheck disable=SC2016  # backticks are literal markdown in the reminder text, not command substitution
  printf 'Debugging task: before investigating, run `qmd query "<focused: component + error>" --collection solutions`. A documented root cause/fix may already exist; /investigate does NOT search the docs/solutions corpus. Use focused keywords, not the raw log (raw pastes mis-rank).\n'
fi
exit 0
