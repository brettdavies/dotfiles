#!/usr/bin/env bash
# PreToolUse hook on every tool: deny a call whose input carries the account's email
# address, its local part, or an entry of the never-send list.
#
# Claude Code puts the signed-in account's address into the model's context on every
# request, subagents included, with only an instruction not to send it anywhere
# (https://github.com/anthropics/claude-code/issues/81138). This guard checks the call
# before it leaves; the harness-side fix is
# https://github.com/anthropics/claude-code/issues/98584.
#
# Values, read on every call:
#   - every "emailAddress" string in ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json, the file
#     the harness injects from, and CLAUDE_CODE_USER_EMAIL when set
#   - the local part of each such address, when it has at least MIN_LOCAL characters
#   - each line of ${NEVER_SEND_LIST:-$HOME/.config/never-send/list}, which the secrets
#     package stows from the git-crypt-encrypted stow/secrets/dot-config/never-send/list:
#     one value per line, blank lines and # comments ignored. A list still in git-crypt
#     ciphertext, from a locked checkout, counts as no list.
# A value that appears in $HOME is skipped, since it would match every path.
#
# The built-in Grep and Glob tools are exempt: they read local files and send nothing, so
# they stay a way to search for the address locally. A payload naming more than one
# tool_name is never exempt, since the second could be the real one.
#
# A call is denied when its payload, as written or URL-decoded (%XX, + as a space),
# contains a value in any letter case. Only the call's text is checked: a value a command
# reads when it runs, or one re-spelled or base64-encoded, gets through.
#
# settings.json runs this with onFailure "block", so a crash, a timeout, or a missing
# script blocks the call. A missing config or list allows; a config that exists but
# cannot be read blocks.
#
# --check prints which sources are live and which list lines are skipped, never a value,
# and exits 1 when there is nothing to protect.
#
# The deny reason adapts
# https://github.com/anthropics/claude-code/issues/95258#issuecomment-6130024743
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
set -eEuo pipefail

# Report a crash on stderr and exit 1, so onFailure blocks the call with a reason.
# Args: line, command
internal_error() {
  printf 'never-send-guard: internal error at line %s: %s (guard-internal-error). The call was blocked and did not run. Stop and tell the user; the guard is ~/.claude/never-send-guard.sh, tested by tests/never-send-guard.bats in the dotfiles repo.\n' "$1" "$2" >&2
  exit 1
}
trap '[ "$BASH_SUBSHELL" -ne 0 ] || internal_error "$LINENO" "$BASH_COMMAND"; exit 1' ERR

readonly CONFIG="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
readonly LIST="${NEVER_SEND_LIST:-$HOME/.config/never-send/list}"
# Shorter local parts turn up inside ordinary words.
readonly MIN_LOCAL=6
# shellcheck disable=SC2088  # shown to the agent as a path, never expanded
readonly DOCS='~/.claude/CLAUDE.md § "Secrets & private identifiers"'

values=()
sources=()
config_state=absent
local_note="no address"
env_note="not set"
list_state=absent
list_loaded=0
list_skipped=""

# Record a value unless it is empty or appears in $HOME.
# Args: value, source
add() {
  local inside=false
  shopt -s nocasematch
  [[ "$HOME" != *"$1"* ]] || inside=true
  shopt -u nocasematch
  [[ -n "$1" && "$inside" = false ]] || return 1
  values+=("$1")
  sources+=("$2")
}

# Record an address and its local part.
# Args: address, source
add_account() {
  local part
  add "$1" "$2" || true
  [[ "$1" == *@* ]] || return 0
  part=${1%@*}
  if [ "${#part}" -lt "$MIN_LOCAL" ]; then
    local_note="not protected alone, shorter than $MIN_LOCAL characters"
  elif add "$part" "$2"; then
    local_note="protected"
  else
    local_note="not protected alone, appears in \$HOME"
  fi
}

if [ -e "$CONFIG" ]; then
  if [ -r "$CONFIG" ]; then
    config_state=none
    found=$(sed -n 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG")
    while IFS= read -r addr; do
      [ -n "$addr" ] || continue
      config_state=found
      add_account "$addr" "$CONFIG"
    done <<<"$found"
  else
    config_state=unreadable
  fi
fi

if [ -n "${CLAUDE_CODE_USER_EMAIL:-}" ]; then
  env_note="set"
  add_account "$CLAUDE_CODE_USER_EMAIL" CLAUDE_CODE_USER_EMAIL
fi

if [ -f "$LIST" ]; then
  if [ ! -r "$LIST" ]; then
    list_state=unreadable
  elif [ "$(head -c 10 "$LIST" | tr -d '\0')" = GITCRYPT ]; then
    list_state=locked
  else
    list_state=loaded
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line=${line%$'\r'}
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      case "$line" in '' | '#'*) continue ;; esac
      if add "$line" "line $n of $LIST"; then
        list_loaded=$((list_loaded + 1))
      else
        list_skipped+="${list_skipped:+, }$n"
      fi
    done <"$LIST"
  fi
fi

if [ "${1:-}" = --check ]; then
  case "$config_state" in
    found) echo "never-send-guard: account address: found in $CONFIG (local part $local_note)" ;;
    none) echo "never-send-guard: account address: none in $CONFIG" ;;
    absent) echo "never-send-guard: account address: no config at $CONFIG" ;;
    unreadable) echo "never-send-guard: account address: $CONFIG exists but cannot be read, so every call is blocked" ;;
  esac
  echo "never-send-guard: CLAUDE_CODE_USER_EMAIL: $env_note"
  case "$list_state" in
    loaded)
      noun=entries
      [ "$list_loaded" -ne 1 ] || noun=entry
      skipped=""
      if [ -n "$list_skipped" ]; then
        skipped="; skipped line $list_skipped (appears in \$HOME)"
        [[ "$list_skipped" != *,* ]] || skipped="; skipped lines $list_skipped (appear in \$HOME)"
      fi
      echo "never-send-guard: list $LIST: $list_loaded $noun loaded$skipped"
      ;;
    absent) echo "never-send-guard: list $LIST: absent" ;;
    unreadable) echo "never-send-guard: list $LIST: exists but cannot be read, so it counts as no list" ;;
    locked) echo "never-send-guard: list $LIST: locked (git-crypt ciphertext), so it counts as no list; unlock the dotfiles checkout and run scripts/stow-deploy" ;;
  esac
  [ "$config_state" != unreadable ] || exit 1
  if [ "${#values[@]}" -eq 0 ]; then
    echo "never-send-guard: nothing to protect"
    exit 1
  fi
  echo "never-send-guard: protecting ${#values[@]} value(s)"
  exit 0
fi

# JSON-escape a string for a double-quoted field. No JSON tool, because the guard must not depend on one: a control
# character this misses makes the output invalid, which onFailure turns into a block rather than an allow.
# Args: text
json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Print the deny and stop.
# Args: reason for the model, message for the user
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"},"systemMessage":"%s"}\n' \
    "$(json "$1")" "$(json "$2")"
  exit 0
}

payload=$(cat)

tool=unknown
tool_re='"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
if [[ "$payload" =~ $tool_re ]]; then
  named=${BASH_REMATCH[1]}
  tool=${named//[^A-Za-z0-9_-]/}
  case "$named" in
    Grep | Glob)
      rest=${payload#*\"tool_name\"}
      [[ "$rest" == *'"tool_name"'* ]] || exit 0
      ;;
  esac
fi

if [ "$config_state" = unreadable ]; then
  deny "never-send-guard denied [account-config-unreadable]: $CONFIG exists but cannot be read. It holds the account address this guard checks every call against, so every call is blocked until it can be read. This call did not run.
next_step [tell-user]: stop and tell the user that $CONFIG is not readable; they can fix its permissions from a terminal, for example chmod 600 $CONFIG. Do not retry until they have.
docs: $DOCS" "never-send-guard blocked a $tool call: $CONFIG exists but cannot be read"
fi

[ "${#values[@]}" -gt 0 ] || exit 0

patterns=()
spaced=false
for value in "${values[@]}"; do
  patterns+=(-e "$value")
  [[ "$value" != *" "* ]] || spaced=true
done

haystack=$payload
if [[ "$payload" == *%[0-9A-Fa-f][0-9A-Fa-f]* ]]; then
  # Backslashes are doubled first so that only the \x escapes made from %XX are read.
  decoded=$(printf '%s' "$payload" \
    | sed -e 's/\\/\\\\/g' -e 's/[+]/ /g' -e 's/%00//g' -e 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')
  haystack+=$'\n'$(printf '%b' "$decoded")
elif [ "$spaced" = true ] && [[ "$payload" == *+* ]]; then
  haystack+=$'\n'$(tr '+' ' ' <<<"$payload")
fi

# grep -c reads all of its input, so no early exit can turn a match into a pass.
rc=0
count=$(grep -aciF "${patterns[@]}" <<<"$haystack") || rc=$?
[ "$rc" -le 1 ] || internal_error "$LINENO" "grep exited $rc"
[ "$count" -gt 0 ] || exit 0

matched=""
i=0
while [ "$i" -lt "${#values[@]}" ]; do
  if grep -aqiF -e "${values[$i]}" <<<"$haystack"; then
    matched=${sources[$i]}
    break
  fi
  i=$((i + 1))
done
case "$matched" in
  "line "*)
    kind="an entry on the user's never-send list"
    seen="the never-send entry on $matched"
    ;;
  "")
    kind="a value the user protects"
    seen="a protected value"
    ;;
  *)
    kind="the user's account email address"
    seen="the account address (from $matched)"
    ;;
esac
deny "never-send-guard denied [address-in-tool-call]: this $tool call contains $kind, or part of it. The call did not run and nothing was sent. The user does not want their email address sent to any website, service, or command through any tool, even when a site asks for contact details. Changing the value does not make it acceptable: do not retry with it shortened, re-spelled, encoded, split, or spaced out, and do not bring it in another way, such as from a file, an environment variable, git config, or command output.
next_step [send-without-it]: retry once without it. Leave out the header, parameter, or field, or use a value with no personal details: for a User-Agent that asks for contact details, use the tool's name and the repository URL from \`git remote get-url origin\`, as in \"my-tool (+https://github.com/owner/repo)\". A tool that does not need the value works too. If the request still fails, skip that step, carry on with the rest of the task, and say in your reply what you skipped. If the task cannot be done at all without the value, stop and tell the user what you wanted to send, where, and why: the guard has no override, so the user would do that step. The check is a case-insensitive substring match, so this may be a false positive, such as a path or word that contains part of an entry; handle it the same way.
docs: $DOCS" "never-send-guard denied a $tool call: it carried $seen"
