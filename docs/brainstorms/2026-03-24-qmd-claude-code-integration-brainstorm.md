# Brainstorm: QMD Integration into Claude Code

**Date:** 2026-03-24 **Status:** closed (shipped)

> Closed (audited 2026-05-02) — implementation landed via plan
> [`docs/plans/2026-03-24-001-feat-qmd-claude-code-integration-plan.md`](../plans/2026-03-24-001-feat-qmd-claude-code-integration-plan.md);
> all five deliverables (skill, settings.json permission, SessionStart hook, collections, embedding)
> are live. See that plan and `~/.claude/skills/qmd/SKILL.md` for the shipped surface.

## What We're Building

Integrate [qmd](https://github.com/tobi/qmd) (a local hybrid search engine for markdown documents) into Claude Code's
search and discovery workflows. QMD combines BM25 full-text search, vector semantic search, and LLM re-ranking — all
running locally via node-llama-cpp with GGUF models.

**Goals:**

1. **Knowledge retrieval** — Claude can search the Obsidian vault and solutions-docs when making decisions
2. **Session memory** — Deferred to a follow-up brainstorm (qmd-sessions pattern)
3. **Codebase discovery** — Claude uses qmd's hybrid search to find relevant docs before reading them

**Non-goals:**

- MCP server (memory overhead not justified for a local CLI tool)
- Session transcript indexing (deferred)
- Marketplace plugin (less customizable than direct CLI + skill)

## Why This Approach

### CLI via Bash + Custom Skill + SessionStart Hook

**Rejected: MCP server** — Adds a Bun process + potential node-llama-cpp model memory. QMD's CLI already has `--files`
and `--json` output modes optimized for agents. The MCP layer makes things *easier* but not *better* — it just wraps the
same CLI in a structured transport. For a read-only local tool, the indirection isn't worth the resident memory.

**Rejected: Marketplace plugin** — Auto-configures MCP + bundles Tobi's generic SKILL.md. Less customizable than a
tailored skill that understands the compound engineering workflow, collection routing, and learnings-researcher
integration.

**Chosen: CLI + Skill + Hook** — Zero overhead. Claude shells out to `qmd` only when needed. A custom SKILL.md teaches
Claude *when* and *how* to search, with collection routing tailored to this setup. A SessionStart hook injects `qmd
status` so Claude knows what's available.

## Key Decisions

### 1. Interface: CLI via Bash (no MCP server)

- Add `Bash(qmd:*)` to allowed permissions in `settings.json`
- Use `--files` format for discovery (compact: docid, score, filepath, context)
- Use `--json` for structured results when detail is needed
- Use `qmd get` for full document retrieval after discovery

### 2. New collections to add

| Collection  | Path                   | Pattern   | Purpose                                     |
| ----------- | ---------------------- | --------- | ------------------------------------------- |
| `solutions` | `~/dev/solutions-docs` | `**/*.md` | Compounded solutions from all projects      |
| `skills`    | `~/.claude/skills/`    | `**/*.md` | Skill definitions, references, scripts docs |

Run after adding:

```bash
qmd update && qmd embed
```

### 3. Custom skill at `~/.claude/skills/qmd/SKILL.md`

- **Triggers:** "search notes", "find in docs", "what do my notes say about", "look up", "check vault"
- **Search escalation ladder:**

1. `qmd search <query> -c solutions -c vault --files` — fast BM25 (~30ms)
2. `qmd vsearch <query> -c solutions -c vault --files` — semantic if BM25 misses (~2s)
3. `qmd query <query> --files` — hybrid + reranking if both miss (~10s)

- **Collection routing guidance:**
- `solutions` — implementation decisions, prior art, patterns, bug fixes
- `vault` — personal knowledge, meeting notes, references, project context
- `stars` — library/tool research, README-level documentation
- `skills` — existing skill patterns, how other skills are structured
- **Output handling:** Parse `--files` output, then `qmd get <docid>` for relevant hits

### 4. SessionStart hook: inject `qmd status`

- Add to the existing `session-context.sh` hook (or a new hook entry)
- Runs `qmd status` and outputs to stdout
- Claude sees available collections, document counts, and example commands
- Minimal overhead (~30ms for status query against SQLite)

### 5. Learnings-researcher augmentation

- The `learnings-researcher` agent currently searches `docs/solutions/` via file-based Grep/Glob
- Augment (don't replace) with: `qmd search "<topic>" -c solutions --files -n 10`
- QMD's BM25 ranking surfaces more relevant results than raw grep for natural-language queries
- Keep Grep as fallback for exact-match patterns (function names, error messages)

### 6. Integration with compound workflow

- `/plan` research phase: skill instructs Claude to search qmd before designing an approach
- `/compound` before writing: search qmd to check if a similar solution already exists
- `/review` agents: can search skills collection to verify pattern consistency

## Architecture

```text
SessionStart hook
  |
  v
session-context.sh --> qmd status (stdout)
  |
  v
Claude sees: "3455 files indexed, collections: vault, solutions, skills, stars..."
  |
  v
During work, Claude uses SKILL.md guidance:
  qmd search "query" -c solutions --files  -->  qmd get #docid
  |
  v
learnings-researcher agent also runs:
  qmd search "topic" -c solutions --files -n 10
```

## Deliverables

1. **`~/.claude/skills/qmd/SKILL.md`** — Custom skill with search guidance, collection routing, escalation ladder
2. **`settings.json` update** — Add `Bash(qmd:*)` to allowed permissions
3. **`session-context.sh` update** — Add `qmd status` output to SessionStart context
4. **`index.yml` update** — Add `solutions` and `skills` collections
5. **`qmd update && qmd embed`** — Index the new collections
6. **Learnings-researcher patch** — Add qmd search step (if agent definition is editable)

## Resolved Questions

1. **Skill location:** `~/.claude/skills/qmd/` (personal). Same pattern as all other custom skills (1password, box,
   expensify, etc.). QMD isn't on headless servers, so deploying via stow would be pointless. The skills directory is
   already a git repo.

2. **Embedding strategy:** Embed eagerly. Run `qmd update && qmd embed` immediately after adding collections. One-time
   10-20 min cost, then all three search modes work from the start.

3. **Learnings-researcher augmentation:** Both approaches. Add a global CLAUDE.md instruction ("also run `qmd search`
   before researching from scratch") AND detailed how-to in the qmd skill (escalation ladder, collection routing). The
   CLAUDE.md provides the trigger; the skill provides the method. No modification to the third-party
   compound-engineering plugin needed.

## References

- [tobi/qmd](https://github.com/tobi/qmd) — QMD source and official skill
- [qmd-sessions](https://github.com/wbelk/claude-qmd-sessions) — Session memory pattern (deferred)
- [William Belk blog post](https://www.williambelk.com/blog/qmd-sessions-claude-code-memory-with-qmd-20260303/) —
  qmd-sessions architecture
- [levineam/qmd-skill](https://github.com/levineam/qmd-skill) — Community skill reference
- [Agentic Note-Taking with Obsidian](https://www.stefanimhoff.de/agentic-note-taking-obsidian-claude-code/) — Vault
  integration pattern
