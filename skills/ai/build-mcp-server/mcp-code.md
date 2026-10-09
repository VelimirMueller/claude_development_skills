# MCP Code

Code for [build-mcp-server](./SKILL.md); reasons in [mcp-patterns.md](./mcp-patterns.md).
Tested (2026-10-09): TypeScript with `@modelcontextprotocol/server` and `client` 2.3.1, `@modelcontextprotocol/hono` 2.0.2, Zod 4.6.5, `tsc --strict`; the six tests below pass; the stdio entry answered `tools/list` and `tools/call` under the Inspector CLI 2.10.1; the HTTP entry returned `401` with a `resource_metadata` challenge, served the protected-resource metadata, rejected a foreign `Origin` with `403` and served a call with the right token. Python with `mcp` 2.3.0 ran over stdio under the Inspector, and over HTTP with the same `401` challenge and an authenticated call.

## Server (`src/server.ts`)

`createServer(auth)` builds one `McpServer` per request. The tenant comes from the verified token. The write tool asks the user to confirm through the protocol.

```ts
// src/server.ts
import { acceptedContent, createMcpHandler, inputRequired, McpServer } from '@modelcontextprotocol/server';
import type { AuthInfo } from '@modelcontextprotocol/server';
import * as z from 'zod/v4';

const MAX_RESULT_CHARS = 20_000;

type Ticket = { id: string; title: string; status: 'open' | 'closed'; tenantId: string };
const tickets: Ticket[] = [
  { id: 'T-1', title: 'Login fails', status: 'open', tenantId: 'acme' },
];

function clip(text: string): string {
  return text.length <= MAX_RESULT_CHARS
    ? text
    : `${text.slice(0, MAX_RESULT_CHARS)}\n[truncated: ${text.length - MAX_RESULT_CHARS} more characters. Narrow the query.]`;
}

export function createServer(auth?: AuthInfo): McpServer {
  const server = new McpServer({ name: 'tickets', version: '1.0.0' });
  const tenantId = auth?.clientId ?? 'acme'; // derive from the verified token, never from tool input

  server.registerTool(
    'search_tickets',
    {
      title: 'Search tickets',
      description:
        'Find support tickets by status. Returns at most 20 tickets with id, title and status. Use get_ticket for details.',
      inputSchema: z.object({
        status: z.enum(['open', 'closed']).describe('Ticket status to filter by'),
        limit: z.number().int().min(1).max(20).default(10),
      }),
      outputSchema: z.object({
        tickets: z.array(z.object({ id: z.string(), title: z.string(), status: z.string() })),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ status, limit }) => {
      const found = tickets
        .filter((t) => t.tenantId === tenantId && t.status === status)
        .slice(0, limit)
        .map(({ id, title, status }) => ({ id, title, status }));
      return {
        content: [{ type: 'text', text: clip(JSON.stringify({ tickets: found })) }],
        structuredContent: { tickets: found },
      };
    },
  );

  server.registerTool(
    'close_ticket',
    {
      title: 'Close ticket',
      description: 'Close one ticket by id. The user is asked to confirm; the call does nothing until they accept.',
      inputSchema: z.object({ id: z.string() }),
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    async ({ id }, ctx) => {
      const t = tickets.find((x) => x.id === id && x.tenantId === tenantId);
      if (!t) {
        return {
          isError: true,
          content: [{ type: 'text', text: `No ticket "${id}". Call search_tickets to list valid ids.` }],
        };
      }
      // Server-enforced human confirmation (multi round-trip request). The model cannot answer it.
      const confirmSchema = z.object({ confirm: z.boolean() });
      const answer = acceptedContent(ctx.mcpReq.inputResponses, 'confirm', confirmSchema);
      if (answer?.confirm !== true) {
        return inputRequired({
          inputRequests: { confirm: inputRequired.elicit({ message: `Close ticket ${id} ("${t.title}")?`, requestedSchema: confirmSchema }) },
        });
      }
      t.status = 'closed';
      return { content: [{ type: 'text', text: `Closed ${id}.` }] };
    },
  );
  return server;
}

export const handler = createMcpHandler((ctx) => createServer(ctx.authInfo));
```

## Streamable HTTP entry (`src/http.ts`)

Replace `verifier` with real verification (a JWT library checking issuer, audience and expiry, or token introspection). `expectedResource` makes the SDK reject tokens issued for another audience.

```ts
// src/http.ts
import { serve } from '@hono/node-server';
import type { Context } from 'hono';
import { createMcpHonoApp } from '@modelcontextprotocol/hono';
import {
  getOAuthProtectedResourceMetadataUrl,
  oauthMetadataResponse,
  OAuthError,
  OAuthErrorCode,
  requireBearerAuth,
} from '@modelcontextprotocol/server';
import type { OAuthMetadata, OAuthTokenVerifier } from '@modelcontextprotocol/server';
import { handler } from './server.js';

const PUBLIC_URL = new URL(process.env.PUBLIC_URL ?? 'http://127.0.0.1:3000/mcp');

// Replace with real JWT / introspection verification against your authorization server.
const verifier: OAuthTokenVerifier = {
  async verifyAccessToken(token) {
    if (token !== 'dev-token') throw new OAuthError(OAuthErrorCode.InvalidToken, 'Unknown token');
    return {
      token,
      clientId: 'acme',
      scopes: ['tickets:read'],
      expiresAt: Math.floor(Date.now() / 1000) + 3600,
      resource: PUBLIC_URL,
    };
  },
};

// Metadata of YOUR authorization server (Auth0, Keycloak, Entra ...). Load it from its discovery document.
const issuer = process.env.AUTH_ISSUER ?? 'https://auth.example.com';
const oauthMetadata: OAuthMetadata = {
  issuer,
  authorization_endpoint: `${issuer}/authorize`,
  token_endpoint: `${issuer}/token`,
  response_types_supported: ['code'],
  code_challenge_methods_supported: ['S256'],
};
const metadataOptions = { oauthMetadata, resourceServerUrl: PUBLIC_URL, scopesSupported: ['tickets:read'] };

const gate = requireBearerAuth({
  verifier,
  requiredScopes: ['tickets:read'],
  expectedResource: PUBLIC_URL,
  resourceMetadataUrl: getOAuthProtectedResourceMetadataUrl(PUBLIC_URL),
});

// Host + Origin validation (DNS rebinding) is on by default for localhost binds.
// Behind a public hostname, pass allowedHosts / allowedOrigins explicitly.
const app = createMcpHonoApp({ host: '127.0.0.1' });
app.get('/.well-known/*', (c: Context) => oauthMetadataResponse(c.req.raw, metadataOptions) ?? c.notFound());
app.all('/mcp', async (c: Context) => {
  const auth = await gate(c.req.raw);
  if (auth instanceof Response) return auth;
  return handler.fetch(c.req.raw, { authInfo: auth, parsedBody: c.get('parsedBody') });
});

serve({ fetch: app.fetch, port: 3000, hostname: '127.0.0.1' });
```

## stdio entry (`src/stdio.ts`)

```ts
// src/stdio.ts
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import { createServer } from './server.js';

serveStdio(() => createServer());
```

## Tests (`tests/server.test.ts`)

```ts
// tests/server.test.ts
import { Client } from '@modelcontextprotocol/client';
import { InMemoryTransport } from '@modelcontextprotocol/server';
import { describe, expect, it } from 'vitest';
import { createServer } from '../src/server.js';

async function connect(clientId: string, confirm?: boolean) {
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await createServer({ token: 't', clientId, scopes: ['tickets:read'] }).connect(serverSide);
  const client = new Client({ name: 'test', version: '1.0.0' }, { capabilities: { elicitation: { form: {} } } });
  // A real host shows this to the user. The test answers for them.
  client.setRequestHandler('elicitation/create', async () => ({ action: 'accept', content: { confirm: confirm ?? false } }));
  await client.connect(clientSide);
  return client;
}

describe('tickets server', () => {
  it('lists task-shaped tools with annotations', async () => {
    const { tools } = await (await connect('acme')).listTools();
    expect(tools.map((t) => t.name)).toEqual(['search_tickets', 'close_ticket']);
    expect(tools[0]!.annotations?.readOnlyHint).toBe(true);
    expect(tools[1]!.annotations?.destructiveHint).toBe(true);
  });
  it('returns structured content that matches the output schema', async () => {
    const r = await (await connect('acme')).callTool({ name: 'search_tickets', arguments: { status: 'open' } });
    expect(r.structuredContent).toEqual({ tickets: [{ id: 'T-1', title: 'Login fails', status: 'open' }] });
  });
  it('scopes data by the token, not by tool input', async () => {
    const r = await (await connect('other-tenant')).callTool({ name: 'search_tickets', arguments: { status: 'open' } });
    expect(r.structuredContent).toEqual({ tickets: [] });
  });
  it('closes a ticket only after the user confirms', async () => {
    const declined = await (await connect('acme', false)).callTool({ name: 'close_ticket', arguments: { id: 'T-1' } });
    expect(JSON.stringify(declined)).not.toContain('Closed T-1');
    const accepted = await (await connect('acme', true)).callTool({ name: 'close_ticket', arguments: { id: 'T-1' } });
    expect(JSON.stringify(accepted.content)).toContain('Closed T-1');
  });
  it('reports a model-actionable error', async () => {
    const r = await (await connect('acme')).callTool({ name: 'close_ticket', arguments: { id: 'T-9' } });
    expect(r.isError).toBe(true);
    expect(JSON.stringify(r.content)).toContain('Call search_tickets');
  });
  it('rejects invalid input before the handler runs', async () => {
    const r = await (await connect('acme')).callTool({ name: 'search_tickets', arguments: { status: 'bogus' } }).catch((e: unknown) => e);
    expect(r instanceof Error || (r as { isError?: boolean }).isError).toBeTruthy();
  });
});
```

## Python (`mcp` 2.x)

The same read tool with OAuth settings. Types from the Pydantic models become the input and output schemas. Run it with `python src/server.py` (Streamable HTTP, port 8000).

```python
# src/server.py
import time
from typing import Literal

from mcp.server import MCPServer
from mcp.server.auth.provider import AccessToken
from mcp.server.auth.settings import AuthSettings
from mcp.types import ToolAnnotations
from pydantic import AnyHttpUrl, BaseModel, Field

PUBLIC_URL = "http://127.0.0.1:8000/mcp"


class DevVerifier:
    """Replace with real JWT or introspection checks against your authorization server."""

    async def verify_token(self, token: str) -> AccessToken | None:
        if token != "dev-token":
            return None
        return AccessToken(token=token, client_id="acme", scopes=["tickets:read"], expires_at=int(time.time()) + 3600, resource=PUBLIC_URL)


mcp = MCPServer(
    "tickets",
    token_verifier=DevVerifier(),
    auth=AuthSettings(
        issuer_url=AnyHttpUrl("https://auth.example.com"),
        resource_server_url=AnyHttpUrl(PUBLIC_URL),
        required_scopes=["tickets:read"],
        validate_token_resource=True,
    ),
)


class Ticket(BaseModel):
    id: str
    title: str
    status: str


class SearchResult(BaseModel):
    tickets: list[Ticket]


@mcp.tool(annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False))
def search_tickets(status: Literal["open", "closed"], limit: int = Field(default=10, ge=1, le=20)) -> SearchResult:
    """Find support tickets by status. Returns at most 20 tickets with id, title and status."""
    return SearchResult(tickets=[Ticket(id="T-1", title="Login fails", status=status)][:limit])


if __name__ == "__main__":
    mcp.run("streamable-http")
```
