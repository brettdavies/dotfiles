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
if [ "$1" = "clone" ]; then
  target="${*: -1}"
  mkdir -p "$target/.git" "$target/node_modules/dep"
  printf 'readme\n' >"$target/README.md"
  head -c 4096 /dev/zero >"$target/node_modules/dep/index.js"
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

@test "clone pass clones new stars and strips build output" {
  _starred acme/new
  _stars --clone-only -j 1
  [ "$status" -eq 0 ]
  [ -d "$STARS_DIR/acme/new/.git" ]
  [ -f "$STARS_DIR/acme/new/README.md" ]
  [ ! -e "$STARS_DIR/acme/new/node_modules" ]
  grep -q '^clone --depth 1 --single-branch --no-tags https://x-access-token@github.com/acme/new.git ' "$GIT_LOG"
  grep -q '"cloned": 1,' "$STARS_DIR/.github-stars-stats.json"
}

@test "parallel workers clone every new star" {
  _starred acme/one acme/two acme/three
  _stars --clone-only -j 3
  [ "$status" -eq 0 ]
  for repo in acme/one acme/two acme/three; do
    [ -d "$STARS_DIR/$repo/.git" ] || { echo "missing $repo"; return 1; }
    [ ! -e "$STARS_DIR/$repo/node_modules" ] || { echo "uncleaned $repo"; return 1; }
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
