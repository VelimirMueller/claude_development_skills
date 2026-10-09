# LLM Security

The contract every `aiskills` skill writes to. A model reads text and produces text; it cannot tell an instruction from data. Treat that as a fact of the platform, not a bug to prompt away, and design so that a fooled model can do no harm.
Companion to [security-baseline.md](../../core/_shared/security-baseline.md) (web and platform baseline) and [logging-contract.md](../../core/_shared/logging-contract.md). Rules with code: [security-patterns.md](../secure-llm-features/security-patterns.md).

## The one rule

**Authority comes from the principal's token, never from text.** The user id, tenant, scopes and budget come from the verified session. Nothing a prompt, a retrieved document, a tool result or the model's own output says can widen them.

Consequence: a successful prompt injection can change what the model *says* and which *allowed* tool it tries. It cannot reach data, tools or spend the user could not reach without the model.

## Trust boundaries

| Text source | Trust | Why | Treatment |
|---|---|---|---|
| System prompt (file in the repo) | Trusted author, **not secret** | Users can extract it; tool schemas and policy text leak with it | No secrets, no authorization logic in it |
| User message | Untrusted input from an authenticated principal | The user is allowed to be adversarial toward the model | Validate size; redact PII before sending; never let it name another user or tenant |
| Retrieved documents (RAG) | **Untrusted** | Anyone who can write to an indexed source can write instructions | Wrap in delimiters in the user turn; strip the closing delimiter; cite, do not obey |
| Tool results (incl. web, email, tickets) | **Untrusted** | Same: indirect injection | Same as documents; cap size; mark the source |
| Tool descriptions from third-party MCP servers | **Untrusted** | The description enters the model's context and can carry instructions; annotations are hints, not guarantees | Use servers you trust; review descriptions on update; pin versions |
| Model output | **Untrusted for every sink** | It carries whatever the injected text asked for | Validate against a schema; escape on render; parameterize SQL and shell; never `eval` |

## The three-way risk

An agent is dangerous when it has all three: **access to private data**, **exposure to untrusted content**, and **a way to send data out or act** (a link or image the client fetches, an HTTP tool, an email tool). Remove one leg by design: no outbound channel, or no private data in the same context as untrusted content, or a human confirms every outward action.

## OWASP Top 10 for LLM Applications, 2026 edition: where each is handled

Edition published 2026-08-04; list and order from the OWASP GenAI Security Project's source repository (see [stack-versions.md](stack-versions.md)). Scope notes after the title are from secondary summaries of the 2026 text.

| ID | Risk | Control in these skills | Where |
|---|---|---|---|
| LLM01:2026 | Prompt Injection | Authority from token; untrusted text in the user turn inside delimiters; schema-validated output; injection cases in the eval gate | [security-patterns.md](../secure-llm-features/security-patterns.md), [eval-patterns.md](../set-up-llm-evals/eval-patterns.md) |
| LLM02:2026 | Sensitive Information Disclosure | Tenant filter in the query plus RLS; PII redaction before sending; no content in logs or span attributes by default | [rag-patterns.md](../build-rag-pipeline/rag-patterns.md), [seam-patterns.md](../build-llm-seam/seam-patterns.md) |
| LLM03:2026 | Excessive Agency | Tools bound to the principal's scopes; read-only by default; writes are proposals a human confirms; step and cost caps | [security-patterns.md](../secure-llm-features/security-patterns.md), [mcp-patterns.md](../build-mcp-server/mcp-patterns.md) |
| LLM04:2026 | Supply Chain | Pinned model snapshots and SDK lockfile; reviewed MCP servers; embedding and rerank vendors named in the data-flow notes | [seam-patterns.md](../build-llm-seam/seam-patterns.md), [stack-versions.md](stack-versions.md) |
| LLM05:2026 | Data and Model Poisoning | Index only allow-listed sources; provenance (`source_uri`, `content_hash`) on every chunk; tenant-scoped writes; a delete path that cascades | [rag-patterns.md](../build-rag-pipeline/rag-patterns.md) |
| LLM06:2026 | Unbounded Consumption | `max_tokens` on every call; per-user daily budget; one deadline with capped retries; retrieval `k` caps; tool-loop caps; eval budget | [security-patterns.md](../secure-llm-features/security-patterns.md), [eval-patterns.md](../set-up-llm-evals/eval-patterns.md) |
| LLM07:2026 | Misinformation | Citations validated against the retrieved set; "I don't know" gates; retrieval evals before prompt tuning | [rag-patterns.md](../build-rag-pipeline/rag-patterns.md) |
| LLM08:2026 | Hidden Context Exposure (named System Prompt Leakage in 2025; also covers tool schemas and policy text) | Assume prompts and tool schemas are readable; enforce policy in code | [security-patterns.md](../secure-llm-features/security-patterns.md) |
| LLM09:2026 | Vector and Embedding Weaknesses | Isolation in the store (query filter, RLS); embeddings treated as sensitive as the source text; ACL filters in SQL, never after top-k | [rag-patterns.md](../build-rag-pipeline/rag-patterns.md) |
| LLM10:2026 | Improper Output Handling (2026 scope includes terminal and IDE sinks that render ANSI sequences, and clients that auto-fetch images) | Sanitize markdown, HTML, links, images and control sequences; parameterize every downstream query | [security-patterns.md](../secure-llm-features/security-patterns.md) |

For agents and multi-agent systems also read the OWASP Top 10 for Agentic Applications (2026, ASI01 to ASI10: goal hijack, tool misuse, identity and privilege abuse, agentic supply chain, unexpected code execution, memory and context poisoning, insecure inter-agent communication, cascading failures, human-agent trust exploitation, rogue agents). Its list was confirmed from secondary sources only.

## The checklist every AI feature passes before merge

1. One seam owns the model call; call sites name a tier, not a model id ([build-llm-seam](../build-llm-seam/SKILL.md)).
2. The principal (user, tenant, scopes) is an argument from the verified session; no tool or query takes identity from model output.
3. Tenant isolation is in the SQL (`where tenant_id = …`) and in RLS; a test proves tenant A cannot read tenant B.
4. Untrusted text (documents, tool results) sits in the user turn inside delimiters, never in the system prompt.
5. Every tool declares `effect: read | write` and a required scope; writes wait for a human confirmation the model cannot give.
6. Model output is validated (schema) and escaped at its sink; no `eval`, no string-built SQL or shell, no unescaped HTML, no auto-fetched markdown images.
7. `max_tokens`, a deadline, a retry cap, a per-user budget and a rate limit exist, and each has a test.
8. Logs and spans carry ids, token counts, cost and error kind. Prompts, completions and retrieved text are off by default.
9. An eval set holds at least one injection case and one unanswerable question, and runs in CI.
10. Provider data terms are checked for the data sent (retention, regions, zero-retention models); the data-flow note names every recipient.

## When to deviate

- **Internal prototype, synthetic data, no tools, no outbound channel:** items 2, 3, 5 and 10 can wait; items 1, 6, 7 and 8 cannot.
- **A read-only assistant over public documents:** tenant isolation and confirmation are moot; keep output handling and consumption limits.
- **Regulated data:** this file is the floor. Add a data-protection review and local or zero-retention models before you add features.
