# shellcheck shell=bash
# The commit message and PR body for a pin bump, following .github/pull_request_template.md section by section.

# Usage: yazi_pins_messages <work-dir> <changes>
# Writes <work-dir>/commit-msg and <work-dir>/pr-body. <changes> is "use old-rev|old-hash -> rev hash; " entries.
yazi_pins_messages() {
  local dir=$1 changes=$2 ver=${YAZI_VERSION:-unknown} list entry
  list=''
  while IFS= read -r entry; do
    entry=${entry#"${entry%%[![:space:]]*}"}
    [ -n "$entry" ] || continue
    list+="- \`${entry%% *}\`: $(sed -E 's/^[^ ]+ ([^|]+)\|[^ ]* -> ([^ ]+) .*/\1 -> \2/' <<<"$entry")"$'\n'
  done < <(tr ';' '\n' <<<"$changes")
  printf '%s\n\n%s\n\n%s' "fix(yazi): pin plugins for yazi $ver" \
    "Homebrew upgraded yazi to $ver. The pins below move to each upstream repo's newest commit that reached its default branch at least seven days ago, and yazi $ver ran them with no failed fetcher." \
    "$list" >"$dir/commit-msg"
  cat >"$dir/pr-body" <<EOF
## Summary

Homebrew upgraded yazi to $ver on the Linux server. The daily brew job (\`scripts/upgrade/yazi-pins.sh\`) moved the pins in \`stow/yazi/dot-config/yazi/package.toml\` to each upstream repo's newest commit that reached its default branch at least seven days ago, by GitHub's push time, and recorded the hashes \`ya pkg install\` computed for them.

$list
## Changelog

### Fixed

- Fix yazi plugins after Homebrew upgraded yazi to $ver, by pinning them to upstream revisions built for it.

## Type of Change

- [ ] \`feat\`: New feature (non-breaking change which adds functionality)
- [x] \`fix\`: Bug fix (non-breaking change which fixes an issue)
- [ ] \`refactor\`: Code refactoring (no functional changes)
- [ ] \`perf\`: Performance improvement
- [ ] \`docs\`: Documentation update
- [ ] \`test\`: Adding or updating tests
- [ ] \`chore\`: Maintenance tasks (dependencies, config, etc.)
- [ ] \`ci\`: CI/CD configuration changes
- [ ] \`style\`: Code style/formatting changes
- [ ] \`build\`: Build system changes
- [ ] \`BREAKING CHANGE\`: Breaking API change (requires major version bump)

## Related Issues/Stories

- Story: n/a
- Issue: n/a
- Architecture: n/a
- Related PRs: None.

## Testing

- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [x] Manual testing completed
- [ ] All tests passing

**Test Summary:**

- Unit tests: n/a
- Integration tests: yazi $ver ran these pins in a private tmux server over a git repo: the git sign rendered beside an untracked file, no fetcher stayed pending, and the task view held no failed task.
- Coverage: n/a

## Files Modified

**Modified:**

- \`$PKG_PATH\`

**Created:**

- None.

**Renamed:**

- None.

**Deleted:**

- None.

## Breaking Changes

- [x] No breaking changes
- [ ] Breaking changes described below:

## Deployment Notes

- [ ] No special deployment steps required
- [x] Deployment steps documented below:

The brew job fast-forwards the Linux server's checkout after this merges when it can, and every host's next daily brew run installs the new pins. To install them at once: \`git -C ~/dotfiles pull --ff-only && ya pkg install\`.

## Checklist

- [x] Code follows project conventions and style guidelines
- [x] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
- [x] Self-review of code completed
- [ ] Tests added/updated and passing
- [x] No new warnings or errors introduced
- [x] Changes are backward compatible (or breaking changes documented)
EOF
}
