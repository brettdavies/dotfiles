#!/usr/bin/env python3
"""Markdown-aware line wrapper.

Reflows prose paragraphs and list items to a target line width while
preserving:
- YAML frontmatter
- Fenced code blocks
- Tables, headings, blockquotes
- HTML blocks, horizontal rules
- Blank lines (paragraph boundaries)
- Inline code spans, kept whole on one line with their bytes unchanged; a
  line break already inside a span joins as the one space CommonMark renders
"""

import re
import sys
import textwrap
from pathlib import Path

# Patterns
HEADING_RE = re.compile(r"^#{1,6}\s")
ULIST_RE = re.compile(r"^(\s*[-*+]\s|\s*\[[ xX]\]\s)")
OLIST_RE = re.compile(r"^(\s*\d+[.)]\s)")
LIST_MARKER_RE = re.compile(r"^([-*+]|\d+[.)]|\[[ xX]\]) ")
HRULE_RE = re.compile(r"^([-*_])\s*\1\s*\1[\s\-*_]*$")
HTML_RE = re.compile(r"^</?[a-zA-Z]")
COMMENT_RE = re.compile(r"^\s*<!--")
FENCE_OPEN_RE = re.compile(r"^(\s*)(```+|~~~+)")
LINK_DEF_RE = re.compile(r"^\[.+\]:\s")

# Matches markdown inline links: [text](url) and images: ![alt](url)
# Also matches [text](url "title") variants
MD_LINK_RE = re.compile(r"!?\[[^\]]*\]\([^)]*\)")

BACKTICK_RUN_RE = re.compile(r"`+")
WHITESPACE_RUN_RE = re.compile(r"\s+")

# A token matching this re-parses as block structure when it opens a line:
# an ATX heading, a list marker, a blockquote, a table row, a fence, a link
# definition, or a setext underline. textwrap picks break points by width
# alone, so prose like "queries #916," or "exits 2." can land one of these at
# the start of a continuation line, where the next read sees new structure and
# markdownlint --fix rewrites the line to match (MD018 turns "#916" into the
# heading "# 916"; a promoted "2." renumbers every ordered item below it).
LINE_START_HAZARD_RE = re.compile(
    r"""^(?:
          \#                    # heading, or an issue ref MD018 promotes into one
        | [-*+](?:\s|$)         # bullet marker
        | \d+[.)](?:\s|$)       # ordered marker; a year plus period qualifies
        | >                     # blockquote
        | \|                    # table row
        | (?:```|~~~)           # code fence
        | \[[^\]]*\]:\s         # link reference definition
        | (?:=+|-{3,})(?:\s|$)  # setext underline / thematic break
      )""",
    re.VERBOSE,
)

# Each rebind pass glues one token pair, so the token count strictly decreases
# and a paragraph converges well inside this bound.
_MAX_REBIND_PASSES = 64

# Placeholders that won't appear in real text. textwrap treats neither as
# whitespace, so a protected token is never broken or rewritten.
_SPACE_PH = "\x00"
_TAB_PH = "\x01"
_CODE_WS_TO_PH = str.maketrans({" ": _SPACE_PH, "\t": _TAB_PH})


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


def _code_spans(text: str) -> list[tuple[int, int]]:
    """Return the [start, end) offsets of each inline code span in `text`.

    CommonMark rules: a backtick run opens a span that the next run of exactly
    the same length closes; a run with no closer is literal text; a backslash
    escapes an opening backtick, but backslashes inside a span are literal.
    """
    spans: list[tuple[int, int]] = []
    pos = 0
    while m := BACKTICK_RUN_RE.search(text, pos):
        start, end = m.span()
        before = text[pos:start]
        if (len(before) - len(before.rstrip("\\"))) % 2:
            start += 1
        if start == end:
            pos = end
            continue
        closer = next(
            (c for c in BACKTICK_RUN_RE.finditer(text, end) if len(c.group()) == end - start),
            None,
        )
        if closer is None:
            pos = end
            continue
        spans.append((start, closer.end()))
        pos = closer.end()
    return spans


def _normalize_and_protect_code(text: str) -> str:
    """Collapse whitespace runs in prose and freeze every inline code span.

    Whitespace inside a code span is content (help-text columns, aligned
    output), so it becomes placeholders instead: textwrap can neither break the
    span across lines nor rewrite its interior.
    """
    parts: list[str] = []
    pos = 0
    for start, end in _code_spans(text):
        parts.append(WHITESPACE_RUN_RE.sub(" ", text[pos:start]))
        parts.append(text[start:end].translate(_CODE_WS_TO_PH))
        pos = end
    parts.append(WHITESPACE_RUN_RE.sub(" ", text[pos:]))
    return "".join(parts).strip()


def _protect_links(text: str) -> str:
    """Replace spaces inside markdown links with placeholders."""
    return MD_LINK_RE.sub(lambda m: m.group(0).replace(" ", _SPACE_PH), text)


def _restore_placeholders(text: str) -> str:
    """Restore the whitespace that link and code-span protection replaced."""
    return text.replace(_SPACE_PH, " ").replace(_TAB_PH, "\t")


def _fill_unpromoted(
    text: str, width: int, initial_indent: str, subsequent_indent: str
) -> str:
    """Wrap `text`, refusing breaks that would promote a token to block structure.

    Any token that would open a continuation line as markdown structure is glued
    to the word before it with the same placeholder the link and marker
    protection uses, which removes that break opportunity. The text itself is
    never edited, so a wrapped file keeps parsing as what its author wrote.
    """
    wrapped = ""
    for _ in range(_MAX_REBIND_PASSES):
        wrapped = textwrap.fill(
            text,
            width=width,
            initial_indent=initial_indent,
            subsequent_indent=subsequent_indent,
            break_long_words=False,
            break_on_hyphens=False,
        )

        # textwrap drops the whitespace it breaks on and joins the rest with
        # single spaces, so its output words map one-to-one onto `text` words.
        promoted_at: int | None = None
        consumed = 0
        for i, line in enumerate(wrapped.split("\n")):
            stripped = line.strip()
            if i and LINE_START_HAZARD_RE.match(stripped):
                promoted_at = consumed
                break
            consumed += len(stripped.split())

        words = text.split(" ")
        if not promoted_at or promoted_at >= len(words):
            return wrapped

        words[promoted_at - 1] += _SPACE_PH + words[promoted_at]
        del words[promoted_at]
        text = " ".join(words)

    return wrapped


def flush(buf: list[str], width: int, indent: str = "") -> str:
    """Join buffered lines and reflow to target width.

    Lines ending with two trailing spaces (markdown hard line breaks)
    are flushed individually to preserve the break.
    """
    lead = buf[0][: len(buf[0]) - len(buf[0].lstrip())] if buf else ""

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
        text = _normalize_and_protect_code(" ".join(l.strip() for l in seg))
        if not text:
            continue
        # Protect spaces inside markdown links so textwrap treats each
        # link as a single unbreakable token
        text = _protect_links(text)
        # Bind a list marker to its first word so an unbreakable word wider
        # than the line never leaves the marker orphaned on its own line
        if indent and not results:
            text = LIST_MARKER_RE.sub(lambda m: m.group(1) + _SPACE_PH, text, count=1)
        wrapped = _fill_unpromoted(
            text,
            width,
            initial_indent=lead if not results else indent,
            subsequent_indent=indent,
        )
        results.append(_restore_placeholders(wrapped))

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
