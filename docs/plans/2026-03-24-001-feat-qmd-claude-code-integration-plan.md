---
title: "feat: Integrate qmd search into Claude Code workflows"
type: feat
status: completed
date: 2026-03-24
origin: docs/brainstorms/2026-03-24-qmd-claude-code-integration-brainstorm.md
---

# feat: Integrate qmd search into Claude Code workflows

## Overview

Wire [qmd](https://github.com/tobi/qmd) — a local hybrid search engine for markdown documents — into Claude Code's
search and discovery workflows via CLI + custom skill + SessionStart hook. QMD gives Claude BM25, vector, and hybrid
search across the Obsidian vault, solutions-docs, skills, and GitHub stars collections (3,624 files, 21,240 vector
embeddings).

## Problem Statement / Motivation

Claude Code currently has no awareness of the user's personal knowledge base (Obsidian vault), compounded solutions
(`docs/solutions/`), or skill library (`~/.claude/skills/`). The learnings-researcher agent uses Grep/Glob against
`docs/solutions/` which only works for exact keyword matches. Natural language queries like "how did we handle headless
deployment" return nothing useful via grep but rank 0.91 in qmd's hybrid search.

## Proposed Solution

CLI via Bash + custom SKILL.md + SessionStart hook (see brainstorm:
`docs/brainstorms/2026-03-24-qmd-claude-code-integration-brainstorm.md`).

- **No MCP server** — zero memory overhead; qmd's `--files` and `--json` output modes are already agent-optimized
- **No marketplace plugin** — less customizable than a tailored skill
- **Collections already indexed** — `solutions` (63 docs) and `skills` (106 docs) were added and embedded during
  brainstorming

## QMD Search Commands: Tradeoffs and Score Optimization

### Command Comparison

| Command | What it does | Speed | Score range | Best for |
|---------|-------------|-------|-------------|----------|
| `qmd search` | BM25 full-text via SQLite FTS5 | ~30ms | 0.0-1.0 (normalized from raw 0-25+) | Exact keywords, function names, error messages, specific terms |
| `qmd vsearch` | Vector semantic via sqlite-vec embeddings | ~2s (cold: ~5s) | 0.0-1.0 (1/(1+cosine_distance)) | Conceptual queries, paraphrases, "how to" questions, synonyms |
| `qmd query` | Hybrid: BM25 + vector + LLM query expansion + RRF fusion + LLM reranking | ~10s | 0.0-1.0 (blended) | Ambiguous queries, broad discovery, highest-quality results |

### How `qmd query` Works Internally

1. **BM25 probe** — fast keyword scan for strong signals
2. **Signal check** — if top BM25 score >= 0.85 AND gap to #2 >= 0.15, skip expensive expansion (already found it)
3. **Query expansion** — fine-tuned 1.7B LLM generates 2 variant queries (lexical + vector/HyDE types)
4. **Parallel search** — routes sub-queries: `lex` variants to BM25, `vec`/`hyde` variants to vector
5. **RRF fusion** (k=60) — merges ranked lists with position weighting (original query lists get 2x weight, rank #1 gets
   +0.05 bonus)
6. **Chunking** — picks best ~800-token chunk per document for reranking
7. **LLM rerank** — cross-encoder scores chunks against original query
8. **Position-aware blending** — protects high-confidence retrieval from reranker disagreement:

- Rank 1-3: 75% retrieval / 25% reranker
- Rank 4-10: 60% retrieval / 40% reranker
- Rank 11+: 40% retrieval / 60% reranker

### Score Interpretation

| Score | Meaning | Action |
|-------|---------|--------|
| 0.8-1.0 | Highly relevant | Read immediately with `qmd get` |
| 0.5-0.8 | Likely relevant | Worth reading, check snippet first |
| 0.3-0.5 | Possibly relevant | Skim title/snippet, read if promising |
| 0.0-0.3 | Weak match | Usually noise; skip unless nothing better |

### How to Get Higher Scores

**For BM25 (`qmd search`):**

- Use exact terms that appear in documents (file names, headings, specific phrases)
- Avoid natural language — "stow deployment conflict" scores better than "how do I handle conflicts when deploying with
  stow"
- BM25 scores filepath, title, and body — matching a title or filename boosts score significantly
- Multiple distinct terms beat long phrases: `stow conflict resolution` > `the stow conflict resolution wrapper`

**For vector (`qmd vsearch`):**

- Natural language works better — "how to sign git commits on headless servers" outperforms bare keywords
- Rephrase if needed — different phrasings activate different embedding dimensions
- Keep queries focused — one clear concept per search, not multi-topic

**For hybrid (`qmd query`):**

- Use natural, descriptive queries — the LLM expansion handles generating keyword variants automatically
- The `--intent` flag can disambiguate: `qmd query "deploy" --intent "dotfiles stow deployment, not CI/CD"`
- Broader queries benefit more from hybrid than narrow ones (for narrow keyword matches, `qmd search` is sufficient and
  300x faster)

**General tips for all modes:**

- `-c collection` focuses search on relevant collections, improving signal-to-noise ratio
- Multiple `-c` flags work: `-c solutions -c vault`
- `-n 10` returns more candidates (default 5 for CLI, 20 for `--files`/`--json`)
- `--min-score 0.3` filters weak matches
- `--explain` shows scoring breakdown per result (useful for debugging)

### Recommended Escalation Ladder

```text
1. qmd search "<query>" -c solutions -c vault --files -n 10
   Fast BM25 (~30ms). Try this first.
   If top score >= 0.5 --> good enough, read the hits.

2. qmd vsearch "<query>" -c solutions -c vault --files -n 10
   Semantic search (~2s). Use when BM25 returns low scores or no relevant hits.
   Natural language queries benefit most here.

3. qmd query "<query>" --files -n 10
   Hybrid pipeline (~10s). Use when both BM25 and vector miss.
   Broadens to all collections (stars, NAS) for maximum recall.
   Reserve for ambiguous or broad discovery queries.
```

## Implementation Phases

### Phase 1: Permissions and SessionStart Hook

**Files to modify:**

- `~/.claude/settings.json` — add `Bash(qmd:*)` to allowed permissions
- `~/.claude/session-context.sh` — add qmd status section

**`settings.json` change:**

Add `"Bash(qmd:*)"` to the `permissions.allow` array, alphabetically between `"Bash(pwd:*)"` and
`"Bash(readlink:*)"`.

**`session-context.sh` change:**

Add a new section block following the existing pattern:

```bash
echo ''
echo '--- qmd collections ---'
if command -v qmd >/dev/null 2>&1; then
  qmd collection list 2>/dev/null || echo '(qmd: no collections configured)'
else
  echo '(qmd not installed)'
fi
```

Use `qmd collection list` instead of `qmd status` — it's faster (no DB size calculation) and gives Claude just the
collection names, paths, and file counts needed to route queries. Guard with `command -v` so sessions on machines
without qmd don't break.

**Acceptance criteria:**

- [x] `qmd` commands run without permission prompts
- [x] SessionStart context shows qmd collections (or graceful "not installed" message)
- [x] Sessions on machines without qmd work normally (no errors)

### Phase 2: Custom Skill

**Files to create:**

- `~/.claude/skills/qmd/SKILL.md` — main skill definition
- `~/.claude/skills/qmd/references/search-guide.md` — detailed search mode reference

**SKILL.md structure** (following 1password/box/gogcli pattern):

```yaml
---
name: qmd
description: >
  Search personal markdown knowledge bases, notes, meeting transcripts, and documentation
  using qmd — a local hybrid search engine. Combines BM25 keyword search, vector semantic search,
  and LLM re-ranking. Use when searching notes, finding docs, looking up solutions, checking vault,
  searching stars, or querying the knowledge base.
---
```

**Body sections:**

1. **Search Commands** — three-tier escalation ladder with speed/quality tradeoffs
2. **Collection Routing** — which collection to search based on query type (`solutions`, `vault`, `stars`, `skills`)
3. **Output Formats** — `--files` for discovery, `--json` for structured results, `qmd get` for full docs
4. **Score Interpretation** — table with score ranges and recommended actions
5. **Tips for Better Results** — keyword vs. natural language guidance per mode
6. **Workflow Integration** — when to search during /plan, /compound, and general research
7. Reference link to `references/search-guide.md` for the full scoring internals

**`references/search-guide.md`** contains the detailed scoring mechanics, RRF fusion explanation, query expansion
internals, and `--explain` output interpretation from the "QMD Search Commands" section above.

**Acceptance criteria:**

- [x] Skill auto-discovered when Claude sees trigger words ("search notes", "find in docs", etc.)
- [x] SKILL.md under 200 lines (following create-agent-skills guidance to keep it under 500, targeting concise)
- [x] References dir contains the full search guide for deep dives
- [x] No `allowed-tools` or `disable-model-invocation` in frontmatter (background knowledge skill pattern)

### Phase 3: Global CLAUDE.md Update

**File to modify:**

- `~/.claude/CLAUDE.md` — add qmd to `## CLI Tool Preferences` section

**Change:**

Add a bullet point in the CLI Tool Preferences section (after the `rg`/`ast-grep` entries):

```markdown
- **For knowledge base search,** use [`qmd`](https://github.com/tobi/qmd) to search the Obsidian vault,
  solutions-docs, and skills collections. Prefer `qmd search` (BM25, ~30ms) for keyword queries; escalate to
  `qmd vsearch` (vector, ~2s) for semantic queries; use `qmd query` (hybrid, ~10s) only for broad discovery. Always
  search qmd before researching from scratch — check solutions and vault for prior art.
```

This provides the global trigger ("always search qmd before researching from scratch") while the skill provides the
detailed method.

**Acceptance criteria:**

- [x] CLAUDE.md instructs Claude to search qmd before researching from scratch
- [x] Instruction is concise (2-3 lines) and references the escalation pattern
- [x] Placed in CLI Tool Preferences section, consistent with existing entries

### Phase 4: Verification

**Test scenarios:**

1. **New session** — verify `qmd collection list` appears in SessionStart context
2. **Keyword search** — ask Claude to "search solutions for stow deployment" and verify it runs `qmd search`
3. **Semantic search** — ask Claude "what do my notes say about headless git signing" and verify escalation to `qmd
   vsearch` if BM25 scores low
4. **Skill discovery** — verify skill triggers on phrases like "check my vault", "search notes", "find in docs"
5. **Graceful degradation** — confirm no errors when qmd is unavailable (headless server scenario, if testable)

## Dependencies and Risks

**Dependencies:**

- qmd v2.0.1 installed via `bun install -g @tobilu/qmd` (already present)
- Collections `solutions` and `skills` already indexed and embedded (done during brainstorm)
- `~/.claude/skills/` is a git repo (for version control)

**Risks:**

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| qmd cold start loads models into memory | Medium | Medium | Only happens for vsearch/query; search is pure SQLite. Models unload after 5min idle. |
| SessionStart hook adds latency | Low | Low | `qmd collection list` is ~30ms against SQLite. Guarded with `command -v`. |
| Skill not discovered by Claude | Low | Medium | Description includes explicit trigger keywords. Test with trigger phrases. |
| Solutions/skills collections go stale | Medium | Low | Run `qmd update` periodically. Could add to a hook later. |

## Sources

### Origin

- **Brainstorm:**
  [docs/brainstorms/2026-03-24-qmd-claude-code-integration-brainstorm.md](docs/brainstorms/2026-03-24-qmd-claude-code-integration-brainstorm.md)
  — key decisions: CLI via Bash (no MCP), personal skill location, eager embedding, dual augmentation

### Internal References

- Skill pattern: `~/.claude/skills/1password/SKILL.md`, `~/.claude/skills/box/SKILL.md`,
  `~/.claude/skills/gogcli/SKILL.md`
- Skill authoring guide: `~/.claude/skills/create-agent-skills/SKILL.md`
- SessionStart hook: `~/.claude/session-context.sh`
- Settings permissions: `~/.claude/settings.json`
- CLAUDE.md CLI section: `~/.claude/CLAUDE.md` (## CLI Tool Preferences)

### External References

- [tobi/qmd README](https://github.com/tobi/qmd) — CLI reference and MCP docs
- [qmd official SKILL.md](https://github.com/tobi/qmd/tree/main/skills/qmd) — upstream skill reference
- [qmd-sessions](https://github.com/wbelk/claude-qmd-sessions) — session memory pattern (deferred)

### Prior Solutions

- `solutions/integration-issues/node-llama-cpp-gpu-vram-management.md` — GPU VRAM management for qmd embed
- `solutions/code-quality/embed-file-size-limit-review-remediation.md` — file size guard for embeddings
