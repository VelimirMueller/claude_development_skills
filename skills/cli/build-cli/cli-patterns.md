# CLI Patterns

Reference for `build-cli`. Library choice per language and the structural rules. The tested code for each language is in [cli-examples.md](cli-examples.md). All four implement the same tiny CLI (`mycli list`, `mycli delete <id>`) with the same contract from [cli-ux.md](cli-ux.md): data on stdout, diagnostics on stderr, `--json` with `schema: 1`, exit codes 0/1/2/3, config precedence, `--dry-run`, `NO_COLOR`. 

## Rule: pick the library per language, and keep the default unless the repo says otherwise

| Language | Default | Why this one | Take instead when |
|---|---|---|---|
| TypeScript | `commander` 15 | Zero dependencies, typed `.opts<T>()`, `exitOverride()` for testable exits, the largest user base and the longest support promise (a security-only line for each old major, 12 months). Builds to one `.mjs` file. | `citty`: you want lazy subcommand loading and plugins and accept a 0.x API. `clipanion`: no, its `latest` is a 2024 release candidate. |
| Go | `cobra` | The de facto standard (kubectl, gh, hugo); completions for four shells, man pages and docs generated from the command tree; GoReleaser can generate Homebrew completions from it. | `urfave/cli` v3: smaller tool, you prefer one package and a flatter API. `kong`: you want the CLI declared as one annotated struct and validated by types. |
| Python | `typer` 0.27 | Arguments are typed function parameters; help, completion and validation come from the hints. Since 0.27 it vendors Click, so there is no Click version to conflict with other packages. | `cyclopts`: you want richer types (unions, dataclasses, pydantic) and stricter docs-from-docstrings; it needs Python >= 3.11. `click`: you want decorators and no type-hint magic. |
| Rust | `clap` 4 (derive) | The standard; derive makes the struct the spec; `try_parse` + `exit()` yields exit 2 for usage errors and exit 0 for help. | `lexopt` or `pico-args`: a tiny tool where compile time and binary size matter more than help generation. |

**Why one default per language:** a team reading five CLIs should see one idiom per language. Alternatives are listed so a deviation is a decision with a reason.

**Interactive prompts** are a separate concern from parsing: `@clack/prompts` (TS), `huh` v2 (Go), `typer.prompt` / `questionary` (Python), `inquire` (Rust). Keep them behind one `prompt` module and call them only when `interactive()` is true.

## Rule: one entry file, thin commands, logic in modules

**Why:** A command handler that parses flags, reads config, calls the API and prints is untestable except through the binary. Splitting parse / run / print keeps each step replaceable and the handler under 20 lines.
**How to apply:** the entry file only wires: build the parser, call `run`, map the result to an exit code. `config` builds the typed config. `output` owns every byte on stdout/stderr and the colour/TTY decision. Commands call domain code that returns values or throws a typed error; they do not print and do not call `exit`. Only the entry file exits.

| Seam | TypeScript | Go | Python | Rust |
|---|---|---|---|---|
| entry | `src/cli.ts` | `cmd/<name>/main.go` | `src/<pkg>/cli.py` + `__main__.py` | `src/main.rs` |
| config | `src/config.ts` | `internal/config` | `src/<pkg>/config.py` | `src/config.rs` |
| output | `src/output.ts` | `internal/out` | `src/<pkg>/output.py` | `src/output.rs` |
| exit codes + error type | `src/exit.ts` | `internal/out` (`Err`) | `src/<pkg>/exit.py` | `src/error.rs` |

## Rule: a typed error carries its exit code

**Why:** Mapping error to exit code in one place stops "which code does this failure get" from being re-decided in every handler.
**How to apply:** domain code throws/returns `CliError(message, code, hint?)`. The entry file prints it through `output.error` and exits with `code`. Anything else that escapes is an unexpected failure: one-line message, exit 1, details only under `MYCLI_DEBUG=1`.

## Rule: generate completions from the same definitions

**Why:** Hand-written completions drift from the flags within a release.
**How to apply:** cobra ships `mycli completion <shell>` for free; Typer ships `--install-completion` / `--show-completion`; clap uses `clap_complete` (add a hidden `completions <shell>` subcommand); commander has none built in; skip completions for a small CLI, and for a large one write a `completion` command by hand (unverified: third-party commander completion packages were not evaluated). GoReleaser's cask can install cobra completions (`generate_completions_from_executable`, see `release-cli`).

## Rule: ask for input only through one prompt seam

**Why:** A prompt scattered through handlers cannot be turned off for CI. One function that checks `interactive()` and falls back to a flag or an error makes the rule structural.
**How to apply:** the TypeScript `prompt.ts` above is the shape: skip if the flag is set, refuse with exit 2 and name the flag when not interactive, ask otherwise. Go: `huh` form behind `out.Interactive()`. Python: `typer.confirm` behind `output.interactive()`. Rust: `inquire::Confirm` behind a `std::io::IsTerminal` check.

## Rule: measure startup once, in CI

**Why:** Startup regressions arrive as one extra import. A budget test catches the PR that adds it.
**How to apply:** a test that spawns `--version` and asserts it finishes under a generous bound (300 ms on CI; the local target is 100 ms). Locally, `hyperfine -N --warmup 5 'mycli --version'`. Reference numbers for the CLIs in [cli-examples.md](cli-examples.md), warm, Apple Silicon, 2026-10-09: Rust 5 ms, Go 13 ms, Node 49 ms (bare `node -e 0` is 25 ms), Python 69 ms (bare interpreter 17 ms). The first run after a build is several times slower; never read one run.

## When to deviate

- **A CLI embedded in a framework app** (a `manage.py`, `rails`-style entry): use the framework's command system and keep the stream and exit-code rules.
- **Single-purpose scripts** (one command, two flags): `node:util` `parseArgs`, `argparse`, `flag` or `lexopt` are enough; the layout above is for tools with subcommands.
- **Windows-first tools:** config dir defaults differ; read the platform dir libraries' docs and keep the XDG override.
