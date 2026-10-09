# CLI Examples

Reference for `build-cli`: one tested implementation per language of the same tiny CLI (`mycli list`, `mycli delete <id>`), following [cli-ux.md](cli-ux.md) and the structure rules in [cli-patterns.md](cli-patterns.md). Each was compiled, linted, tested and run on 2026-10-09 against the versions in [stack-versions.md](../_shared/stack-versions.md). Copy the shape, rename `mycli`, replace the fake `list`/`delete` domain.

Contract all four share: data on stdout, diagnostics on stderr, `--json` prints `{"schema":1,"items":[...]}`, exit codes 0 ok / 1 failure / 2 usage / 3 not found, config precedence flags > env > `.mycli.toml` > user file > defaults, `--dry-run`, `NO_COLOR`.

## TypeScript (commander 15, Node >= 22.18, ESM)

Node runs `.ts` files directly (type stripping), so `node src/cli.ts` is the dev loop and `erasableSyntaxOnly` keeps it honest: no `enum`, no constructor parameter properties, no `namespace`. Imports use the `.ts` extension. Build with `tsdown` to `dist/cli.mjs` (it keeps the `#!/usr/bin/env node` line and sets the executable bit).

**`package.json`**

```json
{
  "name": "mycli",
  "version": "0.1.0",
  "type": "module",
  "bin": { "mycli": "./dist/cli.mjs" },
  "files": ["dist"],
  "engines": { "node": ">=22.18" },
  "dependencies": {
    "@clack/prompts": "^1.8.1",
    "commander": "^15.0.0",
    "env-paths": "^4.0.0",
    "smol-toml": "^1.9.0"
  },
  "devDependencies": {
    "@types/node": "^26.6.4",
    "tsdown": "~0.23.0",
    "typescript": "~7.0.2",
    "vitest": "~5.0.3"
  }
}
```

Runtime libraries go in `dependencies`; tsdown leaves those external and bundles everything in `devDependencies`. Putting commander in `devDependencies` inlines 140 kB into the bundle and hides it from `npm audit` consumers.

**`src/exit.ts`**

```ts
/** Exit codes are public API. Document them in --help and README. */
export const Exit = { ok: 0, failure: 1, usage: 2, notFound: 3 } as const;
export type ExitCode = (typeof Exit)[keyof typeof Exit];

/** Throw this for expected failures; the entry point turns it into a message + exit code. */
export class CliError extends Error {
  readonly code: ExitCode;
  readonly hint: string | undefined;

  constructor(message: string, code: ExitCode = Exit.failure, hint?: string) {
    super(message);
    this.name = 'CliError';
    this.code = code;
    this.hint = hint;
  }
}
```

**`src/output.ts`**

```ts
import { styleText } from 'node:util';

const env = process.env;
const useColor =
  !('NO_COLOR' in env && env.NO_COLOR !== '') &&
  env.TERM !== 'dumb' &&
  (env.FORCE_COLOR ? env.FORCE_COLOR !== '0' : process.stderr.isTTY === true);

export const isInteractive = process.stdin.isTTY === true && process.stdout.isTTY === true && !env.CI;

const paint = (format: Parameters<typeof styleText>[0], text: string) =>
  useColor ? styleText(format, text) : text;

/** Data goes to stdout. Nothing else may write there. */
export function data(value: unknown, json: boolean): void {
  process.stdout.write(json ? `${JSON.stringify(value)}\n` : `${String(value)}\n`);
}

/** Diagnostics go to stderr, so `mycli list | jq` stays clean. */
export const log = {
  info: (msg: string) => process.stderr.write(`${msg}\n`),
  warn: (msg: string) => process.stderr.write(`${paint('yellow', 'warning:')} ${msg}\n`),
  error: (msg: string, hint?: string) => {
    process.stderr.write(`${paint('red', 'error:')} ${msg}\n`);
    if (hint) process.stderr.write(`${paint('dim', `hint: ${hint}`)}\n`);
  },
};
```

**`src/config.ts`**

```ts
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import envPaths from 'env-paths';
import { parse } from 'smol-toml';
import { CliError, Exit } from './exit.ts';

export interface Config {
  endpoint: string;
  timeoutMs: number;
}

const defaults: Config = { endpoint: 'https://api.example.com', timeoutMs: 10_000 };

function readToml(path: string): Partial<Config> {
  if (!existsSync(path)) return {};
  try {
    const raw = parse(readFileSync(path, 'utf8'));
    return {
      ...(typeof raw.endpoint === 'string' && { endpoint: raw.endpoint }),
      ...(typeof raw.timeout_ms === 'number' && { timeoutMs: raw.timeout_ms }),
    };
  } catch (cause) {
    throw new CliError(`Cannot parse ${path}: ${(cause as Error).message}`, Exit.usage);
  }
}

/** Precedence: flags > env > project file > user file (XDG) > defaults. */
export function loadConfig(flags: Partial<Config>, cwd = process.cwd()): Config {
  const userFile = join(envPaths('mycli', { suffix: '' }).config, 'config.toml');
  const fromEnv: Partial<Config> = {
    ...(process.env.MYCLI_ENDPOINT && { endpoint: process.env.MYCLI_ENDPOINT }),
    ...(process.env.MYCLI_TIMEOUT_MS && { timeoutMs: Number(process.env.MYCLI_TIMEOUT_MS) }),
  };
  const merged = {
    ...defaults,
    ...readToml(userFile),
    ...readToml(join(cwd, '.mycli.toml')),
    ...fromEnv,
    ...flags,
  };
  if (!Number.isFinite(merged.timeoutMs) || merged.timeoutMs <= 0)
    throw new CliError(`timeout must be a positive number, got ${merged.timeoutMs}`, Exit.usage);
  return merged;
}
```

**`src/cli.ts`**

```ts
#!/usr/bin/env node
import { Command, CommanderError, InvalidArgumentError } from 'commander';
import { loadConfig } from './config.ts';
import { CliError, Exit } from './exit.ts';
import { data, log } from './output.ts';

const VERSION = '0.1.0';

const positiveInt = (value: string): number => {
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) throw new InvalidArgumentError('must be a positive integer.');
  return n;
};

export function buildProgram(): Command {
  const program = new Command('mycli')
    .description('Manage widgets.')
    .version(VERSION)
    .option('--json', 'machine-readable output on stdout')
    .option('--endpoint <url>', 'API endpoint (env: MYCLI_ENDPOINT)')
    .showHelpAfterError('(run with --help for usage)')
    .addHelpText(
      'after',
      '\nExit codes:\n  0 ok   1 failure   2 usage error   3 not found',
    )
    // Throw instead of process.exit so tests and the entry point control exit.
    .exitOverride();

  program
    .command('list')
    .description('List widgets.')
    .option('-n, --limit <n>', 'max rows', positiveInt, 20)
    .action((opts: { limit: number }) => {
      const { json, endpoint } = program.opts<{ json?: boolean; endpoint?: string }>();
      const config = loadConfig({ ...(endpoint && { endpoint }) });
      const rows = [{ id: 'w1', endpoint: config.endpoint }].slice(0, opts.limit);
      // Stable schema: add fields, never rename or remove within a major version.
      if (json) data({ schema: 1, items: rows }, true);
      else for (const r of rows) data(r.id, false);
    });

  program
    .command('delete <id>')
    .description('Delete a widget.')
    .option('--dry-run', 'show what would be deleted, change nothing')
    .action((id: string, opts: { dryRun?: boolean }) => {
      if (opts.dryRun) {
        log.info(`would delete ${id}`);
        return;
      }
      if (id === 'missing') throw new CliError(`widget ${id} not found`, Exit.notFound);
      log.info(`deleted ${id}`);
    });

  return program;
}

export async function main(argv: string[]): Promise<number> {
  try {
    await buildProgram().parseAsync(argv, { from: 'user' });
    return Exit.ok;
  } catch (err) {
    if (err instanceof CommanderError) {
      // --help and --version exit 0; everything else commander rejects is a usage error.
      return err.exitCode === 0 ? Exit.ok : Exit.usage;
    }
    if (err instanceof CliError) {
      log.error(err.message, err.hint);
      return err.code;
    }
    log.error(err instanceof Error ? err.message : String(err));
    if (process.env.MYCLI_DEBUG) console.error(err);
    return Exit.failure;
  }
}

if (import.meta.main) process.exitCode = await main(process.argv.slice(2));
```

**`src/prompt.ts`**

```ts
import { cancel, confirm, isCancel } from '@clack/prompts';
import { CliError, Exit } from './exit.ts';
import { isInteractive } from './output.ts';

/** Ask only on a TTY. In CI or a pipe, require the explicit flag instead of hanging. */
export async function confirmOrFlag(message: string, yes: boolean | undefined): Promise<void> {
  if (yes) return;
  if (!isInteractive)
    throw new CliError('Refusing to continue without confirmation.', Exit.usage, 'pass --yes');
  const answer = await confirm({ message });
  if (isCancel(answer) || !answer) {
    cancel('Aborted.');
    throw new CliError('Aborted.', Exit.failure);
  }
}
```

**`tsdown.config.ts`**

```ts
import { defineConfig } from 'tsdown';

export default defineConfig({
  entry: { cli: 'src/cli.ts' },
  format: 'esm',
  platform: 'node',
  target: 'node22',
  clean: true,
});
```

**`tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "es2023", "module": "nodenext", "moduleResolution": "nodenext",
    "strict": true, "noUncheckedIndexedAccess": true, "exactOptionalPropertyTypes": true,
    "verbatimModuleSyntax": true, "erasableSyntaxOnly": true, "rewriteRelativeImportExtensions": true,
    "noEmit": true, "skipLibCheck": true, "types": ["node"]
  },
  "include": ["src", "tests"]
}
```

**`tests/cli.test.ts`**

```ts
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const entry = fileURLToPath(new URL('../dist/cli.mjs', import.meta.url));

function run(args: string[], env: Record<string, string> = {}) {
  const r = spawnSync(process.execPath, [entry, ...args], {
    encoding: 'utf8',
    env: { PATH: process.env.PATH ?? '', NO_COLOR: '1', ...env },
  });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

describe('mycli', () => {
  it('prints --help (snapshot)', () => {
    expect(run(['--help']).stdout).toMatchSnapshot();
  });

  it('keeps stdout pure JSON with --json', () => {
    const r = run(['list', '--json']);
    expect(r.code).toBe(0);
    expect(JSON.parse(r.stdout)).toMatchObject({ schema: 1 });
    expect(r.stderr).toBe('');
  });

  it('exits 2 on a usage error and writes only to stderr', () => {
    const r = run(['list', '--limit', 'x']);
    expect(r.code).toBe(2);
    expect(r.stdout).toBe('');
  });

  it('exits 3 when the widget is missing', () => {
    expect(run(['delete', 'missing']).code).toBe(3);
  });
});
```

`exitOverride()` makes commander throw a `CommanderError` instead of calling `process.exit`, which is what lets `main` return a number and the tests stay honest. `err.exitCode === 0` covers `--help` and `--version`; everything else commander rejects is a usage error, exit 2 (commander's own code is 1).

## Go (cobra v1.10, Go 1.27)

`cli.Run(args, stdout, stderr) int` is the test seam: the binary's `main` is one line, and tests call `Run` with buffers. `SilenceUsage` and `SilenceErrors` stop cobra printing twice; the flag-error hook turns cobra's usage errors into exit 2. The `version` and `commit` variables are set by GoReleaser via `-ldflags -X`.

**`cmd/mycli/main.go`**

```go
package main

import (
	"os"

	"example.com/mycli/internal/cli"
)

func main() { os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr)) }
```

**`internal/out/out.go`**

```go
// Package out owns every byte written to stdout/stderr and the color/TTY decision.
package out

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"golang.org/x/term"
)

// Exit codes are public API. Document them in --help and the README.
const (
	ExitOK       = 0
	ExitFailure  = 1
	ExitUsage    = 2
	ExitNotFound = 3
)

// Err carries an exit code through the call stack.
type Err struct {
	Code int
	Msg  string
	Hint string
}

func (e *Err) Error() string { return e.Msg }

func color(w *os.File) bool {
	if v, ok := os.LookupEnv("NO_COLOR"); ok && v != "" {
		return false
	}
	if os.Getenv("TERM") == "dumb" {
		return false
	}
	return term.IsTerminal(int(w.Fd()))
}

// Interactive reports whether prompting is allowed.
func Interactive() bool {
	return term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd())) && os.Getenv("CI") == ""
}

// JSON writes one JSON document to w (stdout). Data only; never diagnostics.
func JSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	return enc.Encode(v)
}

// Error prints a diagnostic to stderr.
func Error(msg, hint string) {
	prefix := "error:"
	if color(os.Stderr) {
		prefix = "\x1b[31merror:\x1b[0m"
	}
	_, _ = fmt.Fprintf(os.Stderr, "%s %s\n", prefix, msg)
	if hint != "" {
		_, _ = fmt.Fprintf(os.Stderr, "hint: %s\n", hint)
	}
}
```

**`internal/config/config.go`**

```go
// Package config resolves settings. Precedence: flags > env > project file > user file > defaults.
package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/pelletier/go-toml/v2"
)

type Config struct {
	Endpoint string `toml:"endpoint"`
	// TimeoutMS is milliseconds, to match MYCLI_TIMEOUT_MS.
	TimeoutMS int `toml:"timeout_ms"`
}

// Overrides holds flag values; nil means "flag not set".
type Overrides struct {
	Endpoint *string
}

func Defaults() Config { return Config{Endpoint: "https://api.example.com", TimeoutMS: 10_000} }

func userConfigPath() (string, error) {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "mycli", "config.toml"), nil
	}
	dir, err := os.UserConfigDir() // ~/Library/Application Support on macOS; set XDG_CONFIG_HOME to override
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "mycli", "config.toml"), nil
}

func overlay(dst *Config, path string) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := toml.Unmarshal(b, dst); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	return nil
}

func Load(cwd string, o Overrides) (Config, error) {
	c := Defaults()
	if p, err := userConfigPath(); err == nil {
		if err := overlay(&c, p); err != nil {
			return c, err
		}
	}
	if err := overlay(&c, filepath.Join(cwd, ".mycli.toml")); err != nil {
		return c, err
	}
	if v := os.Getenv("MYCLI_ENDPOINT"); v != "" {
		c.Endpoint = v
	}
	if v := os.Getenv("MYCLI_TIMEOUT_MS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return c, fmt.Errorf("MYCLI_TIMEOUT_MS must be a positive integer, got %q", v)
		}
		c.TimeoutMS = n
	}
	if o.Endpoint != nil {
		c.Endpoint = *o.Endpoint
	}
	return c, nil
}
```

**`internal/cli/root.go`**

```go
// Package cli wires cobra commands. Commands parse flags and call into the domain; they hold no logic.
package cli

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"example.com/mycli/internal/config"
	"example.com/mycli/internal/out"
)

// Set by GoReleaser via ldflags (-X).
var (
	version = "dev"
	commit  = "none"
)

func NewRoot(stdout, stderr io.Writer) *cobra.Command {
	var jsonOut bool
	var endpoint string

	root := &cobra.Command{
		Use:           "mycli",
		Short:         "Manage widgets.",
		Version:       fmt.Sprintf("%s (%s)", version, commit),
		SilenceUsage:  true, // usage on every runtime error is noise; cobra still prints it for usage errors below
		SilenceErrors: true, // Execute's caller prints errors once, to stderr
		Long:          "Manage widgets.\n\nExit codes:\n  0 ok   1 failure   2 usage error   3 not found",
	}
	root.SetOut(stdout)
	root.SetErr(stderr)
	root.PersistentFlags().BoolVar(&jsonOut, "json", false, "machine-readable output on stdout")
	root.PersistentFlags().StringVar(&endpoint, "endpoint", "", "API endpoint (env: MYCLI_ENDPOINT)")
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error {
		return &out.Err{Code: out.ExitUsage, Msg: err.Error(), Hint: "run with --help for usage"}
	})

	list := &cobra.Command{
		Use:   "list",
		Short: "List widgets.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var o config.Overrides
			if cmd.Flags().Changed("endpoint") {
				o.Endpoint = &endpoint
			}
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			cfg, err := config.Load(cwd, o)
			if err != nil {
				return &out.Err{Code: out.ExitUsage, Msg: err.Error()}
			}
			items := []map[string]string{{"id": "w1", "endpoint": cfg.Endpoint}}
			if jsonOut {
				// Stable schema: add fields, never rename or remove within a major version.
				return out.JSON(cmd.OutOrStdout(), map[string]any{"schema": 1, "items": items})
			}
			for _, it := range items {
				_, _ = fmt.Fprintln(cmd.OutOrStdout(), it["id"])
			}
			return nil
		},
	}

	var dryRun bool
	del := &cobra.Command{
		Use:   "delete <id>",
		Short: "Delete a widget.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if dryRun {
				_, _ = fmt.Fprintf(cmd.ErrOrStderr(), "would delete %s\n", args[0])
				return nil
			}
			if args[0] == "missing" {
				return &out.Err{Code: out.ExitNotFound, Msg: fmt.Sprintf("widget %s not found", args[0])}
			}
			_, _ = fmt.Fprintf(cmd.ErrOrStderr(), "deleted %s\n", args[0])
			return nil
		},
	}
	del.Flags().BoolVar(&dryRun, "dry-run", false, "show what would be deleted, change nothing")

	root.AddCommand(list, del)
	return root
}

// Run executes the CLI and returns the process exit code.
func Run(args []string, stdout, stderr io.Writer) int {
	root := NewRoot(stdout, stderr)
	root.SetArgs(args)
	err := root.Execute()
	if err == nil {
		return out.ExitOK
	}
	var ce *out.Err
	if errors.As(err, &ce) {
		out.Error(ce.Msg, ce.Hint)
		return ce.Code
	}
	// cobra's own errors (unknown command, wrong arg count) are usage errors.
	out.Error(err.Error(), "run with --help for usage")
	return out.ExitUsage
}
```

**`internal/cli/cli_test.go`**

```go
package cli_test

import (
	"bytes"
	"encoding/json"
	"testing"

	"example.com/mycli/internal/cli"
)

func run(t *testing.T, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var o, e bytes.Buffer
	code = cli.Run(args, &o, &e)
	return code, o.String(), e.String()
}

func TestListJSONIsPureStdout(t *testing.T) {
	code, stdout, _ := run(t, "list", "--json")
	if code != 0 {
		t.Fatalf("code = %d", code)
	}
	var v struct{ Schema int }
	if err := json.Unmarshal([]byte(stdout), &v); err != nil || v.Schema != 1 {
		t.Fatalf("stdout is not the documented JSON: %q (%v)", stdout, err)
	}
}

func TestExitCodes(t *testing.T) {
	for name, tc := range map[string]struct {
		args []string
		want int
	}{
		"unknown flag":    {[]string{"list", "--nope"}, 2},
		"unknown command": {[]string{"bogus"}, 2},
		"missing arg":     {[]string{"delete"}, 2},
		"not found":       {[]string{"delete", "missing"}, 3},
		"dry run":         {[]string{"delete", "a", "--dry-run"}, 0},
	} {
		t.Run(name, func(t *testing.T) {
			if got, _, _ := run(t, tc.args...); got != tc.want {
				t.Fatalf("exit = %d, want %d", got, tc.want)
			}
		})
	}
}
```

`golangci-lint` v2 flags `fmt.Fprintf` return values under `errcheck`; the `_, _ =` assignment is deliberate. Write to stdout/stderr through `cmd.OutOrStdout()` / `cmd.ErrOrStderr()` so tests can capture them.

## Python (typer 0.27, Python >= 3.12, uv)

`typer` parses; `main()` only maps `CliError` to an exit code. Typer prints usage errors itself and exits 2. Declare `--json` on each command (as the `JsonOpt` alias) so `mycli list --json` works; Typer does not accept a callback option after the subcommand. `rich_markup_mode=None` keeps help plain, so snapshots and pipes are stable.

**`pyproject.toml`**

```toml
[project]
name = "mycli"
version = "0.1.0"
description = "Manage widgets."
readme = "README.md"
requires-python = ">=3.12"
dependencies = ["typer>=0.27,<1", "platformdirs>=4.12,<5"]

[project.scripts]
mycli = "mycli.cli:main"

[dependency-groups]
dev = ["pytest>=9.1", "ruff>=0.16"]

[build-system]
requires = ["uv_build>=0.12.24,<0.13"]
build-backend = "uv_build"
```

**`src/mycli/exit.py`**

```python
"""Exit codes are public API. Document them in --help and the README."""

from enum import IntEnum


class Exit(IntEnum):
    OK = 0
    FAILURE = 1
    USAGE = 2  # typer/click already exit 2 on usage errors
    NOT_FOUND = 3


class CliError(Exception):
    """Expected failure: the entry point prints the message and exits with `code`."""

    def __init__(
        self, message: str, code: Exit = Exit.FAILURE, hint: str | None = None
    ):
        super().__init__(message)
        self.code = code
        self.hint = hint
```

**`src/mycli/output.py`**

```python
"""Owns every write to stdout/stderr and the color/TTY decision."""

import json
import os
import sys
from typing import Any


def _color() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("TERM") == "dumb":
        return False
    return sys.stderr.isatty()


def interactive() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty() and not os.environ.get("CI")


def data(value: Any, *, as_json: bool) -> None:
    """Data goes to stdout. Nothing else may write there."""
    sys.stdout.write((json.dumps(value) if as_json else str(value)) + "\n")


def info(msg: str) -> None:
    sys.stderr.write(msg + "\n")


def error(msg: str, hint: str | None = None) -> None:
    prefix = "\x1b[31merror:\x1b[0m" if _color() else "error:"
    sys.stderr.write(f"{prefix} {msg}\n")
    if hint:
        sys.stderr.write(f"hint: {hint}\n")
```

**`src/mycli/config.py`**

```python
"""Precedence: flags > env > project file > user file (XDG) > defaults."""

import os
import tomllib
from dataclasses import dataclass, replace
from pathlib import Path

from platformdirs import user_config_path

from .exit import CliError, Exit


@dataclass(frozen=True)
class Config:
    endpoint: str = "https://api.example.com"
    timeout_ms: int = 10_000


def _read(path: Path) -> dict[str, object]:
    try:
        with path.open("rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}
    except tomllib.TOMLDecodeError as e:
        raise CliError(f"Cannot parse {path}: {e}", Exit.USAGE) from e


def _apply(cfg: Config, raw: dict[str, object]) -> Config:
    changes: dict[str, object] = {}
    if isinstance(raw.get("endpoint"), str):
        changes["endpoint"] = raw["endpoint"]
    if isinstance(raw.get("timeout_ms"), int):
        changes["timeout_ms"] = raw["timeout_ms"]
    return replace(cfg, **changes)


def load(*, endpoint: str | None = None, cwd: Path | None = None) -> Config:
    cfg = Config()
    user_file = user_config_path("mycli", appauthor=False) / "config.toml"
    cfg = _apply(cfg, _read(user_file))
    cfg = _apply(cfg, _read((cwd or Path.cwd()) / ".mycli.toml"))
    if env := os.environ.get("MYCLI_ENDPOINT"):
        cfg = replace(cfg, endpoint=env)
    if env := os.environ.get("MYCLI_TIMEOUT_MS"):
        if not env.isdigit() or int(env) <= 0:
            raise CliError(
                f"MYCLI_TIMEOUT_MS must be a positive integer, got {env!r}", Exit.USAGE
            )
        cfg = replace(cfg, timeout_ms=int(env))
    if endpoint is not None:
        cfg = replace(cfg, endpoint=endpoint)
    return cfg
```

**`src/mycli/cli.py`**

```python
from typing import Annotated

import typer

from . import config, output
from .exit import CliError, Exit

app = typer.Typer(
    name="mycli",
    help="Manage widgets.\n\nExit codes: 0 ok, 1 failure, 2 usage error, 3 not found.",
    no_args_is_help=True,
    add_completion=True,
    rich_markup_mode=None,  # plain help: stable for snapshots and pipes
)


# Declared per command (not on the callback) so `mycli list --json` works as well as `mycli --json list`.
JsonOpt = Annotated[
    bool, typer.Option("--json", help="Machine-readable output on stdout.")
]
EndpointOpt = Annotated[
    str | None, typer.Option(help="API endpoint (env: MYCLI_ENDPOINT).")
]


def _version(value: bool) -> None:
    if value:
        from importlib.metadata import version

        typer.echo(version("mycli"))
        raise typer.Exit()


@app.callback()
def root(
    version: Annotated[
        bool,
        typer.Option(
            "--version", callback=_version, is_eager=True, help="Show version."
        ),
    ] = False,
) -> None:
    """Manage widgets."""


@app.command("list")
def list_(
    json: JsonOpt = False,
    endpoint: EndpointOpt = None,
    limit: Annotated[int, typer.Option("--limit", "-n", min=1, help="Max rows.")] = 20,
) -> None:
    """List widgets."""
    cfg = config.load(endpoint=endpoint)
    rows = [{"id": "w1", "endpoint": cfg.endpoint}][:limit]
    if json:
        # Stable schema: add fields, never rename or remove within a major version.
        output.data({"schema": 1, "items": rows}, as_json=True)
    else:
        for r in rows:
            output.data(r["id"], as_json=False)


@app.command()
def delete(
    id: str,
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run", help="Show what would be deleted, change nothing."),
    ] = False,
) -> None:
    """Delete a widget."""
    if dry_run:
        output.info(f"would delete {id}")
        return
    if id == "missing":
        raise CliError(f"widget {id} not found", Exit.NOT_FOUND)
    output.info(f"deleted {id}")


def main() -> None:
    # standalone mode: typer prints usage errors itself and exits 2, --help/--version exit 0.
    try:
        app()
    except CliError as e:
        output.error(str(e), e.hint)
        raise SystemExit(e.code) from None
```

**`src/mycli/__main__.py`**

```python
from .cli import main

main()
```

**`tests/test_cli.py`**

```python
import json
import os
import subprocess
import sys

CLEAN_ENV = {"NO_COLOR": "1", "PATH": os.environ.get("PATH", "")}


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-m", "mycli", *args],
        capture_output=True,
        text=True,
        env=CLEAN_ENV,
        check=False,
    )


def test_json_stdout_is_pure():
    r = run("list", "--json")
    assert r.returncode == 0
    assert json.loads(r.stdout)["schema"] == 1
    assert r.stderr == ""


def test_usage_error_exits_2_with_empty_stdout():
    r = run("list", "--limit", "0")
    assert r.returncode == 2
    assert r.stdout == ""


def test_not_found_exits_3():
    assert run("delete", "missing").returncode == 3


def test_help_lists_commands():
    out = run("--help").stdout
    assert "list" in out and "delete" in out and "Exit codes" in out
```
## Rust (clap 4.6 derive, edition 2024)

`Cli::try_parse().unwrap_or_else(|e| e.exit())` lets clap print help (exit 0) and usage errors (exit 2) itself. `CliError::exit()` maps domain errors to codes. `global = true` makes `--json` valid before and after the subcommand. Edition 2024 allows `let` chains, which clippy now asks for.

**`Cargo.toml (dependencies)`**

```toml
[package]
name = "mycli"
version = "0.1.0"
edition = "2024"
description = "Manage widgets."
license = "MIT"
repository = "https://github.com/acme/mycli"

[dependencies]
clap = { version = "4.6", features = ["derive", "env", "wrap_help"] }
dirs = "7"
serde = { version = "1.0.229", features = ["derive"] }
serde_json = "1.0.151"
thiserror = "2.0.21"
toml = "1.1.8"

[dev-dependencies]
assert_cmd = "2.2.2"
insta = "1"

```

**`src/error.rs`**

```rust
use std::process::ExitCode;

/// Exit codes are public API. Document them in --help and the README.
#[derive(Clone, Copy)]
pub enum Exit {
    Failure = 1,
    Usage = 2, // clap already exits 2 on parse errors
    NotFound = 3,
}

#[derive(Debug, thiserror::Error)]
pub enum CliError {
    #[error("widget {0} not found")]
    NotFound(String),
    #[error("{0}")]
    Config(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl CliError {
    pub fn exit(&self) -> ExitCode {
        ExitCode::from(match self {
            Self::NotFound(_) => Exit::NotFound,
            Self::Config(_) => Exit::Usage,
            Self::Io(_) => Exit::Failure,
        } as u8)
    }
}
```

**`src/output.rs`**

```rust
//! Owns every write to stdout/stderr and the color/TTY decision.
use std::io::{IsTerminal, Write};

fn color() -> bool {
    std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty())
        && std::env::var("TERM").as_deref() != Ok("dumb")
        && std::io::stderr().is_terminal()
}

/// Data goes to stdout. Nothing else may write there.
pub fn data(line: &str) {
    // A closed pipe (`mycli list | head`) is not an error worth a panic.
    let _ = writeln!(std::io::stdout(), "{line}");
}

pub fn info(msg: &str) {
    let _ = writeln!(std::io::stderr(), "{msg}");
}

pub fn error(msg: &str, hint: Option<&str>) {
    let prefix = if color() {
        "\x1b[31merror:\x1b[0m"
    } else {
        "error:"
    };
    let mut err = std::io::stderr();
    let _ = writeln!(err, "{prefix} {msg}");
    if let Some(h) = hint {
        let _ = writeln!(err, "hint: {h}");
    }
}
```

**`src/config.rs`**

```rust
//! Precedence: flags > env > project file > user file (XDG) > defaults.
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::CliError;

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub endpoint: String,
    pub timeout_ms: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            endpoint: "https://api.example.com".into(),
            timeout_ms: 10_000,
        }
    }
}

/// Partial file layer: only keys that are present override.
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct Layer {
    endpoint: Option<String>,
    timeout_ms: Option<u64>,
}

fn read(path: &Path) -> Result<Layer, CliError> {
    match std::fs::read_to_string(path) {
        Ok(text) => toml::from_str(&text)
            .map_err(|e| CliError::Config(format!("cannot parse {}: {e}", path.display()))),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Layer::default()),
        Err(e) => Err(e.into()),
    }
}

fn user_file() -> Option<PathBuf> {
    // XDG_CONFIG_HOME first on every OS; dirs::config_dir() is the platform fallback.
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(dirs::config_dir)?;
    Some(base.join("mycli").join("config.toml"))
}

pub fn load(endpoint_flag: Option<String>) -> Result<Config, CliError> {
    let mut cfg = Config::default();
    let mut layers = Vec::new();
    if let Some(p) = user_file() {
        layers.push(read(&p)?);
    }
    layers.push(read(Path::new(".mycli.toml"))?);
    for l in layers {
        if let Some(v) = l.endpoint {
            cfg.endpoint = v;
        }
        if let Some(v) = l.timeout_ms {
            cfg.timeout_ms = v;
        }
    }
    if let Ok(v) = std::env::var("MYCLI_ENDPOINT")
        && !v.is_empty()
    {
        cfg.endpoint = v;
    }
    if let Ok(v) = std::env::var("MYCLI_TIMEOUT_MS") {
        cfg.timeout_ms = v.parse().ok().filter(|n| *n > 0).ok_or_else(|| {
            CliError::Config(format!(
                "MYCLI_TIMEOUT_MS must be a positive integer, got {v:?}"
            ))
        })?;
    }
    if let Some(v) = endpoint_flag {
        cfg.endpoint = v;
    }
    Ok(cfg)
}
```

**`src/main.rs`**

```rust
mod config;
mod error;
mod output;

use std::process::ExitCode;

use clap::{Parser, Subcommand};
use serde_json::json;

use error::CliError;

#[derive(Parser)]
#[command(
    name = "mycli",
    version,
    about = "Manage widgets.",
    after_help = "Exit codes:\n  0 ok   1 failure   2 usage error   3 not found",
    arg_required_else_help = true
)]
struct Cli {
    /// Machine-readable output on stdout.
    #[arg(long, global = true)]
    json: bool,
    /// API endpoint.
    #[arg(long, global = true, env = "MYCLI_ENDPOINT")]
    endpoint: Option<String>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List widgets.
    List {
        /// Max rows.
        #[arg(short = 'n', long, default_value_t = 20, value_parser = clap::value_parser!(u32).range(1..))]
        limit: u32,
    },
    /// Delete a widget.
    Delete {
        id: String,
        /// Show what would be deleted, change nothing.
        #[arg(long)]
        dry_run: bool,
    },
}

fn run(cli: Cli) -> Result<(), CliError> {
    match cli.command {
        Command::List { limit } => {
            let cfg = config::load(cli.endpoint)?;
            let rows = vec![json!({ "id": "w1", "endpoint": cfg.endpoint })];
            let rows: Vec<_> = rows.into_iter().take(limit as usize).collect();
            if cli.json {
                // Stable schema: add fields, never rename or remove within a major version.
                output::data(&json!({ "schema": 1, "items": rows }).to_string());
            } else {
                for r in &rows {
                    output::data(r["id"].as_str().unwrap_or_default());
                }
            }
            Ok(())
        }
        Command::Delete { id, dry_run } => {
            if dry_run {
                output::info(&format!("would delete {id}"));
                return Ok(());
            }
            if id == "missing" {
                return Err(CliError::NotFound(id));
            }
            output::info(&format!("deleted {id}"));
            Ok(())
        }
    }
}

fn main() -> ExitCode {
    // try_parse + exit(): --help/--version exit 0, usage errors exit 2, both handled by clap.
    let cli = Cli::try_parse().unwrap_or_else(|e| e.exit());
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            output::error(&e.to_string(), None);
            e.exit()
        }
    }
}
```

**`tests/cli.rs`**

```rust
use assert_cmd::Command;

fn mycli() -> Command {
    let mut c = Command::cargo_bin("mycli").unwrap();
    c.env_clear().env("NO_COLOR", "1");
    c
}

#[test]
fn json_stdout_is_pure() {
    let out = mycli()
        .args(["list", "--json"])
        .assert()
        .success()
        .get_output()
        .clone();
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["schema"], 1);
    assert!(out.stderr.is_empty());
}

#[test]
fn usage_error_exits_2() {
    mycli()
        .args(["list", "--limit", "0"])
        .assert()
        .code(2)
        .stdout("");
}

#[test]
fn not_found_exits_3() {
    mycli().args(["delete", "missing"]).assert().code(3);
}

#[test]
fn help_is_stable() {
    let out = mycli()
        .arg("--help")
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    insta::assert_snapshot!(String::from_utf8(out).unwrap());
}
```

The `insta` snapshot for `--help` lands in `tests/snapshots/`. Review it with `cargo insta review`; commit it.

## When to deviate

- These are scaffolds, not libraries. Delete the parts you do not use (a CLI with no config file does not need `config.*`).
- A repo with its own error or output module keeps it; map it onto the same four seams.
