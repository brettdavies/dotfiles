# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The reconcile lock: one restore, sweep, or finish changes tabs at a time, so each pass snapshots the tabs the pass
# ahead of it opened. macOS has no flock(1). The lock is a symlink in the state directory whose target is the holder's
# PID: ln -s creates it with its owner in one step, where mkdir would leave a moment with a lock and no owner. A lock
# whose holder is gone, or whose PID now belongs to a process other than this helper, is taken over.

AR_LOCK=
AR_LOCK_HELD=0

# Usage: lock_owner_alive <pid>
# The holder is always a real process, so this reads ps itself rather than AR_PS, which stands in for Rex's panes.
lock_owner_alive() {
  kill -0 "$1" 2>/dev/null && ps -o command= -p "$1" 2>/dev/null | grep -q 'agent-slot-rex'
}

# Waits up to AR_LOCK_WAIT seconds for the lock, then fails with reconcile-busy.
lock_acquire() {
  local owner deadline=$((SECONDS + AR_LOCK_WAIT)) told=0
  AR_LOCK=$AR_STATE/reconcile.lock
  mkdir -p "$AR_STATE"
  until ln -s "$$" "$AR_LOCK" 2>/dev/null; do
    owner=$(readlink "$AR_LOCK" 2>/dev/null || true)
    if [[ -n $owner ]] && ! lock_owner_alive "$owner"; then
      [[ $(readlink "$AR_LOCK" 2>/dev/null || true) != "$owner" ]] || rm -f "$AR_LOCK"
      continue
    fi
    if ((SECONDS >= deadline)); then
      ar_fail "$(contract_error_json reconcile-busy "another agent-slot-rex (pid ${owner:-unknown}) held the reconcile \
lock for more than $AR_LOCK_WAIT s" --value "$AR_LOCK" --command "agent-slot-rex restore")"
    fi
    if ((told == 0)) && [[ $CONTRACT_OUTPUT == text ]]; then
      printf 'agent-slot-rex: waiting for the reconcile in pid %s to finish\n' "${owner:-unknown}"
      told=1
    fi
    sleep 0.2
  done
  AR_LOCK_HELD=1
  contract_on_exit lock_release
}

# Releases the lock when this process holds it; safe to call any number of times.
lock_release() {
  ((AR_LOCK_HELD == 1)) || return 0
  AR_LOCK_HELD=0
  [[ $(readlink "$AR_LOCK" 2>/dev/null || true) != "$$" ]] || rm -f "$AR_LOCK"
}
