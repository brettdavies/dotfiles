#!/usr/bin/env python3
"""Tests for md-wrap.py.

Run: python3 -B stow/claude/dot-claude/test_md_wrap.py
"""

from __future__ import annotations

import importlib.util
import re
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

# Help-text column layouts quoted as inline code: the whitespace runs between
# columns are the content being quoted, so reflow must keep them byte for byte.
CODE_SPAN_PROSE = (
    "lazygit lists `-cd   --print-config-dir   Print the config directory` and pandoc lists "
    "`-f FORMAT, -r FORMAT  --from=FORMAT, --read=FORMAT` before the next section begins.\n"
)

CODE_SPAN_LIST = """\
- Covers AE2. lazygit's `-cd   --print-config-dir   Print the config directory` yields `-cd` and `--print-config-dir`,
  and a lookup for `-c` does not match; its `-v    --version` yields `-v` and `--version`.
  - ffmpeg's `-y                  overwrite output files` and `-loglevel loglevel  set logging level` are definitions.
  - Thor's ``-f,        [--force]   # desc`` and a tab-separated `--null\t-T reads` row keep their names.
"""

CODE_SPAN_CORPUS = {
    "code_span_prose": (
        CODE_SPAN_PROSE,
        (
            "`-cd   --print-config-dir   Print the config directory`",
            "`-f FORMAT, -r FORMAT  --from=FORMAT, --read=FORMAT`",
        ),
    ),
    "code_span_list": (
        CODE_SPAN_LIST,
        (
            "`-cd   --print-config-dir   Print the config directory`",
            "`-v    --version`",
            "`-y                  overwrite output files`",
            "`-loglevel loglevel  set logging level`",
            "``-f,        [--force]   # desc``",
            "`--null\t-T reads`",
        ),
    ),
}

HASH_REF = (
    "Adapters keep getting the mapping wrong for one upstream status, GitHub 422 on "
    "qualifier-only queries #916, and the arXiv exact-phrase zero result.\n"
)

ORDERED_PROMOTION = (
    "The surrounding runner treats a nonzero status as fatal so the wrapper exits 2. "
    "Pins the behavior against a later refactor.\n"
)

BARE_PLUS = (
    "The changelog bullet renders the operator as a literal token spelled space + space "
    "which the reflow keeps moving between passes.\n"
)

YEAR_PERIOD = (
    "The security wave ran through the summer of 2026. The next release closed the "
    "remaining adapter bugs across every source module.\n"
)

# A list item whose prose carries " + " between terms: textwrap can open a
# continuation line with "+ ", which the next pass reads as a nested bullet and
# re-indents (the shape found in a real solutions doc).
LIST_PLUS = """\
- `meum-id/.github`: private org reusable repo (org-scoped Actions access) hosting `verify-release-tag.yml` (tag-format + tag-is-ancestor-of-main + package.json version match), `create-github-release.yml` (version-anchored changelog extraction + idempotent release creation), and the fleet CI/deploy reusables.
"""

PROMOTION_CORPUS = {
    "hash_ref": HASH_REF,
    "ordered_promotion": ORDERED_PROMOTION,
    "bare_plus": BARE_PLUS,
    "year_period": YEAR_PERIOD,
    "list_plus": LIST_PLUS,
}

CORPUS = {
    "nested": NESTED,
    "ordered_nested": ORDERED_NESTED,
    "hanging": HANGING,
    "orphan": ORPHAN,
    "list_then_prose": LIST_THEN_PROSE,
    **{name: src for name, (src, _) in CODE_SPAN_CORPUS.items()},
    **PROMOTION_CORPUS,
}


class IdempotencyTest(unittest.TestCase):
    def test_second_pass_equals_first(self):
        for name, src in CORPUS.items():
            for width in range(40, 121):
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


class CodeSpanTest(unittest.TestCase):
    """Inline code spans come out of reflow byte for byte and on one line."""

    WIDTHS = range(40, 121)

    def test_span_bytes_survive_at_every_width(self):
        for name, (src, spans) in CODE_SPAN_CORPUS.items():
            for width in self.WIDTHS:
                out = mod.wrap_markdown(src, width)
                lines = out.split("\n")
                for span in spans:
                    self.assertTrue(
                        any(span in line for line in lines),
                        msg=f"{name} at width {width} altered or split {span!r}:\n{out}",
                    )

    def test_prose_whitespace_outside_spans_still_collapses(self):
        out = mod.wrap_markdown("Prose  with   runs `a   b` and    more.\n", 120)
        self.assertEqual("Prose with runs `a   b` and more.\n", out)

    def test_escaped_backtick_does_not_open_a_span(self):
        src = "Write \\` for a literal backtick and `x   y` for code.\n"
        self.assertEqual(src, mod.wrap_markdown(src, 120))

    def test_span_across_a_line_break_joins_with_one_space(self):
        """CommonMark renders a line ending inside a code span as one space."""
        out = mod.wrap_markdown("A span `opens here\n  and closes` on the next line.\n", 120)
        self.assertEqual("A span `opens here and closes` on the next line.\n", out)


class MarkerPromotionTest(unittest.TestCase):
    """A continuation line must never open with block structure the author did not write.

    textwrap breaks on width alone, so each of these shapes lands a structural
    token at the start of a continuation line at some widths. The next parse,
    and markdownlint --fix, then read that token as a heading or list marker.
    """

    WIDTHS = range(40, 121)

    # Deliberately written here rather than imported from md-wrap: the test
    # states what a reader would call promoted structure, so it fails on the
    # behavior when the wrapper regresses instead of tracking its own regex.
    PROMOTED = re.compile(r"^(?:#|[-*+](?:\s|$)|\d+[.)](?:\s|$)|>|\|)")

    def test_no_shape_promotes_at_any_width(self):
        for name, src in PROMOTION_CORPUS.items():
            for width in self.WIDTHS:
                out = mod.wrap_markdown(src, width)
                body = [l for l in out.split("\n") if l.strip()]
                for line in body[1:]:
                    self.assertIsNone(
                        self.PROMOTED.match(line.lstrip()),
                        msg=(
                            f"{name} at width {width} promoted a token to block "
                            f"structure:\n{out}"
                        ),
                    )

    def test_words_survive_rebinding(self):
        """Gluing removes a break opportunity; it must not edit the prose."""
        for name, src in PROMOTION_CORPUS.items():
            for width in self.WIDTHS:
                out = mod.wrap_markdown(src, width)
                self.assertEqual(
                    src.split(),
                    out.split(),
                    msg=f"{name} at width {width} altered the text",
                )

    def test_hazard_free_prose_is_untouched(self):
        """Prose with no structural token wraps exactly as textwrap would."""
        import textwrap as tw

        src = (
            "Plain prose with no structural tokens anywhere in it at all, long "
            "enough that it has to wrap across several physical lines.\n"
        )
        for width in self.WIDTHS:
            self.assertEqual(
                tw.fill(
                    src.strip(),
                    width=width,
                    break_long_words=False,
                    break_on_hyphens=False,
                ),
                mod.wrap_markdown(src, width).rstrip("\n"),
                msg=f"hazard-free prose diverged from plain textwrap at width {width}",
            )


if __name__ == "__main__":
    unittest.main()
