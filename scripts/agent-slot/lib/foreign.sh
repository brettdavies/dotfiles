# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Foreign heads: a slot's head from a repository that is neither origin's nor owned by a trusted owner. Slot paths are
# trusted in Claude ahead of time and Claude runs in bypass permissions mode, so what a checkout tracks would otherwise
# run as this account before anyone reads it. A slot on a foreign head loads no Claude settings from the tree
# (SESSIONS_FOREIGN_ARGS), keeps the tree's Claude config off disk, runs no git hooks, and skips each setup step that
# acts on what the head tracks.
#
# Origin's own heads are not foreign, whoever owns origin: the operator chose them by trusting the prime. An owner that
# cannot be determined is foreign, so the decision fails closed.

# Usage: foreign_url <url>; true unless the URL is origin's repo or a GitHub repo whose owner is in AS_TRUSTED_OWNERS. An
# empty URL, which is how a head whose repository is gone reaches here, and a URL that is not GitHub's are foreign.
foreign_url() {
  local slug trusted
  local -a owners
  [[ -z $1 || $1 != "$REPO_ORIGIN" ]] || return 1
  slug=$(head_github_slug "$1")
  [[ -n $slug ]] || return 0
  [[ $slug != "$(head_github_slug "$REPO_ORIGIN")" ]] || return 1
  read -ra owners <<<"${AS_TRUSTED_OWNERS,,}"
  for trusted in "${owners[@]}"; do
    [[ ${slug%%/*} != "$trusted" ]] || return 1
  done
  return 0
}

# Usage: foreign_fields <url>...; prints the JSON object a slot's seed merges: {head_foreign: true, head_owner} for the
# first foreign URL, with a null owner when it names none, else {}.
foreign_fields() {
  local url slug
  for url in "$@"; do
    foreign_url "$url" || continue
    slug=$(head_github_slug "$url")
    contract_json -n -c --arg owner "${slug%%/*}" \
      '{head_foreign: true, head_owner: (if $owner == "" then null else $owner end)}'
    return
  done
  printf '{}'
}

# The sparse patterns that leave Claude's config out of a foreign head's tree, at any depth. Claude's flags cover only the
# Claude the slot starts: skills shell out to `claude -p`, and a person can type `claude` in any of the slot's panes.
# A sparse checkout survives git checkout, reset, and stash, and leaves the files readable with git show and intact in
# what the agent pushes.
FOREIGN_SPARSE=('/*' '!.claude/' '!.mcp.json' '!CLAUDE.md' '!CLAUDE.local.md')

# Usage: foreign_prepare <slot>; runs before the head is checked out. Checking out an LFS pointer calls the server the
# head's own .lfsconfig names, and a server that never answers holds the slot's setup for as long as the checkout's
# bound, so pointers stay pointers for the slot's whole life.
foreign_prepare() {
  git -C "$1" config filter.lfs.smudge 'git-lfs smudge --skip -- %f'
  git -C "$1" config filter.lfs.process 'git-lfs filter-process --skip'
  git -C "$1" sparse-checkout set --no-cone "${FOREIGN_SPARSE[@]}"
}

# Usage: foreign_parity <repo> <n> <slot>; the setup a foreign head gets in place of the full parity steps. It leaves out
# core.hooksPath and hook copies, which would run the head's hooks or hooks that call into its tree; the prime's Claude
# settings, which Claude would not load here, and whose auto memory a slot on an unreviewed head should not share; and
# the repo-recon and sibling links, whose paths and targets the head's tree decides. git-crypt follows the base branch.
foreign_parity() {
  local repo=$1 n=$2 slot=$3
  parity_git_crypt "$slot" "refs/remotes/origin/$PARITY_BASE"
  parity_solutions "$repo" "$n" "$slot"
}
