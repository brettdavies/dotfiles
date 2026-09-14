#!/usr/bin/env python3
"""Tests for md-wrap.py.

Run: python3 -B stow/claude/dot-claude/test_md_wrap.py
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SCRIPT_PATH = SCRIPT_DIR / "md-wrap.py"

spec = importlib.util.spec_from_file_location("md_wrap", SCRIPT_PATH)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
sys.modules["md_wrap"] = mod
spec.loader.exec_module(mod)


NESTED = """\
- Parent bullet has a long lead-in and continuation prose that goes onto a second wrapped line here yes indeed more.
  - Child A under parent is fairly long so that it will need to wrap onto a second physical line at a narrow width.
    - Grandchild under A is also long enough to require wrapping across the configured narrow target width value now.
  - Child B under parent.
- Another parent.
"""

ORDERED_NESTED = """\
1. First ordered item that is quite long and will wrap onto a second line at the narrow width used by this sample.
2. Second ordered item.
   1. Nested ordered child that is also long enough to wrap onto a second physical line under the narrow width value.
"""

HANGING = """\
- Bullet with hanging continuation prose written on the next source line
  that should stay attached to the same list item after reflow completes here.
"""

ORPHAN = (
    "- [Some Source With A Descriptive Long Title Here]"
    "(https://example.com/a/very/long/path/that/exceeds/the/wrap/width/by/a/lot/xxxxxxxxxxxxxxxxxxxxxx)\n"
)

LIST_THEN_PROSE = """\
- bullet one is long enough to wrap onto a second physical line at the narrow target width used by this sample here.
- bullet two.

Prose paragraph one that follows the list and is also long enough to wrap onto a second physical line at this width.
Prose line two of the same paragraph.
"""

CORPUS = {
    "nested": NESTED,
    "ordered_nested": ORDERED_NESTED,
    "hanging": HANGING,
    "orphan": ORPHAN,
    "list_then_prose": LIST_THEN_PROSE,
}


class IdempotencyTest(unittest.TestCase):
    def test_second_pass_equals_first(self):
        for name, src in CORPUS.items():
            for width in (60, 80, 120):
                first = mod.wrap_markdown(src, width)
                second = mod.wrap_markdown(first, width)
                self.assertEqual(
                    first,
                    second,
                    msg=f"non-idempotent: {name} at width {width}",
                )


class StructurePreservationTest(unittest.TestCase):
    def test_nested_bullet_indent_survives(self):
        out = mod.wrap_markdown(NESTED, 80)
        lines = out.split("\n")
        self.assertTrue(
            any(l.startswith("  - Child A") for l in lines),
            msg=f"child A lost its 2-space indent:\n{out}",
        )
        self.assertTrue(
            any(l.startswith("    - Grandchild") for l in lines),
            msg=f"grandchild lost its 4-space indent:\n{out}",
        )
        self.assertTrue(
            any(l.startswith("  - Child B") for l in lines),
            msg=f"child B lost its 2-space indent:\n{out}",
        )

    def test_nested_ordered_indent_survives(self):
        out = mod.wrap_markdown(ORDERED_NESTED, 80)
        lines = out.split("\n")
        self.assertTrue(
            any(l.startswith("   1. Nested ordered") for l in lines),
            msg=f"nested ordered child lost its 3-space indent:\n{out}",
        )

    def test_wrapped_continuation_aligns_under_marker(self):
        out = mod.wrap_markdown(NESTED, 80)
        lines = out.split("\n")
        idx = next(i for i, l in enumerate(lines) if l.startswith("  - Child A"))
        cont = lines[idx + 1]
        self.assertTrue(
            cont.startswith("    ") and cont.strip(),
            msg=f"child A continuation not indented under its marker:\n{out}",
        )

    def test_long_link_marker_not_orphaned(self):
        out = mod.wrap_markdown(ORPHAN, 80)
        lines = out.split("\n")
        self.assertFalse(
            any(l.strip() in {"-", "*", "+"} for l in lines),
            msg=f"list marker orphaned onto its own line:\n{out}",
        )
        self.assertTrue(
            any(l.startswith("- [Some Source") for l in lines),
            msg=f"marker no longer bound to its content:\n{out}",
        )


if __name__ == "__main__":
    unittest.main()
