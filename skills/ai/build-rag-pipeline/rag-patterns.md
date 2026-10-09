# RAG Patterns

Reference for [build-rag-pipeline](./SKILL.md). Code: [rag-code.md](./rag-code.md).

## Rule: pgvector over a dedicated vector database
**Why:** Documents, chunks, tenants and permissions already live in Postgres. Keeping vectors there gives one transaction (a document and its embeddings commit together or not at all), one backup, one access-control model (row-level security applies to vectors), and filters written in SQL instead of a second query language. A second system adds a sync pipeline that can drift and a second place where tenant isolation can fail.
**How to apply:** `create extension vector`; store `halfvec`, index with HNSW. Revisit only on measurement: retrieval p95 over budget at your corpus size after tuning `hnsw.ef_search`, partial indexes and partitioning, or a need pgvector does not cover (multi-vector late interaction, sparse-dense models at very large scale, scale-out beyond one primary). Then replace `store.ts`; `Embedder`, chunker and `answer` stay.
**Anti-example:** Adopting a vector database for 50,000 chunks because a tutorial did.
**When to deviate:** The data is not in Postgres and never will be (a static index shipped with a desktop app): `sqlite-vec`.

## Rule: `halfvec` with a cosine HNSW index
**Why:** `halfvec` stores 16-bit floats: half the storage and half the index size of `vector`, typically with a small effect on recall (verify on your eval set), and a 4,000-dimension index limit instead of 2,000. Voyage embeddings are normalized to length 1, so cosine and dot product rank the same. HNSW needs no training step and handles inserts; IVFFlat needs a representative table before you build it.
**How to apply:** `embedding halfvec`, an expression index `((embedding::halfvec(1024)) halfvec_cosine_ops) with (m = 16, ef_construction = 64)`, queries `order by embedding::halfvec(1024) <=> $1::halfvec(1024)`. Defaults `m = 16`, `ef_construction = 64`, `hnsw.ef_search = 40`; raise `ef_search` if recall is low (measure). For large builds raise `maintenance_work_mem` so the graph fits in memory. Use pgvector 0.8.3 or later: 0.8.3 fixed a possible HNSW index corruption during vacuum. Shorter vectors (Voyage supports 256 and 512 dims) cut storage and latency further; adopt only if the eval holds.
**When to deviate:** Eval shows `float32` beats `halfvec` on your data (rare): use `vector`, mind the 2,000-dimension index limit.

## Rule: The embedding model is pinned, and re-embedding is explicit
**Why:** Vectors from different models live in different spaces; comparing them returns confident nonsense. A silent model change (a provider alias moving, an env var edit) corrupts retrieval with no error.
**How to apply:** Every vector row stores `embedding_model` (`voyage-4@1024`: model and dimension). The query filters on the model id in use. The index is partial per model (`where embedding_model = 'voyage-4@1024'`), and the model id and dimension reach the SQL only from validated config. Changing models: (1) migration with the new partial index; (2) backfill job writing new rows to `rag_embeddings`; (3) run the retrieval eval against both; (4) flip the config; (5) delete the old rows and index. Voyage states that all embeddings of the `voyage-4` series are compatible with each other, so documents embedded with `voyage-4-large` can be queried with a `voyage-4-lite` query embedding: a cheaper query path. Record both ids and test it before relying on it. Always pass `input_type` (`document` when indexing, `query` when searching); Voyage says not to omit it.
**Anti-example:** `embedding vector(1536)` with no model column: the day you switch models, nothing tells you which rows are stale.

## Rule: Chunk by structure, size by tokens, overlap only where a cut falls inside a thought
**Why:** A chunk is the unit of retrieval and of citation. A chunk that spans two unrelated sections retrieves for both and answers neither. Fixed-width character chunks cut sentences, tables and code in half.
**How to apply:** Split on headings first (a chunk never crosses a heading). Inside a section, pack paragraphs up to about 400 tokens. Keep fenced code and tables whole. Overlap one tail paragraph (about 12%, capped at 50 tokens) only when a section is split mid-way, because a boundary between two paragraphs of one argument is the case overlap helps; across headings the boundary is a real topic change. Embed `heading path + text` so the section title informs the vector, and store the heading path for citations and the FTS index. The token count is an estimate (`characters / 3.5`): chunk size is a quality choice, not a hard limit (the embedding model accepts 32,000 tokens), so a 15% error is irrelevant. Tune size and overlap with the retrieval eval, not by feel.
**Stronger option:** contextual retrieval. Prepend 50 to 100 tokens of LLM-written context ("this chunk is from the 2024 refund policy, section on EU customers") before embedding and indexing. Anthropic measured, on its own evaluation sets at top-20 retrieval with a 5.7% baseline failure rate: contextual embeddings 3.7% (35% fewer failures), plus contextual BM25 2.9% (49%), plus reranking 1.9% (67%). One-time cost they report: about $1.02 per million document tokens with prompt caching. Voyage's `voyage-context-4` gives chunk vectors that see the whole document without writing context text. Try both only after the plain pipeline has an eval to beat.
**When to deviate:** Q&A pairs, tickets, or other records that are already one unit each: one record, one chunk.

## Rule: Hybrid retrieval, fused with reciprocal rank fusion
**Why:** Vectors find paraphrases and miss exact tokens (error codes, SKUs, names, section numbers). Full-text finds exact tokens and misses paraphrases. Real queries need both, so run both and merge.
**How to apply:** Two CTEs in one query: the top 50 by cosine distance, the top 50 by `ts_rank_cd` over a generated `tsvector` with a GIN index (`websearch_to_tsquery` parses user text safely and never throws on odd input). Fuse by rank: `score = Σ 1 / (60 + rank)` over the legs a chunk appears in. RRF uses ranks, so it needs no calibration between a cosine distance and a text-rank score, which live on unrelated scales; `k = 60` is the common default and a flat top is fine. Return the vector similarity too: it is the signal for the "I don't know" gate (the RRF score is not calibrated for that). FTS config: `simple` is safe for mixed languages and identifiers; use the language config (`german`, `english`) for single-language corpora, which adds stemming. If your content is German and queries are German, `german` usually wins: measure.
**Anti-example:** Adding vector and text scores with a hand-tuned weight (`0.7 * cos + 0.3 * rank`): the weight is a guess that breaks when either leg changes.
**When to deviate:** A corpus of long natural prose where the eval shows the full-text leg adds nothing: drop it and save the index.

## Rule: Tenant isolation is in the query and in the database
**Why:** The answer step cannot protect data the retriever already returned. A single missing `where` clause, or a filter applied *after* top-k in application code, leaks another tenant's text into the prompt, and from there into the answer.
**How to apply:** Three layers, all required:
1. `tenant_id` is denormalized onto `rag_chunks` and `rag_embeddings`, and every query filters on it in SQL. Never fetch top-k and filter in code: it shrinks recall and is the classic leak.
2. Row-level security on all three tables with `tenant_id = current_setting('app.tenant_id')`, `force row level security`, and an application role without `bypassrls`. `current_setting` without a default raises when unset: the system fails closed.
3. `withTenant` is the only way to obtain a connection. It opens a transaction and sets the tenant with `set_config(…, true)` (transaction-local, so a pooled connection cannot carry it into the next request). Never use session-level `SET`.
The tenant id comes from the verified session. A test inserts two tenants and asserts that searching as A with a query that *names* B returns nothing.
Other filters (per-document ACL groups, dates, product) go in the same `where` clause. For `hnsw.iterative_scan`: pgvector filters after the index scan, so a selective filter can return fewer rows than asked. `set local hnsw.iterative_scan = relaxed_order` keeps scanning until enough rows pass (bounded by `hnsw.max_scan_tuples`, default 20,000). When one filter value matches few rows, the planner may choose an exact scan on the filter index instead, which is also correct. Very large tenants: a partial HNSW index per tenant, or partition by tenant (both from the pgvector docs).
**When to deviate:** Single-tenant internal tools: keep the column (it costs nothing) and the RLS policy, and set a constant tenant.

## Rule: Optional rerank, only when the eval says ranking is the problem
**Why:** A reranker (a cross-encoder) reads the query and each candidate together, which is more accurate than comparing two vectors. It also adds a network call and per-document cost. It only helps when the right chunk is retrieved but ranked too low.
**How to apply:** Compare recall@20 (or @50) with recall@5. A large gap means the right chunks are found but buried: add a `Reranker` interface between `search` (fetch 50 to 150) and `answer` (pass the top 8 to 20). Anthropic's measurement above reranked 150 candidates to 20. Voyage `rerank-3` (32,000-token context, up to 1,000 documents per request, `top_k`) or a self-hosted cross-encoder such as `BAAI/bge-reranker-v2-m3` (Apache-2.0) when text must stay in your network. Keep it behind an interface; a reranker outage must degrade to the RRF order, not to an error.
**When to deviate:** Recall@20 is already low: reranking cannot return what retrieval missed. Fix chunking or the embedding first.

## Rule: Answer from sources, cite by id, and validate the citations
**Why:** A citation the model invents is worse than none: it looks like proof. Free-text "[source: handbook]" cannot be checked; an id can.
**How to apply:** Number the retrieved chunks inside `<sources>` in the **user** turn, strip any closing delimiter from chunk text, and say in the system prompt that sources are data. The schema is `{ insufficient_context, answer, cited_sources: number[] }`. The server then checks every cited id exists in the retrieved set, and returns the cited chunks (title, path, `source_uri`) as the citations. Anthropic's native citations (`citations: { enabled: true }` on document blocks) give quote-level spans, but do not combine with `output_config.format` (the API returns 400): pick one per call. This skill uses structured output plus ids because the schema also carries the "cannot answer" flag.
**Anti-example:** Asking the model to "cite your sources" in prose and showing whatever it wrote.

## Rule: "I don't know" is a designed path with two gates
**Why:** Without a refusal path a RAG system answers every question, from whatever chunk ranked first. For an unanswerable question that is a confident fabrication.
**How to apply:** Gate 1, before the model: if no vector hit has similarity at or above a floor, return the fixed message without a model call (it saves money too). Calibrate the floor on the eval set: include unanswerable queries and pick the value that rejects them while keeping answerable ones. The `0.3` in the code is a placeholder. Gate 2, after the model: `insufficient_context` is true, or the answer cites nothing, or it cites an id that does not exist: return the fixed message. The message is a constant, not model text, so tests can assert on it.
**When to deviate:** A search UI (no generated answer): return ranked results and let the user judge; skip gate 2.

## Rule: Freshness is a job with a source of truth
**Why:** Indexed text goes stale, and deleted documents stay retrievable until someone removes them: a data-protection problem as much as a quality one.
**How to apply:** Normalize text, hash it (`content_hash`), skip unchanged documents. Embed **before** deleting old chunks, inside one transaction: a provider failure leaves the old version intact. After a full sync, delete documents missing from the source (`removeMissing`); deletes cascade to chunks and embeddings. Store `indexed_at`. Schedule a full sync (daily is a common start) and add change webhooks when the source offers them. A subject's deletion request is a hard delete by `source_uri` or `tenant_id`, which cascades.

## Rule: Evals before prompt tuning
**Why:** If the right chunk is not in the context, no prompt can recover it; if it is, the prompt matters. Tuning the prompt first optimises the wrong stage.
**How to apply:** Build a golden set of 30 or more real queries with the relevant `source_uri`s, plus unanswerable ones. Report recall@5, recall@20 and MRR (rank documents, not chunks). Change one knob at a time: chunk size, overlap, `candidates`, FTS config, hybrid on or off, reranker, embedding model. Keep a change only if a metric improves. Only then build the answer eval ([set-up-llm-evals](../set-up-llm-evals/SKILL.md)). Store the numbers with the date and the settings.

## Rule: Retrieved text is untrusted input
**Why:** Anyone who can write to an indexed source can plant instructions in it ([llm-security.md](../_shared/llm-security.md)).
**How to apply:** Delimit sources in the user turn, strip the closing delimiter, never put them in the system prompt, give the answer step no tools, validate output against the schema, and sanitize rendered markdown ([security-patterns.md](../secure-llm-features/security-patterns.md)). Index only allow-listed sources and record their provenance.

## When to deviate

- **Under about 100 pages of text, one user:** put the documents in the prompt with caching instead of building retrieval. No chunking, no index, no retrieval failures; the cost is tokens per call.
- **Questions that need joins and aggregates** ("revenue by region"): that is text-to-SQL or an API tool, not RAG.
- **Corpus changes every minute:** an on-demand tool call to the live source beats an index.
