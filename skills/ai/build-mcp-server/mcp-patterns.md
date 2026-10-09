# MCP Patterns

Reference for [build-mcp-server](./SKILL.md). Code: [mcp-code.md](./mcp-code.md). Spec: revision 2026-07-28 (`modelcontextprotocol.io/specification/2026-07-28`), checked 2026-10-09.

## Rule: Few tools, shaped like tasks
**Why:** Every tool name, description and schema is in the model's context on every turn. Forty endpoint-shaped tools cost tokens, blur the choice (`list_x`, `search_x`, `find_x`) and make the model assemble workflows from primitives. A tool per user intent lets the model pick once and succeed.
**How to apply:** List the 3 to 7 questions or jobs users bring. One tool each: `search_tickets`, `get_ticket`, `close_ticket`, not `GET /tickets`, `GET /tickets/{id}`, `PATCH /tickets/{id}`, `GET /tickets/{id}/comments`. Return what the next step needs (id, title, status), not the whole record; add a `get_*` tool for detail. Return tools in a deterministic order: the spec says servers SHOULD, so clients can cache the list and prompt caching stays warm.
**Anti-example:** Generating one tool per OpenAPI operation.
**When to deviate:** A developer-facing server over a large API where completeness matters more than tokens: keep the tools, and consider the host's tool search so only relevant tools load.

## Rule: Descriptions say what, when, returns and limits
**Why:** The description is the only documentation the model has. A vague one produces wrong calls; the model cannot ask you.
**How to apply:** Three sentences: what it does, when to use it (and when to use a neighbour instead), what it returns with its limits. `Find support tickets by status. Returns at most 20 tickets with id, title and status. Use get_ticket for details.` Names are `verb_noun`, 1 to 128 characters, letters, digits, `_`, `-`, `.` only, unique per server. Every input field gets `.describe()`. Say units, formats and the allowed range.
**Anti-example:** `description: "Tickets tool"`.

## Rule: Typed inputs, narrow types, explicit limits
**Why:** The schema is validated before your handler runs. A narrow type removes a whole class of bad calls and gives the model a clear menu.
**How to apply:** `z.enum([...])` over free strings; `z.number().int().min(1).max(20).default(10)` over an unbounded number; ids as strings with a pattern when you know it. A tool with no parameters uses `{ type: "object", additionalProperties: false }` (the spec recommends it). Never accept identity (`userId`, `tenantId`) as an input: it comes from the token.
**Anti-example:** `query: z.string()` that is interpolated into SQL.

## Rule: Read-only by default, annotations set explicitly
**Why:** The annotation defaults are not safe: `destructiveHint` defaults to `true` and `openWorldHint` to `true`, `readOnlyHint` to `false`. A tool you do not annotate looks destructive and open-world to a host. Hosts use the hints for confirmation prompts, but the spec is explicit that clients must treat annotations as untrusted unless they come from a trusted server: they are hints for UX, never a security boundary.
**How to apply:** Set all four on every tool: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`. Ship read tools first; add a write tool only for a named use case. Enforce the real limits in code (scopes, tenant filter), not in the annotation.

## Rule: Writes need a confirmation the model cannot give
**Why:** A `confirm: true` argument is filled in by the same model that was talked into the call. It prevents nothing. Human confirmation must come through a channel the model does not control.
**How to apply:** In the 2026-07-28 protocol the server returns an input-required result with an embedded elicitation (multi round-trip request); the client shows it to the user and retries the call with the answer. In the SDK: `inputRequired({ inputRequests: { confirm: inputRequired.elicit({ message, requestedSchema }) } })`, then read the answer with `acceptedContent(ctx.mcpReq.inputResponses, 'confirm', schema)`. A client that does not declare elicitation support gets a missing-capability error: the write tool is unusable there, which is the safe failure. Validate the user's answer (it arrives from the client) with the schema overload. The example in [mcp-code.md](./mcp-code.md) is tested against a client that answers yes and one that answers no.
**When to deviate:** Idempotent, reversible writes of low value (adding a label): rely on the host's own approval prompt and the `destructiveHint: false` annotation.

## Rule: Tools act, resources inform, prompts are the user's
**Why:** The protocol separates who controls each. Tools are model-controlled (the model decides to call them). Resources are application-controlled context addressed by URI (a user attaches a file or a schema). Prompts are user-controlled templates (a slash command).
**How to apply:** Anything parametrized or computed is a tool. Stable, addressable, read-only content a person may want to attach (a schema, a runbook, a config file) is a resource; return it from a tool as a `resource_link` when the model should fetch it later. Use prompts for canned workflows you want users to trigger by name. Most servers need tools only; add the others when a real client uses them.

## Rule: stdio for local, Streamable HTTP for remote, and no sessions
**Why:** stdio is a child process: the host launches it, the user is the owner, credentials come from the environment, no network surface. Streamable HTTP is a normal HTTPS endpoint that many users share. The 2026-07-28 revision removed protocol-level sessions (`Mcp-Session-Id`), the `initialize` handshake, the GET stream and SSE resumability; each request is self-contained and carries its protocol version and client capabilities in `_meta`. Servers scale horizontally with no sticky routing.
**How to apply:** HTTP: one endpoint (`/mcp`), POST only; answer each request with JSON or an SSE stream scoped to that request; closing the stream cancels it. Create the `McpServer` per request from a factory (`createMcpHandler(ctx => createServer(ctx.authInfo))`): the identity is per request, so the tool list may vary by caller's scopes but not by connection. stdio: stdout carries only protocol messages; log to stderr. HTTP+SSE (the 2024 transport) is deprecated; do not build it. State that must survive across calls is an explicit handle returned by one tool and passed to the next (a basket id), validated against the caller on every call, opaque, with a stated expiry in the creating tool's description.
**Anti-example:** Keeping a per-connection "current project" in server memory.

## Rule: Remote servers are OAuth 2.1 resource servers, and validate audience
**Why:** A remote server reachable by many users must know who is calling and refuse tokens that were not issued for it. Accepting any valid token from the same identity provider lets a token stolen from another service work here, and passing the client's token on to an upstream API makes your server a confused deputy.
**How to apply:** Per the spec: serve OAuth Protected Resource Metadata (RFC 9728) at `/.well-known/oauth-protected-resource/<path>` naming your authorization server; answer a missing or invalid token with `401` and `WWW-Authenticate: Bearer … resource_metadata="…"`; answer insufficient scope with `403` and `error="insufficient_scope"` plus the full `scope` needed; validate that the token's audience is **this** server's URL (RFC 8707 resource indicators); require `exp`; accept the token only in the `Authorization` header, never the query string; never forward the client's token to another API: call upstream with your own credentials or a token exchange. Put the tenant and user from the token into `createServer(auth)`. Scope tools by group (`tickets:read`, `tickets:write`) and hide tools the token cannot use. Client registration is the authorization server's job: it should support Client ID Metadata Documents (Dynamic Client Registration is deprecated in this revision). Use an existing identity provider.
**When to deviate:** A server on a private network for one team, behind an authenticating gateway that injects the identity: validate the gateway's signed header instead, and say so in the README. stdio servers do not use OAuth; they read credentials from the environment.

## Rule: Validate the network edge
**Why:** A server on `localhost` is reachable from any web page the user opens (DNS rebinding) unless it checks who is asking.
**How to apply:** Validate `Origin` on every request (invalid present origin gets `403`) and the `Host` header against an allow-list; bind to `127.0.0.1` when local. The SDK adapters do this by default for localhost binds (`createMcpHonoApp({ host })`, `@modelcontextprotocol/node`); behind a public hostname pass `allowedHosts` and `allowedOrigins` explicitly. Cap request body size (the Hono adapter defaults to 4 MiB). When you proxy, send `X-Accel-Buffering: no` on SSE responses so the proxy does not buffer them.

## Rule: Bound every output
**Why:** A tool result goes straight into the model's context. A 5 MB result costs money, evicts the conversation, and may carry text an attacker planted.
**How to apply:** Cap the characters (20,000 in the example) and say how to narrow when truncating: `[truncated: 8,402 more characters. Narrow the query.]`. Paginate with a `cursor` argument and return `nextCursor`. Return fields, not records. The spec says a tool returning structured content SHOULD also return the serialized JSON as text; that doubles the tokens, so keep structured results small. Set `outputSchema` when clients validate; the SDK validates `structuredContent` against it before the result leaves your server.

## Rule: Errors teach the model what to do next
**Why:** The model recovers by reading the error. "Internal error" gives it nothing; "No ticket T-9. Call search_tickets to list valid ids." gives it the next call.
**How to apply:** Two channels. **Protocol errors** (unknown tool, malformed request) are JSON-RPC errors; the SDK produces them. **Tool execution errors** (bad business input, not found, upstream failed) return a normal result with `isError: true` and text that states what was wrong and what to try. Name the field, the allowed values and the neighbouring tool. Never include stack traces, SQL, upstream response bodies, tokens or other tenants' ids.
**Anti-example:** `throw new Error(err.stack)`.

## Rule: Limit, time out and audit every tool
**Why:** The spec requires servers to rate-limit tool invocations, validate inputs and sanitize outputs, and says clients should log tool use. A loop in a client can call a tool hundreds of times.
**How to apply:** Rate-limit per principal (token bucket in the gateway or a Redis counter); set a timeout on every upstream call; log `tool`, `principal id`, `outcome`, `duration`, never arguments or results by default ([logging-contract.md](../../core/_shared/logging-contract.md)). The protocol carries `traceparent` and `tracestate` in `_meta`, so a trace can run from the client through your server; use the OTel API and the MCP attributes `mcp.method.name` (Development status).

## Rule: Tool output is untrusted for the client, so do not launder it
**Why:** If your tool returns text from a third party (a ticket body, a web page, an email), an attacker who controls it can write instructions into the model's context. That is indirect prompt injection ([llm-security.md](../_shared/llm-security.md)).
**How to apply:** Return untrusted content in a clearly named field (`body`, `source`), not mixed into your own sentences; cut it to length; never place it in a tool *description*; keep write tools out of any server that also returns untrusted text unless writes need a confirmation (above). The host is responsible for isolation, your server is responsible for not making it harder.

## Rule: Test it three ways
**Why:** Schema, behaviour and transport fail independently.
**How to apply:** (1) In-memory client test with `InMemoryTransport.createLinkedPair()`: list tools (assert names, order and annotations), call each (assert `structuredContent`), assert tenant scoping through the auth argument, assert the confirmation flow with a client that accepts and one that declines, assert an `isError` message. (2) The Inspector CLI against the real entry point (`npx @modelcontextprotocol/inspector --cli <command> --method tools/list`), which catches stdout pollution and startup errors. (3) For HTTP: `curl` the endpoint without a token (expect `401` with the challenge), with a wrong-audience token (expect `401`), with the right token. Snapshot `tools/list`: an accidental rename or reorder is a breaking change for every client.

## Rule: Do not build on deprecated surface
**Why:** Revision 2026-07-28 deprecates Roots, Sampling and Logging, the HTTP+SSE transport and Dynamic Client Registration, with a minimum 12-month window before removal.
**How to apply:** Do not add them to new servers. Pass directories as tool parameters (not Roots), call your model provider directly through the LLM seam (not Sampling), log to stderr or OpenTelemetry (not the Logging feature). Long-running work: the Tasks extension (`io.modelcontextprotocol/tasks`), not a blocked request.

## When to deviate

- **v1 compatibility:** Clients on protocol 2025-11-25 still exist. The v2 handler serves them through a stateless legacy fallback by default; set it to reject only if you control every client.
- **A server that must keep per-user state:** use explicit handles, a table keyed by user and handle, and expiry. Not memory.
- **One user, one machine, no auth:** a stdio server with read-only tools needs none of the HTTP rules.
