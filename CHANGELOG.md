# Changelog

All notable changes to this project will be documented in this file.

## [2026.05.16]

### Added

- Rectangle window manager (macOS): keyboard hotkeys for snap/resize, size-cycling on repeated arrow presses, flush borders, no margins. Run `scripts/rectangle-defaults.sh` after first-launch Accessibility grant. by @brettdavies in [#70](https://github.com/brettdavies/dotfiles/pull/70)
- ⌃⌥C triggers `centerHalf` with cycling (1/2 → 2/3 → 1/3 centered vertical column on repeated presses), replacing the default translate-only `center` action.
- macOS LaunchAgents for the qmd knowledge-base index: `com.user.qmd-update`, `com.user.qmd-embed`, and `com.user.qmd-cleanup`. Schedule, logs, and bootstrap match the Linux systemd setup so the laptop and server keep their indexes maintained the same way. by @brettdavies in [#71](https://github.com/brettdavies/dotfiles/pull/71)
- `scripts/qmd-launchd-enable.sh` idempotent bootstrap script (run once on macOS after `stow-deploy --all`).
- Install `rtk` via brew so the PreToolUse Bash hook from PR #62 (rewrites `git`, `cargo`, `gh`, `pytest`, `docker`, … through `rtk` for 60-90% token compression) actually runs on macOS. Linux bottles ship in the same formula, so this benefits headless servers too.
- PreToolUse Bash hook (`stow/claude/dot-claude/heredoc-pr-guard.sh`) that blocks heredoc piped into `--body`, `--notes`, or `-m` flags on `gh pr`, `gh issue`, `gh release`, and `git commit` commands. Allows every other heredoc use. Returns a deny JSON with a message pointing at the correct `--body-file` / `--notes-file` / `--file` workflow. by @brettdavies in [#75](https://github.com/brettdavies/dotfiles/pull/75)
- 41-case bats test suite (`tests/heredoc-pr-guard.bats`) covering positive deny cases, negative allow cases, and 13 red-team adversarial bypass attempts (indent-stripping `<<-EOF`, unusual heredoc markers, extra whitespace, subshell wrapping, chained commands, prepended env vars, `--body=value` equals form, quoted markers, request-changes reviews, line-continuation backslash, `bash -c` wrapper).
- New section in `stow/claude/dot-claude/CLAUDE.md`: "Personal paths and machine names: relative or generic in all written artifacts". Sits directly after the existing "Secrets and identifiers" section (same theme of privacy at the echo boundary, distinct category). by @brettdavies in [#77](https://github.com/brettdavies/dotfiles/pull/77)
- pnpm and yarn supply-chain age-gate env vars in `config/shell/supply-chain.sh`, enforcing a 7-day floor on installed packages to mirror the existing npm/bun/uv/pip controls. by @brettdavies in [#78](https://github.com/brettdavies/dotfiles/pull/78)
- New global ALLOW patterns at `stow/claude/dot-claude/settings.json`: lint/dev tools (actionlint, shellcheck, vale, rtk), 1password skill helpers (`~/.claude/skills/1password/scripts/*`), github-repo-setup repo-settings.sh report, unslop score.py, user-wide Read paths under `//home/brett/{,dev/,dev/solutions-docs/,.claude/,dotfiles/}**` and `//usr/bin/**`, WebFetch domains (github.com, docs.rs, crates.io, raw.githubusercontent.com, developers.cloudflare.com, rust-cli.github.io), Skill calls (plan-eng-review, unslop, defuddle), MCP wildcards (`mcp__plugin_cloudflare_*`, `mcp__plugin_compound-engineering_context7__*`, `mcp__plugin_context7_context7__*`). by @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- New global ASK carveouts: `Bash(gh pr create *)`, `Bash(gh pr edit *)`, `Bash(gh pr merge *)`, `Bash(gh repo create *)`, `Bash(op item *)`. These mutate shared state or read 1Password secrets and now prompt despite the broader `Bash(gh:*)` and op CLI presence in allow (deny→ask→allow precedence ensures ask wins).
- Tailscale skill enabled in this repo via `skillOverrides.tailscale = "on"` in `.claude/settings.local.json`.
- 23 Bash CLI tools to global ALLOW: bun add/x, defuddle, flatpak list, kill, magick, npm view, ollama list/ps/stop, pdfimages, pdftocairo, pgrep, rclone, sha256sum, snap list, trash-list, tsc, ty check, unzip, wrangler. by @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)
- 18 skill helper scripts to global ALLOW: 1password (create_item, edit_item, list_tags), bird, clip, docker-engine (docker-doctor, journal-tail, sg-docker.sh), gstack (4 entries), hb-verify, rust-new-repo, tailscale, x-api, plus ~/.claude/{md-align-tables.py, rust-ci-check.sh}.
- 9 Skill() entries to global ALLOW: browse, clip, ce-sessions, design-review, document-release, impeccable, office-hours, pdf-generator, qmd.
- 11 WebFetch domains to global ALLOW: arxiv.org, devcommunity/developer/docs.x.com, docs.brew.sh, docs.nvidia.com, gist.github.com, lib.rs, pandoc.org, sqlite.org, users.rust-lang.org.
- 4 Read paths to global ALLOW: ~/.gstack/projects/**, ~/github/**, /etc/systemd/system/**, /home/linuxbrew/.linuxbrew/share/bash-completion/completions/**.
- 19 ASK carveouts: killall:* and pkill:* (process-pattern killers; ASK so user can override per call), sg docker * (was bypassing the docker:* ASK), 11 wrangler destructive subcommands (delete, secret delete, kv key/namespace delete, r2 object/bucket delete, d1 delete/execute, hyperdrive/queues/workflows delete), 5 rclone destructive (delete, deletefile, purge, sync, bisync --resync). Per the verified deny→ask→allow precedence, these narrow ASK entries override the broader Bash(wrangler:*) and Bash(rclone:*) ALLOWs.
- Micro keybinding: Alt-i toggles overwrite mode (separate concern bundled as a passenger commit).
- `snapshots/tailscale/`: encrypted reference snapshot of the tailnet's ACL, services list, and per-host `tailscale serve` configs after the Taildrive + Services rollout. Refresh recipe in the snapshot README. by @brettdavies in [#84](https://github.com/brettdavies/dotfiles/pull/84)
- `taildrive-mount` and `taildrive-unmount` shell functions (macOS only). `taildrive-mount` calls `osascript -e 'mount volume ...'` for each share so Finder's SUID helper handles the `/Volumes` mkdir that direct `mount_webdav` from a user shell cannot. The share list lives in `$TAILDRIVE_SHARES`, exported from `~/.secrets` (git-crypt encrypted) so no host identifiers land in plaintext in this public repo.

### Changed

- BOOTSTRAP.md "oh-my-zsh" section: removed obsolete macOS/Linux split for plugin install. `brew bundle` handles `zsh-autosuggestions`, `zsh-syntax-highlighting`, and `zsh-completions` on both platforms; `.zshrc` sources them directly. Only `powerlevel10k` (theme, not plugin) still needs a manual symlink. by @brettdavies in [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Normalize `qmd-update.service`'s `Environment="PATH=..."` (quoted) to unquoted `Environment=PATH=...`, matching the format used by every other unit. Semantically identical, since quoting only matters when the value contains whitespace. by @brettdavies in [#74](https://github.com/brettdavies/dotfiles/pull/74)
- `stow/claude/dot-claude/CLAUDE.md` "Pull Requests" section reorganized as "Authoring GitHub correspondence". Three-step workflow now applies to every server-side artifact: author in `/tmp/`, run `/unslop` (mandatory), submit via the file-flag variant. The "Heredoc escape rule" backstop is replaced by an explicit "Enforcement" section pointing at the new hook. by @brettdavies in [#75](https://github.com/brettdavies/dotfiles/pull/75)
- `stow/claude/dot-claude/settings.json` adds the hook to `PreToolUse.Bash`, running before the `rtk hook claude` entry so the deny decision fires before any rewrite.
- The existing Cloudflare-token example in "Secrets and identifiers" referenced an internal hostname in the 1Password entry name. Updated to a generic `(<server>)` placeholder, consistent with the new rule. by @brettdavies in [#77](https://github.com/brettdavies/dotfiles/pull/77)
- RELEASES.md: PR-body discipline rule. Bodies are user-facing substance only; no workflow recaps, no verification artifacts. by @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- `.claude/settings.local.json` allow array alphabetized as a side-effect of the audit script's union pass; same content otherwise.
- SSH config now routes the three Tailscale-enabled host aliases via Tailscale SSH by default (port 22, FQDN, node identity), with a Match-driven override to LAN sshd when this Mac has a `<lan-subnet>.x` IP. Off-LAN: no SSH key needed. On-LAN: direct LAN path retained for speed. by @brettdavies in [#80](https://github.com/brettdavies/dotfiles/pull/80)
- One host's previously-inlined `tmux new -A -s main` RemoteCommand was removed. Auto-tmux on SSH connect is now opt-in per session, not config-default.
- killall:* moved from DENY to ASK. Reason: user does invoke killall periodically for legitimate process-cleanup; outright deny was too strict. ASK preserves the friction without blocking. Bash(kill:*) (PID-targeted, lower risk) stays in ALLOW. by @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)

### Fixed

- Repair PATH ordering on macOS login shells so `/opt/homebrew/bin` and `/opt/homebrew/sbin` precede `/usr/bin` (was being clobbered by Apple's `/etc/zprofile` running `path_helper -s` after `.profile` set up PATH). by @brettdavies in [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Eliminate PATH duplication on shell startup by adding a sentinel guard to `.zshrc`'s `.profile` re-source (matches the pattern in `.bashrc` and `.zshenv`) and dedupe checks to `local-paths.sh` and `lm-studio.sh`.
- Stop oh-my-zsh `plugin not found` warnings by sourcing `zsh-autosuggestions` and `zsh-syntax-highlighting` directly from `$HOMEBREW_PREFIX/share/` (Homebrew's documented integration) instead of declaring them in `plugins=(...)` where omz's detection fails on brew's layout.
- Add `Environment=PATH=...` to four user systemd units that were relying on inherited PATH or internal full-path workarounds. Affects `qmd-cleanup`, `box-bisync`, `obsidian`, and `opendataloader-pdf`. Lets the wrapped scripts find brew-installed tools (`rclone`, `git`, coreutils, etc.) without hardcoded `/home/linuxbrew/.linuxbrew/bin/...` fallbacks. by @brettdavies in [#74](https://github.com/brettdavies/dotfiles/pull/74)
- bats: `tests/stow-deploy-packages.bats` no longer fails on Linux when asserting explicit-arg expansion through `ghostty` (a macOS-only DESKTOP package). by @brettdavies in [#78](https://github.com/brettdavies/dotfiles/pull/78)
- bats: `tests/qmd-serve.bats` assertions for `qmd-update.service` and `qmd-cleanup.service` now match the post-PR-#74 unit files (Environment=PATH=/home/linuxbrew/.linuxbrew/bin:... for brew tool resolution).
- Removed pre-existing one-off entries from global allow that should never have been promoted (specific tax-document copies, pdf-generator scratch builds, Cloudflare-Pages-to-Workers sed renames, claude model probe). 24 entries stripped, mostly subsumed by broader wildcards anyway. by @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- Stripped 50 redundant entries from `.claude/settings.local.json` and 672 from the other 17 `~/dev/*/.claude/settings.local.json` files. The latter are gitignored/untracked, so the strips apply on disk in those repos without separate commits.
- Three speculative MCP wildcards in `stow/claude/dot-claude/settings.json` replaced with enumerated entries: `mcp__plugin_cloudflare_*` becomes 11 entries from the proven cloudflare set (`accounts_list`, `kv_namespaces_list`, `r2_buckets_list`, `set_active_account`, `workers_get_worker`, `workers_list`, `cloudflare-docs__search_cloudflare_documentation`, `cloudflare-api__execute`, `cloudflare-api__search`, `cloudflare-builds__accounts_list`, `cloudflare-observability__accounts_list`); `mcp__plugin_compound-engineering_context7__*` and `mcp__plugin_context7_context7__*` become 4 enumerated entries (2 install paths × 2 tools each). by @brettdavies in [#81](https://github.com/brettdavies/dotfiles/pull/81)
- Stripped 13 redundant entries from `.claude/settings.local.json`: 3 /tmp/test_full.pdf curl probes, 6 macOS personal-home Read entries (orphans on Linux), 4 entries subsumed by the new global wildcards (rclone listremotes/version, kill %1 covered by kill:*). by @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)
- Stripped ~324 entries across 17 other ~/dev/*/.claude/settings.local.json files (gitignored, on-disk only). Two files became empty (brettdavies, dot-github) and were deleted entirely.
- Closed semantic regressions surfaced during the security review: pkill was bypassing the killall deny; sg docker was bypassing the docker ASK; broad wrangler:* and rclone:* ALLOWs would have shipped destructive subcommands auto-allowed.

### Documentation

- Updated `~/dev/solutions-docs/best-practices/claude-code-permission-globs-use-colon-not-star-2026-04-20.md` to correct the previous claim that `Bash(cmd *)` (space-asterisk) was equivalent-to-dangerous Form A. Per current Claude Code docs (verified 2026-05-15), Forms B (space) and C (colon) are equivalent and both safe; only bare-prefix Form A is the typosquat surface. Audit regex corrected from `[^:]\*\)` to `[^: ]\*\)`. by @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- Added `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` covering cross-list precedence (deny → ask → allow), within-list subsumption analysis, strategic carveouts pattern, and the promote-and-strip workflow.
- `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` (commit `4f62307` in solutions-docs) gains a "Tool pattern coverage (verified behavior)" section recording both findings: MCP wildcards do not validate, `Read(~/...)` does. Future audits skip the experiments. by @brettdavies in [#81](https://github.com/brettdavies/dotfiles/pull/81)
- No doc changes in this PR. The audit-strategy doc at `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` already covers cross-list precedence, subsumption analysis, and tool pattern coverage findings used to drive this audit. by @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)
- Replace specific environment-tied references in tracked docs with generic placeholders and role descriptors, improving readability and portability for future contributors. by @brettdavies in [#85](https://github.com/brettdavies/dotfiles/pull/85)

### Removed

- Dead SDKMAN init blocks from `stow/zsh/dot-zprofile` and `stow/bash/dot-bash_profile`. SDKMAN is not installed on either the development Mac or the headless Linux server. by @brettdavies in [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Drop one manual LAN-alias `Host` block from `stow/ssh/dot-ssh/config`. Use the canonical short name from any network: Tailscale SSH off-LAN, LAN sshd on the home network via the existing `Match originalhost` override. by @brettdavies in [#82](https://github.com/brettdavies/dotfiles/pull/82)

**Full Changelog**: [2026.05.11...2026.05.16](https://github.com/brettdavies/dotfiles/compare/2026.05.11...2026.05.16)

## [2026.05.11]

### Added

- Install `rtk-ai/rtk` `PreToolUse` Bash hook for ~60-90% token compression on supported commands (`git`, `cargo`, `gh`, `pytest`, `docker`, etc.). by @brettdavies in [#62](https://github.com/brettdavies/dotfiles/pull/62)
- Document rtk meta commands in global `CLAUDE.md`: `rtk gain` (savings analytics), `rtk discover` (find missed compression opportunities), `rtk proxy <cmd>` (run unfiltered for debugging).
- Add `ancsite`, `ancspec`, `ancskill` tmuxinator configs pointing at `~/dev/agentnative-{site,spec,skill}`. by @brettdavies in [#63](https://github.com/brettdavies/dotfiles/pull/63)

### Changed

- Rename `agentnative-cli` tmuxinator session to `anc` (project root unchanged: `~/dev/agentnative-cli`). by @brettdavies in [#63](https://github.com/brettdavies/dotfiles/pull/63)
- `tmux-new-session` now writes a tmuxinator config under `stow/tmuxinator/dot-config/tmuxinator/<name>.yml` and re-stows the package before launching the session, so every session it creates is reproducible and source-controlled. Sessions are started via `tmuxinator start` instead of raw `tmux new-session`. by @brettdavies in [#67](https://github.com/brettdavies/dotfiles/pull/67)

### Fixed

- Stop auto-formatting files under `/tmp`, `/var/tmp`, and `$TMPDIR` so PR-body drafts and other scratch files paste verbatim into downstream forms. by @brettdavies in [#64](https://github.com/brettdavies/dotfiles/pull/64)
- Restore the 3-pane default layout (yazi, shell, lazygit) to every tmuxinator config — sessions started via `mux start <name>` now reopen with the expected working layout instead of a single bare pane. by @brettdavies in [#66](https://github.com/brettdavies/dotfiles/pull/66)
- Replace deprecated `post:` hook with `on_project_exit:` in every tmuxinator config and in the config template emitted by `tmux-new-session`. Sessions still get the 3-pane resize, but `tmuxinator start` no longer prints the deprecation warning. by @brettdavies in [#68](https://github.com/brettdavies/dotfiles/pull/68)

### Documentation

- Document the triple-diff verification step in `RELEASES.md` (main→release, release→dev, dev→main + guarded-paths grep + `git cherry` patch-id sweep) so missed cherry-picks get caught before the release tag goes out instead of after. by @brettdavies in [#60](https://github.com/brettdavies/dotfiles/pull/60)
- Document the cliff.toml chore-skip footgun in the `RELEASES.md` review step — generated changelog must be cross-checked against PR bodies for cherry-picked PRs whose commit subject starts with a skipped type.
- Add "Prefer `feat`/`fix` over `chore` when the change has any user-observable effect" rule to global CLAUDE.md `## Commit Messages` section, with the `cliff.toml` rationale.
- Restructure `RELEASES.md` to consolidate cliff.toml `chore`-skip guidance into a dedicated `### CHANGELOG is generated, never hand-written` subsection under `## Releasing dev to main` (mirrors sibling brettdavies repos); trim `## PRs and changelog generation` to PR-author-facing content only. by @brettdavies in [#61](https://github.com/brettdavies/dotfiles/pull/61)
- Add a `### Tmuxinator Sessions` section to `README.md` documenting the 3-pane layout intent and `tmuxinator start <name>` (and the `mux start <name>` shell alias, and the SSH form `ssh <host> -t tmuxinator start <name>`) as the preferred launch / connection idiom. Correct the stale "13 projects" count in the stow package row to "16 projects". by @brettdavies in [#68](https://github.com/brettdavies/dotfiles/pull/68)

**Full Changelog**: [2026.05.02...2026.05.11](https://github.com/brettdavies/dotfiles/compare/2026.05.02...2026.05.11)

## [2026.05.02]

### Added

- `qmd-cleanup.timer` + `qmd-cleanup.service`: nightly `qmd cleanup` with `RandomizedDelaySec=2h` so fires land in a [03:00, 05:00] window. by @brettdavies in [#51](https://github.com/brettdavies/dotfiles/pull/51)
- `qmd-ollama-unload-all` helper: dynamically frees Ollama VRAM only when GPU has less than `MIN_FREE_MIB` (default 2048) free, leaving hot pins alone when headroom is sufficient.
- `stow/claude/dot-claude/md-align-tables.py`: GFM table aligner with PEP 723 inline metadata (uv run --script). Reflows mixed compact/aligned tables into consistent aligned-pipe style; preserves alignment hints, escaped pipes, frontmatter, fenced code, and HTML. by @brettdavies in [#52](https://github.com/brettdavies/dotfiles/pull/52)
- `stow/github/dot-config/github/pull_request_template.md`: `**Renamed:**` field in the `## Files Modified` section so rename-style changes get their own bullet category instead of splitting into create+delete or hiding under modified.
- 14 new telemetry opt-outs in `config/shell/telemetry.sh`: Apollo Rover, Astro, AWS CDK, Cloudflare Wrangler, .NET Interactive, .NET svcutil, Gemini CLI, Go runtime (1.23+), Hugging Face Hub, Nuxt, Stripe CLI, Supabase, Turborepo, Vercel. by @brettdavies in [#55](https://github.com/brettdavies/dotfiles/pull/55)
- Discoverability comment in `config/shell/supply-chain.sh` pointing at `stow/bun/dot-bunfig.toml` so future-me doesn't go looking for bun in this file (bun has no env-var equivalent for `minimumReleaseAge`).
- `copy-on-select = clipboard` in `stow/ghostty/dot-config/ghostty/config` so text selected with the mouse is auto-copied to the system clipboard (no Cmd+C needed), parity with tmux behavior. by @brettdavies in [#56](https://github.com/brettdavies/dotfiles/pull/56)

### Changed

- `stow/claude/dot-claude/auto-format.sh`: new Step 2 invokes `md-align-tables.py` (gated on `command -v uv`) between md-wrap and markdownlint; prior Step 2 (markdownlint) renumbered to Step 3. by @brettdavies in [#52](https://github.com/brettdavies/dotfiles/pull/52)
- `stow/claude/dot-claude/CLAUDE.md`: five workflow expansions — parallel CE + qmd learnings dispatch (workaround for EveryInc/compound-engineering-plugin#655), `.context/handoffs/` filename convention, pre-flight PR template read before `gh pr create`, branch-discipline scope refinement (audience, not extension), and two new principle sections (long artifacts go to files; system configs go in dotfiles).
- Re-sorted `telemetry.sh` to strict ASCII alphabetical order. Fixes two pre-existing minor disorderings: `Azure SDK` was before `Azure Functions Core Tools`, and `Sentry` was before `Segment`. by @brettdavies in [#55](https://github.com/brettdavies/dotfiles/pull/55)
- Annotated version-gated entries inline (`GH_TELEMETRY` v2.91.0+, `GOTELEMETRY` Go 1.23+).

### Fixed

- `qmd-embed.service` no longer references the stale `qwen3-coder:30b` model name. Pre-embed VRAM step now adapts to whatever Ollama is actually running, on whichever host. by @brettdavies in [#51](https://github.com/brettdavies/dotfiles/pull/51)
- `stow/claude/dot-claude/md-wrap.py`: `wrap_paragraph.drain()` no longer leaks `buf_indent` across paragraphs. Adds the missing `nonlocal` declaration plus a post-flush reset. by @brettdavies in [#52](https://github.com/brettdavies/dotfiles/pull/52)
- Cross-platform `docs/solutions` symlink: now resolves on both macOS and Linux without per-host re-creation. by @brettdavies in [#54](https://github.com/brettdavies/dotfiles/pull/54)

### Documentation

- Update `stow/claude/dot-claude/CLAUDE.md` recreate-symlink command to use the relative form. by @brettdavies in [#54](https://github.com/brettdavies/dotfiles/pull/54)
- Document PR template sub-section completeness — `Files Modified` and `Related Issues/Stories` sub-headers must appear with `- None.` or `n/a` when empty; only the `Changelog` block's `### Added`/`Changed`/`Fixed`/`Documentation` sections may be deleted when empty. by @brettdavies in [#58](https://github.com/brettdavies/dotfiles/pull/58)
- Document the heredoc escape rule for `gh pr create --body "$(cat <<'EOF' ... EOF)"` — single-quoted delimiters preserve the body literally, so do not escape inner quotes, backslashes, or `$`.
- Expand the plan/docs-only direct-commit exception to cover `docs/ideation/**` and `docs/research/**`.

**Full Changelog**: [2026.04.22...2026.05.02](https://github.com/brettdavies/dotfiles/compare/2026.04.22...2026.05.02)

## [2026.04.22]

### Added

- AppArmor profile for Playwright's Chromium binaries (both `chrome-headless-shell` and full `chrome`), deployed with `sudo scripts/apparmor-deploy.sh`. Persists across reboots via `/etc/apparmor.d/`. by @brettdavies in [#39](https://github.com/brettdavies/dotfiles/pull/39)
- `opendataloader-pdf` stow package: socket unit (`127.0.0.1:5002`), service unit (socket-activated, hardened with `NoNewPrivileges` + `PrivateTmp`), and a two-file launcher (`opendataloader-pdf-hybrid-sa` sh wrapper + `.py` module with LISTEN_FDS dispatch and asyncio idle-exit watchdog). by @brettdavies in [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `scripts/opendataloader-pdf-enable.sh` — one-shot idempotent enable script that stops orphan listeners, reloads systemd, enables `--now` the socket unit, and smoke-tests `/health`.
- `--idle-timeout` flag on the launcher; defaults to 60 s so qmd isn't starved by ODL's residual 4.4 GB.
- Stow-managed `qmd-serve.service` systemd user unit for the sequential-mode daemon (always-on, peak VRAM ~2.6 GB instead of ~5.4 GB). by @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `config/shell/qmd.sh` exports `QMD_SERVER=http://127.0.0.1:7832` in all shell contexts (interactive, non-interactive zsh, cron, systemd children that source `.profile`).
- `stow/qmd/dot-local/bin/qmd` sh wrapper dispatches to the brettdavies/qmd fork at `$HOME/dev/qmd/qmd`.
- `scripts/qmd-serve-enable.sh` is a Linux-only idempotent one-shot that cleans orphan `:7832` listeners, reloads systemd, enables --now, and smokes `/health`.
- `target/**` ignore and `# Canonical version: 2026.04.15` header in the canonical markdownlint config so per-repo copies can detect drift with a one-liner comparison. by @brettdavies in [#49](https://github.com/brettdavies/dotfiles/pull/49)

### Changed

- Change release-branch construction from `git merge origin/development` to cherry-picking PR squash commits, so `git-cliff --unreleased` only sees the true release delta. by @brettdavies in [#37](https://github.com/brettdavies/dotfiles/pull/37)
- `scripts/stow-deploy`: `opendataloader-pdf` added to `SHARED_PACKAGES` and to the Linux-only skip block (macOS deploys skip with a WARNING). by @brettdavies in [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `qmd-embed.service` and `qmd-update.service` ExecStart switched to `%h/.local/bin/qmd` (the new stow wrapper). by @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `QMD_SERVER` export moved out of `stow/shell/dot-profile` into `config/shell/qmd.sh` (feature-named file convention).
- Rename `CLAUDE.md` to `AGENTS.md` so Claude Code, opencode, Cursor, and Codex all read the same project-level instructions. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)
- Update `README.md` stow-package table: add `github`, `openclaw`, `opendataloader-pdf`, and `rust` rows; expand the `qmd` row to cover the new qmd-serve daemon and `.local/bin/qmd` wrapper.
- Update `README.md` Shell Environment table: add `qmd.sh` (exports `QMD_SERVER`).
- Update `README.md` Release Automation section: rename `RELEASE_TOKEN` → `CI_RELEASE_TOKEN` and clarify that release notes come from the committed `CHANGELOG.md`, not from git-cliff at CI time.
- Update `BOOTSTRAP.md` manual stow commands to include `github` (macOS + headless) and `opendataloader-pdf` (headless), matching `scripts/stow-deploy`'s `SHARED_PACKAGES`.
- Update `PROJECT.md` counts (17 → 32 stow packages, 11 → 16 shell fragments) and expand the package breakdown.
- Correct the `RELEASES.md` pipeline diagram to show cherry-picking from dev onto a `release/*` branch branched from main (matches the flow landed in #37).

### Fixed

- `qmd-update.service` now sets an explicit `PATH` that includes the Homebrew prefix so timer-triggered runs can resolve subprocess dependencies. by @brettdavies in [#46](https://github.com/brettdavies/dotfiles/pull/46)
- Auto-format hook now reads its global config fallback from `~/.markdownlint-cli2.yaml` (stow-managed symlink to dotfiles canonical) instead of the deleted `~/.claude/.markdownlint-cli2.yaml` stray. by @brettdavies in [#49](https://github.com/brettdavies/dotfiles/pull/49)
- Realign table column widths across `AGENTS.md`, `README.md`, `PROJECT.md`, and `RELEASES.md` so they satisfy MD060 `aligned` style after the widened rows. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)

### Documentation

- Document the cherry-pick flow and rename "Why branch from main, not development" to explain both the `add/add` conflict and the orphan-history failure modes that motivate this workflow. by @brettdavies in [#37](https://github.com/brettdavies/dotfiles/pull/37)
- Describe \`docs/solutions/\` structure and search path in \`CLAUDE.md\` Reference section. by @brettdavies in [#41](https://github.com/brettdavies/dotfiles/pull/41)
- Mark \`docs/plans/2026-04-21-001-feat-opendataloader-pdf-socket-activation-plan.md\` as \`completed\` with post-ship notes describing shipped state, deviations, and measured timings. by @brettdavies in [#42](https://github.com/brettdavies/dotfiles/pull/42)

**Full Changelog**: [2026.04.15...2026.04.22](https://github.com/brettdavies/dotfiles/compare/2026.04.15...2026.04.22)

## [2026.04.15]

### Added

- Add `DO_NOT_TRACK=1` universal telemetry opt-out (consoledonottrack.com) plus targeted opt-outs for VS Code (`VSCODE_TELEMETRY_LEVEL=off`), PowerShell (`POWERSHELL_TELEMETRY_OPTOUT=1`), and Azure Functions Core Tools (`FUNCTIONS_CORE_TOOLS_TELEMETRY_OPTOUT=1`) by @brettdavies in [#31](https://github.com/brettdavies/dotfiles/pull/31) and [#32](https://github.com/brettdavies/dotfiles/pull/32)
- Add nightly autocommit for `obsidian-vault`, `solutions-docs`, and agent-skills with a systemd timer randomized to 2-4 AM CT by @brettdavies in [#33](https://github.com/brettdavies/dotfiles/pull/33)
- Add `mnt-nas.automount` for on-demand NAS mounting (fixes the WiFi boot race) and `scripts/nas-deploy.sh` for copy-deploying system-level systemd units by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)
- Add `github/` stow package targeting `~/.config/github/` for repo-workflow templates; `SHARED_PACKAGES` in `scripts/stow-deploy` now includes it by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)

### Changed

- Rename `RELEASING.md` to `RELEASES.md` and restructure to the canonical release-doc layout shared across brettdavies repos by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)
- Move the canonical PR template from `stow/claude/dot-claude/templates/pull-request.md` to `stow/github/dot-config/github/pull_request_template.md`; `.github/pull_request_template.md` is now a real inlined file so GitHub's PR-template discovery works
- Prohibit AI-attribution trailers on commit messages and PR bodies via global CLAUDE.md directive
- Move `QMD_SERVER` and Bun PATH exports from `.zshrc` to `.profile` so cron, SSH commands, and other non-interactive contexts see them
- Support markdown hard line breaks (two trailing spaces) in the `md-wrap.py` PostToolUse hook and in the markdownlint config; prefer the project-local `markdownlint-cli2.yaml` over the global one for line-width
- Strengthen the query-solutions-first instruction in global CLAUDE.md
- Stop tracking `TODOS.md` (added to global gitignore)

### Fixed

- Fix nightly autocommit to embed the Conventional Commits spec and SRP rules in the prompt, and delegate full add+commit to `claude -p` rather than staging in shell

### Documentation

- Document the system-level systemd units pattern in CLAUDE.md (copy-deploy, not stow) and add a matching section to README.md by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)

**Full Changelog**: [2026.04.01...2026.04.15](https://github.com/brettdavies/dotfiles/compare/2026.04.01...2026.04.15)

## [2026.04.01]

### Added

- Add `gogcli` stow package with `config.json` and shell wrapper by @brettdavies in
  [#27](https://github.com/brettdavies/dotfiles/pull/27)
- Add tmuxinator stow package with 13 declarative session YAML configs by @brettdavies in
  [#28](https://github.com/brettdavies/dotfiles/pull/28)
- Add `mux` (tmuxinator passthrough) and `mux-all` (start all sessions) shell functions
- Add caam account manager stow package with daemon auto-start and `claude-switch`
- Add headless Obsidian stow package with systemd service, config, and CLI wrapper
- Add rclone Box bisync stow package with systemd timer and git-crypt encrypted config
- Add systemd user timers for qmd, openclaw, and nightly rustup-update
- Add supply-chain safety for uv, npm, pip, and bun (package age gates)
- Add TPM bootstrap instructions to BOOTSTRAP.md

### Changed

- Adopt changelog-as-committed-artifact release process (no more CI-generated changelog)
- Inline brew shellenv to eliminate Ruby subprocess on startup (~200ms savings)
- Replace docs/solutions/ directory with symlink to shared solutions-docs repo
- Rename RELEASE_TOKEN to CI_RELEASE_TOKEN by @brettdavies in [#26](https://github.com/brettdavies/dotfiles/pull/26)
- Pin external GitHub Actions to commit SHAs, upgrade to actions/checkout v6.0.2

### Fixed

- Add Homebrew site-functions to zsh fpath (fixes completions for tmuxinator, brew, gh, bat, etc.)
- Split caam interactive/non-interactive wrapper, add claude-switch helper
- Update openclaw service paths from OpenClaw to Areas/openclaw
- Enable rclone bisync filters and exclude Obsidian per-device state

### Documentation

- Add RELEASING.md with CalVer release branch procedure
- Overhaul README and extract bootstrap guide

**Full Changelog**: [2026.03.19...2026.04.01](https://github.com/brettdavies/dotfiles/compare/2026.03.19...2026.04.01)

## [2026.03.19]

### Changed

- Rename RELEASE_TOKEN to CI_RELEASE_TOKEN for clarity by @brettdavies in
  [#26](https://github.com/brettdavies/dotfiles/pull/26)

**Full Changelog**: [2026.03.18...2026.03.19](https://github.com/brettdavies/dotfiles/compare/2026.03.18...2026.03.19)

## [2026.03.18]

### Added

- Add `bun`, `pip`, `codex`, `opencode`, `local` stow packages
- Add `lazygit`, `micro`, `yazi` stow packages with configs
- Add platform-aware `$EDITOR` via `config/shell/` and `.gitconfig`
- Add `gh` CLI merge guard wrapper to block AI merges into `main`/`master`
- Add encrypted `gh` hosts.yml via git-crypt

### Changed

- Cross-platform editor config, CI hardening, new stow packages, and docs overhaul by @brettdavies in
  [#23](https://github.com/brettdavies/dotfiles/pull/23)
- Overhaul README with stow package table, shell environment table, and performance section
- Extract BOOTSTRAP.md from README with detailed platform-specific setup

### Fixed

- Release workflow fixes and action SHA pinning by @brettdavies in
  [#24](https://github.com/brettdavies/dotfiles/pull/24)
- Pin all external actions to commit SHAs
- Fix release body extraction (use git-cliff action output instead of bare CLI)

**Full Changelog**: [2026.03.13...2026.03.18](https://github.com/brettdavies/dotfiles/compare/2026.03.13...2026.03.18)

## [2026.03.13]

### Added

- Per-platform git config templates (`config/git/local.linux`, `config/git/local.darwin`)
- `stow-deploy` auto-deploys platform template to `~/.config/git/local` if absent

### Fixed

- Cross-platform hardening for shell scripts, SSH config, and git signing by @brettdavies in
  [#22](https://github.com/brettdavies/dotfiles/pull/22)
- Headless server adoption (OpenClaw, EDITOR/VISUAL, printer aliases, tmux)
- Cross-platform guards (Obsidian macOS-only, hbash Linuxbrew fallback)

### Documentation

- Compound solution: cross-platform shell idiom and config hardening

**Full Changelog**:
  [2026.03.12.1...2026.03.13](https://github.com/brettdavies/dotfiles/compare/2026.03.12.1...2026.03.13)

## [2026.03.12.1]

### Fixed

- Force Node.js 24 for GitHub Actions by @brettdavies in [#20](https://github.com/brettdavies/dotfiles/pull/20)

**Full Changelog**:
  [2026.03.12...2026.03.12.1](https://github.com/brettdavies/dotfiles/compare/2026.03.12...2026.03.12.1)

## [2026.03.12]

### Added

- Initial dotfiles repository with GNU Stow
- Script library with sync, verification, and dry-run
- Git-crypt encryption for secrets, SSH config, and git allowed_signers
- iCloud sync via LaunchAgent (macOS)
- Claude Code configuration and project documentation
- Cross-platform deployment to Ubuntu server
- `scripts/stow-deploy` conflict resolution wrapper with `--headless` mode by @brettdavies in
  [#4](https://github.com/brettdavies/dotfiles/pull/4)
- Repo-local enforcement (hooks, rulesets, config) by @brettdavies in
  [#3](https://github.com/brettdavies/dotfiles/pull/3)
- Auto-configure `core.hooksPath` in stow-deploy by @brettdavies in [#7](https://github.com/brettdavies/dotfiles/pull/7)
- CalVer changelog automation with git-cliff by @brettdavies in [#16](https://github.com/brettdavies/dotfiles/pull/16)
- `stow/tmux` package with full tmux config and TPM by @brettdavies in
  [#11](https://github.com/brettdavies/dotfiles/pull/11)
- Platform-aware package sets (`SHARED_PACKAGES` + `DESKTOP_PACKAGES`) by @brettdavies in
  [#12](https://github.com/brettdavies/dotfiles/pull/12)

### Changed

- Restructure as configuration store, remove shell CLI
- Zero-disk secret loading with `op inject`
- Branch workflow enforcement and documentation

### Fixed

- Cross-platform git signing and Claude Code hook guards
- Portable binary detection in git hooks by @brettdavies in [#8](https://github.com/brettdavies/dotfiles/pull/8)
- Standardize hook shebangs, add strict mode, optimize git-crypt check by @brettdavies in
  [#5](https://github.com/brettdavies/dotfiles/pull/5)
- Shell startup optimization from ~440ms to ~190ms by @brettdavies in
  [#14](https://github.com/brettdavies/dotfiles/pull/14)

### Documentation

- Compound solution for deployment hardening (sentinel, binary detection, auto hooks) by @brettdavies in
  [#10](https://github.com/brettdavies/dotfiles/pull/10)
