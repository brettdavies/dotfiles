#!/usr/bin/env bats
# github-stars: clone and update the user's starred GitHub repos under STARS_DIR. Every case runs offline against
# stubbed `gh` and `git` on PATH and a sandbox STARS_DIR.
#
# Run: bats tests/github-stars.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
STARS="$REPO_ROOT/stow/local/dot-local/bin/github-stars"

setup() {
  [ "$(uname -s)" = "Linux" ] || skip "github-stars relies on GNU du, numfmt and date"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export STARS_DIR="$BATS_TEST_TMPDIR/stars"
  export STARRED_LIST="$BATS_TEST_TMPDIR/starred"
  export GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export STUB_GH_AUTH=0
  mkdir -p "$STUBS" "$STARS_DIR"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
  cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit "$STUB_GH_AUTH" ;;
  "auth token") echo stub-token ;;
  "api users/"*) cat "$STARRED_LIST" ;;
  *) exit 64 ;;
esac
EOF
  cat >"$STUBS/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_LOG"
printf 'auth-config:%s\n' "${GIT_CONFIG_KEY_0:-none}" >>"$GIT_LOG"
[[ "$*" == *"--get remote.origin.promisor"* ]] && echo true
if [ "$1" = "clone" ]; then
  target="${*: -1}"
  mkdir -p "$target/.git"
  printf 'readme\n' >"$target/README.md"
fi
EOF
  chmod +x "$STUBS"/*
}

_stars() {
  run env PATH="$STUBS:$PATH" "$STARS" "$@"
}

_starred() {
  printf '%s\n' "$@" >"$STARRED_LIST"
}

# Swap the git stub for one that runs the real git, with every github.com HTTPS URL pointed at a local bare fixture.
_use_real_git() {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  # Remote URLs git uses on its own (lazy fetches, the restored SSH origin) resolve to the fixtures too.
  printf '[url "file://%s/"]\n\tinsteadOf = git@github.com:\n' "$FIXTURES" >"$GIT_CONFIG_GLOBAL"
  local real_git
  real_git=$(command -v git)
  cat >"$STUBS/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = clone ] && [ -n "\${STUB_FAIL_CLONE:-}" ]; then exit 1; fi
args=()
for a in "\$@"; do
  [[ "\$a" =~ ^https://([^@/]+@)?github\.com/(.+)\$ ]] && a="file://$FIXTURES/\${BASH_REMATCH[2]}"
  args+=("\$a")
done
exec "$real_git" "\${args[@]}"
EOF
}

# _fixture_commit <owner/repo> <path=content>...: commit the files to the fixture's work tree and publish it as the
# bare repo the stars URLs resolve to.
_fixture_commit() {
  local name="$1" work="$BATS_TEST_TMPDIR/work/$1" spec
  shift
  [ -d "$work" ] || git init -q -b main "$work"
  for spec in "$@"; do
    mkdir -p "$work/$(dirname "${spec%%=*}")"
    printf '%s\n' "${spec#*=}" >"$work/${spec%%=*}"
  done
  git -C "$work" -c core.excludesFile=/dev/null add -A
  git -C "$work" -c user.name=t -c user.email=t@example.com commit -q -m fixture
  if [ -d "$FIXTURES/$name.git" ]; then
    git -C "$work" push -q "$FIXTURES/$name.git" main
  else
    mkdir -p "$FIXTURES/$(dirname "$name")"
    git clone -q --bare "$work" "$FIXTURES/$name.git"
    git -C "$FIXTURES/$name.git" config uploadpack.allowFilter true
    git -C "$FIXTURES/$name.git" config uploadpack.allowAnySHA1InWant true
  fi
}

_real_repo() {
  _fixture_commit acme/real README.md=one src/main.go=main node_modules/dep/index.js=dep \
    src/node_modules/nested/index.js=nested pkg/mod.pyc=bytecode vendor/lib/lib.go=vendored build/build.sh=script \
    assets/logo.png=pngbytes img/photo.JPG=jpgbytes
}

_no_local_blob() {
  ! GIT_NO_LAZY_FETCH=1 git -C "$STARS_DIR/$1" cat-file -e "HEAD:$2" 2>/dev/null
}

_pack_kib() {
  git -C "$STARS_DIR/$1" count-objects -v | awk '/^size(-pack)?:/ { s += $2 } END { print s + 0 }'
}

_clean_tree() {
  run git -C "$STARS_DIR/$1" status --porcelain
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "dirty $1: $output"; return 1; }
}

_local_clone() {
  mkdir -p "$STARS_DIR/$1/.git"
}

@test "--help prints usage for the github-stars command and exits 0" {
  _stars --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: github-stars [OPTIONS]"* ]]
}

@test "an unknown option is a usage error" {
  _stars --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --bogus"* ]]
}

@test "stops when gh is not authenticated" {
  STUB_GH_AUTH=1 _stars -n
  [ "$status" -eq 1 ]
  [[ "$output" == *"not authenticated"* ]]
}

@test "dry run lists stars to clone and clones to update, skips the owner's repos, and runs no git" {
  _starred acme/kept acme/new BrettDavies/mine
  _local_clone acme/kept
  _stars -n -j 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would clone:"*"  - acme/new"* ]]
  [[ "$output" == *"Would update:"*"  - acme/kept"* ]]
  [[ "$output" != *"BrettDavies/mine"* ]]
  [ ! -e "$GIT_LOG" ]
  [ ! -e "$STARS_DIR/acme/new" ]
}

@test "clone pass clones new stars over HTTPS and records them" {
  _starred acme/new
  _stars --clone-only -j 1
  [ "$status" -eq 0 ]
  [ -d "$STARS_DIR/acme/new/.git" ]
  [ -f "$STARS_DIR/acme/new/README.md" ]
  grep -q '^clone .* https://x-access-token@github.com/acme/new.git ' "$GIT_LOG"
  grep -q '"cloned": 1,' "$STARS_DIR/.github-stars-stats.json"
}

@test "parallel workers clone every new star" {
  _starred acme/one acme/two acme/three
  _stars --clone-only -j 3
  [ "$status" -eq 0 ]
  for repo in acme/one acme/two acme/three; do
    [ -d "$STARS_DIR/$repo/.git" ] || { echo "missing $repo"; return 1; }
  done
  grep -q '"cloned": 3,' "$STARS_DIR/.github-stars-stats.json"
}

@test "update pass fetches and resets existing clones" {
  _starred acme/kept
  _local_clone acme/kept
  _stars --update-only -j 1
  [ "$status" -eq 0 ]
  grep -qx 'remote set-url origin https://x-access-token@github.com/acme/kept.git' "$GIT_LOG"
  grep -qx 'fetch --depth 1 origin' "$GIT_LOG"
  grep -qx 'reset --hard origin/HEAD' "$GIT_LOG"
  grep -q '"updated": 1,' "$STARS_DIR/.github-stars-stats.json"
}

@test "the gh token reaches git through its environment, never its arguments" {
  _starred acme/new acme/kept
  _local_clone acme/kept
  _stars -j 1
  [ "$status" -eq 0 ]
  run grep -c stub-token "$GIT_LOG"
  [ "$output" = "0" ]
  run grep -cvx 'auth-config:http.https://github.com/.extraheader' <(grep '^auth-config:' "$GIT_LOG")
  [ "$output" = "0" ]
}

@test "prune dry run names unstarred clones and deletes nothing" {
  _starred acme/kept
  _local_clone acme/kept
  _local_clone acme/gone
  _stars --prune -n -j 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would remove (unstarred): acme/gone"* ]]
  [ -d "$STARS_DIR/acme/gone/.git" ]
}

@test "prune removes unstarred clones and their empty owner directory" {
  _starred acme/kept
  _local_clone acme/kept
  _local_clone gone-owner/gone
  _stars --prune --update-only -j 1
  [ "$status" -eq 0 ]
  [ ! -e "$STARS_DIR/gone-owner" ]
  [ -d "$STARS_DIR/acme/kept/.git" ]
}

@test "a clone leaves out dependency and bytecode trees and keeps committed source" {
  _use_real_git
  _real_repo
  _fixture_commit RhetTbull/osxphotos tests/test-images/img.bin=pixels tests/keep.txt=keep
  _starred acme/real RhetTbull/osxphotos
  _stars --clone-only -j 2
  [ "$status" -eq 0 ]
  local repo="$STARS_DIR/acme/real"
  [ -f "$repo/README.md" ]
  [ -f "$repo/src/main.go" ]
  [ -f "$repo/vendor/lib/lib.go" ]
  [ -f "$repo/build/build.sh" ]
  [ ! -e "$repo/node_modules" ]
  [ ! -e "$repo/src/node_modules" ]
  [ ! -e "$repo/pkg/mod.pyc" ]
  [ -n "$(git -C "$repo" ls-files node_modules/dep/index.js)" ]
  [ ! -e "$repo/assets/logo.png" ]
  [ ! -e "$repo/img/photo.JPG" ]
  [ "$(git -C "$repo" config --get remote.origin.promisor)" = "true" ]
  _no_local_blob acme/real assets/logo.png
  _no_local_blob acme/real img/photo.JPG
  [ "$(git -C "$repo" show HEAD:assets/logo.png)" = "pngbytes" ]
  _clean_tree acme/real
  [ ! -e "$STARS_DIR/RhetTbull/osxphotos/tests/test-images" ]
  [ -f "$STARS_DIR/RhetTbull/osxphotos/tests/keep.txt" ]
  _clean_tree RhetTbull/osxphotos
}

@test "an update brings in new commits without restoring excluded trees" {
  _use_real_git
  _real_repo
  _starred acme/real
  _stars --clone-only -j 1
  _fixture_commit acme/real README.md=two node_modules/dep/new.js=dep2 vendor/lib/new.go=vendored2
  _stars --update-only -j 1
  [ "$status" -eq 0 ]
  local repo="$STARS_DIR/acme/real"
  [ "$(cat "$repo/README.md")" = "two" ]
  [ -f "$repo/vendor/lib/new.go" ]
  [ ! -e "$repo/node_modules" ]
  _clean_tree acme/real
  [ "$(git -C "$repo" config --get core.logAllRefUpdates)" = "false" ]
  [ "$(git -C "$repo" config --get gc.pruneExpire)" = "now" ]
  [ -z "$(git -C "$repo" reflog)" ]
  run git -C "$repo" rev-parse -q --verify ORIG_HEAD
  [ "$status" -ne 0 ]
}

@test "an update converts a full clone and restores committed source an earlier cleanup deleted" {
  _use_real_git
  _real_repo
  _starred acme/real
  mkdir -p "$STARS_DIR/acme"
  git clone -q "file://$FIXTURES/acme/real.git" "$STARS_DIR/acme/real"
  rm -rf "$STARS_DIR/acme/real/node_modules" "$STARS_DIR/acme/real/vendor" "$STARS_DIR/acme/real/build"
  _stars --update-only -j 1
  [ "$status" -eq 0 ]
  local repo="$STARS_DIR/acme/real"
  [ -f "$repo/vendor/lib/lib.go" ]
  [ -f "$repo/build/build.sh" ]
  [ ! -e "$repo/node_modules" ]
  [ ! -e "$repo/src/node_modules" ]
  _clean_tree acme/real
  [ "$(git -C "$repo" config --get remote.origin.promisor)" = "true" ]
  _no_local_blob acme/real assets/logo.png
  [ -z "$(ls -A "$STARS_DIR/.github-stars-tmp" 2>/dev/null)" ]
}

@test "a failed re-clone leaves the full clone in place and still updates it" {
  _use_real_git
  _real_repo
  _starred acme/real
  mkdir -p "$STARS_DIR/acme"
  git clone -q "file://$FIXTURES/acme/real.git" "$STARS_DIR/acme/real"
  rm -rf "$STARS_DIR/acme/real/vendor"
  _fixture_commit acme/real README.md=two
  STUB_FAIL_CLONE=1 _stars --update-only -j 1
  [ "$status" -eq 0 ]
  local repo="$STARS_DIR/acme/real"
  [ -z "$(git -C "$repo" config --get remote.origin.promisor)" ]
  [ "$(cat "$repo/README.md")" = "two" ]
  [ -f "$repo/vendor/lib/lib.go" ]
  [ -z "$(ls -A "$STARS_DIR/.github-stars-tmp" 2>/dev/null)" ]
}

@test "a clone that keeps changing keeps a bounded object store" {
  _use_real_git
  head -c 600000 /dev/urandom | base64 >"$BATS_TEST_TMPDIR/blob"
  _fixture_commit acme/busy README.md=busy "data/blob.txt=$(cat "$BATS_TEST_TMPDIR/blob")"
  _starred acme/busy
  _stars --clone-only -j 1
  local baseline
  baseline=$(_pack_kib acme/busy)
  for _ in 1 2 3 4 5; do
    head -c 600000 /dev/urandom | base64 >"$BATS_TEST_TMPDIR/blob"
    _fixture_commit acme/busy "data/blob.txt=$(cat "$BATS_TEST_TMPDIR/blob")"
    _stars --update-only -j 1
    [ "$status" -eq 0 ]
  done
  echo "baseline ${baseline} KiB, after 5 updates $(_pack_kib acme/busy) KiB"
  [ "$(_pack_kib acme/busy)" -le $((baseline * 5 / 2)) ]
  _clean_tree acme/busy
}

@test "sparse patterns combine the global exclusions with a repo's own overrides" {
  run bash -c 'source "$1" && _sparse_patterns TomerAberbach/profiler-md' _ "$STARS"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n!/examples/input\n'* ]]
  [[ "$output" == *$'\n!/examples/output'* ]]
  [[ "$output" == *$'\n!*.png\n'* ]]
  [[ "$output" == *$'\n!*.PNG\n'* ]]
  [[ "$output" == *$'\n!node_modules/\n'* ]]
  run bash -c 'source "$1" && _sparse_patterns acme/plain' _ "$STARS"
  [ "$status" -eq 0 ]
  [[ "$output" != *'!/'* ]]
}
