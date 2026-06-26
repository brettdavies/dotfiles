# Changelog

All notable changes to this project will be documented in this file.

## [2026.06.26]

### Added

- Claude Code now auto-formats shell scripts with `shfmt -i 2 -ci -bn` on edit, matching the pre-commit and pre-push shell checks. by @brettdavies in [#132](https://github.com/brettdavies/dotfiles/pull/132)
- New `~/.claude/guides/shell-style.md` covering shell conventions `shfmt` and `shellcheck` do not enforce: function naming, `ALL_CAPS` constants, doc-block shape, function ordering, and errors-to-STDERR.
- `scripts/tailscale-serve-setup.sh`: idempotent reproducer for bigdaddy's Tailscale Serve config (openclaw node serve + `svc:ollama` service serve), so a fresh host or a dropped binding recovers in one run. by @brettdavies in [#136](https://github.com/brettdavies/dotfiles/pull/136)
- `com.user.qmd-serve` LaunchAgent that keeps `qmd serve` resident on `127.0.0.1:7832` (loopback only), with `RunAtLoad` + `KeepAlive`, full-resident (no `--low-vram`). by @brettdavies in [#138](https://github.com/brettdavies/dotfiles/pull/138)
- `brave-search` helper: query the Brave Search API from the CLI and print ranked results, with the API key read from 1Password at call time via a mode-600 curl config so it never reaches a child process argv or an exported env var. by @brettdavies in [#148](https://github.com/brettdavies/dotfiles/pull/148)
- `gh-revision-audit` helper: list issues and PRs you authored that still carry multiple non-deleted edit-history revisions worth pruning through the GitHub web UI.
- `~/.grok/bin` on PATH with grok zsh completions.
- Tailscale serve binding for `svc:codex-proxy`: advertises the codex-proxy OpenAI-compat endpoint at `https://codex-proxy.<tailnet>/` forwarding to `127.0.0.1:8080`, health-gated before the VIP is pointed at it. Unlike `svc:ollama` it needs no Caddy Host-rewrite shim (codex-proxy accepts any Host header); inbound stays gated by the tailnet ACL plus the `LITELLM_API_KEY` bearer. by @brettdavies in [#149](https://github.com/brettdavies/dotfiles/pull/149)
- Deploy the gbrain thin-client config on macOS via stow, pointing at the shared Postgres brain; the Mac is a read-only client with no local indexing daemons. by @brettdavies in [#150](https://github.com/brettdavies/dotfiles/pull/150)
- Route gbrain embeddings and chat/expansion to the tailnet services on macOS via Darwin-gated `OLLAMA_BASE_URL` / `LITELLM_BASE_URL`, keeping a single shared embedder for vector-space consistency.
- `xurl` alias plus a `~/.local/bin/xurl` shim, both forwarding to `xr` (the `xurl-rs` binary). The alias covers interactive shells; the shim covers subprocess callers that never load it. by @brettdavies in [#152](https://github.com/brettdavies/dotfiles/pull/152)

### Changed

- Install `ruby` explicitly via the Brewfile. by @brettdavies in [#134](https://github.com/brettdavies/dotfiles/pull/134)
- macOS `qmd` dispatcher now targets the fork launcher (`~/dev/qmd/bin/qmd`), which provides `qmd serve` and `QMD_REMOTE_URL`; the upstream package provided neither. by @brettdavies in [#138](https://github.com/brettdavies/dotfiles/pull/138)
- `QMD_REMOTE_URL` is now exported on all platforms; `QMD_LOW_VRAM` is now Linux-only (macOS runs the daemon full-resident).
- The periodic `com.user.qmd-embed` job routes through the resident daemon (`QMD_REMOTE_URL` declared in the plist `EnvironmentVariables`, since launchd does not inherit the interactive shell environment).
- Promote reusable permission grants (tailscale serve, caddy, ssh-keygen fingerprint reads) into the global Claude allowlist, default the permission mode to `acceptEdits`, and disable workflow keyword triggers. by @brettdavies in [#148](https://github.com/brettdavies/dotfiles/pull/148)
- Allow `time ./scripts/generate-changelog.py *` in the global permission allowlist alongside the existing `generate-changelog.sh` grants. by @brettdavies in [#149](https://github.com/brettdavies/dotfiles/pull/149)
- `scripts/stow-deploy` no longer treats `gbrain` as Linux-only: its config deploys on macOS while its systemd indexing units are dropped. by @brettdavies in [#150](https://github.com/brettdavies/dotfiles/pull/150)
- Global gitignore ignores `.pytest_cache/`. by @brettdavies in [#155](https://github.com/brettdavies/dotfiles/pull/155)

### Fixed

- Stop tracking qmd's machine-specific `index.yml` as a stow symlink, which left a permanent dirty working tree on macOS. Collections config now deploys from a per-platform template. by @brettdavies in [#133](https://github.com/brettdavies/dotfiles/pull/133)
- Put Homebrew's Ruby ahead of macOS system Ruby 2.6 on PATH so Bundler satisfies the supply-chain cooldown policy (`>= 4.0.13`). by @brettdavies in [#134](https://github.com/brettdavies/dotfiles/pull/134)
- Fix a Ruby PATH glob that aborted zsh shell startup on hosts with keg-only Homebrew Ruby but no gem binstub directory. by @brettdavies in [#135](https://github.com/brettdavies/dotfiles/pull/135)
- The `svc:ollama` Tailscale service now reaches Ollama from other tailnet nodes. A loopback Caddy proxy rewrites the `Host` header so Ollama's DNS-rebinding check accepts the served request, while Ollama stays bound to loopback only. by @brettdavies in [#139](https://github.com/brettdavies/dotfiles/pull/139)
- Fix `bundle`/`ruby` resolving to macOS system Ruby in login shells by re-asserting keg-only Homebrew Ruby in `~/.zprofile` after `path_helper`. by @brettdavies in [#140](https://github.com/brettdavies/dotfiles/pull/140)
- Stop the `stow-deploy` integration tests from hijacking the live `~` deployment when run from a worktree or second clone (e.g. the pre-push hook inside a worktree). by @brettdavies in [#141](https://github.com/brettdavies/dotfiles/pull/141)
- Stop the changelog / sync / pre-push bats fixtures from mutating the real repo (identity config + stray commits/branches) when their `cd` to a temp dir fails. by @brettdavies in [#142](https://github.com/brettdavies/dotfiles/pull/142)
- Fix `bundle` resolving to macOS system Ruby (Bundler 1.17.2) in bash, cron, and non-login shells; keg-only Homebrew Ruby is now forced ahead of `/usr/bin` so Bundler meets the supply-chain cooldown floor. by @brettdavies in [#151](https://github.com/brettdavies/dotfiles/pull/151)
- Fix `bundle` and `ruby` resolving to macOS system Ruby (Bundler 1.17.2) inside the Claude Code Bash tool; keg-only Homebrew Ruby is now placed ahead of `/usr/bin` so Bundler meets the supply-chain cooldown floor. by @brettdavies in [#154](https://github.com/brettdavies/dotfiles/pull/154)
- `stow-deploy` no longer leaves systemd `--user` timers (`qmd-embed`/`qmd-update`/`qmd-cleanup`) in a failed, unscheduled state after a re-deploy. The deploy now reloads the user manager and restarts the timer units it ships, so a restow can't silently kill the schedule. by @brettdavies in [#157](https://github.com/brettdavies/dotfiles/pull/157)
- `qmd-embed.service` now pins the CUDA GPU backend (`NODE_LLAMA_CPP_GPU=cuda`), so scheduled embedding runs on the GPU instead of silently falling back to CPU through node-llama-cpp's Vulkan prebuilt. by @brettdavies in [#159](https://github.com/brettdavies/dotfiles/pull/159)
- `qmd-embed` caps per-batch work (`--max-docs-per-batch 50 --max-batch-mb 10`) so GPU embedding stays within the VRAM the unit frees, avoiding ggml/CUDA aborts on the shared low-VRAM box.

### Documentation

- Document the one-time Bundler install for the cooldown policy in `BOOTSTRAP.md`. by @brettdavies in [#134](https://github.com/brettdavies/dotfiles/pull/134)
- BOOTSTRAP.md gains a Linux Server Setup section documenting the serve script and the one-time service-host approval step in the admin console. by @brettdavies in [#136](https://github.com/brettdavies/dotfiles/pull/136)
- Add a `CONCEPTS.md` entry defining the "gbrain thin client" host role. by @brettdavies in [#150](https://github.com/brettdavies/dotfiles/pull/150)
- Extend the present-state / no-temporal-narration policy to in-repo prose docs (READMEs, docs, specs, runbooks, plans), with an exception for designated change records (decision-logs, `CHANGELOG`/`RELEASES`, migration records). by @brettdavies in [#153](https://github.com/brettdavies/dotfiles/pull/153)
- Rewrite README to match the current repo: all 34 stow packages (adds caddy, ollama), all 21 shell fragments, the bats.yml workflow with corrected triggers, and the layout tree. by @brettdavies in [#155](https://github.com/brettdavies/dotfiles/pull/155)
- Add Philosophy and Engineering Practices sections to PROJECT.md and refresh its package and fragment inventory.
- Define the shell config chain and bare launcher in CONCEPTS.md.
- Remove backburnered dotfiles-cli references from AGENTS.md, PROJECT.md, and scripts/stow-deploy.
- Restructure `RELEASES.md` into a runbook that cross-links its companions and folds the four post-tag checks into the Tagging section. by @brettdavies in [#156](https://github.com/brettdavies/dotfiles/pull/156)
- Add `RELEASES-RATIONALE.md` documenting the why behind the branching model, PR conventions, triple-diff verification, CHANGELOG generation, CI-side CalVer tagging, and the surgical backport.
- Add `RELEASES-PREFLIGHT.md`, a config-only pre-cut checklist covering repo health, changelog completeness, cross-platform deploy sanity, release mechanics, and the prose floor.

**Full Changelog**: [2026.06.16...2026.06.26](https://github.com/brettdavies/dotfiles/compare/2026.06.16...2026.06.26)

## [2026.06.16]

### Added

- Export `TMUXINATOR_CONFIG` from `config/shell/tmuxinator.sh` so tmuxinator reads and writes the stow source directly,
  no backport step. by @brettdavies in [#109](https://github.com/brettdavies/dotfiles/pull/109)
- Six tmuxinator templates land in the stow package: `birdskill`, `brettdavies`, `homebrew`, `qmd`, `ssite`, `xrskill`.
- `@`-import of `git-and-github.md` in global CLAUDE.md so the git/GitHub workflow rules load in every Claude Code
  session. by @brettdavies in [#111](https://github.com/brettdavies/dotfiles/pull/111)
- `anc-dev` SSH tunnel now forwards the Wrangler dev range, dev registry, Worker inspector, and common dev ports
  (3000/5173/8080). by @brettdavies in [#112](https://github.com/brettdavies/dotfiles/pull/112)
- Supply-chain exception documenting `@main` pins for brettdavies-owned reusable workflows.
- `stow/ollama/` package containing the systemd override drop-in, deploy runbook, and `.stow-local-ignore` exclusion
  list. by @brettdavies in [#113](https://github.com/brettdavies/dotfiles/pull/113)
- `docs/solutions/**` to the markdownlint ignore list. Consumed by every brettdavies repo that copies this template via
  the `github-repo-setup` bootstrap procedure. by @brettdavies in
  [#114](https://github.com/brettdavies/dotfiles/pull/114)
- Adopt the official Codex self-installer (`curl -fsSL https://chatgpt.com/codex/install.sh | sh`) as the supported
  install path; deploys to `~/.local/bin/codex` with `codex update` for self-updating. by @brettdavies in
  [#115](https://github.com/brettdavies/dotfiles/pull/115)
- Add `~/.codex/AGENTS.md` (stowed) as a cross-package symlink to `~/.claude/CLAUDE.md` so codex picks up the same
  global agent rules as Claude Code.
- Add the `gbrain` MCP server to codex via `mcp_servers.gbrain`, mirroring the Claude config.
- Define `Cross-package symlink` in `CONCEPTS.md` so future docs and PRs can cite the pattern without redefinition. by
  @brettdavies in [#116](https://github.com/brettdavies/dotfiles/pull/116)
- `tmux-prune-orphans.timer` systemd user timer (fires at 02:15 local) that sweeps orphan tmux clients whose controlling
  terminal died. by @brettdavies in [#117](https://github.com/brettdavies/dotfiles/pull/117)
- `client-detached` hook in `tmux.conf` invoking the same prune script on every client disconnect.
- New `tools-atime` script under `scripts/tools-atime/` that ranks installed CLI tools across brew, uv, cargo, bun, and
  caches by last-used time and disk footprint. by @brettdavies in
  [#119](https://github.com/brettdavies/dotfiles/pull/119)
- `--inspect <target>` drill-down for `uv-cache`, `bun-cache`, `brew/<formula>`, `uv/<tool>`, `cargo/<crate>`, and
  `bun/<pkg>`. uv-cache reports TOTAL and FREEABLE per archive so the user sees honest disk-reclaim potential.
- `--reclaim` guided interactive cleanup mode that walks top reclaim candidates, prompts per row with a manager-specific
  action menu, and dispatches to the right PM subcommand. Dry-run by default; `--apply` executes.
- Auto-loaded `## Voice notes` section in global `CLAUDE.md` pointing the agent at
  `~/dev/brettdavies/brettdavies/.context/voice.md` for drafting prose in Brett's voice, with an explicit register split
  (heavy on conversational surfaces, light on technical artifacts). by @brettdavies in
  [#120](https://github.com/brettdavies/dotfiles/pull/120)
- Voice-match instruction paired with `/unslop` in step 2 of the "Authoring GitHub correspondence" workflow in
  `guides/git-and-github.md`, so deterministic scrubbing and voice-matching happen in the same pass.
- Stow package `gbrain`: systemd user units for `gbrain sync` (every 15m) and `gbrain dream` (nightly 02:00),
  Linux-only. by @brettdavies in [#121](https://github.com/brettdavies/dotfiles/pull/121)
- Stow package `codex-proxy`: oneshot systemd user unit that brings up the docker-compose codex-proxy stack so paid LLM
  traffic bills against corp ChatGPT credits, Linux-only.
- `LITELLM_API_KEY` env var exported from `stow/secrets/dot-secrets`, sourced at shell init from the `secrets-dev`
  1Password vault.
- `LITELLM_BASE_URL` env var (`http://localhost:8080/v1`) exported from `config/shell/litellm.sh`.
- `stow/codex/dot-codex/config.toml` is git-crypt encrypted at rest. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- Trust entries in codex config for `~` and `~/dotfiles`.
- New `claude-code-archive` systemd timer (every 30 min) that converts Claude Code session jsonl to redacted markdown
  under `~/.gbrain/transcripts/claude-code/`. Idempotent and corpus-permanent; survives Claude Code's 30-day eviction
  window. by @brettdavies in [#123](https://github.com/brettdavies/dotfiles/pull/123)
- New `claude-code-sessions` qmd collection, default-excluded from `qmd query` results. Reach raw transcripts with `qmd
  query -c claude-code-sessions "<phrase>"`.
- New `claude-code-synthesize-sweep.sh` script for hand-rolled `gbrain dream --phase synthesize` backfill over the
  corpus. Ships ready; the user invokes manually with cost-monitoring via the existing
  `~/.gbrain/audit/dream-budget-*.jsonl` ledger. `--dry-run` and `-h/--help` are safe no-cost paths.
- New `~/.config/qmd/index.yml` adopted into stow management (`stow/qmd/dot-config/qmd/`), where it was previously a
  plain unversioned file.
- New `subagent-to-md.py` converter for the subagent jsonl shape that `cc2md` doesn't understand (different fields:
  `agentId`, `parentUuid`, `entrypoint`). Output mirrors cc2md's markdown so the corpus stays uniform for qmd and
  synthesize. by @brettdavies in [#124](https://github.com/brettdavies/dotfiles/pull/124)
- `claude-code-archive.sh` now walks `~/.claude/projects/**/subagents/agent-*.jsonl` in addition to cc2md's top-level
  session list. Brings the corpus to ~1156 transcripts (was ~256).
- New SessionEnd hook `~/.claude/claude-code-archive.sh` fires the archive on session close. Defensive schema: tries
  `.transcript_path`, falls back to `.session_id` filesystem walk. Fire-and-forget, always exits 0.
- `stow/gbrain/dot-gbrain/config.json` (git-crypt encrypted) and `stow/gbrain/dot-gbrain/preferences.json` (plain).
  `scripts/stow-deploy gbrain` symlinks them to `~/.gbrain/`. by @brettdavies in
  [#126](https://github.com/brettdavies/dotfiles/pull/126)
- uv install-time malware check: every sync queries OSV for known-malware advisories against the locked resolution and
  aborts before a matched package's code runs. Enabled when uv >= 0.11.16 is installed; bypass a single run with
  `UV_MALWARE_CHECK=0`. by @brettdavies in [#127](https://github.com/brettdavies/dotfiles/pull/127)
- `scripts/sync-dev-after-release.sh`: post-release backport that surgically copies `CHANGELOG.md` from `origin/main`
  and opens a PR to `dev`, so dev's changelog stops drifting behind released history. CalVer-validated
  (`YYYY.MM.DD[.N]`), idempotent, with preflight guards on tag existence, main reachability, and GitHub Release publish
  state. by @brettdavies in [#128](https://github.com/brettdavies/dotfiles/pull/128)
- `scripts/generate-changelog.py`: vendored git-cliff + PR-body changelog generator with CalVer release-branch detection
  and a `--print-tag` helper.

### Changed

- Rename `homebrewcore.yml` to `hbcore.yml` and `homebrewtap.yml` to `hbtap.yml`. Drop standalone `homebrew.yml`. by
  @brettdavies in [#109](https://github.com/brettdavies/dotfiles/pull/109)
- Humanize every `name:` field (`ANC CLI`, `HB Core`, `Agent Skills`, etc.).
- CLAUDE.md preamble calls out `git-and-github.md` as the one auto-loaded guide. by @brettdavies in
  [#111](https://github.com/brettdavies/dotfiles/pull/111)
- Resolution-time cooldown section documents per-tool native support (Bundler, uv, pip, npm, pnpm, yarn, bun) and tools
  without it (cargo, Homebrew, Go modules), pointing at `config/shell/supply-chain.sh`. by @brettdavies in
  [#112](https://github.com/brettdavies/dotfiles/pull/112)
- `docs/solutions/` symlink recreate command uses an absolute `$HOME` path for portability across repo depths.
- ollama systemd unit binds to `127.0.0.1:11434` (loopback only) instead of `0.0.0.0:11434` (all interfaces). LAN
  clients and tailnet peers can no longer reach the raw API by IP; intentional reach paths are loopback, the
  `svc:ollama` Tailscale Serve service, and a per-stack docker socat sidecar. by @brettdavies in
  [#113](https://github.com/brettdavies/dotfiles/pull/113)
- Canonical version bumped `2026.04.15` to `2026.06.09`. by @brettdavies in
  [#114](https://github.com/brettdavies/dotfiles/pull/114)
- Expand `~/.codex/config.toml` with `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`,
  `model_reasoning_summary = "auto"`, `web_search = "live"`, and `features.memories = true`. by @brettdavies in
  [#115](https://github.com/brettdavies/dotfiles/pull/115)
- Negate the global `~/.config/git/ignore` block on `AGENTS.md` for the single stow source path
  `stow/codex/dot-codex/AGENTS.md` so the stowed agent rules can be committed.
- Ollama service now keeps up to 4 models hot in VRAM. Reduces evict-and-reload thrash when routing across embedding,
  chat, and codegen models in quick succession. by @brettdavies in
  [#118](https://github.com/brettdavies/dotfiles/pull/118)
- `.claude/settings.local.json` allowlists `Bash(gbrain *)` and the gbrain MCP read-side tools (`whoami`,
  `get_brain_identity`, `get_stats`, `list_jobs`) so headless cycles don't prompt. by @brettdavies in
  [#121](https://github.com/brettdavies/dotfiles/pull/121)
- `stow/codex/dot-codex/config.toml` trusts `~/gbrain` so the codex CLI runs unattended for headless dream cycles.
- gbrain allowlist (`Bash(gbrain *)` and four `mcp__gbrain__*` MCP entries) moved from project-local
  `.claude/settings.local.json` to user-global `~/.claude/settings.json`. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- `gbrain` now reads `dream.synthesize.session_corpus_dir = ~/.gbrain/transcripts/claude-code/`. Nightly
  `gbrain-dream.timer` picks up new transcripts automatically (12h synth cooldown still applies on the corpus-scan
  path). by @brettdavies in [#123](https://github.com/brettdavies/dotfiles/pull/123)
- `emit_discovered` audit event now carries a `source` field (`top_level` or `subagents`) so the two sweep passes can be
  counted separately without re-derivation. by @brettdavies in [#124](https://github.com/brettdavies/dotfiles/pull/124)
- Pre-push hook now skips shellcheck + bats when every changed file in the push is `.md`. git-lfs still runs in all
  cases. by @brettdavies in [#125](https://github.com/brettdavies/dotfiles/pull/125)

### Fixed

- Align `on_project_first_start` resize-pane targets with each project's `name:` field, including quoting for names that
  contain spaces. Corrects both the new renames and pre-existing copy-paste targets that pointed at the wrong session.
  by @brettdavies in [#109](https://github.com/brettdavies/dotfiles/pull/109)
- Removed plaintext `OPENAI_API_KEY` literal from `stow/secrets/dot-secrets`. git-crypt protects the file at rest, but
  the inline export was still a leak path for anyone with the git-crypt key. Slot is preserved as a commented
  placeholder so callsites that previously read `$OPENAI_API_KEY` migrate to `$LITELLM_API_KEY` against the local proxy.
  by @brettdavies in [#121](https://github.com/brettdavies/dotfiles/pull/121)
- Shell startup tests in `tests/shell-config.bats` no longer fail. Interactive zsh/bash and non-interactive zsh are back
  under their respective 500ms/200ms budgets. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- Release runbook pointed at `~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh`, which no longer exists;
  the changelog step was unrunnable as written. by @brettdavies in
  [#128](https://github.com/brettdavies/dotfiles/pull/128)

### Documentation

- Global PR template comment under `## Changelog` names `generate-changelog.py` as the script that parses the
  categorized bullets at release time. by @brettdavies in [#110](https://github.com/brettdavies/dotfiles/pull/110)
- `OLLAMA_MAX_LOADED_MODELS=4` comment expanded with VRAM math and eviction semantics. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- `RELEASES.md` now documents the post-release backport-to-dev step and drops the stale "dev is untouched" claim. by
  @brettdavies in [#128](https://github.com/brettdavies/dotfiles/pull/128)

**Full Changelog**: [2026.06.03...2026.06.16](https://github.com/brettdavies/dotfiles/compare/2026.06.03...2026.06.16)

## [2026.06.03]

### Added

- Cross-platform `stow/qmd` package: stowing `qmd` now works on both macOS and Linux with the right backend dispatched
  per OS. by @brettdavies in [#87](https://github.com/brettdavies/dotfiles/pull/87)
- `STOW_FLAGS+=(--ignore='\.DS_Store$')` in `scripts/stow-deploy` (always): suppresses macOS Finder turds across every
  package on both OSes.
- `STOW_FLAGS+=(--ignore='\.(service|timer)$')` in `scripts/stow-deploy` (macOS only): skips Linux systemd unit files
  that share packages with cross-platform content.
- Per-platform "read PDF" opener for selectable, searchable PDF text. Pressing `o` on a PDF opens Preview.app on macOS
  or `pdftotext` extracted into micro on Linux. by @brettdavies in
  [#89](https://github.com/brettdavies/dotfiles/pull/89)
- `y` shell wrapper (bash + zsh) that cds the parent shell to yazi's last directory on quit. Adopted in all 16
  tmuxinator session configs and the `tmux-new-session` template, with a silent fallback to plain `yazi`.
- git.yazi plugin with plain-letter status signs (M / A / D / U / ? / !) as a linemode column, computed via two
  prepend_fetchers in yazi.toml and registered in a new `init.lua`.
- Brewfile entries for `yazi`, `glow`, `poppler`, `resvg`, `imagemagick`, and `sevenzip` so `brew bundle` provisions a
  complete yazi preview pipeline on a fresh machine: text extraction, markdown rendering, SVG rasterization,
  AVIF/HEIC/JXL decoding, font sample rendering, and archive contents listing.
- `defuddle` to the Brewfile under a new web-content-extraction comment block. Fresh `brew bundle` machines now
  provision defuddle on PATH with zero per-call resolve cost. by @brettdavies in
  [#90](https://github.com/brettdavies/dotfiles/pull/90)
- `Bash(defuddle:*)` allow-list entry on the caam streams profile alongside the existing `Bash(bunx defuddle:*)`
  fallback.
- New SSH host entry that tunnels `localhost:8787` to a remote wrangler dev server via Tailscale. `ExitOnForwardFailure
  yes` makes a local port collision fail loudly instead of silently dropping into a shell with no tunnel. by
  @brettdavies in [#93](https://github.com/brettdavies/dotfiles/pull/93)
- New `uuidv7` CLI helper at `~/.local/bin/uuidv7` (three-line `python3.14` script around `uuid.uuid7()`) for generating
  time-ordered, collision-proof IDs for tmp-file naming and similar one-off needs. by @brettdavies in
  [#94](https://github.com/brettdavies/dotfiles/pull/94)
- `lt_check` shell function at `~/dotfiles/config/shell/languagetool.sh`. Parallel grammar-check workhorse with category
  whitelist, 10-rule baseline denylist, byte-offset-to-line approximation, and graceful skip when LanguageTool is
  unreachable. Exit codes: 0 (clean) / 1 (blocking) / 2 (unreachable, stderr notice) / 3 (usage). by @brettdavies in
  [#95](https://github.com/brettdavies/dotfiles/pull/95)
- `lt_info`, `lt_languages`, `lt_rules`, `lt_categories` query helpers for inspecting the LT server and the active
  override surface.
- `LT_DENY_RULES_BASELINE` constant for repo-specific extensions:
  `LT_DENY_RULES="${LT_DENY_RULES_BASELINE}|EXTRA_RULE"`.
- New `config/shell/build-flags.sh` and `config/shell/run-flags.sh` that set `-march=native -O3 -pipe` CFLAGS/CXXFLAGS
  plus runtime env defaults for local compilation on Linux hosts. macOS toolchains skip these (handled by Xcode/brew).
  by @brettdavies in [#98](https://github.com/brettdavies/dotfiles/pull/98)
- New `scripts/qmd-llama-rebuild.sh` to rebuild `node-llama-cpp` from source with the host's CPU/GPU flags, plus a
  runbook callout pointing at it.
- Allow `curl -sS http://127.0.0.1:7832/health` in the local Claude allowlist for qmd-serve liveness probes. by
  @brettdavies in [#99](https://github.com/brettdavies/dotfiles/pull/99)
- `scripts/playwright-deps-deploy.sh`: provisions browser launch on Linux. Always deploys the Chromium AppArmor userns
  profile plus a boot unit that survives reboots, and installs heavy Chromium/WebKit system libraries only when
  explicitly requested. by @brettdavies in [#100](https://github.com/brettdavies/dotfiles/pull/100)
- `apparmor-playwright.service`: boot unit that reloads the Chromium userns profile at boot, because Ubuntu's
  `apparmor.service` is skipped on minimized server images.
- `UserPromptSubmit` hook (`solutions-prefetch.sh`): on debugging-flavored prompts, reminds you to query
  `docs/solutions` before investigating. Reminder-only, fail-open, no qmd call. by @brettdavies in
  [#101](https://github.com/brettdavies/dotfiles/pull/101)
- Grant Claude Code Read/Edit/Write on `/tmp/**` via `permissions.additionalDirectories`, unblocking the collision-proof
  `/tmp/` commit/PR/release body workflow without per-call permission prompts. by @brettdavies in
  [#103](https://github.com/brettdavies/dotfiles/pull/103)
- Add `op-skill-nudge.sh` PreToolUse/Bash hook so secret-handling commands trigger the 1Password skill helper before
  execution.
- New "Resolution-time aging window (cooldown)" section in `supply-chain-pinning.md` covering Bundler 4.0.13+
  `cooldown`, uv `exclude-newer`, pnpm `minimumReleaseAge`, and the per-tool emergency-bypass flags. Notes that npm and
  bun have no native equivalent. by @brettdavies in [#104](https://github.com/brettdavies/dotfiles/pull/104)
- `CONCEPTS.md` at repo root: 9-entry glossary in 4 clusters (Hosts, Packages, System configuration, Policies). Names
  the project-specific terms a new engineer needs defined to follow conversations, tickets, or code in this repo. by
  @brettdavies in [#105](https://github.com/brettdavies/dotfiles/pull/105)
- AGENTS.md `## Reference` section: one-line entry pointing at `CONCEPTS.md` so agents and collaborators discover the
  shared vocabulary alongside `docs/solutions/`.

### Changed

- `stow/qmd/dot-local/bin/qmd` is now an OS-aware dispatcher (`case "$(uname -s)"` → `~/dev/qmd/qmd` on Linux,
  `~/.cache/bun/bin/qmd` on macOS). by @brettdavies in [#87](https://github.com/brettdavies/dotfiles/pull/87)
- Linux-only qmd artifacts (7 systemd `.service`/`.timer` units + the `qmd-ollama-unload-all` helper) moved from
  `stow/qmd/` into `stow/local/`.
- `qmd` removed from the Linux-only skip case in `scripts/stow-deploy` (the package is now cross-platform).
- WebFetch-intercept hook (`stow/claude/dot-claude/defuddle-webfetch.sh`) redirects to `defuddle parse <url>` instead of
  `bunx defuddle parse <url>`. by @brettdavies in [#90](https://github.com/brettdavies/dotfiles/pull/90)
- `gh` wrapper's pr-merge-to-main block: second line now reads "Ask the human to perform the merge; the PR body is used
  as the squash commit message" (was: "Please provide a ready-to-paste squash merge commit message").
- Rename `QMD_SERVER` env var to `QMD_REMOTE_URL` and `qmd serve --sequential` flag to `qmd serve --low-vram`, matching
  the upstream qmd fork. Anyone with a manual `export QMD_SERVER=…` elsewhere needs to switch to `QMD_REMOTE_URL`. by
  @brettdavies in [#92](https://github.com/brettdavies/dotfiles/pull/92)
- GitHub-correspondence workflow in CLAUDE.md now requires collision-proof tmp-file names:
  `/tmp/pr-body-<repo>.<branch>.md` for PR-scoped artifacts and `/tmp/<kind>-$(uuidv7).md` for everything else. Step 3
  also now requires `trash <path>` after a successful `gh` or `git commit` call. by @brettdavies in
  [#94](https://github.com/brettdavies/dotfiles/pull/94)
- `stow/claude/dot-claude/heredoc-pr-guard.sh` deny reasons now point at `~/.claude/CLAUDE.md § "Authoring GitHub
  correspondence: /tmp/ + --body-file + /unslop"` and show the canonical filename per artifact class
  (`/tmp/pr-body-<repo>.<branch>.md`, `/tmp/commit-msg-$(uuidv7).md`, etc.). by @brettdavies in
  [#95](https://github.com/brettdavies/dotfiles/pull/95)
- `stow/local/dot-config/systemd/user/qmd-serve.service` now sets `Environment=NODE_LLAMA_CPP_GPU=cuda`, pinning the
  backend so the daemon survives NVIDIA driver branch upgrades. by @brettdavies in
  [#98](https://github.com/brettdavies/dotfiles/pull/98)
- Tighten PR body rules: summaries describe the net diff vs the base branch; triple-diff stats, leak-check output,
  patch-id counts, pre-push gate results, CI status, prose-scrub findings, and exclusion rationale stay out of the body.
  by @brettdavies in [#99](https://github.com/brettdavies/dotfiles/pull/99)
- CLAUDE.md "Query solutions first" rule now explicitly covers `/investigate` and other gstack debugging skills, and
  extends the qmd-learnings-researcher dispatch to them. by @brettdavies in
  [#101](https://github.com/brettdavies/dotfiles/pull/101)
- Restructure the global `CLAUDE.md` into a progressive-disclosure layout: a slim always-on index plus seven on-demand
  topic guides under `~/.claude/guides/` (cli-tools, code-comments, git-and-github, local-only-files,
  supply-chain-pinning, workflows-and-skills, writing-safety). Reduces always-on context while preserving every rule;
  detail loads with Read only when the relevant task runs. by @brettdavies in
  [#102](https://github.com/brettdavies/dotfiles/pull/102)
- Strengthen CI watch policy (`CLAUDE.md` + `ci-watch-prompt.sh` header): a completed watcher is not a green watcher.
  After every completion notification, re-query `gh pr view --json statusCheckRollup,mergeStateStatus` (or `gh run view
  --json conclusion`) and assert every conclusion is `SUCCESS`. by @brettdavies in
  [#103](https://github.com/brettdavies/dotfiles/pull/103)
- Expand chain-discovery rule to cover cross-repo `repository_dispatch` flows (e.g. agentnative-cli release →
  brettdavies/homebrew-tap → callback to agentnative-cli finalize-release). Both repos must be watched and re-queried
  until they quiesce.
- Pin `autoUpdatesChannel: "stable"`, `enableWorkflows: false`, `workflowKeywordTriggerEnabled: false`; bump
  `effortLevel` from `high` to `xhigh`.
- Relocate `skillOverrides` from the trailing block to immediately after `permissions` (content unchanged).

### Fixed

- The PostToolUse `ci-watch-prompt.sh` hook now retries `gh run list` up to 5 times with a 2 s delay between attempts.
  Previously the hook queried once with a 2 s lead-in, which lost the race against GitHub's API surfacing
  newly-triggered runs (especially after `gh pr create`) and silently exited without emitting the watch reminder. by
  @brettdavies in [#87](https://github.com/brettdavies/dotfiles/pull/87)
- 3-pane tmuxinator sessions (`mux start <name>` / `tmuxinator start <name>`) now resize to the documented 33% yazi /
  67% shell / 33% lazygit layout when launched from a bare shell, not only from inside an existing tmux session. by
  @brettdavies in [#88](https://github.com/brettdavies/dotfiles/pull/88)
- Yazi 26.x no longer prints TOML parse errors at startup for the stowed yazi, theme, and keymap configs. Editor schema
  tooling continues to work via the Taplo `#:schema` directive. by @brettdavies in
  [#89](https://github.com/brettdavies/dotfiles/pull/89)
- Yazi image preview (PNG, JPEG, etc.) now renders inside tmux on macOS with Ghostty. Previously the panel was blank
  because tmux stripped the Kitty graphics escape sequences yazi emits.
- Yazi SVG, AVIF / HEIC / JXL, font, and archive previews now render via the corresponding built-in previewers plus
  their newly-tracked external tools.
- `y()` yazi wrapper rejects malformed `--cwd-file` output via an `[ -d "$cwd" ]` guard, matching yazi's upstream
  canonical pattern. Function doc-comment now states the actual yazi defaults (`q` writes cwd-file; `Q` does not). by
  @brettdavies in [#90](https://github.com/brettdavies/dotfiles/pull/90)
- Stop emitting `npm warn Unknown env config "minimum-release-age"` on every `npm` invocation. The pnpm-only env var is
  now exported only when pnpm is on PATH, and the npm-only env var is gated on `npm --version` being 11.10.0 or newer.
  by @brettdavies in [#91](https://github.com/brettdavies/dotfiles/pull/91)
- `qmd-serve` queries no longer fall back to slow Vulkan inference. Verified end-to-end after a 570 → 580 driver swap on
  the dev box: expand query 25.3s → 2.7s, rerank 40 chunks 31.1s → 1.9s, total cold query 114s → 12.4s (≈9-16x). by
  @brettdavies in [#98](https://github.com/brettdavies/dotfiles/pull/98)

### Documentation

- New: `docs/solutions/architecture-patterns/cross-platform-stow-package-gating-2026-05-17.md` documenting the
  package-level vs file-level OS gating decision framework, the file-extension-regex rationale (stow 2.4.1's `--ignore`
  matches file basenames not directory names), and adjacent gotchas (bun global cache purge silently uninstalls
  binaries; macOS Finder `.DS_Store` proliferation). by @brettdavies in
  [#87](https://github.com/brettdavies/dotfiles/pull/87)
- Refreshed: `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md` and
  `docs/solutions/architecture-patterns/stow-dotfiles-architecture-and-failure-modes-2026-04-20.md` to incorporate the
  new gating tier in their failure-mode maps, hardened-defaults lists, and reference sections.
- `AGENTS.md` Reference section gains a link to the new architecture-patterns doc.
- New "Code Comments" policy section in CLAUDE.md codifying the WHY-only standard, hard bans, allowed external refs, and
  language-specific overrides for public surface area. by @brettdavies in
  [#94](https://github.com/brettdavies/dotfiles/pull/94)
- New paragraph in `AGENTS.md § Shell Config Chain` titled "External scripts that need a helper must source it
  explicitly". It documents that non-login bash scripts (git hooks, CI, `bash scripts/foo.sh`) read no startup files, so
  they must source helpers with the `DOTFILES_SHELL_DIR` fallback pattern. by @brettdavies in
  [#95](https://github.com/brettdavies/dotfiles/pull/95)
- Add explicit anti-pattern note to `CLAUDE.md`: don't write the tmp commit/PR-body path to a sidecar file and re-read
  it later. Re-paste the literal path in each Bash call, or recompute it deterministically. Rule applies to any sidecar
  filename. Picking a different name doesn't make it safe. by @brettdavies in
  [#96](https://github.com/brettdavies/dotfiles/pull/96)
- `docs/runbooks/headless-gpu-server-nvidia-driver.md` gains a DKMS-migration section and an A.6 post-migration GPU
  consumer verification step, capturing what was learned during the diagnostic cycle. by @brettdavies in
  [#98](https://github.com/brettdavies/dotfiles/pull/98)
- Runbook for diagnosing `browse` and Playwright browser-launch failures on Linux: sandbox `Permission denied` (profile
  not loaded) versus missing WebKit dependencies. by @brettdavies in
  [#100](https://github.com/brettdavies/dotfiles/pull/100)
- Add `docs/progressive-disclosure-evals.md`: a six-eval harness verifying fetch-on-demand and prohibition-floor
  behavior, with a validity gate noting the suite must run from a fresh `claude` process. by @brettdavies in
  [#102](https://github.com/brettdavies/dotfiles/pull/102)
- `RELEASES.md § PRs and changelog generation`: add the rule that release PR bodies use one logical line per bullet and
  paragraph (GitHub soft-wraps), and that bullets copied from `CHANGELOG.md` must be unwrapped first because the source
  content is pre-wrapped at the repo's MD013 limit. by @brettdavies in
  [#107](https://github.com/brettdavies/dotfiles/pull/107)

**Full Changelog**: [2026.05.16...2026.06.03](https://github.com/brettdavies/dotfiles/compare/2026.05.16...2026.06.03)

## [2026.05.16]

### Added

- Rectangle window manager (macOS): keyboard hotkeys for snap/resize, size-cycling on repeated arrow presses, flush
  borders, no margins. Run `scripts/rectangle-defaults.sh` after first-launch Accessibility grant. by @brettdavies in
  [#70](https://github.com/brettdavies/dotfiles/pull/70)
- ⌃⌥C triggers `centerHalf` with cycling (1/2 → 2/3 → 1/3 centered vertical column on repeated presses), replacing the
  default translate-only `center` action.
- macOS LaunchAgents for the qmd knowledge-base index: `com.user.qmd-update`, `com.user.qmd-embed`, and
  `com.user.qmd-cleanup`. Schedule, logs, and bootstrap match the Linux systemd setup so the laptop and server keep
  their indexes maintained the same way. by @brettdavies in [#71](https://github.com/brettdavies/dotfiles/pull/71)
- `scripts/qmd-launchd-enable.sh` idempotent bootstrap script (run once on macOS after `stow-deploy --all`).
- Install `rtk` via brew so the PreToolUse Bash hook from PR #62 (rewrites `git`, `cargo`, `gh`, `pytest`, `docker`, …
  through `rtk` for 60-90% token compression) actually runs on macOS. Linux bottles ship in the same formula, so this
  benefits headless servers too.
- PreToolUse Bash hook (`stow/claude/dot-claude/heredoc-pr-guard.sh`) that blocks heredoc piped into `--body`,
  `--notes`, or `-m` flags on `gh pr`, `gh issue`, `gh release`, and `git commit` commands. Allows every other heredoc
  use. Returns a deny JSON with a message pointing at the correct `--body-file` / `--notes-file` / `--file` workflow. by
  @brettdavies in [#75](https://github.com/brettdavies/dotfiles/pull/75)
- 41-case bats test suite (`tests/heredoc-pr-guard.bats`) covering positive deny cases, negative allow cases, and 13
  red-team adversarial bypass attempts (indent-stripping `<<-EOF`, unusual heredoc markers, extra whitespace, subshell
  wrapping, chained commands, prepended env vars, `--body=value` equals form, quoted markers, request-changes reviews,
  line-continuation backslash, `bash -c` wrapper).
- New section in `stow/claude/dot-claude/CLAUDE.md`: "Personal paths and machine names: relative or generic in all
  written artifacts". Sits directly after the existing "Secrets and identifiers" section (same theme of privacy at the
  echo boundary, distinct category). by @brettdavies in [#77](https://github.com/brettdavies/dotfiles/pull/77)
- pnpm and yarn supply-chain age-gate env vars in `config/shell/supply-chain.sh`, enforcing a 7-day floor on installed
  packages to mirror the existing npm/bun/uv/pip controls. by @brettdavies in
  [#78](https://github.com/brettdavies/dotfiles/pull/78)
- New global ALLOW patterns at `stow/claude/dot-claude/settings.json`: lint/dev tools (actionlint, shellcheck, vale,
  rtk), 1password skill helpers (`~/.claude/skills/1password/scripts/*`), github-repo-setup repo-settings.sh report,
  unslop score.py, user-wide Read paths under `//home/brett/{,dev/,dev/solutions-docs/,.claude/,dotfiles/}**` and
  `//usr/bin/**`, WebFetch domains (github.com, docs.rs, crates.io, raw.githubusercontent.com,
  developers.cloudflare.com, rust-cli.github.io), Skill calls (plan-eng-review, unslop, defuddle), MCP wildcards
  (`mcp__plugin_cloudflare_*`, `mcp__plugin_compound-engineering_context7__*`, `mcp__plugin_context7_context7__*`). by
  @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- New global ASK carveouts: `Bash(gh pr create *)`, `Bash(gh pr edit *)`, `Bash(gh pr merge *)`, `Bash(gh repo create
  *)`, `Bash(op item *)`. These mutate shared state or read 1Password secrets and now prompt despite the broader
  `Bash(gh:*)` and op CLI presence in allow (deny→ask→allow precedence ensures ask wins).
- Tailscale skill enabled in this repo via `skillOverrides.tailscale = "on"` in `.claude/settings.local.json`.
- 23 Bash CLI tools to global ALLOW: bun add/x, defuddle, flatpak list, kill, magick, npm view, ollama list/ps/stop,
  pdfimages, pdftocairo, pgrep, rclone, sha256sum, snap list, trash-list, tsc, ty check, unzip, wrangler. by
  @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)
- 18 skill helper scripts to global ALLOW: 1password (create_item, edit_item, list_tags), bird, clip, docker-engine
  (docker-doctor, journal-tail, sg-docker.sh), gstack (4 entries), hb-verify, rust-new-repo, tailscale, x-api, plus
  ~/.claude/{md-align-tables.py, rust-ci-check.sh}.
- 9 Skill() entries to global ALLOW: browse, clip, ce-sessions, design-review, document-release, impeccable,
  office-hours, pdf-generator, qmd.
- 11 WebFetch domains to global ALLOW: arxiv.org, devcommunity/developer/docs.x.com, docs.brew.sh, docs.nvidia.com,
  gist.github.com, lib.rs, pandoc.org, sqlite.org, users.rust-lang.org.
- 4 Read paths to global ALLOW: ~/.gstack/projects/**, ~/github/**, /etc/systemd/system/**,
  /home/linuxbrew/.linuxbrew/share/bash-completion/completions/**.
- 19 ASK carveouts: killall:*and pkill:* (process-pattern killers; ASK so user can override per call), sg docker *(was
  bypassing the docker:* ASK), 11 wrangler destructive subcommands (delete, secret delete, kv key/namespace delete, r2
  object/bucket delete, d1 delete/execute, hyperdrive/queues/workflows delete), 5 rclone destructive (delete,
  deletefile, purge, sync, bisync --resync). Per the verified deny→ask→allow precedence, these narrow ASK entries
  override the broader Bash(wrangler:*) and Bash(rclone:*) ALLOWs.
- Micro keybinding: Alt-i toggles overwrite mode (separate concern bundled as a passenger commit).
- `snapshots/tailscale/`: encrypted reference snapshot of the tailnet's ACL, services list, and per-host `tailscale
  serve` configs after the Taildrive + Services rollout. Refresh recipe in the snapshot README. by @brettdavies in
  [#84](https://github.com/brettdavies/dotfiles/pull/84)
- `taildrive-mount` and `taildrive-unmount` shell functions (macOS only). `taildrive-mount` calls `osascript -e 'mount
  volume ...'` for each share so Finder's SUID helper handles the `/Volumes` mkdir that direct `mount_webdav` from a
  user shell cannot. The share list lives in `$TAILDRIVE_SHARES`, exported from `~/.secrets` (git-crypt encrypted) so no
  host identifiers land in plaintext in this public repo.

### Changed

- BOOTSTRAP.md "oh-my-zsh" section: removed obsolete macOS/Linux split for plugin install. `brew bundle` handles
  `zsh-autosuggestions`, `zsh-syntax-highlighting`, and `zsh-completions` on both platforms; `.zshrc` sources them
  directly. Only `powerlevel10k` (theme, not plugin) still needs a manual symlink. by @brettdavies in
  [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Normalize `qmd-update.service`'s `Environment="PATH=..."` (quoted) to unquoted `Environment=PATH=...`, matching the
  format used by every other unit. Semantically identical, since quoting only matters when the value contains
  whitespace. by @brettdavies in [#74](https://github.com/brettdavies/dotfiles/pull/74)
- `stow/claude/dot-claude/CLAUDE.md` "Pull Requests" section reorganized as "Authoring GitHub correspondence".
  Three-step workflow now applies to every server-side artifact: author in `/tmp/`, run `/unslop` (mandatory), submit
  via the file-flag variant. The "Heredoc escape rule" backstop is replaced by an explicit "Enforcement" section
  pointing at the new hook. by @brettdavies in [#75](https://github.com/brettdavies/dotfiles/pull/75)
- `stow/claude/dot-claude/settings.json` adds the hook to `PreToolUse.Bash`, running before the `rtk hook claude` entry
  so the deny decision fires before any rewrite.
- The existing Cloudflare-token example in "Secrets and identifiers" referenced an internal hostname in the 1Password
  entry name. Updated to a generic `(<server>)` placeholder, consistent with the new rule. by @brettdavies in
  [#77](https://github.com/brettdavies/dotfiles/pull/77)
- RELEASES.md: PR-body discipline rule. Bodies are user-facing substance only; no workflow recaps, no verification
  artifacts. by @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- `.claude/settings.local.json` allow array alphabetized as a side-effect of the audit script's union pass; same content
  otherwise.
- SSH config now routes the three Tailscale-enabled host aliases via Tailscale SSH by default (port 22, FQDN, node
  identity), with a Match-driven override to LAN sshd when this Mac has a `<lan-subnet>.x` IP. Off-LAN: no SSH key
  needed. On-LAN: direct LAN path retained for speed. by @brettdavies in
  [#80](https://github.com/brettdavies/dotfiles/pull/80)
- One host's previously-inlined `tmux new -A -s main` RemoteCommand was removed. Auto-tmux on SSH connect is now opt-in
  per session, not config-default.
- killall:*moved from DENY to ASK. Reason: user does invoke killall periodically for legitimate process-cleanup;
  outright deny was too strict. ASK preserves the friction without blocking. Bash(kill:*) (PID-targeted, lower risk)
  stays in ALLOW. by @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)

### Fixed

- Repair PATH ordering on macOS login shells so `/opt/homebrew/bin` and `/opt/homebrew/sbin` precede `/usr/bin` (was
  being clobbered by Apple's `/etc/zprofile` running `path_helper -s` after `.profile` set up PATH). by @brettdavies in
  [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Eliminate PATH duplication on shell startup by adding a sentinel guard to `.zshrc`'s `.profile` re-source (matches the
  pattern in `.bashrc` and `.zshenv`) and dedupe checks to `local-paths.sh` and `lm-studio.sh`.
- Stop oh-my-zsh `plugin not found` warnings by sourcing `zsh-autosuggestions` and `zsh-syntax-highlighting` directly
  from `$HOMEBREW_PREFIX/share/` (Homebrew's documented integration) instead of declaring them in `plugins=(...)` where
  omz's detection fails on brew's layout.
- Add `Environment=PATH=...` to four user systemd units that were relying on inherited PATH or internal full-path
  workarounds. Affects `qmd-cleanup`, `box-bisync`, `obsidian`, and `opendataloader-pdf`. Lets the wrapped scripts find
  brew-installed tools (`rclone`, `git`, coreutils, etc.) without hardcoded `/home/linuxbrew/.linuxbrew/bin/...`
  fallbacks. by @brettdavies in [#74](https://github.com/brettdavies/dotfiles/pull/74)
- bats: `tests/stow-deploy-packages.bats` no longer fails on Linux when asserting explicit-arg expansion through
  `ghostty` (a macOS-only DESKTOP package). by @brettdavies in [#78](https://github.com/brettdavies/dotfiles/pull/78)
- bats: `tests/qmd-serve.bats` assertions for `qmd-update.service` and `qmd-cleanup.service` now match the post-PR-#74
  unit files (Environment=PATH=/home/linuxbrew/.linuxbrew/bin:... for brew tool resolution).
- Removed pre-existing one-off entries from global allow that should never have been promoted (specific tax-document
  copies, pdf-generator scratch builds, Cloudflare-Pages-to-Workers sed renames, claude model probe). 24 entries
  stripped, mostly subsumed by broader wildcards anyway. by @brettdavies in
  [#79](https://github.com/brettdavies/dotfiles/pull/79)
- Stripped 50 redundant entries from `.claude/settings.local.json` and 672 from the other 17
  `~/dev/*/.claude/settings.local.json` files. The latter are gitignored/untracked, so the strips apply on disk in those
  repos without separate commits.
- Three speculative MCP wildcards in `stow/claude/dot-claude/settings.json` replaced with enumerated entries:
  `mcp__plugin_cloudflare_*` becomes 11 entries from the proven cloudflare set (`accounts_list`, `kv_namespaces_list`,
  `r2_buckets_list`, `set_active_account`, `workers_get_worker`, `workers_list`,
  `cloudflare-docs__search_cloudflare_documentation`, `cloudflare-api__execute`, `cloudflare-api__search`,
  `cloudflare-builds__accounts_list`, `cloudflare-observability__accounts_list`);
  `mcp__plugin_compound-engineering_context7__*` and `mcp__plugin_context7_context7__*` become 4 enumerated entries (2
  install paths × 2 tools each). by @brettdavies in [#81](https://github.com/brettdavies/dotfiles/pull/81)
- Stripped 13 redundant entries from `.claude/settings.local.json`: 3 /tmp/test_full.pdf curl probes, 6 macOS
  personal-home Read entries (orphans on Linux), 4 entries subsumed by the new global wildcards (rclone
  listremotes/version, kill %1 covered by kill:*). by @brettdavies in
  [#83](https://github.com/brettdavies/dotfiles/pull/83)
- Stripped ~324 entries across 17 other ~/dev/*/.claude/settings.local.json files (gitignored, on-disk only). Two files
  became empty (brettdavies, dot-github) and were deleted entirely.
- Closed semantic regressions surfaced during the security review: pkill was bypassing the killall deny; sg docker was
  bypassing the docker ASK; broad wrangler:*and rclone:* ALLOWs would have shipped destructive subcommands auto-allowed.

### Documentation

- Updated `~/dev/solutions-docs/best-practices/claude-code-permission-globs-use-colon-not-star-2026-04-20.md` to correct
  the previous claim that `Bash(cmd *)` (space-asterisk) was equivalent-to-dangerous Form A. Per current Claude Code
  docs (verified 2026-05-15), Forms B (space) and C (colon) are equivalent and both safe; only bare-prefix Form A is the
  typosquat surface. Audit regex corrected from `[^:]\*\)` to `[^: ]\*\)`. by @brettdavies in
  [#79](https://github.com/brettdavies/dotfiles/pull/79)
- Added `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` covering cross-list
  precedence (deny → ask → allow), within-list subsumption analysis, strategic carveouts pattern, and the
  promote-and-strip workflow.
- `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` (commit `4f62307` in
  solutions-docs) gains a "Tool pattern coverage (verified behavior)" section recording both findings: MCP wildcards do
  not validate, `Read(~/...)` does. Future audits skip the experiments. by @brettdavies in
  [#81](https://github.com/brettdavies/dotfiles/pull/81)
- No doc changes in this PR. The audit-strategy doc at
  `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` already covers cross-list
  precedence, subsumption analysis, and tool pattern coverage findings used to drive this audit. by @brettdavies in
  [#83](https://github.com/brettdavies/dotfiles/pull/83)
- Replace specific environment-tied references in tracked docs with generic placeholders and role descriptors, improving
  readability and portability for future contributors. by @brettdavies in
  [#85](https://github.com/brettdavies/dotfiles/pull/85)

### Removed

- Dead SDKMAN init blocks from `stow/zsh/dot-zprofile` and `stow/bash/dot-bash_profile`. SDKMAN is not installed on
  either the development Mac or the headless Linux server. by @brettdavies in
  [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Drop one manual LAN-alias `Host` block from `stow/ssh/dot-ssh/config`. Use the canonical short name from any network:
  Tailscale SSH off-LAN, LAN sshd on the home network via the existing `Match originalhost` override. by @brettdavies in
  [#82](https://github.com/brettdavies/dotfiles/pull/82)

**Full Changelog**: [2026.05.11...2026.05.16](https://github.com/brettdavies/dotfiles/compare/2026.05.11...2026.05.16)

## [2026.05.11]

### Added

- Install `rtk-ai/rtk` `PreToolUse` Bash hook for ~60-90% token compression on supported commands (`git`, `cargo`, `gh`,
  `pytest`, `docker`, etc.). by @brettdavies in [#62](https://github.com/brettdavies/dotfiles/pull/62)
- Document rtk meta commands in global `CLAUDE.md`: `rtk gain` (savings analytics), `rtk discover` (find missed
  compression opportunities), `rtk proxy <cmd>` (run unfiltered for debugging).
- Add `ancsite`, `ancspec`, `ancskill` tmuxinator configs pointing at `~/dev/agentnative-{site,spec,skill}`. by
  @brettdavies in [#63](https://github.com/brettdavies/dotfiles/pull/63)

### Changed

- Rename `agentnative-cli` tmuxinator session to `anc` (project root unchanged: `~/dev/agentnative-cli`). by
  @brettdavies in [#63](https://github.com/brettdavies/dotfiles/pull/63)
- `tmux-new-session` now writes a tmuxinator config under `stow/tmuxinator/dot-config/tmuxinator/<name>.yml` and
  re-stows the package before launching the session, so every session it creates is reproducible and source-controlled.
  Sessions are started via `tmuxinator start` instead of raw `tmux new-session`. by @brettdavies in
  [#67](https://github.com/brettdavies/dotfiles/pull/67)

### Fixed

- Stop auto-formatting files under `/tmp`, `/var/tmp`, and `$TMPDIR` so PR-body drafts and other scratch files paste
  verbatim into downstream forms. by @brettdavies in [#64](https://github.com/brettdavies/dotfiles/pull/64)
- Restore the 3-pane default layout (yazi, shell, lazygit) to every tmuxinator config — sessions started via `mux start
  <name>` now reopen with the expected working layout instead of a single bare pane. by @brettdavies in
  [#66](https://github.com/brettdavies/dotfiles/pull/66)
- Replace deprecated `post:` hook with `on_project_exit:` in every tmuxinator config and in the config template emitted
  by `tmux-new-session`. Sessions still get the 3-pane resize, but `tmuxinator start` no longer prints the deprecation
  warning. by @brettdavies in [#68](https://github.com/brettdavies/dotfiles/pull/68)

### Documentation

- Document the triple-diff verification step in `RELEASES.md` (main→release, release→dev, dev→main + guarded-paths grep
- `git cherry` patch-id sweep) so missed cherry-picks get caught before the release tag goes out instead of after. by
  @brettdavies in [#60](https://github.com/brettdavies/dotfiles/pull/60)
- Document the cliff.toml chore-skip footgun in the `RELEASES.md` review step — generated changelog must be
  cross-checked against PR bodies for cherry-picked PRs whose commit subject starts with a skipped type.
- Add "Prefer `feat`/`fix` over `chore` when the change has any user-observable effect" rule to global CLAUDE.md `##
  Commit Messages` section, with the `cliff.toml` rationale.
- Restructure `RELEASES.md` to consolidate cliff.toml `chore`-skip guidance into a dedicated `### CHANGELOG is
  generated, never hand-written` subsection under `## Releasing dev to main` (mirrors sibling brettdavies repos); trim
  `## PRs and changelog generation` to PR-author-facing content only. by @brettdavies in
  [#61](https://github.com/brettdavies/dotfiles/pull/61)
- Add a `### Tmuxinator Sessions` section to `README.md` documenting the 3-pane layout intent and `tmuxinator start
  <name>` (and the `mux start <name>` shell alias, and the SSH form `ssh <host> -t tmuxinator start <name>`) as the
  preferred launch / connection idiom. Correct the stale "13 projects" count in the stow package row to "16 projects".
  by @brettdavies in [#68](https://github.com/brettdavies/dotfiles/pull/68)

**Full Changelog**: [2026.05.02...2026.05.11](https://github.com/brettdavies/dotfiles/compare/2026.05.02...2026.05.11)

## [2026.05.02]

### Added

- `qmd-cleanup.timer` + `qmd-cleanup.service`: nightly `qmd cleanup` with `RandomizedDelaySec=2h` so fires land in a
  [03:00, 05:00] window. by @brettdavies in [#51](https://github.com/brettdavies/dotfiles/pull/51)
- `qmd-ollama-unload-all` helper: dynamically frees Ollama VRAM only when GPU has less than `MIN_FREE_MIB` (default

1) free, leaving hot pins alone when headroom is sufficient.

- `stow/claude/dot-claude/md-align-tables.py`: GFM table aligner with PEP 723 inline metadata (uv run --script). Reflows
  mixed compact/aligned tables into consistent aligned-pipe style; preserves alignment hints, escaped pipes,
  frontmatter, fenced code, and HTML. by @brettdavies in [#52](https://github.com/brettdavies/dotfiles/pull/52)
- `stow/github/dot-config/github/pull_request_template.md`: `**Renamed:**` field in the `## Files Modified` section so
  rename-style changes get their own bullet category instead of splitting into create+delete or hiding under modified.
- 14 new telemetry opt-outs in `config/shell/telemetry.sh`: Apollo Rover, Astro, AWS CDK, Cloudflare Wrangler, .NET
  Interactive, .NET svcutil, Gemini CLI, Go runtime (1.23+), Hugging Face Hub, Nuxt, Stripe CLI, Supabase, Turborepo,
  Vercel. by @brettdavies in [#55](https://github.com/brettdavies/dotfiles/pull/55)
- Discoverability comment in `config/shell/supply-chain.sh` pointing at `stow/bun/dot-bunfig.toml` so future-me doesn't
  go looking for bun in this file (bun has no env-var equivalent for `minimumReleaseAge`).
- `copy-on-select = clipboard` in `stow/ghostty/dot-config/ghostty/config` so text selected with the mouse is
  auto-copied to the system clipboard (no Cmd+C needed), parity with tmux behavior. by @brettdavies in
  [#56](https://github.com/brettdavies/dotfiles/pull/56)

### Changed

- `stow/claude/dot-claude/auto-format.sh`: new Step 2 invokes `md-align-tables.py` (gated on `command -v uv`) between
  md-wrap and markdownlint; prior Step 2 (markdownlint) renumbered to Step 3. by @brettdavies in
  [#52](https://github.com/brettdavies/dotfiles/pull/52)
- `stow/claude/dot-claude/CLAUDE.md`: five workflow expansions — parallel CE + qmd learnings dispatch (workaround for
  EveryInc/compound-engineering-plugin#655), `.context/handoffs/` filename convention, pre-flight PR template read
  before `gh pr create`, branch-discipline scope refinement (audience, not extension), and two new principle sections
  (long artifacts go to files; system configs go in dotfiles).
- Re-sorted `telemetry.sh` to strict ASCII alphabetical order. Fixes two pre-existing minor disorderings: `Azure SDK`
  was before `Azure Functions Core Tools`, and `Sentry` was before `Segment`. by @brettdavies in
  [#55](https://github.com/brettdavies/dotfiles/pull/55)
- Annotated version-gated entries inline (`GH_TELEMETRY` v2.91.0+, `GOTELEMETRY` Go 1.23+).

### Fixed

- `qmd-embed.service` no longer references the stale `qwen3-coder:30b` model name. Pre-embed VRAM step now adapts to
  whatever Ollama is actually running, on whichever host. by @brettdavies in
  [#51](https://github.com/brettdavies/dotfiles/pull/51)
- `stow/claude/dot-claude/md-wrap.py`: `wrap_paragraph.drain()` no longer leaks `buf_indent` across paragraphs. Adds the
  missing `nonlocal` declaration plus a post-flush reset. by @brettdavies in
  [#52](https://github.com/brettdavies/dotfiles/pull/52)
- Cross-platform `docs/solutions` symlink: now resolves on both macOS and Linux without per-host re-creation. by
  @brettdavies in [#54](https://github.com/brettdavies/dotfiles/pull/54)

### Documentation

- Update `stow/claude/dot-claude/CLAUDE.md` recreate-symlink command to use the relative form. by @brettdavies in
  [#54](https://github.com/brettdavies/dotfiles/pull/54)
- Document PR template sub-section completeness — `Files Modified` and `Related Issues/Stories` sub-headers must appear
  with `- None.` or `n/a` when empty; only the `Changelog` block's `### Added`/`Changed`/`Fixed`/`Documentation`
  sections may be deleted when empty. by @brettdavies in [#58](https://github.com/brettdavies/dotfiles/pull/58)
- Document the heredoc escape rule for `gh pr create --body "$(cat <<'EOF' ... EOF)"` — single-quoted delimiters
  preserve the body literally, so do not escape inner quotes, backslashes, or `$`.
- Expand the plan/docs-only direct-commit exception to cover `docs/ideation/**` and `docs/research/**`.

**Full Changelog**: [2026.04.22...2026.05.02](https://github.com/brettdavies/dotfiles/compare/2026.04.22...2026.05.02)

## [2026.04.22]

### Added

- AppArmor profile for Playwright's Chromium binaries (both `chrome-headless-shell` and full `chrome`), deployed with
  `sudo scripts/apparmor-deploy.sh`. Persists across reboots via `/etc/apparmor.d/`. by @brettdavies in
  [#39](https://github.com/brettdavies/dotfiles/pull/39)
- `opendataloader-pdf` stow package: socket unit (`127.0.0.1:5002`), service unit (socket-activated, hardened with
  `NoNewPrivileges` + `PrivateTmp`), and a two-file launcher (`opendataloader-pdf-hybrid-sa` sh wrapper + `.py` module
  with LISTEN_FDS dispatch and asyncio idle-exit watchdog). by @brettdavies in
  [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `scripts/opendataloader-pdf-enable.sh` — one-shot idempotent enable script that stops orphan listeners, reloads
  systemd, enables `--now` the socket unit, and smoke-tests `/health`.
- `--idle-timeout` flag on the launcher; defaults to 60 s so qmd isn't starved by ODL's residual 4.4 GB.
- Stow-managed `qmd-serve.service` systemd user unit for the sequential-mode daemon (always-on, peak VRAM ~2.6 GB
  instead of ~5.4 GB). by @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `config/shell/qmd.sh` exports `QMD_SERVER=http://127.0.0.1:7832` in all shell contexts (interactive, non-interactive
  zsh, cron, systemd children that source `.profile`).
- `stow/qmd/dot-local/bin/qmd` sh wrapper dispatches to the brettdavies/qmd fork at `$HOME/dev/qmd/qmd`.
- `scripts/qmd-serve-enable.sh` is a Linux-only idempotent one-shot that cleans orphan `:7832` listeners, reloads
  systemd, enables --now, and smokes `/health`.
- `target/**` ignore and `# Canonical version: 2026.04.15` header in the canonical markdownlint config so per-repo
  copies can detect drift with a one-liner comparison. by @brettdavies in
  [#49](https://github.com/brettdavies/dotfiles/pull/49)

### Changed

- Change release-branch construction from `git merge origin/development` to cherry-picking PR squash commits, so
  `git-cliff --unreleased` only sees the true release delta. by @brettdavies in
  [#37](https://github.com/brettdavies/dotfiles/pull/37)
- `scripts/stow-deploy`: `opendataloader-pdf` added to `SHARED_PACKAGES` and to the Linux-only skip block (macOS deploys
  skip with a WARNING). by @brettdavies in [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `qmd-embed.service` and `qmd-update.service` ExecStart switched to `%h/.local/bin/qmd` (the new stow wrapper). by
  @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `QMD_SERVER` export moved out of `stow/shell/dot-profile` into `config/shell/qmd.sh` (feature-named file convention).
- Rename `CLAUDE.md` to `AGENTS.md` so Claude Code, opencode, Cursor, and Codex all read the same project-level
  instructions. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)
- Update `README.md` stow-package table: add `github`, `openclaw`, `opendataloader-pdf`, and `rust` rows; expand the
  `qmd` row to cover the new qmd-serve daemon and `.local/bin/qmd` wrapper.
- Update `README.md` Shell Environment table: add `qmd.sh` (exports `QMD_SERVER`).
- Update `README.md` Release Automation section: rename `RELEASE_TOKEN` → `CI_RELEASE_TOKEN` and clarify that release
  notes come from the committed `CHANGELOG.md`, not from git-cliff at CI time.
- Update `BOOTSTRAP.md` manual stow commands to include `github` (macOS + headless) and `opendataloader-pdf` (headless),
  matching `scripts/stow-deploy`'s `SHARED_PACKAGES`.
- Update `PROJECT.md` counts (17 → 32 stow packages, 11 → 16 shell fragments) and expand the package breakdown.
- Correct the `RELEASES.md` pipeline diagram to show cherry-picking from dev onto a `release/*` branch branched from
  main (matches the flow landed in #37).

### Fixed

- `qmd-update.service` now sets an explicit `PATH` that includes the Homebrew prefix so timer-triggered runs can resolve
  subprocess dependencies. by @brettdavies in [#46](https://github.com/brettdavies/dotfiles/pull/46)
- Auto-format hook now reads its global config fallback from `~/.markdownlint-cli2.yaml` (stow-managed symlink to
  dotfiles canonical) instead of the deleted `~/.claude/.markdownlint-cli2.yaml` stray. by @brettdavies in
  [#49](https://github.com/brettdavies/dotfiles/pull/49)
- Realign table column widths across `AGENTS.md`, `README.md`, `PROJECT.md`, and `RELEASES.md` so they satisfy MD060
  `aligned` style after the widened rows. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)

### Documentation

- Document the cherry-pick flow and rename "Why branch from main, not development" to explain both the `add/add`
  conflict and the orphan-history failure modes that motivate this workflow. by @brettdavies in
  [#37](https://github.com/brettdavies/dotfiles/pull/37)
- Describe \`docs/solutions/\` structure and search path in \`CLAUDE.md\` Reference section. by @brettdavies in
  [#41](https://github.com/brettdavies/dotfiles/pull/41)
- Mark \`docs/plans/2026-04-21-001-feat-opendataloader-pdf-socket-activation-plan.md\` as \`completed\` with post-ship
  notes describing shipped state, deviations, and measured timings. by @brettdavies in
  [#42](https://github.com/brettdavies/dotfiles/pull/42)

**Full Changelog**: [2026.04.15...2026.04.22](https://github.com/brettdavies/dotfiles/compare/2026.04.15...2026.04.22)

## [2026.04.15]

### Added

- Add `DO_NOT_TRACK=1` universal telemetry opt-out (consoledonottrack.com) plus targeted opt-outs for VS Code
  (`VSCODE_TELEMETRY_LEVEL=off`), PowerShell (`POWERSHELL_TELEMETRY_OPTOUT=1`), and Azure Functions Core Tools
  (`FUNCTIONS_CORE_TOOLS_TELEMETRY_OPTOUT=1`) by @brettdavies in [#31](https://github.com/brettdavies/dotfiles/pull/31)
  and [#32](https://github.com/brettdavies/dotfiles/pull/32)
- Add nightly autocommit for `obsidian-vault`, `solutions-docs`, and agent-skills with a systemd timer randomized to 2-4
  AM CT by @brettdavies in [#33](https://github.com/brettdavies/dotfiles/pull/33)
- Add `mnt-nas.automount` for on-demand NAS mounting (fixes the WiFi boot race) and `scripts/nas-deploy.sh` for
  copy-deploying system-level systemd units by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)
- Add `github/` stow package targeting `~/.config/github/` for repo-workflow templates; `SHARED_PACKAGES` in
  `scripts/stow-deploy` now includes it by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)

### Changed

- Rename `RELEASING.md` to `RELEASES.md` and restructure to the canonical release-doc layout shared across brettdavies
  repos by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)
- Move the canonical PR template from `stow/claude/dot-claude/templates/pull-request.md` to
  `stow/github/dot-config/github/pull_request_template.md`; `.github/pull_request_template.md` is now a real inlined
  file so GitHub's PR-template discovery works
- Prohibit AI-attribution trailers on commit messages and PR bodies via global CLAUDE.md directive
- Move `QMD_SERVER` and Bun PATH exports from `.zshrc` to `.profile` so cron, SSH commands, and other non-interactive
  contexts see them
- Support markdown hard line breaks (two trailing spaces) in the `md-wrap.py` PostToolUse hook and in the markdownlint
  config; prefer the project-local `markdownlint-cli2.yaml` over the global one for line-width
- Strengthen the query-solutions-first instruction in global CLAUDE.md
- Stop tracking `TODOS.md` (added to global gitignore)

### Fixed

- Fix nightly autocommit to embed the Conventional Commits spec and SRP rules in the prompt, and delegate full
  add+commit to `claude -p` rather than staging in shell

### Documentation

- Document the system-level systemd units pattern in CLAUDE.md (copy-deploy, not stow) and add a matching section to
  README.md by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)

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
