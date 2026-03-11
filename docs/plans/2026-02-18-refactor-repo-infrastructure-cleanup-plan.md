---
title: "refactor: repo infrastructure cleanup (todos 010-015)"
type: refactor
status: active
date: 2026-02-18
---

# refactor: repo infrastructure cleanup (todos 010-015)

Six P3 review findings from prior code reviews. All are small, independent changes to
repo infrastructure: PR template, rulesets, git hooks, and conventions.

## Implementation Checklist

### 010: Simplify PR template

`.github/pull_request_template.md` is 118 lines with sections for team review, testing
metrics, stakeholder analysis, and multi-reviewer workflows. This is a solo dotfiles repo —
the `/workflows:work` command generates detailed PR descriptions anyway.

**Replace with:**

```markdown
## Summary

-

## Test plan

-
```

- [ ] Replace `.github/pull_request_template.md` with minimal template (under 15 lines)

### 011: Add drift warning to ruleset JSON exports

`.github/rulesets/protect-main.json` and `protect-development.json` are static exports of
GitHub rulesets managed through the UI. They're not consumed by automation and will drift.

- [ ] Add `.github/rulesets/README.md` explaining these are point-in-time exports for reference
- [ ] Note the date of last export and how to re-export (`gh api repos/OWNER/REPO/rulesets`)

### 012: Extract shared git-crypt unlock logic from hooks

`.githooks/post-checkout:7-15` and `.githooks/post-merge:7-15` contain identical git-crypt
unlock + sentinel check blocks (9 lines each). Only the LFS chain command differs.

- [ ] Create `.githooks/lib.sh` with `try_git_crypt_unlock()` function
- [ ] Source `lib.sh` from both `post-checkout` and `post-merge`
- [ ] Verify LFS chaining still works for both hooks
- [ ] Verify git-crypt auto-unlock works after checkout and merge

### 013: Document --no-verify bypass in pre-commit and README

`.githooks/post-checkout:3` has a bypass comment but `.githooks/pre-commit` does not.
README doesn't mention `--no-verify` anywhere.

- [ ] Add bypass comment to `.githooks/pre-commit` header:
      `# Bypass: git commit --no-verify`
- [ ] Add one-line note to README.md in the Git Hooks section:
      `Bypass with --no-verify for emergency fixes.`

### 014: Add markdownlint-cli2 to Brewfile

`stow/claude/dot-claude/auto-format.sh` invokes `markdownlint-cli2` directly (not via `bunx`).
The binary is installed via Homebrew but not listed in `stow/brew/Brewfile` — would fail on
fresh machines.

- [ ] Add `brew "markdownlint-cli2"` to `stow/brew/Brewfile`

### 015: Standardize error message prefixes

`scripts/stow-deploy` uses UPPERCASE prefixes (`FATAL:`, `ERROR:`, `WARNING:`) consistently
to stderr. `.githooks/pre-commit` uses lowercase (`error:`). Standardize on UPPERCASE to
match the larger, more-established script.

- [ ] Update `.githooks/pre-commit` error messages from `error:` to `ERROR:`
- [ ] Verify all hooks and scripts use UPPERCASE severity prefixes

## Acceptance Criteria

- [ ] PR template under 15 lines
- [ ] Ruleset exports have drift warning README
- [ ] Git-crypt unlock logic in exactly one place (`.githooks/lib.sh`)
- [ ] `--no-verify` documented in pre-commit header and README
- [ ] `markdownlint-cli2` in Brewfile
- [ ] All error messages use UPPERCASE prefixes to stderr

## References

- Todo files: `todos/010-015-pending-p3-*.md`
- Error convention baseline: `scripts/stow-deploy:33,41,49,53,67,81`
- Hook duplication: `.githooks/post-checkout:7-15` = `.githooks/post-merge:7-15`
- Learnings: `docs/solutions/deployment-issues/portable-binary-detection-sentinel-fix-and-auto-hooks.md`
