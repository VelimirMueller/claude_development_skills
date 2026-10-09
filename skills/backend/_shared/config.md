# Config

One rule across TypeScript, Go and Python: read the environment once at startup, validate it against a schema, and crash with the full list of what is wrong. Nothing else in the process reads the environment.
Principle: [fail fast on configuration](../../core/_shared/engineering-principles.md). Secret handling: [security-baseline.md](../../core/_shared/security-baseline.md) rule 1.

## Rule: One config module, parsed once, imported everywhere
**Why:** `process.env.X ?? ''`, `os.Getenv("X")` and `os.environ["X"]` scattered over the code give untyped strings and failures on the first request in production. One module gives a typed object, one place to read the full list of settings, and one place to fake in tests.
**How to apply:**

| Language | File | Mechanism | Entry point calls |
|---|---|---|---|
| TypeScript | `src/config.ts` | Zod 4 schema over `process.env` | `loadConfig()` in `main.ts` |
| Go | `internal/config/config.go` | `Load(lookup func(string) (string, bool))` into a struct, explicit parsing | `config.FromOS()` in `main.go` |
| Python | `src/<pkg>/config.py` | `pydantic-settings` `BaseSettings` | `get_settings()` in `main.py` |

Only the entry point (`main.ts`, `main.go`, `main.py`) calls the loader. It passes values down. Services and repositories receive what they need as arguments; they never import config.
**Anti-example:** `const url = process.env.DATABASE_URL!` inside a repository.

## Rule: Validate shape, not presence
**Why:** A set but wrong value (`PORT=eighty`, a URL without a scheme) passes a presence check and fails at use.
**How to apply:** Coerce numbers and durations, constrain enums and ranges, parse URLs. Required values have no default. Optional features are optional in the schema, not skipped in the check.

TypeScript:

```ts
const schema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']).default('info'),
  DATABASE_URL: z.url(),                       // required: no default
});
const parsed = schema.safeParse(process.env);
if (!parsed.success) throw new Error(`Invalid configuration:\n  ${parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('\n  ')}`);
```

Go (collect every error, then `errors.Join`):

```go
port, err := strconv.Atoi(get("PORT", "8080"))
if err != nil || port < 1 || port > 65535 {
	errs = append(errs, errors.New("PORT: must be an integer from 1 to 65535"))
}
// ...
return cfg, errors.Join(errs...)
```

Python:

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", frozen=True)
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    database_url: PostgresDsn            # required: no default
```

**Why (Go by hand):** The Go ecosystem has env-parsing libraries, but the standard library already does the work in about 30 lines, and an explicit `Load` function takes a lookup function, so tests pass a map and never touch `os.Setenv`.

## Rule: Errors name the key, never the value
**Why:** A value in an error message ends up in logs and CI output. A mistyped secret is still a secret.
**How to apply:** Messages say `PORT: must be an integer from 1 to 65535`. Type secrets as `SecretStr` (Python) so a stray `repr` prints `**********`. In Zod, build the message from `issue.path` and `issue.message` only, never from `issue.input` (a rejected secret would be echoed).

## Rule: Secrets come from the environment only; `.env.example` is committed
**Why:** Git history is forever. A committed `.env.example` with names and dummy values is the documentation of the contract; the real `.env` is git-ignored.
**How to apply:** Commit `.env.example` with every key, no real values, comments for non-obvious ones. `.gitignore` has `.env`. Production values come from the platform (Vercel project settings, systemd `EnvironmentFile`, Kubernetes Secret, Supabase secrets). Do not bake secrets into images.

Local loading per language:

| Language | Dev | Production |
|---|---|---|
| TypeScript | `tsx watch --env-file-if-exists=.env` (Node reads the file; no `dotenv` dependency) | platform env; `node dist/main.mjs` |
| Go | `set -a; . ./.env; set +a; go run ./cmd/<svc>` (or the task runner's dotenv support, e.g. `just` with `set dotenv-load`) | platform env |
| Python | `pydantic-settings` reads `.env` itself | platform env; `.env` is absent, real env wins |

## Rule: Same key names in all three languages
**Why:** A team that runs a TypeScript and a Go service should not relearn the variable names. Dashboards, Helm values and CI secrets reuse them.
**How to apply:** Shared keys: `DEPLOYMENT_ENVIRONMENT` (`development` | `staging` | `production`), `OTEL_SERVICE_NAME`, `LOG_LEVEL`, `PORT` (TS and Go read it; Python takes it from `fastapi run --port "${PORT:-8000}"`), `DATABASE_URL` (libpq URL form, `postgres://` or `postgresql://`), `SHUTDOWN_TIMEOUT_MS` (TS) / `SHUTDOWN_TIMEOUT` (Go duration, `10s`). OTel SDK variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, …) are read by the SDK itself, see [observability.md](../../core/_shared/observability.md).
**Note:** `NODE_ENV` is not used for behavior. `DEPLOYMENT_ENVIRONMENT` says where the process runs; build mode is a separate concern.

## When to deviate

- A serverless runtime (Cloudflare Workers) passes bindings per request, not via `process.env`: validate the bindings object with the same schema inside the entry, per request or once per isolate.
- A secret manager that injects files, not variables (Docker/Kubernetes secrets mounted at a path): read the file in the config module (`*_FILE` convention) and keep the typed object the same.
- Hot-reloaded config (feature flags): that is a flag client with its own seam, not this module.
