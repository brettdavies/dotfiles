# CLI Tool Preferences

Detail behind the **CLI tools** rule in `~/.claude/CLAUDE.md`. The always-on essentials live inline; this file holds the
full preference list, the tool-substitution table, and the hook/auth notes. Open it when choosing a tool, debugging a
hook, or unsure what's installed.

- **Priority order for installing CLI tools:** brew > bunx/uvx > python3/node (last resorts only).
- **Python: leave no cache or venv artifacts in the project tree.** The user does not want `__pycache__/`, `.venv/`,
  `.pytest_cache/`, `.ruff_cache/`, `*.egg-info`, `uv.lock`, or build dirs generated beside their source. Prevent them
  rather than `.gitignore`-hiding them — the goal is to not generate the artifact, not to hide it — and `trash` any that
  appear. **Bake the bypass into the project itself, not the machine:** the tree must stay clean on CI and on any other
  machine, so the fixes below live in the repo (`pyproject.toml`, `python -B`, `sys.dont_write_bytecode`,
  `--no-project`). Brett's machines also set the shell env vars noted below, but those are a safety net that does not
  travel — never rely on them in place of the in-project settings.
- **Bytecode (`__pycache__/`):** in-project — run with `python -B` (disables bytecode writing for that process, no env
  var needed) and set `sys.dont_write_bytecode = True` at the top of executable entry points and in a root `conftest.py`
  (belt-and-suspenders for imports; single-file scripts with no local imports need nothing — Python never caches
  `__main__`). A plain `python -m <pkg>.<mod>` without `-B` still caches the first-imported module, so prefer `-B` or
  the console-script path. Safety net (this machine only): `PYTHONDONTWRITEBYTECODE=1` in
  `~/dotfiles/config/shell/python.sh`.
- **uv `.venv/` + `uv.lock`** — no env var suppresses these, so always prevent them per-invocation: a plain `uv run`
  inside a project dir syncs the project and writes `.venv/` + `uv.lock` into it. Run a package's console script with
  `uv run --no-project --with . <script> …` (installs into the ephemeral cache, imports run from there — leaves nothing
  in the tree, the cleanest option), or a module from source with `uv run --no-project python -B -m <pkg>.<mod> …`.
- **pytest `.pytest_cache/`:** in-project — pin `[tool.pytest.ini_options] addopts = "-p no:cacheprovider"` in
  `pyproject.toml` (travels with the repo, works in CI). Run a suite with `uv run --no-project --with pytest python -B
  -m pytest`. Safety net (this machine only): `PYTEST_ADDOPTS="-p no:cacheprovider"` in
  `~/dotfiles/config/shell/python.sh` (trade-off: disables the cache-backed `--lf`/`--ff`/`--nf` reruns).
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
- **File deletion:** `trash` (via Bash), never `rm` or `git rm` (both denied in `settings.json`). `trash` is a binary on
  both platforms: the stock `/usr/bin/trash` on macOS, and `trash-cli` from the Brewfile on Linux. Two cleanup paths in
  `scripts/` keep an explicit `|| rm -rf` fallback for their own temp directories, so a host mid-bootstrap without
  `trash-cli` yet does not fail the deploy; that is the only sanctioned exception.
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
- **Playwright browsers are system-provided, never installed per-repo.** The browser binaries live in the shared
  `$PLAYWRIGHT_BROWSERS_PATH` (exported by `~/dotfiles/config/shell/caches.sh`) and are provisioned by
  `~/dotfiles/scripts/playwright-browsers-deploy.sh` (curl + unzip, user-space). **Never run `playwright install` to
  download browsers** — Node 26 / libuv 1.52.1's io_uring extractor deadlocks on this kernel and hangs forever (root
  cause: `docs/solutions/runtime-errors/playwright-browser-install-stall-manual-cache-install.md`).
  `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` stops `bun install`'s postinstall from auto-fetching browsers, so a dependency
  install never triggers the wedge; it does NOT no-op an explicit `playwright install`, which still fetches any browser
  missing from the cache. The provisioned markers are what make an explicit install skip the browsers a repo uses, so
  the dotfiles set must cover every browser the repos launch (chromium + webkit today, no firefox). Repos **exact-pin
  the one canonical version** (`DEFAULT_VERSION` in the deploy script) instead of a caret range, so the resolved version
  always matches the provisioned browser revisions. **Check what's provisioned** with `ls $PLAYWRIGHT_BROWSERS_PATH` and
  the script's version map. **To change the version:** bump the map + re-run the dotfiles script, then realign the repo
  pins — never bump a repo's Playwright independently, and never re-provision from an arbitrary repo or e2e run. **Watch
  out for `bun x playwright install`:** `bunx` uses a repo's local install only when `node_modules` is present; run
  standalone (a fresh worktree, before `bun install`, or outside a repo) it floats to the LATEST published Playwright,
  ignores the repo pin, and tries to fetch whatever browsers that release wants — this is why older setups kept pulling
  newer-and-newer revisions. Run the repo's local Playwright instead (`bun run test:e2e` → `playwright test` from
  `node_modules`); `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` neutralizes any stray install call either way.
- When uncertain what CLI tools are available, you can enumerate installed tools with the following commands:
- `brew list` to list installed Homebrew CLI tools
- `pipx list` to list Python-based CLI utilities
- `bun pm ls -g` to list globally installed Bun packages
- If a needed tool is missing, ask the user to install it.
- **Rust pre-push checks:** Every Rust repo has `scripts/hooks/pre-push` which mirrors CI (fmt, clippy `-Dwarnings`,
  test, cargo-deny, Windows compat). Activated via `git config core.hooksPath scripts/hooks` (run once after clone). The
  hook runs automatically on `git push`; if it fails, fix the issues before pushing.
