# shellcheck shell=bash
# What a push delivers, derived from the ref-update lines git hands pre-push.
#
# Git writes one line per ref on the hook's stdin,
# `<local ref> <local sha> <remote ref> <remote sha>`, with the all-zero sha
# standing in for a side that does not exist: local for a delete, remote for
# a ref the remote has never seen. The shape of the command says nothing about
# content (a delete, an up-to-date push, a tag on a pushed commit, and a
# history rewrite that kept the tree all deliver nothing), so the gate decides
# from the delivered paths rather than from the line shape.
#
# Sourced by .githooks/pre-push; every function reads its ref lines on stdin.

PUSH_SCOPE_ZERO_SHA=0000000000000000000000000000000000000000

# A ref the remote has never seen is compared against the forever-branches,
# whose content has already been through CI.
PUSH_SCOPE_BASES=(origin/dev origin/main)

_push_scope_base() {
  local ref
  for ref in "${PUSH_SCOPE_BASES[@]}"; do
    git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 || continue
    git merge-base "$1" "$ref" 2>/dev/null && return 0
  done
  return 1
}

# push_delivered_files: print the paths whose content this push adds to the
# remote, one per line, each once.
#
# Exit 0 with no output when nothing is delivered: every line is a delete,
# stdin is empty (git runs the hook even when everything is up to date), or
# every pushed tree is already on the remote side.
# Exit 2 when the scope cannot be known: the remote-side object is not in this
# repository (the remote moved since the last fetch), or a new ref shares no
# history with any base. The caller treats unknown as "run everything".
push_delivered_files() {
  local local_ref local_sha remote_ref remote_sha base
  local files=''
  # shellcheck disable=SC2034 # ref names are positional; only the shas matter
  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "$local_sha" ] || continue
    [ "$local_sha" != "$PUSH_SCOPE_ZERO_SHA" ] || continue
    if [ "$remote_sha" = "$PUSH_SCOPE_ZERO_SHA" ]; then
      base=$(_push_scope_base "$local_sha") || return 2
    else
      git cat-file -e "$remote_sha^{commit}" 2>/dev/null || return 2
      base=$remote_sha
    fi
    files+=$(git diff --name-only "$base" "$local_sha")$'\n'
  done
  printf '%s' "$files" | sed '/^$/d' | sort -u
}

# push_files_gate_relevant: exit 0 when at least one path on stdin is read by
# a gate. Markdown is the one kind none of them reads: lint-shell and
# lint-workflows own fixed target lists that exclude it, and no bats test
# asserts on documentation.
push_files_gate_relevant() {
  grep -qvE '\.md$'
}
