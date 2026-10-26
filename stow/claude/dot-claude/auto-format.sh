#!/usr/bin/env bash

# Auto-format hook for Claude Code (PostToolUse)
# Each formatter uses `|| true` so failures never block Claude's file writes
set -e

file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

[[ -z "$file" ]] && exit 0
[[ ! -f "$file" ]] && exit 0

# A loose file under a scratch path is a transient draft, such as a PR body
# written for `gh pr edit --body-file`, and keeps its authored shape so it
# pastes cleanly into GitHub forms. A file inside a git work tree is repo
# content wherever its checkout lives, so a worktree under /tmp is formatted
# like any other. `--is-inside-work-tree` prints "false" with a zero exit for a
# path inside the .git directory, so the test reads its output, not its status.
in_scratch_path() {
  case "$1" in
    /tmp/* | /var/tmp/*) return 0 ;;
  esac
  [[ -n "${TMPDIR:-}" && "${TMPDIR%/}" != "/" && "$1" == "${TMPDIR%/}"/* ]]
}
if in_scratch_path "$file" \
  && [[ "$(git -C "$(dirname "$file")" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]]; then
  exit 0
fi

ext="${file##*.}"

# JSON output (not plain text) because PostToolUse hooks feed additionalContext
# back into Claude's transcript only via structured JSON
report_errors() {
  local errors="$1"
  [ -z "$errors" ] && return
  jq -n --arg ctx "$errors" '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: $ctx
        }
    }'
}

has_prettier_config() {
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.json" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.yml" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.yaml" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.js" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.cjs" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.mjs" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/prettier.config.js" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/prettier.config.cjs" ]] \
    || [[ -f "$CLAUDE_PROJECT_DIR/prettier.config.mjs" ]]
}

case "$ext" in
  ts | tsx | js | jsx | json | jsonc)
    # No report_errors: pure formatters either fix everything or fail on parse errors (already visible)
    if [[ -f "$CLAUDE_PROJECT_DIR/biome.json" ]] || [[ -f "$CLAUDE_PROJECT_DIR/biome.jsonc" ]]; then
      cd "$CLAUDE_PROJECT_DIR"
      bunx biome check --write "$file" 2>&1 | tail -1 || true
    elif has_prettier_config; then
      cd "$CLAUDE_PROJECT_DIR"
      bunx prettier --write "$file" 2>&1 | tail -1 || true
    fi
    ;;
  css | scss | less | html | vue | svelte | yaml | yml | graphql | gql)
    if has_prettier_config; then
      cd "$CLAUDE_PROJECT_DIR"
      bunx prettier --write "$file" 2>&1 | tail -1 || true
    fi
    # actionlint for GitHub Actions workflow files — must live here,
    # not in a later `yml|yaml)` arm, because bash `case` stops at the
    # first match and `yaml|yml` already matches above.
    if [[ "$ext" == "yml" || "$ext" == "yaml" ]] \
      && [[ "$file" == *".github/workflows/"* ]] \
      && command -v actionlint &>/dev/null; then
      lint_output=$(actionlint "$file" 2>&1) || true
      report_errors "$lint_output"
    fi
    ;;
  md)
    # --- Step 1: auto-wrap prose to configured line width ---
    md_wrap="$HOME/.claude/md-wrap.py"
    md_align="$HOME/.claude/md-align-tables.py"
    global_config="$HOME/.markdownlint-cli2.yaml"
    md013_default=120

    # The config that governs a markdown file is the one in that file's own
    # directory tree, found by walking up from the file. The session's project
    # dir is the wrong anchor: an Edit can reach a repo other than
    # CLAUDE_PROJECT_DIR, and that repo's own MD013 width and `ignores`,
    # including a 9999 opt-out, are the ones that apply to it.
    #
    # The walk is lexical on the path as handed in, never resolved through
    # realpath. A file reached through a symlinked directory has to stay
    # described by the tree holding the link, because that is the path form the
    # ignore globs are written against: physically resolving
    # <repo>/docs/solutions/x.md to the shared clone strips the very prefix
    # `docs/solutions/**` matches on. $HOME terminates the walk because the
    # global config lives there and is the intended fallback.
    #
    # Sets md_base to the directory whose markdownlint config governs the file,
    # which is also the directory that config's `ignores` globs are matched
    # from. The walk stops at the first boundary it meets, so a file can never
    # be governed by a config outside its own repository.
    md_base=""
    md_resolve_roots() {
      local dir=$1
      while :; do
        if [[ -f "$dir/.markdownlint-cli2.yaml" || -f "$dir/.markdownlint.yaml" ]]; then
          md_base=$dir
          return 0
        fi
        # A repo that declares no config of its own still takes the global one,
        # whose globs read as repo-relative (`CHANGELOG.md`, `docs/solutions/**`),
        # so stop here and match them from the repo root. -e, not -d: a worktree
        # or a repo with an external git dir carries .git as a gitdir pointer
        # file.
        if [[ -e "$dir/.git" ]]; then
          md_base=$dir
          return 0
        fi
        if [[ -n "${CLAUDE_PROJECT_DIR:-}" && "$dir" == "$CLAUDE_PROJECT_DIR" ]]; then
          md_base=$dir
          return 0
        fi
        if [[ "$dir" == "$HOME" || "$dir" == "/" ]]; then
          md_base=$dir
          return 0
        fi
        dir=$(dirname "$dir")
      done
    }

    [[ "$file" == /* ]] || file="$PWD/$file"
    md_resolve_roots "$(dirname "$file")"

    # Matching the globs from anywhere the file does not live under would leave
    # rel_file absolute below, which matches no glob and makes the whole ignore
    # list dead rather than merely wrong.
    cd "$md_base" || exit 0

    # The config's `ignores` globs gate every step, not just the linter.
    # markdownlint-cli2 applies them itself, but the prose wrapper and the table
    # aligner take a path and format it, so a file the config excludes was still
    # being rewritten by steps 1 and 2. That reflowed the shared solutions repo
    # and any generated artifact whose own tool owns its line breaks: a
    # CHANGELOG.md emitted as one logical line per bullet came back wrapped, and
    # the next `git add -A` committed the rewrap.
    md_ignored() {
      local rel=$1 cfg pat
      command -v yq &>/dev/null || return 1
      for cfg in .markdownlint-cli2.yaml .markdownlint.yaml "$global_config"; do
        [[ -f "$cfg" ]] || continue
        while IFS= read -r pat; do
          [[ -n "$pat" ]] || continue
          # Unquoted on purpose: $pat is a glob to match with, not a literal.
          # shellcheck disable=SC2053
          [[ "$rel" == $pat ]] && return 0
          # `.ignores[]` yields nothing when the key is absent. This is mikefarah
          # yq, which has no `empty`, so the jq spelling errors out instead.
        done < <(yq '.ignores[]' "$cfg" 2>/dev/null)
      done
      return 1
    }

    # markdownlint resolves its globs from the config's directory, so compare
    # the path relative to that directory rather than whatever form the hook was
    # handed. $PWD is that directory after the cd above. A path left absolute
    # here matches no glob, so no ignore could ever apply to it.
    rel_file="${file#"$PWD"/}"
    if md_ignored "$rel_file"; then
      exit 0
    fi

    # Read the configured line width from the config the walk above selected,
    # falling back to the global one when that tree declares none.
    max_len=$md013_default
    if command -v yq &>/dev/null; then
      if [[ -f .markdownlint-cli2.yaml ]]; then
        max_len=$(yq ".config.MD013.line_length // $md013_default" .markdownlint-cli2.yaml)
      elif [[ -f .markdownlint.yaml ]]; then
        max_len=$(yq ".config.MD013.line_length // $md013_default" .markdownlint.yaml)
      elif [[ -f "$global_config" ]]; then
        max_len=$(yq ".config.MD013.line_length // $md013_default" "$global_config")
      fi
    fi

    # Repo opt-out: an absurd MD013 line width (>= 9999) disables markdown
    # auto-format here (prose wrap, table align, and lint autofix all skip), so
    # a repo whose committed markdown owns its own wrapping and table style is
    # never reflowed by a one-line edit.
    if [[ "$max_len" =~ ^[0-9]+$ ]] && ((max_len >= 9999)); then
      exit 0
    fi

    if [[ -x "$md_wrap" ]]; then
      python3 "$md_wrap" -i -w "$max_len" "$file" 2>/dev/null || true
    fi

    # --- Step 2: align GFM tables (MD060 autofix; upstream gap tracked at
    # DavidAnson/markdownlint#1980). Script uses a `uv run --script` shebang so
    # PEP 723 inline metadata drives its own interpreter resolution. ---
    if [[ -x "$md_align" ]] && command -v uv &>/dev/null; then
      "$md_align" "$file" 2>/dev/null || true
    fi

    # --- Step 3: run markdownlint ---
    local_config=""
    [[ -f .markdownlint-cli2.yaml ]] && local_config=".markdownlint-cli2.yaml"
    [[ -f .markdownlint.yaml ]] && local_config=".markdownlint.yaml"

    config_args=()
    tmp_config=""
    if [[ -n "$local_config" ]] && command -v yq &>/dev/null; then
      tmp_config="/tmp/.markdownlint-cli2.yaml"
      yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$global_config" "$local_config" >"$tmp_config"
      config_args=(--config "$tmp_config")
    elif [[ -f "$global_config" ]]; then
      config_args=(--config "$global_config")
    fi

    lint_status=0
    lint_output=$(markdownlint-cli2 "${config_args[@]}" --no-globs --fix "$file" 2>&1) || lint_status=$?

    # Forward only what the agent can act on. markdownlint-cli2 opens with a
    # version banner, a `Finding:` line restating the path and every ignore
    # glob, and a `Linting: N file` count. On a clean file those three plus
    # `Summary: 0 issues in 0 files` are the entire output, so forwarding it
    # spends context on every markdown edit to say nothing; on a file that does
    # have violations they push the violations down the report. `Summary:` is
    # kept whenever the count is non-zero, because then it is the headline.
    lint_report=$(printf '%s\n' "$lint_output" | grep -Ev \
      '^(markdownlint-cli2 v|Finding: |Linting: [0-9]+ files?$|Summary: 0 issues)' || true)
    if [[ -z "${lint_report//[[:space:]]/}" ]]; then
      lint_report=""
    fi

    # A non-zero exit that filters down to nothing means markdownlint failed in
    # a way its own summary lines do not describe, such as an unreadable config
    # or a crash. The raw output is the only diagnostic in that case, so keep it
    # rather than reporting silence over a broken linter.
    if [[ -z "$lint_report" ]] && ((lint_status != 0)); then
      lint_report=$lint_output
    fi

    # Any remaining MD013 violations are unbreakable lines (long URLs, code spans).
    # Tell the agent the limit and that these are acceptable exceptions.
    if [[ "$lint_report" == *"MD013"* ]]; then
      lint_report="${lint_report}
MD013 fix hint: line length limit is ${max_len} characters. Wrap lines to fill up to this limit — do not wrap shorter. Remaining MD013 violations are likely unbreakable tokens (long URLs or inline code) — these are acceptable."
    fi

    [[ -n "$tmp_config" ]] && rm -f "$tmp_config"
    report_errors "$lint_report"
    ;;
  py)
    if command -v ruff &>/dev/null && [[ -f "$CLAUDE_PROJECT_DIR/pyproject.toml" ]]; then
      # Lint fixes before format — otherwise formatting may conflict with lint autofixes
      lint_output=$(ruff check --fix "$file" 2>&1) || true
      ruff format "$file" 2>&1 || true
      report_errors "$lint_output"
    fi
    ;;
  rs)
    if command -v rustfmt &>/dev/null; then
      rustfmt "$file" 2>&1 || true
    fi
    ;;
  sh)
    if command -v shfmt &>/dev/null; then
      # shfmt honors the .editorconfig `ignore` sections (generated completions,
      # test data) for an explicit path only under --apply-ignore.
      shfmt -i 2 -ci -bn --apply-ignore -w "$file" 2>&1 || true
    fi
    ;;
  rb)
    if command -v rubocop &>/dev/null; then
      lint_output=$(rubocop -a --format simple "$file" 2>&1) || true
      report_errors "$lint_output"
    fi
    ;;
esac

exit 0
