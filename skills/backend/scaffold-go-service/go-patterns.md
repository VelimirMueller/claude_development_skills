# Go Service Patterns

Reference for [scaffold-go-service](SKILL.md). Each rule was checked against the scaffold in [go-files.md](go-files.md) on 2026-10-09 (Go 1.27.1, golangci-lint 2.14.0).

## Rule: stdlib `net/http` and `ServeMux` first
**Why:** Since Go 1.22 the standard mux matches method and path wildcards (`mux.HandleFunc("GET /notes/{id}", …)`, `r.PathValue("id")`). That covers most services, adds no dependency and gets security fixes with the toolchain. A router library earns its place only when you need something the mux lacks.
**How to apply:** One `Handler()` method builds the mux and wraps it with middleware (`recoverer`, `accessLog`). Routes read as a table of `METHOD /path`. Add a catch-all `"/"` handler to answer 404 as problem+json, because the mux's default 404 is plain text.
**Anti-example:** Pulling in a web framework for three routes.
**When to deviate:** Use `chi` (v5, stdlib-compatible `http.Handler`) when you need route groups with per-group middleware, or when the repo already uses it. Keep handlers as plain `http.HandlerFunc` so the swap stays mechanical.

## Rule: `cmd/<svc>/main.go` is a thin composition root; code lives in `internal/`
**Why:** `internal/` cannot be imported from outside the module, so the service's packages are not accidentally a public API. `main` that only wires and starts is the one place that knows every concrete type.
**How to apply:** `main()` calls `run() error` and prints one `fatal:` line on failure. `run` loads config, builds the logger, repositories, services and the HTTP API, then serves and shuts down. Every other package takes its dependencies as arguments ([service-layout.md](../_shared/service-layout.md)).
**When to deviate:** A library module that also ships a binary: put the public packages at the module root and keep the binary in `cmd/`.

## Rule: Interfaces live where they are used
**Why:** A Go interface is satisfied implicitly. Defining it in the consumer (the service's `NoteStore`, the transport's `NotesService`) keeps it small, shaped by one caller's need, and fakeable without importing the producer.
**How to apply:** The repository exports a concrete type; the service declares the 1 to 3 methods it calls. Return concrete types, accept interfaces.
**Anti-example:** A `repository.Repository` interface with twelve methods declared next to the implementation.

## Rule: Config is parsed once, with explicit code
**Why:** See [config.md](../_shared/config.md). `Load(lookup)` takes a lookup function so tests pass a map and never call `os.Setenv`. All invalid keys are reported together with `errors.Join`; values never appear in errors.
**How to apply:** `config.FromOS()` in `main`. Required values have no default. Durations use `time.ParseDuration`; the log level uses `slog.Level.UnmarshalText`.

## Rule: `log/slog` with JSON, contract field names, explicit logger
**Why:** `slog` is in the standard library and structured. The fixed field names (`timestamp`, `level`, `message`, `service.name`, `deployment.environment.name`) make one query work across TypeScript, Go and Python ([logging-contract.md](../../core/_shared/logging-contract.md)). A logger passed as a value has no hidden global state.
**How to apply:** `logging.New(w, level, service, env)` renames the built-in keys in `ReplaceAttr`, lowercases the level and redacts sensitive keys. Log with the `*Context` methods (`InfoContext(ctx, …)`) so a trace handler can add `trace_id`. HTTP fields use OTel names: `http.request.method`, `url.path`, `http.response.status_code`. Log an error once, where it is handled.
**Lint:** `sloglint` with `no-global: all` and `context: scope` fails the build on `slog.Info(...)` and on a missing `*Context` call.

## Rule: One place turns domain errors into HTTP, as problem+json
**Why:** RFC 9457 gives clients one error shape (`application/problem+json` with `type`, `title`, `status`, `detail`, `instance`). A single `fail` function means a new domain error is one `case`, and no handler invents its own status.
**How to apply:** Services return wrapped sentinel errors (`fmt.Errorf("note %q: %w", id, ErrNoteNotFound)`). `fail` uses `errors.Is` to choose the status; the default branch logs and returns a 500 with no detail. The `recoverer` middleware turns a panic into the same 500. Check with `errors.Is`/`errors.As`, never `==` ( `errorlint` enforces it).
**Anti-example:** Returning `err.Error()` of an unknown error to the client: leaks SQL and paths ([security-baseline.md](../../core/_shared/security-baseline.md)).

## Rule: Liveness and readiness are separate, and readiness drains
**Why:** A load balancer that restarts a pod because the database is slow turns a blip into an outage. During shutdown, traffic must stop before connections close.
**How to apply:** `/healthz` returns 200 and checks nothing. `/readyz` runs each `ReadinessCheck` with a 2 s context and returns 503 on the first failure, or after `Drain()` was called. `main` calls `Drain()` on SIGTERM, then `srv.Shutdown`.
**When to deviate:** On Kubernetes, add a short `preStop` sleep so endpoints update before the process stops listening.

## Rule: Graceful shutdown: signal context, `Shutdown` with a deadline
**Why:** `signal.NotifyContext` gives one context that is cancelled on SIGINT or SIGTERM; `http.Server.Shutdown` stops accepting and waits for in-flight requests; a deadline stops a stuck request from blocking exit forever.
**How to apply:** `BaseContext` returns the signal context, so long handlers see cancellation. Shutdown uses `context.WithTimeout(context.WithoutCancel(ctx), cfg.ShutdownTimeout)`: the parent is already cancelled, so derive from `WithoutCancel`. Set `ReadHeaderTimeout` and `IdleTimeout` on the server; `gosec` flags a server without them.
**When to deviate:** A server with long-lived streams (SSE, WebSocket): add `srv.RegisterOnShutdown` to close them.

## Rule: Context flows from the request to the query
**Why:** A client that disconnects should cancel the database call. A context dropped in the middle leaves work running for nobody.
**How to apply:** `ctx` is the first parameter of every function that does I/O. Handlers pass `r.Context()`. Never store a context in a struct. `noctx` flags HTTP requests built without one; `contextcheck` flags calls that drop it. In tests use `t.Context()` (Go 1.24+).

## Rule: golangci-lint v2: `default: standard` plus a short enable list
**Why:** v2 configs start with `version: "2"`; v1 files fail to load. `standard` brings `errcheck`, `govet`, `ineffassign`, `staticcheck`, `unused`. The extra linters each catch a real class of bug in a service: `bodyclose`, `noctx`, `contextcheck` (leaked contexts and bodies), `errorlint` (wrapped errors), `gosec` (server timeouts, unsafe patterns), `sloglint` (logger discipline), `misspell`, `unconvert`.
**How to apply:** `.golangci.yml` from [go-files.md](go-files.md); run `golangci-lint config verify` then `golangci-lint run ./...`. Formatters (`gofmt`, `goimports`) are listed under `formatters:`; `golangci-lint fmt` applies them. Pin the version in CI and re-verify it ([stack-versions.md](../_shared/stack-versions.md)).
**Anti-example:** `default: all` and then a long disable list: every upgrade adds new failures.
**When to deviate:** Turn off a linter for `_test.go` only (the scaffold excludes `gosec` there); never repo-wide to get green.

## Rule: Tests beside the code, black-box, with `httptest`
**Why:** `go test` is per package. `package httpapi_test` tests the exported surface the way a caller sees it. `httptest.NewRecorder` runs the full handler chain in-process.
**How to apply:** Build the API with in-memory repositories; assert status, content type and body. A real Postgres via `testcontainers-go` (`modules/postgres`) belongs in integration tests under `tests/` behind a build tag or `-short` skip.
**When to deviate:** White-box tests for unexported logic stay in the same package, in a separate file.

## When to deviate

- Needs gRPC or Connect next to HTTP: add the server in `transport/` as a second adapter; the service and repository stay.
- Needs OpenAPI-first: write `openapi.yaml` and generate server stubs with `oapi-codegen`, and keep the layers behind the generated interface.
- Needs a database: add `sqlc` with `pgx` (`pgxpool`) under `internal/repository/`; `db.Ping` becomes a readiness check ([stack-versions.md](../_shared/stack-versions.md)).
