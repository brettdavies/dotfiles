# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Slot paths, locks, records, and the ledger.
#
# A slot is ~/slots/<repo>/<N>. Its record is .git/agent-slot.json inside the clone, or ~/slots/<repo>/.<N>.claim.json
# before the clone exists. Records are replaced whole (temporary file, then rename) under the slot's lock.
#
# Two flock locks: ~/slots/<repo>/.lock covers only picking a slot number; ~/slots/<repo>/.<N>.lock is held by a launch
# from its claim to its commit point and taken by teardown, resume, and every record update. A setting-up or
# tearing-down slot is rolled back only by a process that takes the slot lock without waiting, which succeeds only
# once its owner has died.

declare -gA RECORD_LOCK_FDS=()

slot_path() { printf '%s/%s/%s' "$AS_ROOT" "$1" "$2"; }
slot_claim_file() { printf '%s/%s/.%s.claim.json' "$AS_ROOT" "$1" "$2"; }

# The record a reader sees: the clone's own once it has one, else the claim, which also covers a clone whose setup
# stopped before its record moved in.
record_file() {
  local in_clone
  in_clone=$(slot_path "$1" "$2")/.git/agent-slot.json
  if [[ -f $in_clone ]]; then
    printf '%s' "$in_clone"
  else
    slot_claim_file "$1" "$2"
  fi
}

# Where the next write lands: inside the clone as soon as it exists.
_record_target() {
  local path
  path=$(slot_path "$1" "$2")
  if [[ -d $path/.git ]]; then
    printf '%s/.git/agent-slot.json' "$path"
  else
    slot_claim_file "$1" "$2"
  fi
}

# Slot numbers that hold a clone or a claim, ascending. An empty slot path, such as one `warm` trusted ahead of time,
# holds neither and is free.
slot_numbers() {
  local dir=$AS_ROOT/$1 entry name
  [[ -d $dir ]] || return 0
  for entry in "$dir"/* "$dir"/.*.claim.json; do
    name=${entry##*/}
    if [[ $name == .*.claim.json ]]; then
      name=${name#.}
      name=${name%.claim.json}
      [[ -f $entry ]] || continue
    else
      [[ -d $entry/.git ]] || continue
    fi
    [[ $name =~ ^[0-9]+$ ]] && printf '%s\n' "$name"
  done | sort -n -u
}

slot_taken() {
  [[ -d $(slot_path "$1" "$2")/.git || -f $(slot_claim_file "$1" "$2") ]]
}

slot_repos() {
  local entry
  [[ -d $AS_ROOT ]] || return 0
  for entry in "$AS_ROOT"/*/; do
    [[ -d $entry ]] && printf '%s\n' "$(basename "$entry")"
  done
}

# Usage: record_lock <lock-file> <key> <--nowait | --wait SECONDS>
_record_lock() {
  local file=$1 key=$2 mode=$3 secs=${4:-0} fd
  [[ -z ${RECORD_LOCK_FDS[$key]:-} ]] || return 0
  mkdir -p "${file%/*}"
  exec {fd}>>"$file"
  if [[ $mode == --nowait ]]; then
    flock -n "$fd" || {
      exec {fd}>&-
      return 1
    }
  else
    flock -w "$secs" "$fd" || {
      exec {fd}>&-
      return 1
    }
  fi
  RECORD_LOCK_FDS[$key]=$fd
}

_record_unlock() {
  local fd=${RECORD_LOCK_FDS[$1]:-}
  [[ -n $fd ]] || return 0
  exec {fd}>&-
  unset 'RECORD_LOCK_FDS[$1]'
}

record_lock_repo() { _record_lock "$AS_ROOT/$1/.lock" "repo:$1" --wait "${2:-30}"; }
record_unlock_repo() { _record_unlock "repo:$1"; }

# Usage: record_lock_slot <repo> <n> [--nowait | --wait SECONDS]
record_lock_slot() { _record_lock "$AS_ROOT/$1/.$2.lock" "slot:$1/$2" "${3:---wait}" "${4:-10}"; }
record_unlock_slot() { _record_unlock "slot:$1/$2"; }
record_holds_slot() {
  local key=slot:$1/$2
  [[ -n ${RECORD_LOCK_FDS[$key]:-} ]]
}

# Sets RECORD to the record, or returns 1 when there is none. A record from a newer schema stops the command.
RECORD=
record_read() {
  local file
  RECORD=
  file=$(record_file "$1" "$2")
  [[ -f $file ]] || return 1
  RECORD=$(<"$file")
  record_check_schema "$RECORD" "$file"
}

record_check_schema() {
  local schema version
  schema=$(contract_json -r '.schema // ""' <<<"$1")
  version=${schema##*/}
  if [[ $version =~ ^[0-9]+$ ]] && ((version > CONTRACT_SCHEMA_VERSION)); then
    contract_fail record-schema-newer "$2 was written by a newer agent-slot ($schema)" --value "$schema" \
      --command "cd ~/dotfiles && git pull"
  fi
}

# Usage: record_write <repo> <n> <json>
# Replaces the record. Once the clone exists the record moves into it and the claim file goes away.
record_write() {
  local file tmp claim
  file=$(_record_target "$1" "$2")
  tmp=$(mktemp "${file%/*}/.agent-slot.json.XXXXXX")
  if ! contract_json -c --arg schema "$CONTRACT_SCHEMA" '.schema = $schema' <<<"$3" >"$tmp" || [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
  claim=$(slot_claim_file "$1" "$2")
  if [[ $file != "$claim" && -e $claim ]]; then
    rm -f "$claim"
  fi
}

# Usage: record_update <repo> <n> [jq options] <filter>
# Applies the filter to the record under the slot lock, so concurrent writers each land their own fields.
record_update() {
  local repo=$1 n=$2 took=0 updated
  shift 2
  if ! record_holds_slot "$repo" "$n"; then
    record_lock_slot "$repo" "$n" --wait 10 || return 1
    took=1
  fi
  if record_read "$repo" "$n" && updated=$(contract_json -c "$@" <<<"$RECORD"); then
    record_write "$repo" "$n" "$updated"
  else
    ((took == 0)) || record_unlock_slot "$repo" "$n"
    return 1
  fi
  ((took == 0)) || record_unlock_slot "$repo" "$n"
}

# Usage: ledger_append <event> <json-members-object>
ledger_append() {
  local line fd
  mkdir -p "${AS_LEDGER%/*}"
  line=$(contract_json -c --arg schema "$CONTRACT_SCHEMA" --arg ts "$(contract_now)" --arg event "$1" \
    '{schema: $schema, ts: $ts, event: $event} + .' <<<"$2")
  exec {fd}>>"$AS_LEDGER.lock"
  flock -w 5 "$fd" || true
  printf '%s\n' "$line" >>"$AS_LEDGER"
  exec {fd}>&-
}
