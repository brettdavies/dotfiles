#!/usr/bin/env python3
"""Tests for md-align-tables.py.

md-align-tables.py imports wcwidth, so run this with that dependency available:

    uv run --no-project --with wcwidth python3 -B stow/claude/dot-claude/test_md_align_tables.py

Without it the module cannot load, so every case skips rather than fails; a bare
`python3 -B` run proves nothing. tests/md-align-tables.bats supplies wcwidth
through uv.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SCRIPT_PATH = SCRIPT_DIR / "md-align-tables.py"
MDL_CONFIG = Path.home() / ".markdownlint-cli2.yaml"

try:
    spec = importlib.util.spec_from_file_location("md_align", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["md_align"] = mod
    spec.loader.exec_module(mod)
    IMPORT_ERROR: str | None = None
except ImportError as err:  # wcwidth absent
    mod = None  # type: ignore[assignment]
    IMPORT_ERROR = str(err)


def align(text: str) -> str:
    """Run the script's own pipeline over `text` and return the result."""
    return "".join(mod.process(text.splitlines(keepends=True)))


def md060_errors(text: str) -> int:
    """Count MD060 errors markdownlint reports for `text`."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "t.md"
        path.write_text(text)
        proc = subprocess.run(
            [
                "markdownlint-cli2",
                "--config",
                str(MDL_CONFIG),
                "--no-globs",
                str(path),
            ],
            capture_output=True,
            text=True,
        )
        return (proc.stdout + proc.stderr).count("MD060")


EMOJI_BODY = (
    "| Wave step | Before | After |\n"
    "| --- | --- | --- |\n"
    "| Step 4 | ⏳ pending | ✅ done |\n"
    "| Step 5 | plain | plain |\n"
)

CJK_BODY = "| Greeting | n |\n| --- | --- |\n| 你好 | 1 |\n"

ASCII_ALIGNED = (
    "| Head | Col |\n| ---- | --- |\n| a    | b   |\n| ccc  | d   |\n"
)

NO_TABLE = "# Title\n\nProse paragraph with a | pipe that is not a table.\n\n- bullet\n"


@unittest.skipIf(mod is None, f"wcwidth unavailable: {IMPORT_ERROR}")
class DisplayWidthTest(unittest.TestCase):
    def test_wide_chars_measure_two_columns(self):
        self.assertEqual(2, mod.display_width("⏳"))
        self.assertEqual(4, mod.display_width("你好"))

    def test_ascii_collapses_to_len(self):
        for s in ("", "a", "Head", "a b c"):
            self.assertEqual(len(s), mod.display_width(s))

    def test_control_chars_fall_back_to_codepoints(self):
        """wcswidth returns -1 here; the fallback must never narrow a cell."""
        s = "a\x07b"
        self.assertEqual(len(s), mod.display_width(s))


@unittest.skipIf(mod is None, f"wcwidth unavailable: {IMPORT_ERROR}")
@unittest.skipIf(
    shutil.which("markdownlint-cli2") is None or not MDL_CONFIG.is_file(),
    "markdownlint-cli2 or its global config is unavailable",
)
class MD060AgreementTest(unittest.TestCase):
    """The point of the script: what it emits must satisfy the rule it exists for."""

    def test_emoji_body_cells_satisfy_md060(self):
        self.assertEqual(0, md060_errors(align(EMOJI_BODY)))

    def test_cjk_body_cells_satisfy_md060(self):
        self.assertEqual(0, md060_errors(align(CJK_BODY)))

    def test_every_row_renders_to_one_width(self):
        """Measured here, not via the script's own helper, so this fails on the
        behavior when the width function regresses rather than tracking it."""
        from wcwidth import wcswidth

        out = align(EMOJI_BODY)
        rows = [l for l in out.split("\n") if l.startswith("|")]
        widths = {wcswidth(r) for r in rows}
        self.assertEqual(
            1,
            len(widths),
            msg=f"rows disagree on rendered width {sorted(widths)}:\n{out}",
        )


@unittest.skipIf(mod is None, f"wcwidth unavailable: {IMPORT_ERROR}")
class NoRegressionTest(unittest.TestCase):
    def test_ascii_table_is_byte_identical(self):
        self.assertEqual(ASCII_ALIGNED, align(ASCII_ALIGNED))

    def test_file_without_a_table_is_byte_identical(self):
        self.assertEqual(NO_TABLE, align(NO_TABLE))

    def test_alignment_is_idempotent(self):
        for name, src in (
            ("emoji", EMOJI_BODY),
            ("cjk", CJK_BODY),
            ("ascii", ASCII_ALIGNED),
        ):
            once = align(src)
            self.assertEqual(once, align(once), msg=f"non-idempotent: {name}")


if __name__ == "__main__":
    unittest.main()
