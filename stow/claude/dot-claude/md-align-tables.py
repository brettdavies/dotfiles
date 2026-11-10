#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.10"
# dependencies = ["wcwidth"]
# ///
"""Reflow GitHub-Flavored Markdown tables to consistent "aligned" column style.

Why this exists: markdownlint's MD060/table-column-style rule flags mixed
compact/aligned table pipes but does not ship an autofixer (upstream
DavidAnson/markdownlint#1980 — open, unresolved). This script normalizes every
table in a file to aligned style so MD060 reports 0 errors.

Behavior:
- Operates in-place. Files with no tables are byte-identical after run.
- Preserves YAML frontmatter, fenced code blocks, headings, lists, and HTML —
  only rewrites blocks whose first two lines match <row> + <separator>.
- Respects alignment hints in the separator row (:--- / ---: / :---:).
- Pads each column to the max-content width across header + body, with a
  one-space gutter on both sides of every cell.
- Escaped pipes inside cells (\\|) are preserved verbatim.
- Measures cell content in display columns, matching MD060 (see display_width).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from wcwidth import wcswidth

FENCE_RE = re.compile(r"^\s*(```+|~~~+)")
SEP_ROW_RE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$")


def display_width(text: str) -> int:
    """Width of `text` in terminal columns, which is what MD060 compares pipes on.

    `len` counts codepoints, so an emoji or CJK character measures one column
    narrower than it renders and the padded pipe lands left of the header's.
    The rule reports that as a misalignment this script cannot see, and since
    MD060 has no autofixer the error survives the whole format chain.

    wcswidth returns -1 for a string carrying a control character; fall back to
    the codepoint count there, so a cell never measures narrower than it did
    before and this only ever widens a column.
    """
    width = wcswidth(text)
    return len(text) if width < 0 else width


def split_row(line: str) -> list[str]:
    s = line.rstrip("\n").strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    parts: list[str] = []
    buf = ""
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            buf += s[i : i + 2]
            i += 2
            continue
        if c == "|":
            parts.append(buf)
            buf = ""
            i += 1
            continue
        buf += c
        i += 1
    parts.append(buf)
    return [p.strip() for p in parts]


def parse_alignments(sep_cells: list[str]) -> list[str]:
    out = []
    for cell in sep_cells:
        c = cell.strip()
        left = c.startswith(":")
        right = c.endswith(":")
        if left and right:
            out.append("center")
        elif right:
            out.append("right")
        elif left:
            out.append("left")
        else:
            out.append("none")
    return out


def pad(text: str, width: int, align: str) -> str:
    # `width` is display columns; the padding below is ASCII spaces, one column
    # each, so only the content measure changes.
    n = display_width(text)
    if n >= width:
        return text
    extra = width - n
    if align == "right":
        return " " * extra + text
    if align == "center":
        l = extra // 2
        r = extra - l
        return " " * l + text + " " * r
    return text + " " * extra


def format_table(header: list[str], sep: list[str], body: list[list[str]]) -> list[str]:
    aligns = parse_alignments(sep)
    cols = len(header)
    body = [row + [""] * (cols - len(row)) if len(row) < cols else row[:cols] for row in body]
    widths = [display_width(header[i]) for i in range(cols)]
    for row in body:
        for i, cell in enumerate(row):
            cell_width = display_width(cell)
            if cell_width > widths[i]:
                widths[i] = cell_width
    # separator needs room for alignment colons
    sep_min = [3 + (1 if a == "left" else 0) + (1 if a == "right" else 0) + (2 if a == "center" else 0) for a in aligns]
    for i in range(cols):
        if widths[i] < sep_min[i]:
            widths[i] = sep_min[i]

    def emit(cells: list[str]) -> str:
        padded = [" " + pad(cells[i], widths[i], aligns[i]) + " " for i in range(cols)]
        return "|" + "|".join(padded) + "|"

    def emit_sep() -> str:
        parts = []
        for i, a in enumerate(aligns):
            w = widths[i]
            if a == "left":
                parts.append(" :" + "-" * (w - 1) + " ")
            elif a == "right":
                parts.append(" " + "-" * (w - 1) + ": ")
            elif a == "center":
                parts.append(" :" + "-" * (w - 2) + ": ")
            else:
                parts.append(" " + "-" * w + " ")
        return "|" + "|".join(parts) + "|"

    out = [emit(header), emit_sep()]
    for row in body:
        out.append(emit(row))
    return out


def process(lines: list[str]) -> list[str]:
    result: list[str] = []
    in_fence = False
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if FENCE_RE.match(line):
            in_fence = not in_fence
            result.append(line)
            i += 1
            continue
        if in_fence:
            result.append(line)
            i += 1
            continue
        # Table: current line has a pipe AND next line is a separator row.
        if "|" in line and i + 1 < n and SEP_ROW_RE.match(lines[i + 1]):
            header_cells = split_row(line)
            sep_cells = split_row(lines[i + 1])
            if len(sep_cells) != len(header_cells):
                result.append(line)
                i += 1
                continue
            body: list[list[str]] = []
            j = i + 2
            while j < n:
                nxt = lines[j]
                s = nxt.strip()
                if not s or "|" not in s:
                    break
                if FENCE_RE.match(nxt):
                    break
                body.append(split_row(nxt))
                j += 1
            formatted = format_table(header_cells, sep_cells, body)
            result.extend(l + "\n" for l in formatted)
            i = j
            continue
        result.append(line)
        i += 1
    return result


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in {"-h", "--help"}:
        print("usage: md-align-tables.py <file> [<file> ...]", file=sys.stderr)
        return 0 if len(argv) >= 2 else 2
    rc = 0
    for path in argv[1:]:
        p = Path(path)
        try:
            text = p.read_text()
        except OSError as err:
            print(f"md-align-tables: {path}: {err}", file=sys.stderr)
            rc = 1
            continue
        lines = text.splitlines(keepends=True)
        new_text = "".join(process(lines))
        if new_text != text:
            p.write_text(new_text)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
