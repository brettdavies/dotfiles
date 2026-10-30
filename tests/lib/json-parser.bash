# shellcheck shell=bash
# Runs a PreToolUse guard under a PATH that decides which JSON parser it finds,
# so a suite can show what the guard does when jaq is missing.
#
# PATH is rebuilt from links to /usr/bin and /bin with jq and jaq left out,
# behind a directory holding the bash running the test, so macOS does not drop
# the guard to /bin/bash 3.2, and the parser the mode asks for.
#
# Usage: run_hook_with_parser <none|jq|jaq|broken> <hook> <payload>
#   none    neither jaq nor jq on PATH
#   jq      jq alone; skips the test when the host has no jq
#   jaq     jaq alone; skips the test when the host has no jaq
#   broken  a jaq that exits 5 whenever it runs
# Leaves status, output (stdout), and stderr set, as `run --separate-stderr` does.

bats_require_minimum_version 1.5.0

# One link directory per source, so names /bin and /usr/bin share never collide.
_json_parser_link_dir() {
  local src=$1 dest=$2
  mkdir -p "$dest"
  local GLOBIGNORE="$src/jq:$src/jaq"
  ln -s "$src"/* "$dest"/
}

run_hook_with_parser() {
  local mode=$1 hook=$2 payload=$3
  local root="$BATS_FILE_TMPDIR/json-parser"
  local shim="$root/shim-$mode"
  if [[ ! -d $root/usr-bin ]]; then
    _json_parser_link_dir /usr/bin "$root/usr-bin"
    if [[ ! /bin -ef /usr/bin ]]; then
      _json_parser_link_dir /bin "$root/bin"
    fi
  fi
  if [[ ! -d $shim ]]; then
    case $mode in
      jq | jaq) command -v "$mode" >/dev/null || skip "$mode not installed" ;;
      none | broken) ;;
      *)
        echo "run_hook_with_parser: unknown mode $mode" >&2
        return 2
        ;;
    esac
    mkdir -p "$shim"
    ln -s "$BASH" "$shim/bash"
    case $mode in
      jq | jaq) ln -s "$(command -v "$mode")" "$shim/$mode" ;;
      broken) printf '#!/bin/sh\nexit 5\n' >"$shim/jaq" && chmod +x "$shim/jaq" ;;
    esac
  fi
  PATH="$shim:$root/usr-bin:$root/bin" run --separate-stderr "$hook" <<<"$payload"
}

# After run_hook_with_parser: the guard blocked with exit 2 and a JSON deny whose
# reason carries <token>. Sets REASON to that reason.
assert_parser_block() {
  local token=$1
  # shellcheck disable=SC2154 # status, output, and stderr are set by bats' run
  echo "status=$status stdout=$output stderr=$stderr"
  [ "$status" -eq 2 ]
  jaq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
  REASON=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $REASON == *"[$token]"* ]]
}

# The guard, given <payload> with jq alone, returns the same deny reason it
# returns with the host's own parser.
assert_same_deny_with_jq() {
  local hook=$1 payload=$2 want
  want=$("$hook" <<<"$payload" | jaq -r '.hookSpecificOutput.permissionDecisionReason')
  [ -n "$want" ]
  run_hook_with_parser jq "$hook" "$payload"
  # shellcheck disable=SC2154 # status, output, and stderr are set by bats' run
  echo "status=$status stdout=$output stderr=$stderr"
  [ "$status" -eq 0 ]
  [ "$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" = "$want" ]
}

# The JSON for a Bash tool call running <command>.
bash_payload() {
  # shellcheck disable=SC2016 # $c is a jaq variable
  jaq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
}
