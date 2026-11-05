# Playwright's install and uninstall delete every browser directory no client
# names, where a client is a .links file whose whole content is a directory
# holding a browsers.json. One client per directory and per alias keeps the set
# through that cleanup, since a browsers.json holds one revision per browser.

pw_client_json() {
  local name=${1%-*}
  printf '{"browsers": [{"name": "%s", "revision": "%s"}]}\n' "${name//_/-}" "${1##*-}"
}

# The trailing x keeps a newline that $(...) would strip and Playwright would not.
pw_client_ok() {
  [ "$(cat "$PW_CLIENTS/$1/browsers.json" 2>/dev/null)" = "$(pw_client_json "$1")" ] \
    && [ "$(
      cat "$PW_LINKS/dotfiles-$1" 2>/dev/null
      printf x
    )" = "$PW_CLIENTS/${1}x" ]
}

# A correct client is not touched. Otherwise the file is written outside .links
# and renamed in, browsers.json before the link, so a cleanup that runs midway
# never reads an empty or half-written client and deletes every directory.
pw_register() {
  pw_client_ok "$1" && return 0
  mkdir -p "$PW_CLIENTS/$1"
  pw_client_json "$1" >"$STAGE/json"
  pw_rename_over "$STAGE/json" "$PW_CLIENTS/$1/browsers.json"
  printf '%s' "$PW_CLIENTS/$1" >"$STAGE/link"
  pw_rename_over "$STAGE/link" "$PW_LINKS/dotfiles-$1"
}

# pw_alias NAME TARGET: a real directory at an alias name is replaced; a
# symlink already pointing at the target is left alone.
pw_alias() {
  local l="$BP/$1"
  [ -L "$l" ] && [ "$(readlink "$l")" = "$2" ] && return 0
  if [ -e "$l" ] && [ ! -L "$l" ]; then rm -rf "${l:?}"; fi
  ln -s "$2" "$STAGE/alias"
  pw_rename_over "$STAGE/alias" "$l"
}

# Removes only what this deploy can show it wrote: a stale dotfiles-<name> link
# whose content is the client directory of that name, in a shape the deploy
# writes or wrote before (playwright-<version> and chromium-alias-<revision>).
pw_prune_clients() {
  local link n body base
  for link in "$PW_LINKS"/dotfiles-*; do
    [ -L "$link" ] || [ -e "$link" ] || continue
    n=${link##*/dotfiles-}
    ! pw_in "$n" "${PW_WANTED[@]}" || continue
    body=$(
      cat "$link"
      printf x
    )
    body=${body%x}
    if [[ $n =~ $PW_DIR_RE ]]; then
      base=$PW_CLIENTS
    elif [[ $n =~ ^(playwright-[0-9]+\.[0-9]+\.[0-9]+|chromium-alias-[0-9]+)$ ]]; then
      base=$BP/.dotfiles
    else
      continue
    fi
    [ "$body" = "$base/$n" ] || continue
    rm -f "$base/$n/browsers.json" "$link"
    rmdir "$base/$n" 2>/dev/null || true
  done
}

# A symlink at a browser-directory name that the pin no longer asks for is a
# stale alias when it points into the cache; one pointing elsewhere stays.
pw_prune_symlinks() {
  local l n t
  for l in "$BP"/*; do
    [ -L "$l" ] || continue
    n=${l##*/}
    [[ $n =~ $PW_BROWSER_RE ]] || continue
    ! pw_in "$n" "${PW_WANTED[@]}" || continue
    t=$(readlink "$l")
    if [[ $t != */* || $t == "$BP"/* ]]; then rm -f "$l"; fi
  done
}
