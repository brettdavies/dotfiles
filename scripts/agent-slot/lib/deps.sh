# shellcheck shell=bash disable=SC2034 # its globals are read by the functions that call these
# The dependency install a new slot of a JavaScript repo gets before its agent starts.

# Installs what the clone's root lockfile pins, because a repo's hooks fail every tool-backed gate in a clone without it.
# An install runs the head's code with this account's credentials before anyone reads it, so it runs only where that is
# already chosen: the prime has node_modules, Claude trusts the prime, and the base branch holds the head. Only a frozen
# install runs: it writes no lockfile, and a lockfile that disagrees with its package.json fails. It also takes whatever
# the lockfile pins without consulting the supply-chain age gate, a release published that day included (measured on npm
# 11.16, bun 1.4.4, and pnpm 11.9), so the gate binds only whoever wrote the lock. npm and pnpm still get the gate from its
# one definition, because a lifecycle script that resolves a version reads it from the environment, which an SSH command
# or a Claude hook may not have set; bun reads it from ~/.bunfig.toml. bun comes first because the repo that holds two
# lockfiles installs with bun. An install that does not finish leaves a usable slot, so it is reported rather than fatal.
#
# PARITY_DEPS is {manager, command, status, log}, with status one of installed, failed, timed-out, tool-missing,
# prime-not-set-up, head-not-on-base, or null when the repo has nothing to install.
PARITY_DEPS=null
parity_deps() {
  local prime=$1 slot=$2 manager tool out status=installed log=''
  local -a args run
  PARITY_DEPS=null
  [[ -f $slot/package.json ]] || return 0
  if [[ -f $slot/bun.lock ]]; then
    manager=bun args=(install --frozen-lockfile)
  elif [[ -f $slot/pnpm-lock.yaml ]]; then
    manager=pnpm args=(install --frozen-lockfile)
  elif [[ -f $slot/package-lock.json ]]; then
    manager=npm args=(ci)
  else
    return 0
  fi
  tool=${AS_TOOL[$manager]}
  if ! trust_known "$prime" || [[ ! -d $prime/node_modules ]]; then
    status='prime-not-set-up'
  elif ! git -C "$slot" merge-base --is-ancestor HEAD "refs/remotes/origin/$PARITY_BASE" 2>/dev/null; then
    status='head-not-on-base'
  elif [[ -z $tool ]]; then
    status='tool-missing'
  else
    run=("$tool" "${args[@]}")
    [[ $manager == bun ]] \
      || run=(bash -c 'source "$1"; shift; exec "$@"' gate "$AS_HOME/../../config/shell/supply-chain.sh" "${run[@]}")
    if ! bounded out deps "$AS_DEPS_TIMEOUT" "${AS_GIT_REMOTE[@]}" "PATH=${tool%/*}:$PATH" PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
      /usr/bin/env -C "$slot" "${run[@]}"; then
      status=failed
      # A manager that ignores TERM takes timeout's KILL and exits 137.
      ((BOUNDED_STATUS != 124 && BOUNDED_STATUS != 137)) || status='timed-out'
      log=$BOUNDED_LOG
    fi
  fi
  PARITY_DEPS=$(contract_json -n -c --arg manager "$manager" --arg command "$manager ${args[*]}" --arg status "$status" \
    --arg log "$log" '{manager: $manager, command: $command, status: $status, log: (if $log == "" then null else $log end)}')
}
