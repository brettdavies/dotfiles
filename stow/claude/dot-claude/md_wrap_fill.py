"""Paragraph reflow for md-wrap: join a buffered paragraph and wrap it to width."""

import re
import textwrap

from md_wrap_inline import (
    SPACE_PH,
    normalize_and_protect_code,
    protect_links,
    restore_placeholders,
)

LIST_MARKER_RE = re.compile(r"^([-*+]|\d+[.)]|\[[ xX]\]) ")

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

        words[promoted_at - 1] += SPACE_PH + words[promoted_at]
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
        budget = max(1, width - max(len(lead), len(indent)))
        text = normalize_and_protect_code(" ".join(l.strip() for l in seg), budget)
        if not text:
            continue
        # Protect spaces inside markdown links so textwrap treats each
        # link as a single unbreakable token
        text = protect_links(text)
        # Bind a list marker to its first word so an unbreakable word wider
        # than the line never leaves the marker orphaned on its own line
        if indent and not results:
            text = LIST_MARKER_RE.sub(lambda m: m.group(1) + SPACE_PH, text, count=1)
        wrapped = _fill_unpromoted(
            text,
            width,
            initial_indent=lead if not results else indent,
            subsequent_indent=indent,
        )
        results.append(restore_placeholders(wrapped))

    # Re-join with trailing double-space line breaks between segments
    if len(results) <= 1:
        return results[0] if results else ""
    return "  \n".join(results)

