---
title: "refactor: repo infrastructure cleanup (todos 010-015)"
type: refactor
status: completed
date: 2026-02-18
---

# refactor: repo infrastructure cleanup (todos 010-015)

Six P3 review findings from prior code reviews. All are small, independent changes to repo infrastructure: PR template,
rulesets, git hooks, and conventions.

## Resolution / Post-ship notes (audited 2026-05-02)

This grab-bag landed unevenly. Closing out as `completed` with per-item disposition rather than tracking it as `active`
indefinitely:

| Item                                       | Status          | Notes                                                                                                                                                                                                                   |
| ------------------------------------------ | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 010 Simplify PR template                   | **Superseded**  | Decision reversed. The template is now deliberately elaborate (149 lines) and is the cascade source-of-truth referenced by global `~/.claude/CLAUDE.md` ("Pull Requests" section). Shipped under PR #35 / `2026.04.15`. |
| 011 Rulesets README drift warning          | **Not shipped** | No `.github/rulesets/README.md` exists. Lower priority than expected — the JSON exports are point-in-time references and the team is one person; drift is self-evident. Reopen as a fresh todo if it ever bites.        |
| 012 Extract `.githooks/lib.sh`             | **Not shipped** | The 9-line duplication between `post-checkout` and `post-merge` remains. ROI judged too low; fewer than 20 lines and the indirection cost (sourcing across hooks under `core.hooksPath`) outweighs the dedup.           |
| 013 Document `--no-verify` bypass          | **Partial**     | `post-checkout` has a bypass comment; `pre-commit` does not, and README has no mention. Not blocking.                                                                                                                   |
| 014 Add `markdownlint-cli2` to Brewfile    | **Shipped**     | `brew "markdownlint-cli2"` present in `stow/brew/Brewfile`.                                                                                                                                                             |
| 015 Standardize error prefixes (UPPERCASE) | **Shipped**     | `.githooks/pre-commit` uses `ERROR:` prefixes.                                                                                                                                                                          |

If/when items 011-013 re-surface they should be filed as new, single-item plans rather than revived from this stale
grab-bag.

## Implementation Checklist

### 010: Simplify PR template

`.github/pull_request_template.md` is 118 lines with sections for team review, testing metrics, stakeholder analysis,
and multi-reviewer workflows. This is a solo dotfiles repo — the `/workflows:work` command generates detailed PR
descriptions anyway.

**Replace with:**

```markdown
## Summary

-

## Test plan

-
```

- [ ] Replace `.github/pull_request_template.md` with minimal template (under 15 lines)

### 011: Add drift warning to ruleset JSON exports

`.github/rulesets/protect-main.json` and `protect-development.json` are static exports of GitHub rulesets managed
through the UI. They're not consumed by automation and will drift.

- [ ] Add `.github/rulesets/README.md` explaining these are point-in-time exports for reference
- [ ] Note the date of last export and how to re-export (`gh api repos/OWNER/REPO/rulesets`)

### 012: Extract shared git-crypt unlock logic from hooks

`.githooks/post-checkout:7-15` and `.githooks/post-merge:7-15` contain identical git-crypt unlock + sentinel check
blocks (9 lines each). Only the LFS chain command differs.

- [ ] Create `.githooks/lib.sh` with `try_git_crypt_unlock()` function
- [ ] Source `lib.sh` from both `post-checkout` and `post-merge`
- [ ] Verify LFS chaining still works for both hooks
- [ ] Verify git-crypt auto-unlock works after checkout and merge

### 013: Document --no-verify bypass in pre-commit and README

`.githooks/post-checkout:3` has a bypass comment but `.githooks/pre-commit` does not. README doesn't mention
`--no-verify` anywhere.

- [ ] Add bypass comment to `.githooks/pre-commit` header: `# Bypass: git commit --no-verify`
- [ ] Add one-line note to README.md in the Git Hooks section: `Bypass with --no-verify for emergency fixes.`

### 014: Add markdownlint-cli2 to Brewfile

`stow/claude/dot-claude/auto-format.sh` invokes `markdownlint-cli2` directly (not via `bunx`). The binary is installed
via Homebrew but not listed in `stow/brew/Brewfile` — would fail on fresh machines.

- [ ] Add `brew "markdownlint-cli2"` to `stow/brew/Brewfile`

### 015: Standardize error message prefixes

`scripts/stow-deploy` uses UPPERCASE prefixes (`FATAL:`, `ERROR:`, `WARNING:`) consistently to stderr.
`.githooks/pre-commit` uses lowercase (`error:`). Standardize on UPPERCASE to match the larger, more-established script.

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
