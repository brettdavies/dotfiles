#!/usr/bin/env python3
"""Tests for gitleaks-redact.py.

Run: python3 scripts/sync/lib/test_gitleaks_redact.py
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SHIM_PATH = SCRIPT_DIR / "gitleaks-redact.py"
CONFIG_PATH = SCRIPT_DIR / "gitleaks.toml"

spec = importlib.util.spec_from_file_location("gitleaks_redact", SHIM_PATH)
assert spec is not None and spec.loader is not None
gr = importlib.util.module_from_spec(spec)
sys.modules["gitleaks_redact"] = gr
spec.loader.exec_module(gr)


class GitleaksRedactTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("gitleaks") is None:
            raise unittest.SkipTest("gitleaks not on PATH")
        cls.config = CONFIG_PATH

    def _redact(self, content: str) -> tuple[str, list[dict]]:
        out, events, _ = gr.redact_text(content, self.config)
        return out, events

    def test_anthropic_key_redacted(self) -> None:
        sample = "sk-ant-api03-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefAAAA\n"
        out, _ = self._redact(sample)
        self.assertIn("[REDACTED:anthropic-key]", out)
        self.assertNotIn("sk-ant-api03-deadbeef", out)

    def test_op_uri_with_spaces_redacted(self) -> None:
        sample = "op://secrets-dev/Brave Search API Key (Paid)/credential\n"
        out, _ = self._redact(sample)
        self.assertIn("[REDACTED:op-uri]", out)
        self.assertNotIn("Brave Search API Key", out)

    def test_postgres_dsn_with_embedded_tailscale_hostname(self) -> None:
        sample = "postgresql://app:hunter2longenoughforentropy@postgres.tail42ba87.ts.net:5432/db?sslmode=disable\n"
        out, _ = self._redact(sample)
        self.assertIn("[REDACTED:gbrain-postgres-dsn]", out)
        self.assertNotIn("hunter2", out)
        self.assertNotIn("tail42ba87.ts.net", out)

    def test_bare_tailscale_hostname_redacted(self) -> None:
        sample = "mybox.tail42ba87.ts.net\n"
        out, _ = self._redact(sample)
        self.assertIn("[REDACTED:tailscale-hostname]", out)
        self.assertNotIn("tail42ba87", out)

    def test_litellm_key_assignment_redacted(self) -> None:
        sample = "LITELLM_API_KEY=sk-litellm-abcd1234deadbeefdeadbeefdeadbeef\n"
        out, _ = self._redact(sample)
        self.assertIn("[REDACTED:litellm-key]", out)
        self.assertNotIn("sk-litellm-abcd1234", out)

    def test_bearer_token_redacted(self) -> None:
        sample = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.deadbeef\n"
        out, _ = self._redact(sample)
        self.assertIn("[REDACTED:codex-proxy-token]", out)
        self.assertNotIn("eyJhbGciOi", out)

    def test_no_findings_passthrough(self) -> None:
        sample = "# A normal markdown heading\n\nDiscussing API keys in general.\n"
        out, events = self._redact(sample)
        self.assertEqual(out, sample)
        self.assertEqual(events, [])

    def test_multiple_findings_on_same_line(self) -> None:
        sample = (
            "Two creds: sk-ant-api03-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefAAAA "
            "and op://vault/item/credential\n"
        )
        out, _ = self._redact(sample)
        self.assertIn("[REDACTED:anthropic-key]", out)
        self.assertIn("[REDACTED:op-uri]", out)
        self.assertNotIn("sk-ant-api03-", out)
        self.assertNotIn("op://vault", out)

    def test_audit_jsonl_written(self) -> None:
        sample = "sk-ant-api03-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefAAAA\n"
        out, events = self._redact(sample)
        self.assertIn("[REDACTED:anthropic-key]", out)
        with tempfile.TemporaryDirectory() as td:
            jsonl = Path(td) / "audit.jsonl"
            gr.append_audit(jsonl, events, "test-input.md")
            lines = jsonl.read_text().splitlines()
            self.assertEqual(len(lines), 1)
            record = json.loads(lines[0])
            self.assertEqual(record["event"], "redacted")
            self.assertEqual(record["rule_id"], "anthropic-key")
            self.assertEqual(record["schema_version"], 1)
            self.assertEqual(record["file"], "test-input.md")

    def test_main_writes_to_stdout(self) -> None:
        sample = "sk-ant-api03-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefAAAA\n"
        with tempfile.TemporaryDirectory() as td:
            in_path = Path(td) / "in.md"
            in_path.write_text(sample)
            captured: list[str] = []

            class FakeStdout:
                def write(self, s: str) -> int:
                    captured.append(s)
                    return len(s)

            real_stdout = sys.stdout
            sys.stdout = FakeStdout()  # type: ignore[assignment]
            try:
                rc = gr.main([str(in_path)])
            finally:
                sys.stdout = real_stdout
            self.assertEqual(rc, 0)
            self.assertIn("[REDACTED:anthropic-key]", "".join(captured))

    def test_conversational_pattern_discussion_unredacted(self) -> None:
        sample = "Discussing patterns like sk-ant-X here in conversational prose.\n"
        out, events = self._redact(sample)
        self.assertEqual(out, sample)
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
