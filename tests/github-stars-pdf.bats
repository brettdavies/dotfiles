#!/usr/bin/env bats
# github-stars-pdf: convert allowlisted PDFs from the starred clones to markdown under STARS_DIR/_pdf-markdown, where
# qmd's stars collection indexes them. Real git against local fixtures, a stubbed converter, no network.
#
# Run: bats tests/github-stars-pdf.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
CMD="$REPO_ROOT/stow/local/dot-local/bin/github-stars-pdf"

setup() {
  [ "$(uname -s)" = "Linux" ] || skip "github-stars-pdf runs on the Linux server"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  printf '[user]\n\tname = t\n\temail = t@example.com\n[commit]\n\tgpgsign = false\n' >"$GIT_CONFIG_GLOBAL"
  export STARS_DIR="$BATS_TEST_TMPDIR/stars"
  OUT="$STARS_DIR/_pdf-markdown"
  export CONVERT_LOG="$BATS_TEST_TMPDIR/convert.log"
  export PDF_TO_MARKDOWN="$BATS_TEST_TMPDIR/convert"
  cat >"$PDF_TO_MARKDOWN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$CONVERT_LOG"
[ "${STUB_CONVERT_FAIL:-0}" = 1 ] && exit 0
name=$(basename "$1" .pdf)
mkdir -p "$2"
printf -- '---\ntitle: %s\n---\nconverted: %s\n' "$name" "$(cat "$1")" >"$2/$name.md"
EOF
  chmod +x "$PDF_TO_MARKDOWN"
  mkdir -p "$STARS_DIR"
}

# _clone_with <owner/repo> <path=content>...: a local clone holding the given committed files.
_clone_with() {
  local dir="$STARS_DIR/$1"
  shift
  git init -q "$dir"
  for kv in "$@"; do
    mkdir -p "$dir/$(dirname "${kv%%=*}")"
    printf '%s' "${kv#*=}" >"$dir/${kv%%=*}"
  done
  git -C "$dir" add -A && git -C "$dir" commit -qm init
}

@test "--help exits 0 and an unknown option is a usage error" {
  run "$CMD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: github-stars-pdf"* ]]
  run "$CMD" --bogus
  [ "$status" -eq 2 ]
}

@test "converts an allowlisted PDF to markdown beside the clones, never inside one" {
  _clone_with acme/papers "docs/Big Paper.pdf=PDF-ONE" README.md=hi
  run "$CMD" "acme/papers:docs/Big Paper.pdf"
  [ "$status" -eq 0 ]
  [ "$(sed -n 4p "$OUT/acme/papers/docs/Big Paper.md")" = "converted: PDF-ONE" ]
  [ -z "$(git -C "$STARS_DIR/acme/papers" status --porcelain)" ]
  run find "$OUT" -type f ! -name '*.md' ! -name .manifest
  [ -z "$output" ]
}

@test "an unchanged PDF is not converted again; a changed one is" {
  _clone_with acme/papers paper.pdf=V1
  "$CMD" acme/papers:paper.pdf
  "$CMD" acme/papers:paper.pdf
  [ "$(wc -l <"$CONVERT_LOG")" -eq 1 ]
  printf 'V2' >"$STARS_DIR/acme/papers/paper.pdf"
  git -C "$STARS_DIR/acme/papers" commit -qam v2
  run "$CMD" acme/papers:paper.pdf
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CONVERT_LOG")" -eq 2 ]
  [ "$(sed -n 4p "$OUT/acme/papers/paper.md")" = "converted: V2" ]
}

@test "a failed conversion keeps the previous markdown and fails the run, after the other entries" {
  _clone_with acme/papers paper.pdf=V1 other.pdf=O1
  "$CMD" acme/papers:paper.pdf
  printf 'V2' >"$STARS_DIR/acme/papers/paper.pdf"
  git -C "$STARS_DIR/acme/papers" commit -qam v2
  STUB_CONVERT_FAIL=1 run "$CMD" acme/papers:paper.pdf
  [ "$status" -eq 1 ]
  [ "$(sed -n 4p "$OUT/acme/papers/paper.md")" = "converted: V1" ]
  run "$CMD" acme/papers:paper.pdf acme/papers:other.pdf
  [ "$status" -eq 0 ]
  [ -f "$OUT/acme/papers/other.md" ]
}

@test "a repo that is not cloned or a path not in the repo is skipped with a warning" {
  _clone_with acme/papers paper.pdf=V1
  run "$CMD" acme/missing:x.pdf acme/papers:nope.pdf acme/papers:paper.pdf
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/missing"*"not cloned"* ]]
  [[ "$output" == *"acme/papers:nope.pdf"*"not in the repo"* ]]
  [ -f "$OUT/acme/papers/paper.md" ]
}

@test "markdown for entries no longer listed is removed" {
  _clone_with acme/papers a.pdf=A b.pdf=B
  "$CMD" acme/papers:a.pdf acme/papers:b.pdf
  run "$CMD" acme/papers:a.pdf
  [ "$status" -eq 0 ]
  [ -f "$OUT/acme/papers/a.md" ]
  [ ! -e "$OUT/acme/papers/b.md" ]
}

@test "fetches a PDF a partial clone left out, on demand" {
  local src="$BATS_TEST_TMPDIR/remote/acme/papers"
  git init -q "$src" && printf 'LAZY' >"$src/paper.pdf" && printf 'hi' >"$src/README.md"
  git -C "$src" add -A && git -C "$src" commit -qm init
  git -C "$src" config uploadpack.allowFilter true
  git -C "$src" config uploadpack.allowAnySHA1InWant true
  git clone -q --filter=blob:none --no-checkout "file://$src" "$STARS_DIR/acme/papers"
  printf '%s\n' '/*' '!*.pdf' | git -C "$STARS_DIR/acme/papers" sparse-checkout set --no-cone --stdin
  git -C "$STARS_DIR/acme/papers" checkout -q
  blob=$(git -C "$STARS_DIR/acme/papers" rev-parse HEAD:paper.pdf)
  run env GIT_NO_LAZY_FETCH=1 git -C "$STARS_DIR/acme/papers" cat-file -e "$blob"
  [ "$status" -ne 0 ]
  run "$CMD" acme/papers:paper.pdf
  [ "$status" -eq 0 ]
  [ "$(sed -n 4p "$OUT/acme/papers/paper.md")" = "converted: LAZY" ]
  [ ! -e "$STARS_DIR/acme/papers/paper.pdf" ]
}

@test "the built-in allowlist names each source as owner/repo:path.pdf" {
  run bash -c 'source "$1" && printf "%s\n" "${PDF_SOURCES[@]}"' _ "$CMD"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -ge 12 ]
  run grep -cvE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:.+\.pdf$' <<<"$output"
  [ "$output" = "0" ]
}
