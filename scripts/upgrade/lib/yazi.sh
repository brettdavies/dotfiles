# shellcheck shell=bash
# The brew job's yazi steps: installing the packages package.toml pins. Sourced after run-log.sh.

_yazi_info_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    _run_log_output info 6 "$line"
  done
}

# Usage: yazi_pkg_install
# Runs `ya pkg install` when ya is on PATH. Its lines are info events, since an error ya prints is not the run's error;
# a non-zero exit adds one warning, and the run's outcome still follows the upgrade alone.
yazi_pkg_install() {
  local status
  command -v ya >/dev/null 2>&1 || return 0
  if ya pkg install 2>&1 | _yazi_info_lines; then
    status=0
  else
    status=${PIPESTATUS[0]}
  fi
  if [ "$status" -ne 0 ]; then
    run_log_note warning "Warning: ya pkg install exited $status; installed yazi packages may not match package.toml. Rerun: ya pkg install"
  fi
}
