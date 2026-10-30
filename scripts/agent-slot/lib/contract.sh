# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The output contract shared by agent-slot on the Linux server and agent-slot-rex on the Mac.
#
# Text output is for people; `--output json` is for agents and the Rex helper. In JSON mode a success prints one object
# on stdout and an error prints one object on stderr. Schema dotfiles.agent-slot/1: fields are only ever added.
#
#   success  {schema, ok: true, verb, ...verb fields}
#   error    {schema, ok: false, verb, reason, exit_code, message, value, next_step {action, command, docs},
#             recovery {side_effects, retryable, max_retries, reconcile}, context {version, tools, config, env}, log}
#
# reason comes from the closed table below, which is also the README's table of reasons (tests/agent-slot-docs.bats
# holds the two equal). side_effects is none, partial, complete, or unknown, and reconcile names the command that
# settles an unknown outcome. context carries tool versions and config paths, and only the names of environment
# variables, never their values.

CONTRACT_SCHEMA=dotfiles.agent-slot/1
CONTRACT_SCHEMA_VERSION=1
CONTRACT_DOCS=https://github.com/brettdavies/dotfiles/blob/main/README.md#agent-slot-reasons

EXIT_OK=0
EXIT_GENERAL=1
EXIT_USAGE=2
EXIT_AUTH=77
EXIT_CONFIG=78

CONTRACT_ACTIONS='none run rerun retry install authenticate fix-config ask-operator inspect-log'

# reason                      exit  retryable  max_retries  action
CONTRACT_REASONS='
usage                         2     false      0            run
script-error                  1     true       1            rerun
dependency-missing            78    false      0            install
record-schema-newer           78    false      0            install
not-in-slot                   1     false      0            run
repo-not-found                2     false      0            run
slot-not-found                1     false      0            run
slot-busy                     1     true       3            retry
invalid-task-name             2     false      0            run
prompt-file-unreadable        2     false      0            run
slot-limit-reached            78    false      0            ask-operator
clone-failed                  1     true       2            retry
solutions-symlink-missing     78    false      0            fix-config
hooks-path-outside-checkout   78    false      0            fix-config
git-crypt-locked              78    false      0            fix-config
trust-dialog-unrecognized     78    false      0            ask-operator
tmux-unresponsive             1     true       3            retry
tmux-failed                   1     true       1            retry
pr-state-unknown              1     true       3            retry
item-not-found                2     false      0            run
item-kind-mismatch            2     false      0            rerun
task-has-open-pr              1     false      0            none
teardown-blocked              1     false      0            run
slot-outside-root             78    false      0            ask-operator
gh-auth-missing               77    false      0            authenticate
git-crypt-key-missing         78    false      0            fix-config
solutions-corpus-missing      78    false      0            fix-config
slots-config-missing          78    false      0            install
prune-timer-inactive          78    false      0            run
slot-path-untrusted           78    false      0            run
bypass-mode-unaccepted        78    false      0            fix-config
version-unverified            0     false      0            ask-operator
repo-required                 2     false      0            run
server-unreachable            1     true       5            retry
rex-action-unregistered       78    false      0            run
rex-failed                    1     true       2            retry
reconcile-busy                1     true       1            retry
compound-not-run              1     false      0            run
background-jobs-running       1     false      0            run
finished-by-operator          1     false      0            none
release-withdrawn             1     false      0            none
sweep-timer-inactive          78    false      0            run
'

CONTRACT_VERB=agent-slot
CONTRACT_OUTPUT=text
CONTRACT_EMITTED=0
CONTRACT_PROGRAM=agent-slot
CONTRACT_ARGV=()
CONTRACT_LAST_FAILURE=
CONTRACT_TOOLS=()
CONTRACT_CONFIG='{}'
CONTRACT_REPO=.
CONTRACT_LOG_DIR=
CONTRACT_NOISE=/dev/null
declare -gA CONTRACT_TOOL_PATHS=()

# A tool's own complaint goes to the run's noise file rather than stderr, so stderr carries one JSON error and nothing
# else; a script-error log quotes the file's end.
contract_json() {
  "${AGENT_SLOT_JQ:-jaq}" "$@" 2>>"$CONTRACT_NOISE"
}

# Usage: contract_init <program> <args...>
# Records the invocation for script-error's rerun command and installs the traps.
#
# contract_fail exits the shell it runs in, so a function that can call it runs in the main shell and returns its
# result through a variable, never inside $(...): a failure in a subshell would end only the subshell. Command
# substitutions are kept for functions that cannot fail that way, and inherit_errexit makes those stop at a failure
# rather than run on with errexit off.
contract_init() {
  CONTRACT_PROGRAM=$1
  shift
  CONTRACT_ARGV=("$@")
  CONTRACT_NOISE=$(mktemp)
  set -E
  shopt -s inherit_errexit
  trap '_contract_on_err' ERR
  trap '_contract_on_exit $?' EXIT
}

_contract_on_err() {
  CONTRACT_LAST_FAILURE="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}: $BASH_COMMAND"
}

# Usage: contract_on_exit <command...>
# Runs the command when the program exits, before the exit status is reported, on every path out.
CONTRACT_CLEANUPS=()
contract_on_exit() {
  CONTRACT_CLEANUPS+=("$(contract_quote "$@")")
}

_contract_on_exit() {
  local status=$1 command log='' noise=$CONTRACT_NOISE cleanup
  for cleanup in "${CONTRACT_CLEANUPS[@]}"; do
    eval "$cleanup" 2>>"$noise" || true
  done
  CONTRACT_CLEANUPS=()
  CONTRACT_NOISE=/dev/null
  if ((status == 0 || CONTRACT_EMITTED == 1)); then
    [[ $noise == /dev/null ]] || rm -f "$noise"
    return 0
  fi
  command=$(contract_quote "$CONTRACT_PROGRAM" "${CONTRACT_ARGV[@]}")
  if [[ -n $CONTRACT_LOG_DIR ]] && mkdir -p "$CONTRACT_LOG_DIR" 2>/dev/null; then
    log="$CONTRACT_LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$-script-error.log"
    {
      printf 'command: %s\nexit: %s\nstopped at: %s\nlast failed call: %s\n--- tool stderr\n' "$command" "$status" \
        "${CONTRACT_LAST_FAILURE:-unknown}" "${BOUNDED_LOG:-none}"
      tail -n 40 "$noise" 2>/dev/null
    } >"$log" 2>/dev/null || log=''
  fi
  [[ $noise == /dev/null ]] || rm -f "$noise"
  contract_fail script-error "$CONTRACT_PROGRAM $CONTRACT_VERB stopped unexpectedly (exit $status)${CONTRACT_LAST_FAILURE:+ at $CONTRACT_LAST_FAILURE}" \
    --command "$command" --side-effects unknown --reconcile "$CONTRACT_PROGRAM list" --log "$log"
}

contract_quote() {
  local out='' arg
  for arg in "$@"; do
    if [[ $arg =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then
      out+="${out:+ }$arg"
    else
      out+="${out:+ }'${arg//\'/\'\\\'\'}'"
    fi
  done
  printf '%s' "$out"
}

# Usage: contract_reason_field <reason> <exit|retryable|max_retries|action>
contract_reason_field() {
  awk -v r="$1" -v f="$2" '
    $1 == r { col = (f == "exit") ? 2 : (f == "retryable") ? 3 : (f == "max_retries") ? 4 : 5; print $col; found = 1 }
    END { exit !found }' <<<"$CONTRACT_REASONS"
}

contract_reasons() {
  awk 'NF == 5 { print $1 }' <<<"$CONTRACT_REASONS"
}

contract_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Milliseconds since the epoch. Bash before 5 has no EPOCHREALTIME, and macOS date has no %N, so there it counts whole
# seconds.
contract_ms() {
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    printf '%s' "$((${EPOCHREALTIME/[.,]/} / 1000))"
  else
    printf '%s' "$(($(printf '%(%s)T' -1) * 1000))"
  fi
}

# Usage: contract_log_line <file> <line>
# Appends one line to a log of JSON lines. Past CONTRACT_LOG_MAX bytes the log first moves to <file>.1, replacing the one
# there, so the two hold about twice that at most. Never fails the caller.
CONTRACT_LOG_MAX=1048576
contract_log_line() {
  local log=$1
  {
    mkdir -p "${log%/*}"
    if [[ -f $log ]] && (($(wc -c <"$log") > CONTRACT_LOG_MAX)); then
      mv -f "$log" "$log.1"
    fi
    printf '%s\n' "$2" >>"$log"
  } 2>/dev/null || true
}

# Usage: contract_use_tools <tool...>
# Names the tools the current step calls, so an error's context carries their versions.
contract_use_tools() {
  CONTRACT_TOOLS=("$@")
}

# Usage: _contract_tool_version <name> <path>
_contract_tool_version() {
  local bin
  bin=$(command -v "$2" 2>/dev/null) || {
    echo missing
    return
  }
  case $1 in
    tmux) timeout 5 "$bin" -V </dev/null 2>/dev/null || true ;;
    *) timeout 5 "$bin" --version </dev/null 2>/dev/null | head -1 || true ;;
  esac
}

_contract_context() {
  local version tools='{}' tool env_names
  version=$(git -C "$CONTRACT_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
  for tool in "${CONTRACT_TOOLS[@]}"; do
    tools=$(contract_json -c --arg k "$tool" --arg v "$(_contract_tool_version "$tool" "${CONTRACT_TOOL_PATHS[$tool]:-$tool}")" \
      '. + {($k): $v}' <<<"$tools")
  done
  env_names=$({ compgen -e | grep -E '^(AGENT_SLOT|REX)_' || true; } | sort \
    | contract_json -R -s -c 'split("\n") | map(select(. != ""))')
  contract_json -n -c --arg version "$version" --argjson tools "$tools" --argjson env "$env_names" \
    --argjson config "$CONTRACT_CONFIG" '{version: $version, tools: $tools, config: $config, env: $env}'
}

# Usage: contract_error_json <reason> <message> [options]
# Prints one error object. Options: --value V, --command C, --action A, --side-effects S, --reconcile C, --log PATH,
# --exit N (overrides the table's code).
contract_error_json() {
  local reason=$1 message=$2
  shift 2
  local value='' has_value=0 command='' action='' side=none reconcile='' log='' code=''
  while (($#)); do
    case $1 in
      --value) value=$2 has_value=1 ;;
      --command) command=$2 ;;
      --action) action=$2 ;;
      --side-effects) side=$2 ;;
      --reconcile) reconcile=$2 ;;
      --log) log=$2 ;;
      --exit) code=$2 ;;
      *) return 2 ;;
    esac
    shift 2
  done
  local retryable max_retries
  [[ -n $code ]] || code=$(contract_reason_field "$reason" exit) || code=$EXIT_GENERAL
  retryable=$(contract_reason_field "$reason" retryable) || retryable=false
  max_retries=$(contract_reason_field "$reason" max_retries) || max_retries=0
  [[ -n $action ]] || action=$(contract_reason_field "$reason" action) || action=none
  [[ -n $command ]] || action=none
  contract_json -n -c --arg schema "$CONTRACT_SCHEMA" --arg verb "$CONTRACT_VERB" --arg reason "$reason" \
    --argjson code "$code" --arg message "$message" --arg value "$value" --argjson has_value "$has_value" \
    --arg action "$action" --arg command "$command" --arg docs "$CONTRACT_DOCS" --arg side "$side" \
    --argjson retryable "$retryable" --argjson max "$max_retries" --arg reconcile "$reconcile" \
    --argjson context "$(_contract_context)" --arg log "$log" '
    {schema: $schema, ok: false, verb: $verb, reason: $reason, exit_code: $code, message: $message,
     value: (if $has_value == 1 then $value else null end),
     next_step: {action: $action, command: (if $command == "" then null else $command end), docs: $docs},
     recovery: {side_effects: $side, retryable: $retryable, max_retries: $max,
                reconcile: (if $reconcile == "" then null else $reconcile end)},
     context: $context, log: (if $log == "" then null else $log end)}'
}

# Usage: contract_error_text <error-json>; the error as the lines a person reads.
contract_error_text() {
  contract_json -r '
    "\(.reason): \(.message)",
    (if .value != null then "  value: \(.value)" else empty end),
    (if .next_step.command != null then "  next: \(.next_step.command)" else empty end),
    (if .log != null then "  log: \(.log)" else empty end)' <<<"$1"
}

contract_help_command() {
  local help=$CONTRACT_PROGRAM
  [[ $CONTRACT_VERB == "$CONTRACT_PROGRAM" ]] || help+=" $CONTRACT_VERB"
  printf '%s --help' "$help"
}

# Usage: contract_emit_error <error-json>
# Prints an error object on stderr, or the prose with the next step and a help pointer.
contract_emit_error() {
  local text
  CONTRACT_EMITTED=1
  if [[ $CONTRACT_OUTPUT == json ]]; then
    printf '%s\n' "$1" >&2
  else
    text=$(contract_error_text "$1")
    printf '%s: %s\n  see %s, or %s\n' "$CONTRACT_PROGRAM" "$text" "$(contract_help_command)" "$CONTRACT_DOCS" >&2
  fi
}

# Usage: contract_fail <reason> <message> [options]
# Prints the error and exits with its code.
contract_fail() {
  local err code
  err=$(contract_error_json "$@")
  code=$(contract_json -r '.exit_code' <<<"$err")
  contract_emit_error "$err"
  exit "$code"
}

# Usage: output_flag <arg> [next]; reads --output VALUE or --output=VALUE into CONTRACT_OUTPUT and sets OUTPUT_SHIFT to
# the arguments it used, 0 when <arg> is not the flag.
OUTPUT_SHIFT=0
output_flag() {
  local value
  OUTPUT_SHIFT=0
  case $1 in
    --output) value=${2:-} OUTPUT_SHIFT=2 ;;
    --output=*) value=${1#--output=} OUTPUT_SHIFT=1 ;;
    *) return 0 ;;
  esac
  [[ $value == json || $value == text ]] || usage_fail "--output takes json or text" "$([[ $1 == --output ]] && printf '%s' "$value" || printf '%s' "$1")"
  CONTRACT_OUTPUT=$value
}

# Usage: contract_no_json_tool <program> <args...>; prints dependency-missing for a host with neither jaq nor jq. With
# no JSON tool to build it, the error object is written out by hand; tests/agent-slot-contract.bats holds its keys to
# the ones `agent-slot schema` requires.
contract_no_json_tool() {
  local program=$1
  shift
  if [[ " $* " == *" --output json "* || " $* " == *" --output=json "* ]]; then
    printf '{"schema":"%s","ok":false,"verb":"%s","reason":"dependency-missing","exit_code":%s,' \
      "$CONTRACT_SCHEMA" "$program" "$EXIT_CONFIG" >&2
    printf '"message":"neither jaq nor jq is installed","value":"jaq",' >&2
    printf '"next_step":{"action":"install","command":"brew install jaq","docs":"%s"},' "$CONTRACT_DOCS" >&2
    printf '"recovery":{"side_effects":"none","retryable":false,"max_retries":0,"reconcile":null},' >&2
    printf '"context":{"version":null,"tools":{},"config":{},"env":[]},"log":null}\n' >&2
  else
    echo "$program: dependency-missing: neither jaq nor jq is installed; next: brew install jaq" >&2
  fi
}

# Usage: refuse_leading_output <args...>; a usage error when --output comes before the verb. Claude's permission rules
# for the verbs that delete slots match the verb as the first argument, so no other order may run.
refuse_leading_output() {
  [[ ${1:-} == --output || ${1:-} == --output=* ]] || return 0
  [[ " $* " != *" --output json "* && " $* " != *" --output=json "* ]] || CONTRACT_OUTPUT=json
  contract_fail usage "--output goes after the verb, as in: $CONTRACT_PROGRAM <verb> --output json" --value "$1" \
    --command "$CONTRACT_PROGRAM --help"
}

# Usage: usage_fail <message> [value]; a usage error pointing at the current verb's help.
usage_fail() {
  if (($# > 1)); then
    contract_fail usage "$1" --value "$2" --command "$(contract_help_command)"
  fi
  contract_fail usage "$1" --command "$(contract_help_command)"
}

# Usage: contract_ok <json-members-object> [<jq filter for text output>]
# Prints a success object built from the members, or the text the filter renders from it.
contract_ok() {
  local body
  body=$(contract_json -c --arg schema "$CONTRACT_SCHEMA" --arg verb "$CONTRACT_VERB" \
    '{schema: $schema, ok: true, verb: $verb} + .' <<<"$1")
  CONTRACT_EMITTED=1
  if [[ $CONTRACT_OUTPUT == json ]]; then
    printf '%s\n' "$body"
  elif [[ -n ${2:-} ]]; then
    contract_json -r "$2" <<<"$body"
  fi
}
