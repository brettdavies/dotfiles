---
title: "feat(gmail): add forward command with attachment support"
type: feat
status: completed
date: 2026-03-24
origin: docs/brainstorms/2026-03-24-gogcli-gmail-forward-requirements.md
---

# feat(gmail): add forward command with attachment support

## Overview

Add a `gog gmail forward <messageId>` command to gogcli that forwards an email with all attachments in a single command.
This closes [#166](https://github.com/steipete/gogcli/issues/166) and supersedes the stale
[PR #167](https://github.com/steipete/gogcli/pull/167).

## Problem Statement / Motivation

gogcli has no per-message forward command. The current workaround requires 3 manual steps: download attachments, compose
a new email, re-send. This is especially painful for agent-driven workflows (expensify-forward-receipt) and interactive
CLI use. (see origin: docs/brainstorms/2026-03-24-gogcli-gmail-forward-requirements.md)

## Proposed Solution

A dedicated `gmail forward` command that:

1. Fetches the original message via Gmail API
2. Extracts body and attachments from the MIME tree
3. Builds a new RFC 822 message with forwarded content + optional preface + combined attachments
4. Sends via `messages.send`

All building blocks exist in the codebase: `buildRFC822()`, `resolveComposeFrom()`, `collectAttachments()`,
`fetchAttachmentBytes()`, `findPartBody()`, `writeSendResults()`. The forward command composes them into a new flow
without modifying existing code.

### Command Interface

```text
gog gmail forward <messageId> --to <addr> [flags]

Flags:
  --to           Recipients (comma-separated, required)
  --cc           CC recipients (comma-separated)
  --bcc          BCC recipients (comma-separated)
  --subject      Override subject (default: "Fwd: <original>")
  --body         Body preface (plain text)
  --body-file    Body preface from file ('-' for stdin)
  --from         Send from verified send-as alias
  --attach       Additional local file (repeatable)
  --no-attachments  Strip original attachments
```

### Forward Message Layout

```text
[optional user preface]

---------- Forwarded message ----------
From: Original Sender <sender@example.com>
Date: Mon, 1 Jan 2024 10:00:00 -0800
Subject: Original Subject
To: original@example.com
Cc: cc@example.com

[original message body]
```

HTML variant uses `<br>` separators and `html.EscapeString()` for header values. Plain text preface is auto-escaped to
HTML when the original message has HTML content.

## Technical Considerations

### Architecture: Reuse Without Modification

The key insight (vs PR #167) is that **no existing files need modification** except `gmail.go` for command registration:

| Existing Helper | File | Used For |
|----------------|------|----------|
| `resolveComposeFrom()` | `gmail_compose.go:38` | From-address + send-as resolution |
| `listSendAs()` | `gmail_compose.go` | Pre-fetch send-as list |
| `resolveBodyInput()` | `gmail_body_input.go:11` | `--body` / `--body-file` resolution |
| `buildRFC822()` | `gmail_mime.go:44` | MIME message construction |
| `mailAttachment{Data}` | `gmail_mime.go:18` | Pre-loaded byte attachments (no temp files) |
| `writeSendResults()` | `gmail_send.go:366` | JSON/plain output |
| `findPartBody()` | `gmail_thread.go:397` | Extract text/plain or text/html from parts |
| `stripHTMLTags()` | `gmail_thread.go:39` | HTML -> plain text fallback |
| `headerValue()` | `gmail_thread_search_helpers.go:96` | Extract headers from MessagePart |
| `splitCSV()` | `csv.go:5` | Comma-split recipients |
| `collectAttachments()` | `gmail_attachments.go:176` | Extract attachment metadata from MIME tree |
| `fetchAttachmentBytes()` | `gmail_attachment.go:225` | Fetch attachment data by ID |
| `expandComposeAttachmentPaths()` | `gmail_compose.go:18` | Expand ~ in --attach paths |
| `attachmentsFromPaths()` | `gmail_compose.go:30` | Convert paths to mailAttachment |
| `normalizeGmailMessageID()` | `webid.go:51` | Normalize message ID format |
| `dryRunExit()` | `dryrun.go:15` | --dry-run support |

PR #167 created a new `resolveSendFrom()` and refactored `gmail_send.go`. Our approach: just call `resolveComposeFrom()`
which is already shared by `send` and `drafts`. Zero refactoring of existing code.

### Attachment Pipeline

```text
Original message
  -> collectAttachments() -> []attachmentInfo (metadata only)
  -> for each: fetchAttachmentBytes(messageID, attID) -> []byte
  -> mailAttachment{Filename, MIMEType, Data: bytes}

Local --attach files
  -> expandComposeAttachmentPaths() -> attachmentsFromPaths()
  -> mailAttachment{Path: filepath}

Combined -> buildRFC822(opts) -> raw RFC 822 bytes -> base64url -> messages.send
```

`buildRFC822()` already handles both `Data`-based and `Path`-based attachments (checks `len(a.Data) == 0` before falling
back to `os.ReadFile`). Forward must always set `Filename` on API-fetched attachments since `filepath.Base("")` returns
`"."`.

### Known Limitations (v1)

- **Inline images (CID-referenced parts):** Converted to regular attachments. CID references in HTML body will break.
  Follow-up issue to implement `multipart/related` with `Content-ID` preservation.
- **No total size pre-check:** Consistent with `gmail send`. Large messages fail at the API with a 400 error.
- **No `--body-html` for preface:** Plain text only, auto-escaped for HTML variant. Consistent with primary use case.
- **Thread preservation deferred:** Forwarded message creates a new thread. Gmail may auto-thread by subject/references.

### Edge Cases

| Case | Behavior |
|------|----------|
| HTML-only original (no text/plain) | `stripHTMLTags()` generates plain text fallback |
| No-body message (attachment-only) | Header block alone is sufficient |
| Subject already has "Fwd:" or "Fw:" | Skip prefix (case-insensitive) |
| Subject has "Re:" prefix | Prepend "Fwd:" (semantically distinct) |
| Empty subject | "Fwd: (no subject)" |
| Attachment fetch fails mid-download | Fail entirely, send nothing |
| `--no-attachments` + `--attach` | Strip originals, include only local files |

## Acceptance Criteria

- [ ] `gog gmail forward <id> --to user@example.com` forwards with all attachments
- [ ] `gog gmail forward <id> --to user@example.com --no-attachments` strips attachments
- [ ] `gog gmail forward <id> --to user@example.com --attach local.pdf` adds local file alongside originals
- [ ] `gog gmail forward <id> --to user@example.com --no-attachments --attach local.pdf` replaces attachments
- [ ] `gog gmail forward <id> --to user@example.com --subject "Custom"` overrides subject
- [ ] `gog gmail forward <id> --to user@example.com --body "FYI"` prepends preface
- [ ] `gog gmail forward <id> --to user@example.com --cc a@b.com --bcc c@d.com` handles CC/BCC
- [ ] `gog gmail forward <id> --to user@example.com --from alias@example.com` uses send-as alias
- [ ] `gog gmail forward <id> --to user@example.com --json` outputs JSON
- [ ] `gog gmail forward <id> --to user@example.com --dry-run` shows what would be sent
- [ ] `make ci` passes (fmt, lint, test)
- [ ] PR references #166, credits PR #167's design

## MVP

### `internal/cmd/gmail_forward.go`

```go
package cmd

import (
    "context"
    "encoding/base64"
    "fmt"
    "html"
    "strings"

    "google.golang.org/api/gmail/v1"

    "github.com/steipete/gogcli/internal/outfmt"
    "github.com/steipete/gogcli/internal/ui"
)

type GmailForwardCmd struct {
    MessageID     string   `arg:"" name:"messageId" help:"Message ID to forward"`
    To            string   `name:"to" help:"Recipients (comma-separated; required)"`
    Cc            string   `name:"cc" help:"CC recipients (comma-separated)"`
    Bcc           string   `name:"bcc" help:"BCC recipients (comma-separated)"`
    Subject       string   `name:"subject" help:"Override subject (default: Fwd: <original>)"`
    Body          string   `name:"body" help:"Body preface (plain text)"`
    BodyFile      string   `name:"body-file" help:"Body preface file ('-' for stdin)"`
    From          string   `name:"from" help:"Send from verified send-as alias"`
    Attach        []string `name:"attach" help:"Additional local file (repeatable)"`
    NoAttachments bool     `name:"no-attachments" help:"Strip original attachments"`
}

func (c *GmailForwardCmd) Run(ctx context.Context, flags *RootFlags) error {
    // 1. Validate inputs
    // 2. dryRunExit() if applicable
    // 3. requireGmailService()
    // 4. Fetch original message (format=full)
    // 5. resolveComposeFrom() for --from
    // 6. Resolve subject (forwardSubject)
    // 7. resolveBodyInput() for --body/--body-file
    // 8. buildForwardBodies() - preface + header block + original
    // 9. Collect attachments (unless --no-attachments)
    //    - collectAttachments() + fetchAttachmentBytes()
    //    - Merge with --attach local files
    // 10. buildRFC822()
    // 11. messages.send
    // 12. writeSendResults()
}

// forwardSubject prepends "Fwd: " unless already present.
func forwardSubject(original string) string { ... }

// forwardHeaderBlock builds the "---------- Forwarded message ----------" block.
func forwardHeaderPlain(p *gmail.MessagePart) string { ... }
func forwardHeaderHTML(p *gmail.MessagePart) string { ... }

// buildForwardBodies assembles plain + HTML bodies with preface and original content.
func buildForwardBodies(payload *gmail.MessagePart, prefacePlain string) (plain, htmlBody string) { ... }

// collectForwardAttachments fetches attachment bytes from the original message.
func collectForwardAttachments(ctx context.Context, svc *gmail.Service, messageID string, payload *gmail.MessagePart) ([]mailAttachment, error) { ... }
```

### `internal/cmd/gmail.go` (modification)

```go
// Add to GmailCmd struct in the "Write" group:
Forward GmailForwardCmd `cmd:"" name:"forward" group:"Write" help:"Forward a message"`
```

### `internal/cmd/gmail_forward_test.go`

```go
// Unit tests for forward helper functions:
// - TestForwardSubject (cases: empty, normal, already "Fwd:", "Fw:", "FWD:", "Re: Something")
// - TestForwardHeaderPlain / TestForwardHeaderHTML
// - TestBuildForwardBodies (plain-only, html-only, both, with preface, without preface)
// - TestCollectForwardAttachments (with mock parts)
```

### `internal/cmd/execute_gmail_forward_test.go`

```go
// Integration tests via Execute() with httptest mock server:
// 1. TestExecute_GmailForward_DefaultSubjectAndAttachments
//    - Mock: message with text/plain body + 1 attachment
//    - Verify: "Fwd: " subject, forwarded header block, attachment data in MIME
// 2. TestExecute_GmailForward_HTMLOnlyMessage
//    - Mock: message with only text/html body
//    - Verify: plain text fallback via stripHTMLTags, HTML preserved
// 3. TestExecute_GmailForward_CustomSubject
//    - Verify: --subject overrides default "Fwd: "
// 4. TestExecute_GmailForward_CcAndBcc
//    - Verify: Cc and Bcc headers in MIME
// 5. TestExecute_GmailForward_NoAttachments
//    - Verify: --no-attachments strips original attachments
// 6. TestExecute_GmailForward_ExtraLocalAttachments
//    - Verify: --attach adds local files alongside originals
// 7. TestExecute_GmailForward_NoAttachmentsWithLocalAttach
//    - Verify: --no-attachments + --attach replaces originals with locals
```

## Dependencies & Risks

- **Upstream acceptance:** steipete/gogcli accepts external PRs (confirmed by merged community PRs). AGENTS.md provides
  clear guidelines.
- **Merge window:** Main branch may move. Fork from latest `main` just before implementation.
- **Go toolchain:** Must match repo's `go.mod` version. Run `make tools` to install pinned dev tools.
- **No OAuth credentials needed for unit tests:** All tests use `httptest` mock servers + `newGmailService` override
  pattern (established in existing tests).

## Implementation Steps

1. **Fork steipete/gogcli** and create `feat/gmail-forward` branch from `main`
2. **Create `internal/cmd/gmail_forward.go`** with command struct, Run method, and forward helpers
3. **Modify `internal/cmd/gmail.go`** to register the `Forward` command in the "Write" group
4. **Create `internal/cmd/gmail_forward_test.go`** with unit tests for helper functions
5. **Create `internal/cmd/execute_gmail_forward_test.go`** with integration tests
6. **Run `make ci`** (fmt + lint + test) and fix any issues
7. **Submit PR** referencing #166, crediting PR #167's design, summarizing scope/testing/new flags per AGENTS.md

## Sources

- **Origin document:**
  [docs/brainstorms/2026-03-24-gogcli-gmail-forward-requirements.md](docs/brainstorms/2026-03-24-gogcli-gmail-forward-requirements.md)
  -- Key decisions: flags over positional for recipients, forward attachments by default, fresh impl over landing PR
  #167
- **Issue:** [steipete/gogcli#166](https://github.com/steipete/gogcli/issues/166) -- Feature request
- **Prior art:** [steipete/gogcli#167](https://github.com/steipete/gogcli/pull/167) -- Stale PR with solid design, merge
  conflicts, bundled unrelated changes
- **Contribution guidelines:** [AGENTS.md](https://github.com/steipete/gogcli/blob/main/AGENTS.md)
