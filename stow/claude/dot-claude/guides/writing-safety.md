# Writing Safety: Secrets, Identifiers, Paths & Hostnames

Detail behind the **Secrets & private identifiers** and **Personal paths & hostnames** rules in `~/.claude/CLAUDE.md`.
The hard prohibitions live inline in CLAUDE.md; this file holds the examples, the scope list, and the pre-submit grep
guard. Open it before echoing any value from a secret store or submitting any commit/PR/issue/release/doc text.

## Secrets and identifiers: never echo, refer by location

When handling any value pulled from a secret store (`op`, `gh secret`, `printenv`, `aws ssm`, etc.), refer to it by
**location** or **name** — never reproduce the literal value in chat, commit messages, PR descriptions, summaries, or
retrospectives.

This applies uniformly to formal secrets (API tokens, passwords, keys) AND to identifiers the user took any step to keep
private (account IDs, tenant IDs, internal URLs). The "not formally a secret" carve-out does not exist at the echo
boundary — if the user routed it through `op` or a GitHub secret, they have a reason, and reproducing the value defeats
the intent regardless of formal classification.

Examples:

- ✅ "the `account_id` field in `Cloudflare API Token - Wrangler (<server>)`"
- ✅ "piped from 1Password to `gh secret set CF_ACCOUNT_ID`"
- ❌ "set `CF_ACCOUNT_ID` to `<the literal value>`"
- ❌ in a retrospective: "I echoed `<literal>` in my summary" — repeats the leak

**The retrospective trap:** when acknowledging a prior leak, the reflex is to quote the leaked value to show what
happened. Don't. Name the field, describe the location, or use `<the value>` / `<the ID>` as a placeholder. Quoting a
leak while owning it re-leaks it.

**How to apply:**

- Before echoing any value returned by `op`, `gh secret`, `printenv`, `scripts/read_field.sh`, or similar, ask: would I
  be comfortable with this in a public gist or training transcript? If not, use the name.
- In commit / PR bodies, describe the change referentially: "rotated `CF_ACCOUNT_ID`", not "set `CF_ACCOUNT_ID` to X".
- In retrospectives or debug logs that discuss a leaked value, never re-quote it. Reference it by name.
- Reflex rule, no exceptions. The chat transcript is not the trust boundary you think it is.

## Personal paths and machine names: relative or generic in all written artifacts

The secrets rule above covers values from secret stores. This rule covers two broader categories that frequently leak
into commit messages, PR bodies, and docs without anyone noticing:

**Personally-identifying paths.** Any path containing a username (`/Users/<user>/...`, `/home/<user>/...`,
`/c/Users/<user>/...`) reveals the developer's local layout and identity. Replace with relative or environment-variable
forms. Examples:

- `/Users/<user>/dotfiles/...` → `~/dotfiles/...`
- `/home/<user>/.bun/bin` → `$HOME/.bun/bin`
- If you must show a path that the runtime stores absolutely (systemd `Environment=`, plist `PATH=`, etc.), substitute
  `$HOME` in the rendered text and note that the literal file expands it.

Standard-system absolute paths without identifying segments stay as-is: `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin`, `/etc/...`, `/home/linuxbrew/.linuxbrew/bin` (Linuxbrew's install path is shared across all installations
and isn't PII).

**Machine and host names.** Don't reference internal hostnames (development boxes, home-network machines, Tailscale
magic DNS names, cloud-account labels) by their literal name in any written artifact. Use generic descriptors that
communicate the role. Examples:

- `<internal-hostname>`, `<internal-hostname>_wifi` → "the Linux server", "the deployed server", "the headless server",
  "this Mac" (Mac itself isn't identifying since every macOS dev box is "a Mac")
- Cloud account names, tenant identifiers, internal subdomains → describe by role

**Scope:** commit messages, PR titles and bodies, issue bodies, issue comments, release notes, docs in `docs/solutions/`
(which sync to a separate private repo), READMEs, plan files in `docs/plans/`, chat transcripts that may get pasted into
issues, retrospective notes. The 1Password entry name in the Cloudflare example above is itself written `(<server>)`,
not the literal hostname — the rule applies even to "harmless-looking" examples in docs.

**Exception — functional code and config:** SSH config entries, hostname-dependent scripts, systemd unit files that need
the literal `/home/<user>/` path because the runtime doesn't expand `$HOME`, and similar code that NEEDS the literal
value to function are fine. The rule applies to written artifacts about the code, not the code itself.

**How to apply:**

- Before submitting any commit message, PR body, or doc, scan the draft. A practical grep guard before `gh pr edit
  --body-file`:

  ```bash
  rg '/Users/[^/]+/|/home/[^/]+/|<your-known-hostnames>' "$BODY"   # or whichever /tmp/<naming-rule>.md path
  ```

  If anything fires, replace with relative or generic equivalents before submit.
- The `/unslop` skill doesn't detect these patterns yet — treat the guard above as your own pre-submit pass until it
  does.
- For solutions-docs entries (which ship to a separate private repo), the bar is the same as PRs: generic descriptors
  only.
