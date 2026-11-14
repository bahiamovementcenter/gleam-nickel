# ncl

Gleam bindings to [Nickel](https://nickel-lang.org), the configuration language.

This library makes Nickel available to Gleam applications. It does not prescribe how your
application should be structured: it gives you the building blocks to evaluate Nickel
programs, validate data against contracts, resolve imports, decode results into typed Gleam
values, and report errors.

| Capability | API |
| --- | --- |
| Parsing and evaluation | `ncl.parse`, `ncl.eval`, `ncl.export`, `ncl.typecheck` |
| Contract validation | `ncl.validate`, `ncl.validate_value`, `ncl.check`, `context.apply_contract` |
| Import resolution | `context.add_import_path`, `ncl/imports` (`resolve`, `scan`, `dependencies`) |
| Value conversion and typed decoding | `ncl/value` (`Value`, `to_nickel`, `to_json`, `decode`), `ncl.eval_as` |
| Error reporting | `ncl/error` (`NickelError` with kind, structured diagnostics and Nickel's rendering) |
| Configuration context | `ncl/context` (working directory, import paths, contracts, injected values, focus, timeout, runner) |
| Field metadata | `ncl.query` (documentation, types, contracts, priorities) |

## Backends

By default every call runs the `nickel` command line program. The **native backend** runs
Nickel inside the Erlang VM instead, through the `ncl_nif` library. It's built from this
repository's `native/ncl_nif` crate over
[nickel-embed](https://github.com/bahiamovementcenter/rust-nickel), the engine every `*-ncl`
binding shares, and released with each version. Install the one for your platform once
(Linux x86_64 and aarch64, macOS aarch64):

```sh
gleam run -m ncl/install
```

It downloads the library from this version's GitHub release, checks its SHA-256 against the
checksum published with the package, and saves it in your user cache directory
(`~/.cache/ncl/<version>/`), where the native backend finds it. Elsewhere, build it yourself
and point `NCL_NIF` at it:

```sh
cargo build --release --manifest-path native/ncl_nif/Cargo.toml
export NCL_NIF=$PWD/native/ncl_nif/target/release/libncl_nif.so
```

(On macOS, rename the `.dylib` Cargo builds to `.so`.) Then:

```gleam
let ctx = context.new() |> context.with_backend(context.Native)
ncl.eval(ctx, source.file("server.ncl"))   // same API, no process per call
```

| | `Cli` (default) | `Native` |
| --- | --- | --- |
| Needs | the `nickel` executable | the `ncl_nif` library |
| Per call | ~20 ms (process start) | ~11 ms (loading Nickel's standard library) |
| Whole numbers beyond 64 bits | become `Float` | stay exact `Int` |
| A crash in Nickel | an error value | stops the VM (panics become errors) |
| `context.with_timeout` | kills the process | returns an error; the evaluation runs on in the background |
| Package manifests (`with_manifest_path`) | only with a `nickel` built with `package-experimental` (released binaries ignore them) | yes |
| Lazy evaluation (`ncl/lazy`) | no | yes |

Timings are for a small program on Linux x86_64. The whole test suite runs against both
backends in CI.

### Lazy evaluation

`ncl/lazy` evaluates a program only as far as you read it, like Nickel's Go bindings. A
field you never read is never evaluated, so its errors and its cost don't matter:

```gleam
import ncl/lazy

let assert Ok(program) = lazy.new(ctx, source.file("cluster.ncl"))
let assert Ok(root) = lazy.eval_shallow(program)
let assert Ok(port) = lazy.get(root, ["servers", "api", "port"])
lazy.view(port)      // -> Ok(lazy.Number(8080, 1)): exact rationals
lazy.to_value(root)  // -> evaluates everything into a `Value`
```

`lazy.view` shows one level of a value (`Record`, `Array`, `Number`, `EnumTag`,
`EnumVariant`...), with nested values as further expressions. Reading from a loaded program
takes about 0.1 ms.

## Requirements

- Gleam 1.14 or later, Erlang target, Erlang/OTP 27 or later.
- The [`nickel` command line program](https://nickel-lang.org/getting-started) (tested with
  1.14), on the `PATH` or configured with `context.with_executable`; or the native library
  (see Backends).
- A POSIX `sh` (Linux, macOS, BSD, WSL).

```sh
gleam add ncl
```

## Quick start

```gleam
import gleam/dynamic/decode
import ncl
import ncl/context
import ncl/source

pub type Server {
  Server(host: String, port: Int)
}

fn server_decoder() -> decode.Decoder(Server) {
  use host <- decode.field("host", decode.string)
  use port <- decode.field("port", decode.int)
  decode.success(Server(host:, port:))
}

pub fn main() {
  let ctx = context.new()

  // Evaluate inline code into a generic value...
  let assert Ok(value) = ncl.eval(ctx, source.code("{ answer = 6 * 7 }"))

  // ...or a file straight into your own types.
  let assert Ok(server) =
    ncl.eval_as(ctx, source.file("server.ncl"), decode.at(["server"], server_decoder()))
}
```

## Configuration contexts

A `Context` holds everything about *how* a program is evaluated. Contexts are immutable, so
you can build a base context once and derive variants from it.

```gleam
import ncl/context
import ncl/contract
import ncl/syntax
import ncl/value

let base =
  context.new()
  |> context.with_working_directory("config")   // relative paths and inline imports
  |> context.add_import_path("lib")             // like `nickel -I lib`
  |> context.with_timeout(5000)                 // milliseconds

let production =
  base
  |> context.apply_contract(contract.file("schema.ncl"))
  // Fill fields left undefined or with a default value (Nickel's customize mode).
  |> context.assign(["server", "port"], value.Int(443))
  |> context.assign_code(["server", "environment"], syntax.enum_tag("production"))
  // Force a value even if the configuration defines one.
  |> context.override(["server", "host"], value.String("0.0.0.0"))
```

Other settings: `set_env` (for example `NICKEL_IMPORT_PATH`), `focus` (evaluate a single field,
like `--field`), `with_executable`, `with_manifest_path` and `with_package_cache_dir` (Nickel
packages: `import foo` resolves to the dependencies a `Nickel-pkg.ncl` manifest lists),
`with_strict_typechecking`, `with_rendered_errors`, and `with_runner`.

## Contracts

```gleam
import ncl
import ncl/contract
import ncl/value

let schema =
  contract.code("{ port | std.number.PosNat, host | String | default = \"localhost\" }")

// Validate the result of a program.
ncl.validate(ctx, source.file("server.ncl"), schema)

// Validate Gleam data: returns the value with defaults applied.
ncl.validate_value(ctx, value.record([#("port", value.Int(80))]), schema)
// -> Ok(Record(host: "localhost", port: 80))
```

Contracts added to a context with `context.apply_contract` apply to every evaluation in it.

## Values

`ncl/value.Value` mirrors what Nickel can export: `Null`, `Bool`, `Int`, `Float`, `String`,
`Array` and `Record`. It converts to and from JSON, to `Dynamic` (so any
`gleam/dynamic/decode` decoder works through `value.decode`), and to Nickel source code with
`value.to_nickel`, which is how Gleam data is passed to Nickel.

Enum tags are exported as strings; use `syntax.enum_tag` with `context.assign_code` to pass
one in. Whole numbers that do not fit in 64 bits are exported by Nickel as floats.

## Imports

Nickel looks for an import relative to the importing file, then in the import paths, then
in `NICKEL_IMPORT_PATH`. `ncl/imports` reproduces this search so applications can, for
example, watch the files a configuration depends on:

```gleam
import ncl/imports

let assert Ok(files) = imports.dependencies(ctx, source.file("server.ncl"))
// -> ["/app/config/server.ncl", "/app/config/defaults.ncl", "/app/config/lib/shared.ncl", ...]
```

`imports.scan` lists the `import` expressions of some source code, and `imports.resolve`
finds the file a single import refers to. Discovery is lexical: computed import paths are
not detected.

## Errors

All operations return `Result(_, ncl/error.Error)`:

- `NickelError(kind, diagnostics, rendered)`: Nickel rejected the program. `kind` is a
  best-effort classification (`ParseError`, `TypeError`, `ContractViolation`, `ImportError`,
  `MissingField`, `UnboundIdentifier`, `SerializationError`, `EvaluationError`),
  `diagnostics` is Nickel's structured report (messages, notes, labelled byte ranges), and
  `rendered` is Nickel's own rendering with file names and source excerpts.
- `DecodeError(errors)`: the result did not match the decoder given to `eval_as`.
- `ProcessError(reason)`: Nickel could not be run (not installed, timed out...).
- `UnexpectedOutput`, `TemporaryFileError`: unlikely failures of the bindings themselves.

`error.describe` turns any of them into a message for humans.

Producing `rendered` runs Nickel a second time when a call fails. Disable it with
`context.with_rendered_errors(False)` if failures are frequent and the cost matters.

## How it works

The bindings run the `nickel` CLI (`nickel export --format json --error-format json ...`),
pass inline code on standard input, and parse its output. Running the process goes through
`ncl/runner.Runner`, which you can replace with `context.with_runner`, to run Nickel in a
container, through `nix run`, or to stub it in tests.

## Related

`docs/handoff-gleam-nickel-embedded.md` describes a planned companion package that embeds
the Nickel interpreter instead of running the CLI, and the trade-offs between the two.

## Development

With [Nix](https://nixos.org) (flakes enabled), the repository provides everything:

```sh
nix develop          # shell with Gleam, Erlang/OTP 27, Nickel and the native library
gleam test
NCL_TEST_BACKEND=native gleam test   # the same suite on the native backend

nix flake check      # format check + full test suite in the Nix sandbox
nix fmt              # format flake.nix
```

Without Nix, install Gleam, Erlang/OTP 27+ and `nickel`, then run `gleam test`.

The flake's checks fetch the Hex dependencies pinned in `manifest.toml` through Nix, so
they run offline. After changing dependencies, `gleam deps download` updates
`manifest.toml` and the checks pick up the new versions automatically.

### The native library

`native/ncl_nif` is a Rust crate: an Erlang NIF over nickel-embed, which it pins to a
rust-nickel revision in its `Cargo.toml`. It holds no Nickel logic of its own, only the
session threads and the conversion to Gleam's terms. `sh native/ncl_nif/test/run.sh` builds
it and runs its Erlang tests. To move to a new rust-nickel release, change the pin, run
`cargo update -p nickel-embed` in `native/ncl_nif`, and run both test suites.

### Releases

Bump `version` in `gleam.toml` and the changelog, then push a tag `vX.Y.Z`. The release
workflow builds the native library for each platform, attaches it to a GitHub release, writes
the checksums into `src/ncl_nif_checksums.erl` and publishes to Hex (it needs the repository
secret `HEXPM_API_KEY`).
