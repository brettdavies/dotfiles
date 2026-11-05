# The one reader of config/playwright/browsers.pin. It never sources or evals
# the file and picks no field with sed: each line is split by `read`, and its
# value must match the shape listed here before it is kept. Anything else stops
# with a stable reason that shows the value masked (see errors.sh).

# shellcheck source=errors.sh
source "${BASH_SOURCE[0]%/*}/errors.sh"
# shellcheck source=plan.sh
source "${BASH_SOURCE[0]%/*}/plan.sh"

PIN_REVISION_RE='^[1-9][0-9]{0,8}$'
PIN_SEMVER_RE='^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'
PIN_SHA_RE='^[0-9a-f]{64}$'
declare -A PIN_SHA=()

pin_bad() {
  pw_fail "the pin has an invalid value for $1" pin-invalid-value "nothing changed" "$PW_DEPLOY --help" "$2"
}

# pin_load PATH sets PIN_CFT_VERSION, PIN_WEBKIT_REVISION, PIN_FFMPEG_REVISION,
# PIN_LIBRARY_VERSION, PIN_LIBRARY_SHA256, PIN_SOURCE_RELEASE, PIN_SOURCE_SHA256,
# PIN_{CHROMIUM,WEBKIT,FFMPEG}_ALIASES, PIN_SHA[archive] and PW_CFT_NUMBER, the
# number Playwright's cleanup can claim for the CfT directories: the build and
# patch, since the major and minor never reach it.
pin_load() {
  local path="$1" line key rest val extra name re seen=" " build patch
  local -a vals
  PIN_SHA=()
  [ -f "$path" ] && [ -r "$path" ] \
    || pw_fail "no readable pin at $(printf %q "$path")" pin-not-found "nothing changed" "$PW_DEPLOY --help"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    read -r key rest <<<"$line"
    re=
    case "$key" in
      cft-version) re='^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,3}$' ;;
      webkit-revision | ffmpeg-revision) re=$PIN_REVISION_RE ;;
      library-version | source-release) re=$PIN_SEMVER_RE ;;
      library-sha256 | source-sha256) re=$PIN_SHA_RE ;;
      chromium-aliases | webkit-aliases | ffmpeg-aliases)
        read -r -a vals <<<"$rest"
        [ "${#vals[@]}" -gt 0 ] || pin_bad "$key" "$rest"
        for val in "${vals[@]}"; do [[ $val =~ $PIN_REVISION_RE ]] || pin_bad "$key" "$val"; done
        ;;
      sha256)
        read -r val rest extra <<<"$rest"
        # shellcheck disable=SC2086 # PW_ARCHIVES is a list of names
        pw_in "$val" $PW_ARCHIVES && [[ $rest =~ $PIN_SHA_RE ]] && [ -z "$extra" ] && [ -z "${PIN_SHA[$val]:-}" ] \
          || pin_bad sha256 "$val $rest"
        PIN_SHA[$val]=$rest
        continue
        ;;
      *) pw_fail "the pin has a line this parser does not know" pin-malformed "nothing changed" "$PW_DEPLOY --help" "$key" ;;
    esac
    [ -z "$re" ] || [[ $rest =~ $re ]] || pin_bad "$key" "$rest"
    [[ $seen != *" $key "* ]] || pw_fail "the pin repeats a key" pin-malformed "nothing changed" "$PW_DEPLOY --help" "$key"
    seen+="$key "
    name=${key^^}
    printf -v "PIN_${name//-/_}" '%s' "$rest"
  done <"$path"
  for key in cft-version webkit-revision ffmpeg-revision library-version library-sha256 source-release source-sha256 \
    chromium-aliases webkit-aliases ffmpeg-aliases; do
    [[ $seen == *" $key "* ]] || pw_fail "the pin lacks a required key" pin-incomplete "nothing changed" "$PW_DEPLOY --help" "$key"
  done
  for val in $PW_REQUIRED; do
    [ -n "${PIN_SHA[$val]:-}" ] \
      || pw_fail "the pin lacks the sha256 of a required archive" pin-incomplete "nothing changed" "$PW_DEPLOY --help" "$val"
  done
  for val in $PIN_WEBKIT_ALIASES; do
    [ "$val" -le "$PIN_WEBKIT_REVISION" ] || pin_bad webkit-aliases "$val"
  done
  IFS=. read -r _ _ build patch <<<"$PIN_CFT_VERSION"
  PW_CFT_NUMBER=$((10#$build * 1000 + 10#$patch))
}
