# API Codegen Patterns

Reference for `design-http-api`. How each track produces `openapi.json`, how the frontend turns it into types, and how the typed client sits on the existing `fetcher` seam. Every snippet here was compiled or run on 2026-10-09 (versions in [stack-versions.md](../_shared/stack-versions.md)).

## Rule: Emit the spec with a script, commit the output, gate CI on the diff
**Why:** The committed file is what reviewers read and what `oasdiff` compares. The CI diff check proves the file matches the code.
**How to apply:** one script per track writes `openapi.json` to the repo root; `.gitignore` must not list it (the Hono scaffold lists it; remove that line).

```jsonc
// package.json (TS) — backend repo
"openapi": "tsx scripts/print-openapi.ts > openapi.json",
"api:check": "pnpm openapi && git diff --exit-code openapi.json"
```

Hono: `scripts/print-openapi.ts` from `scaffold-hono-service` already does this (`app.request('/openapi.json')`, document registered with `app.doc31`). Use `doc31`, not `doc`, so the file says `3.1.0`.

FastAPI:

```python
# scripts/print_openapi.py  (run: uv run python scripts/print_openapi.py > openapi.json)
import json, sys
from svc.app import create_app
from svc.config import get_settings

json.dump(create_app(get_settings()).openapi(), sys.stdout, indent=2)
sys.stdout.write("\n")
```

## Rule: Name operations and fields for the client, not for the framework
**Why:** The client method name is the `operationId`. FastAPI's default (`list_orders_orders_get`) and a missing id in Hono produce unreadable calls. JSON is `camelCase` for the frontend; Python models are `snake_case`.
**How to apply:**
- Hono: `operationId: 'listOrders'` in every `createRoute`.
- FastAPI: one function sets ids from route names, one base model sets camel aliases.

```python
from fastapi import FastAPI
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel

def operation_id(route: APIRoute) -> str:
    return route.name              # function name: list_orders -> operationId "list_orders"

class ApiModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)

app = FastAPI(generate_unique_id_function=operation_id)
```

openapi-fetch addresses operations by path and method, so the id matters for docs, other generators and `oasdiff` output, not for this client's call sites. Keep it stable: renaming it is a breaking change for generators that use it.

## Rule: FastAPI error responses must be declared as `application/problem+json` with the schema
**Why:** `responses={404: {"model": Problem}}` documents the error as `application/json`; the server sends `application/problem+json`. Declaring `content={"application/problem+json": {}}` next to it gives an empty schema, and the generated client types the error as `unknown` (verified). Post-process once, in the OpenAPI function, so every route stays a one-liner.
**How to apply:**

```python
def problem_json_media_type(schema: dict) -> dict:
    """`model=` error responses are documented as application/json; ours are problem+json."""
    for path in schema["paths"].values():
        for op in path.values():
            if not isinstance(op, dict):
                continue  # path items also hold non-operation keys (parameters, summary)
            for status, resp in op["responses"].items():
                content = resp.get("content", {})
                if status.isdigit() and int(status) >= 400 and "application/json" in content:
                    content["application/problem+json"] = content.pop("application/json")
    return schema

def install_openapi(app: FastAPI) -> None:
    def custom_openapi() -> dict:
        if app.openapi_schema is None:
            app.openapi_schema = problem_json_media_type(FastAPI.openapi(app))
        return app.openapi_schema
    app.openapi = custom_openapi  # type: ignore[method-assign]
```

Call `install_openapi(app)` in `create_app`. Routes declare `responses={404: {"model": Problem}}` with no `content`. The generated type is then `components["schemas"]["Problem"]`.

## Rule: Go is spec-first with `oapi-codegen`, strict server, request validation in middleware
**Why:** `oapi-codegen` 2.8 supports OpenAPI 3.1 (`type: [string, "null"]` becomes `*string`). The strict server turns each operation into one typed method (`ListOrders(ctx, ListOrdersRequestObject) (ListOrdersResponseObject, error)`), so a response that is not in the spec does not compile. The generated code binds and type-checks parameters but does **not** enforce `minimum`/`maximum`/`pattern`; the `nethttp-middleware` request validator does (verified: `limit=0` against `minimum: 1` returned 400).
**How to apply:**

```yaml
# oapi-codegen.yaml
package: api
output: internal/transport/httpapi/api.gen.go
generate:
  std-http-server: true     # net/http ServeMux, matches the scaffold
  strict-server: true
  models: true
  embedded-spec: true       # GetSwagger() feeds the validator
```

```go
// internal/transport/httpapi/generate.go
package httpapi

//go:generate go tool oapi-codegen -config ../../../oapi-codegen.yaml ../../../openapi.yaml
```

Install the tool with `go get -tool github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@<version>` (Go 1.24+ `tool` directive: version pinned in `go.mod`, no `tools.go`). Mounting, with problem+json for both binding and validation failures:

```go
spec, err := GetSwagger()
if err != nil { return nil, err }
spec.Servers = nil // otherwise the validator also checks the Host header
validate := nethttpmw.OapiRequestValidatorWithOptions(spec, &nethttpmw.Options{
	ErrorHandlerWithOpts: func(_ context.Context, err error, w http.ResponseWriter, r *http.Request, o nethttpmw.ErrorHandlerOpts) {
		writeProblem(w, r, o.StatusCode, err.Error()) // the scaffold's helper: same body shape
	},
})
strict := NewStrictHandlerWithOptions(svc, nil, StrictHTTPServerOptions{
	RequestErrorHandlerFunc:  func(w http.ResponseWriter, r *http.Request, err error) { writeProblem(w, r, http.StatusBadRequest, err.Error()) },
	ResponseErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) { /* log, then */ writeProblem(w, r, http.StatusInternalServerError, "") },
})
return HandlerWithOptions(strict, StdHTTPServerOptions{
	BaseRouter:       http.NewServeMux(),
	Middlewares:      []MiddlewareFunc{validate},
	ErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) { writeProblem(w, r, http.StatusBadRequest, err.Error()) },
})
```

`ErrorHandlerFunc` in `StdHTTPServerOptions` handles parameter binding errors; `RequestErrorHandlerFunc` in the strict options handles body decoding. Both default to plain text, which breaks the problem+json rule. Set both.
**Anti-example:** `HandlerFromMux(strict, mux)` with no options: binding errors come back as `text/plain`.

## Rule: Frontend types come from the committed spec file, not from a running server
**Why:** `openapi-typescript http://localhost:3000/openapi.json` needs a running backend and breaks offline and in CI. A file path is deterministic.
**How to apply:** if the spec lives in the same repo: `"api:types": "openapi-typescript openapi.json -o src/api/schema.d.ts"` and commit `schema.d.ts`. If the backend is another repo: copy the file in a scheduled sync PR, or generate from a pinned raw URL of a tagged commit. `api:check`: `pnpm api:types && git diff --exit-code src/api/schema.d.ts`.

## Wire into the fetcher seam

`openapi-fetch` calls `fetch(Request)` and returns `{ data, error, response }`. The frontend `fetcher` returns parsed JSON and throws, so it cannot be passed as `fetch`. Split the seam in two layers: a raw layer that returns a `Response` and owns credentials, CSRF and the 401 refresh, and `fetcher` on top of it. The typed client then uses the raw layer, and nothing is duplicated.

Add to `src/libs/fetcher.ts` (auth version; it reuses that file's `buildHeaders` and `refreshSession`):

```ts
// Raw layer: same credentials, CSRF header and single 401 refresh as fetcher(), but returns the Response.
export async function fetchRaw(input: Request): Promise<Response> {
  const send = (req: Request) =>
    fetch(new Request(req, { credentials: 'include', headers: buildHeaders({ method: req.method, headers: req.headers }) }));
  const res = await send(input.clone()); // a Request body can be read once; keep the original for the retry
  if (res.status === 401 && (await refreshSession())) return send(input);
  return res;
}
```

Base version (no auth): drop `credentials`, `refreshSession` and the 401 branch: `fetch(new Request(input, { headers: buildHeaders({ method: input.method, headers: input.headers }) }))`. Once `fetchRaw` exists, the 401 retry in `fetcher()` can call it too, so there is one refresh path; that edit belongs to the frontend `fetcher.md` owner.

```ts
// src/libs/api-client.ts
import createClient from 'openapi-fetch';
import type { components, paths } from '@/api/schema';
import { env } from '@/libs/env';
import { fetchRaw } from '@/libs/fetcher';

export type Problem = components['schemas']['Problem'];

export class ApiProblem extends Error {
  readonly problem: Problem;
  constructor(problem: Problem) {
    super(problem.detail ?? problem.title);
    this.name = 'ApiProblem';
    this.problem = problem;
  }
}

export const api = createClient<paths>({ baseUrl: env.VITE_API_URL, fetch: fetchRaw });

/** { data, error } -> value, or throw ApiProblem. TanStack Query needs a throw to enter its error state. */
export function unwrap<T>(result: { data?: T; error?: Problem }): T {
  if (result.error) throw new ApiProblem(result.error);
  return result.data as T;
}
```

Use it in a query function, the only place server data is fetched (server data lives in the Query cache, see the frontend state rules):

```ts
useQuery({
  queryKey: queryKeys.orders.list({ limit }),
  queryFn: async () => unwrap(await api.GET('/orders', { params: { query: { limit } } })),
});
```

Verified: a wrong query param type fails `tsc`; a `400 application/problem+json` response arrives as a typed `error` (`error.title`). Network errors still throw from `fetch`; handle both through the error boundary.
**Why `unwrap` over `throwOnError`:** openapi-fetch 0.17 has no `throwOnError` option; the discriminated result is the library's design. One 5-line helper keeps it.
**Why not wrap `api` in `fetcher`:** `fetcher<T>(path)` takes a path string, so every call would lose its path and parameter types, which is the point of generating the client.

## When to deviate

- The frontend does not use TanStack Query: still use `unwrap`, and let the caller handle `ApiProblem`.
- Server-rendered frontends (Nuxt, Next.js): create the client per request on the server with the request's cookies; `fetchRaw` above assumes a browser.
- A very large spec (thousands of operations): `openapi-typescript` stays fast; split the document only if reviewers cannot read it.
- Orval or Hey API instead of `openapi-typescript`: pick one only if you want generated hooks or runtime validation; both add generated code to review. Not verified here.
