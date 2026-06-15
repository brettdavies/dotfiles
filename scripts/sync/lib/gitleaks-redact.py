#!/usr/bin/env python3
"""Redact gitleaks findings in a markdown file.

Reads a file, runs gitleaks against it (config = sibling gitleaks.toml), parses
the JSON findings, and rewrites the file content with `[REDACTED:<RuleID>]`
placeholders in place of each detected secret. Result goes to stdout.

Fail-open: on any gitleaks subprocess failure, the input is passed through
unchanged with a single warning header line, and an audit event is emitted.
The caller decides whether to abort or proceed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = SCRIPT_DIR / "gitleaks.toml"
PLACEHOLDER = "[REDACTED:{rule_id}]"
WARNING_HEADER = "<!-- [REDACTION-FAILED: gitleaks exited {code}] -->\n"


@dataclass(frozen=True)
class Finding:
    rule_id: str
    start_line: int
    end_line: int
    start_column: int
    end_column: int
    match: str
    secret: str


def parse_findings(raw: str) -> list[Finding]:
    if not raw.strip():
        return []
    data = json.loads(raw)
    return [
        Finding(
            rule_id=item["RuleID"],
            start_line=int(item["StartLine"]),
            end_line=int(item["EndLine"]),
            start_column=int(item["StartColumn"]),
            end_column=int(item["EndColumn"]),
            match=item["Match"],
            secret=item["Secret"],
        )
        for item in data
    ]


def run_gitleaks(content: str, config: Path) -> tuple[int, str, str]:
    # `errors="replace"` for stdin encoding because cc2md occasionally emits
    # terminal control sequences inside Bash tool outputs that are not valid
    # UTF-8. Without replacement, the subprocess encoder raises and the whole
    # redaction pass aborts, producing a corpus gap.
    proc = subprocess.run(
        [
            "gitleaks",
            "stdin",
            "--no-banner",
            "--config",
            str(config),
            "--report-format",
            "json",
            "--report-path",
            "/dev/stdout",
            "--exit-code",
            "0",
            "--log-level",
            "error",
        ],
        input=content.encode("utf-8", errors="replace"),
        capture_output=True,
        check=False,
    )
    return proc.returncode, proc.stdout.decode("utf-8", errors="replace"), proc.stderr.decode("utf-8", errors="replace")


def drop_contained(findings: list[Finding]) -> list[Finding]:
    """Drop findings fully contained inside another single-line finding.

    Outer match wins because the outer placeholder masks the inner secret too;
    keeping both would either double-redact or fail to find the inner match in
    the mutated line.
    """
    widest_first = sorted(
        findings,
        key=lambda f: (
            f.start_line,
            f.start_column,
            -(f.end_line * 10_000 + f.end_column),
        ),
    )
    kept: list[Finding] = []
    for f in widest_first:
        contained = False
        for k in kept:
            same_line = k.start_line == f.start_line == k.end_line == f.end_line
            if (
                same_line
                and k.start_column <= f.start_column
                and f.end_column <= k.end_column
            ):
                contained = True
                break
        if not contained:
            kept.append(f)
    return kept


def apply_redactions(content: str, findings: list[Finding]) -> tuple[str, list[dict]]:
    if not findings:
        return content, []

    audit: list[dict] = []
    deduped = drop_contained(findings)
    findings_sorted = sorted(
        deduped,
        key=lambda f: (f.start_line, f.start_column, -(f.end_column - f.start_column)),
        reverse=True,
    )

    lines = content.split("\n")
    for f in findings_sorted:
        if f.start_line < 1 or f.start_line > len(lines):
            continue
        idx = f.start_line - 1
        line = lines[idx]
        placeholder = PLACEHOLDER.format(rule_id=f.rule_id)

        if f.start_line == f.end_line and f.match in line:
            lines[idx] = line.replace(f.match, placeholder, 1)
            audit.append(
                {
                    "event": "redacted",
                    "rule_id": f.rule_id,
                    "line": f.start_line,
                    "column": f.start_column,
                }
            )
            continue

        if f.start_line != f.end_line:
            joined = "\n".join(lines[idx : f.end_line])
            if f.match in joined:
                replaced = joined.replace(f.match, placeholder, 1)
                new_segment = replaced.split("\n")
                lines[idx : f.end_line] = new_segment
                audit.append(
                    {
                        "event": "redacted",
                        "rule_id": f.rule_id,
                        "line": f.start_line,
                        "column": f.start_column,
                    }
                )
                continue

        audit.append(
            {
                "event": "redaction_skipped",
                "rule_id": f.rule_id,
                "line": f.start_line,
                "column": f.start_column,
                "reason": "match_not_found_after_prior_redactions",
            }
        )

    return "\n".join(lines), audit


def append_audit(jsonl_path: Path | None, events: list[dict], file: str) -> None:
    if jsonl_path is None or not events:
        return
    jsonl_path.parent.mkdir(parents=True, exist_ok=True)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with jsonl_path.open("a", encoding="utf-8") as fh:
        for ev in events:
            record = {"schema_version": 1, "ts": now, "file": file, **ev}
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def redact_text(content: str, config: Path) -> tuple[str, list[dict], int]:
    code, stdout, stderr = run_gitleaks(content, config)
    if code != 0:
        events = [{"event": "redaction_failed", "exit_code": code, "stderr": stderr[:512]}]
        return WARNING_HEADER.format(code=code) + content, events, code
    findings = parse_findings(stdout)
    redacted, events = apply_redactions(content, findings)
    return redacted, events, 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Redact gitleaks findings in a markdown file.")
    parser.add_argument("input", help="Path to the input markdown file.")
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG),
        help=f"Path to gitleaks config (default: {DEFAULT_CONFIG}).",
    )
    parser.add_argument(
        "--audit-jsonl",
        default=None,
        help="If set, append per-finding audit events to this JSONL path.",
    )
    args = parser.parse_args(argv)

    input_path = Path(args.input)
    config_path = Path(args.config)
    audit_path = Path(args.audit_jsonl) if args.audit_jsonl else None

    try:
        content = input_path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        print(f"gitleaks-redact: input not found: {input_path}", file=sys.stderr)
        return 2

    redacted, events, _ = redact_text(content, config_path)
    append_audit(audit_path, events, str(input_path))
    sys.stdout.write(redacted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
