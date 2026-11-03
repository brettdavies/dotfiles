# shellcheck shell=bash
# The brew job's yazi steps: installing the packages package.toml pins, and on Linux bumping the pins when yazi
# changes. Sourced after run-log.sh.

_yazi_info_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    _run_log_output info 6 "$line"
  done
}

# Usage: yazi_pkg_install
# Runs `ya pkg install --discard` when ya is on PATH. Without --discard, ya refuses to replace an installed package whose
# files differ from the hash package.toml records, and an older pin's files always differ from a newer pin's hash;
# package.toml owns every installed plugin and flavor, so there is no local edit to keep. Its lines are info events,
# since an error ya prints is not the run's error; a non-zero exit adds one warning, and the run's outcome still follows
# the upgrade alone.
yazi_pkg_install() {
  local status
  command -v ya >/dev/null 2>&1 || return 0
  if ya pkg install --discard 2>&1 | _yazi_info_lines; then
    status=0
  else
    status=${PIPESTATUS[0]}
  fi
  if [ "$status" -ne 0 ]; then
    run_log_note warning "Warning: ya pkg install exited $status; installed yazi packages may not match package.toml. Rerun: ya pkg install --discard"
  fi
}

YAZI_PINS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/yazi-pins.sh"

# Usage: yazi_pins_after_upgrade
# On Linux, runs the pin bump when the installed yazi differs from the version the pins were last proven on (the
# stamp the bump writes on bumped or not-needed), and records its outcome object as RUN_YAZI_PINS. The bump's stderr
# becomes info events. A job that dies during the bump still ends with a failed/script-error object.
yazi_pins_after_upgrade() {
  local version stamp out last log next
  [ "$RUN_OS" = Linux ] || return 0
  version=$(yazi --version 2>/dev/null | awk '/Version:/ { print $2; exit }' || true)
  [ -n "$version" ] || return 0
  stamp=$(cat "${YAZI_PINS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles}/yazi-pins-proven" 2>/dev/null || true)
  [ "$version" != "$stamp" ] || return 0
  next="\"next_step\":{\"action\":\"rerun\",\"command\":$(_run_log_str "$YAZI_PINS_SCRIPT"),\"docs\":\"$RUN_LOG_DOCS#yazi-plugin-pins\"}"
  RUN_YAZI_PINS="{\"outcome\":\"failed\",\"reason\":\"script-error\",\"exit_code\":null,\"message\":\"the brew job ended during the pin bump\",\"value\":null,\"yazi_version\":$(_run_log_str "$version"),\"pr\":null,\"host_update\":null,$next}"
  log=$(mktemp "${TMPDIR:-/tmp}/yazi-pins-log.XXXXXX")
  out=$(timeout "${YAZI_PINS_TIMEOUT:-3600}" "${YAZI_PINS_CMD:-$YAZI_PINS_SCRIPT}" 2>"$log") || true
  _yazi_info_lines <"$log"
  rm -f "$log"
  last=$(tail -n 1 <<<"$out")
  case $last in
    '{"outcome":"bumped"'* | '{"outcome":"not-needed"'* | '{"outcome":"waiting"'* | '{"outcome":"failed"'*)
      RUN_YAZI_PINS=$last
      ;;
    *)
      RUN_YAZI_PINS="{\"outcome\":\"failed\",\"reason\":\"bad-output\",\"exit_code\":null,\"message\":\"the pin bump printed no outcome object\",\"value\":$(_run_log_str "$last"),\"yazi_version\":$(_run_log_str "$version"),\"pr\":null,\"host_update\":null,$next}"
      ;;
  esac
  case $RUN_YAZI_PINS in
    '{"outcome":"waiting"'* | '{"outcome":"failed"'*)
      run_log_note warning "Warning: the yazi pin bump ended $(sed -E 's/^\{"outcome":"([^"]*)","reason":"([^"]*)".*/\1 (\2)/' <<<"$RUN_YAZI_PINS"); run.end yazi_pins holds the next step"
      ;;
  esac
}
