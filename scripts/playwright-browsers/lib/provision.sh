# Archives into numeric real directories, each with the record of the archive
# and URL it came from. A directory counts as provisioned only while its
# executable is present and that record matches what the pin now asks for.

# Directories this run put in place, for the failure line that says what it changed.
PW_ARRIVED=()

pw_moved() {
  if [ "${#PW_ARRIVED[@]}" -eq 0 ]; then
    echo "nothing moved; the existing set stays in place"
  else
    echo "no alias moved; ${PW_ARRIVED[*]} arrived and a rerun fetches the rest"
  fi
}

pw_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# Atomic rename that replaces a file or a symlink and never moves into a
# directory: -T on GNU mv, -h on the BSD one.
pw_rename_over() {
  if mv --version >/dev/null 2>&1; then mv -fT "$1" "$2"; else mv -fh "$1" "$2"; fi
}

pw_record() {
  printf 'sha256 %s\nurl %s\n' "${PIN_SHA[${PW_ARCHIVE[$1]}]}" "${PW_URL[$1]}"
}

pw_dir_complete() {
  local d="$BP/${PW_DIR[$1]}"
  [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/INSTALLATION_COMPLETE" ] && [ -x "$d/${PW_EXE[$1]}" ]
}

pw_provisioned() {
  pw_dir_complete "$1" && [ "$(cat "$BP/${PW_DIR[$1]}/.dotfiles-record" 2>/dev/null)" = "$(pw_record "$1")" ]
}

# pw_provision INDEX: fetch, verify, unpack and mark in the stage, then rename
# into place. The stage lives inside the cache so the rename never copies, and
# a failure before it leaves the existing directory alone.
pw_provision() {
  local i="$1" dir="${PW_DIR[$1]}" archive="${PW_ARCHIVE[$1]}" want got
  if pw_provisioned "$i"; then
    pw_note "$dir already provisioned"
    return 0
  fi
  want=${PIN_SHA[$archive]}
  pw_note "fetching $archive for $dir"
  curl --fail --silent --show-error --proto '=https' --retry 3 --retry-delay 2 \
    -o "$STAGE/$archive" "${PW_URL[$i]}" \
    || pw_fail "$archive could not be fetched from ${PW_URL[$i]}" archive-fetch-failed "$(pw_moved)" "$PW_DEPLOY"
  got=$(pw_sha256 "$STAGE/$archive")
  [ "$got" = "$want" ] \
    || pw_fail "$archive hashes to $got and the pin names $want" archive-hash-mismatch \
      "$(pw_moved)" "curl -fsS $(printf %q "${PW_URL[$i]}") | sha256sum"
  unzip -q "$STAGE/$archive" -d "$STAGE/$dir" \
    || pw_fail "$archive could not be unpacked" archive-extract-failed "$(pw_moved)" "$PW_DEPLOY"
  [ -x "$STAGE/$dir/${PW_EXE[$i]}" ] \
    || pw_fail "$archive does not hold the executable Playwright launches" archive-incomplete \
      "$(pw_moved)" "grep -n archive-incomplete $PW_RUNBOOK"
  : >"$STAGE/$dir/INSTALLATION_COMPLETE"
  : >"$STAGE/$dir/DEPENDENCIES_VALIDATED"
  pw_record "$i" >"$STAGE/$dir/.dotfiles-record"
  if [ -e "$BP/$dir" ] || [ -L "$BP/$dir" ]; then
    if [ "$(cat "$BP/$dir/.dotfiles-record" 2>/dev/null)" = "$(pw_record "$i")" ]; then
      pw_note "replacing $dir, whose executable or install marker is gone"
    else
      pw_note "replacing $dir, which is not from this pin"
    fi
  fi
  pw_register "$dir"
  rm -rf "${BP:?}/$dir" "${STAGE:?}/$archive"
  mv "$STAGE/$dir" "$BP/$dir"
  PW_ARRIVED+=("$dir")
  pw_note "provisioned $dir"
}
