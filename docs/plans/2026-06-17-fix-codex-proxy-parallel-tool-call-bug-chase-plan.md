# gbrain dream-patterns "Tool results are missing" bug — root cause and fix

Record of the `Tool results are missing for tool calls call_<id>, ...` failure that dead-lettered every `gbrain dream
--phase patterns` run on the codex stack, and the fix that resolved it.

The chase began as a codex-proxy parallel-tool-call investigation (the filename reflects that origin). codex-proxy
turned out to be uninvolved. The real cause is in gbrain's gateway-native subagent loop. This document states the
resolved truth; the discarded codex-proxy hypotheses are retained at the end so the next investigator does not re-walk
them.

Fix lives in `~/gbrain` on branch `fix/gateway-loop-persist-tool-result-turns` (commit `fix(subagent): persist and
reconcile tool-result turns in the gateway loop`), pushed to `origin`.

---

## 1. Summary

`gbrain dream --phase patterns` submits one subagent per fan-out over the reflection corpus. On the codex stack each
subagent runs gbrain's gateway-native tool loop (`agent.use_gateway_loop=true`) against `litellm:gpt-5.4-mini`. That
loop persisted the assistant tool-call turns but **never persisted the tool-result user turns**, and — unlike the legacy
Anthropic path — had **no crash-replay reconciliation**. Any interruption mid-conversation (worker recycle, rate-lease
renewal, RSS watchdog, abort) left the persisted conversation unbalanced: an assistant turn carrying tool-calls with no
matching tool-results. On the next worker claim the loop fed that unbalanced array straight into `chat()`, the Vercel AI
SDK validator rejected it with `Tool results are missing for tool calls ...`, and because the bad state was already on
disk, every retry rebuilt the same array and failed identically until the job dead-lettered.

The failure scaled with corpus size because more fan-out subagents over a long cycle make at least one mid-conversation
interruption near-certain. Anthropic-stack users never saw it: the legacy Anthropic path persists tool-result turns and
reconciles on replay. codex-proxy was never in the failure path.

---

## 2. The stack (corrected)

Three layers, not four:

- **gbrain** — the Vercel AI SDK consumer. The subagent loop runs through `gateway.toolLoop()`
  (`src/core/ai/gateway.ts`) via `runSubagentViaGateway()` (`src/core/minions/handlers/subagent.ts`), gated on
  `agent.use_gateway_loop=true`.
- **codex-proxy** — `ghcr.io/icebear0828/codex-proxy:latest`, OpenAI-shape endpoint on `127.0.0.1:8080`. Healthy and
  correct throughout.
- **OpenAI Codex** — `gpt-5.x` via the `responses` API.

There is no litellm sidecar. The gbrain `litellm` recipe (`src/core/ai/recipes/litellm-proxy.ts`) is the generic
openai-compatible template; `LITELLM_BASE_URL` resolves to codex-proxy's OpenAI endpoint (`http://127.0.0.1:8080/v1`,
exported from `~/dotfiles/config/shell/litellm.sh`). The patterns subagent reaches codex-proxy because the patterns
phase dropped its `ANTHROPIC_API_KEY` gate (there is no Anthropic key on the dev host, so the gateway loop is the only
path).

---

## 3. Root cause (proven)

`gateway.toolLoop()` drives the assistant → tool-dispatch → tool-result cycle and exposes persistence callbacks so the
subagent handler can record each step for crash-replay:

- `onAssistantTurn` — persists the assistant turn (tool-calls included) before any tool runs.
- `onToolCallStart` / `onToolCallComplete` / `onToolCallFailed` — persist each tool execution row in
  `subagent_tool_executions`.

The loop built the tool-result user turn and pushed it onto the in-memory `messages` array, but **discarded its message
index and never persisted it** — the literal `void userMessageIdx` in `toolLoop`, and no tool-result callback wired in
`runSubagentViaGateway`. So `subagent_messages` accumulated assistant tool-call turns with no interleaved tool-result
turns.

On replay, `loadPriorMessages()` reconstructs the conversation from `subagent_messages` and the loop sets `messages =
[...priorMessages]`. With the tool-result turns missing, that array ends with an assistant turn whose tool-calls are
unanswered. The legacy Anthropic path guards exactly this case (`subagent.ts` reconciliation block): it re-synthesizes
the tool-result turn from the persisted executions before continuing. The gateway path had no equivalent, so it called
`chat()` with the unbalanced array and the AI SDK threw `Tool results are missing for tool calls call_<id>, ...`.

The error is poison, not transient: once an interrupted job's unbalanced state is on disk, every retry rebuilds the same
array and throws the same error, so the job exhausts its attempts and dies. The three dead subagent jobs observed on the
dev host (`Invalid prompt: The messages do not match the ModelMessage[] schema` on the first attempt, then `Tool results
are missing for tool calls call_8All..., call_uLo1...` on the retries) are this exact mechanism.

---

## 4. How codex-proxy was exonerated

Four independent results, none of which implicate the proxy:

1. **Minimal repro against the real transport.** `repro.mjs` (section 8) drives non-streaming `generateText` against
   codex-proxy at `127.0.0.1:8080/v1` — gbrain's exact transport. A single tool call, two forced-parallel tool calls,
   and four forced-parallel tool calls all round-trip cleanly: distinct `call_<id>` values, complete arguments per call,
   matched tool results, clean final answer. Verified on both `gpt-5.5` and `gpt-5.4-mini`.
2. **Message conversion is correct.** `toModelMessages()` converts a balanced multi-tool conversation into a valid AI
   SDK v6 `ModelMessage[]` — the assistant tool-calls followed by a single `role: 'tool'` message carrying both results
   with structured `{ type, value }` outputs. The conversion is not the bug.
3. **The dead-job error reproduces with no proxy involved.** Feeding gbrain's own `chat()` an unbalanced conversation
   (`[user, assistant(2 tool-calls)]` with no tool-result turn) throws the identical `Tool results are missing for tool
   calls call_1, call_2` — the precise shape of the production failure, produced entirely inside gbrain.
4. **The one real codex-proxy hazard is on a path gbrain never uses.** `codex-to-openai.ts` keys tool-call argument
   deltas inconsistently (`functionCallStart` registers the index under `item.call_id`; `functionCallDelta`/`Done`
   resolve it under `call_id ?? item_id` with a `?? 0` fallback), which could collapse parallel-call arguments onto
   index 0 in the **streaming** translation. gbrain uses non-streaming `generateText`, so that path is never exercised.
   It remains a latent upstream bug for streaming clients, unrelated to this failure.

---

## 5. The fix

Mirror what the legacy Anthropic path already does.

`~/gbrain`, branch `fix/gateway-loop-persist-tool-result-turns`:

- `src/core/ai/gateway.ts` — add an `onToolResultTurn(turnIdx, messageIdx, blocks)` callback to `ToolLoopOpts` and
  invoke it where the tool-result user turn is built (replacing `void userMessageIdx`), so the caller persists the turn
  before the next dispatch.
- `src/core/minions/handlers/subagent.ts` —
- wire `onToolResultTurn` to `persistMessage(role: 'user', ...)`, making `subagent_messages` symmetric with the
    assistant-turn writes;
- add replay reconciliation before the loop: when prior messages end with an assistant turn carrying unanswered
    tool-calls, re-synthesize the tool-result turn from the settled `subagent_tool_executions` rows (keyed by provider
    `tool_use_id`), persist and append it. If any tool is still unsettled, bail rather than fabricate a result, so a
    non-idempotent tool is never re-run.
- `test/e2e/subagent-gateway-toolresult-replay.test.ts` — new regression test (section 6).

Properties: additive, gated behind the existing `agent.use_gateway_loop`, and faithful to real tool outputs (no risk of
mining patterns from dropped or garbled tool results). The persist (going-forward completeness) and the reconciliation
(closes the crash window between the assistant-turn persist and the tool-result persist, and recovers already-poisoned
jobs whose tools all settled) together make the loop crash-safe.

---

## 6. Why the test suite missed it

The existing crash-replay suite (`test/e2e/subagent-crash-replay-multi-provider.test.ts`) stubs the chat transport
(`__setChatTransportForTests`), so the real AI SDK validator never runs and an unbalanced `messages` array is never
rejected. The suite verifies that prior tools are not re-executed on replay, but never that the reconstructed
conversation is structurally balanced — the exact property the production validator enforces. The bug lived in that
blind spot.

The new test captures what the loop hands `chat()` on resume and asserts the conversation is balanced (every assistant
tool-call answered by a matching tool-result), and that the reconciled tool-result turn is persisted to
`subagent_messages`. It fails without the fix and passes with it.

---

## 7. Verification and remaining work

Done:

- The targeted subagent / gateway / tool-loop test surface passes (the only unrelated failure is a stray ELF
  `src/cli.ts` in the working tree shadowing the source; `git restore src/cli.ts` fixes it).
- The new regression test is proven to fail without the fix and pass with it.

Remaining (operational, owned by the operator):

1. Merge `fix/gateway-loop-persist-tool-result-turns` into `personal` (and/or PR to `master`).
2. Restart the Minions worker so the running daemon picks up the new code.
3. Re-submit the dead subagent jobs (923–925), or let the next cycle re-run.
4. Optional end-to-end confirmation: a real `gbrain dream --phase patterns` at corpus scale completes with balanced
   `subagent_messages` and no dead subagent jobs. The deterministic regression test already proves the mechanism; the
   e2e is confidence over real Codex spend.

---

## 8. Reproduction scaffolding (reference)

Kept under `~/.gstack/projects/brettdavies-gbrain/dream-patterns-codex-proxy/` so the next regression starts from the
same scaffold.

`repro.mjs` — minimal client that drives non-streaming `generateText` directly at codex-proxy. Run knobs:

```bash
cd ~/.gstack/projects/brettdavies-gbrain/dream-patterns-codex-proxy
MODEL=gpt-5.5 PROMPT=single        node repro.mjs   # one tool call (control)
MODEL=gpt-5.5 PROMPT=parallel      node repro.mjs   # two forced-parallel calls
MODEL=gpt-5.4-mini PROMPT=four-parallel node repro.mjs
```

It symlinks `node_modules` to `~/gbrain/node_modules` so the `ai` package under test is gbrain's pinned version (the
validator behavior is version-specific). It logs the on-wire request and the raw codex-proxy response, and prints each
assistant turn's tool-call ids + arguments. All shapes pass — this is the evidence the proxy is healthy for parallel
tool calls.

The decisive gbrain-side reproduction (the dead-job error with no proxy in the path) drives gbrain's own `chat()` after
`configureGateway()` with an unbalanced `[user, assistant(2 tool-calls)]` conversation; it throws `Tool results are
missing for tool calls call_1, call_2`.

codex-proxy upstream source (TypeScript, not brettdavies-owned) lives at https://github.com/icebear0828/codex-proxy. The
local `~/dev/tools/codex-proxy/` directory is compose-only (no source checkout). No fork or image rebuild was needed.

---

## 9. Discarded hypotheses (do not re-walk)

All disproven during the chase:

- **codex-proxy collides or drops `tool_call` ids under parallel calls.** Refuted: 2 and 4 parallel calls round-trip
  cleanly through the non-streaming path on both models. The streaming index-key hazard in `codex-to-openai.ts` is real
  but on a path gbrain never uses.
- **litellm `drop_params` strips a request field.** Dead: there is no litellm in the stack.
- **gbrain appends `tool_use_id` instead of `tool_call_id`.** Refuted: `toModelMessages()` maps the internal
  `tool_use_id` to the AI SDK `toolCallId` before dispatch.
- **Codex returns a partial set of parallel `function_call` items under load** / **codex-proxy times out between
  parallel calls.** Not reached: the failure reproduces deterministically inside gbrain from persisted state,
  independent of any live Codex response.

---

## 10. Superseded approach

The original plan proposed a gbrain `chat.parallel_tool_calls` config knob plus a codex-proxy fork and image rebuild.
Both are moot. Parallel tool calls work through codex-proxy; the failure was gbrain-side persistence, not provider
behavior. No knob, no fork, no rebuild — the fix is the persistence-and-reconciliation symmetry in section 5.
