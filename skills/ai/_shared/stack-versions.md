# Stack Versions (ai)

Verified lines for the AI toolchain, checked **2026-10-09**. Re-verify before scaffolding; this is a floor, not a pin.
Lookup commands and the four status words (stable, rc/beta, announced, unverified) are defined in [version-protocol.md](../../core/_shared/version-protocol.md).
One row per tool: `tool | line | verified from | note`. A row marked `unverified` was not confirmed against a primary source.

## Anthropic API and SDKs

| Tool | Line | Verified from | Note |
|---|---|---|---|
| `@anthropic-ai/sdk` (npm) | 0.132.1 | `npm view @anthropic-ai/sdk version` | Zod helper: `@anthropic-ai/sdk/helpers/zod` (`zodOutputFormat`); peer `zod` `^3.25 \|\| ^4`. The seam compiled against this line |
| `anthropic` (PyPI) | 1.12.1 | PyPI JSON `info.version` | 1.x line. `messages.parse(output_format=<Pydantic model>)`, `AsyncAnthropic`. Compiled and type-checked (pyright) against this line |
| `claude-opus-5-5` | $4 in / $20 out per MTok, 1M context, 128K output | `platform.claude.com/docs/en/about-claude/models/overview.md`, 2026-10-09 | Default effort `medium`; thinking cannot be disabled; forced `tool_choice` `any`/`tool` returns 400; retirement not sooner than 2027-09-22 |
| `claude-sonnet-5-5` | $2 / $10, 1M, 128K | same page | Default effort `high`; `thinking: {type: "disabled"}` returns 400; retirement not sooner than 2027-09-28 |
| `claude-haiku-5-5` | from $0.10 / $0.50 (up to a 100K prompt; $0.50 / $2.50 beyond), 1M, 128K | same page | Default effort `medium`; for classification, extraction, routing; retirement not sooner than 2027-10-07 |
| `claude-fable-5-1` | $10 / $50, 1M, 128K | same page | Thinking always on; needs 30-day data retention (no zero-retention); forced `tool_choice` returns 400. Not a default tier; opt in per task after an eval |
| Model ids | dateless ids are pinned snapshots | same page, "Claude API ID" note | Never append a date suffix. Bedrock ids carry an `anthropic.` prefix |
| Cache pricing | read 10% of input price (5% on Opus 5.5 and Sonnet 5.5, 2.5% on Fable 5.1); write 1.25x (5 min) or 2x (1 h) | models overview (reads); write multipliers from the claude-api skill reference, 2026-10-06 | Re-check `platform.claude.com/docs/en/about-claude/pricing.md` before trusting the price table in `config/llm.models.json` |
| Cache minimum | 512 tokens on the 5.5 and 5 generations | claude-api skill reference, 2026-10-06 (states "check the prompt caching docs before relying on their values") | Shorter prefixes silently do not cache: `cache_creation_input_tokens: 0` |
| Structured outputs | GA, `output_config.format` | `platform.claude.com/docs/en/build-with-claude/structured-outputs.md` | No `minimum`/`maximum`/`minLength`/`maxLength`, no recursive schemas, `additionalProperties: false` required; SDK helpers move unsupported constraints into descriptions. Refusal and `max_tokens` can break the schema. `output_format` is deprecated |
| Batch API | 50% off, up to 100,000 requests or 256 MB | claude-api skill reference | Results in any order: key by `custom_id` |
| Token counting | `client.messages.countTokens` / `count_tokens` | claude-api skill reference | Model-specific. Never use `tiktoken` for Claude |
| Removed on current models | `budget_tokens`, sampling parameters (`temperature`, `top_p`, `top_k`), assistant prefill | claude-api skill reference | Sending them returns 400. Use `output_config.effort` and structured outputs |
| Refusal fallbacks | beta `server-side-fallback-2026-07-01`, `fallbacks: "default"` | claude-api skill reference only | **unverified** against public docs; the seam maps `stop_reason: "refusal"` to `LlmError('refusal')` and does not use it |

## Embeddings, reranking, vector store

| Tool | Line | Verified from | Note |
|---|---|---|---|
| Anthropic embeddings | none offered | `platform.claude.com/docs/en/build-with-claude/embeddings.md` | The docs point to Voyage AI |
| `voyage-4-large`, `voyage-4`, `voyage-4-lite` | 32,000 context; 1024 dims default, also 256 / 512 / 2048 | same page and `docs.voyageai.com/docs/embeddings` | All embeddings of the 4 series are compatible with each other. Always pass `input_type` `query` / `document`. Output is normalized to length 1 |
| `voyage-context-4` | 120,000 context with auto-chunking | embeddings page | Contextualized chunk embeddings; alternative to LLM-generated chunk context |
| `voyage-code-4` | 32,000 | embeddings page | Code retrieval |
| `rerank-3`, `rerank-3-lite` | 32,000 context; at most 1,000 documents per request | `docs.voyageai.com/docs/reranker` | `rerank-2.5` is the previous generation |
| Voyage endpoint | `https://ai.mongodb.com/v1` (Atlas model API keys) or `https://api.voyageai.com/v1` (Voyage platform keys) | embeddings page; reranker page | Which one applies depends on where the key was created. The seam takes it from config |
| `voyageai` | npm 0.4.0, PyPI 0.5.0 | registries | Not used: the embedder seam calls the HTTP API with `fetch` (about 30 lines) |
| Cohere rerank | `rerank-v4.0-pro`, `rerank-v4.0-fast` | model names seen on `docs.cohere.com/docs/rerank` | **unverified** beyond the names |
| `BAAI/bge-reranker-v2-m3` | Apache-2.0 | `huggingface.co/api/models/BAAI/bge-reranker-v2-m3` | Self-hosted cross-encoder when text may not leave your network |
| pgvector | 0.8.7 (2026-10-01) | `raw.githubusercontent.com/pgvector/pgvector/master/CHANGELOG.md` and README | Postgres 13+. 0.8.0 added iterative index scans. 0.8.3 fixed possible HNSW index corruption during vacuum: do not run below 0.8.3. HNSW limits: `vector` 2,000 dims, `halfvec` 4,000 |
| Postgres image used to test | `pgvector/pgvector:0.8.7-pg18` (Postgres 18.6) | `docker pull`, ran the SQL in these skills | |
| HNSW defaults | `m = 16`, `ef_construction = 64`, `hnsw.ef_search = 40`, `hnsw.max_scan_tuples = 20000` | pgvector README | `hnsw.iterative_scan` = `off` / `strict_order` / `relaxed_order` |
| `pg` (npm) | 8.23.1 | `npm view pg version` | |
| `psycopg` / `psycopg-pool` | 3.3.6 / 3.3.3 | PyPI JSON | `psycopg.sql` composes the dimension and model id safely |
| `pgvector` client packages | npm 0.3.0, PyPI 0.5.1 | registries | Not needed: pass the vector as text and cast `::halfvec` |

## Observability

| Tool | Line | Verified from | Note |
|---|---|---|---|
| `@opentelemetry/api` | 1.9.1 | `npm view` | Business code uses the API only ([observability.md](../../core/_shared/observability.md)) |
| `opentelemetry-api` (PyPI) | 1.45.1 | PyPI JSON | |
| OTel GenAI semantic conventions | status **Development** | `github.com/open-telemetry/semantic-conventions-genai` (moved out of the core semconv repo), `docs/gen-ai/client-inference.md`, 2026-10-09 | Span name `{gen_ai.operation.name} {gen_ai.request.model}`, kind `CLIENT`. Required: `gen_ai.operation.name`, `gen_ai.provider.name`. `gen_ai.usage.input_tokens` **includes cached tokens**; cache counts in `gen_ai.usage.cache_read.input_tokens` and `gen_ai.usage.cache_write.input_tokens`. `gen_ai.prompt.name` and `gen_ai.prompt.version` exist. Message content (`gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.system_instructions`) is Opt-In. Metric names have changed between drafts: pin and re-verify on upgrade |
| Anthropic provider value | `gen_ai.provider.name = "anthropic"` | `docs/gen-ai/anthropic.md` in the same repo | |
| MCP semantic conventions | `mcp.method.name`, `mcp.session.id` (Development) | `docs/gen-ai/mcp.md` in the same repo | MCP 2026-07-28 documents `traceparent`, `tracestate`, `baggage` in `_meta` for trace propagation |

## MCP

| Tool | Line | Verified from | Note |
|---|---|---|---|
| MCP specification | revision **2026-07-28** (previous 2025-11-25) | `modelcontextprotocol.io/specification/2026-07-28` and its changelog | Stateless: no `initialize`, no `Mcp-Session-Id`, no GET stream; per-request `_meta` carries version and capabilities; multi round-trip requests replace server-initiated requests; Tasks moved to an extension. Deprecated: Roots, Sampling, Logging, HTTP+SSE transport, Dynamic Client Registration |
| `@modelcontextprotocol/server` | 2.3.1 | `npm view`; engines `node >=20` | v2, the stable line since 2026-07-27. Peer deps: `zod ^4.2`. Needs `"types": ["node"]` with TypeScript 6 or later |
| `@modelcontextprotocol/client` | 2.3.1 | `npm view` | Used for in-memory server tests |
| `@modelcontextprotocol/node` / `hono` / `express` | 2.1.1 / 2.0.2 / 2.0.2 | `npm view` | Thin adapters: Host and Origin validation, body parsing |
| `@modelcontextprotocol/sdk` | 1.32.1 | `npm view`: still the `latest` dist-tag | The **v1** line, single package, protocol 2025-11-25 era. v1 gets fixes for at least six months after 2026-07-27. A plain `npm i @modelcontextprotocol/sdk` installs it. Do not use for new servers |
| `mcp` (PyPI) | 2.3.0, Python >= 3.10 | PyPI JSON; ran a server under the Inspector | `from mcp.server import MCPServer`; `@mcp.tool(annotations=ToolAnnotations(...))`; `TokenVerifier` + `AuthSettings` for OAuth |
| `fastmcp` (PyPI) | 4.1.0 | PyPI JSON | Separate project; not used here |
| `@modelcontextprotocol/inspector` | 2.10.1 | `npm view`; ran `--cli` against stdio servers | `npx @modelcontextprotocol/inspector --cli <cmd> --method tools/list` |

## Evals

| Tool | Line | Verified from | Note |
|---|---|---|---|
| `vitest` | 5.0.3 | `npm view vitest version` | Runs the in-repo eval harness and the unit tests |
| `pytest` / `pytest-asyncio` | 9.1.1 / 1.4.0 | PyPI JSON | `asyncio_mode = "auto"` |
| `inspect-ai` (PyPI) | 0.3.277 (MIT) | PyPI JSON; ran a task with `--model mockllm/model` | UK AI Security Institute and Meridian Labs. `inspect eval <file> --model anthropic/<id>`, `inspect view` |
| `promptfoo` (npm) | 0.124.1 (MIT) | `npm view promptfoo`; `promptfoo eval --help` | OpenAI agreed to acquire Promptfoo on 2026-03-09 and stated it stays open source (`promptfoo.dev/blog/promptfoo-joining-openai`); closing status **unverified**. Flags seen: `-c`, `-o <file>` (json, jsonl, junit.xml ...), `--repeat`, `--no-cache`, `-j` |
| `braintrust` | npm 3.37.1, PyPI 0.45.0 | registries | Hosted experiment tracking; not used here |
| `ragas` / `deepeval` | 0.4.3 / 4.2.8 | PyPI JSON | Not used: metrics here are computed in about 30 lines |
| `zod` | 4.6.5 | `npm view zod version` | |
| `pydantic` | 2.14.0 | PyPI JSON | |

## Security references

| Reference | Line | Verified from | Note |
|---|---|---|---|
| OWASP Top 10 for LLM Applications | **2026 edition**, published 2026-08-04 | `github.com/GenAI-Security-Project/GenAI-LLM-Top10` README (current release); the 2025 edition is archived | List in [llm-security.md](llm-security.md). The older `OWASP/www-project-top-10-for-large-language-model-applications` repo is a legacy archive |
| OWASP Top 10 for Agentic Applications | 2026, ASI01 to ASI10, published 2025-12-09 | secondary sources only | **unverified** against the primary OWASP page |
