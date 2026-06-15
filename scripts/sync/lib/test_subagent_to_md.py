#!/usr/bin/env python3
"""Tests for subagent-to-md.py.

Run: python3 scripts/sync/lib/test_subagent_to_md.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SHIM_PATH = SCRIPT_DIR / "subagent-to-md.py"

spec = importlib.util.spec_from_file_location("subagent_to_md", SHIM_PATH)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
sys.modules["subagent_to_md"] = mod
spec.loader.exec_module(mod)


def make_user(content, session="parent-1", agent="agent-1", ts="2026-06-10T10:00:00Z"):
    return {
        "type": "user",
        "sessionId": session,
        "agentId": agent,
        "timestamp": ts,
        "message": {"role": "user", "content": content},
    }


def make_assistant(content, model="claude-haiku-4-5", session="parent-1", agent="agent-1", ts="2026-06-10T10:00:05Z"):
    return {
        "type": "assistant",
        "sessionId": session,
        "agentId": agent,
        "timestamp": ts,
        "message": {"role": "assistant", "model": model, "content": content},
    }


class SubagentToMdTest(unittest.TestCase):
    def _render(self, records):
        return mod.render(records)

    def test_string_user_content(self):
        out = self._render([make_user("Hello, do the thing.")])
        self.assertIn("# Subagent Session", out)
        self.assertIn("## User", out)
        self.assertIn("Hello, do the thing.", out)

    def test_assistant_text_block(self):
        records = [make_user("Q"), make_assistant([{"type": "text", "text": "A"}])]
        out = self._render(records)
        self.assertIn("## Assistant", out)
        self.assertIn("A", out)
        self.assertIn("claude-haiku-4-5", out)

    def test_assistant_tool_use_collapses(self):
        records = [
            make_assistant([
                {"type": "tool_use", "id": "tu_1", "name": "Bash", "input": {"command": "ls"}}
            ])
        ]
        out = self._render(records)
        self.assertIn("<details>", out)
        self.assertIn("tool_use: Bash", out)
        self.assertIn('"command": "ls"', out)

    def test_assistant_thinking_collapses(self):
        records = [make_assistant([{"type": "thinking", "thinking": "Let me reason."}])]
        out = self._render(records)
        self.assertIn("<summary>thinking</summary>", out)
        self.assertIn("Let me reason.", out)

    def test_user_tool_result(self):
        records = [
            make_user([
                {"type": "tool_result", "tool_use_id": "tu_1", "content": "file1\nfile2\n"}
            ])
        ]
        out = self._render(records)
        self.assertIn("tool_result (tu_1)", out)
        self.assertIn("file1", out)

    def test_attachment_annotated(self):
        records = [
            {"type": "attachment", "attachment": {"type": "deferred_tools_delta"}, "agentId": "x", "sessionId": "y", "timestamp": "z"}
        ]
        out = self._render(records)
        self.assertIn("attachment: deferred_tools_delta", out)

    def test_header_metadata_from_first_real_record(self):
        records = [
            {"type": "attachment", "attachment": {"type": "x"}},
            make_user("hi", session="parent-42", agent="agent-99", ts="2026-06-15T01:02:03Z"),
        ]
        out = self._render(records)
        self.assertIn("parent-42", out)
        self.assertIn("agent-99", out)
        self.assertIn("2026-06-15T01:02:03Z", out)

    def test_main_writes_to_output_file(self):
        records = [make_user("hello"), make_assistant([{"type": "text", "text": "world"}])]
        with tempfile.TemporaryDirectory() as td:
            in_path = Path(td) / "in.jsonl"
            in_path.write_text("\n".join(json.dumps(r) for r in records))
            out_path = Path(td) / "out.md"
            rc = mod.main([str(in_path), "-o", str(out_path)])
            self.assertEqual(rc, 0)
            text = out_path.read_text()
            self.assertIn("hello", text)
            self.assertIn("world", text)

    def test_parse_error_recovers(self):
        with tempfile.TemporaryDirectory() as td:
            in_path = Path(td) / "in.jsonl"
            in_path.write_text(
                json.dumps(make_user("ok")) + "\n"
                + "{this is not json}\n"
                + json.dumps(make_assistant([{"type": "text", "text": "still works"}])) + "\n"
            )
            captured: list[str] = []

            class FakeStdout:
                def write(self, s):
                    captured.append(s)
                    return len(s)

            real = sys.stdout
            sys.stdout = FakeStdout()  # type: ignore[assignment]
            try:
                rc = mod.main([str(in_path)])
            finally:
                sys.stdout = real
            self.assertEqual(rc, 0)
            joined = "".join(captured)
            self.assertIn("ok", joined)
            self.assertIn("still works", joined)


if __name__ == "__main__":
    unittest.main()
