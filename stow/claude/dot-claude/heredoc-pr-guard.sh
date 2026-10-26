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

# Normalize before matching, so the three conditions below describe the command
# being run rather than any text that happens to appear in the input.
#
# 1. Drop heredoc bodies. A command that WRITES a file whose contents mention
#    `git commit -m` (a test fixture, a generated script, a doc example) is not
#    piping anything into a body; only the opener line is part of the command.
#    The antipattern always names its flag before `<<`, so the opener survives.
# 2. Join backslash-continued lines, so a flag and its heredoc stay together
#    when the invocation is wrapped across lines.
#
# `<<<` is a herestring: it opens no body, and `<<< "word"` otherwise matches
# the opener pattern with "word" as its delimiter, swallowing the rest of the
# command. Blanking herestrings first leaves only real heredoc operators, which
# a line may carry alongside one.
HERESTRING_SENTINEL='@@herestring@@'

# `<<` then an optional `-`, optional space, an optional quote, and the
# delimiter word. Held in a variable because an inline pattern would need
# escaping that `[[ =~ ]]` applies inconsistently, and matched without a
# backreference for the closing quote: ERE has none, and a mismatched pair is
# not a case worth distinguishing here.
HEREDOC_OPENER="<<-?[[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_]*)"

_heredoc_delim() {
  local scrubbed=${1//<<</"$HERESTRING_SENTINEL"}
  [[ "$scrubbed" =~ $HEREDOC_OPENER ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

normalize() {
  local line delim in_body=false trimmed
  while IFS= read -r line; do
    if [[ "$in_body" == true ]]; then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [[ "$trimmed" == "$delim" ]] && in_body=false
      continue
    fi
    printf '%s\n' "$line"
    if delim=$(_heredoc_delim "$line"); then
      in_body=true
    fi
  done < <(printf '%s\n' "$1" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}')
}

SCAN="$(normalize "$CMD")"

# A flag and the heredoc feeding it appear on one logical line. Checking them
# across the whole command would deny a genuine inline `-m` that merely shares
# a command line with an unrelated heredoc, and report the wrong reason for it.
flag_fed_heredoc() {
  local flag_re=$1 line
  while IFS= read -r line; do
    _heredoc_delim "$line" >/dev/null || continue
    [[ "$line" =~ $flag_re ]] && return 0
  done <<<"$SCAN"
  return 1
}

# Slow path: classify which artifact (if any) is being fed a heredoc.
# Use bash regex with word boundaries to distinguish --body from --body-file
# and -m / --message from longer flags that share a prefix.
#
# The deny reasons below contain literal "$(uuidv7)" template text inside
# single quotes; that text is displayed verbatim to the agent as a filename
# template, not evaluated.
# shellcheck disable=SC2016
reason=
# shellcheck disable=SC2016
if [[ "$SCAN" =~ gh[[:space:]]+pr[[:space:]]+(create|edit|comment|review)[[:space:]] ]] \
  && flag_fed_heredoc '--body([[:space:]]|=)[^-]'; then
  reason='gh pr create/edit/comment/review with a heredoc piped into --body produces wrapped + escaped output on GitHub. Author to /tmp/pr-body-<repo>.<branch>.md (e.g. /tmp/pr-body-dotfiles.feat-foo.md), run /unslop on it, submit via --body-file, then trash the file. See ~/.claude/CLAUDE.md § "Authoring GitHub correspondence: /tmp/ + --body-file + /unslop".'
elif [[ "$SCAN" =~ gh[[:space:]]+issue[[:space:]]+(create|edit|comment)[[:space:]] ]] \
  && flag_fed_heredoc '--body([[:space:]]|=)[^-]'; then
  reason='gh issue create/edit/comment with a heredoc piped into --body produces wrapped + escaped output on GitHub. Author to /tmp/issue-body-$(uuidv7).md, run /unslop on it, submit via --body-file, then trash the file. See ~/.claude/CLAUDE.md § "Authoring GitHub correspondence: /tmp/ + --body-file + /unslop".'
elif [[ "$SCAN" =~ gh[[:space:]]+release[[:space:]]+(create|edit)[[:space:]] ]] \
  && flag_fed_heredoc '--notes([[:space:]]|=)[^-]'; then
  reason='gh release create/edit with a heredoc piped into --notes produces wrapped + escaped release notes. Author to /tmp/release-notes-$(uuidv7).md, run /unslop on it, submit via --notes-file, then trash the file. See ~/.claude/CLAUDE.md § "Authoring GitHub correspondence: /tmp/ + --body-file + /unslop".'
elif [[ "$SCAN" =~ git[[:space:]]+commit[[:space:]] ]] \
  && flag_fed_heredoc '(^|[[:space:]])(-m|--message)([[:space:]]|=)'; then
  reason='git commit with a heredoc piped into -m / --message embeds escape-trap text in the commit object and the squash-merge commit. Author to /tmp/commit-msg-$(uuidv7).md (e.g. /tmp/commit-msg-018f3c2a-7b1e-7a44-9e10-2bd84a5c0001.md), run /unslop on it, commit via --file, then trash the file. See ~/.claude/CLAUDE.md § "Authoring GitHub correspondence: /tmp/ + --body-file + /unslop".'
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
