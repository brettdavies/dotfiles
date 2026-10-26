# shellcheck shell=bash
# The git environment a hook inherits, and how to keep it from the tools a
# hook starts.
#
# Git exports GIT_DIR into hooks run from a linked worktree, and an absolute
# GIT_INDEX_FILE into pre-commit, pointing at the temporary index during
# `commit -a` and `commit <path>`. Either one outranks the cwd and `-C` a child
# tool gives its own git calls, so a test that builds a fixture repository, or
# a tool that refreshes a cache it keeps in git, works on this repository
# instead. The hook's own git calls start at the worktree root and need neither
# to find the repository; pre-commit's staged-path lookup needs the temporary
# index, so that hook keeps the variables and strips them per child.
#
# Sourced by .githooks/pre-commit and .githooks/pre-push.

git_env_clear() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE
}

# git_env_isolated <command>...: run the command in a subshell without them.
git_env_isolated() {
  (
    git_env_clear
    "$@"
  )
}
