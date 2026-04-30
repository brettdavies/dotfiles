#!/usr/bin/env python3
"""Markdown-aware line wrapper.

Reflows prose paragraphs and list items to a target line width while
preserving:
- YAML frontmatter
- Fenced code blocks
- Tables, headings, blockquotes
- HTML blocks, horizontal rules
- Blank lines (paragraph boundaries)
"""

import re
import sys
import textwrap
from pathlib import Path

# Patterns
HEADING_RE = re.compile(r"^#{1,6}\s")
ULIST_RE = re.compile(r"^(\s*[-*+]\s|\s*\[[ xX]\]\s)")
OLIST_RE = re.compile(r"^(\s*\d+[.)]\s)")
HRULE_RE = re.compile(r"^([-*_])\s*\1\s*\1[\s\-*_]*$")
HTML_RE = re.compile(r"^</?[a-zA-Z]")
COMMENT_RE = re.compile(r"^\s*<!--")
FENCE_OPEN_RE = re.compile(r"^(\s*)(```+|~~~+)")
LINK_DEF_RE = re.compile(r"^\[.+\]:\s")

# Matches markdown inline links: [text](url) and images: ![alt](url)
# Also matches [text](url "title") variants
MD_LINK_RE = re.compile(r"!?\[[^\]]*\]\([^)]*\)")

# Placeholder that won't appear in real text
_SPACE_PH = "\x00"


def list_indent(line: str) -> str | None:
    """If line is a list item, return the continuation indent string."""
    for pat in (ULIST_RE, OLIST_RE):
        m = pat.match(line)
        if m:
            return " " * len(m.group(1))
    return None



def is_structure(line: str) -> bool:
    """Return True if the line is markdown structure (not wrappable)."""
    s = line.rstrip()
    if not s:
        return True
    if s.startswith("|") or s.startswith(">"):
        return True
    return bool(
        HEADING_RE.match(s)
        or HRULE_RE.match(s)
        or HTML_RE.match(s)
        or COMMENT_RE.match(s)
        or LINK_DEF_RE.match(s)
    )


def _protect_links(text: str) -> str:
    """Replace spaces inside markdown links with placeholders."""
    return MD_LINK_RE.sub(lambda m: m.group(0).replace(" ", _SPACE_PH), text)


def _restore_links(text: str) -> str:
    """Restore spaces inside markdown links."""
    return text.replace(_SPACE_PH, " ")


def flush(buf: list[str], width: int, indent: str = "") -> str:
    """Join buffered lines and reflow to target width.

    Lines ending with two trailing spaces (markdown hard line breaks)
    are flushed individually to preserve the break.
    """
    # Split buffer at hard line breaks (lines ending with 2+ spaces)
    segments: list[str] = []
    current: list[str] = []
    for l in buf:
        if l.rstrip() != l and l.endswith("  "):
            # This line has a hard break — flush current + this line separately
            current.append(l.rstrip())
            segments.append(current)
            current = []
        else:
            current.append(l)
    if current:
        segments.append(current)
    buf.clear()

    results: list[str] = []
    for seg in segments:
        text = " ".join(l.strip() for l in seg)
        text = re.sub(r"\s+", " ", text).strip()
        if not text:
            continue
        # Protect spaces inside markdown links so textwrap treats each
        # link as a single unbreakable token
        text = _protect_links(text)
        wrapped = textwrap.fill(
            text,
            width=width,
            initial_indent="" if not results else indent,
            subsequent_indent=indent,
            break_long_words=False,
            break_on_hyphens=False,
        )
        results.append(_restore_links(wrapped))

    # Re-join with trailing double-space line breaks between segments
    if len(results) <= 1:
        return results[0] if results else ""
    return "  \n".join(results)


def wrap_markdown(content: str, width: int = 120) -> str:
    """Wrap prose paragraphs and list items to the target width."""
    lines = content.split("\n")
    out: list[str] = []
    buf: list[str] = []
    buf_indent = ""  # continuation indent for current buffer
    state = "normal"  # normal | frontmatter | code
    fence_re: re.Pattern | None = None
    at_start = True

    def drain():
        nonlocal buf_indent
        if buf:
            out.append(flush(buf, width, buf_indent))
        buf_indent = ""

    for raw in lines:
        line = raw.rstrip("\r")

        # --- frontmatter ---
        if state == "frontmatter":
            out.append(line)
            if line.strip() == "---":
                state = "normal"
                at_start = False
            continue

        # --- fenced code block ---
        if state == "code":
            out.append(line)
            if fence_re and fence_re.match(line.strip()):
                state = "normal"
                fence_re = None
            continue

        # frontmatter opener (first non-empty content in file)
        if at_start and line.strip() == "---":
            drain()
            state = "frontmatter"
            out.append(line)
            continue

        at_start = False

        # code fence opener
        m = FENCE_OPEN_RE.match(line)
        if m:
            drain()
            state = "code"
            ch = m.group(2)[0]
            n = len(m.group(2))
            fence_re = re.compile(rf"^{re.escape(ch)}{{{n},}}\s*$")
            out.append(line)
            continue

        # blank line
        if not line.strip():
            drain()
            out.append(line)
            continue

        # structural markdown (tables, headings, HRs, HTML, link defs)
        if is_structure(line):
            drain()
            out.append(line)
            continue

        # list item — starts a new buffer with continuation indent
        li = list_indent(line)
        if li is not None:
            drain()
            buf_indent = li
            buf.append(line)
            continue

        # indented line while accumulating a list item — continuation
        if buf and buf_indent and line[0] == " ":
            buf.append(line)
            continue

        # indented line with no active list buffer — pass through
        # (indented code block or other structure)
        if line[0] in (" ", "\t") and not buf:
            out.append(line)
            continue

        # prose — accumulate (flush any prior list buffer first)
        if buf and buf_indent:
            drain()
            buf_indent = ""
        buf.append(line)

    drain()
    return "\n".join(out)


def main() -> None:
    import argparse

    p = argparse.ArgumentParser(description="Markdown-aware prose line wrapper")
    p.add_argument("files", nargs="*", help="files to process (stdin if omitted)")
    p.add_argument("-w", "--width", type=int, default=120, help="target width (default: 120)")
    p.add_argument("-i", "--in-place", action="store_true", help="edit files in place")
    p.add_argument("--check", action="store_true", help="exit 1 if changes needed")
    args = p.parse_args()

    if not args.files:
        content = sys.stdin.read()
        result = wrap_markdown(content, args.width)
        if content.endswith("\n") and not result.endswith("\n"):
            result += "\n"
        sys.stdout.write(result)
        return

    rc = 0
    for fp in args.files:
        path = Path(fp)
        content = path.read_text()
        result = wrap_markdown(content, args.width)
        if content.endswith("\n") and not result.endswith("\n"):
            result += "\n"

        if args.check:
            if content != result:
                print(f"{fp}: needs wrapping", file=sys.stderr)
                rc = 1
        elif args.in_place:
            if content != result:
                path.write_text(result)
        else:
            sys.stdout.write(result)

    sys.exit(rc)


if __name__ == "__main__":
    main()
