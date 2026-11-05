# --check: compare the cache with the pin and report every difference with a
# stable reason, changing nothing. Builds this deploy recorded that the pin no
# longer names are retained, not stray.

pw_check() {
  local i n t e l q
  for i in "${!PW_DIR[@]}"; do
    n=${PW_DIR[$i]}
    if ! pw_dir_complete "$i"; then
      pw_finding "$n is missing or incomplete" directory-incomplete "changed nothing; a deploy restores it" "$PW_DEPLOY"
    elif ! pw_provisioned "$i"; then
      pw_finding "$n was not provisioned from the archive and URL the pin names" provenance-mismatch \
        "changed nothing; a deploy fetches it again" "$PW_DEPLOY"
    fi
  done
  for e in "${PW_ALIAS[@]}"; do
    n=${e%% *}
    t=${e##* }
    if [ -L "$BP/$n" ]; then
      { [ "$(readlink "$BP/$n")" = "$t" ] && [ -f "$BP/$n/INSTALLATION_COMPLETE" ]; } \
        || pw_finding "alias $n does not resolve to $t" alias-wrong-target "changed nothing; a deploy repoints it" "$PW_DEPLOY"
    elif [ -e "$BP/$n" ]; then
      pw_finding "$n is a real directory where the pin puts an alias to $t" alias-real-directory \
        "changed nothing; a deploy replaces it with the alias" "$PW_DEPLOY"
    else
      pw_finding "alias $n to $t is missing" alias-missing "changed nothing; a deploy creates it" "$PW_DEPLOY"
    fi
  done
  for n in "${PW_WANTED[@]}"; do
    pw_client_ok "$n" \
      || pw_finding "no client registers $n, so another Playwright's install deletes it" client-missing \
        "changed nothing; a deploy registers it" "$PW_DEPLOY"
  done
  for l in "$PW_LINKS"/dotfiles-*; do
    [ -L "$l" ] || [ -e "$l" ] || continue
    ! pw_in "${l##*/dotfiles-}" "${PW_WANTED[@]}" || continue
    q=$(printf %q "$l")
    pw_finding "a client link names nothing in the set" client-unrecognised \
      "changed nothing; a deploy removes the ones it wrote" "ls -l $q" "${l##*/}"
  done
  for e in "$BP"/*; do
    n=${e##*/}
    [[ $n =~ $PW_BROWSER_RE ]] || continue
    ! pw_in "$n" "${PW_WANTED[@]}" || continue
    q=$(printf %q "$e")
    if [ -L "$e" ]; then
      pw_finding "a symlink at a browser-directory name is not an alias of the pin" stray-symlink \
        "changed nothing; a deploy removes the ones that point into this cache" "ls -l $q" "$n"
    else
      pw_finding "a browser directory is outside the pin and no deploy recorded it" stray-directory \
        "changed nothing; remove it once nothing uses it" "ls -ld $q" "$n"
    fi
  done
  for n in "${PW_RETAINED[@]}"; do pw_note "retained build $n"; done
  pw_finding_tail
  [ "$PW_FAILED" -eq 0 ] || exit 1
  printf 'OK: browser set %s at CfT %s, WebKit %s, ffmpeg %s: %s aliases, %s clients\n' \
    "$BP" "$PIN_CFT_VERSION" "$PIN_WEBKIT_REVISION" "$PIN_FFMPEG_REVISION" "${#PW_ALIAS[@]}" "${#PW_WANTED[@]}"
}
