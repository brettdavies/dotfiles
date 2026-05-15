# shellcheck shell=bash
# GitHub PR line comments
gh-pr-comments() {
  gh api "repos/$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')/pulls/$1/comments" \
    --jq '.[] | {author: .user.login, body: .body, path: .path, line: .line, position: .position}'
}
