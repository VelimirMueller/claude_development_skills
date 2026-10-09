# Go Service: File Contents

Canonical contents for [SKILL.md](SKILL.md). Every file here ran clean on 2026-10-09 (`gofmt -l`, `go vet`, `go test`, `golangci-lint run` = 0 issues, a live `curl` and SIGTERM check) on Go 1.27.1 and golangci-lint 2.14.0. Replace the module path `example.com/svc` and the command name `svc`. The `notes` module is a worked example of the layering: delete it once a real module exists.

## `go.mod`

```
module example.com/svc

go 1.27.1
```

## `.golangci.yml`

```yaml
version: "2"

run:
  timeout: 5m

linters:
  default: standard        # errcheck, govet, ineffassign, staticcheck, unused
  enable:
    - bodyclose
    - contextcheck
    - errorlint
    - gosec
    - noctx
    - sloglint
    - misspell
    - unconvert
  settings:
    sloglint:
      no-global: all       # pass *slog.Logger explicitly
      context: scope       # use *Context methods when a ctx is in scope
      attr-only: false
  exclusions:
    presets:
      - comments
      - std-error-handling
    rules:
      - path: _test\.go
        linters: [gosec]

formatters:
  enable:
    - gofmt
    - goimports
```

## `.env.example`

```bash
DEPLOYMENT_ENVIRONMENT=development
OTEL_SERVICE_NAME=svc
PORT=8080
LOG_LEVEL=info
SHUTDOWN_TIMEOUT=10s
# DATABASE_URL=postgres://user:password@localhost:5432/app
```

## `internal/config/config.go`

```go
// Package config loads and validates the process environment once, at startup.
package config

import (
	"errors"
	"log/slog"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Environment     string // development, staging or production
	ServiceName     string
	Port            int
	LogLevel        slog.Level
	ShutdownTimeout time.Duration
	// Add required secrets as fields without defaults, e.g. DatabaseURL string.
}

// Load reads configuration through lookup (use os.LookupEnv in main).
// It reports every invalid key at once and never includes values in errors.
func Load(lookup func(string) (string, bool)) (Config, error) {
	var errs []error
	get := func(key, def string) string {
		if v, ok := lookup(key); ok && v != "" {
			return v
		}
		return def
	}

	cfg := Config{
		Environment: get("DEPLOYMENT_ENVIRONMENT", "development"),
		ServiceName: get("OTEL_SERVICE_NAME", "svc"),
	}
	switch cfg.Environment {
	case "development", "staging", "production":
	default:
		errs = append(errs, errors.New("DEPLOYMENT_ENVIRONMENT: must be development, staging or production"))
	}

	port, err := strconv.Atoi(get("PORT", "8080"))
	if err != nil || port < 1 || port > 65535 {
		errs = append(errs, errors.New("PORT: must be an integer from 1 to 65535"))
	}
	cfg.Port = port

	if err := cfg.LogLevel.UnmarshalText([]byte(get("LOG_LEVEL", "info"))); err != nil {
		errs = append(errs, errors.New("LOG_LEVEL: must be debug, info, warn or error"))
	}

	d, err := time.ParseDuration(get("SHUTDOWN_TIMEOUT", "10s"))
	if err != nil || d <= 0 {
		errs = append(errs, errors.New("SHUTDOWN_TIMEOUT: must be a positive duration such as 10s"))
	}
	cfg.ShutdownTimeout = d

	return cfg, errors.Join(errs...)
}

// FromOS is Load bound to the real environment.
func FromOS() (Config, error) { return Load(os.LookupEnv) }
```

## `internal/config/config_test.go`

```go
package config_test

import (
	"strings"
	"testing"

	"example.com/svc/internal/config"
)

func lookup(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestDefaults(t *testing.T) {
	cfg, err := config.Load(lookup(nil))
	if err != nil || cfg.Port != 8080 {
		t.Fatalf("cfg=%+v err=%v", cfg, err)
	}
}

func TestReportsEveryInvalidKey(t *testing.T) {
	_, err := config.Load(lookup(map[string]string{"PORT": "x", "LOG_LEVEL": "loud"}))
	if err == nil || !strings.Contains(err.Error(), "PORT") || !strings.Contains(err.Error(), "LOG_LEVEL") {
		t.Fatalf("err = %v", err)
	}
}
```

## `internal/platform/logging/logging.go`

```go
// Package logging builds the process-wide structured logger.
// The field names follow core/_shared/logging-contract.md.
package logging

import (
	"io"
	"log/slog"
	"strings"
)

var redacted = map[string]bool{
	"authorization": true, "cookie": true, "set-cookie": true,
	"password": true, "token": true, "secret": true, "api_key": true,
}

// New returns a JSON logger. Pass it down explicitly; do not use the global slog default.
func New(w io.Writer, level slog.Level, service, environment string) *slog.Logger {
	h := slog.NewJSONHandler(w, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 {
				switch a.Key {
				case slog.TimeKey:
					a.Key = "timestamp"
				case slog.MessageKey:
					a.Key = "message"
				case slog.LevelKey:
					a.Value = slog.StringValue(strings.ToLower(a.Value.String()))
				}
			}
			if redacted[strings.ToLower(a.Key)] {
				a.Value = slog.StringValue("[redacted]")
			}
			return a
		},
	})
	return slog.New(h).With("service.name", service, "deployment.environment.name", environment)
}
```

## `internal/platform/logging/logging_test.go`

```go
package logging_test

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"testing"

	"example.com/svc/internal/platform/logging"
)

func TestContractFields(t *testing.T) {
	var buf bytes.Buffer
	logging.New(&buf, slog.LevelInfo, "svc", "development").Info("hello", "token", "s3cret")

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"timestamp", "level", "message", "service.name", "deployment.environment.name"} {
		if _, ok := got[k]; !ok {
			t.Errorf("missing field %q in %v", k, got)
		}
	}
	if got["level"] != "info" || got["token"] != "[redacted]" {
		t.Errorf("level=%v token=%v", got["level"], got["token"])
	}
}
```

## `internal/repository/notes.go`

```go
// Package repository is the only layer that talks to storage.
package repository

import (
	"context"
	"errors"
)

var ErrNotFound = errors.New("not found")

type Note struct {
	ID   string `json:"id"`
	Body string `json:"body"`
}

// NotesMemory is a stand-in. Replace it with a sqlc-backed implementation behind the same method set.
type NotesMemory struct{ rows map[string]Note }

func NewNotesMemory(seed ...Note) *NotesMemory {
	m := &NotesMemory{rows: make(map[string]Note, len(seed))}
	for _, n := range seed {
		m.rows[n.ID] = n
	}
	return m
}

func (m *NotesMemory) FindByID(ctx context.Context, id string) (Note, error) {
	if err := ctx.Err(); err != nil {
		return Note{}, err
	}
	n, ok := m.rows[id]
	if !ok {
		return Note{}, ErrNotFound
	}
	return n, nil
}
```

## `internal/service/notes.go`

```go
// Package service holds use cases. It imports no net/http types.
package service

import (
	"context"
	"errors"
	"fmt"

	"example.com/svc/internal/repository"
)

// ErrNoteNotFound is the domain error the transport layer maps to 404.
var ErrNoteNotFound = errors.New("note not found")

// NoteStore is defined here, where it is used, so tests can fake it.
type NoteStore interface {
	FindByID(ctx context.Context, id string) (repository.Note, error)
}

type Notes struct{ store NoteStore }

func NewNotes(store NoteStore) *Notes { return &Notes{store: store} }

func (s *Notes) Get(ctx context.Context, id string) (repository.Note, error) {
	n, err := s.store.FindByID(ctx, id)
	switch {
	case errors.Is(err, repository.ErrNotFound):
		return repository.Note{}, fmt.Errorf("note %q: %w", id, ErrNoteNotFound)
	case err != nil:
		return repository.Note{}, fmt.Errorf("find note: %w", err)
	}
	return n, nil
}
```

## `internal/transport/httpapi/problem.go`

```go
package httpapi

import (
	"encoding/json"
	"net/http"
)

// Problem is an RFC 9457 problem details object.
type Problem struct {
	Type     string `json:"type"`
	Title    string `json:"title"`
	Status   int    `json:"status"`
	Detail   string `json:"detail,omitempty"`
	Instance string `json:"instance,omitempty"`
}

func writeProblem(w http.ResponseWriter, r *http.Request, status int, detail string) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	// An encode error means the client went away; the status line is already sent.
	_ = json.NewEncoder(w).Encode(Problem{
		Type:     "about:blank",
		Title:    http.StatusText(status),
		Status:   status,
		Detail:   detail,
		Instance: r.URL.Path,
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
```

## `internal/transport/httpapi/server.go`

```go
// Package httpapi is the transport layer: routing, decoding, status codes.
package httpapi

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	"example.com/svc/internal/repository"
	"example.com/svc/internal/service"
)

// NotesService is what the handlers need. The concrete *service.Notes satisfies it.
type NotesService interface {
	Get(ctx context.Context, id string) (repository.Note, error)
}

// ReadinessCheck reports whether one dependency is reachable.
type ReadinessCheck struct {
	Name  string
	Check func(ctx context.Context) error
}

type Deps struct {
	Log    *slog.Logger
	Notes  NotesService
	Checks []ReadinessCheck
}

type API struct {
	deps     Deps
	draining atomic.Bool
}

func New(deps Deps) *API { return &API{deps: deps} }

// Drain makes /readyz fail so the load balancer stops sending traffic before Shutdown.
func (a *API) Drain() { a.draining.Store(true) }

// Handler wires routes with Go 1.22+ method and wildcard patterns.
func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.live)
	mux.HandleFunc("GET /readyz", a.ready)
	mux.HandleFunc("GET /notes/{id}", a.getNote)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeProblem(w, r, http.StatusNotFound, "")
	})
	return a.recoverer(a.accessLog(mux))
}

func (a *API) live(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *API) ready(w http.ResponseWriter, r *http.Request) {
	if a.draining.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	for _, c := range a.deps.Checks {
		if err := c.Check(ctx); err != nil {
			a.deps.Log.WarnContext(r.Context(), "readiness check failed", "check", c.Name, "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *API) getNote(w http.ResponseWriter, r *http.Request) {
	n, err := a.deps.Notes.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, n)
}

// fail is the single place where domain errors become HTTP statuses.
func (a *API) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrNoteNotFound):
		writeProblem(w, r, http.StatusNotFound, err.Error())
	default:
		a.deps.Log.ErrorContext(r.Context(), "unhandled error", "err", err, "url.path", r.URL.Path)
		writeProblem(w, r, http.StatusInternalServerError, "")
	}
}

func (a *API) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		defer func() {
			if v := recover(); v != nil {
				a.deps.Log.ErrorContext(ctx, "panic", "panic", fmt.Sprint(v), "url.path", r.URL.Path)
				writeProblem(w, r, http.StatusInternalServerError, "")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (a *API) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		a.deps.Log.InfoContext(r.Context(), "request",
			"http.request.method", r.Method, "url.path", r.URL.Path,
			"http.response.status_code", rec.status,
			"duration_ms", time.Since(start).Milliseconds())
	})
}
```

## `internal/transport/httpapi/server_test.go`

```go
package httpapi_test

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"example.com/svc/internal/repository"
	"example.com/svc/internal/service"
	"example.com/svc/internal/transport/httpapi"
)

func newAPI(checks ...httpapi.ReadinessCheck) *httpapi.API {
	store := repository.NewNotesMemory(repository.Note{ID: "1", Body: "hi"})
	return httpapi.New(httpapi.Deps{
		Log:    slog.New(slog.DiscardHandler),
		Notes:  service.NewNotes(store),
		Checks: checks,
	})
}

func do(t *testing.T, api *httpapi.API, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	api.Handler().ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, path, nil))
	return rec
}

func TestHealth(t *testing.T) {
	if got := do(t, newAPI(), "/healthz").Code; got != http.StatusOK {
		t.Fatalf("healthz = %d", got)
	}
}

func TestReadyFailsWhenDependencyDown(t *testing.T) {
	down := httpapi.ReadinessCheck{Name: "db", Check: func(context.Context) error { return errors.New("down") }}
	if got := do(t, newAPI(down), "/readyz").Code; got != http.StatusServiceUnavailable {
		t.Fatalf("readyz = %d", got)
	}
}

func TestReadyFailsWhileDraining(t *testing.T) {
	api := newAPI()
	api.Drain()
	if got := do(t, api, "/readyz").Code; got != http.StatusServiceUnavailable {
		t.Fatalf("readyz = %d", got)
	}
}

func TestMissingNoteIsProblemJSON(t *testing.T) {
	rec := do(t, newAPI(), "/notes/nope")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/problem+json") {
		t.Fatalf("content-type = %q", ct)
	}
}

func TestGetNote(t *testing.T) {
	rec := do(t, newAPI(), "/notes/1")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"body":"hi"`) {
		t.Fatalf("got %d %s", rec.Code, rec.Body.String())
	}
}
```

## `cmd/svc/main.go`

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"example.com/svc/internal/config"
	"example.com/svc/internal/platform/logging"
	"example.com/svc/internal/repository"
	"example.com/svc/internal/service"
	"example.com/svc/internal/transport/httpapi"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.FromOS()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}
	log := logging.New(os.Stdout, cfg.LogLevel, cfg.ServiceName, cfg.Environment)

	api := httpapi.New(httpapi.Deps{
		Log:   log,
		Notes: service.NewNotes(repository.NewNotesMemory(repository.Note{ID: "1", Body: "hello"})),
		// Checks: []httpapi.ReadinessCheck{{Name: "db", Check: pool.Ping}},
	})

	// ctx is cancelled on SIGINT/SIGTERM; every request context derives from it.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := &http.Server{
		Addr:              net.JoinHostPort("", strconv.Itoa(cfg.Port)),
		Handler:           api.Handler(),
		BaseContext:       func(net.Listener) context.Context { return ctx },
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", srv.Addr)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("serve: %w", err)
	case <-ctx.Done():
	}

	log.Info("shutting down")
	api.Drain()
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("shutdown: %w", err)
	}
	// Close pools and flush telemetry here, after the server has drained.
	return nil
}
```
