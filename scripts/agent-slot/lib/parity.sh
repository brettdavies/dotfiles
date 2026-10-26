# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Setting a fresh clone up like the repo's prime checkout. The order matters: git-crypt unlocks the tree before any
# hook path is set, so no hook runs against ciphertext, and a clone that stays locked is refused rather than handed
# out, because it would commit plaintext into encrypted paths.

PARITY_BASE=
PARITY_MISSING_SIBLINGS=()

# Usage: parity_checkout_base <slot>; checks out dev when origin has it, else origin's default branch.
parity_checkout_base() {
  local slot=$1 head
  if git -C "$slot" rev-parse --verify -q refs/remotes/origin/dev >/dev/null; then
    PARITY_BASE=dev
  else
    head=$(git -C "$slot" symbolic-ref -q --short refs/remotes/origin/HEAD || true)
    PARITY_BASE=${head#origin/}
  fi
  [[ -n $PARITY_BASE ]] || PARITY_BASE=$(git -C "$slot" symbolic-ref --short HEAD)
  if [[ $(git -C "$slot" symbolic-ref --short HEAD) != "$PARITY_BASE" ]]; then
    git -C "$slot" checkout -q -B "$PARITY_BASE" "origin/$PARITY_BASE"
  fi
}

# Usage: parity_git_crypt <slot>
parity_git_crypt() {
  local slot=$1 out file
  git -C "$slot" grep -q -e 'filter=git-crypt' -- '.gitattributes' '**/.gitattributes' 2>/dev/null || return 0
  if [[ -z $AS_GIT_CRYPT ]]; then
    contract_fail git-crypt-locked "the repo uses git-crypt, and git-crypt is not installed on this server" \
      --value git-crypt --command "brew install git-crypt" --side-effects none
  fi
  if [[ ! -r $AS_GIT_CRYPT_KEY ]]; then
    contract_fail git-crypt-locked "the repo uses git-crypt, and there is no key at $AS_GIT_CRYPT_KEY" \
      --value "$AS_GIT_CRYPT_KEY" --command "agent-slot doctor" --side-effects none
  fi
  if ! bounded out git-crypt 120 /usr/bin/env -C "$slot" "$AS_GIT_CRYPT" unlock "$AS_GIT_CRYPT_KEY"; then
    contract_fail git-crypt-locked "git-crypt unlock failed in the new clone" --value "$AS_GIT_CRYPT_KEY" \
      --command "agent-slot doctor" --side-effects none --log "$BOUNDED_LOG"
  fi
  if [[ -z $(git -C "$slot" config --local --get filter.git-crypt.smudge || true) ]]; then
    contract_fail git-crypt-locked "the new clone has no git-crypt filter configured after unlock" \
      --value "$slot" --command "agent-slot doctor" --side-effects none
  fi
  local attr value
  while IFS= read -r -d '' file && IFS= read -r -d '' attr && IFS= read -r -d '' value; do
    [[ $attr == filter && $value == git-crypt && -f $slot/$file ]] || continue
    if [[ $(head -c 10 "$slot/$file" | tr -d '\0') == GITCRYPT ]]; then
      contract_fail git-crypt-locked "$file is still encrypted after unlock" --value "$file" \
        --command "agent-slot doctor" --side-effects none
    fi
  done < <(git -C "$slot" ls-files -z | git -C "$slot" check-attr -z --stdin filter)
}

# Usage: parity_hooks <prime> <slot>
# The slot runs its own copy of the repo's hooks: a hooks path inside the prime becomes the same path relative to the
# slot, and hooks installed straight into the prime's .git/hooks are copied.
parity_hooks() {
  local prime=$1 slot=$2 path abs real prime_real hook
  path=$(git -C "$prime" config --local --get core.hooksPath || true)
  if [[ -z $path ]]; then
    for hook in "$prime"/.git/hooks/*; do
      [[ -f $hook && -x $hook && $hook != *.sample ]] || continue
      cp -p "$hook" "$slot/.git/hooks/"
    done
    return 0
  fi
  # shellcheck disable=SC2088 # a literal ~/ in git config is expanded here
  case $path in
    "~/"*) abs=$HOME/${path#"~/"} ;;
    /*) abs=$path ;;
    *) abs=$prime/$path ;;
  esac
  real=$(realpath -m "$abs")
  prime_real=$(realpath "$prime")
  if [[ $real != "$prime_real"/* ]]; then
    contract_fail hooks-path-outside-checkout \
      "the prime checkout's core.hooksPath points outside it, so a slot cannot run its own copy of the hooks" \
      --value "$path" --command "git -C $prime config core.hooksPath" --side-effects none
  fi
  git -C "$slot" config core.hooksPath "${real#"$prime_real"/}"
}

# Usage: parity_solutions <slot>
parity_solutions() {
  local slot=$1 link=$1/docs/solutions
  if [[ ! -d $AS_SOLUTIONS ]]; then
    contract_fail solutions-symlink-missing \
      "the docs/solutions symlink could not be created: the shared solutions repo is missing at $AS_SOLUTIONS" \
      --value "$AS_SOLUTIONS" --command "agent-slot doctor" --side-effects none
  fi
  if [[ -e $link && ! -L $link ]]; then
    contract_fail solutions-symlink-missing "docs/solutions exists in the repo as a real path, not a symlink" \
      --value "$link" --command "git -C $slot ls-files docs/solutions" --side-effects none
  fi
  mkdir -p "$slot/docs"
  ln -sfn "$AS_SOLUTIONS" "$link"
  [[ -d $link/ ]] || contract_fail solutions-symlink-missing "docs/solutions does not resolve" --value "$link" \
    --command "agent-slot doctor" --side-effects none
}

# Usage: parity_memory_dir <prime>
# Prints Claude's auto memory directory for the prime checkout. The project directory is found by what it holds, a
# transcript recorded with the prime as its working directory, rather than by re-deriving Claude's naming rule; the
# derived name is only the first candidate and the answer for a prime Claude has never run in.
parity_memory_dir() {
  local prime=$1 guess dir file n
  guess=$AS_CLAUDE_PROJECTS/${prime//[^A-Za-z0-9]/-}
  for dir in "$guess" "$AS_CLAUDE_PROJECTS"/*; do
    n=0
    for file in "$dir"/*.jsonl; do
      if [[ ! -f $file ]] || ((n++ >= 3)); then break; fi
      if head -n 20 "$file" | grep -qF "\"cwd\":\"$prime\""; then
        printf '%s/memory' "$dir"
        return
      fi
    done
  done
  printf '%s/memory' "$guess"
}

# Usage: parity_claude_settings <prime> <slot>
# Writes the slot's .claude/settings.local.json with two keys: the prime's auto memory directory, and the prime's
# permission rules with the prime's path rewritten to the slot's wherever it is not the start of a longer name. Copied, never linked: Claude rewrites the file in
# place.
parity_claude_settings() {
  local prime=$1 slot=$2 perms='null' file=$1/.claude/settings.local.json
  if [[ -r $file ]]; then
    perms=$(contract_json -c --arg p "$prime" --arg s "$slot" '
      def swap_string: split($p) as $parts
        | reduce range(1; $parts | length) as $i ($parts[0];
            . + (if $parts[$i] | test("^[A-Za-z0-9._-]") then $p else $s end) + $parts[$i]);
      def swap: if type == "object" then map_values(swap) elif type == "array" then map(swap)
        elif type == "string" then swap_string else . end;
      .permissions // null | swap' "$file")
  fi
  mkdir -p "$slot/.claude"
  contract_json -n --arg mem "$(parity_memory_dir "$prime")" --argjson perms "$perms" \
    '{autoMemoryDirectory: $mem} + (if $perms == null then {} else {permissions: $perms} end)' \
    >"$slot/.claude/settings.local.json"
}

# Tracked symlinks, NUL-separated.
_parity_tracked_symlinks() {
  local entry
  while IFS= read -r -d '' entry; do
    [[ ${entry%% *} == 120000 ]] && printf '%s\0' "${entry#*$'\t'}"
  done < <(git -C "$1" ls-files -s -z)
}

# Usage: parity_siblings <repo> <slot>
# Tracked symlinks such as VOICE.md -> ../meum-control/brand/VOICE.md resolve under ~/dev because the prime's siblings
# sit beside it. A link to each such sibling's prime checkout beside the numbered slots makes them resolve the same
# way. Sets PARITY_MISSING_SIBLINGS to the siblings with no prime checkout.
parity_siblings() {
  local repo=$1 slot=$2 repo_dir slot_real file target resolved sibling name path _
  local -A seen=()
  PARITY_MISSING_SIBLINGS=()
  repo_dir=$AS_ROOT_REAL/$repo
  slot_real=$(realpath "$slot")
  while IFS= read -r -d '' file; do
    target=$(readlink "$slot/$file") || continue
    [[ $target == ../* || $target == */../* ]] || continue
    resolved=$(realpath -m "$(dirname "$slot_real/$file")/$target")
    [[ $resolved == "$repo_dir"/* && $resolved != "$slot_real" && $resolved != "$slot_real"/* ]] || continue
    sibling=${resolved#"$repo_dir"/}
    sibling=${sibling%%/*}
    [[ -z ${seen[$sibling]:-} && ! $sibling =~ ^[0-9]+$ ]] || continue
    seen[$sibling]=1
    path=''
    while IFS=$'\t' read -r name path _; do
      [[ $name == "$sibling" ]] && break
      path=''
    done < <(repo_primes)
    if [[ -n $path ]]; then
      ln -sfn "$path" "$AS_ROOT/$repo/$sibling"
    else
      PARITY_MISSING_SIBLINGS+=("$sibling")
    fi
  done < <(_parity_tracked_symlinks "$slot")
}
