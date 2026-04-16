#!/usr/bin/env bash

# Auto-format hook for Claude Code (PostToolUse)
# Each formatter uses `|| true` so failures never block Claude's file writes
set -e

file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

[[ -z "$file" ]] && exit 0
[[ ! -f "$file" ]] && exit 0

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
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.json" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.yml" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.yaml" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.js" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.cjs" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/.prettierrc.mjs" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/prettier.config.js" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/prettier.config.cjs" ]] ||
  [[ -f "$CLAUDE_PROJECT_DIR/prettier.config.mjs" ]]
}

case "$ext" in
  ts|tsx|js|jsx|json|jsonc)
    # No report_errors: pure formatters either fix everything or fail on parse errors (already visible)
    if [[ -f "$CLAUDE_PROJECT_DIR/biome.json" ]] || [[ -f "$CLAUDE_PROJECT_DIR/biome.jsonc" ]]; then
      cd "$CLAUDE_PROJECT_DIR"
      bunx biome check --write "$file" 2>&1 | tail -1 || true
    elif has_prettier_config; then
      cd "$CLAUDE_PROJECT_DIR"
      bunx prettier --write "$file" 2>&1 | tail -1 || true
    fi
    ;;
  css|scss|less|html|vue|svelte|yaml|yml|graphql|gql)
    if has_prettier_config; then
      cd "$CLAUDE_PROJECT_DIR"
      bunx prettier --write "$file" 2>&1 | tail -1 || true
    fi
    ;;
  md)
    cd "$CLAUDE_PROJECT_DIR"

    # --- Step 1: auto-wrap prose to configured line width ---
    md_wrap="$HOME/.claude/md-wrap.py"
    global_config="$HOME/.markdownlint-cli2.yaml"

    # Read the configured line width — prefer project-local config over global
    max_len=120
    if command -v yq &>/dev/null; then
      if [[ -f .markdownlint-cli2.yaml ]]; then
        max_len=$(yq '.config.MD013.line_length // 120' .markdownlint-cli2.yaml)
      elif [[ -f .markdownlint.yaml ]]; then
        max_len=$(yq '.config.MD013.line_length // 120' .markdownlint.yaml)
      elif [[ -f "$global_config" ]]; then
        max_len=$(yq '.config.MD013.line_length // 120' "$global_config")
      fi
    fi

    if [[ -x "$md_wrap" ]]; then
      python3 "$md_wrap" -i -w "$max_len" "$file" 2>/dev/null || true
    fi

    # --- Step 2: run markdownlint ---
    local_config=""
    [[ -f .markdownlint-cli2.yaml ]] && local_config=".markdownlint-cli2.yaml"
    [[ -f .markdownlint.yaml ]] && local_config=".markdownlint.yaml"

    config_args=()
    tmp_config=""
    if [[ -n "$local_config" ]] && command -v yq &>/dev/null; then
      tmp_config="/tmp/.markdownlint-cli2.yaml"
      yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$global_config" "$local_config" > "$tmp_config"
      config_args=(--config "$tmp_config")
    elif [[ -f "$global_config" ]]; then
      config_args=(--config "$global_config")
    fi

    lint_output=$(markdownlint-cli2 "${config_args[@]}" --no-globs --fix "$file" 2>&1) || true

    # Any remaining MD013 violations are unbreakable lines (long URLs, code spans).
    # Tell the agent the limit and that these are acceptable exceptions.
    if [[ "$lint_output" == *"MD013"* ]]; then
      lint_output="${lint_output}
MD013 fix hint: line length limit is ${max_len} characters. Wrap lines to fill up to this limit — do not wrap shorter. Remaining MD013 violations are likely unbreakable tokens (long URLs or inline code) — these are acceptable."
    fi

    [[ -n "$tmp_config" ]] && rm -f "$tmp_config"
    report_errors "$lint_output"
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
  rb)
    if command -v rubocop &>/dev/null; then
      lint_output=$(rubocop -a --format simple "$file" 2>&1) || true
      report_errors "$lint_output"
    fi
    ;;
  yml|yaml)
    if [[ "$file" == *".github/workflows/"* ]] && command -v actionlint &>/dev/null; then
      lint_output=$(actionlint "$file" 2>&1) || true
      report_errors "$lint_output"
    fi
    ;;
esac

exit 0
