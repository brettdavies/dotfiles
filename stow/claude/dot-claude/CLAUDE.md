# Global User Instructions

## Core Coding Principles

- **DRY (Don't Repeat Yourself):** Avoid duplicating logic or data; abstract and reuse code where possible.
- **STAR (Single Truth, Authoritative Record):** Ensure shared types, constants, and config live in a single place; always import, never duplicate.
- **SRP (Single Responsibility Principle):** Each module, class, or function should have exactly one responsibility or reason to change.
- **OCP (Open/Closed Principle):** Code entities should be open for extension but closed for modification.
- **SOLID (Object-Oriented Design Principles):**
  - **S**ingle Responsibility: Each module/class has only one reason to change.
  - **O**pen/Closed: Code is open for extension, closed for modification.
  - **L**iskov Substitution: Types are replaceable by their subtypes without correctness errors.
  - **I**nterface Segregation: Prefer many small, focused interfaces to large, generic ones.
  - **D**ependency Inversion: Rely on abstractions, not concrete implementations.
- **ACID (Atomic, Consistent, Isolated, Durable) for Data:** Treat every state change and file update as atomic—leave no chance for partial or inconsistent writes.
- **KISS (Keep It Simple, Stupid):** Prioritize simplicity in code and design; avoid unnecessary complexity.
- **YAGNI (You Aren't Gonna Need It):** Don't add features or abstractions until they are necessary.
- **Fail Fast:** Catch missing environment variables or invalid states at startup whenever possible.
- **Explicit is Better:** Prefer clear, type-safe code and explicit imports over magic or implicit behaviors.
- **200-Line Refactor Trigger:** Any single file exceeding 200 lines of code (excluding comments) should trigger a refactor review to evaluate splitting responsibilities into smaller, focused modules.

---

## CLI Tool Usage Guidance

- **Prefer CLI tools** over direct in-memory manipulation when possible, especially for editing or searching within larger files or across the codebase.
  - Examples: Use `sed`, `awk`, or in-place editing CLI utilities for modifying files; use code-aware tools (`ast-grep`) for refactoring.
- **For file deletion,** do NOT use `rm` or `git rm`.
  - Instead, use [`trash`](https://github.com/sindresorhus/trash) to safely move files to the system trash.
- **For code search:**
  - Always use [`rg` (ripgrep)](https://github.com/BurntSushi/ripgrep) instead of `grep` for fast recursive search.
  - [`ast-grep`](https://ast-grep.github.io/) is available for syntax-aware codebase traversal.
- When uncertain what CLI tools are available, you can enumerate installed tools with the following commands:
  - `brew list` to list installed Homebrew CLI tools,
  - `uvx list`, `pip3 list`, and `pipx list` to list Python-based CLI utilities,
  - `bun pm ls -g` to list globally installed Bun packages (if any provide CLI tools).
  - If a needed tool is missing, ask the user to install it.

---

## Commit Messages

Always utilize Conventional Commits. Always reference `.cursor/rules/commit-message.mdc` for full specification and agent workflow instructions before starting working on a git commit or amending a commit.

---

**Last Updated**: 2025-12-03
