# shellcheck shell=bash
# JSON Lines run log for the scheduled upgrade jobs. Every line a job writes to stdout is one JSON object:
#
#   journalctl --user -t brew-upgrade -o cat | jaq -Rc 'fromjson? | select(.event == "run.end")'   Linux
#   jaq -c 'select(.event == "run.end")' ~/Library/Logs/brew-upgrade.jsonl                            macOS
#
# On Linux, -t keeps to the job's own lines (the unit's SyslogIdentifier) and fromjson? skips any line that is not
# JSON, such as a crash message from bash itself.
#
# Schema dotfiles.upgrade/1. Fields are only ever added. Every event carries schema, ts (UTC), event, job, run_id
# (the systemd invocation ID under systemd), and host.
#
#   run.start  os, trigger (systemd | launchd | manual), pid, command, tool_version, settings {VAR: value | null}
#   output     level (error | warning | info), line: one line of the command's combined stdout and stderr
#   run.end    outcome (success | failure), exit_code, reason (ok | cooldown-unset | upgrade-failed | script-error),
#              message, duration_s, errors, warnings, first_error, changes [{name, from, to}] with null for an added
#              or removed package (changes itself is null when the run ended before comparing versions), next_step
#              {action (none | inspect-config | rerun), command, docs}
#
# outcome follows the exit status alone, so a successful run can still report errors > 0 when the tool printed error
# lines and exited 0. A run that dies after run.start, from a failed command or a kill such as the systemd start
# timeout, still ends with a run.end whose reason is script-error.
#
# When stdout is the journal, each line also starts with a syslog priority prefix (<3> error, <4> warning, <6> info),
# which journald strips and records as PRIORITY, so `journalctl --user -p err` lists failed runs.

RUN_LOG_SCHEMA=dotfiles.upgrade/1
RUN_LOG_DOCS=https://github.com/brettdavies/dotfiles/blob/main/BOOTSTRAP.md

_run_log_str() {
  local s=${1//[[:cntrl:]]/ }
  s=${s//\\/\\\\}
  printf '"%s"' "${s//\"/\\\"}"
}

_run_log_emit() { # <priority> <event> [<json members>]
  local prefix=
  [ "$RUN_LOG_JOURNALD" = 1 ] && prefix="<$1>"
  printf '%s{"schema":"%s","ts":"%s","event":"%s","job":"%s","run_id":"%s","host":%s%s}\n' "$prefix" \
    "$RUN_LOG_SCHEMA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$RUN_JOB" "$RUN_ID" "$RUN_HOST" "${3:+,$3}"
}

# Usage: run_log_start <job> <command> <tool-version> [VAR...]
# Emits run.start, recording each VAR's value as a setting.
run_log_start() {
  RUN_JOB=$1 RUN_COMMAND=$2 RUN_STARTED=$SECONDS RUN_OS=$(uname -s) RUN_LOG_FINISHED=0
  RUN_SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # Ubuntu ships uuidgen in an optional package; the kernel's generator needs nothing installed.
  RUN_ID=${INVOCATION_ID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')}
  RUN_HOST=$(_run_log_str "$(hostname -s)")
  RUN_ERRORS=0 RUN_WARNINGS=0 RUN_FIRST_ERROR=
  # systemd.exec(5): a child can inherit JOURNAL_STREAM after its stdout moved elsewhere, so it names the journal only
  # while it still matches stdout's device and inode.
  RUN_LOG_JOURNALD=0
  if [ -n "${JOURNAL_STREAM:-}" ] && [ "$(stat -L -c '%d:%i' "/proc/$$/fd/1" 2>/dev/null)" = "$JOURNAL_STREAM" ]; then
    RUN_LOG_JOURNALD=1
  fi
  local trigger=manual settings='' var
  if [ -n "${INVOCATION_ID:-}" ]; then
    trigger=systemd
  elif [ "${XPC_SERVICE_NAME:-}" = "com.user.$RUN_JOB" ]; then
    trigger=launchd
  fi
  for var in "${@:4}"; do
    if [ -n "${!var+set}" ]; then
      settings+="${settings:+,}\"$var\":$(_run_log_str "${!var}")"
    else
      settings+="${settings:+,}\"$var\":null"
    fi
  done
  trap '_run_log_exit $?' EXIT
  _run_log_emit 6 run.start "\"os\":\"$RUN_OS\",\"trigger\":\"$trigger\",\"pid\":$$,\"command\":$(_run_log_str "$2"),\"tool_version\":$(_run_log_str "$3"),\"settings\":{$settings}"
}

_run_log_lines() { # <summary-file>
  local line level priority errors=0 warnings=0 first_error=
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      [Ee]rror:* | fatal:*)
        level=error priority=3 errors=$((errors + 1))
        [ -n "$first_error" ] || first_error=$line
        ;;
      [Ww]arning:*) level=warning priority=4 warnings=$((warnings + 1)) ;;
      *) level=info priority=6 ;;
    esac
    _run_log_emit "$priority" output "\"level\":\"$level\",\"line\":$(_run_log_str "$line")"
  done
  printf '%s\n%s\n%s\n' "$errors" "$warnings" "$first_error" >"$1"
}

# Usage: run_log_capture <command> [args...]
# Runs the command, emitting one output event per line, and sets RUN_STATUS to its exit status.
run_log_capture() {
  local summary
  summary=$(mktemp)
  if "$@" 2>&1 | _run_log_lines "$summary"; then
    RUN_STATUS=0
  else
    RUN_STATUS=${PIPESTATUS[0]}
  fi
  {
    read -r RUN_ERRORS
    read -r RUN_WARNINGS
    IFS= read -r RUN_FIRST_ERROR
  } <"$summary"
  rm -f "$summary"
}

# Usage: run_log_changes <before> <after>
# Each argument holds "name version" lines; prints the JSON array of packages whose version differs.
run_log_changes() {
  {
    printf '%s\n' "$1"
    echo --
    printf '%s\n' "$2"
  } | awk '
    $0 == "--" { after = 1; next }
    NF < 2 { next }
    !after { before[$1] = $2; next }
    {
      if (!($1 in before)) from = "null"
      else if (before[$1] == $2) { delete before[$1]; next }
      else from = "\"" before[$1] "\""
      delete before[$1]
      out = out (out == "" ? "" : ",") "{\"name\":\"" $1 "\",\"from\":" from ",\"to\":\"" $2 "\"}"
    }
    END {
      for (name in before) out = out (out == "" ? "" : ",") "{\"name\":\"" name "\",\"from\":\"" before[name] "\",\"to\":null}"
      print "[" out "]"
    }'
}

_run_log_exit() { # <exit-status>
  [ "$RUN_LOG_FINISHED" = 0 ] || return 0
  run_log_finish "$(($1 == 0 ? 1 : $1))" script-error "the job exited before finishing its run" null rerun "$RUN_SCRIPT"
}

# Usage: run_log_finish <exit-code> <reason> <message> <changes-json> [<action> <command>]
# Emits run.end and exits with the code.
run_log_finish() {
  local outcome=success priority=6 first_error=null scheduler=systemd
  local next_step='{"action":"none","command":null,"docs":null}'
  RUN_LOG_FINISHED=1
  [ "$RUN_OS" != Darwin ] || scheduler=launchd
  if [ "$1" -ne 0 ]; then
    outcome=failure priority=3
    next_step="{\"action\":\"$5\",\"command\":$(_run_log_str "$6"),\"docs\":\"$RUN_LOG_DOCS#scheduled-brew-and-uv-upgrades-$scheduler\"}"
  fi
  [ -z "$RUN_FIRST_ERROR" ] || first_error=$(_run_log_str "$RUN_FIRST_ERROR")
  _run_log_emit "$priority" run.end "\"outcome\":\"$outcome\",\"exit_code\":$1,\"reason\":\"$2\",\"message\":$(_run_log_str "$3"),\"duration_s\":$((SECONDS - RUN_STARTED)),\"errors\":$RUN_ERRORS,\"warnings\":$RUN_WARNINGS,\"first_error\":$first_error,\"changes\":$4,\"next_step\":$next_step"
  exit "$1"
}

# Usage: run_log_complete <changes-json>
# Finishes the run from RUN_STATUS, pointing a failure at a rerun of the calling script by its absolute path.
run_log_complete() {
  if [ "$RUN_STATUS" -eq 0 ]; then
    run_log_finish 0 ok "$RUN_COMMAND succeeded" "$1"
  else
    run_log_finish "$RUN_STATUS" upgrade-failed "$RUN_COMMAND exited $RUN_STATUS" "$1" rerun "$RUN_SCRIPT"
  fi
}
