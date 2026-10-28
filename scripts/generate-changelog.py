#!/usr/bin/env -S PYTHONDONTWRITEBYTECODE=1 uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate or update CHANGELOG.md using git-cliff with PR body expansion.

Usage:
    generate-changelog.py [--tag vX.Y.Z] [repo-path]
    generate-changelog.py --check [repo-path]
    generate-changelog.py --dry-run [--tag vX.Y.Z] [repo-path]
    generate-changelog.py --print-tag [--tag TAG] [repo-path]
    generate-changelog.py --from-dev-prs [--dev-branch dev] [--tag vX.Y.Z] [repo-path]
    generate-changelog.py --crate NAME --tag NAME-vX.Y.Z [repo-path]
    generate-changelog.py --audit-sections [--crate NAME] [--tag TAG] [repo-path]

Options:
    --tag vX.Y.Z   Override version tag (default: extracted from branch name).
    --print-tag    Print the resolved version tag and exit (no git-cliff run).
    --from-dev-prs Build the version section from the PRs merged into the
                   integration branch that no earlier release carried, instead
                   of from the release branch's commits. This is the mode for an
                   overlay-built release branch, whose single commit carries no
                   per-PR history. No git-cliff run.
    --dev-branch   Integration branch --from-dev-prs reads (default: dev).
    --audit-sections
                   List the PRs --from-dev-prs would read whose entry would
                   fall back to their title because the body never offered the
                   changelog section; exit 1 when any does. A section left
                   empty is an answer and passes. Writes nothing.
    --crate NAME   Generate a workspace member's own changelog. The member's
                   [package.metadata.changelog] table in its Cargo.toml names
                   the PR-body heading that addresses it, its tag prefix, its
                   changelog path and the paths it counts as its own; the
                   workspace keeps one cliff.toml. Needs --tag.
    --check        Verify CHANGELOG.md has a versioned section
                   (exit 1 if only [Unreleased]).
    --dry-run      Run the regen flow against the current CHANGELOG.md and
                   restore the original on exit. Exit 0 if regeneration
                   produces identical content (idempotent), exit 1 with a
                   unified diff if it would drift. The first stderr line
                   names the drift: "differs only in line wrapping" when the
                   two match once whitespace and line breaks collapse (a
                   lint config or formatter rewraps the file), "would
                   change" when the content differs. Requires an existing
                   CHANGELOG.md.

Version detection: the branch name must match release/vN.N.N (with optional
suffix like release/v1.0.5-ci-migration). Pass --tag when not on a release
branch.

Pipeline:
    1. git-cliff emits a versioned section from commits since the last tag
       (prepended onto CHANGELOG.md, or created if missing).
    2. PR numbers in that section are fetched from GitHub; each PR body's
       ## Changelog section is parsed for ### Breaking changes / ### Added /
       ### Changed / ### Deprecated / ### Removed / ### Fixed /
       ### Documentation bullets.
    3. The version section in CHANGELOG.md is rewritten with the aggregated,
       attributed bullets and a Full Changelog compare link.

Falls back to a flat ## Changes list when a PR uses the older template shape.

Run on a release/vX.Y.Z branch before opening the PR to main.
"""

from __future__ import annotations

import argparse
import difflib
from datetime import datetime, timezone
from fnmatch import fnmatch
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

# Emitted in this order; any other `###` heading a PR body uses follows them.
# "Breaking changes" is also the git-cliff group for `type!:` commits in
# cliff.toml, so the skeleton and the PR-body pass agree on the label.
CATEGORIES = [
    "Breaking changes",
    "Added",
    "Changed",
    "Deprecated",
    "Removed",
    "Fixed",
    "Documentation",
]


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def have(cmd: str) -> bool:
    return run(["bash", "-c", f"command -v {cmd}"]).returncode == 0


SEMVER_BRANCH_RE = re.compile(r"^release/v(\d+\.\d+\.\d+)")
CALVER_BRANCH_RE = re.compile(r"^release/(\d{4}\.\d{2}\.\d{2}(?:\.\d+)?)")


def release_branch_tag() -> tuple[str, str | None]:
    """The current branch, and the tag its release-branch name carries or None.

    `release/vX.Y.Z` yields `vX.Y.Z`; a CalVer branch `release/YYYY.MM.DD`
    (optionally `.N`) yields the bare date, since CalVer repos tag without
    a `v` prefix.
    """
    proc = run(["git", "branch", "--show-current"])
    branch = proc.stdout.strip() if proc.returncode == 0 else ""
    semver = SEMVER_BRANCH_RE.match(branch)
    if semver:
        return branch, f"v{semver.group(1)}"
    calver = CALVER_BRANCH_RE.match(branch)
    return branch, calver.group(1) if calver else None


def detect_tag_from_branch() -> str:
    """Read the version tag off a release branch name, or fail naming --tag."""
    branch, tag = release_branch_tag()
    if tag is None:
        fail(
            f"could not detect version from branch '{branch}'\n"
            "Use a release/vX.Y.Z or release/YYYY.MM.DD branch, or pass --tag"
        )
    print(f"Detected version {tag} from branch {branch}", file=sys.stderr)
    return tag


# A changelog that only points at other changelogs carries this marker. The
# generator refuses to write one, because a workspace's root file routes to the
# per-crate histories and holds no version sections to regenerate.
ROUTER_MARKER = "changelog-router"


def is_router(changelog: Path) -> bool:
    if not changelog.exists():
        return False
    head = changelog.read_text()[:2000]
    return ROUTER_MARKER in head


def refuse_router(changelog: Path, crate: str | None) -> None:
    """Stop before writing a routing changelog, naming the way to the real one."""
    if not is_router(changelog):
        return
    hint = (
        "pass --crate NAME to generate that crate's changelog instead"
        if not crate
        else f"{crate}'s [package.metadata.changelog] points at this file; point it at the crate's own"
    )
    fail(
        f"{changelog} routes to the per-crate changelogs and holds no release "
        f"history; {hint}"
    )


def check_mode(changelog: Path) -> int:
    if not changelog.exists():
        print("FAIL: CHANGELOG.md does not exist", file=sys.stderr)
        return 1
    for line in changelog.read_text().splitlines():
        if line.startswith("## ["):
            if "[Unreleased]" in line:
                print(
                    "FAIL: CHANGELOG.md has [Unreleased] instead of a versioned section",
                    file=sys.stderr,
                )
                print(
                    "Run: generate-changelog.py (on a release/vX.Y.Z branch)",
                    file=sys.stderr,
                )
                return 1
            print("OK: CHANGELOG.md has versioned section")
            return 0
    print("FAIL: CHANGELOG.md has no versioned section", file=sys.stderr)
    return 1


def ensure_github_token() -> None:
    if os.environ.get("GITHUB_TOKEN"):
        return
    if not have("gh"):
        return
    if run(["gh", "auth", "status"]).returncode != 0:
        return
    token = run(["gh", "auth", "token"]).stdout.strip()
    if token:
        os.environ["GITHUB_TOKEN"] = token


def run_git_cliff(
    tag: str, changelog: Path, config: Path, scope: dict | None = None
) -> None:
    """Render the skeleton for TAG, scoped to SCOPE's paths and tag line.

    `--include-path`, `--exclude-path` and `--tag-pattern` carry a member's
    scope, so one config serves every member of the workspace.
    """
    args = ["git", "cliff", "--unreleased", "--tag", tag, "-c", str(config)]
    if scope:
        for pattern in scope["include_paths"]:
            args += ["--include-path", pattern]
        for pattern in scope["exclude_paths"]:
            args += ["--exclude-path", pattern]
        escaped = re.escape(scope["tag_prefix"])
        args += ["--tag-pattern", rf"^{escaped}[0-9]+\.[0-9]+\.[0-9]+$"]
    if changelog.exists():
        args += ["--prepend", str(changelog)]
    else:
        args += ["-o", str(changelog)]
    if subprocess.run(args).returncode != 0:
        sys.exit(1)
    if scope:
        # cliff.toml's body strips only a bare leading `v`, so a member's tag
        # heads the new section as `## [<crate>-vX.Y.Z]`. Every other section of
        # a member changelog, and every reader of one, names the bare version.
        version = version_from_tag(tag, scope["tag_prefix"])
        content = changelog.read_text()
        changelog.write_text(content.replace(f"## [{tag}]", f"## [{version}]", 1))


def read_crate_changelog_config(repo: Path, crate: str) -> dict:
    """A member's `[package.metadata.changelog]` table, with defaults filled in.

    Read from cargo rather than from a per-member cliff.toml, so the workspace
    keeps one git-cliff config and each member states its own tag line, paths
    and changelog location beside its own manifest. `tag_prefix` defaults to
    `<crate>-v` and `changelog` to the file beside the manifest, which is what
    a member added later needs no table to get.
    """
    proc = run(
        ["cargo", "metadata", "--format-version", "1", "--no-deps"], cwd=str(repo)
    )
    if proc.returncode != 0:
        fail(f"cargo metadata failed: {proc.stderr.strip()}")
    for package in json.loads(proc.stdout).get("packages", []):
        if package.get("name") != crate:
            continue
        manifest_dir = Path(package["manifest_path"]).parent
        table = (package.get("metadata") or {}).get("changelog") or {}
        rel = manifest_dir.relative_to(repo).as_posix()
        return {
            "heading": table.get("heading", f"Changelog ({crate})"),
            "tag_prefix": table.get("tag_prefix", f"{crate}-v"),
            "changelog": repo / table.get("changelog", f"{rel}/CHANGELOG.md"),
            "include_paths": table.get("include_paths", [f"{rel}/**"]),
            "exclude_paths": table.get("exclude_paths", []),
        }
    fail(f"{crate} is not a workspace member of {repo}")


def path_matches(path: str, patterns: list[str]) -> bool:
    """Whether PATH matches any of git-cliff's glob PATTERNS."""
    return any(fnmatch(path, pattern) for pattern in patterns)


def pr_touches_member(
    owner: str, repo: str, num: int, include: list[str], exclude: list[str]
) -> bool:
    """Whether a PR changed a file the member counts as its own.

    A PR GitHub cannot answer for counts as touching it, so a lookup failure
    never silently drops a change from the changelog.
    """
    cached = _PR_CACHE.get((owner, repo, num)) or {}
    paths: list[str] | None = None
    if cached.get("paths_complete"):
        paths = cached.get("paths")
    if paths is None:
        proc = run(
            [
                "gh", "api", "--paginate",
                f"repos/{owner}/{repo}/pulls/{num}/files",
                "--jq", ".[].filename",
            ],
            timeout=60,
        )
        if proc.returncode != 0:
            return True
        paths = proc.stdout.split()
    for filename in paths:
        if path_matches(filename, include) and not path_matches(filename, exclude):
            return True
    return False


# The groups cliff.toml's commit_parsers route conventional-commit types to,
# in its order, for a PR that supplied no changelog block and falls back to its
# title. Kept in step with that file, so a title lands where the same commit
# would: a `type!:` subject is a breaking change before its type is skipped.
TITLE_GROUPS: list[tuple[re.Pattern[str], str | None]] = [
    (re.compile(r"^release"), None),
    (re.compile(r"^[a-z]+(\([^)]*\))?!:"), "Breaking changes"),
    (re.compile(r"^feat"), "Added"),
    (re.compile(r"^fix"), "Fixed"),
    (re.compile(r"^refactor"), "Changed"),
    (re.compile(r"^perf"), "Changed"),
    (re.compile(r"^docs"), "Documentation"),
    (re.compile(r"^(chore|ci|build|style|test)(\([^)]*\))?:"), None),
]


def group_for_title(title: str) -> str | None:
    """The changelog group a conventional-commit subject belongs to, or None to skip."""
    for pattern, group in TITLE_GROUPS:
        if pattern.match(title):
            return group
    return "Changed"


def read_remote_github(cliff_toml: Path) -> tuple[str | None, str | None]:
    data = tomllib.loads(cliff_toml.read_text())
    remote = data.get("remote", {}).get("github", {})
    return remote.get("owner"), remote.get("repo")


def extract_version_section(content: str, version: str) -> str:
    out: list[str] = []
    in_section = False
    needle = f"[{version}]"
    for line in content.splitlines():
        if line.startswith("## ["):
            if in_section:
                break
            if needle in line:
                in_section = True
        if in_section:
            out.append(line)
    return "\n".join(out)


def pr_numbers_from_section(section: str) -> list[int]:
    """Collect PR numbers from both bullet forms.

    git-cliff's skeleton emits `(#N)`; the expanded section rewrites those
    into `[#N](...)` links. Matching both keeps re-runs against an
    already-expanded section from silently finding zero PRs and skipping
    the refresh.
    """
    seen: dict[int, None] = {}
    for m in re.finditer(r"\(#(\d+)\)|\[#(\d+)\]", section):
        seen[int(m.group(1) or m.group(2))] = None
    return sorted(seen)


_PR_CACHE: dict[tuple[str, str, int], dict | None] = {}


def prefetch_prs(owner: str, repo: str, numbers: list[int]) -> None:
    """Fill the PR cache for NUMBERS in as few requests as possible.

    One REST call per PR makes a release with many candidates take minutes:
    the body, the title and the changed paths are all needed for each one.
    GraphQL aliases fetch them together, 50 PRs per request. A failure here is
    not fatal, because the per-PR REST path stays as the fallback.
    """
    pending = [n for n in numbers if (owner, repo, n) not in _PR_CACHE]
    for start in range(0, len(pending), 50):
        chunk = pending[start : start + 50]
        aliases = "\n".join(
            f'  p{n}: pullRequest(number: {n}) {{ number title body '
            f'author {{ login }} '
            f'files(first: 100) {{ nodes {{ path }} pageInfo {{ hasNextPage }} }} }}'
            for n in chunk
        )
        query = (
            f'query {{ repository(owner: "{owner}", name: "{repo}") {{\n'
            f'{aliases}\n}} }}'
        )
        proc = run(["gh", "api", "graphql", "-f", f"query={query}"], timeout=120)
        if proc.returncode != 0:
            continue
        try:
            data = json.loads(proc.stdout)["data"]["repository"]
        except (json.JSONDecodeError, KeyError, TypeError):
            continue
        for node in (data or {}).values():
            if not node:
                continue
            files = node.get("files") or {}
            _PR_CACHE[(owner, repo, node["number"])] = {
                "body": node.get("body"),
                "author": (node.get("author") or {}).get("login"),
                "title": node.get("title"),
                "paths": [f["path"] for f in (files.get("nodes") or [])],
                "paths_complete": not (files.get("pageInfo") or {}).get("hasNextPage"),
            }


def fetch_pr(owner: str, repo: str, num: int) -> dict | None:
    key = (owner, repo, num)
    if key in _PR_CACHE:
        return _PR_CACHE[key]
    _PR_CACHE[key] = _fetch_pr_uncached(owner, repo, num)
    return _PR_CACHE[key]


def _fetch_pr_uncached(owner: str, repo: str, num: int) -> dict | None:
    proc = run(
        [
            "gh",
            "api",
            f"repos/{owner}/{repo}/pulls/{num}",
            "--jq",
            "{body: .body, author: .user.login, title: .title}",
        ],
        timeout=10,
    )
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def slice_below(body: str, header_pattern: str) -> str | None:
    match = re.search(header_pattern, body, re.MULTILINE)
    if not match:
        return None
    rest = body[match.end() :]
    next_h2 = re.search(r"^## ", rest, re.MULTILINE)
    return rest[: next_h2.start()] if next_h2 else rest


# A fenced block indented under a bullet. Column-zero fences are not part of
# the bullet, so they do not open one.
FENCE_OPEN_RE = re.compile(r"^\s+(`{3,}|~{3,})")


def extract_changelog_sections(
    body: str, heading: str = r"^## Changelog\s*$"
) -> dict[str, list[str]]:
    """Map each `### <heading>` under HEADING to its bullets.

    A bullet's continuation lines fold into it as one line, because a changelog
    bullet is one logical line. An indented fenced code block is the exception:
    it is kept verbatim, newlines and indentation intact, so a breaking entry
    can carry the before/after snippet a breaking-change policy asks for.
    Folding a fence would paste its lines into running prose and destroy it.
    """
    sections: dict[str, list[str]] = {}
    content = slice_below(body, heading)
    if content is None:
        return sections
    current: str | None = None
    fence: str | None = None
    for line in content.split("\n"):
        if fence is not None:
            sections[current][-1] += "\n" + line
            if line.strip().startswith(fence):
                fence = None
            continue
        h3 = re.match(r"^### (.+)", line)
        if h3:
            current = h3.group(1).strip()
            sections.setdefault(current, [])
            continue
        if current is None:
            continue
        opener = FENCE_OPEN_RE.match(line)
        if opener and sections.get(current):
            fence = opener.group(1)
            # The blank line the body had before the fence was dropped as
            # neither bullet nor continuation; a fence abutting the bullet
            # text renders as part of it.
            sections[current][-1] += "\n\n" + line
            continue
        if re.match(r"^- ", line):
            sections[current].append(line)
        elif sections.get(current) and re.match(r"^  \S", line):
            sections[current][-1] = sections[current][-1].rstrip() + " " + line.strip()
    return sections


def with_attribution(entry: str, attrib: str) -> str:
    """Attach the author and PR link to an entry's first line.

    An entry that carries a fenced snippet runs to several lines, and appending
    to the whole string would put the attribution after the closing fence.
    """
    if not attrib or " by @" in entry:
        return entry
    head, sep, rest = entry.partition("\n")
    return head + attrib + sep + rest


def declares_empty_changelog(body: str, heading: str = r"^## Changelog\s*$") -> bool:
    """Whether the body offers the changelog section and leaves it empty.

    The PR template tells an author whose change is not user-facing to delete
    the `###` subsections, which leaves the heading standing over nothing. That
    is a decision, so it reads differently from a body that never offered the
    section at all, where the title is the best answer available.

    Scoped to the heading being read, so a PR that described the binary and
    said nothing about a member has not declared the member unaffected.
    """
    for header in (heading, r"^## Changes\s*$"):
        if slice_below(body, header) is not None:
            return True
    return False


def extract_flat_changes(body: str) -> list[str]:
    bullets: list[str] = []
    content = slice_below(body, r"^## Changes\s*$")
    if content is None:
        return bullets
    for line in content.split("\n"):
        if re.match(r"^- ", line):
            bullets.append(line)
        elif bullets and re.match(r"^  \S", line):
            bullets[-1] = bullets[-1].rstrip() + " " + line.strip()
    return bullets


def classify_body(body: str, title: str, heading: str = r"^## Changelog\s*$"):
    """How a PR body answers for the changelog under HEADING.

    ("authored", sections) when the section carries bullets, ("flat", bullets)
    for a `## Changes` list, ("declared", None) when the body offers the
    section and leaves it empty, ("title", group) when the title stands in as
    the entry, and ("none", None) when nothing lands. collect_entries writes
    from it and --audit-sections reports from it, so the audit names exactly
    the PRs whose title would reach the notes.
    """
    sections = extract_changelog_sections(body, heading)
    if sections and any(bullets for bullets in sections.values()):
        return "authored", sections
    flat = extract_flat_changes(body)
    if flat:
        return "flat", flat
    # An author who filled in the template and left the section empty has
    # already answered the question, so the title is not a better answer
    # than the one given. The scoped types the fallback skips cover only
    # the type prefix, and internal work also ships as fix(ci), fix(hooks)
    # and fix(release), whose titles read as raw conventional commits
    # beside authored bullets.
    if declares_empty_changelog(body, heading):
        return "declared", None
    # No changelog content in the body: the PR title is the bullet, so a
    # shipped change is never silently absent from the section. Types the
    # cliff.toml policy skips (chore, ci, build, style, test) stay out here
    # too; a PR of those types that matters carries its own ## Changelog.
    group = group_for_title(title) if title else None
    return ("title", group) if group else ("none", None)


def collect_entries(
    owner: str,
    repo: str,
    pr_numbers: list[int],
    heading: str = r"^## Changelog\s*$",
    answered: set[int] | None = None,
) -> dict[str, list[str]]:
    """Aggregate the PR bodies' changelog bullets by category.

    ANSWERED, when given, collects the PRs whose body carried content under the
    heading, for a caller that reports how many PRs wrote their own entries.

    A PR that carries the heading and leaves it empty is skipped; one that never
    carries it falls back to its title, grouped by its conventional-commit type
    the way the git-cliff parsers group a commit.
    """
    aggregated: dict[str, list[str]] = {}
    for num in pr_numbers:
        pr = fetch_pr(owner, repo, num)
        if not pr:
            continue
        body = pr.get("body") or ""
        author = pr.get("author") or ""
        attrib = (
            f" by @{author} in [#{num}](https://github.com/{owner}/{repo}/pull/{num})"
            if author
            else ""
        )
        title = (pr.get("title") or "").strip()
        kind, found = classify_body(body, title, heading)
        if kind == "authored":
            if answered is not None:
                answered.add(num)
            for category, bullets in found.items():
                if not bullets:
                    continue
                aggregated.setdefault(category, [])
                for index, bullet in enumerate(bullets):
                    aggregated[category].append(
                        with_attribution(bullet, attrib) if index == 0 else bullet
                    )
        elif kind == "flat":
            aggregated.setdefault("Changed", [])
            for index, bullet in enumerate(found):
                aggregated["Changed"].append(
                    with_attribution(bullet, attrib) if index == 0 else bullet
                )
        elif kind == "title":
            aggregated.setdefault(found, [])
            aggregated[found].append(f"- {title}{attrib}")
    return aggregated


def version_from_tag(tag: str, prefix: str = "") -> str:
    """The bare `X.Y.Z` a tag names.

    A workspace member tags as `<crate>-vX.Y.Z`, so the prefix is supplied by
    the caller that knows which line is being released; the binary's own tags
    are `vX.Y.Z` and fall through to the `v` strip.
    """
    if prefix and tag.startswith(prefix):
        return tag[len(prefix) :]
    return tag[1:] if tag.startswith("v") else tag


def resolve_version_tag(version: str, prefix: str = "") -> str | None:
    """Return the git tag for a released version, or None.

    Tries the caller's own tag line first, then the `v`-prefixed spelling and
    the bare one (CalVer repos tag without a prefix). The existence check keeps
    the compare link from referencing a tag that does not exist (e.g. the first
    release, with no prior tag); the caller omits the link instead of emitting
    a dead ref. Repos with historical tags under another naming scheme should
    rename those tags rather than widen this lookup further.
    """
    candidates = ([f"{prefix}{version}"] if prefix else []) + [f"v{version}", version]
    for candidate in candidates:
        if run(["git", "tag", "-l", candidate]).stdout.strip():
            return candidate
    return None


def previous_tag(current_tag: str, prefix: str = "") -> str | None:
    """Newest release tag on the same line as the one being cut, or None.

    A member's line is selected by its prefix. Without one the binary's bare
    `vX.Y.Z` tags are matched and a member's prefixed tags are rejected, so the
    two lines never baseline against each other.
    """
    pattern = re.compile(rf"^{re.escape(prefix)}\d") if prefix else re.compile(r"^v?\d")
    for candidate in run(["git", "tag", "--sort=-version:refname"]).stdout.split():
        if candidate == current_tag or not pattern.match(candidate):
            continue
        if not prefix and "-v" in candidate:
            continue
        return candidate
    return None


BOOKKEEPING_RE = re.compile(r"^chore\(release\): (backport|sync dev)")


def dev_release_anchor(base: str, prev_tag: str | None) -> str | None:
    """The commit on BASE that ends the previous release, or None for the start.

    The backport commit is the boundary: everything after it on the integration
    branch belongs to this release. Its subject reads `sync dev after <tag>`,
    or `backport <tag> artifacts` from older backport scripts. Only the subject
    counts, because a later commit's message can quote it. Falling back to the
    tag covers a repo whose previous release was never synced back.
    """
    if not prev_tag:
        return None
    backport = re.compile(
        rf"^chore\(release\): (sync dev after|backport) {re.escape(prev_tag)}\b"
    )
    proc = run(["git", "log", f"origin/{base}", "--format=%H %s"])
    for line in proc.stdout.splitlines():
        sha, _, subject = line.partition(" ")
        if backport.match(subject):
            return sha
    found = run(["git", "rev-parse", "--verify", "--quiet", prev_tag]).stdout.strip()
    return prev_tag if found else None


def binary_tag_beside(tag: str) -> str | None:
    """The binary's `vX.Y.Z` tag on the same commit as a member's tag, or None.

    The dev backport's subject names only the binary's tag, so a member released
    in the same commit reaches its boundary through that tag's backport.
    """
    proc = run(["git", "tag", "--points-at", f"{tag}^{{commit}}"])
    for candidate in proc.stdout.split():
        if re.match(r"^v\d", candidate):
            return candidate
    return None


def release_anchor(base: str, prev_tag: str | None) -> str | None:
    """The boundary on BASE where this release's window opens, or None for the start."""
    anchor_tag = prev_tag
    if prev_tag and not re.match(r"^v\d", prev_tag):
        # A member's tag sits on main, which shares no recent history with the
        # integration branch; as an anchor it would open the window to nearly
        # all of it. The backport of the binary tag beside it is the boundary.
        anchor_tag = binary_tag_beside(prev_tag) or prev_tag
    anchor = dev_release_anchor(base, anchor_tag)
    if not anchor:
        # A member releasing for the first time has no tag of its own, and the
        # whole history of the integration branch is not its window: it ships
        # inside the current release train, so the repository's own anchor
        # bounds it. Without this the candidate list is every PR ever merged.
        anchor = dev_release_anchor(base, previous_tag("", ""))
    return anchor


def pr_numbers_in(span: str) -> list[int]:
    """The `(#N)` PR numbers of SPAN's commit subjects, bookkeeping left out.

    Read from git rather than `gh pr list --base <branch>`, because a stacked PR
    targets the branch below it rather than the integration branch and that query
    never returns one. The squash-merge subject carries `(#N)` whatever the PR
    targeted, so the history is the complete list.
    """
    proc = run(["git", "log", span, "--format=%s"])
    if proc.returncode != 0:
        fail(f"git log {span} failed: {proc.stderr.strip()}")
    numbers: dict[int, None] = {}
    for subject in proc.stdout.splitlines():
        if BOOKKEEPING_RE.match(subject):
            continue
        found = re.search(r"\(#(\d+)\)", subject)
        if found:
            numbers[int(found.group(1))] = None
    return sorted(numbers)


def merged_pr_numbers(base: str, prev_tag: str | None) -> list[int]:
    """PR numbers merged into BASE after the previous release's boundary."""
    anchor = release_anchor(base, prev_tag)
    return pr_numbers_in(f"{anchor}..origin/{base}" if anchor else f"origin/{base}")


BOUNDARY_RE = re.compile(r"^chore\(release\): (?:sync dev after|backport) (\S+)")


def carried_over_pr_numbers(
    base: str, prev_tag: str | None, cited: set[int] | None = None
) -> list[int]:
    """PR numbers merged before the previous release's backport that it may not carry.

    A release is cut from the integration branch and backported once its tag is
    out, so a PR merged in between ships in neither window that opens at a
    backport. These are the PRs between the backport before the previous one on
    the same release line and the previous one. The caller drops every one the
    changelog already lists, which leaves the PRs the previous release did not
    carry. With no earlier backport, the previous release was cut after the
    newest PR its section cites (CITED), so these are the PRs after that one.
    The newest rather than the oldest, because a window opened earlier would
    read back PRs an older generator left out on purpose. A section that cites
    no PR, such as a first release's hand-written notes, carries nothing over;
    nor does a boundary that is no backport commit, such as a tag.
    """
    anchor = release_anchor(base, prev_tag)
    if not anchor:
        return []
    line: str | None = None
    start: str | None = None
    newest_cited: str | None = None
    proc = run(["git", "log", f"origin/{base}", "--format=%H %s"])
    for entry in proc.stdout.splitlines():
        sha, _, subject = entry.partition(" ")
        found = BOUNDARY_RE.match(subject)
        if line is None:
            if sha == anchor:
                if not found:
                    return []
                line = release_line(found.group(1))
        elif found and release_line(found.group(1)) == line:
            start = sha
            break
        elif cited and newest_cited is None and not BOOKKEEPING_RE.match(subject):
            number = re.search(r"\(#(\d+)\)", subject)
            if number and int(number.group(1)) in cited:
                newest_cited = sha
    start = start or newest_cited
    if not start:
        return []
    return pr_numbers_in(f"{start}..{anchor}")


def release_line(tag: str) -> str:
    """The prefix naming TAG's release line: empty for the binary, `name-` for a member."""
    return re.sub(r"v?\d.*$", "", tag)


def listed_before(content: str, version: str | None) -> set[int]:
    """PR numbers a changelog lists outside VERSION's section: what earlier releases carried."""
    this_section = extract_version_section(content, version) if version else ""
    return set(pr_numbers_from_section(content)) - set(pr_numbers_from_section(this_section))


def unreleased_pr_numbers(
    base: str, prev_tag: str | None, content: str, version: str | None, prefix: str = ""
) -> list[int]:
    """The PRs this release carries: merged since the previous release's backport,
    or before it and carried by no release, leaving out every PR the changelog
    CONTENT lists outside VERSION's section."""
    cited: set[int] = set()
    if prev_tag:
        previous = extract_version_section(content, version_from_tag(prev_tag, prefix))
        cited = set(pr_numbers_from_section(previous))
    numbers = carried_over_pr_numbers(base, prev_tag, cited) + merged_pr_numbers(base, prev_tag)
    listed = listed_before(content, version)
    return sorted({n for n in numbers if n not in listed})


def seed_version_section(changelog: Path, version: str) -> None:
    """Create CHANGELOG.md if needed and insert an empty `## [version]` section
    at the top, so rewrite_version_section has a header to fill."""
    header = (
        "# Changelog\n\n"
        "All notable changes to this project will be documented in this file.\n\n"
    )
    content = changelog.read_text() if changelog.exists() else header
    if re.search(rf"^## \[{re.escape(version)}\]", content, re.MULTILINE):
        return
    # UTC, because cliff.toml renders its own header from `{{ timestamp | date() }}`
    # in UTC. A local date here makes the two generation modes stamp different days
    # for one release whenever the operator's offset crosses midnight.
    stamp = datetime.now(timezone.utc).date().isoformat()
    section = f"## [{version}] - {stamp}\n\n"
    first = re.search(r"^## \[", content, re.MULTILINE)
    if first:
        content = content[: first.start()] + section + content[first.start():]
    else:
        content = content.rstrip("\n") + "\n\n" + section
    changelog.write_text(content)


def rewrite_version_section(
    changelog: Path,
    version: str,
    tag: str,
    owner: str,
    repo: str,
    entries: dict[str, list[str]],
    prefix: str = "",
) -> None:
    content = changelog.read_text()
    header_re = re.compile(rf"^## \[{re.escape(version)}\].*$", re.MULTILINE)
    header_match = header_re.search(content)
    if not header_match:
        return

    pieces: list[str] = [header_match.group(0)]
    seen: set[str] = set()
    for cat in CATEGORIES:
        bullets = entries.get(cat)
        if bullets:
            pieces.append(f"\n### {cat}\n")
            pieces.extend(bullets)
            seen.add(cat)
    for cat, bullets in entries.items():
        if cat in seen or not bullets:
            continue
        pieces.append(f"\n### {cat}\n")
        pieces.extend(bullets)

    new_section = "\n".join(pieces) + "\n"

    prev_match = re.search(
        rf"## \[{re.escape(version)}\].*?\n## \[([^\]]+)\]", content, re.DOTALL
    )
    if prev_match:
        prev_tag = resolve_version_tag(prev_match.group(1), prefix)
        if prev_tag:
            new_section += (
                f"\n**Full Changelog**: "
                f"[{prev_tag}...{tag}]"
                f"(https://github.com/{owner}/{repo}/compare/"
                f"{prev_tag}...{tag})\n"
            )

    section_re = re.compile(
        rf"## \[{re.escape(version)}\].*?(?=\n## \[|\Z)", re.DOTALL
    )
    new_content = section_re.sub(new_section.rstrip() + "\n", content, count=1)
    changelog.write_text(new_content)


def report_dry_run(original: str, regenerated: str) -> int:
    """Report --dry-run drift between the on-disk and regenerated changelog.

    Returns 0 when they match and 1 on any drift, printing the reason line and
    a unified diff to stderr. Drift that vanishes once every run of whitespace
    collapses to one space is named as wrapping: the generator writes one
    logical line per bullet, so a rewrapped file still fails, but the reason
    points at the rewrap instead of the PR bodies. Line-based whitespace
    tolerance misses a bullet split across two lines, hence the flattening.
    """
    if regenerated == original:
        print("DRY RUN: CHANGELOG.md is current (no regen drift)")
        return 0
    if " ".join(original.split()) == " ".join(regenerated.split()):
        reason = (
            "DRY RUN: CHANGELOG.md differs only in line wrapping (whitespace-only "
            "regen drift; a lint config or formatter likely rewraps it)"
        )
    else:
        reason = "DRY RUN: CHANGELOG.md would change (regen drift detected)"
    print(reason, file=sys.stderr)
    sys.stderr.writelines(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            regenerated.splitlines(keepends=True),
            fromfile="CHANGELOG.md (current)",
            tofile="CHANGELOG.md (regenerated)",
        )
    )
    return 1


def member_pr_numbers(
    owner: str, repo: str, pr_nums: list[int], crate_config: dict
) -> tuple[list[int], int]:
    """The PRs among PR_NUMS that belong to the member, and how many by their block.

    The release branch carries no member history, so membership comes from the
    files each PR changed rather than from git-cliff. A body that addresses the
    member directly counts whatever it touched: the author's own block is a
    better answer than the paths, which miss a change made while the member's
    code lived elsewhere.
    """
    include = crate_config["include_paths"]
    exclude = crate_config["exclude_paths"]
    if not include:
        return pr_nums, 0
    heading_re = rf"^## {re.escape(crate_config['heading'])}\s*$"
    kept: list[int] = []
    by_block = 0
    for n in pr_nums:
        pr = fetch_pr(owner, repo, n)
        body = (pr or {}).get("body") or ""
        if slice_below(body, heading_re) is not None:
            kept.append(n)
            by_block += 1
        elif pr_touches_member(owner, repo, n, include, exclude):
            kept.append(n)
    return kept, by_block


def audit_sections_mode(
    args,
    cliff_toml: Path,
    changelog: Path,
    prefix: str = "",
    crate_config: dict | None = None,
) -> int:
    """Name the PRs whose changelog entry would be their title for want of a section.

    The PRs are the ones --from-dev-prs reads for the same changelog: those
    merged into the integration branch that no release on this tag line
    carried, so a stacked PR is among them, narrowed to the member's own for
    --crate. A body is judged by classify_body, the rule collect_entries
    writes from.
    """
    owner, repo_name = read_remote_github(cliff_toml)
    if not (owner and repo_name):
        fail("--audit-sections needs [remote.github] owner/repo in cliff.toml")
    if not have("gh"):
        fail("--audit-sections needs the gh CLI")
    ensure_github_token()

    tag = args.tag or release_branch_tag()[1]
    prev = previous_tag(tag or "", prefix)
    content = changelog.read_text() if changelog.exists() else ""
    version = version_from_tag(tag, prefix) if tag else None
    pr_nums = unreleased_pr_numbers(args.dev_branch, prev, content, version, prefix)
    prefetch_prs(owner, repo_name, pr_nums)
    label = crate_config["heading"] if crate_config else "Changelog"
    heading = rf"^## {re.escape(label)}\s*$"
    if crate_config and pr_nums:
        pr_nums, _ = member_pr_numbers(owner, repo_name, pr_nums, crate_config)

    counts = {"authored": 0, "flat": 0, "declared": 0, "none": 0}
    findings: list[str] = []
    for num in pr_nums:
        pr = fetch_pr(owner, repo_name, num)
        if not pr:
            findings.append(f"#{num}: GitHub did not return it, so its section is unchecked")
            continue
        title = (pr.get("title") or "").strip()
        kind, _ = classify_body(pr.get("body") or "", title, heading)
        if kind == "title":
            findings.append(f"#{num} {title}: no '## {label}' section, so the title becomes its entry")
        else:
            counts[kind] += 1

    window = f"since {prev}" if prev else "in its whole history"
    print(
        f"{len(pr_nums)} PR(s) merged into {args.dev_branch} {window}: "
        f"{counts['authored'] + counts['flat']} with entries, "
        f"{counts['declared']} left '## {label}' empty on purpose, "
        f"{counts['none']} need none, {len(findings)} without the section"
    )
    for finding in findings:
        print(f"  {finding}")
    return 1 if findings else 0


def from_dev_prs_mode(
    args,
    cliff_toml: Path,
    changelog: Path,
    prefix: str = "",
    crate_config: dict | None = None,
) -> int:
    """Fill the version section from PRs merged into the integration branch."""
    tag = args.tag or detect_tag_from_branch()
    version = version_from_tag(tag, prefix)
    owner, repo_name = read_remote_github(cliff_toml)
    if not (owner and repo_name):
        fail("--from-dev-prs needs [remote.github] owner/repo in cliff.toml")
    if not have("gh"):
        fail("--from-dev-prs needs the gh CLI")
    ensure_github_token()

    dry_run_original: str | None = None
    if args.dry_run:
        if not changelog.exists():
            fail("--dry-run requires an existing CHANGELOG.md to compare against")
        dry_run_original = changelog.read_text()

    try:
        prev = previous_tag(tag, prefix)
        seed_version_section(changelog, version)
        content = changelog.read_text()
        pr_nums = unreleased_pr_numbers(args.dev_branch, prev, content, version, prefix)
        prefetch_prs(owner, repo_name, pr_nums)
        if crate_config and pr_nums:
            total = len(pr_nums)
            pr_nums, by_block = member_pr_numbers(owner, repo_name, pr_nums, crate_config)
            if crate_config["include_paths"]:
                print(
                    f"{len(pr_nums)} of {total} PRs belong to {args.crate} "
                    f"({by_block} by their own changelog block)",
                    file=sys.stderr,
                )
        if not pr_nums:
            print(
                f"no PRs merged into {args.dev_branch} since {prev or 'the start'} "
                "that the changelog does not already list",
                file=sys.stderr,
            )
        if pr_nums and crate_config:
            label = crate_config["heading"]
            heading = rf"^## {re.escape(label)}\s*$"
            answered: set[int] = set()
            entries = collect_entries(owner, repo_name, pr_nums, heading, answered)
            print(
                f"{len(answered)} of {len(pr_nums)} carry a '## {label}' block "
                "with content; a PR that leaves it empty says the crate is "
                "unaffected, and one that omits it falls back to its title",
                file=sys.stderr,
            )
        else:
            entries = collect_entries(owner, repo_name, pr_nums) if pr_nums else {}
        if entries:
            rewrite_version_section(
                changelog, version, tag, owner, repo_name, entries, prefix
            )

        if dry_run_original is not None:
            return report_dry_run(dry_run_original, changelog.read_text())

        print(f"Updated {changelog} from {len(pr_nums)} PRs merged into {args.dev_branch}")
        print("\nNext steps:")
        print(f"  git add {changelog}")
        print("  git commit -m 'docs: update CHANGELOG.md'")
        return 0
    finally:
        if dry_run_original is not None:
            changelog.write_text(dry_run_original)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Run regen against the current CHANGELOG.md and restore the original on exit. "
            "Exit 0 if idempotent, 1 with a unified diff if it would drift. The first "
            "stderr line names whitespace-only drift as line wrapping (a lint config or "
            "formatter rewraps the file) and anything else as regen drift."
        ),
    )
    parser.add_argument(
        "--print-tag",
        action="store_true",
        help="Print the resolved version tag and exit (no git-cliff run).",
    )
    parser.add_argument(
        "--from-dev-prs",
        action="store_true",
        help=(
            "Build the version section from PRs merged into --dev-branch since the "
            "previous release (overlay-built release branches); no git-cliff run."
        ),
    )
    parser.add_argument("--dev-branch", default="dev")
    parser.add_argument(
        "--audit-sections",
        action="store_true",
        help=(
            "List the PRs --from-dev-prs would read whose entry would fall back to "
            "their title because the body never offered the changelog section; exit 1 "
            "when any does. A section left empty passes. Writes nothing."
        ),
    )
    parser.add_argument("--tag")
    parser.add_argument(
        "--crate",
        help=(
            "Generate a workspace member's own changelog instead of the root one: "
            "the file its [package.metadata.changelog] table names, on its own tag "
            "line (default <crate>-vX.Y.Z). "
            "Requires --tag, since a member is released from a branch off the "
            "integration branch rather than from a release/vX.Y.Z branch."
        ),
    )
    parser.add_argument("repo_path", nargs="?", default=".")
    args = parser.parse_args()

    repo = Path(args.repo_path).resolve()
    # One git-cliff config for the workspace. Its `[git]` defaults describe the
    # binary's line; a member overrides the scope through CLI flags below.
    cliff_toml = repo / "cliff.toml"
    changelog = repo / "CHANGELOG.md"
    prefix = ""
    crate_config: dict | None = None
    if args.crate:
        crate_config = read_crate_changelog_config(repo, args.crate)
        changelog = crate_config["changelog"]
        prefix = crate_config["tag_prefix"]
        # A release branch names the binary's tag, so only a member on some
        # other tag line has to be told which one is being cut.
        if not args.tag and not (args.check or args.audit_sections) and prefix != "v":
            fail(f"--crate needs --tag {prefix}X.Y.Z")

    if not cliff_toml.exists():
        fail(f"cliff.toml not found in {repo}")

    # Before anything reads or writes it. A routing changelog has no version
    # section to check and must never be regenerated over.
    refuse_router(changelog, args.crate)

    if args.check:
        return check_mode(changelog)

    if args.audit_sections:
        return audit_sections_mode(args, cliff_toml, changelog, prefix, crate_config)

    if args.print_tag:
        print(args.tag or detect_tag_from_branch())
        return 0

    if args.from_dev_prs:
        return from_dev_prs_mode(args, cliff_toml, changelog, prefix, crate_config)

    if not have("git-cliff"):
        print("error: git-cliff is not installed", file=sys.stderr)
        print("  Install: cargo install git-cliff", file=sys.stderr)
        print("  Or:      brew install git-cliff", file=sys.stderr)
        return 1

    tag = args.tag or detect_tag_from_branch()
    version = version_from_tag(tag, prefix)

    ensure_github_token()

    dry_run_original: str | None = None
    if args.dry_run:
        if not changelog.exists():
            fail("--dry-run requires an existing CHANGELOG.md to compare against")
        dry_run_original = changelog.read_text()

    # Duplicate-section guard: skip the git-cliff prepend when a section for
    # this tag already exists, so re-running against an already-released tag
    # doesn't append a second copy of the same version. The PR-body expansion
    # below still runs either way, so an existing section is refreshed from
    # the current PR bodies (and dry-run has something real to compare).
    section_header_re = re.compile(
        rf"^## \[{re.escape(version)}\]", re.MULTILINE
    )
    duplicate_section = (
        changelog.exists() and bool(section_header_re.search(changelog.read_text()))
    )
    if duplicate_section and not args.dry_run:
        print(
            f"CHANGELOG.md already has a [{version}] section; "
            "skipping prepend, refreshing from PR bodies"
        )

    try:
        if not duplicate_section:
            cwd = os.getcwd()
            try:
                os.chdir(repo)
                run_git_cliff(tag, changelog, cliff_toml, crate_config)
            finally:
                os.chdir(cwd)

        owner, repo_name = read_remote_github(cliff_toml)
        has_gh_integration = bool(owner and repo_name and have("gh"))

        if has_gh_integration:
            section = extract_version_section(changelog.read_text(), version)
            pr_nums = pr_numbers_from_section(section)
            prefetch_prs(owner, repo_name, pr_nums)
            heading = r"^## Changelog\s*$"
            if crate_config:
                # git-cliff scoped the section to the member's paths, so its PRs
                # are the member's. Each one's bullets come from the block
                # addressed to the member, read the way --from-dev-prs reads
                # them, so refreshing a section either mode wrote reproduces it.
                heading = rf"^## {re.escape(crate_config['heading'])}\s*$"
            if pr_nums:
                entries = collect_entries(owner, repo_name, pr_nums, heading)
                if entries:
                    rewrite_version_section(
                        changelog, version, tag, owner, repo_name, entries, prefix
                    )

        if dry_run_original is not None:
            return report_dry_run(dry_run_original, changelog.read_text())

        if has_gh_integration:
            print(f"Updated {changelog}")
        else:
            print(
                f"Updated {changelog} (skipping PR expansion; missing [remote.github] or gh CLI)"
            )
        print("\nNext steps:")
        print(f"  git add {changelog}")
        print("  git commit -m 'docs: update CHANGELOG.md'")
        return 0
    finally:
        if dry_run_original is not None:
            changelog.write_text(dry_run_original)


if __name__ == "__main__":
    sys.exit(main())
