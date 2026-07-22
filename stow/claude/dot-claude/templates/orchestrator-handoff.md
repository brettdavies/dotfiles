# Orchestrator handoff — pointer

The canonical handoff template lives in the `orchestrator-handoff` skill:

- Deployed path: `~/.claude/skills/orchestrator-handoff/templates/handoff.md`
- Source of truth: the `orchestrator-handoff` skill in the agent-skills repo

Invoke the skill (`/orchestrator-handoff [plan-path]`) rather than copying a template by hand: it scans the plan, builds
the per-unit dispatch map with worker goal text, runs the requirements-coverage and gate-reopening checks, writes the
filled handoff to `.context/handoffs/`, and prints the copy-paste goal for a fresh orchestrator session.

This file stays only so existing references to `~/.claude/templates/orchestrator-handoff.md` resolve; do not extend it —
extend the skill's template.
