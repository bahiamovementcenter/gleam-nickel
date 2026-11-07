# Handoff: gleam-nickel-embedded

This document is for whoever starts a new repository, `gleam-nickel-embedded`, which
embeds the Nickel interpreter in Gleam applications on the Erlang VM. Nickel's own Go
bindings ([nickel-lang/go-nickel](https://github.com/nickel-lang/go-nickel)) take the same
approach. It explains how that project relates to this one, what has been checked, which
problems have to be solved, and a suggested plan.

Written on 2026-11-07, against this repository at the commit that adds this file.

## 1. Background

This repository (`gleam-nickel-bindings`, Gleam package `nickel`) runs the `nickel`
command-line program for every call and reads its JSON output. That keeps the interpreter
in a separate operating system process. We decided to keep this design and build an
embedded variant as a **separate package** instead of replacing it. The two serve
different needs:

| | `nickel` (this repo, CLI) | `gleam-nickel-embedded` (new) |
|---|---|---|
| Per-call cost | ~33 ms for a trivial program (measured; ~25 ms is process start) | Expected far lower; not measured |
| Install | User installs `nickel` | Interpreter ships with the package |
| Values | What JSON can hold (enum tags become strings; big integers become floats) | Full Nickel values: enum tags, enum variants, exact rationals |
| Lazy evaluation | No | Possible, with work (section 4.3) |
| Crash isolation | A crash in Nickel is an error value | A crash in native code stops the whole VM |
| Timeouts | The process is killed (`context.with_timeout`) | No way to stop a running evaluation |
| Features | Typecheck, contracts from files, customize-mode assignments, field focus, `query` metadata, package manifests | Only what the Rust library exposes (section 3) |

The new package should **not** try to replace this one. Its users choose it for speed,
lazy evaluation or full values, and accept the costs above.

## 2. What was verified, and how

| Fact | How it was checked |
|---|---|
| Nickel publishes a stable Rust library, `nickel-lang` (latest 2.2.0 at the time of writing; Rust edition 2024; depends on `nickel-lang-core` 0.18) | crates.io API; crate source downloaded and read |
| `nickel_lang::Context` and `nickel_lang::Expr` are **not `Send`** (they contain `Rc` and `Box<dyn Write>`) | Compiled `fn is_send<T: Send>()` against both: errors E0277 |
| go-nickel uses Nickel's **C API** (`nickel_lang.h`) through cgo, with prebuilt static libraries for linux amd64/arm64, darwin arm64 and windows amd64, each 16–18 MB | Cloned the repository and inspected `lib/` and `include/` |
| The CLI's JSON error format is documented as "not guaranteed to be stable yet"; the Rust library's `ErrorFormat::Json` produces the same diagnostics | `nickel export --help`; `nickel-lang` source (`Error::format`) |
| Nickel evaluates deep non-tail recursion (depth 1,000,000) without crashing | Ran it with the 1.14 CLI |
| The Rust library has no cancellation or interruption API | Read the public API of `nickel-lang` 2.2.0 |

Not verified: the speed of an embedded call, Hex's package size limits, and whether the
Rust library builds for every target listed in section 5.

## 3. The Rust library's public API (`nickel-lang` 2.2.0)

Available:

- `Context::new()`, `with_added_import_paths(Vec<OsString>)`, `with_trace(impl Write)`
  (output of `std.trace`), `with_source_name(String)` (the name used in error messages).
- `eval_deep(&str)`, `eval_deep_for_export(&str)` (skips `not_exported` fields),
  `eval_shallow(&str)`, `eval_expr_shallow(Expr)`.
- `expr_to_json`, `expr_to_yaml`, `expr_to_toml`.
- `Expr` inspection: `is_*`, `as_bool`, `as_number` (with `as_i64`, `as_f64`,
  `as_rational` returning numerator and denominator as strings), `as_str`, `as_enum_tag`,
  `as_enum_variant`, `as_record` (iteration yields `(&str, Option<Expr>)`; `None` for a
  field without a value), `as_array`, `to_serde`.
- `Error::format(writer, ErrorFormat)` with `AnsiText`, `Text`, `Json`, `Yaml`, `Toml`.

Gaps compared with this repository:

- **Source strings only.** Every `eval_*` takes `&str`. To evaluate a file, evaluate
  `import "/absolute/path.ncl"` (set `with_source_name` so errors name the file). Several
  files: `(import "a") & (import "b")`. **Check** how relative imports inside a source
  string resolve (current directory or source name); this was not tested.
- **`NICKEL_IMPORT_PATH` is not read automatically.** The library's documentation says the
  embedding program must read it and pass the paths itself.
- **No typechecking entry point.** It would need `nickel-lang-core`, whose API is not
  stable.
- **No contract option.** Wrap the program instead: `(program) | (import "contract.ncl")`
  or `(program) | (inline contract)`.
- **No customize mode** (this repo's `assign` / `override`). Closest equivalent: merge a
  record into the program, `(program) & { server.port | force = 443 }` for an override.
  Merging at normal priority approximates `assign`, but fails on a field that already has
  a value, where the CLI's customize mode reports a different error. Document the
  difference.
- **No field selection.** Wrap: `(program).server.port`.
- **No metadata query.** A `FieldMetadata` type (doc, optional, not_exported, merge
  priority) exists in the source, but no public function in 2.2.0 returns it.
  *Correction to an earlier conversation note, which said this metadata was exposed.*
  Contracts and type annotations are not exposed either.
- **No package manifests.**

## 4. The hard problems

### 4.1 Building and shipping native code with Gleam

Gleam's build tool compiles Gleam, Erlang and Elixir; it does not run `cargo`. Options:

1. **Erlang companion package built by rebar3.** Gleam can depend on rebar3 packages from
   Hex. A small Erlang package (for example `nickel_nif`) compiles the Rust code through a
   rebar3 plugin (such as `rebar3_cargo`) and loads it with `erlang:load_nif/2`. The Gleam
   package depends on it and calls it with `@external`. Cost: every user needs a Rust
   toolchain, and the first build compiles Nickel (minutes).
2. **Prebuilt binaries.** Like go-nickel: build the shared library in CI for each
   platform, then either ship it inside the Hex package (`priv/`) or download it on first
   load, checked against pinned SHA-256 hashes. Check Hex's size limits before choosing
   to ship inside the package: go-nickel's static libraries are 16–18 MB each.
   Downloading at load time needs network access in production, which some users won't
   accept.
3. **Nix.** A flake can build the native library reproducibly (this repository already has
   a flake to start from). Good for development and Nix users, but not a distribution
   strategy for Hex users on its own.

Recommendation: option 1 to start (simple and honest), with option 2 added once the API
settles.

### 4.2 Safety inside the VM

- Run every evaluation on a **dirty CPU scheduler** (Rustler:
  `#[rustler::nif(schedule = "DirtyCpu")]`). The pool is one per core by default, so
  concurrent evaluations queue behind each other.
- Rustler turns Rust panics into Erlang exceptions, but an abort, a stack overflow or
  running out of memory still stops the whole VM.
- **There is no timeout.** An evaluation that never ends holds a dirty scheduler forever.
  Document this prominently. Users who evaluate configs they don't trust should use the
  CLI package, or the port option in 4.4.

### 4.3 Lazy evaluation and thread safety

Rustler resources (handles kept between NIF calls) must be `Send + Sync`. `Context` and
`Expr` are neither (checked: section 2), and the BEAM may run successive NIF calls on
different scheduler threads. Choices, from simplest to most capable:

1. **Eager only (first version).** Each NIF call creates a `Context`, evaluates, converts
   the `Expr` into Erlang terms, and drops everything before returning. No handle
   survives the call, so thread safety is not an issue. Covers deep evaluation, export
   and contracts.
2. **Context per thread with message passing.** A dedicated OS thread owns the `Context`
   and every `Expr` from it. NIF calls send requests over a channel and wait (or reply
   with a message to the caller). Safe, but more code.
3. **Mutex plus `unsafe impl Send`.** Put the `Context` and all its `Expr` values behind
   one `Mutex` in one resource. Sound only if no `Rc` is ever touched outside that
   lock. Avoid unless 2 is too slow.

### 4.4 A middle option worth considering: a long-lived port program

Instead of a NIF, ship a small Rust program, linked with `nickel-lang`, that the VM starts
once and talks to over stdin/stdout (an Erlang port), with a simple framed protocol.

- Keeps crash isolation, and timeouts (kill and restart the program).
- No per-call process start, so most of the speed gain.
- Lazy handles are easy: the program is single-threaded, so `Send` doesn't matter;
  handles are integer IDs.
- Still needs per-platform binaries (4.1, option 2) or a Rust toolchain.

This could be the best balance for many users. Consider it before committing to a NIF.

## 5. Suggested plan

1. **Scaffold.** Gleam package `nickel_embedded`, Erlang target, OTP 27+. Copy this
   repository's `flake.nix` and extend the dev shell with `cargo`, `rustc` and
   `rust-analyzer`. Put the Rust crate in `native/` and depend on `nickel-lang = "2.2"`
   and `rustler`.
2. **Eager core (4.3, option 1).** NIFs: `eval_deep`, `eval_deep_for_export`, `export`
   (json, yaml, toml), all taking source code, import paths and a source name. Return
   either an Erlang term encoding of the value, or the error rendered as JSON and as text.
3. **Gleam API.** Match this repository's API where it fits, so users can switch packages
   with few changes:
   - Reuse the shapes of `nickel/value.Value`, `nickel/error.Error` and `Diagnostic`
     (`nickel/error.parse_diagnostics` can parse `ErrorFormat::Json` unchanged), and
     `nickel/context.Context`.
   - Extend `Value` with `Enum(String)`, `EnumVariant(String, Value)` and an exact
     `Rational(numerator: Int, denominator: Int)` (or keep `Int`/`Float` and add
     `Rational` only for non-integers).
   - Implement `Source.Files` and contracts by generating wrapper source (section 3).
   - Read `NICKEL_IMPORT_PATH` in Gleam and pass it explicitly.
   - Consider a shared, dependency-free package for `Value`, the error types and `syntax`
     if both packages need to stay in step.
4. **Tests.** Port `test/nickel_test.gleam` from this repository. Most cases should pass
   unchanged. Expect differences in `typecheck`, `query`, `assign`/`override` and timeouts;
   mark them clearly. Add tests for enum values, rationals, and a panic in native code not
   stopping the VM.
5. **Benchmark** against this package before claiming speed gains. Measure first call
   (loading Nickel's standard library) separately from later calls.
6. **Lazy evaluation** (4.3, option 2 or the port approach in 4.4) once the eager version
   is stable.
7. **Distribution** (4.1): start with option 1; add prebuilt binaries for linux x86_64 and
   aarch64, and macOS aarch64, through CI.

## 6. Open questions for the owner

- NIF or long-lived port program (4.4)?
- Must users avoid installing Rust (forces prebuilt binaries early)?
- Share types with this package through a common package, or copy them?
- Which platforms must be supported on day one?
- Licence: this repository uses Apache-2.0; go-nickel and the `nickel-lang` crate use MIT. Check
  compatibility of whatever you ship with the Nickel binaries.

## 7. References

- This repository: `src/nickel.gleam` (CLI invocation), `src/nickel/context.gleam`,
  `src/nickel/value.gleam`, `src/nickel/error.gleam`, `test/nickel_test.gleam`, `flake.nix`.
- go-nickel: https://github.com/nickel-lang/go-nickel (`context.go`, `nickel.go`,
  `include/nickel_lang.h`).
- Rust library: https://crates.io/crates/nickel-lang (source in https://github.com/tweag/nickel,
  under `lang/`; check the path in the current repository layout).
- Rustler: https://github.com/rusterlium/rustler (0.39.0 at the time of writing).
- Nickel: https://nickel-lang.org
