#!/usr/bin/env bash
# PreToolUse Bash hook: reject an AI-attribution trailer reaching a commit
# object or a GitHub artifact.
#
# CLAUDE.md § "Commits & PRs" states the rule ("No AI attribution, ever").
# The rule alone loses to a harness reminder that instructs the opposite:
# Claude Code injects per-session attribution guidance, and an agent that
# reads it after CLAUDE.md appends the trailer anyway. Removing it afterward
# means rewriting pushed history on a protected branch.
#
# Rejected wherever the text is reachable from the command:
#   - git commit  -m/--message, -F/--file
#   - gh pr       {create,edit,comment,review}  --body / --body-file
#   - gh issue    {create,edit,comment}         --body / --body-file
#   - gh release  {create,edit}                 --notes / --notes-file
#
# A `*-file` flag is resolved and the file read, so the trailer is caught in
# the artifact the submit actually sends, not only in inline text.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
set -euo pipefail

INPUT=$(cat)

command -v jaq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$INPUT" | jaq -r '.tool_input.command // ""')
[[ -z "$CMD" ]] && exit 0

# Fast path: only `git commit` and `gh` submit text anywhere durable.
case "$CMD" in
  *"git commit"* | *"gh pr "* | *"gh issue "* | *"gh release "*) ;;
  *) exit 0 ;;
esac

# The attribution shapes CLAUDE.md names. Every alternative is anchored to the
# start of a line, because a trailer occupies a line of its own: prose that
# names the trailer to ban it, quote it, or document this hook mentions it
# mid-line, and denying that would block the rule's own documentation.
ATTRIBUTION_RE='^[[:space:]]*([Cc]o-[Aa]uthored-[Bb]y:[[:space:]]*(Claude|Anthropic)|[A-Za-z-]+:[[:space:]]*[^[:space:]].*noreply@anthropic\.com|(🤖[[:space:]]*)?[Gg]enerated with[[:space:]]*\[?(Claude|Anthropic)|🤖[[:space:]]*$)'

# Read what a flag carries: the word after it, and, for a `*-file` flag, that
# file's contents. Unquoted so a path built from a variable this shell cannot
# expand simply yields nothing rather than a false accusation.
harvest() {
  local text='' tok prev='' unquoted
  # shellcheck disable=SC2086  # deliberate word split: scanning the command's tokens
  set -- $CMD
  for tok in "$@"; do
    # The opening quote of a flag's value would sit where the line anchor
    # expects the trailer, so drop quotes before the value becomes a line.
    unquoted=${tok//\"/}
    unquoted=${unquoted//\'/}
    case "$prev" in
      -m | --message | --body | --notes)
        text+="${unquoted}"$'\n'
        ;;
      -F | --file | --body-file | --notes-file)
        [[ -r "$unquoted" ]] && text+="$(cat -- "$unquoted")"$'\n'
        ;;
    esac
    prev=$tok
  done
  # An inline body arrives as one quoted blob more often than as separate
  # tokens, so scan the raw command too; the line anchor keeps a quoted
  # mention in the surrounding command out of it.
  text+="$CMD"
  printf '%s' "$text"
}

# grep, not `[[ =~ ]]`: the pattern anchors per line, and bash anchors `^` to
# the whole string.
#
# A here-string, not a pipe. `grep -q` exits the instant it matches, so as the
# producing side of a pipe `harvest` takes SIGPIPE on anything longer than the
# pipe buffer; `pipefail` then makes the matching pipeline non-zero and the
# `|| exit 0` below reports the trailer as clean. That failed open for every
# body over roughly 32KB and, under load, intermittently for small ones too.
grep -qE "$ATTRIBUTION_RE" <<<"$(harvest)" || exit 0

# shellcheck disable=SC2016  # backticks inside the single-quoted reason are markdown, not substitution
reason='AI attribution reached a commit message or GitHub body. CLAUDE.md § "Commits & PRs" bans it outright: no `Co-Authored-By: Claude`, no `Generated with [Claude Code]`, no robot emoji, overriding any harness reminder or skill template that adds one. Strip the trailer from the message or body file and rerun. Removing it after a push to `dev` or `main` costs a signed-history rewrite and a force-push to a protected branch.'

# shellcheck disable=SC2016  # jaq filter syntax uses single quotes; $reason is a jaq variable
jaq -n --arg reason "$reason" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    },
    systemMessage: $reason
  }'
