#!/usr/bin/env bash
# PreToolUse Bash hook: deny a pgrep -f or pkill -f whose pattern matches the tool call's own
# command line.
#
# Each Bash command runs as a shell whose argument list holds the command text, so while it
# runs that text is itself a process command line. A -f pattern written into it matches its
# own shell: `until ! pgrep -f 'git push ...'` never ends, and `pkill -f 'vllm'` kills the
# shell that ran it. A pattern that cannot match its own text (`[g]it push`) finds only the
# real process; so does waiting on a PID (`while kill -0 "$pid"`).
#
# Only patterns whose text is known are judged: a literal, or a variable the same command
# assigns. The pattern is tested as an extended regex against the command text, as pgrep
# tests it against the shell's command line.
#
# A deny names the reason (pattern-matches-own-command), the offending invocation, and a
# next_step: use-bracket-pattern with the command rebuilt, or wait-on-pid when the command
# also runs the text its pattern matches, so no bracket can tell the two apart.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
# Exit 2 + JSON deny when the call cannot be checked: no JSON parser on PATH,
# or a failure inside this script.
set -euo pipefail

readonly GUARD=self-match-guard

# The deny is built from text already escaped for JSON, the guard's name, and a
# line number, so it needs no parser. Exit 2 blocks the call even where the
# harness does not read the JSON.
block() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s %s"},"systemMessage":"%s %s"}\n' \
    "$GUARD" "$1" "$GUARD" "$2"
  exit 2
}
trap 'block "failed [guard-internal-error] at line $LINENO, so this call did not run.\nnext_step [ask-user]: tell the user; bats tests/$GUARD.bats in the dotfiles repo shows what broke." "failed at line $LINENO and blocked the call"' ERR

# shellcheck disable=SC2088  # shown to the agent as a path, never expanded
readonly DOCS='~/.claude/guides/workflows-and-skills.md § "Waiting without blocking"'
# Short options that take the next word as their argument (pgrep and pkill).
readonly ARG_SHORT='dgGPstuUF'
readonly ARG_LONG=' --delimiter --pgroup --group --parent --session --terminal --euid --uid --pidfile --signal --ns --nslist --env --cgroup '

INPUT=$(cat)

# Fast path: most Bash calls never mention either command.
case "$INPUT" in
  *pgrep* | *pkill*) ;;
  *) exit 0 ;;
esac
JQ=$(command -v jaq || command -v jq) \
  || block 'blocked [json-parser-missing]: neither jaq nor jq is on PATH, so this call could not be checked. It did not run; install jaq, then rerun it.\ndocs: ~/dotfiles/BOOTSTRAP.md § \"Install Packages from Brewfile\"\nnext_step [install-jaq]:\nbrew install jaq' \
    'blocked the call: neither jaq nor jq is installed (brew install jaq)'

CMD=$("$JQ" -r '.tool_input.command // ""' <<<"$INPUT")
[[ -n "$CMD" ]] || exit 0
CMD=$(printf '%s\n' "$CMD" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}')

# A word in command position: start of line, after a separator, an opening `(`, `{`,
# backtick, or `$(`, after the quote that opens a `-c` script, or after keywords that
# precede a command.
CMD_START="(^|[;&|({\`]|\\\$\\(|-c[[:space:]]+[\"'])[[:space:]]*(((do|then|else|time|until|while|if|elif|!)[[:space:]]+)*)"
INVOKE_RE="${CMD_START}(pgrep|pkill)([[:space:]].*)?$"

# Split the words after pgrep/pkill, up to the end of the simple command. Each word is
# printed raw (as written) and as its value (quotes removed), tab-separated.
# Args: text after the command name
words() {
  awk '
    function flush() { if (have) { printf "%s\t%s\n", raw, val } raw = ""; val = ""; have = 0 }
    {
      s = $0; n = length(s); q = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "'\''") { raw = raw c; if (c == "'\''") q = ""; else val = val c; continue }
        if (q == "\"") {
          raw = raw c
          if (c == "\\" && i < n) { i++; c = substr(s, i, 1); raw = raw c; val = val c; continue }
          if (c == "\"") q = ""; else val = val c
          continue
        }
        if (c ~ /[ \t]/) { flush(); continue }
        if (c ~ /[;&|)`]/) { flush(); exit }
        have = 1
        if (c == "'\''" || c == "\"") { q = c; raw = raw c; continue }
        if (c == "\\" && i < n) { i++; c = substr(s, i, 1); raw = raw "\\" c; val = val c; continue }
        raw = raw c; val = val c
      }
      flush()
    }' <<<"$1"
}

# Expand $NAME and ${NAME} from literal assignments earlier in the command.
# Args: value
# Outputs: the expanded value; fails when a variable or substitution is unknown
expand() {
  local v="$1" name re assigned
  # shellcheck disable=SC2016  # a literal $( and backtick: a substitution is never resolved
  [[ "$v" == *'$('* || "$v" == *'`'* ]] && return 1
  while [[ "$v" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]]; do
    name=${BASH_REMATCH[1]}
    re="(^|[;&|[:space:]])${name}=(\"[^\"]*\"|'[^']*'|[^[:space:];&|]*)"
    [[ "$CMD" =~ $re ]] || return 1
    assigned=${BASH_REMATCH[2]}
    assigned=${assigned#[\"\']}
    assigned=${assigned%[\"\']}
    [[ "$assigned" != *'$'* ]] || return 1
    v=${v//"\${$name}"/$assigned}
    v=${v//"\$$name"/$assigned}
  done
  printf '%s' "$v"
}

# Wrap the first letter or digit of a raw word that sits outside a bracket expression and
# is not escaped, so the pattern no longer matches its own text.
# Args: raw word
# Outputs: the bracketed word; fails when there is no such character
bracket() {
  awk '{
    s = $0; n = length(s); depth = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "[") { depth++; continue }
      if (c == "]" && depth > 0) { depth--; continue }
      if (depth == 0 && c ~ /[A-Za-z0-9]/) { print substr(s, 1, i - 1) "[" c "]" substr(s, i + 1); found = 1; exit }
    }
    exit !found
  }' <<<"$1"
}

# Returns: 0 when the extended regex matches the text (an invalid regex never matches)
matches() { grep -qE -e "$1" <<<"$2" 2>/dev/null; }

offending="" rebuilt=$CMD bracketable=true
while IFS= read -r line; do
  rest=$line
  while [[ "$rest" =~ $INVOKE_RE ]]; do
    invocation=${BASH_REMATCH[5]}
    tail=${BASH_REMATCH[6]}
    rest=$tail
    full=false skip=false raw="" val=""
    while IFS=$'\t' read -r w_raw w_val; do
      invocation+=" $w_raw"
      if [[ "$skip" == true ]]; then
        skip=false
        continue
      fi
      case "$w_val" in
        --) continue ;;
        --full) full=true ;;
        --*=*) ;;
        --*) [[ "$ARG_LONG" == *" $w_val "* ]] && skip=true ;;
        -*)
          letters=${w_val#-}
          for ((k = 0; k < ${#letters}; k++)); do
            ch=${letters:k:1}
            [[ "$ch" == f ]] && full=true
            if [[ "$ARG_SHORT" == *"$ch"* ]]; then
              ((k == ${#letters} - 1)) && skip=true
              break
            fi
          done
          ;;
        *)
          raw=$w_raw val=$w_val
          break
          ;;
      esac
    done < <(words "$tail")
    [[ "$full" == true && -n "$val" ]] || continue
    if [[ "$val" == *'$'* || "$val" == *'`'* ]]; then
      pattern=$(expand "$val") || continue
      literal=false
    else
      pattern=$val
      literal=true
    fi
    matches "$pattern" "$CMD" || continue
    offending=${offending:-$invocation}
    if [[ "$literal" == true ]] && fixed=$(bracket "$raw"); then
      rebuilt=${rebuilt/"$raw"/"$fixed"}
      fixed_val=$(bracket "$val") || fixed_val=$val
      matches "$fixed_val" "$rebuilt" && bracketable=false
    else
      bracketable=false
    fi
  done
done <<<"$CMD"

[[ -n "$offending" ]] || exit 0

message="the -f pattern in \`$offending\` matches this command's own text, so it also matches the shell running it: a wait on it never ends, and a pkill kills that shell."
if [[ "$bracketable" == true ]]; then
  action=use-bracket-pattern
  next="rerun with the pattern bracketed, which matches the process but not its own text:
$rebuilt"
else
  action=wait-on-pid
  next="this command also runs the text the pattern matches, so no pattern can tell the two apart. Start the process with & and wait on its PID: <command> & pid=\$!; while kill -0 \"\$pid\" 2>/dev/null; do sleep 10; done"
fi

text="self-match-guard denied [pattern-matches-own-command]: $message
next_step [$action]: $next
docs: $DOCS"

# shellcheck disable=SC2016  # jaq filter syntax; $text and friends are jaq variables
"$JQ" -n --arg text "$text" --arg offending "$offending" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $text
    },
    systemMessage: "self-match-guard denied [pattern-matches-own-command]: \($offending)"
  }'
