# What the pin turns into on this host: the real directories to provision, the
# aliases that point at them, and the recorded builds already on disk. Download
# hosts are fixed here and never read from the pin.

PW_CFT_HOST=https://storage.googleapis.com/chrome-for-testing-public
PW_CDN=https://cdn.playwright.dev/builds
PW_DIR_RE='^(chromium|chromium_headless_shell|webkit|ffmpeg)-[0-9]+$'
PW_BROWSER_RE='^[a-z_]+(-[a-z_]+)*-[0-9]+$'

# archive | platform | kind | directory prefix | executable inside the directory
PW_TABLE=(
  'chrome-linux64.zip|linux-x64|cft|chromium|chrome-linux64/chrome'
  'chrome-headless-shell-linux64.zip|linux-x64|cft|chromium_headless_shell|chrome-headless-shell-linux64/chrome-headless-shell'
  'webkit-ubuntu-24.04.zip|linux-x64|webkit|webkit|pw_run.sh'
  'ffmpeg-linux.zip|linux-x64|ffmpeg|ffmpeg|ffmpeg-linux'
  'chrome-mac-arm64.zip|mac-arm64|cft|chromium|chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'
  'chrome-headless-shell-mac-arm64.zip|mac-arm64|cft|chromium_headless_shell|chrome-headless-shell-mac-arm64/chrome-headless-shell'
  'webkit-mac-14-arm64.zip|mac-arm64|webkit|webkit|pw_run.sh'
  'webkit-mac-15-arm64.zip|mac-arm64|webkit|webkit|pw_run.sh'
  'webkit-mac-26-arm64.zip|mac-arm64|webkit|webkit|pw_run.sh'
  'ffmpeg-mac-arm64.zip|mac-arm64|ffmpeg|ffmpeg|ffmpeg-mac'
)

# Every archive name the pin may hash, and those every pin must hash: a Mac
# WebKit archive is present only for the macOS releases its build supports.
PW_ARCHIVES="" PW_REQUIRED=""
for _row in "${PW_TABLE[@]}"; do
  PW_ARCHIVES+="${_row%%|*} "
  [[ $_row == webkit-mac-* ]] || PW_REQUIRED+="${_row%%|*} "
done
unset _row

pw_in() {
  local x="$1" e
  shift
  for e in "$@"; do [ "$e" = "$x" ] && return 0; done
  return 1
}

pw_detect_platform() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) PW_PLATFORM=linux-x64 PW_CFT_DIR=linux64 ;;
    Darwin/arm64) PW_PLATFORM=mac-arm64 PW_CFT_DIR=mac-arm64 ;;
    *) pw_fail "no browser set is built for this platform" unsupported-platform \
      "nothing changed" "$PW_DEPLOY --help" "$(uname -s) $(uname -m)" ;;
  esac
}

# Playwright's registry maps the Darwin major to a macOS release (23 is 14, 24
# is 15, 25 and later 26) and downloads that release's WebKit archive. A Mac is
# refused unless the pin hashes that archive; one older than the lowest the pin
# hashes is told the release required, and one the pin has no archive for is told so.
pw_mac_webkit() {
  local darwin mac=0 lowest="" a
  darwin=$(uname -r)
  darwin=${darwin%%.*}
  if [[ $darwin =~ ^[0-9]+$ ]]; then
    if [ "$darwin" -ge 25 ]; then mac=26; elif [ "$darwin" -ge 23 ]; then mac=$((darwin - 9)); fi
  fi
  PW_WEBKIT_ARCHIVE="webkit-mac-$mac-arm64.zip"
  [ -z "${PIN_SHA[$PW_WEBKIT_ARCHIVE]:-}" ] || return 0
  for a in $PW_ARCHIVES; do
    [[ $a == webkit-mac-* && -n "${PIN_SHA[$a]:-}" ]] || continue
    lowest=${a#webkit-mac-}
    lowest=${lowest%%-*}
    break
  done
  if [ -n "$lowest" ] && [ "$mac" -lt "$lowest" ]; then
    pw_fail "this pin's WebKit needs macOS $lowest or later" mac-release-unsupported \
      "nothing downloaded" "$PW_DEPLOY --help" "Darwin $(uname -r)"
  fi
  pw_fail "this pin hashes no WebKit build for macOS $mac" mac-release-unsupported \
    "nothing downloaded" "$PW_DEPLOY --help" "Darwin $(uname -r)"
}

# Fills PW_DIR, PW_EXE, PW_ARCHIVE and PW_URL for the four directories this
# host provisions, and PW_ALIAS with "alias target" pairs.
pw_plan() {
  local row archive plat kind prefix exe rev url r
  PW_DIR=() PW_EXE=() PW_ARCHIVE=() PW_URL=() PW_ALIAS=()
  pw_detect_platform
  [ "$PW_PLATFORM" = linux-x64 ] || pw_mac_webkit
  for row in "${PW_TABLE[@]}"; do
    IFS='|' read -r archive plat kind prefix exe <<<"$row"
    [ "$plat" = "$PW_PLATFORM" ] || continue
    [[ $archive != webkit-mac-* || $archive = "$PW_WEBKIT_ARCHIVE" ]] || continue
    case "$kind" in
      cft) rev=$PW_CFT_NUMBER url=$PW_CFT_HOST/$PIN_CFT_VERSION/$PW_CFT_DIR/$archive ;;
      webkit) rev=$PIN_WEBKIT_REVISION url=$PW_CDN/webkit/$PIN_WEBKIT_REVISION/$archive ;;
      ffmpeg) rev=$PIN_FFMPEG_REVISION url=$PW_CDN/ffmpeg/$PIN_FFMPEG_REVISION/$archive ;;
    esac
    PW_DIR+=("$prefix-$rev") PW_EXE+=("$exe") PW_ARCHIVE+=("$archive") PW_URL+=("$url")
  done
  for r in $PIN_CHROMIUM_ALIASES; do
    PW_ALIAS+=("chromium-$r chromium-$PW_CFT_NUMBER" "chromium_headless_shell-$r chromium_headless_shell-$PW_CFT_NUMBER")
  done
  for r in $PIN_WEBKIT_ALIASES; do
    [ "$r" = "$PIN_WEBKIT_REVISION" ] || PW_ALIAS+=("webkit-$r webkit-$PIN_WEBKIT_REVISION")
  done
  for r in $PIN_FFMPEG_ALIASES; do
    [ "$r" = "$PIN_FFMPEG_REVISION" ] || PW_ALIAS+=("ffmpeg-$r ffmpeg-$PIN_FFMPEG_REVISION")
  done
}

# PW_WANTED is every directory name that needs a client: the set, the aliases,
# and any build this deploy recorded earlier that the pin no longer names.
pw_wanted() {
  local d n a
  PW_WANTED=("${PW_DIR[@]}") PW_RETAINED=()
  for a in "${PW_ALIAS[@]}"; do PW_WANTED+=("${a%% *}"); done
  for d in "$BP"/*/; do
    d=${d%/}
    n=${d##*/}
    [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/.dotfiles-record" ] || continue
    [[ $n =~ $PW_DIR_RE ]] || continue
    ! pw_in "$n" "${PW_WANTED[@]}" || continue
    PW_WANTED+=("$n") PW_RETAINED+=("$n")
  done
}
