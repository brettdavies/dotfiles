#!/usr/bin/env python3
"""Convert a subagent jsonl transcript to GitHub-flavored markdown.

cc2md handles top-level Claude Code session jsonl but not the subagent
shape (different fields, no top-level session metadata). This converter
reads `~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl`
and emits markdown that looks similar enough to cc2md output that the
gitleaks redaction shim and qmd treat both as one corpus.

Output goes to stdout (default) or `-o <path>`.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def fmt_text(text: str) -> str:
    return text.rstrip() + "\n"


def render_user_content(content: Any) -> str:
    if isinstance(content, str):
        return fmt_text(content)
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            kind = item.get("type")
            if kind == "text":
                parts.append(fmt_text(item.get("text", "")))
            elif kind == "tool_result":
                tool_id = item.get("tool_use_id", "")
                result = item.get("content", "")
                if isinstance(result, list):
                    inner: list[str] = []
                    for r in result:
                        if isinstance(r, dict) and r.get("type") == "text":
                            inner.append(r.get("text", ""))
                    result_text = "\n".join(inner)
                else:
                    result_text = str(result)
                parts.append(
                    f"<details>\n<summary>tool_result ({tool_id})</summary>\n\n```\n{result_text.rstrip()}\n```\n\n</details>\n"
                )
            elif kind == "image":
                parts.append("_[image elided]_\n")
            else:
                parts.append(f"_[unhandled user content type: {kind}]_\n")
        return "".join(parts)
    return ""


def render_assistant_content(content: Any) -> str:
    if not isinstance(content, list):
        return fmt_text(str(content))
    parts: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        kind = item.get("type")
        if kind == "text":
            parts.append(fmt_text(item.get("text", "")))
        elif kind == "thinking":
            thinking_text = item.get("thinking", "")
            parts.append(
                f"<details>\n<summary>thinking</summary>\n\n{thinking_text.rstrip()}\n\n</details>\n"
            )
        elif kind == "tool_use":
            tool_name = item.get("name", "")
            tool_id = item.get("id", "")
            tool_input = item.get("input", {})
            input_json = json.dumps(tool_input, indent=2, ensure_ascii=False)
            parts.append(
                f"<details>\n<summary>tool_use: {tool_name} ({tool_id})</summary>\n\n```json\n{input_json}\n```\n\n</details>\n"
            )
        else:
            parts.append(f"_[unhandled assistant content type: {kind}]_\n")
    return "".join(parts)


def parse_first_record(records: list[dict[str, Any]]) -> dict[str, str]:
    for rec in records:
        if rec.get("type") in ("user", "assistant") and rec.get("agentId"):
            return {
                "agent_id": str(rec.get("agentId", "")),
                "session_id": str(rec.get("sessionId", "")),
                "cwd": str(rec.get("cwd", "")),
                "git_branch": str(rec.get("gitBranch", "")),
                "entrypoint": str(rec.get("entrypoint", "")),
                "first_ts": str(rec.get("timestamp", "")),
                "version": str(rec.get("version", "")),
            }
    return {"agent_id": "", "session_id": "", "cwd": "", "git_branch": "", "entrypoint": "", "first_ts": "", "version": ""}


def render_header(meta: dict[str, str], model: str) -> str:
    rows = [
        f"| First message | {meta['first_ts']} |",
        f"| Parent Session | {meta['session_id']} |",
        f"| Agent ID | {meta['agent_id']} |",
        f"| Model | {model} |",
        f"| Working Directory | {meta['cwd']} |",
        f"| Branch | {meta['git_branch']} |",
        f"| Entrypoint | {meta['entrypoint']} |",
        f"| Version | {meta['version']} |",
    ]
    table = "| Field | Value |\n|-------|-------|\n" + "\n".join(rows) + "\n"
    return (
        "# Subagent Session\n\n"
        "> [!NOTE]\n"
        "> Blue blocks are **user** messages\n\n"
        "> [!TIP]\n"
        "> Green blocks are **assistant** responses\n\n"
        + table
        + "\n---\n\n"
    )


def render(records: list[dict[str, Any]]) -> str:
    meta = parse_first_record(records)
    model = ""
    body_parts: list[str] = []

    for rec in records:
        if not isinstance(rec, dict):
            continue
        kind = rec.get("type")
        msg = rec.get("message") or {}

        if kind == "user":
            content = msg.get("content")
            if content is None:
                continue
            rendered = render_user_content(content)
            if rendered.strip():
                body_parts.append(f"## User\n\n{rendered}\n")
        elif kind == "assistant":
            if not model:
                model = str(msg.get("model", ""))
            content = msg.get("content")
            rendered = render_assistant_content(content)
            if rendered.strip():
                body_parts.append(f"## Assistant\n\n{rendered}\n")
        elif kind == "attachment":
            attachment = rec.get("attachment") or {}
            atype = attachment.get("type", "")
            body_parts.append(f"_[attachment: {atype}]_\n\n")

    header = render_header(meta, model or "(unknown)")
    return header + "".join(body_parts)


def load_records(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            records.append({"type": "_parse_error", "raw": line[:200]})
    return records


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Convert subagent jsonl to markdown.")
    parser.add_argument("input", help="Path to subagent jsonl.")
    parser.add_argument("-o", "--output", default=None, help="Write to this file instead of stdout.")
    args = parser.parse_args(argv)

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"subagent-to-md: input not found: {input_path}", file=sys.stderr)
        return 2

    records = load_records(input_path)
    rendered = render(records)

    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
