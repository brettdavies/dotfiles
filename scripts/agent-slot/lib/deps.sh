# shellcheck shell=bash disable=SC2034 # its globals are read by the functions that call these
# The dependency install a new slot of a JavaScript repo gets before its agent starts.

# Installs what the clone's root lockfile pins, because a repo's hooks fail every tool-backed gate in a clone without it.
# An install runs lifecycle scripts with this account's credentials before anyone reads them, so it runs only where that
# is already chosen. A prime with no package in node_modules, or one Claude does not trust, shows no install has been
# chosen on this host. A head the base branch does not hold could change what runs through any tracked file: a
# package.json, an .npmrc's script-shell, an npm-shrinkwrap.json that outranks the lock, or a script they call. Only a
# frozen install runs: it writes no lockfile, and a lockfile that disagrees with its package.json fails. It also takes
# whatever the lockfile pins without consulting the supply-chain age gate, a release published that day included
# (measured on npm 11.16, bun 1.4.4, and pnpm 11.9), so the gate binds only whoever wrote the lock. npm and pnpm still
# get the gate from its one definition, because a lifecycle script that resolves a version reads it from the environment,
# which an SSH command or a Claude hook may not have set; bun reads it from ~/.bunfig.toml. A nested lockfile is left
# alone: the repos' hooks pass on the root install, and some nested ones are fixtures. bun comes first because the repo
# that holds two lockfiles installs with bun. An install that does not finish leaves a usable slot, so it is reported
# rather than fatal.
#
# PARITY_DEPS is {manager, command, status, log, off_base, dirty, dirty_total, stopped, stopped_total}, with status one of
# installed, failed, timed-out, tool-missing, not-ignored, prime-not-set-up, head-not-on-base, or null when the repo has
# nothing to install, and off_base what _parity_off_base prints, or null. A script can leave what blocks teardown under
# any status: dirty names the paths it left, and stopped the processes setup stopped, by name only, since an argument can
# hold a secret and the ledger keeps this. dirty misses a file that was already dirty before the install changed it
# further, which only a reopen can meet, and dirty_total past the list's cap can count build output.
PARITY_DEPS=null
PARITY_INSTALL_RUN=''
parity_deps() {
  local prime=$1 slot=$2 manager tool out started status=installed log='' before off_base dirty='' stopped
  local -a args run
  PARITY_DEPS=null PARITY_STOPPED=()
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
  off_base=$(_parity_off_base "$prime" "$slot")
  if ! trust_known "$prime" || ! _parity_prime_has_deps "$prime"; then
    status='prime-not-set-up'
  elif [[ -n $off_base ]]; then
    status='head-not-on-base'
  elif ! git -C "$slot" check-ignore -q node_modules/; then
    status='not-ignored'
  elif [[ -z $tool ]]; then
    status='tool-missing'
  else
    run=("$tool" "${args[@]}")
    [[ $manager == bun ]] \
      || run=(bash -c 'source "$1"; shift; exec "$@"' gate "$AS_HOME/../../config/shell/supply-chain.sh" "${run[@]}")
    before=$(mktemp)
    _parity_status "$slot" >"$before" || true
    PARITY_INSTALL_RUN=$(mktemp)
    contract_on_exit _parity_stop_install
    run=(setsid --wait bash -c 'printf "%s" "$$" >"$1"; shift; exec "$@"' session "$PARITY_INSTALL_RUN" "${run[@]}")
    started=$SECONDS
    if ! bounded out deps "$AS_DEPS_TIMEOUT" "${AS_GIT_REMOTE[@]}" "PATH=${tool%/*}:$PATH" \
      "AGENT_SLOT_INSTALL_RUN=$PARITY_INSTALL_RUN" PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
      /usr/bin/env -C "$slot" "${run[@]}"; then
      status=failed
      # A manager that ignores TERM takes timeout's KILL and exits 137; a KILL from outside, such as the OOM killer, ends
      # the install before the limit and stays a failure.
      if ((BOUNDED_STATUS == 124 || (BOUNDED_STATUS == 137 && SECONDS - started >= AS_DEPS_TIMEOUT))); then
        status='timed-out'
      fi
      log=$BOUNDED_LOG
    fi
    _parity_stop_install
    dirty=$(_parity_new_paths "$slot" "$before") || dirty=''
    rm -f "$before"
  fi
  stopped=$(printf '%s\n' "${PARITY_STOPPED[@]}" | sort)
  PARITY_DEPS=$(contract_json -n -c --arg manager "$manager" --arg command "$manager ${args[*]}" --arg status "$status" \
    --arg log "$log" --arg off_base "$off_base" \
    --argjson dirty "$(_parity_json_lines "$dirty")" --argjson dirty_total "$(_parity_line_count "$dirty")" \
    --argjson stopped "$(_parity_json_lines "$stopped")" --argjson stopped_total "$(_parity_line_count "$stopped")" \
    '{manager: $manager, command: $command, status: $status, log: (if $log == "" then null else $log end),
      off_base: (if $off_base == "" then null else $off_base end),
      dirty: $dirty, dirty_total: $dirty_total, stopped: $stopped, stopped_total: $stopped_total}')
}

# A list and its entries stay this short: deps travels by argument through the slot record, the ledger, and the session
# context, and one argument past 128 KiB would fail the launch and roll the slot back.
PARITY_LIST_MAX=50
PARITY_ENTRY_MAX=256

# Usage: _parity_json_lines <text>; prints its first non-empty lines as a JSON array. jaq refuses a byte that is not UTF-8,
# which a path can hold and the cut can leave, so those go; this list is a report. iconv exits non-zero when it drops one.
_parity_json_lines() {
  LC_ALL=C awk -v max="$PARITY_LIST_MAX" -v width="$PARITY_ENTRY_MAX" 'length($0) && ++n <= max { print substr($0, 1, width) }' <<<"$1" \
    | { iconv -c -f UTF-8 -t UTF-8 || true; } \
    | contract_json -R -s -c 'split("\n") | map(select(. != ""))'
}

# Usage: _parity_line_count <text>; prints how many non-empty lines it holds.
_parity_line_count() {
  grep -c . <<<"$1" || true
}

# Usage: _parity_status <slot>; prints what the slot holds beyond HEAD, one NUL-ended entry per path, sorted for comm: git
# status with an ignored directory whole, as `agent-slot check` reads it, and each ignored file under the directories
# setup fills, since a directory listed whole hides a write inside it.
_parity_status() {
  {
    git -C "$1" status --porcelain=v1 -z --no-renames --untracked-files=all --ignored=matching
    git -C "$1" ls-files -z --others --ignored --exclude-standard -- .claude .context docs | sed -z 's/^/!! /'
  } | LC_ALL=C sort -zu
}

# Usage: _parity_new_paths <slot> <snapshot from _parity_status>; prints each path new since the snapshot, one per line,
# leaving out the tool and build output `agent-slot check` leaves out, and what is under it: the C sort puts a directory
# before its files. A newline in a name prints as ?. A path past what the list can name only adds to a count, so the rest
# go unclassified, since this loop costs seconds per 10,000 paths after the install's time limit has ended.
_parity_new_paths() {
  local entry path skipped='' named=0
  while IFS= read -r -d '' entry; do
    path=${entry:3}
    if [[ ${entry:0:2} == '!!' ]]; then
      [[ -z $skipped || $path != "$skipped"* ]] || continue
      if _check_build_output '!!' "$path"; then
        skipped=$path
        continue
      fi
    fi
    printf '%s\n' "${path//$'\n'/?}"
    ((++named < PARITY_LIST_MAX)) || {
      cut -z -c4- | tr '\n\0' '?\n'
      break
    }
  done < <(LC_ALL=C comm -z -13 "$2" <(_parity_status "$1"))
}

# Stops what the install left running, and sets PARITY_STOPPED to its names: whatever is still in the install's session,
# and whatever left that session but carries the environment entry the install started with. A process that did both
# stays running, and `agent-slot check` names it if it holds the slot. The passes after the first are for a process that
# ignores TERM and keeps forking. Runs at exit too, for a launch stopped during its install, and before a rollback, so
# nothing still writing can bring back the path the rollback removed. It stays armed until it is done, so a stop that lands
# during these passes runs them again. SIGKILL runs no cleanup, so a launch killed that way leaves these running.
_parity_stop_install() {
  local run_file=$PARITY_INSTALL_RUN session pid pids signal=TERM pass
  local -A names=()
  [[ -n $run_file ]] || return 0
  session=$(<"$run_file") || session=''
  for pass in 1 2 3 4; do
    pids=$(_parity_install_pids "$session" "$run_file")
    [[ -n $pids ]] || break
    for pid in $pids; do
      [[ -n ${names[$pid]:-} ]] || names[$pid]=$(cat "/proc/$pid/comm" 2>/dev/null) || true
      kill "-$signal" "$pid" 2>/dev/null || true
    done
    sleep 0.2
    signal=KILL
  done
  PARITY_INSTALL_RUN=''
  rm -f "$run_file"
  PARITY_STOPPED=("${names[@]}")
}

# Usage: _parity_install_pids <session id> <run>; prints the pid of each process in that session or carrying that run's
# environment entry. grep has no such entry and reads it from stdin, so it never matches itself.
_parity_install_pids() {
  {
    [[ ! $1 =~ ^[1-9][0-9]*$ ]] || pgrep -s "$1" || true
    # shellcheck disable=SC2062 # the glob names the files; the pattern comes from stdin
    grep -lsazxF -f - /proc/[0-9]*/environ <<<"AGENT_SLOT_INSTALL_RUN=$2" | cut -d/ -f3 || true
  } | sort -un
}

# True when a prime's node_modules holds a package. A repo with a dependency leaves one at the top level under bun, npm,
# and pnpm alike. A dot directory there shows no install: prettier and vite make theirs in a repo nobody installed.
_parity_prime_has_deps() {
  local entry
  for entry in "$1"/node_modules/*; do
    [[ ! -e $entry ]] || return 0
  done
  return 1
}

# Usage: _parity_off_base <prime> <slot>; prints why the slot's head is not one this host has chosen, or nothing when it is.
# parity_base takes a dev branch by its name, and anyone who can push to origin can make one, so the base counts only if
# the prime holds a branch of that name and has seen it on origin (prime-lacks-base), and origin's still holds what the prime
# last saw (base-rewritten). A fast-forward of the base installs: the base's own scripts are what the prime tracks. Then the
# base must hold the head (base-lacks-head), and a PR's own base must too (pr-base-lacks-head), since a release PR's head is
# on dev and not yet on main. The head must be the base's tip (head-behind-base), since a head set back to an older commit
# can bring back a script the base has since removed. A prime that fetches between the clone and this check reads as
# base-rewritten for that one slot, which declines rather than installs.
_parity_off_base() {
  local prime=$1 slot=$2 base_ref="refs/remotes/origin/$PARITY_BASE" known pr_base
  if ! git -C "$prime" show-ref --verify -q "refs/heads/$PARITY_BASE" \
    || ! known=$(git -C "$prime" rev-parse -q --verify "$base_ref^{commit}"); then
    echo prime-lacks-base
    return 0
  fi
  # A commit a partial clone lacks fails here at once, rather than fetching for as long as the network allows.
  if ! GIT_NO_LAZY_FETCH=1 git -C "$slot" merge-base --is-ancestor "$known" "$base_ref" 2>/dev/null; then
    echo base-rewritten
    return 0
  fi
  if ! git -C "$slot" merge-base --is-ancestor HEAD "$base_ref" 2>/dev/null; then
    echo base-lacks-head
    return 0
  fi
  if [[ $(contract_json -r '.kind // ""' <<<"${ITEM:-null}") == pr ]]; then
    pr_base=$(contract_json -r '.base_branch // ""' <<<"${ITEM:-null}")
    if [[ -z $pr_base ]] || ! git -C "$slot" merge-base --is-ancestor HEAD "refs/remotes/origin/$pr_base" 2>/dev/null; then
      echo pr-base-lacks-head
      return 0
    fi
  fi
  [[ $(git -C "$slot" rev-parse HEAD) == "$(git -C "$slot" rev-parse "$base_ref")" ]] || echo head-behind-base
}
