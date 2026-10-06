"""Inline token protection for md-wrap: code spans, links, and their placeholders."""

import re

# Matches markdown inline links: [text](url) and images: ![alt](url)
# Also matches [text](url "title") variants
MD_LINK_RE = re.compile(r"!?\[[^\]]*\]\([^)]*\)")

BACKTICK_RUN_RE = re.compile(r"`+")
WHITESPACE_RUN_RE = re.compile(r"\s+")

# Placeholders that won't appear in real text. textwrap treats neither as
# whitespace, so a protected token is never broken or rewritten.
SPACE_PH = "\x00"
TAB_PH = "\x01"
_CODE_WS_TO_PH = str.maketrans({" ": SPACE_PH, "\t": TAB_PH})


def code_spans(text: str) -> list[tuple[int, int]]:
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


def _freeze_span(span: str, breakable: bool) -> str:
    """Turn a code span's whitespace into placeholders textwrap cannot break on.

    A span wider than the line it must fit on keeps its lone interior spaces
    real, so textwrap may break there: CommonMark renders a line ending inside
    a span as one space, so that break reads exactly as the space it replaces.
    Runs of two or more whitespace characters, tabs, and the padding next to
    the backticks carry meaning and stay frozen either way.
    """
    if not breakable:
        return span.translate(_CODE_WS_TO_PH)
    opener = len(span) - len(span.lstrip("`"))
    closer = len(span) - len(span.rstrip("`"))
    inner = span[opener : len(span) - closer]
    out = []
    for i, ch in enumerate(inner):
        lone = (
            ch == " "
            and 0 < i < len(inner) - 1
            and not inner[i - 1].isspace()
            and not inner[i + 1].isspace()
        )
        out.append(ch if lone else ch.translate(_CODE_WS_TO_PH))
    return span[:opener] + "".join(out) + span[len(span) - closer :]


def normalize_and_protect_code(text: str, budget: int) -> str:
    """Collapse whitespace runs in prose and freeze every inline code span.

    Whitespace inside a code span is content (help-text columns, aligned
    output), so it becomes placeholders instead: textwrap can neither break the
    span across lines nor rewrite its interior. A span longer than `budget`
    characters cannot fit on any line, so `_freeze_span` leaves it breakable
    at its lone interior spaces instead of overflowing the line limit.
    """
    parts: list[str] = []
    pos = 0
    for start, end in code_spans(text):
        parts.append(WHITESPACE_RUN_RE.sub(" ", text[pos:start]))
        parts.append(_freeze_span(text[start:end], end - start > budget))
        pos = end
    parts.append(WHITESPACE_RUN_RE.sub(" ", text[pos:]))
    return "".join(parts).strip()


def protect_links(text: str) -> str:
    """Replace spaces inside markdown links with placeholders."""
    return MD_LINK_RE.sub(lambda m: m.group(0).replace(" ", SPACE_PH), text)


def restore_placeholders(text: str) -> str:
    """Restore the whitespace that link and code-span protection replaced."""
    return text.replace(SPACE_PH, " ").replace(TAB_PH, "\t")

