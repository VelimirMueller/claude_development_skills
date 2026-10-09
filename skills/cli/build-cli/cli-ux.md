# CLI UX Rules

Reference for `build-cli`. A CLI is called by people and by scripts. Every rule below keeps one of them from being surprised. The ideas follow [clig.dev](https://clig.dev); each rule says why in our terms.

## Rule: stdout is data, stderr is everything else

**Why:** `mycli list | jq` and `$(mycli id)` read stdout. One progress line or warning there breaks every script that consumes it. stderr is the channel humans read and pipes ignore.
**How to apply:** one `output` module owns both streams (see `cli-patterns.md`). Results, JSON and the single value a user asked for go to stdout. Progress, warnings, errors, prompts and hints go to stderr. Never `console.log` / `print` / `println!` outside that module.
**Anti-example:** `print(f"Fetching {url}...")` followed by `print(json.dumps(rows))`. The consumer gets two lines and a parse error.

## Rule: exit codes are public API

**Why:** `if mycli check; then` and CI steps branch on the code. Changing a code is a breaking change, the same as renaming a flag.
**How to apply:** `0` success, `1` generic failure, `2` usage error (bad flag, missing argument; Typer/Click and clap already exit 2, commander and cobra need one line, shown in `cli-patterns.md`), then domain codes from `3` up, each named in one enum and listed in `--help` and the README. Keep the list short; a code nobody branches on is noise. Never exit with a raw signal value, and never exit 0 after printing an error.
**Anti-example:** `exit(-1)` (wraps to 255) or exiting 1 for "not found" and for "network down", so a script cannot retry only the second.

## Rule: `--json` is a schema, not a dump

**Why:** People write `jq` filters against your output. A renamed key breaks them silently, a changed type breaks them loudly.
**How to apply:**
- `--json` prints exactly one JSON document on stdout and nothing else (`--jsonl` for streams: one object per line).
- Wrap lists in an object with a `schema` integer: `{"schema": 1, "items": [...]}`. A top-level array cannot grow a field later.
- Add fields freely. Never rename, remove or change the type of a field inside a major version. Bump `schema` only with the major.
- Errors under `--json` still go to stderr as text, with the exit code. If a consumer needs the error as data, add `{"schema":1,"error":{"code":"not_found","message":"..."}}` to stdout as a documented opt-in, not by default.
- Dates are RFC 3339 UTC strings; IDs are strings; no bare `null` for "empty list" (use `[]`).
- Test it: parse stdout with a JSON parser and assert stderr is empty.

**Anti-example:** printing a table when `--json` is missing and `JSON.stringify(everything)` when present, including internal fields. The internal fields become the contract.

## Rule: config precedence is flags > env > project file > user file > defaults

**Why:** The narrower and more deliberate a source, the higher it ranks. A flag is this one command; an env var is this shell or CI job; a project file is this repo; the user file is this person. One fixed order means nobody has to guess why a value won.
**How to apply:**
- One `config` module builds a typed `Config` once at startup and nothing else reads `process.env` / `os.Getenv` / `std::env`.
- Project file: `.<name>.toml` in the working directory (walk up to the repo root only if the tool needs it). User file: `$XDG_CONFIG_HOME/<name>/config.toml`, falling back to `~/.config/<name>/config.toml` (`~/Library/Application Support` is the platform default on macOS in Go and Rust libraries; honour `XDG_CONFIG_HOME` first so one rule holds on every OS).
- Env vars are `<NAME>_<KEY>` upper-case (`MYCLI_ENDPOINT`). A flag must have an env twin only when CI will want it.
- TOML over YAML and JSON: comments allowed, no implicit typing surprises (`no` is a string), parsers in every language's standard path.
- Reject unknown keys in files. A typo'd `timout_ms` that is silently ignored is a bug report in a month.
- `mycli config show --json` prints the resolved config and which layer set each key. It answers every "why is it using that endpoint" question.
- Secrets never come from flags (they land in `ps` and shell history). Read them from env or a file path flag (`--token-file`), and never print them, not even in `--verbose` or `config show` (print `***`).

**Anti-example:** a config library that merges layers by magic and lowercases keys. Debugging "which layer won" then needs a debugger.

## Rule: colour and prompts follow the terminal, not your taste

**Why:** Escape codes in a log file or a pipe are garbage; a prompt in CI hangs the job until the timeout.
**How to apply:**
- Colour only when the stream is a TTY, `NO_COLOR` is unset or empty ([no-color.org](https://no-color.org)), `TERM` is not `dumb`, and `FORCE_COLOR` is not `0`. Decide per stream: stdout may be piped while stderr is a TTY. Colour never carries meaning alone (the word `error:` stays).
- Interactive means stdin **and** stdout are TTYs and `CI` is unset. Prompt only then. Every prompt has a flag (`--yes`, `--name`) so the same operation runs unattended.
- When a prompt is needed and the session is not interactive, fail with exit 2 and name the flag. Do not guess a default for a destructive question.
- Spinners and progress bars draw on stderr and only on a TTY; otherwise print plain lines or nothing.

**Anti-example:** `read -p "Continue? [y/N]"` with no flag. The Dockerfile that runs it hangs forever.

## Rule: destructive commands have `--dry-run`, and say what they changed

**Why:** People run a destructive command once to see what it does. If the only way to see is to do it, they will not run it.
**How to apply:** Every command that deletes, overwrites, sends or spends takes `--dry-run`: it runs the same code path up to the write, prints what would happen on stderr (the data a real run would return still goes to stdout), exits 0, and changes nothing. A real run prints one line per change. Confirm interactively only above a threshold you can state (deleting more than one thing, or anything irreversible), and `--yes` skips it.
**Anti-example:** a `--dry-run` implemented as a second code path that drifts from the real one. Share the planning step; only the final write differs.

## Rule: errors say what, why, and what to do next

**Why:** The reader is mid-task. An error that names the cause and the next step saves a search and a support message.
**How to apply:** `error: <what failed>: <the reason>` on one line, optionally `hint: <command or flag>` on the next. Name the file, flag or value involved. No stack trace by default (print it under `MYCLI_DEBUG=1` or `--verbose`). Unexpected exceptions still exit 1 with a one-line message and the debug hint. Usage errors print the usage line or `run with --help`.
**Anti-example:** `Error: ENOENT` or a Python traceback for a missing file the user typed wrong.

## Rule: `--help` is the first documentation, so write it as such

**Why:** People type `-h` before they read a README. Help text is also what shell completions and man pages are generated from.
**How to apply:** one-line description per command and per flag; usage line with `<required>` and `[optional]`; list the exit codes and one example in the root help; `-h` and `--help` both work, on every subcommand, and exit 0; `--version` prints one line, `name version`, exit 0. No command does work when called with no arguments unless that is its purpose: a bare `mycli` prints help (exit 0 for the root, 2 for a subcommand missing its required argument). Generate completions (`mycli completion zsh`) from the same definitions.

## Rule: subcommands are `noun verb`, flags are long first

**Why:** Shared nouns group related actions in help and completion (`mycli widget list`, `mycli widget delete`), and verbs stay consistent across nouns. Short flags are typing aids; long flags are what scripts and reviews read.
**How to apply:** every flag has a long form; short forms only for the five or six used all day (`-n`, `-o`, `-v`, `-q`, `-y`, `-h`). Global flags (`--json`, `--quiet`, `--verbose`, `--no-color`) work before and after the subcommand. Keep the same flag meaning in every command (`-n` is always the limit). Use `--` to end options before positional values that start with a dash. Standard names win: `--version`, `--help`, `--force`, `--dry-run`, `--output`.

## Rule: start fast

**Why:** A CLI called in a loop, a shell prompt or a git hook pays its startup every time. Slow startup becomes slow tooling everywhere.
**How to apply:** do no work at import time: no network, no config reads, no heavy imports outside the command that needs them. Budget: under 100 ms for `--help` and `--version`. Measure with `hyperfine 'mycli --version'`. TypeScript: bundle with tsdown and import big dependencies lazily (`await import()`); Python: import heavy modules inside the command function (Typer and Click already defer help rendering); Go and Rust start fast by default, so keep `init()` and `lazy_static` empty.

## Rule: be quiet on success, loud on failure

**Why:** Unix tools print nothing when there is nothing to say; scripts and humans both rely on it.
**How to apply:** a command whose job is a side effect prints one short line on stderr (or nothing with `--quiet`). `--quiet` hides non-errors; `--verbose` adds diagnostics to stderr; neither changes stdout. Never print "Done!" banners.

## Rule: tests spawn the binary

**Why:** Exit codes, stream separation and argument parsing live in the process boundary. A unit test that calls the handler function skips exactly what breaks in production.
**How to apply:** one test file per CLI that runs the built entry point (`spawnSync`, `subprocess.run`, `assert_cmd`, `exec.Command` or a `Run(args, stdout, stderr) int` seam in Go) with a clean environment (`NO_COLOR=1`, no inherited `MYCLI_*`), and asserts: exit code, stdout, stderr, separately. Required cases: `--json` stdout parses and stderr is empty; a usage error exits 2 with empty stdout; each domain exit code; `--version`. Snapshot `--help` for the root and each subcommand: a help change shows up in review as a diff.
**Anti-example:** asserting on `stdout + stderr` joined. A diagnostic leaking into stdout then passes.

## Rule: the CLI is its own docs

**Why:** A README that duplicates `--help` goes stale in a week.
**How to apply:** README holds install, one quick-start, the config precedence table, the exit-code table and the JSON schema versions. Everything else is `--help`. Link, do not copy.

## Cross-links

- Logging for long-running or daemon CLIs: [logging-contract](../../core/_shared/logging-contract.md). A one-shot CLI does not emit JSON logs; it follows this file.
- Secrets handling: [security-baseline](../../core/_shared/security-baseline.md).
- Principles behind the seams: [engineering-principles](../../core/_shared/engineering-principles.md).

## When to deviate

- **Wrapper CLIs** (they exec another tool): pass its exit code through and do not renumber it.
- **Interactive-first tools** (a scaffolder, a TUI): prompts are the product. Keep the non-interactive flags and the TTY check anyway; add `--yes` or `--no-input`.
- **Long-running servers started from a CLI**: logs follow the logging contract (JSON to stdout) and the stream rule above does not apply to the server process.
- **Existing tools with established output**: keep the format, add `--json` beside it, and document the change as additive.
