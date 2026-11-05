# Shared setup for the browser-set suites (tests/playwright-*.bats): a sandbox
# cache, a fake platform and download tools, archives laid out the way
# Playwright launches from them, and the pinned playwright-core for the cases
# that run Playwright's own cleanup. Load with: load lib/browser-set

BS_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
BS_SCRIPT="$BS_ROOT/scripts/playwright-browsers-deploy.sh"
BS_PIN="$BS_ROOT/config/playwright/browsers.pin"
BS_CORE_CACHE="${BS_CORE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-bats/playwright-core}"
BS_REAL_CURL="$(command -v curl)"

# Each archive and the executable Playwright launches from inside it, as read
# from the registry's EXECUTABLE_PATHS rather than from the scripts under test.
BS_ARCHIVE_SPECS=(
  chrome-linux64.zip=chrome-linux64/chrome
  chrome-headless-shell-linux64.zip=chrome-headless-shell-linux64/chrome-headless-shell
  webkit-ubuntu-24.04.zip=pw_run.sh
  ffmpeg-linux.zip=ffmpeg-linux
  'chrome-mac-arm64.zip=chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'
  chrome-headless-shell-mac-arm64.zip=chrome-headless-shell-mac-arm64/chrome-headless-shell
  webkit-mac-15-arm64.zip=pw_run.sh
  webkit-mac-26-arm64.zip=pw_run.sh
  ffmpeg-mac-arm64.zip=ffmpeg-mac
)

bs_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# setup_file: BS_ARCHIVES (fixture archives) and BS_TEST_PIN, the repo's pin
# with each archive's hash replaced by its fixture's.
bs_build_archives() {
  BS_ARCHIVES="$BATS_FILE_TMPDIR/archives"
  BS_TEST_PIN="$BATS_FILE_TMPDIR/test.pin"
  mkdir -p "$BS_ARCHIVES"
  python3 -B -I -c '
import sys, zipfile
out = sys.argv[1]
for spec in sys.argv[2:]:
    name, path = spec.split("=", 1)
    with zipfile.ZipFile(out + "/" + name, "w") as z:
        info = zipfile.ZipInfo(path)
        info.external_attr = 0o755 << 16
        z.writestr(info, "#!/bin/sh\necho " + name + "\n")
' "$BS_ARCHIVES" "${BS_ARCHIVE_SPECS[@]}"
  {
    grep -v '^sha256 ' "$BS_PIN"
    for spec in "${BS_ARCHIVE_SPECS[@]}"; do
      echo "sha256 ${spec%%=*} $(bs_sha256 "$BS_ARCHIVES/${spec%%=*}")"
    done
  } >"$BS_TEST_PIN"
  export BS_ARCHIVES BS_TEST_PIN
}

# setup: a sandbox cache, a uname that reports BS_OS/BS_ARCH/BS_KERNEL, and a
# curl that serves the fixture named by the URL's last component and logs its
# command line. A URL containing BS_CURL_404 answers 404; BS_CURL_SERVE replaces the bytes.
bs_sandbox() {
  local stubs="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$stubs"
  cat >"$stubs/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -m) echo "${BS_ARCH:-x86_64}" ;; -r) echo "${BS_KERNEL:-6.8.0}" ;; *) echo "${BS_OS:-Linux}" ;; esac
EOF
  cat >"$stubs/curl" <<'EOF'
#!/usr/bin/env bash
ARGS="$*" url="" out=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac
  shift
done
echo "$ARGS" >>"$BS_CURL_LOG"
name=${url##*/}
case "$url" in *"${BS_CURL_404:-@none@}"*) src=/nonexistent ;; *) src="$BS_ARCHIVES/$name" ;; esac
[ -f "$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "${BS_CURL_SERVE:-$src}" "$out"
EOF
  chmod +x "$stubs/uname" "$stubs/curl"
  PATH="$stubs:$PATH"
  export BS_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  : >"$BS_CURL_LOG"
  export PLAYWRIGHT_BROWSERS_PATH="$BATS_TEST_TMPDIR/browsers"
  BP="$PLAYWRIGHT_BROWSERS_PATH"
  unset PLAYWRIGHT_SKIP_BROWSER_GC PLAYWRIGHT_DOWNLOAD_HOST BS_OS BS_ARCH BS_KERNEL BS_CURL_404 BS_CURL_SERVE
}

# A Mac of the given Darwin kernel (25 is macOS 26, 24 is 15, 23 is 14).
bs_as_mac() {
  export BS_OS=Darwin BS_ARCH=arm64 BS_KERNEL="${1:-27.0.0}"
}

# Nothing here may reach a cache outside the test's own sandbox.
bs_guard() {
  [[ ${PLAYWRIGHT_BROWSERS_PATH:-} == "$BATS_TEST_TMPDIR"/* ]] || {
    echo "refusing to run outside the test sandbox: ${PLAYWRIGHT_BROWSERS_PATH:-unset}" >&2
    return 1
  }
}

deploy() {
  bs_guard || return 1
  run --separate-stderr "$BS_SCRIPT" --pin "$BS_TEST_PIN" "$@"
}

# A finished install as Playwright leaves one: the executable and both markers.
bs_seed() {
  local dir="$1" exe="${2:-bin}"
  mkdir -p "$BP/$dir/$(dirname "$exe")"
  : >"$BP/$dir/$exe"
  chmod +x "$BP/$dir/$exe"
  : >"$BP/$dir/INSTALLATION_COMPLETE"
  : >"$BP/$dir/DEPENDENCIES_VALIDATED"
}

# Prints the unpacked pinned playwright-core, fetching it into BS_CORE_CACHE by
# the hash in the pin, read through the pin's own parser. Exit 77 when the
# registry cannot be reached at all; any HTTP error or a differing hash is a
# failure. BS_FETCH_CURL replaces curl, for the cases that exercise this.
bs_core_fetch() {
  local ver sha dir tmp rc=0
  read -r ver sha < <("$BASH" -c 'source "$1/scripts/playwright-browsers/lib/pin.sh"; pin_load "$2"; echo "$PIN_LIBRARY_VERSION $PIN_LIBRARY_SHA256"' _ "$BS_ROOT" "$BS_PIN")
  dir="$BS_CORE_CACHE/$sha"
  if [ -f "$dir/package/cli.js" ]; then
    echo "$dir/package"
    return 0
  fi
  mkdir -p "$BS_CORE_CACHE"
  tmp="$(mktemp -d "$BS_CORE_CACHE/.fetch.XXXXXX")"
  "${BS_FETCH_CURL:-$BS_REAL_CURL}" -sS -f -m 120 -o "$tmp/core.tgz" "https://registry.npmjs.org/playwright-core/-/playwright-core-$ver.tgz" || rc=$?
  case "$rc" in
    0) ;;
    6 | 7 | 28 | 35 | 52 | 56) echo "no route to the npm registry (curl exit $rc)" >&2 && return 77 ;;
    *) echo "fetching playwright-core $ver failed (curl exit $rc)" >&2 && return 1 ;;
  esac
  [ "$(bs_sha256 "$tmp/core.tgz")" = "$sha" ] || {
    echo "playwright-core $ver does not hash to the pin's $sha" >&2
    return 1
  }
  tar -xzf "$tmp/core.tgz" -C "$tmp"
  mkdir -p "$dir"
  mv "$tmp/package" "$dir/package" 2>/dev/null || true
  rm -rf "${tmp:?}"
  echo "$dir/package"
}

# CORE is the pinned playwright-core, or the test skips for want of node or a
# route to the registry.
bs_need_core() {
  local rc=0
  command -v node >/dev/null 2>&1 || skip "node is not on PATH"
  CORE="$(bs_core_fetch)" || rc=$?
  [ "$rc" -ne 77 ] || skip "the npm registry cannot be reached from this host"
  [ "$rc" -eq 0 ] || return 1
}

# Playwright's own CLI against the sandbox, with downloads pointed at a closed port.
bs_playwright() {
  bs_guard || return 1
  PLAYWRIGHT_DOWNLOAD_HOST=http://127.0.0.1:1 run node "$CORE/cli.js" "$@"
}
