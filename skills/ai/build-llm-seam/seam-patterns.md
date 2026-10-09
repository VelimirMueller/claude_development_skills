# LLM Seam Patterns

Reference for [build-llm-seam](./SKILL.md). Canonical code: [llm-seam-ts.md](../_shared/llm-seam-ts.md), [llm-seam-py.md](../_shared/llm-seam-py.md). Principle: [one seam per vendor and per I/O boundary](../../core/_shared/engineering-principles.md).

## Rule: One module owns every model call
**Why:** A model call has a dozen cross-cutting concerns: credentials, timeout, retry, cost, logging, redaction, schema validation, caching. Spread over call sites, each is done differently in each place and fixed in none. One module means one place to change a retry policy and one place to fake in a test.
**How to apply:** `src/platform/llm/` exports `createLlm` and the request and result types. The vendor SDK is imported only inside `adapters/`. Services take `llm` as an argument (composition root, no globals).
**Anti-example:** `new Anthropic()` inside a route handler, with `model: 'claude-opus-5-5'` and a hand-written `try/catch`.

## Rule: Call sites name a tier, never a model id
**Why:** Model ids change on a calendar: new generations, retirements (current ids are committed to run until 2027-09-22 at the earliest), price cuts. A literal id in forty places is forty edits and forty places to forget the eval. Tiers (`quality`, `balanced`, `fast`) say what the task needs; the config says what serves it today.
**How to apply:** `config/llm.models.json` maps tier to `{ model, effort, price }`. The loader validates it with Zod at startup. Changing a model is a PR that touches the JSON and the eval results, nothing else. Ids are exact strings from the models page, with no date suffix. Set `effort` explicitly: the default differs per model (`medium` on Opus 5.5 and Haiku 5.5, `high` on Sonnet 5.5 and Fable 5.1).
**Anti-example:** `model: process.env.MODEL ?? 'claude-opus-5-5'` at the call site: untyped, unvalidated, and still a literal.
**When to deviate:** A per-tenant model choice (a customer who brings their own key and model): make it a tier override in config keyed by tenant, still resolved inside the seam.

## Rule: The SDK is banned outside the seam
**Why:** A convention that asks nicely loses to a deadline. A lint rule makes the wrong import fail the build.
**How to apply:** Biome (checked on 2.5.15):

```json
{
  "linter": { "rules": { "style": { "noRestrictedImports": { "level": "error", "options": { "paths": {
    "@anthropic-ai/sdk": "Call models through src/platform/llm, never the SDK directly.",
    "openai": "Call models through src/platform/llm, never the SDK directly."
  } } } } } },
  "overrides": [{ "includes": ["src/platform/llm/**"], "linter": { "rules": { "style": { "noRestrictedImports": "off" } } } }]
}
```

Ruff (checked): 

```toml
[lint]
extend-select = ["TID251"]
[lint.flake8-tidy-imports.banned-api]
"anthropic".msg = "Call models through app.platform.llm, never the SDK directly."
"openai".msg = "Call models through app.platform.llm, never the SDK directly."
[lint.per-file-ignores]
"src/app/platform/llm/**" = ["TID251"]
```

**When to deviate:** A one-off script in `scripts/` that is not shipped: allow it with a per-file override and a comment.

## Rule: Adapters speak one error taxonomy
**Why:** Retry logic that knows `Anthropic.RateLimitError` cannot serve a second provider. Retry logic that reads a `kind` can.
**How to apply:** Every adapter maps its SDK's errors to `LlmError` with a `kind`: `rate_limit`, `overloaded`, `server`, `timeout`, `connection` (retryable) and `bad_request`, `auth`, `refusal`, `truncated`, `invalid_output` (not). The Anthropic mapping: 429 is `rate_limit`, 529 is `overloaded`, other 5xx is `server`, 401 and 403 are `auth`, other 4xx is `bad_request`, `stop_reason: "refusal"` is `refusal`, `stop_reason: "max_tokens"` is `truncated`. Carry the provider's `retry-after` as `retryAfterMs`. The message never includes prompt or completion text: it ends up in logs.
**Anti-example:** `catch (e) { if (e.message.includes('overloaded')) retry() }`: string matching on provider prose.

## Rule: One deadline, one retry policy, owned by the seam
**Why:** The Anthropic SDK retries by default (2 times). A seam that retries 3 times on top makes up to 9 attempts per call, each with its own timeout: a 60 s timeout becomes minutes of hidden load on an already struggling provider. One owner makes the worst case computable.
**How to apply:** Create the provider client with `maxRetries: 0` and `timeout: <per-attempt>`. The seam wraps the call in `withRetry`: full-jitter exponential backoff (`random(0, min(cap, base * 2^attempt))`), the longer of that and `retry-after`, retry only `retryable` kinds, stop at `maxRetries` or when the caller aborts. The logical call has one deadline of `timeout * (retries + 1)`. Each retry is an event on the span, not a new span.
**Anti-example:** Retrying on `invalid_output` in a loop: it spends money to hit the same wall. If the schema keeps failing, fix the prompt or the schema.
**When to deviate:** Interactive chat: set `maxRetries` to 1 and a short deadline; a spinner for 90 s is worse than an error.

## Rule: Structured output is constrained by the API and validated by you
**Why:** The API constrains generation to a JSON Schema, but its schema language is narrow: no `minimum`, `maximum`, `minLength`, `maxLength`, no recursive schemas, `additionalProperties: false` required. The SDK helper turns unsupported constraints into prose in the description. Prose is a request; only a local `safeParse` against your real Zod or Pydantic model enforces it. A refusal or a `max_tokens` stop can also return text that does not match the schema.
**How to apply:** The caller passes a Zod or Pydantic schema. The adapter sends it (`output_config.format` via `zodOutputFormat`; `output_format=Model` in Python), checks `stop_reason` first, then parses and validates the result locally. A failure is `invalid_output`, with the failing path in the message and no value. Use `output_config.format` for JSON; do not use assistant prefill (400 on current models) or forced `tool_choice` (400 on Opus 5.5, Sonnet 5.5, Fable 5.1). The first request with a new schema pays a one-time grammar compile (cached 24 hours); changing `output_config.format` invalidates the prompt cache for that conversation.
**Anti-example:** `JSON.parse(text) as Summary`: a cast is not a check.

## Rule: Stream user-facing text and large outputs
**Why:** A non-streaming request with a large `max_tokens` can hit HTTP timeouts, and a user waiting on a blank screen reads it as broken.
**How to apply:** The seam exposes `stream(req, onText)` next to `generate`. The adapter streams when a delta callback is set or `maxTokens` is above 16,000, and returns the assembled message (`finalMessage()`, `get_final_message()`). The span covers the whole stream. With a schema, validate once at the end; never parse partial JSON.
**When to deviate:** Background jobs with small outputs: non-streaming is simpler and the provider SDK still enforces the timeout.

## Rule: Cache the stable prefix, and prove it
**Why:** Prompt caching is a prefix match: any changed byte earlier in the prompt invalidates everything after it. Cache reads cost 10% of input price (5% on Opus 5.5 and Sonnet 5.5). The failure is silent: calls succeed and the bill is higher.
**How to apply:** Order the request stable-first: tools, then system prompt, then messages. The prompt loader refuses variables in a `cache: true` prompt, so the system text is byte-identical across calls; variable and untrusted content goes in the user turn. The adapter puts one `cache_control: { type: 'ephemeral' }` breakpoint on the system block. Caches are per model: a tier change starts cold. The minimum cacheable prefix is 512 tokens on the current generation (check the docs: it was 1,024 to 4,096 on older models), and a shorter prefix silently does not cache. Choose the 5-minute TTL when requests sharing the prefix start less than 5 minutes apart; the 1-hour TTL (`ttl: '1h'`, write cost 2x) only pays when the gap is 5 to 60 minutes. Verify with usage: `cache_read_input_tokens` above zero on the second call. Put that check in a test or a dashboard, because a later prompt edit can break it unnoticed.
**Anti-example:** `Current date: ${new Date()}` at the top of the system prompt: a new prefix on every call. Put the date in the user turn.
**When to deviate:** A prompt under the minimum or one used once a day: do not mark it; the write premium buys nothing.

## Rule: Emit `gen_ai.*` spans with tokens, cost and latency
**Why:** You cannot manage what a call costs or how long it takes if the numbers live only in the provider's dashboard. Standard attribute names let any backend (SigNoz, Grafana) chart them.
**How to apply:** One `CLIENT` span per logical call, named `chat <model>`, covering retries and streaming. Attributes (OpenTelemetry GenAI conventions, status Development, verified 2026-10-09): `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.request.max_tokens`, `gen_ai.request.stream`, `gen_ai.prompt.name`, `gen_ai.prompt.version`, `gen_ai.response.model`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_write.input_tokens`, `error.type`. **`gen_ai.usage.input_tokens` includes cached tokens**; Anthropic's `usage.input_tokens` does not, so the adapter adds `cache_read_input_tokens` and `cache_creation_input_tokens` to it. Cost is not in the convention: use `app.llm.cost_usd` on the span and an `app.llm.cost` counter keyed by `app.llm.task`. Latency is the span duration; for streams add `gen_ai.response.time_to_first_chunk` (seconds) when the UX depends on it. Span status carries the error kind only. Keep metric attributes low-cardinality: task names, never user ids.
**Anti-example:** Putting the prompt or the completion in a span attribute. The conventions make message content opt-in for a reason; it is personal data in your trace store. Leave it off; enable it only in a non-production environment with synthetic data.
**When to deviate:** The conventions are in Development status and have renamed metrics between drafts. Pin the attribute names in one file (`telemetry.ts`) so an upgrade is one edit.

## Rule: Prompts are files with a version
**Why:** A prompt is behaviour. A prompt edited inline in a service is a deploy with no diff review and no eval. A file with a version appears in review, in `git blame` and in every span.
**How to apply:** `prompts/<name>.md` with `version` in the frontmatter. Bump it on any change that can alter output; the version goes on every span (`gen_ai.prompt.version`). A prompt change merges only with an eval run ([set-up-llm-evals](../set-up-llm-evals/SKILL.md)). Read the directory from explicit config, never from `import.meta.url` or `__file__`: a bundler or a wheel moves them. Ship `prompts/` and `config/` in the image next to the build output.
**Anti-example:** A template literal with `${userInput}` inside the system prompt: it welds untrusted text to the instructions.

## Rule: Redact personal data before it leaves, and make the policy explicit
**Why:** Whatever you send is stored by the provider for its retention period, and some models require retention (Fable 5.1 is not available under zero data retention). Removing what the task does not need is cheaper than a data-protection incident.
**How to apply:** Every request declares `pii: 'redact' | 'allow'`; the type has no default, so forgetting it does not compile. `redact` replaces emails, IBANs, secrets, phone numbers and Luhn-valid card numbers with placeholders (`[EMAIL_1]`) — in the message contents **and in prompt variables**, which are redacted before substitution into the system prompt on one shared mapping so placeholders never collide — and restores them in the output: a string directly, a structured result field by field, re-validated against its schema. Pattern redaction does **not** find names, street addresses or free-text identifiers. For those, add a named-entity step (a self-hosted NER model, or Presidio) behind the same function, and test it on your own data. A placeholder the model invented (not in the mapping) stays as it is.
**When to deviate:** A task whose input is the personal data (an HR letter rewriter): use `allow`, have the data-processing agreement in place, and say so in the data-flow note.

## Rule: Count before you spend
**Why:** A prompt that grows (retrieved text, history) can cost ten times what the first test did, and a budget check needs the number before the call, not after.
**How to apply:** The price table is in config; the seam computes `costUsd` from usage on every call. `llm.countTokens(req)` returns the input tokens through the provider's own counter (`client.messages.countTokens` for Anthropic; model-specific) on the same redacted text `generate` would send; a worst-case cost is `inputTokens * inputPrice + maxTokens * outputPrice`. Never `tiktoken`: it undercounts Claude tokens (the claude-api reference puts it at 15 to 20% on plain text, more on code). The counter is a network call: use it for budget guards on large inputs, not on every small request.
**Offline work:** Use the Batch API (50% off, results within 24 hours, any order: key by `custom_id`) for evals, backfills and nightly jobs. `runBatch` in `adapters/anthropic-batch.ts` shares the config and validation; never for the PR gate or anything a user waits on.

## Rule: Test with a fake adapter, not a mocked SDK
**Why:** Mocking `messages.create` pins the test to one SDK's call shape. A fake adapter tests the seam's behaviour (redaction, retry, cost, validation) and every service that depends on it, with no network and no key.
**How to apply:** `fakeAdapter([...responses])` records calls and replays responses or errors. Unit tests use it. Evals and the smoke test use the real adapter ([set-up-llm-evals](../set-up-llm-evals/SKILL.md)). A contract test per real adapter checks the error-mapping table above.

## When to deviate

- **Agent loops** (many tool turns): keep the seam for each model call and build the loop in a separate `agent` module on top, or use the SDK's tool runner inside the adapter. The seam rules (config, retry, telemetry) still apply per call.
- **Provider-specific features** (extended server tools, computer use, fast mode, task budgets): add them as optional, neutrally named fields on `AdapterCall`; an adapter that lacks them ignores or rejects them. Do not leak vendor field names into call sites.
- **Throwaway spike:** call the SDK directly in a script outside `src/`; do not merge it into the service.
