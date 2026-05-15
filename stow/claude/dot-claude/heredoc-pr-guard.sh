#!/usr/bin/env bash
# PreToolUse Bash hook: reject heredoc piped into a server-side artifact's
# body or notes field (gh PR/issue/comment/review/release, git commit -m).
# The auto-format hook does not reach inline heredocs, and inline heredocs
# trigger the well-known escape traps documented in CLAUDE.md "Pull Requests"
# and solutions-docs `workflow-issues/gh-pr-body-heredoc-escape-trap-20260413.md`.
#
# Antipatterns rejected:
#   - gh pr     {create,edit,comment,review} ... --body "$(cat <<EOF ... EOF)"
#   - gh issue  {create,edit,comment}        ... --body "$(cat <<EOF ... EOF)"
#   - gh release{create,edit}                ... --notes "$(cat <<EOF ... EOF)"
#   - git commit -m / --message                  "$(cat <<EOF ... EOF)"
#
# All of the above use --body-file (or --notes-file / --file) instead,
# pointing at a /tmp/ artifact that's been authored and (where applicable)
# scrubbed via /unslop before submission.
#
# Allowed (untouched): every other heredoc use — cat > file <<EOF,
# bash <<EOF, ssh host <<EOF, script bodies, function definitions, etc.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
set -euo pipefail

INPUT=$(cat)

# Guard: jaq required for JSON parsing
command -v jaq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$INPUT" | jaq -r '.tool_input.command // ""')
[[ -z "$CMD" ]] && exit 0

# Fast path: no heredoc operator anywhere → allow
case "$CMD" in
    *"<<"*) ;;
    *) exit 0 ;;
esac

# Slow path: classify which artifact (if any) is being fed a heredoc.
# Use bash regex with word boundaries to distinguish --body from --body-file
# and -m / --message from longer flags that share a prefix.
reason=
if [[ "$CMD" =~ gh[[:space:]]+pr[[:space:]]+(create|edit|comment|review)[[:space:]] ]] \
   && [[ "$CMD" =~ --body([[:space:]]|=)[^-] ]] \
   && [[ "$CMD" =~ \<\< ]]; then
    reason='gh pr create/edit/comment/review with a heredoc piped into --body produces wrapped + escaped output on GitHub. Write the body to /tmp/<artifact>.md, run /unslop /tmp/<artifact>.md (mandatory — recasts AI-slop patterns), then submit via --body-file /tmp/<artifact>.md. See CLAUDE.md "Pull Requests" section.'
elif [[ "$CMD" =~ gh[[:space:]]+issue[[:space:]]+(create|edit|comment)[[:space:]] ]] \
     && [[ "$CMD" =~ --body([[:space:]]|=)[^-] ]] \
     && [[ "$CMD" =~ \<\< ]]; then
    reason='gh issue create/edit/comment with a heredoc piped into --body produces wrapped + escaped output on GitHub. Write the body to /tmp/<artifact>.md, run /unslop /tmp/<artifact>.md, then submit via --body-file /tmp/<artifact>.md. See CLAUDE.md "GitHub correspondence".'
elif [[ "$CMD" =~ gh[[:space:]]+release[[:space:]]+(create|edit)[[:space:]] ]] \
     && [[ "$CMD" =~ --notes([[:space:]]|=)[^-] ]] \
     && [[ "$CMD" =~ \<\< ]]; then
    reason='gh release create/edit with a heredoc piped into --notes produces wrapped + escaped release notes. Write the notes to /tmp/release-notes.md, run /unslop /tmp/release-notes.md, then submit via --notes-file /tmp/release-notes.md. See CLAUDE.md "GitHub correspondence".'
elif [[ "$CMD" =~ git[[:space:]]+commit[[:space:]] ]] \
     && [[ "$CMD" =~ (^|[[:space:]])(-m|--message)([[:space:]]|=) ]] \
     && [[ "$CMD" =~ \<\< ]]; then
    reason='git commit with a heredoc piped into -m / --message embeds escape-trap text in the commit object and the squash-merge commit. Write the message to /tmp/commit-msg.md and use git commit --file /tmp/commit-msg.md instead. See CLAUDE.md "Commit Messages".'
else
    exit 0
fi

# Emit deny JSON (both permissionDecisionReason and systemMessage per defuddle hook's pattern)
# shellcheck disable=SC2016  # jaq filter syntax uses single quotes; $reason is a jaq variable, not shell
jaq -n --arg reason "$reason" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    },
    systemMessage: $reason
  }'
