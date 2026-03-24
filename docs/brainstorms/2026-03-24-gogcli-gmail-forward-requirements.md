---
date: 2026-03-24
topic: gogcli-gmail-forward
---

# Gmail Forward Command for gogcli

## Problem Frame

gogcli has no `gmail forward` command. Forwarding an email with attachments currently requires a 3-step manual
workaround: download attachments with `gmail attachment`, compose a new email with `gmail send --attach`, and send. This
is especially painful for agent-driven workflows (e.g., forwarding receipts to Expensify) and interactive CLI use where
forwarding should be a single command.

An open issue ([#166](https://github.com/steipete/gogcli/issues/166)) and stale PR
([#167](https://github.com/steipete/gogcli/pull/167)) exist upstream. PR #167 has merge conflicts, bundles unrelated
changes, and lacks `--attach` for additional local files. We will submit a clean, focused PR referencing #166.

## Requirements

- R1. Add `gog gmail forward <messageId>` command in the "Write" group alongside `send`
- R2. Use flag-based recipients (`--to`, `--cc`, `--bcc`) consistent with `gmail send` pattern; messageId is a
  positional arg
- R3. Forward all original attachments by default (fetched via Gmail API attachment endpoints)
- R4. `--no-attachments` flag to strip original attachments from the forwarded message
- R5. `--attach` (repeatable) flag to add additional local files alongside forwarded attachments in the same message
- R6. Prepend "Fwd: " to subject (skip if already prefixed); `--subject` flag to override
- R7. Optional body preface via `--body` / `--body-file` inserted before forwarded content
- R8. Include forwarded message header block (From, Date, Subject, To, Cc) in both plain text and HTML variants
- R9. `--from` flag for send-as alias support, consistent with `gmail send`
- R10. `--json` / `--plain` output via existing `writeSendResults()` for agent consumption
- R11. MIME construction must use the existing `buildRFC822()` pipeline; no duplicate MIME logic
- R12. From-address resolution logic must be shared between `send` and `forward`; no copy-paste duplication
- R13. Unit tests covering: default forward with attachments, HTML-only messages, custom subject, CC/BCC, no-attachments
  flag, extra local attachments via --attach

## Success Criteria

- `gog gmail forward <id> --to user@example.com` forwards with all attachments in a single command
- `gog gmail forward <id> --to user@example.com --no-attachments --attach local.pdf` forwards text only with a local
  file
- Agent workflows (expensify-forward-receipt skill) can replace the 3-step workaround with one command
- `make ci` passes (lint, test, fmt)
- PR is focused (forward command only, no unrelated changes)

## Scope Boundaries

- No interactive message picker (use `gmail search` + pipe to get message IDs)
- No draft-forward (save forward as draft) in this PR
- No thread-forward (forwarding an entire thread) in this PR
- No open-tracking integration for forwards in this PR
- Thread preservation (setting ThreadID on the sent message) is deferred — Gmail may auto-thread by subject/references

## Key Decisions

- **Flags over positional for recipients**: `--to` not positional `<to>`, matching `gmail send` pattern. MessageId stays
  positional since it's a resource reference (like `gmail get <id>`)
- **Forward attachments by default**: Matches user expectation from email clients. Opt-out via `--no-attachments`
- **Fresh implementation over landing PR #167**: PR #167 has merge conflicts, unrelated changes (docs, drive), and lacks
  `--attach`. A clean PR is faster and more maintainable
- **Reference PR #167 in our PR**: Credit the design work, link the issue

## Dependencies / Assumptions

- Upstream repo (steipete/gogcli) accepts external PRs (confirmed by existing merged community PRs)
- We will fork steipete/gogcli to submit the PR
- AGENTS.md guidelines apply: Conventional Commits, `make ci` gate, stdlib `testing` + `httptest`, parseable stdout
  (`--json`/`--plain`) with hints to stderr
- PR description must summarize scope, note testing performed, and list new user-facing flags (per AGENTS.md)
- Maintainer handles CHANGELOG.md credit on landing; PR should make this easy by clearly listing new flags and
  referencing #166

## Outstanding Questions

### Deferred to Planning

- Affects R12 / Technical: Should `resolveSendFrom()` live in `gmail_helpers.go` (PR #167's approach) or
  `gmail_compose.go` (where the existing `resolveComposeFrom()` lives)?
- Affects R3 / Technical: Should attachment fetching be parallelized for messages with many attachments, or is
  sequential sufficient for typical use?
- Affects R11 / Needs research: Does `buildRFC822()` need modification to accept pre-loaded `[]byte` attachment data
  (from API) alongside file-path-based attachments, or does the existing `mailAttachment` struct already support both?

## Next Steps

-> `/ce:plan` for structured implementation planning
