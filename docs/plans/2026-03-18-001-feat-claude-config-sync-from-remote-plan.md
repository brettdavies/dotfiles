---
title: "feat: Sync Claude Code config files from remote servers"
type: feat
status: abandoned
date: 2026-03-18
deepened: 2026-03-19
---

## Resolution / Post-ship notes (2026-05-02 audit)

Marked `abandoned`. As of release `2026.05.02` (today), `scripts/claude-sync` does not exist, no
`scripts/sync/incoming/` staging area is in the repo or `.gitignore`, and no commit references this work. The need was
superseded in practice:

- `nightly-autocommit.service` (shipped in release `2026.04.15`,
  [PR #33](https://github.com/brettdavies/dotfiles/pull/33)) now auto-commits drift from `obsidian-vault`,
  `solutions-docs`, and the agent-skills repo, which covers the highest-value pull-target the original plan was chasing.
- Per-repo `CLAUDE.md` / `AGENTS.md` configs are reviewed in-place during normal repo work rather than batch-pulled.

If a remote-sync need re-emerges, this plan is the design starting point — but for now it's parked, not active.

# feat: Sync Claude Code config files from remote servers

## Enhancement Summary

**Deepened on:** 2026-03-19 **Sections enhanced:** 10 **Research agents used:** architecture-strategist,
security-sentinel, performance-oracle, code-simplicity-reviewer, pattern-recognition-specialist, spec-flow-analyzer,
learnings-researcher, best-practices-researcher, plus 4 web research queries

### Key Improvements

1. **Batch transfer architecture** -- replace per-repo rsync with single-SSH-session `find | tar` pipeline
2. **diff3 evaluation** -- concluded `diff -ru` (with `colordiff`) is correct; `diff3` is for three-way merge, not
   applicable here
3. **Security hardening** -- host alias validation, `--base-dir` sanitization, atomic staging, tar safety flags
4. **SSH ControlMaster** -- reuse a single multiplexed SSH connection for all operations
5. **Exit code alignment** -- align shared exit codes with `stow-deploy` (USAGE=2, DEPENDENCY=3)
6. **Flow gaps filled** -- `--dry-run` behavior specified, `.claude/commands/` and `.claude/agents/` added to scope,
   interrupted-transfer sentinel, `FATAL:` prefix for terminal errors
7. **Flag parsing fix** -- flags must come before positional arg to match `stow-deploy` `while --*` pattern

### New Considerations Discovered

- Global gitignore at `~/.config/git/ignore` already ignores `CLAUDE.md`/`AGENT.md` etc., providing double-safety but
  also preventing `git diff` review of staged files
- Remote `find` output must use `-print0` for path safety
- `rsync` exit code 24 (files vanished) needs explicit handling under `set -e`
- Symlinked config files on remote need explicit handling (preserve symlinks, don't follow)
- Script will likely exceed 200 lines; single-file design is intentional (matching `stow-deploy` precedent)

---

## Overview

Create a shell script (`scripts/claude-sync`) that SSHes into a remote server, auto-discovers all repos under `~/dev/`
containing Claude Code configuration files, and pulls those files into a local staging area
(`scripts/sync/incoming/<host>/`) for manual review and adoption into the dotfiles repo.

This is a **pull-only workflow** -- run from macOS, fetching config from headless Linux servers. The staging area serves
as a review buffer; files are never adopted automatically.

## Problem Statement / Motivation

Claude Code configuration evolves on remote servers as repos are actively developed. Per-repo `CLAUDE.md`, `AGENTS.md`,
`AGENT.md`, and `.claude/settings.local.json` files accumulate valuable project-specific instructions, permissions, and
agent guidance that should be reviewed and potentially adopted into the dotfiles release cycle.

Currently there is no mechanism to pull these configs back. The only sync direction in the repo is push (stow-deploy).
Without a pull workflow, configuration drift goes unnoticed and useful patterns discovered on servers are lost.

## Proposed Solution

A single self-contained bash script following the `stow-deploy` conventions:

```text
scripts/claude-sync [--base-dir DIR] [--dry-run] <ssh-host-alias>
```

### Research Insights: Flag Ordering

The original plan placed `<ssh-host-alias>` before flags. This breaks the `stow-deploy` flag parsing pattern (`while [[
"${1:-}" == --* ]]`), which consumes flags first, then treats remaining positional args. **Flags must come before the
positional argument** for consistency with `stow-deploy`.

### Core Flow

1. **Pre-flight** -- Verify `.gitignore` contains `scripts/sync/incoming/`, check dependencies
2. **Validate** -- Regex-validate host alias, check SSH config (`ssh -G`), verify connectivity (`ssh -o BatchMode=yes
   ... true`)
3. **Discover** -- Single SSH session: find all repos, discover all config files, emit NUL-delimited file list
4. **Diff** -- If prior sync exists (sentinel present), show `diff -ru` between old staging and incoming files
5. **Transfer** -- Pull discovered files via single `find | tar` pipeline (or rsync `--files-from`) into temp dir
6. **Finalize** -- Atomically replace old staging with temp dir, write `.sync-complete` sentinel
7. **Summarize** -- Report files synced, repos found, and any errors

### Target Files

| File                          | Location                     | Discovery                      |
| ----------------------------- | ---------------------------- | ------------------------------ |
| `CLAUDE.md`                   | Repo root                    | Direct check                   |
| `AGENT.md`                    | Repo root + subdirs          | Recursive, prune vendored dirs |
| `AGENTS.md`                   | Repo root + subdirs          | Recursive, prune vendored dirs |
| `.claude/settings.local.json` | Repo `.claude/` dir          | Direct check                   |
| `.claude/CLAUDE.md`           | Repo `.claude/` dir          | Direct check                   |
| `.claude/commands/*.md`       | Repo `.claude/commands/` dir | Direct check (glob)            |
| `.claude/agents/*.md`         | Repo `.claude/agents/` dir   | Direct check (glob)            |

### Research Insights: Expanded .claude/ Scope

Claude Code supports custom slash commands (`.claude/commands/*.md`) and agent definitions (`.claude/agents/*.md`).
These represent high-value per-project configuration that is arguably more useful to sync than `settings.local.json`.
The expanded scope captures these automatically.

### Staging Directory Structure

```text
scripts/sync/incoming/
  <host-alias>/
    .sync-complete          <-- sentinel: indicates last sync completed successfully
    <relative-repo-path>/
      CLAUDE.md
      AGENTS.md
      .claude/
        settings.local.json
        CLAUDE.md
        commands/
          deploy.md
        agents/
          reviewer.md
      src/
        AGENTS.md
```

Repo paths are relative to `~/dev/` to avoid name collisions (e.g., `work/api/` vs `personal/api/`).

## Technical Considerations

### SSH Compatibility

- Always pass `-o RemoteCommand=none -o RequestTTY=no` to override any per-host interactive settings (e.g., hosts with
  `RemoteCommand tmux ...` would hang without this)
- Pre-validate host alias with `ssh -G <host>` before attempting connection
- Use existing SSH config (named hosts, `~/.ssh/brett_ed25519` key)

### Research Insights: SSH Connection Management

**Define a single `SSH_CMD` variable** used for all remote operations:

```bash
SSH_OPTS=(-o RemoteCommand=none -o RequestTTY=no -o ConnectTimeout=10)
```

**Use SSH ControlMaster** to multiplex all SSH operations over a single connection. This eliminates the overhead of
multiple TCP handshakes and SSH key exchanges:

```bash
ctrl_dir=$(mktemp -d)
ctrl_sock="$ctrl_dir/ctrl-%C"
SSH_OPTS+=(-o ControlMaster=auto -o ControlPath="$ctrl_sock" -o ControlPersist=60)
trap 'ssh -O exit -o ControlPath="$ctrl_sock" "$host" 2>/dev/null; rm -rf "$ctrl_dir" "${tmpdir:-}"' EXIT INT TERM
```

**Connectivity verification** must go beyond `ssh -G` (which only parses config, does not connect):

```bash
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$host" true 2>/dev/null; then
    echo "FATAL: Cannot establish SSH connection to '$host'" >&2
    exit "$EXIT_SSH"
fi
```

The `-o BatchMode=yes` prevents password prompts (which would hang in a script).

**Best practice pitfalls with `set -euo pipefail` and SSH:**

- SSH returns exit 255 for connection failures vs. 1-254 for remote command failures -- distinguish these
- Always use `&&` (not `;`) to chain remote commands, or pass `set -euo pipefail` into the remote shell
- Never combine `local` and command substitution: `local result; result=$(ssh ...)` (separate declaration)
- Use `((counter++)) || true` to prevent `set -e` from killing the script when counter is 0
- Use `ssh -n` when running SSH inside loops that read from stdin (SSH consumes stdin)
- Single-quote remote commands to prevent local shell expansion (`ssh host 'echo $HOSTNAME'`)

**ShellCheck warnings to expect:**

- SC2029 (client-side variable expansion in SSH commands) -- use single quotes or `# shellcheck disable=SC2029`
- SC2087 (unquoted heredoc delimiter) -- quote delimiter: `<< 'EOF'`
- SC2095 (SSH swallowing stdin in loops) -- use `ssh -n` or `< /dev/null`
- SC2317 (unreachable command in trap handler) -- suppress with `# shellcheck disable=SC2317`

### Host Alias Validation

### Research Insights: Security -- Input Validation

The host alias is a user-provided CLI argument passed directly to SSH. **Validate it** to prevent command injection:

```bash
if [[ ! "$host" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "FATAL: Invalid host alias: contains disallowed characters" >&2
    exit "$EXIT_USAGE"
fi
```

Additionally, verify the host resolves to a non-default configuration via `ssh -G` output parsing (check that `hostname`
is not the literal alias, which would indicate no matching SSH config entry).

### `--base-dir` Sanitization

### Research Insights: Security -- Path Traversal Prevention

The `--base-dir` argument is interpolated into remote `find` commands. **Sanitize it**:

- Reject values containing `..`, `;`, `|`, `$`, backticks, or other shell metacharacters
- Require it to be an absolute path starting with `/` or `~/`
- Pass it as a positional argument to a heredoc script (not interpolated into a command string)

### Repo Discovery

- A "repo" is any directory containing `.git/` under the base dir
- Discovery depth: `find ~/dev -maxdepth 3 -name .git -type d` covers `~/dev/repo/` and `~/dev/org/repo/`
- Repos are identified by their path relative to `~/dev/`

### Research Insights: Discovery Depth Limitation

The `maxdepth 3` limit means repos at `~/dev/org/team/project/` (depth 4) are missed. Document this limitation in
`--help` output. Workaround: `--base-dir ~/dev/org/team` narrows the search scope.

### AGENT.md / AGENTS.md Recursive Search

- Prune vendored directories: `node_modules`, `vendor`, `.venv`, `target`, `build`, `dist`, `.git`
- Follow symlinks for config files (not for directory traversal)

### Research Insights: Extended Prune List

Add commonly missed directories: `__pycache__`, `.tox`, `.mypy_cache`, `.pytest_cache`, `coverage`, `.next`, `.nuxt`,
`.cache`, `.terraform`, `pkg`. Define the prune list as an **array variable** at the top of the script for
maintainability:

```bash
PRUNE_DIRS=(node_modules vendor .venv target build dist .git __pycache__ .tox .mypy_cache .pytest_cache coverage .next .nuxt .cache .terraform pkg)
```

### Transfer Mechanism

### Research Insights: Batch Transfer Architecture (Key Enhancement)

**The user asked:** "Is it possible to find all required files and then do a batch transfer? That would likely be
quicker than multiple rsyncs. If not for all repos at once, then at the remote repo level?"

**Answer: Yes, and it should be done at the all-repos-at-once level.**

#### Why Batch Beats Per-Repo

| Approach                       | SSH Connections         | Overhead                                      | Best For                               |
| ------------------------------ | ----------------------- | --------------------------------------------- | -------------------------------------- |
| Per-repo rsync (original plan) | N (one per repo)        | High: N TCP handshakes + N rsync negotiations | Large files, incremental sync          |
| Per-repo rsync + ControlMaster | 1 TCP, N rsync sessions | Medium: N rsync negotiations over one TCP     | Incremental sync with connection reuse |
| Single `find \| tar` pipeline  | 1 TCP, 1 session        | **Minimal**: one streaming transfer           | **Small text files (our case)**        |
| rsync `--files-from`           | 1 TCP, 1 rsync session  | Low: one rsync with file list                 | Mix of small and large files           |

For this use case (5-50 repos, 1-10 small text config files each, total payload likely under 1 MB), either the **tar
pipeline** or **rsync `--files-from`** approach is appropriate. Both reduce the operation to 1-2 SSH sessions total.

**Performance oracle recommendation:** `rsync --files-from` is the best balance of simplicity and performance (2 SSH
sessions: 1 discover + 1 transfer). The tar pipeline saves one SSH invocation but couples discovery and transfer, making
error handling and path remapping harder. The marginal 100-200ms savings is not worth the added complexity at this
scale.

**Simplicity reviewer counterpoint:** Ubuntu always ships rsync (`ubuntu-minimal` dependency). The tar fallback is YAGNI
-- if rsync is missing, that indicates a broken deployment worth investigating, not something to silently paper over.
**Use rsync. One code path. Fail if missing.**

#### Recommended Architecture: Two-Phase Single-Session

**Phase 1: Discovery + file list generation (single SSH command)**

```bash
ssh "${SSH_OPTS[@]}" "$host" bash -s -- "$base_dir" << 'REMOTE_SCRIPT'
set -euo pipefail
base_dir="${1:-$HOME/dev}"
[[ -d "$base_dir" ]] || { echo "NOTE: $base_dir does not exist" >&2; exit 0; }

# Find all repos
while IFS= read -r -d '' gitdir; do
    repo_dir="${gitdir%/.git}"
    repo_rel="${repo_dir#$base_dir/}"

    # Direct checks (repo root and .claude/ dir)
    for f in CLAUDE.md .claude/settings.local.json .claude/CLAUDE.md; do
        [[ -f "$repo_dir/$f" ]] && printf '%s\0' "$repo_rel/$f"
    done

    # Glob checks (.claude/commands/*.md, .claude/agents/*.md)
    for glob_dir in .claude/commands .claude/agents; do
        if [[ -d "$repo_dir/$glob_dir" ]]; then
            for f in "$repo_dir/$glob_dir"/*.md; do
                [[ -f "$f" ]] && printf '%s\0' "$repo_rel/${f#$repo_dir/}"
            done
        fi
    done

    # Recursive search for AGENT.md / AGENTS.md with pruning
    find "$repo_dir" \
        \( -name node_modules -o -name vendor -o -name .venv -o -name target \
           -o -name build -o -name dist -o -name .git -o -name __pycache__ \
           -o -name .cache -o -name .terraform \) -prune -o \
        \( -name AGENT.md -o -name AGENTS.md \) -print0 |
    while IFS= read -r -d '' agent_file; do
        # Skip binary/git-crypt locked files
        if grep -qI '' "$agent_file" 2>/dev/null; then
            printf '%s\0' "$repo_rel/${agent_file#$repo_dir/}"
        fi
    done

done < <(find "$base_dir" -maxdepth 3 -name .git -type d -print0)
REMOTE_SCRIPT
```

**Phase 2: Batch transfer (single tar pipe)**

```bash
# file_list populated from Phase 1 output
ssh "${SSH_OPTS[@]}" "$host" \
    tar czf - -C "$base_dir" --null -T - < <(printf '%s\0' "${file_list[@]}") |
    tar xzf - --no-same-permissions --no-same-owner -C "$tmpdir"
```

This approach combines discovery and transfer into a single SSH session (thanks to ControlMaster), with discovery
generating a NUL-delimited file list that feeds directly into a single `tar` pipeline.

#### Alternative: rsync `--files-from`

If rsync is preferred (e.g., for incremental re-sync of large files in future scope):

```bash
# Generate file list on remote, pipe to local rsync
ssh "${SSH_OPTS[@]}" "$host" '...' |  # NUL-delimited file list
rsync -avz --files-from=- -0 -e "ssh ${SSH_OPTS[*]}" "$host:$base_dir/" "$tmpdir/"
```

The `--files-from=-` reads from stdin, `-0` expects NUL-delimited input. This runs a **single rsync session** over the
ControlMaster connection with an exact file list -- no per-file negotiation waste.

#### Implementation Decision: Choose One Transfer Mechanism

Two viable options exist. **Choose one, not both** (per simplicity reviewer: two code paths that must produce identical
results is a maintenance burden with no payoff):

**Option A: `rsync --files-from` (recommended)**

- Requires rsync on both ends (guaranteed on Ubuntu, available via Homebrew on macOS)
- Clean separation: Phase 1 discovers files, Phase 2 transfers them
- rsync handles path remapping, error reporting, and partial failure naturally
- Future-proof: adding incremental sync is trivial
- Drop `-z` on LAN (compression overhead exceeds savings for sub-10KB files); keep for WAN

**Option B: `find | tar` pipeline**

- Requires only `tar` (POSIX standard, universal)
- Slightly faster (1 SSH session vs 2), but marginal at this scale
- Couples discovery and transfer, complicating error handling
- Path remapping requires manual `tar --transform` or `-C` flags
- No incremental sync capability

If rsync is missing on the remote, fail with `FATAL:` and `EXIT_DEPENDENCY` rather than silently falling back.

### Diff Tool Evaluation: diff vs diff3 vs colordiff

### Research Insights: diff3 Is Not Applicable Here

The user asked whether `diff3` would be better than `diff` or `colordiff`. The answer is **no -- diff3 solves a
different problem**.

| Tool        | Purpose                              | Applicable?                                           |
| ----------- | ------------------------------------ | ----------------------------------------------------- |
| `diff`      | Two-way file/directory comparison    | **Yes** -- comparing old staging vs new staging       |
| `colordiff` | Color wrapper around `diff`          | **Yes** -- improves readability, optional enhancement |
| `diff3`     | Three-way merge (mine, older, yours) | **No** -- requires a common ancestor file             |

`diff3` is designed for merge conflict resolution: given three versions of a file (your version, the common ancestor,
and their version), it produces a merged output with conflict markers. This is the algorithm behind `git merge`.

For this use case (comparing the previous sync snapshot against the current remote state), there are only **two
versions**: old staging and new files. There is no common ancestor. Standard `diff -ru` (unified recursive diff) is the
correct tool.

**Implementation:**

```bash
if command -v colordiff >/dev/null 2>&1; then
    diff -ru "$old_staging" "$tmpdir" | colordiff | ${PAGER:-less -R}
else
    diff -ru "$old_staging" "$tmpdir" | ${PAGER:-less}
fi
```

### Staging Lifecycle

### Research Insights: Atomic Replacement with Sentinel

The original plan's lifecycle had an ambiguity: "show diff between old and new" implies new files exist locally, but
they haven't been pulled yet at diff time. The corrected lifecycle:

1. Pull new files into a **temp directory** (`mktemp -d` within `scripts/sync/`)
2. If prior sync exists **and** `.sync-complete` sentinel is present:

- Show `diff -ru` between old staging dir and temp dir
- If sentinel is absent: `WARNING: prior sync was incomplete, skipping diff`
1. Atomically replace: `mv "$staging_dir" "${staging_dir}.old" && mv "$tmpdir" "$staging_dir"`
2. Clean up: `rm -rf "${staging_dir}.old"`
3. Write `.sync-complete` sentinel to `"$staging_dir/.sync-complete"`

The sentinel file prevents misleading diffs against partially-transferred data from interrupted prior runs.

**Simplicity reviewer counterpoint:** The in-script diff lifecycle adds temp directory management, sentinel logic,
first-run detection, and cleanup edge cases. Consider dropping it entirely: write files directly to staging, let the
operator use `diff -r` or a file browser manually. First sync and re-sync follow the same code path. The diff is only
useful if you re-sync frequently; if you review files immediately after syncing, the diff is redundant. **Decision: keep
the diff lifecycle** (the value of seeing what changed since last sync justifies the complexity, but keep it simple --
temp dir + rename + sentinel is the minimum viable approach).

### `--dry-run` Behavior

### Research Insights: Spec Gap Filled

The original plan listed `--dry-run` in the usage line but never defined its behavior.

**Specified behavior:**

- Connects to the remote (validates SSH connectivity)
- Runs the discovery phase (finds repos and config files)
- Prints the file list that would be transferred (one file per line, grouped by repo)
- If prior staging exists, shows what the diff would contain
- Does NOT transfer any files, create/modify staging directories, or write the sentinel
- Exit code 0 on success

### Privacy

- `scripts/sync/incoming/` must be added to `.gitignore` (prevents hostname and private repo config leakage)
- Terminal output uses the SSH alias as-is (acceptable since it's user-facing, not committed)
- The privacy constraint (no hostnames in commits/docs) is satisfied by gitignoring the staging area

### Research Insights: Privacy Defense in Depth

1. **Gitignore pre-flight check**: The script must verify `scripts/sync/incoming/` is in `.gitignore` before running.
   Refuse to proceed if not. This prevents accidental commits during development/testing.
2. **Double-safety from global gitignore**: The global gitignore at `~/.config/git/ignore` already ignores
   `**/CLAUDE.md`, `**/AGENT.md`, `**/AGENTS.md`, `**/.claude/settings.local.json`. This means even if the repo-level
   `.gitignore` entry were missed, most files would still be hidden from `git status`. However, this also means **`git
   diff` cannot be used to review staged files** -- review must use `diff`, `cat`, or a file browser directly.
3. **`.gitignore` update must be the first commit** in the implementation PR, before any sync testing occurs.
4. **Staging directory permissions**: Create with `chmod 700` to prevent other users from reading synced configs.

### Script Conventions (matching stow-deploy)

- `#!/usr/bin/env bash` with `set -euo pipefail`
- Exit codes aligned with `stow-deploy` for shared categories:

| Code | Name              | Meaning                                        |
| ---- | ----------------- | ---------------------------------------------- |
| 2    | `EXIT_USAGE`      | Bad arguments or flags (matches `stow-deploy`) |
| 3    | `EXIT_DEPENDENCY` | Missing required tools (matches `stow-deploy`) |
| 4    | `EXIT_SSH`        | SSH connection or authentication failure       |
| 5    | `EXIT_TRANSFER`   | File transfer failure                          |

- Error prefixes: `FATAL:`, `ERROR:`, `WARNING:`, `NOTE:` to stderr

### Research Insights: Error Prefix Convention Alignment

The original plan omitted `FATAL:`. Per `stow-deploy` convention:

- **`FATAL:`** -- unrecoverable error that terminates the script immediately (SSH connectivity failure, missing
  dependency, gitignore check failure)
- **`ERROR:`** -- per-item failure in a loop that continues (individual repo transfer failure)
- **`WARNING:`** -- non-fatal condition worth noting (empty config file, git-crypt locked file skipped)
- **`NOTE:`** -- purely informational (no repos found, discovery depth limit)

### Research Insights: Script Structure Conventions

From `stow-deploy` and documented learnings:

- **Header comment**: Brief description, rationale for single-file design, usage line
- **Section separators**: Use `# --- Section Name ---` format (matching `stow-deploy`)
- **REPO_ROOT derivation**: `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"`
- **Target file list and prune list as arrays** at script top (single source of truth, with cross-reference comment to
  the global gitignore)
- **200-line threshold**: Script will likely exceed 200 lines. Add a header comment acknowledging this is intentional
  (matching `stow-deploy` precedent of self-contained single file for operational reliability)
- **`--help` flag**: Add basic usage output (gap in both `stow-deploy` and the original plan)

### Research Insights: Cross-Platform Shell Idioms (from docs/solutions/)

From the documented learnings in this repo:

- **Binary detection**: Use `grep -qI '' "$file"` instead of `file` command (POSIX-safe, documented in
  `portable-binary-detection-sentinel-fix-and-auto-hooks.md`)
- **Git-crypt detection**: Supplement with magic header check: `head -c 10 "$file" | grep -q '^\x00GITCRYPT'`
- **Tool existence**: Use `command -v tool >/dev/null 2>&1` (never `which`)
- **Avoid `sed -i`**: BSD vs GNU incompatibility. Use parameter expansion for simple substitutions
- **Avoid `grep -oP`**: macOS BSD grep lacks PCRE. Use `sed -n 's/.../p'` for extraction
- **`$HOME` not hardcoded paths**: Never use `/Users/brett/` or `/home/brett/`
- **Non-interactive remote shells**: When running `ssh host 'command'`, zsh sources only `.zshenv`. If the remote
  command needs `$PATH` or other env vars, rely on the `.zshenv` -> `.profile` chain
- **Subshell variable loss**: Avoid `cmd | while read` when accumulating results -- use process substitution (`while
  read ... < <(cmd)`) or temp files instead
- **Bash 3.2**: If the script runs on macOS with `/bin/bash`, avoid `declare -A` (associative arrays), and use
  `"${arr[@]+"${arr[@]}"}"` for empty array safety under `set -u`. However, since we use `#!/usr/bin/env bash` and
  Homebrew bash is 5.x, this is a minor concern.

### Edge Cases

| Scenario                                     | Handling                                                        |
| -------------------------------------------- | --------------------------------------------------------------- |
| `~/dev/` doesn't exist on remote             | `NOTE:` message, exit 0                                         |
| No repos with config files found             | `NOTE:` message, exit 0                                         |
| SSH connection failure                       | `FATAL:` message, exit `EXIT_SSH`                               |
| Partial transfer failure                     | Report successes and failures, exit `EXIT_TRANSFER`             |
| Empty config files                           | Sync with `WARNING:` in summary                                 |
| Binary/locked git-crypt files                | Skip with `WARNING:` (detect via `grep -qI` + git-crypt header) |
| `scripts/sync/incoming/` not in `.gitignore` | `FATAL:` message, refuse to run                                 |
| Prior sync incomplete (no sentinel)          | `WARNING:`, skip diff, re-sync from scratch                     |
| rsync exit code 24 (files vanished)          | `WARNING:`, treat as partial success                            |
| Concurrent execution (same host)             | Race on staging dir; recommend documenting as limitation for v1 |
| Symlinked config files on remote             | Preserve symlinks (rsync default `-l`); do not follow with `-L` |
| Neither rsync nor tar on remote              | `FATAL:` message, exit `EXIT_DEPENDENCY`                        |
| Repo path with spaces/special chars          | NUL-delimited `find -print0` + `read -d ''` throughout          |
| Host alias with shell metacharacters         | Regex validation: `^[a-zA-Z0-9._-]+$`                           |

### Research Insights: Transfer Security

**rsync safety flags:**

```bash
rsync -avz --no-perms --chmod=u=rwX,go= -e "ssh ${SSH_OPTS[*]}" ...
```

- `--no-perms --chmod=u=rwX,go=` normalizes permissions (prevents setuid/world-writable from remote)
- Do NOT use `--copy-links` / `-L` (a symlink to `/etc/passwd` would copy the target file)

**tar safety flags (receiving side):**

```bash
tar xzf - --no-same-permissions --no-same-owner -C "$tmpdir"
```

- Prevents absolute path extraction and permission inheritance from remote

### Research Insights: Remote Discovery as Heredoc

Pass the discovery logic as a heredoc to `ssh host bash -s` rather than building inline command strings. This avoids
multi-level quoting issues and makes the remote logic readable and testable:

```bash
ssh "${SSH_OPTS[@]}" "$host" bash -s -- "$base_dir" << 'REMOTE_SCRIPT'
# All discovery logic here, single-quoted delimiter prevents local expansion
REMOTE_SCRIPT
```

## System-Wide Impact

- **Interaction graph**: Script is standalone. No callbacks, hooks, or chained processes. Staging area is passive (no
  auto-adopt).
- **Error propagation**: SSH and transfer errors are caught and reported. `set -e` ensures no silent failures. Distinct
  exit codes allow wrapping scripts to distinguish failure types. Critical SSH commands use explicit error checking
  rather than relying solely on `set -e`.
- **State lifecycle risks**: Staging area uses atomic temp-dir-then-rename pattern (matching `stow-deploy`'s
  `resolve_tree_fold`). Interrupted transfers leave only a temp dir that the next run cleans up via `trap`. The
  `.sync-complete` sentinel prevents misleading diffs against partial data.
- **API surface parity**: No other interfaces expose this functionality.
- **Integration test scenarios**: SSH connectivity mocking is complex; focus bats tests on argument parsing, exit codes,
  and discovery logic (mock SSH output). Consider extracting discovery logic into a testable function.

## Acceptance Criteria

- [ ] `scripts/claude-sync <host>` discovers repos under `~/dev/` on the remote and syncs config files to
  `scripts/sync/incoming/<host>/`
- [ ] Discovers all target file types: `CLAUDE.md`, `AGENT.md`, `AGENTS.md`, `.claude/settings.local.json`,
  `.claude/CLAUDE.md`, `.claude/commands/*.md`, `.claude/agents/*.md`
- [ ] AGENT.md/AGENTS.md recursive search prunes vendored directories (extended prune list)
- [ ] Repo paths in staging are relative to `~/dev/` (no name collisions)
- [ ] SSH hosts with `RemoteCommand` are handled via `-o RemoteCommand=none -o RequestTTY=no`
- [ ] Host alias is regex-validated and pre-validated with `ssh -G` + connectivity check before connecting
- [ ] Re-syncing shows diff of old vs new before replacing staging (only when sentinel confirms prior sync completeness)
- [ ] `scripts/sync/incoming/` is added to `.gitignore` (first commit in PR)
- [ ] Script pre-flight checks that `.gitignore` entry exists before running
- [ ] Exit codes align with `stow-deploy` for shared categories (USAGE=2, DEPENDENCY=3)
- [ ] Error messages use `FATAL:`/`ERROR:`/`WARNING:`/`NOTE:` prefixes to stderr
- [ ] `--base-dir` flag allows overriding `~/dev/` default with input sanitization
- [ ] `--dry-run` flag lists discoverable files without transferring
- [ ] Script passes ShellCheck
- [ ] Bats tests cover argument validation, exit codes, and input sanitization (`tests/claude-sync-args.bats`,
  `tests/claude-sync-discovery.bats`)
- [ ] All remote paths handled with NUL-delimited I/O (`-print0` / `read -d ''`)
- [ ] SSH ControlMaster used for connection reuse across discovery + transfer phases
- [ ] Atomic staging replacement (temp dir + rename) with `.sync-complete` sentinel
- [ ] Staging directory created with `chmod 700`
- [ ] `trap` cleanup on EXIT/INT/TERM removes temp dirs and closes ControlMaster

## Success Metrics

- Script successfully pulls Claude config from the test server in under 30 seconds
- All repos with config files are discovered (no false negatives within maxdepth 3)
- Staging area accurately reflects current remote state after each run
- No hostnames or private repo names leak into git history
- Single SSH connection for entire operation (ControlMaster)

## Dependencies & Risks

| Dependency                 | Status   | Risk                                                  |
| -------------------------- | -------- | ----------------------------------------------------- |
| SSH connectivity to remote | Required | SSH config already works; test host available         |
| `tar` on remote            | Required | POSIX standard; always available on Ubuntu            |
| `rsync` on remote          | Optional | Only needed if `--rsync` flag is used                 |
| `diff` on macOS            | Required | Ships with macOS; `colordiff` is optional enhancement |
| `find` on remote           | Required | POSIX standard; always available                      |
| `mktemp` on macOS          | Required | Ships with macOS (BSD mktemp)                         |

**Risks:**

- Large repos with deep directory trees could slow AGENT.md discovery -- mitigated by extended prune list
- SSH `RemoteCommand` on certain host aliases -- mitigated by override flags in `SSH_OPTS`
- Privacy leakage if `.gitignore` update is forgotten -- mitigated by pre-flight check that refuses to run
- `maxdepth 3` misses deeply nested repos -- mitigated by documenting limitation and `--base-dir` workaround
- Concurrent execution could corrupt staging -- mitigated by documenting as v1 limitation (atomic replacement reduces
  window)

## Sources & References

### Internal References

- Script conventions: `scripts/stow-deploy` (flag parsing, exit codes, error output patterns)
- Existing sync pattern: `scripts/sync/sync_dev_to_icloud.sh` (rsync usage, legacy conventions)
- SSH config: `stow/ssh/dot-ssh/config` (host aliases, RemoteCommand patterns)
- Global gitignore: `stow/git/dot-config/git/ignore` (AGENT.md and AGENTS.md entries)
- Claude stow package: `stow/claude/dot-claude/` (local Claude config structure)
- Shell idiom hardening: `docs/solutions/deployment-issues/cross-platform-shell-idiom-and-config-hardening.md`
- Headless signing/hooks: `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- Binary detection: `docs/solutions/deployment-issues/portable-binary-detection-sentinel-fix-and-auto-hooks.md`
- Stow-deploy conventions: `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md`
- Shell config chain: `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`
- Error conventions: `docs/solutions/configuration-fixes/todo-backlog-resolution-and-convention-enforcement.md`

### External References

- [diff3 -- Wikipedia](https://en.wikipedia.org/wiki/Diff3) -- three-way merge algorithm (not applicable)
- [GNU diff3 manual](https://www.gnu.org/software/diffutils/manual/html_node/diff3-Merging.html)
- [Slant: Best Linux diff tools](https://www.slant.co/topics/5882/~linux-diff-tools)
- [Resilio: How to rsync large numbers of files faster](https://www.resilio.com/blog/rsync-large-number-of-files)
-
  [Jeff Geerling: 4x faster sync with rclone vs rsync](https://www.jeffgeerling.com/blog/2025/4x-faster-network-file-sync-rclone-vs-rsync/)
- [NixCraft: tar over SSH](https://www.cyberciti.biz/faq/howto-use-tar-command-through-network-over-ssh-session/)
- [CSC Docs: tar + SSH for many small files](https://docs.csc.fi/data/moving/tar_ssh/)
- [rsync man page -- `--files-from`](https://man7.org/linux/man-pages/man1/rsync.1.html)
- [BashFAQ/105 -- Why doesn't set -e do what I expected?](https://mywiki.wooledge.org/BashFAQ/105)
- [ShellCheck: SC2029](https://www.shellcheck.net/wiki/SC2029) -- SSH variable expansion
- [ShellCheck: SC2095](https://www.shellcheck.net/wiki/SC2095) -- SSH stdin consumption

### Related Patterns

- Deployment is currently push-only (`stow-deploy`). This script introduces the first pull/sync pattern.
- `scripts/sync/logs/` already gitignored -- follows the same pattern for `scripts/sync/incoming/`.
