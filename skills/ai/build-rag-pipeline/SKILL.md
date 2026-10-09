---
name: build-rag-pipeline
description: Use when building retrieval-augmented answers over your own documents — structure-aware chunking, pinned embeddings in pgvector, hybrid vector plus full-text search with RRF, tenant isolation in the query, citations, an "I don't know" path, retrieval evals before prompt tuning.
---

# Build a RAG Pipeline

Ingest, normalize, chunk, embed, store, retrieve, answer with citations. The order of work matters: build retrieval and measure it (recall@k, MRR) **before** touching the answer prompt. Most bad RAG answers are retrieval failures that a prompt cannot fix. Store default: `ai.rag_store: pgvector` in the profile.

## 1. Audit current state

Read `.claude/stack-profile.md` (`database`, `ai.rag_store`, `ai.provider`, `languages`, `backend.track`). If absent, detect per [stack-profile.md](../../core/_shared/stack-profile.md). Change nothing yet:

```bash
grep -rln "pgvector\|halfvec\|vector(" migrations drizzle alembic src 2>/dev/null           # existing vector schema
grep -rniE "embed|chunk|similarity|cosine|<=>" src --include=*.ts --include=*.py | head       # ad hoc retrieval code
ls src/platform/llm src/rag evals/datasets 2>/dev/null                                        # seam, RAG module, golden sets
grep -rn "tenant_id\|row level security\|enable row level" migrations drizzle alembic 2>/dev/null | head
psql "$DATABASE_URL" -c "select extname, extversion from pg_extension where extname='vector'"  # expect 0.8.3 or later
```

Report: model calls outside the seam ([build-llm-seam](../build-llm-seam/SKILL.md) comes first), embeddings without a recorded model id, retrieval without a tenant filter, no golden queries, chunking by fixed characters.

## 2. Decide what to do

- No seam yet → run `build-llm-seam` first; the answer step calls it.
- No vector schema → full install (steps 4–6).
- Schema exists, embeddings carry no model id → add `rag_embeddings` and backfill (step 5); this is the one change that is hard to do later.
- Retrieval works, answers are wrong → do not edit prompts yet: build the retrieval eval (step 7).
- Everything present and `Verify` passes → "already in place".

## 3. Detect the store track

| Signal | Branch |
|---|---|
| `ai.rag_store: pgvector`, or Postgres in the profile | pgvector: this skill's code. Default, justified in [rag-patterns.md](./rag-patterns.md) |
| `database.host: supabase` | pgvector is available there; same SQL. Check `select extversion` first |
| `sqlite-vec`, local single-user tool | Keep the `Embedder` and chunker; write the store against sqlite-vec; no RLS, so isolation is by file per tenant |
| `qdrant`, or a measured need the store cannot meet | Keep the interfaces (`Embedder`, `search`, `answer`); replace `store.ts`. The measured need is a retrieval p95 above budget after tuning `ef_search` and indexes at your corpus size |
| `languages`: python | Same SQL; [rag-code.md](./rag-code.md#python-store) has `store.py` |

## 4. Install only what's missing

```bash
# Postgres: the extension (pgvector 0.8.7 on the image tested; managed hosts: enable "vector")
psql "$DATABASE_URL" -c "create extension if not exists vector"
pnpm add pg zod && pnpm add -D @types/pg        # TypeScript
uv add "psycopg[binary]" psycopg-pool           # Python
```

Embeddings: Anthropic offers no embedding model; use Voyage AI (`voyage-4`, 1024 dims). Add `VOYAGE_API_KEY` and `VOYAGE_BASE_URL` (`https://ai.mongodb.com/v1` for Atlas keys, `https://api.voyageai.com/v1` for Voyage platform keys) to the service config. If text may not leave your network, run `voyage-4-nano` (open weights) or another model behind the same `Embedder` interface.

## 5. Generate the seams

Layout (the store is the repository layer, `answer` is the service, see [service-layout.md](../../backend/_shared/service-layout.md)):

```
migrations/0001_rag.sql      # tables, HNSW index, FTS index, RLS
src/rag/chunk.ts             # markdown-aware chunker
src/rag/embed.ts             # Embedder interface + Voyage adapter
src/rag/store.ts             # withTenant, upsertDocument, search: the only SQL
src/rag/ingest.ts            # normalize, ingest, removeMissing
src/rag/answer.ts            # context, citations, "I don't know"
prompts/rag-answer.md        # versioned prompt
evals/datasets/retrieval.jsonl
```

All code: [rag-code.md](./rag-code.md). Run the migration as a role that owns the tables; the application connects as a different role without `bypassrls`. Edit: the model id and dimension in the index (`voyage-4@1024`), the FTS config (`simple` mixes languages safely; use `german`, `english` … when the corpus is one language), the similarity floor in `answer.ts` (calibrate on the eval set).

## 6. Wire it up

1. **Ingest job.** A CLI or queue consumer reads sources, calls `ingest(pool, embedder, doc)`. It is idempotent: an unchanged `content_hash` returns `unchanged` and costs nothing.
2. **Freshness.** After each full sync call `removeMissing(pool, tenantId, liveUris)`. Schedule the sync (cron, or a webhook from the source for changes).
3. **Retrieval endpoint.** Derive `tenantId` from the verified session, never from the request body. `withTenant(pool, tenantId, c => search(c, embedder, { tenantId, text }))`, then `answer(llm, question, hits)`. Return `sources` with the answer.
4. **Re-embedding is a deliberate act:** new migration with the new partial index, backfill into `rag_embeddings` under the new id, run the retrieval eval on both, flip the config, drop the old rows and index. See [rag-patterns.md](./rag-patterns.md#rule-the-embedding-model-is-pinned-and-re-embedding-is-explicit).

## 7. Verify

```bash
TEST_DATABASE_URL=postgres://app_role:…@localhost/test pnpm vitest run tests/rag.test.ts   # Python: uv run pytest tests/test_rag.py
```

Expected: chunker tests pass; the retrieval test shows tenant A's search never returns tenant B's text, even when the query itself names tenant B (RLS wins); an unchanged document returns `unchanged`; a weak match returns the fixed "I don't know".

Then the part that matters. Write 30 or more golden queries into `evals/datasets/retrieval.jsonl` (`{id, tenant, query, relevant: [source_uri]}`), including a few that have **no** answer in the corpus, and run:

```bash
pnpm tsx evals/retrieval.ts evals/datasets/retrieval.jsonl      # prints recall@5, recall@20, MRR and the worst query ids
```

Record the numbers. Change one thing at a time (chunk size, `candidates`, hybrid on or off, reranker) and keep a change only if recall@k or MRR improves. In `psql`, `explain` the vector leg once: expect `Index Scan using rag_emb_… (hnsw)`. Eval design: [set-up-llm-evals](../set-up-llm-evals/SKILL.md).

## References
- [rag-patterns.md](./rag-patterns.md): rules and why. [rag-code.md](./rag-code.md): all code.
- [llm-seam-ts.md](../_shared/llm-seam-ts.md): the answer step goes through the seam.
- [llm-security.md](../_shared/llm-security.md): documents are untrusted text; tenant isolation is LLM02 and LLM09.
- [stack-versions.md](../_shared/stack-versions.md): pgvector, Voyage, driver lines.
