# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Purging a torn-down slot's clone from the trash. The trash shares the slot root's volume, so moving the clone there
# frees nothing until that entry is purged, and teardown purges it at once.
#
# trash-cli names the entry it makes only in its -vv debug log, which is no interface: it takes the file's name, then
# appends _1 through _99, then a random _N, whichever is free. The clone's entry is the one whose .trashinfo gives the
# clone's path after the move and did not before it. Another file's entry gives another path, and no other entry for
# this path can appear in between, since the slot lock is held and the path is empty once the move is done. When the
# move added no such entry, or more than one, nothing is purged.
#
# The purge deletes the entry's files first and its .trashinfo last, so an interrupted purge leaves an entry that
# trash-rm still finds. It runs after the slot lock is released, since launch takes the lock of the lowest free slot
# without waiting and the purge touches nothing under the slot root. A purge that fails or outlasts PURGE_BOUND leaves
# the slot torn down and reports a code from PURGE_CODES, with the trash-rm command that finishes it.

PURGE_CODES='trash-entry-unknown purge-failed'
PURGE_DOCS=${CONTRACT_DOCS%#*}#purge-failures
# Rex's finish key allows the server's finish 300 s, and trash-empty purged 801 GB in 3,716 entries, 725 of them
# torn-down clones, in 99 s on this server.
PURGE_BOUND=180
PURGE_PATH=
PURGE_BEFORE=()
PURGE_ENTRY=
PURGE_RESULT=null

# Usage: _purge_entries <path>; prints the name of each trash entry whose .trashinfo gives <path> as where it came from.
_purge_entries() {
  local file line location name base=${1##*/}
  for file in "$AS_TRASH_DIR/info/$base.trashinfo" "$AS_TRASH_DIR/info/${base}_"*.trashinfo; do
    [[ -f $file ]] || continue
    location=
    while IFS= read -r line; do
      if [[ $line == Path=* ]]; then
        location=${line#Path=}
        break
      fi
    done <"$file"
    printf -v location '%b' "${location//%/\\x}"
    [[ $location == "$1" ]] || continue
    name=${file##*/}
    printf '%s\n' "${name%.trashinfo}"
  done
}

# Usage: purge_before <path>; records the trash's entries for <path> before teardown moves it there.
purge_before() {
  PURGE_PATH=$1
  mapfile -t PURGE_BEFORE < <(_purge_entries "$1")
}

# Sets PURGE_ENTRY to the one entry for PURGE_PATH that purge_before did not see, or '' when there is not exactly one.
purge_find() {
  local name added=0
  local -A seen=()
  for name in "${PURGE_BEFORE[@]}"; do seen[$name]=1; done
  PURGE_ENTRY=
  while IFS= read -r name; do
    [[ -z ${seen[$name]:-} ]] || continue
    PURGE_ENTRY=$name
    added=$((added + 1))
  done < <(_purge_entries "$PURGE_PATH")
  ((added == 1)) || PURGE_ENTRY=
}

# Usage: purge_run <repo> <n>; deletes PURGE_ENTRY from the trash, sets PURGE_RESULT to {purged, entry, ms}, with code,
# message, next_step, and log when it failed, and appends a purge ledger event.
purge_run() {
  local start out entry='' code='' message='' log=''
  start=$(contract_ms)
  if [[ -z $PURGE_ENTRY ]]; then
    code=trash-entry-unknown
    message="the trash gained no single entry for $PURGE_PATH, so nothing was purged"
  else
    entry=$AS_TRASH_DIR/files/$PURGE_ENTRY
    if bounded out purge "$PURGE_BOUND" rm -rf --one-file-system -- "$entry"; then
      bounded out purge 10 rm -f -- "$AS_TRASH_DIR/info/$PURGE_ENTRY.trashinfo" || true
    fi
    if ((BOUNDED_STATUS == 124)); then
      code=purge-failed message="rm did not finish purging $entry within $PURGE_BOUND s" log=$BOUNDED_LOG
    elif ((BOUNDED_STATUS != 0)); then
      code=purge-failed message="rm exited $BOUNDED_STATUS purging $entry" log=$BOUNDED_LOG
    fi
  fi
  PURGE_RESULT=$(contract_json -n -c --arg entry "$entry" --arg code "$code" --arg m "$message" --arg log "$log" \
    --arg cmd "$(contract_quote trash-rm "$PURGE_PATH")" --arg docs "$PURGE_DOCS" \
    --argjson ms "$(($(contract_ms) - start))" '
    {purged: ($code == ""), entry: (if $entry == "" then null else $entry end), ms: $ms}
    + (if $code == "" then {} else {code: $code, message: $m, next_step: {action: "run", command: $cmd, docs: $docs},
       log: (if $log == "" then null else $log end)} end)')
  ledger_append purge "$(contract_json -c --arg repo "$1" --argjson n "$2" '{repo: $repo, slot: $n} + .' \
    <<<"$PURGE_RESULT")"
}
