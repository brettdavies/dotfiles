# shellcheck shell=bash
# LiteLLM / OpenAI-compat proxy endpoints.
#
# Routes paid LLM traffic through a local proxy that translates between
# OpenAI-compat client calls and a backend that bills against a non-API
# credit pool (e.g. codex-proxy → corp ChatGPT Codex credits).
#
# `.profile` sources this file before `~/.secrets` and before the Homebrew
# PATH block. URLs only — the bearer key lives in `~/.secrets` (loaded after
# Homebrew so `op` is on PATH for the 1Password lookup).
#
# Codex-proxy quirk: serves OpenAI-style `/v1/...` paths. Vanilla LiteLLM
# serves bare `/chat/completions` — drop the `/v1` suffix if pointing at one.
export LITELLM_BASE_URL="http://localhost:8080/v1"

# Legacy Claude-Code-via-LiteLLM stubs kept for reference; not active.
# export ANTHROPIC_BASE_URL="http://localhost:4000"
# export ANTHROPIC_API_KEY="sk-mlx-local-12345"
# export ANTHROPIC_MODEL="qwen-1.7b"
