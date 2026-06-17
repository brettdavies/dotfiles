# codex-proxy / litellm parallel-tool-call bug chase plan

Working file for the `Tool results are missing for tool calls call_<id>, ...` failure that lands on every `gbrain dream
--phase patterns` run when the chat stack routes through `gbrain -> litellm -> codex-proxy -> OpenAI Codex (gpt-5.x)`.

Plan owner: `personal` branch on `~/gbrain`. Upstream PRs (if any) cut from clean `feat/...` branches against
`brettdavies/gbrain master`. Any fix that touches `~/dev/tools/codex-proxy/` is upstream to `icebear0828/codex-proxy`
and ships locally via a fork+rebuild of the docker image (image: `ghcr.io/icebear0828/codex-proxy:latest`).

---

## 1. Scope and exit criteria

In scope:

- The chat completion path used by `gbrain dream --phase patterns` only. The subagent loop runs the Vercel AI SDK
  `generateText` against the litellm-proxy recipe (`src/core/ai/recipes/litellm-proxy.ts`, `implementation:
  'openai-compatible'`).
- The four-layer call chain: gbrain (AI SDK) -> litellm (BerriAI OSS proxy) -> codex-proxy
  (`ghcr.io/icebear0828/codex-proxy:latest`) -> OpenAI Codex (`gpt-5.x`).
- Reflection corpus sized 500+ rows (the size at which the failure became deterministic on the dev host).

Out of scope:

- The embed path (handled by `embedMultimodal*`, never hits chat completions).
- The Anthropic-direct recipe (`anthropic`), the Bedrock recipe, and the Groq recipe (none route through codex-proxy).
- gbrain's `extract`, `query`, `volunteer_context` paths that do not request tools.

Exit criteria (all four must hold before this plan closes):

1. `gbrain dream --phase patterns` against a 500-row reflection corpus on the dev host completes with `status: ok` for
   ten consecutive runs.
2. The `messages` array persisted to `subagent_tools` / `messages` is structurally balanced: every assistant `tool_use`
   block has a matching `tool` message with the same `tool_call_id` immediately following.
3. The fix lives behind a config knob (`chat.parallel_tool_calls`) so reflective rollback is one config write away.
4. The diagnosis is reproducible from a minimal Node script committed to `~/.gstack/projects/brettdavies-gbrain/` under
   the chase folder so the next regression starts from the same scaffold.

---

## 2. Current state of each layer

### 2.1 gbrain (AI SDK consumer, `~/gbrain`)

- Chat dispatch lives in `src/core/ai/gateway.ts` around the `chat()` function. The subagent loop calls it inside
  `src/core/minions/handlers/subagent.ts`.
- `toModelMessages()` in `gateway.ts` rebuilds the `messages` array into the Vercel AI SDK shape before each hop.
  `tool_use` blocks come back from the model as `assistant.content[*].type === 'tool_use'`; the loop appends a `tool`
  message per `tool_use_id` and re-dispatches.
- The error text `Tool results are missing for tool calls: ...` lives in
  `node_modules/ai/docs/09-troubleshooting/21-missing-tool-results-error.mdx` and is thrown by the AI SDK validator when
  it detects an assistant turn carrying `tool_use` blocks whose ids are not all covered by subsequent `tool` messages.
- `parallel_tool_calls` is not currently surfaced anywhere in gbrain. The OpenAI-compatible request is built with
  whatever the AI SDK's default is (truthy for OpenAI-shape providers).
- Capability metadata (`src/core/ai/capabilities.ts`) declares the litellm recipe as supporting parallel tool use; in
  practice we have not verified that codex-proxy honors that promise.

### 2.2 litellm (BerriAI OSS, https://github.com/BerriAI/litellm)

- Local install runs as a sidecar; gbrain reaches it via `LITELLM_BASE_URL`. The setup hint in `litellm-proxy.ts`
  documents the `/v1` suffix requirement when fronting OpenAI-shaped upstreams (this is codex-proxy's shape).
- litellm normalizes the request shape to OpenAI `chat/completions` and pipes the upstream response back through. It
  does NOT (by default) rewrite `tool_calls` -> `tool_use`, drop ids, or coalesce parallel calls. It will, however, drop
  unknown fields and translate Anthropic-shape responses into OpenAI-shape if the upstream returns Anthropic JSON.
- litellm has a `drop_params: true` mode that silently strips request fields the upstream rejects; if a fresh install
  has that on, `parallel_tool_calls: false` from gbrain could be eaten before it reaches codex-proxy.

### 2.3 codex-proxy (upstream `icebear0828/codex-proxy`, not brettdavies-owned)

- Local docker-compose at `~/dev/tools/codex-proxy/docker-compose.yml` pulls `ghcr.io/icebear0828/codex-proxy:latest`.
  The compose file binds `127.0.0.1:8080:8080` for the OpenAI-shape endpoint and `1455:1455` for an auxiliary port.
- The proxy translates OpenAI `chat/completions` requests into Codex (`responses` API) calls and translates the Codex
  response back into OpenAI shape. The Codex API does not natively present `parallel_tool_calls`; the proxy is the only
  thing in the stack that knows whether multiple `tool_call` blocks in one assistant message are safe.
- We do not own this code. Source lives at https://github.com/icebear0828/codex-proxy. Fix paths are: (a) open a PR
  upstream, (b) maintain a local fork with the docker image rebuilt from `./Dockerfile` (the compose file already has a
  commented-out `build: .` block that swaps the image for a local build).
- Suspected behavior under parallel tool calls: the proxy emits multiple `tool_call` blocks in one assistant turn but
  reuses or drops ids during the Codex round trip, so the client cannot match `tool` responses back to the original ids.
  The AI SDK then refuses the next dispatch.

### 2.4 OpenAI Codex (gpt-5.x via the `responses` API)

- Codex `responses` is a tool-call-shaped API, not the legacy `chat/completions` shape. Each turn returns `output[*]`
  items with `type: 'function_call'` carrying a `call_id`. Parallel calls are returned as multiple items in one
  response.
- Codex `call_id` values are stable per response. If codex-proxy maps them straight through to OpenAI
  `tool_calls[*].id`, parallel calls survive. If codex-proxy generates fresh ids per round trip, parallelism breaks.

---

## 3. Ranked hypotheses

H1 (highest prior). codex-proxy reuses or collides `tool_call.id` values when the Codex response carries more than one
parallel `function_call`. The AI SDK can match the first `tool` response but not the rest, so it throws on the next
dispatch. Supporting evidence: failure only fires under `--phase patterns`, which is the only phase that fans out
parallel tool calls; failure rate scales with corpus size (more reflections per turn == more parallel calls per turn).

H2. codex-proxy emits OpenAI-shape `tool_calls[*].id` correctly, but its streaming SSE frames split a single tool call
across multiple `delta` chunks and the id is only present on the first chunk. litellm or the AI SDK sees a `tool_call`
with a missing or empty id and silently drops it from the assistant message; the next dispatch lacks the `tool` response
for the id the client did not retain.

H3. litellm's `drop_params: true` strips a `parallel_tool_calls: false` from gbrain's request even though gbrain has not
set it. Less likely but worth ruling out: the AI SDK may add it on its own when the model id matches a known OpenAI
shape.

H4. The AI SDK throws because the `tool` messages we append carry the `tool_use_id` field name instead of
`tool_call_id`. gbrain's persistence layer uses `tool_use_id` everywhere (Anthropic-native naming); the AI SDK mapping
for OpenAI shape expects `tool_call_id`. This would fail on every turn, not only `patterns`, so the hypothesis is
unlikely to be the root cause but may compound the failure if H1 is partially true.

H5. Codex `responses` API rate-limits parallel `function_call` execution at the upstream and returns a partial response
(one `function_call` instead of N) under load. codex-proxy faithfully relays the partial; gbrain sees the original N
tool_use ids in its persisted history but only N-1 in the current response, fails the validator on the NEXT turn because
the assistant message it persisted on disk is the older N-call version.

H6. Wall-clock skew: codex-proxy times out the Codex request between parallel calls and emits an HTTP 200 with a
malformed assistant message. The proxy sets a soft deadline of 60s and Codex `gpt-5.5` blows through it on the patterns
phase.

---

## 4. Minimal repro script

Goal: drive the four-layer stack from a tight Node script that requests two parallel tool calls and inspects the on-wire
payloads at every hop. Lives at `~/.gstack/projects/brettdavies-gbrain/dream-patterns-codex-proxy/repro.mjs`.

```js
// repro.mjs - reproduces the parallel-tool-call failure against the local
// litellm -> codex-proxy -> Codex stack.
import { generateText, tool } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { z } from 'zod';

const provider = createOpenAICompatible({
  name: 'litellm',
  baseURL: process.env.LITELLM_BASE_URL ?? 'http://127.0.0.1:4000/v1',
  apiKey: process.env.LITELLM_API_KEY ?? 'sk-local',
});

const model = provider(process.env.MODEL ?? 'gpt-5.4-mini');

const result = await generateText({
  model,
  messages: [
    {
      role: 'system',
      content:
        'You always call BOTH lookup_a and lookup_b in parallel before you answer. ' +
        'Do not answer until both tools have responded.',
    },
    { role: 'user', content: 'Compare A and B and tell me which wins.' },
  ],
  tools: {
    lookup_a: tool({
      description: 'fetch facts about A',
      inputSchema: z.object({ topic: z.string() }),
      execute: async () => ({ result: 'A facts' }),
    }),
    lookup_b: tool({
      description: 'fetch facts about B',
      inputSchema: z.object({ topic: z.string() }),
      execute: async () => ({ result: 'B facts' }),
    }),
  },
  maxRetries: 0,
  // Toggle to test the gbrain-side fix:
  // experimental_providerMetadata: { openai: { parallel_tool_calls: false } },
});

console.log(JSON.stringify({ steps: result.steps, response: result.response }, null, 2));
```

Run knobs:

```bash
cd ~/.gstack/projects/brettdavies-gbrain/dream-patterns-codex-proxy
LITELLM_BASE_URL=http://127.0.0.1:4000/v1 LITELLM_API_KEY=sk-local MODEL=gpt-5.4-mini node repro.mjs
```

The script is the smallest possible client that can reproduce the failure. Iterate on it before touching the real gbrain
build.

---

## 5. Per-layer isolation tests

The goal is to localize the bug to one layer by capturing the on-wire JSON between every adjacent pair.

### 5.1 Between gbrain and litellm

`mitmproxy` runs in front of litellm. Reconfigure gbrain to send chat to the mitmproxy listen port and let mitmproxy
reverse-proxy to litellm.

```bash
mitmweb --mode reverse:http://127.0.0.1:4000 --listen-host 127.0.0.1 --listen-port 14000 --web-port 18081
LITELLM_BASE_URL=http://127.0.0.1:14000/v1 node repro.mjs
```

Inspect the captured request body for `tools[]`, `tool_choice`, and `parallel_tool_calls`. Inspect the captured response
body for `choices[0].message.tool_calls[]` and confirm every id is non-empty and unique.

### 5.2 Between litellm and codex-proxy

`mitmdump` is more useful here because we want machine-readable JSON for diff'ing against the previous capture.

```bash
mitmdump --mode reverse:http://127.0.0.1:8080 --listen-host 127.0.0.1 --listen-port 14080 \
  --set save_stream_file=~/.gstack/projects/brettdavies-gbrain/dream-patterns-codex-proxy/litellm-out.mitm
```

Then point litellm at the mitmdump port instead of codex-proxy:8080. The litellm config edit is one line:

```yaml
# ~/.config/litellm/config.yaml (or wherever your install reads from)
model_list:
  - model_name: gpt-5.4-mini
    litellm_params:
      model: openai/gpt-5.4-mini
      api_base: http://127.0.0.1:14080/v1
      api_key: sk-local
```

Diff the request body captured in 5.1 against the request body captured here. Anything missing was eaten by litellm.
Same exercise on the response. This is where H3 lives or dies.

### 5.3 Between codex-proxy and OpenAI Codex

codex-proxy talks TLS to OpenAI. `mitmproxy` can do TLS but the proxy has to trust mitmproxy's CA. The faster diagnostic
is `tcpdump` plus `sslkeylogfile` on codex-proxy. Inside the codex-proxy container, set
`SSLKEYLOGFILE=/app/data/sslkeys.log` (it picks up the env automatically if the upstream HTTP client honors it; node
does via `--use-system-ca` + a wrapper).

If the upstream client does not honor `SSLKEYLOGFILE`, fall back to swapping `codex_api_base` (in codex-proxy config) to
point at a local mitmproxy in reverse mode trusted via a CA mounted into the container:

```bash
mitmdump --mode reverse:https://api.openai.com --listen-host 0.0.0.0 --listen-port 14443 \
  --set ssl_insecure=true
```

Mount the proxy CA into `/app/config/mitm-ca.pem` and set `NODE_EXTRA_CA_CERTS=/app/config/mitm-ca.pem` in the
codex-proxy compose `environment` block. Edit `~/dev/tools/codex-proxy/config/` to swap `codex_api_base` to
`http://host.docker.internal:14443/v1`. Capture every request/response pair codex-proxy makes to Codex.

Confirm whether the Codex `responses` payload contains parallel `function_call` items with distinct `call_id` values,
and whether codex-proxy maps each to a distinct `tool_calls[*].id` in its OpenAI-shape response.

### 5.4 Stack-wide tcpdump fallback

If mitm-injection is too disruptive, fall back to plain pcap capture on the loopback interface and offline analysis:

```bash
sudo tcpdump -i lo -s 0 -w /tmp/codex-stack.pcap 'tcp port 4000 or tcp port 8080'
```

Wireshark can decode the HTTP/1.1 bodies offline. This works on the gbrain<->litellm and litellm<->codex-proxy hops; the
codex-proxy<->Codex hop is TLS and pcap-only is useless without keys.

---

## 6. Per-layer fix paths

### 6.1 gbrain-side knob (`chat.parallel_tool_calls`)

Most reversible fix. Add a config key that flows through `gateway.ts` into the OpenAI-compatible request body as
`parallel_tool_calls: false`. Default value: `true` (preserve current behavior); the litellm recipe sets it to `false`
for the chat touchpoint when the upstream is detected as codex-proxy.

Touch list:

- `src/core/config.ts` -- add `chat.parallel_tool_calls` to the keychain and the merge logic.
- `src/core/ai/types.ts` -- add the field to `ChatOptions` (or the request-shape interface that `chat()` forwards).
- `src/core/ai/gateway.ts` -- thread it into the `generateText` call so the AI SDK forwards it as a provider option for
  openai-compatible.
- `src/core/ai/recipes/litellm-proxy.ts` -- set the recipe-level default to `false` until the codex-proxy bug is fixed
  upstream.
- `src/commands/providers.ts` -- expose the knob via `gbrain providers set chat.parallel_tool_calls false`.
- `test/ai/gateway-parallel-tool-calls.test.ts` -- new unit test that mocks the OpenAI-compatible client and asserts the
  field rides on the request body when the knob is set.

### 6.2 Sequential-prompt fallback in the subagent loop

If H1 holds and codex-proxy cannot be patched upstream quickly, gbrain can rewrite the system prompt during the
`patterns` phase to instruct the model to call tools one at a time, and additionally trim the assistant turn before the
next dispatch so any orphan `tool_use` block past the first is discarded with a synthetic `tool` response.

Touch list:

- `src/core/cycle/patterns.ts` -- gate the multi-tool prompt behind the parallel knob.
- `src/core/minions/handlers/subagent.ts` -- in the replay path, if the persisted assistant message has more `tool_use`
  blocks than the messages array has matching `tool` responses, synthesize a `tool` message with `result: { error:
  'parallel_tool_call_dropped', reason: 'codex-proxy-bug-#NNN' }` for each orphan id and log a counter so the regression
  shows up in the brain stats.
- Eval: `test/dream/patterns-codex-proxy-fallback.test.ts` confirms the synth-tool path keeps the dispatch alive without
  contaminating downstream pattern aggregation.

### 6.3 Upstream codex-proxy PR or local-fork rebuild

If the captures from section 5 prove codex-proxy is the culprit:

- Open an issue at https://github.com/icebear0828/codex-proxy with the pcap excerpt and a synthetic-reproducer request
  body. Title: `parallel tool_call ids collide on Codex responses-API translation`. Reference this plan's diagnosis.
- If the upstream timeline is unclear, fork to `brettdavies/codex-proxy`, apply the fix on a
  `fix/parallel-tool-call-id-mapping` branch, push, and rebuild the local image:

```bash
cd ~/dev/tools/codex-proxy
git clone https://github.com/brettdavies/codex-proxy.git src
# Edit docker-compose.yml: comment 'image: ghcr.io/icebear0828/codex-proxy:latest', uncomment 'build: ./src'
docker compose build --no-cache codex-proxy
docker compose up -d codex-proxy
```

The compose file already documents the `build: .` swap; we point `build:` at the fork checkout.

The fix shape inside codex-proxy is one of: (a) propagate Codex `call_id` straight through to OpenAI `tool_calls[*].id`
instead of generating fresh ids, (b) buffer the SSE stream until every tool-call id is complete before emitting, (c)
when the proxy decides it cannot preserve parallelism, return `parallel_tool_calls: false` semantics by serializing the
calls into separate assistant turns.

### 6.4 litellm-side mitigation

Lowest-priority. If captures show litellm dropping fields, set `drop_params: false` in its config:

```yaml
# ~/.config/litellm/config.yaml
litellm_settings:
  drop_params: false
  set_verbose: true
```

Restart litellm and re-run the repro. This rules out H3.

---

## 7. Verification

Two corpora, in order:

### 7.1 Canary (smallest possible)

```bash
gbrain dream --phase patterns --limit 5 --canary
```

Five reflections, no fan-out, fast enough to run on every iteration of the fix loop. Pass = clean exit + no `Tool
results are missing` in stderr.

### 7.2 500-reflection corpus

```bash
gbrain dream --phase patterns --limit 500
```

This is the size at which the failure became deterministic. Pass criteria:

- Ten consecutive runs with `status: ok`.
- Zero `parallel_tool_call_dropped` synth-tool entries in the persisted messages (i.e. the upstream fix worked, not just
  the fallback).
- `subagent_tools` table shows every `tool_use_id` matched by exactly one `tool` row per job.

### 7.3 Brain integrity gate

After both corpora pass, run:

```bash
gbrain doctor
gbrain check-backlinks --since "$(date -I -d '-2 days')"
```

These catch the case where the synth-tool fallback masked a real failure and pattern aggregation silently dropped
reflections.

---

## 8. Risks and rollback

- Risk: setting `parallel_tool_calls: false` slows the patterns phase by 1.5-2x because tool calls serialize.
  Mitigation: a knob, not a hard-coded constant. Roll back via `gbrain providers set chat.parallel_tool_calls true`.
- Risk: forked codex-proxy image drifts from upstream. Mitigation: stamp the image with the upstream commit SHA it
  forked from (`docker compose build --build-arg UPSTREAM_SHA=<sha>`) and check the upstream issue weekly; collapse the
  fork when the upstream PR lands.
- Risk: the synth-tool fallback in section 6.2 hides a genuine model failure (e.g. Codex returned an error the proxy
  swallowed). Mitigation: increment a brain stat counter every time the fallback fires; alert if it fires more than 1%
  of patterns turns over a 24h window.
- Risk: mitmproxy CA mounted into codex-proxy container outlives the chase and weakens TLS on the host. Mitigation:
  dedicated config dir (`~/dev/tools/codex-proxy/config-mitm/`) bind-mounted only during the chase; tear down via
  `docker compose down && rm -rf config-mitm/`.
- Risk: the AI SDK adds `parallel_tool_calls: true` on its own and gbrain's `false` is overridden. Mitigation: capture
  in 5.1 confirms the on-wire value; if overridden, drop down to the provider-options escape hatch
  (`experimental_providerMetadata.openai.parallel_tool_calls = false`).

---

## 9. File touch list (repo-relative paths)

`~/gbrain` (`personal` branch first, `feat/chat-parallel-tool-call-knob` for upstream PR):

- `src/core/config.ts` -- add the keychain entry, db column read, merge logic.
- `src/core/ai/types.ts` -- thread `parallel_tool_calls?: boolean` into `ChatOptions`.
- `src/core/ai/gateway.ts` -- forward into `generateText` provider options.
- `src/core/ai/recipes/litellm-proxy.ts` -- recipe-level default of `false` for the chat touchpoint until upstream
  codex-proxy fix lands; document the inversion.
- `src/core/cycle/patterns.ts` -- gate parallel-tool prompt on the knob.
- `src/core/minions/handlers/subagent.ts` -- synth-tool fallback for orphan `tool_use` ids; new counter.
- `src/commands/providers.ts` -- surface the knob in `gbrain providers set`.
- `test/ai/gateway-parallel-tool-calls.test.ts` -- new unit test.
- `test/dream/patterns-codex-proxy-fallback.test.ts` -- new unit test for the synth-tool fallback.
- `docs/guides/litellm-proxy.md` -- document the codex-proxy gotcha and the knob.
- `CHANGELOG.md` -- entry under the next release.

`~/dev/tools/codex-proxy/` (compose-side):

- `docker-compose.yml` -- swap to `build: ./src` when the fork is active.
- `config/` -- any proxy-side config required by the fix (e.g. a `preserve_call_ids: true` flag if the upstream PR
  introduces one).

`~/dev/codex-proxy-fork/` (if we fork):

- The fork's translation layer (path TBD until we read the upstream source) -- the actual id-mapping fix.

`~/.gstack/projects/brettdavies-gbrain/dream-patterns-codex-proxy/`:

- `repro.mjs` -- the minimal repro from section 4.
- `litellm-out.mitm`, `codex-out.mitm` -- captured streams from section 5.
- `pre-fix-fail.log`, `post-fix-pass.log` -- canary outputs bracketing the fix.

---

## 10. Six concrete test scenarios

Each scenario is a single repro command plus the pass/fail signal. Run all six before declaring the chase closed.

S1. **Single tool, single call.** Bench: the bug should not fire here regardless of fix.

```bash
LITELLM_BASE_URL=http://127.0.0.1:4000/v1 MODEL=gpt-5.4-mini PROMPT=single node repro.mjs
```

Pass = clean exit, one assistant turn with one `tool_use` and one matching `tool` response.

S2. **Two tools, forced parallel, no fix.** This is the headline reproducer.

```bash
LITELLM_BASE_URL=http://127.0.0.1:4000/v1 MODEL=gpt-5.4-mini PROMPT=parallel node repro.mjs
```

Pass (pre-fix) = throws `Tool results are missing`. Pass (post-fix) = clean exit, two `tool` responses, each with a
distinct `tool_call_id`.

S3. **Two tools, forced parallel, `parallel_tool_calls: false`.** Validates the gbrain-side knob.

```bash
LITELLM_BASE_URL=http://127.0.0.1:4000/v1 MODEL=gpt-5.4-mini PROMPT=parallel \
  PARALLEL_TOOL_CALLS=false node repro.mjs
```

Pass = clean exit, two assistant turns (one tool call each), no orphan ids.

S4. **Four tools, forced parallel, fork build active.** Stresses the codex-proxy id-mapping fix.

```bash
LITELLM_BASE_URL=http://127.0.0.1:4000/v1 MODEL=gpt-5.4-mini PROMPT=four-parallel node repro.mjs
```

Pass = clean exit, four distinct `tool_call_id` values, four matching `tool` responses, all ids end-to-end identical to
the Codex `call_id` values captured in the codex-proxy<->Codex pcap.

S5. **Canary patterns run.**

```bash
gbrain dream --phase patterns --limit 5 --canary
```

Pass = `status: ok`, persisted messages structurally balanced.

S6. **500-reflection patterns run, ten consecutive.**

```bash
for i in $(seq 1 10); do
  gbrain dream --phase patterns --limit 500 || { echo "FAIL on run $i"; break; }
done
```

Pass = ten clean runs, no `parallel_tool_call_dropped` counter increments, `subagent_tools` balanced for every job.

---

## 11. Sequencing

1. Stand up the repro script (section 4) and confirm the failure fires on S2 without touching gbrain.
2. Run captures 5.1 and 5.2 to localize: if the request body to codex-proxy already carries duplicate or missing ids,
   the bug is gbrain or litellm; otherwise the bug is downstream.
3. Run capture 5.3 to confirm Codex returns clean `call_id` values and codex-proxy mangles them on the way back.
4. Ship the gbrain-side knob (section 6.1) and exercise S3 to confirm the bug is dodgeable.
5. File the upstream codex-proxy issue with the captures attached. Open the fork in parallel.
6. Rebuild the local image from the fork (section 6.3) and exercise S4.
7. Run S5, then S6.
8. Land the gbrain knob on `personal` first, then cut a clean `feat/` branch for upstream PR if the fix is generally
   useful (the knob almost certainly is; the recipe default of `false` is debatable and may stay `personal`-only until
   the upstream codex-proxy fix lands).
9. Close task #15.

---

## 12. Open questions

- Does the AI SDK forward `parallel_tool_calls` for the `openai-compatible` provider, or only for the native `openai`
  provider? If only the latter, we need the `experimental_providerMetadata.openai` escape hatch or a custom request-body
  interceptor. Confirm in capture 5.1.
- Does the Codex `responses` API guarantee `call_id` uniqueness across the lifetime of one client session, or only
  within a single response? If only the latter, codex-proxy is forced to namespace ids and the fix shape changes.
- Does `gpt-5.5` differ from `gpt-5.4-mini` in how often it emits parallel tool calls? If yes, the failure rate per
  corpus row is model-dependent and the 500-row threshold is not the right gate -- use a tool-call count instead.
- Is there a litellm-side translation hook we can register to fix the ids without forking codex-proxy? Unlikely (litellm
  trusts its upstream's tool_calls), but worth a search before forking.
- Does icebear0828 accept PRs at a reasonable cadence? Check the repo's PR history before betting the chase on an
  upstream merge.
