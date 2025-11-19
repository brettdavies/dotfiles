# CLAUDE.md

## CLI Tool Usage Guidance

- **Prefer CLI tools** over direct in-memory manipulation when possible, especially for editing or searching within larger files or across the codebase.
    - Examples: Use `sed`, `awk`, or in-place editing CLI utilities for modifying files; use code-aware tools (`ast-grep`) for refactoring.
- **For file deletion,** do NOT use `rm` or `git rm`.  
    - Instead, use [`trash`](https://github.com/sindresorhus/trash) to safely move files to the system trash, preserving the ability to recover accidentally deleted files.
- **For code search:**
    - Always use [`rg` (ripgrep)](https://github.com/BurntSushi/ripgrep) instead of `grep` for fast recursive search.
    - [`ast-grep`](https://ast-grep.github.io/) is also available for powerful, syntax-aware, high-performance codebase traversal.
- When uncertain what CLI tools are available on the system, first run:
    ```bash
    brew list
    ```
    to enumerate all installed Homebrew tools. If your desired CLI tool is not listed, or you encounter a "command not found" error, ask the user to install the necessary tool before continuing.
- **Summary:** Use CLI-oriented, scriptable approaches for repetitive or large-scale file/codebase operations. Prefer code-aware tools for search/replace and avoid destructive deletions. If a needed tool is missing, request that the user install it before attempting the operation.

## Core Coding Principles

- **DRY (Don't Repeat Yourself):** Avoid duplicating logic or data; abstract and reuse code where possible.
- **STAR (Single Truth, Authoritative Record):** Ensure shared types, constants, and config live in a single place; always import, never duplicate.
- **ACID (Atomic, Consistent, Isolated, Durable) for Data:** Treat every state change and file update as atomic—leave no chance for partial or inconsistent writes.
- **Fail Fast:** Catch missing environment variables or invalid states at startup whenever possible.
- **Explicit is Better:** Prefer clear, type-safe code and explicit imports over magic or implicit behaviors.

See [Coding Standards](./docs/architecture/17-coding-standards.md) for full details.

---

## Git Commit Message Format

**Trigger**: when creating commits

### Conventional Commits Specification

Use the Conventional Commit Messages specification to generate commit messages

The commit message should be structured as follows:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Commit Types

The commit contains the following structural elements, to communicate intent to the consumers of your library:

- **fix**: a commit of the type fix patches a bug in your codebase (this correlates with PATCH in Semantic Versioning).
- **feat**: a commit of the type feat introduces a new feature to the codebase (this correlates with MINOR in Semantic Versioning).
- **BREAKING CHANGE**: a commit that has a footer BREAKING CHANGE:, or appends a ! after the type/scope, introduces a breaking API change (correlating with MAJOR in Semantic Versioning). A BREAKING CHANGE can be part of commits of any type.
- **types other than fix: and feat:** are allowed, for example @commitlint/config-conventional (based on the Angular convention) recommends build:, chore:, ci:, docs:, style:, refactor:, perf:, test:, and others.
- **footers other than BREAKING CHANGE:** <description> may be provided and follow a convention similar to git trailer format.
- Additional types are not mandated by the Conventional Commits specification, and have no implicit effect in Semantic Versioning (unless they include a BREAKING CHANGE). A scope may be provided to a commit's type, to provide additional contextual information and is contained within parenthesis, e.g., feat(parser): add ability to parse arrays.

### Specification Details

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119.

- Commits MUST be prefixed with a type, which consists of a noun, feat, fix, etc., followed by the OPTIONAL scope, OPTIONAL !, and REQUIRED terminal colon and space.
- The type feat MUST be used when a commit adds a new feature to your application or library.
- The type fix MUST be used when a commit represents a bug fix for your application.
- A scope MAY be provided after a type. A scope MUST consist of a noun describing a section of the codebase surrounded by parenthesis, e.g., fix(parser):
- A description MUST immediately follow the colon and space after the type/scope prefix. The description is a short summary of the code changes, e.g., fix: array parsing issue when multiple spaces were contained in string.
- A longer commit body MAY be provided after the short description, providing additional contextual information about the code changes. The body MUST begin one blank line after the description.
- A commit body is free-form and MAY consist of any number of newline separated paragraphs.
- One or more footers MAY be provided one blank line after the body. Each footer MUST consist of a word token, followed by either a :<space> or <space># separator, followed by a string value (this is inspired by the git trailer convention).
- A footer's token MUST use - in place of whitespace characters, e.g., Acked-by (this helps differentiate the footer section from a multi-paragraph body). An exception is made for BREAKING CHANGE, which MAY also be used as a token.
- A footer's value MAY contain spaces and newlines, and parsing MUST terminate when the next valid footer token/separator pair is observed.
- Breaking changes MUST be indicated in the type/scope prefix of a commit, or as an entry in the footer.
- If included as a footer, a breaking change MUST consist of the uppercase text BREAKING CHANGE, followed by a colon, space, and description, e.g., BREAKING CHANGE: environment variables now take precedence over config files.
- If included in the type/scope prefix, breaking changes MUST be indicated by a ! immediately before the :. If ! is used, BREAKING CHANGE: MAY be omitted from the footer section, and the commit description SHALL be used to describe the breaking change.
- Types other than feat and fix MAY be used in your commit messages, e.g., docs: update ref docs.
- The units of information that make up Conventional Commits MUST NOT be treated as case sensitive by implementors, with the exception of BREAKING CHANGE which MUST be uppercase.
- BREAKING-CHANGE MUST be synonymous with BREAKING CHANGE, when used as a token in a footer.

---

**Last Updated**: 2025-11-07
