#!/usr/bin/env bats
# Tests for scripts/playwright-browsers-deploy.sh: registering the browser set
# it provides with Playwright's install-time cleanup, and --check.
#
# Run: bats tests/playwright-browsers-deploy.bats
#      PLAYWRIGHT_CORE_DIR=<playwright-core package dir> bats tests/playwright-browsers-deploy.bats
#
# PLAYWRIGHT_BROWSERS_PATH points at a per-test sandbox seeded with finished
# installs, so every provisioning step skips; `curl` and `unzip` are stubs that
# fail the run if the script reaches for the network. `uname` is a stub
# reporting Linux, so the suite runs on a Mac too. The last test runs a real
# Playwright install against the sandbox and skips unless PLAYWRIGHT_CORE_DIR
# names a playwright-core package.
#
# run-tests: parallel

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/playwright-browsers-deploy.sh"
VERSION=1.62.1

# The Playwright 1.62.1 set: each directory and the executable Playwright
# launches from it.
CANONICAL=(
  "chromium-1234 chrome-linux64/chrome"
  "chromium_headless_shell-1234 chrome-headless-shell-linux64/chrome-headless-shell"
  "webkit-2336 pw_run.sh"
  "ffmpeg-1011 ffmpeg-linux"
)

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/usr/bin/env bash\necho Linux\n' >"$STUBS/uname"
  printf '#!/usr/bin/env bash\necho "unexpected download: $*" >&2\nexit 97\n' >"$STUBS/curl"
  printf '#!/usr/bin/env bash\necho "unexpected extract: $*" >&2\nexit 97\n' >"$STUBS/unzip"
  chmod +x "$STUBS/uname" "$STUBS/curl" "$STUBS/unzip"
  PATH="$STUBS:$PATH"
  export PLAYWRIGHT_BROWSERS_PATH="$BATS_TEST_TMPDIR/browsers"
  BP="$PLAYWRIGHT_BROWSERS_PATH"
  unset PLAYWRIGHT_SKIP_BROWSER_GC
}

# A finished install as Playwright and the deploy script leave one: the
# executable plus both completion markers.
seed_install() {
  local dir="$1" exe="${2:-bin}"
  mkdir -p "$BP/$dir/$(dirname "$exe")"
  : >"$BP/$dir/$exe"
  chmod +x "$BP/$dir/$exe"
  : >"$BP/$dir/INSTALLATION_COMPLETE"
  : >"$BP/$dir/DEPENDENCIES_VALIDATED"
}

seed_canonical_set() {
  local entry
  for entry in "${CANONICAL[@]}"; do
    # shellcheck disable=SC2086 # entry is "dir exe"
    seed_install $entry
  done
}

# The alias symlinks a deploy run made, as directory names.
aliases() {
  local link
  for link in "$BP"/chromium-* "$BP"/chromium_headless_shell-*; do
    [ -L "$link" ] && basename "$link"
  done
  return 0
}

# Print each browser directory Playwright's install-time cleanup keeps. For
# every .links file it reads <file content>/browsers.json, taking the content
# whole (a trailing newline breaks the path), and keeps <name>-<revision> for
# the first entry of each browser name, with dashes in the name turned to
# underscores, when INSTALLATION_COMPLETE resolves there. Everything else
# named like a browser directory is deleted. Source: playwright-core 1.64.1,
# Registry._traverseBrowserInstallations and _deleteStaleBrowsers.
kept_by_playwright_cleanup() {
  local link target dir
  for link in "$BP/.links"/*; do
    [ -f "$link" ] || continue
    target="$(
      cat "$link"
      printf x
    )"
    target="${target%x}"
    [ -f "$target/browsers.json" ] || continue
    jq -r 'reduce .browsers[] as $b ({}; if has($b.name) then . else . + {($b.name): $b.revision} end)
      | to_entries[] | "\(.key | gsub("-"; "_"))-\(.value)"' "$target/browsers.json" |
      while read -r dir; do
        [ -f "$BP/$dir/INSTALLATION_COMPLETE" ] && echo "$dir"
      done
  done | sort -u
}

@test "a deploy run registers every directory it provides with Playwright's cleanup" {
  seed_canonical_set
  run "$SCRIPT" "$VERSION"
  [ "$status" -eq 0 ]
  run aliases
  [ -n "$output" ]
  local kept dir entry
  kept="$(kept_by_playwright_cleanup)"
  for entry in "${CANONICAL[@]}"; do
    dir="${entry%% *}"
    grep -qx "$dir" <<<"$kept" || {
      echo "cleanup deletes $dir; kept: $kept" >&2
      return 1
    }
  done
  for dir in $(aliases); do
    grep -qx "$dir" <<<"$kept" || {
      echo "cleanup deletes alias $dir; kept: $kept" >&2
      return 1
    }
  done
}

@test "re-running the deploy keeps one client link per registered set" {
  seed_canonical_set
  run "$SCRIPT" "$VERSION"
  [ "$status" -eq 0 ]
  local first
  first="$(ls "$BP/.links")"
  [ -n "$first" ]
  run "$SCRIPT" "$VERSION"
  [ "$status" -eq 0 ]
  [ "$(ls "$BP/.links")" = "$first" ]
}

@test "--check passes on a provisioned and registered set" {
  seed_canonical_set
  run "$SCRIPT" "$VERSION"
  [ "$status" -eq 0 ]
  run "$SCRIPT" --check "$VERSION"
  [ "$status" -eq 0 ]
}

@test "--check names a missing browser and the aliases it leaves dangling" {
  seed_canonical_set
  run "$SCRIPT" "$VERSION"
  [ "$status" -eq 0 ]
  local dangling
  dangling="$(aliases | grep '^chromium-' | head -1)"
  [ -n "$dangling" ]
  rm -rf "${BP:?}/chromium-1234"
  run --separate-stderr "$SCRIPT" --check "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"chromium-1234"* ]]
  [[ "$stderr" == *"$dangling"* ]]
  [[ "$stderr" == *"playwright-browsers-deploy.sh $VERSION"* ]]
}

@test "--check reports a set no client link registers, and changes nothing" {
  seed_canonical_set
  run "$SCRIPT" "$VERSION"
  [ "$status" -eq 0 ]
  rm -f "$BP"/.links/*
  local before
  before="$(find "$BP" | sort)"
  run --separate-stderr "$SCRIPT" --check "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *".links"* ]]
  [ "$(find "$BP" | sort)" = "$before" ]
}

@test "--check on a host with no provisioned cache fails without creating one" {
  run --separate-stderr "$SCRIPT" --check "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"chromium-1234"* ]]
  [ ! -e "$BP" ]
}

@test "an unknown flag is a usage error" {
  run --separate-stderr "$SCRIPT" --frobnicate
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage:"* ]]
}

@test "a real Playwright install of another version keeps the registered set" {
  [ -n "${PLAYWRIGHT_CORE_DIR:-}" ] ||
    skip "set PLAYWRIGHT_CORE_DIR to a playwright-core package directory to run its install here"
  command -v node >/dev/null || skip "node is not on PATH"
  seed_canonical_set
  run "$SCRIPT" "$VERSION"
  [ "$status" -eq 0 ]
  local wanted
  wanted="$(aliases)"
  # The other version's own browsers, already finished, so its install
  # downloads nothing and only its link write and cleanup act on the sandbox.
  local name rev
  while read -r name rev; do
    seed_install "${name//-/_}-$rev"
  done < <(jq -r '.browsers[] | select(.name == "chromium" or .name == "chromium-headless-shell" or .name == "ffmpeg")
    | "\(.name) \(.revision)"' "$PLAYWRIGHT_CORE_DIR/browsers.json")
  run timeout 120 node "$PLAYWRIGHT_CORE_DIR/cli.js" install chromium
  echo "$output"
  [ "$status" -eq 0 ]
  local entry dir
  for entry in "${CANONICAL[@]}"; do
    dir="${entry%% *}"
    [ -f "$BP/$dir/INSTALLATION_COMPLETE" ] || {
      echo "the install deleted $dir" >&2
      return 1
    }
  done
  for dir in $wanted; do
    [ -L "$BP/$dir" ] || {
      echo "the install deleted alias $dir" >&2
      return 1
    }
  done
}
