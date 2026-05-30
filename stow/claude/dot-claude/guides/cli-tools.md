# CLI Tool Preferences

Detail behind the **CLI tools** rule in `~/.claude/CLAUDE.md`. The always-on essentials live inline; this file holds the
full preference list, the tool-substitution table, and the hook/auth notes. Open it when choosing a tool, debugging a
hook, or unsure what's installed.

- **Priority order for installing CLI tools:** brew > bunx/uvx > python3/node (last resorts only).
- **Python entry points: suppress bytecode caches by default.** When a Python script imports local modules — a PEP 723
  script run via `uv run`, or any package under `scripts/` — set `sys.dont_write_bytecode = True` at the very top of the
  entry, before importing those modules, so no `__pycache__/` is ever written beside the source. Prefer the in-code flag
  over a `.gitignore` rule: the goal is to not generate the artifact, not to hide it. Single-file scripts with no local
  imports need nothing (Python never caches the `__main__` module). `PYTHONDONTWRITEBYTECODE=1` in the environment is
  the equivalent global lever when you'd rather not touch the script.
- **ALWAYS use CLI tools via Bash over built-in tools.** This overrides Claude Code's default preference for
  Read/Edit/Grep/Glob. The built-in tools are fallbacks, not defaults. Concrete rules:
- **Searching code:** `rg` (via Bash), not Grep. `ast-grep` for structural matches.
- **Searching files:** `find` or `fd` (via Bash), not Glob.
- **Reading files:** `cat`, `head`, `tail`, `bat` (via Bash), not Read. Exception: Read for images/PDFs.
- **Editing files:** `sed`, `awk`, or in-place CLI utilities (via Bash), not Edit. Exception: Edit for surgical
  single-line replacements where `sed` addressing would be fragile.
- **Writing files:** heredoc with `cat` or `tee` (via Bash), not Write. Exception: Write for new files where the entire
  content is being generated.
- **JSON processing:** `jaq` (via Bash), not manual parsing.
- **Refactoring:** `ast-grep` or `sed` with find, not Edit with replace_all.
- CLI tools produce better output for review, compose with pipes, and match how this user works. When in doubt, reach
  for Bash.
- **File deletion:** `trash` (via Bash), never `rm` or `git rm` (both denied in `settings.json`).
- **Knowledge base search:** use [`qmd`](https://github.com/tobi/qmd) to search the Obsidian vault, solutions-docs, and
  skills collections. Always use `qmd query` (hybrid, ~10s) as the default — it combines BM25 + vector + LLM re-ranking
  and produces significantly better results than `qmd search` alone. Prefer multiple focused queries with 2-3 terms each
  over one query with many terms. Always search qmd before researching from scratch — check solutions and vault for
  prior art.
- **Auto-format hook:** A PostToolUse hook wraps markdown prose to 120 characters (`md-wrap.py`) then runs
  `markdownlint-cli2 --fix`. Do NOT manually wrap markdown lines — the hook handles it. Do NOT use `mdformat`, `pandoc`,
  or `prettier` for markdown formatting.
- **rtk auto-rewrite hook:** A PreToolUse hook on Bash transparently rewrites supported commands (`git`, `cargo`, `gh`,
  `pytest`, `docker`, etc.) through [`rtk`](https://github.com/rtk-ai/rtk) for 60-90% token compression. Three meta
  commands are NOT auto-rewritten and must be invoked explicitly: `rtk gain` (savings analytics), `rtk discover` (find
  missed compression opportunities), `rtk proxy <cmd>` (run unfiltered for debugging). Idempotent — already-`rtk`
  commands pass through unchanged.
- **GitHub CLI auth:** `gh` uses OAuth (not a fine-grained PAT) for interactive use. This allows creating issues, PRs,
  and forks on any public repo. Do NOT run `gh auth login --with-token` — use the default `gh auth login` OAuth flow.
  Fine-grained PATs are only for CI/CD (`CI_RELEASE_TOKEN` in GitHub Actions).
- When uncertain what CLI tools are available, you can enumerate installed tools with the following commands:
- `brew list` to list installed Homebrew CLI tools
- `pipx list` to list Python-based CLI utilities
- `bun pm ls -g` to list globally installed Bun packages
- If a needed tool is missing, ask the user to install it.
- **Rust pre-push checks:** Every Rust repo has `scripts/hooks/pre-push` which mirrors CI (fmt, clippy `-Dwarnings`,
  test, cargo-deny, Windows compat). Activated via `git config core.hooksPath scripts/hooks` (run once after clone). The
  hook runs automatically on `git push`; if it fails, fix the issues before pushing.
