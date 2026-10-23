#!/usr/bin/env bash
# PreToolUse Bash hook: deny waits that block the session or poll slowly.
#
# Rules, from ~/.claude/CLAUDE.md "Never block on a wait":
#   - foreground: no `sleep` longer than 10 s, and no while/until polling loop
#     at all (it blocks until its condition holds, however short each sleep);
#   - background: no poll interval and no fixed wait longer than 10 s.
# A background one-shot wait that an external system mandates (a Retry-After)
# passes when the command carries `# sleep-guard: required-delay`.
#
# Each deny names one reason from a closed set (sleep-blocks-session,
# poll-loop-blocks-session, poll-interval-too-long, fixed-wait-too-long), the
# offending text, and a next_step rebuilt from the denied command, so the agent
# can rerun it without composing the fix itself.
#
# Only literal durations are judged: `sleep "$delay"` passes outside a
# foreground polling loop, since its length is unknown here.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
set -euo pipefail

readonly MAX_WAIT=10
readonly MARKER='# sleep-guard: required-delay'
readonly UNTIL_TEMPLATE='until <condition>; do sleep 10; done'
# shellcheck disable=SC2088  # shown to the agent as a path, never expanded
readonly DOCS='~/.claude/guides/workflows-and-skills.md § "Waiting without blocking"'

INPUT=$(cat)

# Fast path: most Bash calls never mention sleep.
case "$INPUT" in
  *sleep*) ;;
  *) exit 0 ;;
esac
command -v jaq >/dev/null 2>&1 || exit 0

CMD=$(jaq -r '.tool_input.command // ""' <<<"$INPUT")
BACKGROUND=$(jaq -r '.tool_input.run_in_background // false' <<<"$INPUT")
[[ -n "$CMD" ]] || exit 0

# Join backslash-continued lines, so `sleep \` + `60` reads as one command.
CMD=$(printf '%s\n' "$CMD" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}')

# A word in command position: start of line, after a separator or an opening
# `(`, `{`, backtick, or `$(`, after the quote that opens a `-c` script, or after
# do/then/else/time. Held in variables because inline patterns would need
# escaping that `[[ =~ ]]` applies inconsistently.
CMD_START="(^|[;&|({\`]|\\\$\\(|-c[[:space:]]+[\"'])[[:space:]]*((do|then|else|time)[[:space:]]+)?"
SLEEP_RE="${CMD_START}(sleep[[:space:]]+([^;&|)\`\"'#]*[^;&|)\`\"'#[:space:]]))"
SLEEP_CMD_RE="${CMD_START}sleep([[:space:]]|$)"
POLL_LOOP_RE="${CMD_START}(while|until)[[:space:]]"
LOOP_RE="${CMD_START}(while|until|for)[[:space:]]"

# Print the total seconds of a sleep operand list (GNU sleep sums its operands);
# fail when any operand is not a literal duration.
# Args: operand text
duration() {
  local total=0 word words
  read -ra words <<<"$1"
  for word in "${words[@]}"; do
    case "$word" in
      inf | infinity)
        echo inf
        return 0
        ;;
    esac
    [[ "$word" =~ ^([0-9]*\.?[0-9]+)([smhd]?)$ ]] || return 1
    total=$(awk -v t="$total" -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[2]}" 'BEGIN {
      m = (u == "m") ? 60 : (u == "h") ? 3600 : (u == "d") ? 86400 : 1
      printf "%g", t + n * m }')
  done
  echo "$total"
}

# Returns: 0 when the duration exceeds MAX_WAIT
too_long() { [[ "$1" == inf ]] || awk -v s="$1" -v m="$MAX_WAIT" 'BEGIN { exit !(s > m) }'; }

has_sleep=false
poll_loop=false
loop=false
long_texts=()
long_secs=()
while IFS= read -r line; do
  [[ "$line" =~ $POLL_LOOP_RE ]] && poll_loop=true
  [[ "$line" =~ $LOOP_RE ]] && loop=true
  [[ "$line" =~ $SLEEP_CMD_RE ]] && has_sleep=true
  rest=$line
  while [[ "$rest" =~ $SLEEP_RE ]]; do
    text=${BASH_REMATCH[4]}
    if secs=$(duration "${BASH_REMATCH[5]}") && too_long "$secs"; then
      long_texts+=("$text")
      long_secs+=("$secs")
    fi
    rest=${rest#*"${BASH_REMATCH[0]}"}
  done
done <<<"$CMD"

[[ "$has_sleep" == true ]] || exit 0

# Rebuild the command with every long sleep replaced.
# Args: replacement text
# Outputs: the rebuilt command
rebuild() {
  local out=$CMD i
  for i in "${!long_texts[@]}"; do
    out=${out/"${long_texts[$i]}"/"$1"}
  done
  printf '%s' "$out"
}

reason="" offending="" message="" action="" next=""
first="${long_texts[0]:-}" first_secs="${long_secs[0]:-}"
if [[ "$BACKGROUND" != true ]]; then
  if [[ "$poll_loop" == true ]]; then
    reason=poll-loop-blocks-session
    offending="$(grep -oE '(while|until)[[:space:]][^;]*' <<<"$CMD" | head -n 1)"
    message="this polling loop runs in the foreground and blocks the session until its condition holds."
    action=rerun-in-background
    next="rerun the loop with run_in_background: true; its exit notifies you, and you keep working meanwhile:"
    ((${#long_texts[@]} == 0)) || CMD=$(rebuild "sleep $MAX_WAIT")
  elif ((${#long_texts[@]} > 0)); then
    reason=sleep-blocks-session
    offending=$first
    message="\`$first\` would block this session for $first_secs s; no wait may exceed $MAX_WAIT s. Waiting on a job you started? Run the job itself with run_in_background: true; its completion notice wakes you."
    if [[ "$loop" == true ]]; then
      action=rerun-in-background
      next="rerun with run_in_background: true and a $MAX_WAIT s interval:"
      CMD=$(rebuild "sleep $MAX_WAIT")
    else
      action=poll-condition-in-background
      next="rerun with run_in_background: true, replacing <condition> with the check you are waiting on:"
      CMD=$(rebuild "$UNTIL_TEMPLATE")
    fi
  fi
elif ((${#long_texts[@]} > 0)); then
  if [[ "$loop" == true ]]; then
    reason=poll-interval-too-long
    offending=$first
    message="\`$first\` polls every $first_secs s, so the event can sit unnoticed that long; poll at most every $MAX_WAIT s."
    action=shorten-interval
    next="rerun with run_in_background: true and a $MAX_WAIT s interval:"
    CMD=$(rebuild "sleep $MAX_WAIT")
  elif [[ "$CMD" != *"$MARKER"* ]]; then
    reason=fixed-wait-too-long
    offending=$first
    message="\`$first\` waits a fixed $first_secs s instead of for the event; no wait may exceed $MAX_WAIT s. If an external system mandates this delay (a Retry-After), keep it and append \`$MARKER\`."
    action=poll-condition-in-background
    next="rerun with run_in_background: true, replacing <condition> with the check you are waiting on:"
    CMD=$(rebuild "$UNTIL_TEMPLATE")
  fi
fi

[[ -n "$reason" ]] || exit 0

text="sleep-guard denied [$reason]: $message
next_step [$action]: $next
$CMD
docs: $DOCS"

# shellcheck disable=SC2016  # jaq filter syntax; $text and friends are jaq variables
jaq -n --arg text "$text" --arg reason "$reason" --arg offending "$offending" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $text
    },
    systemMessage: "sleep-guard denied [\($reason)]: \($offending)"
  }'
