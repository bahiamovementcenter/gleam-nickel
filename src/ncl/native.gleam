//// The native backend: Nickel running inside the Erlang VM.
////
//// Select it with `context.with_backend(context.Native)`; every function of
//// the `ncl` module then works without the `nickel` executable, and
//// `ncl/lazy` gives on-demand access to values. The interpreter comes from
//// the `ncl_nif` library, built from this repository's `native/ncl_nif`
//// crate over [nickel-embed](https://github.com/bahiamovementcenter/rust-nickel).
//// Install the prebuilt one for this version once:
////
//// ```sh
//// gleam run -m ncl/install
//// ```
////
//// or build it yourself:
////
//// ```sh
//// cargo build --release --manifest-path native/ncl_nif/Cargo.toml
//// export NCL_NIF=$PWD/native/ncl_nif/target/release/libncl_nif.so
//// ```
////
//// The library is looked for at `$NCL_NIF`, then as `priv/libncl_nif.so` in
//// this package, then where `ncl/install` puts it. On macOS, rename the
//// `.dylib` that Cargo builds to `.so`.
////
//// Each evaluation runs on its own operating system thread, so it never
//// blocks the VM's schedulers. Compared with the command line backend:
////
//// - Values are exact: whole numbers of any size stay `Int`.
//// - A crash in native code (other than a Rust panic, which becomes an
////   error) stops the whole VM, so don't evaluate untrusted configurations.
//// - A timed out call returns an error, but the evaluation keeps running on
////   its thread until it ends.
//// - Package manifests (`context.with_manifest_path`) always work: the
////   library includes Nickel's package manager, which released `nickel`
////   executables leave out.
//// - `ncl.version` returns the version of `nickel-lang-core` linked in,
////   not of a Nickel release.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import ncl/context.{type Context}
import ncl/contract
import ncl/error.{type Diagnostic, type Error, type ErrorKind}
import ncl/metadata.{type FieldMetadata}
import ncl/runner
import ncl/source.{type Source}
import ncl/value.{type Value}

/// Whether the native library is loaded, and if not, why.
pub fn load_error() -> Result(Nil, String) {
  ffi_load_error()
}

/// Whether the native backend can be used.
pub fn is_available() -> Bool {
  result.is_ok(ffi_load_error())
}

/// The version of `nickel-lang-core` in the native library, e.g. `"0.19.0"`.
pub fn core_version() -> Result(String, Error) {
  ffi_core_version() |> result.map_error(to_error(_, True))
}

// --- Sessions (internal) ------------------------------------------------------

/// A thread owning one Nickel program and the expressions taken from it.
/// It stops once the session and its expressions are garbage-collected.
pub type Session

/// An expression in a session. Internal: use `ncl/lazy`.
pub type Handle

@internal
pub type Input {
  /// Code, and the name it gets in messages, which also sets where its
  /// relative imports are resolved.
  Code(code: String, name: String)
  File(path: String)
}

@internal
pub type Override {
  Assign(path: List(String), code: String)
  Force(path: List(String), code: String)
}

@internal
pub type Options {
  Options(
    inputs: List(Input),
    import_paths: List(String),
    contract_files: List(String),
    contract_code: List(String),
    overrides: List(Override),
    field: List(String),
    trace: Bool,
    manifest: Option(String),
    package_cache_dir: Option(String),
  )
}

@internal
pub type EvalMode {
  Deep
  DeepForExport
  Shallow
  RecordSpine
}

@internal
pub type Format {
  Json
  Yaml
  Toml
  Text
}

@internal
pub type Request {
  Build(Options)
  Eval(EvalMode)
  EvalValue
  Export(Format)
  Typecheck(strict: Bool)
  Parse
  Query
  ForceExpr(Handle)
  Inspect(Handle)
  ToValue(Handle)
  ExportExpr(Handle, Format)
  Display(Handle)
  TakeTrace
}

@internal
pub type Failure {
  NickelFailure(
    kind: Option(ErrorKind),
    diagnostics: List(Diagnostic),
    rendered: String,
  )
  NativeFailure(reason: String)
  TimedOut(milliseconds: Int)
}

/// One level of an expression, with nested expressions as handles.
@internal
pub type RawView {
  Null
  Bool(Bool)
  Number(numerator: Int, denominator: Int)
  String(String)
  EnumTag(String)
  EnumVariant(tag: String, argument: Handle)
  Record(fields: List(#(String, Option(Handle))))
  Array(items: List(Handle))
  Other
  Unevaluated
}

@internal
pub fn to_error(failure: Failure, render: Bool) -> Error {
  case failure {
    NickelFailure(kind:, diagnostics:, rendered:) ->
      error.NickelError(
        kind: refine_kind(kind, diagnostics),
        diagnostics:,
        rendered: case render {
          True -> rendered
          False -> ""
        },
      )
    NativeFailure(reason) -> error.NativeError(reason)
    TimedOut(ms) -> error.ProcessError(runner.TimedOut(ms))
  }
}

/// The library's kind when it has one, except that it reports unbound
/// identifiers as type errors (they are found while typechecking), which the
/// command line backend reports as `UnboundIdentifier`.
fn refine_kind(kind: Option(ErrorKind), diagnostics: List(Diagnostic)) {
  case kind, error.classify(diagnostics) {
    Some(error.TypeError), error.UnboundIdentifier -> error.UnboundIdentifier
    Some(kind), _ -> kind
    None, classified -> classified
  }
}

/// What a program built from a context includes.
@internal
pub type Parts {
  Parts(contracts: Bool, assignments: Bool, field: List(String), trace: Bool)
}

/// Starts a session and builds a program in it from a context and a source,
/// resolving paths the way the command line backend would in the context's
/// working directory.
@internal
pub fn start(
  context: Context,
  program: Source,
  parts: Parts,
) -> Result(Session, Error) {
  let render = context.render_errors(context)
  use session <- result.try(
    ffi_new_session() |> result.map_error(to_error(_, render)),
  )
  let directory = working_directory(context)
  let resolve = fn(path) { resolve(directory, path) }
  let contracts = case parts.contracts {
    True -> context.contracts(context)
    False -> []
  }
  let inline = list.any(contracts, fn(c) { !is_file_contract(c) })
  let import_paths =
    list.flatten([
      context.import_paths(context),
      env_import_paths(context),
      // Like the CLI backend: imports in inline contracts fall back to the
      // working directory.
      case inline {
        True -> ["."]
        False -> []
      },
    ])
  let options =
    Options(
      inputs: case program {
        source.Code(code) -> [Code(code, resolve("<stdin>"))]
        source.Files(paths) -> list.map(paths, fn(p) { File(resolve(p)) })
      },
      import_paths: list.map(import_paths, resolve),
      contract_files: list.filter_map(contracts, fn(c) {
        case c {
          contract.ContractFile(path) -> Ok(resolve(path))
          contract.ContractCode(_) -> Error(Nil)
        }
      }),
      contract_code: list.filter_map(contracts, fn(c) {
        case c {
          contract.ContractCode(code) -> Ok(code)
          contract.ContractFile(_) -> Error(Nil)
        }
      }),
      overrides: case parts.assignments {
        True ->
          list.map(context.assignments(context), fn(a) {
            case a {
              context.Assign(path, code) -> Assign(path, code)
              context.Override(path, code) -> Force(path, code)
            }
          })
        False -> []
      },
      field: parts.field,
      trace: parts.trace,
      manifest: option.map(context.manifest_path(context), resolve),
      package_cache_dir: option.map(context.package_cache_dir(context), resolve),
    )
  use Nil <- result.map(call_nil(context, session, Build(options)))
  session
}

fn is_file_contract(contract: contract.Contract) -> Bool {
  case contract {
    contract.ContractFile(_) -> True
    contract.ContractCode(_) -> False
  }
}

/// The absolute working directory: the process runs in one directory for
/// every session, so relative paths are resolved here instead.
fn working_directory(context: Context) -> String {
  let cwd = current_directory()
  case context.working_directory(context) {
    Some(directory) -> resolve(cwd, directory)
    None -> cwd
  }
}

fn resolve(directory: String, path: String) -> String {
  case path {
    "/" <> _ -> path
    "." -> directory
    "./" <> rest -> directory <> "/" <> rest
    _ -> directory <> "/" <> path
  }
}

/// `NICKEL_IMPORT_PATH`, from the context's environment or the VM's, as the
/// `nickel` executable would read it.
fn env_import_paths(context: Context) -> List(String) {
  let variable =
    context.environment(context)
    |> list.key_find("NICKEL_IMPORT_PATH")
    |> result.lazy_or(fn() { getenv("NICKEL_IMPORT_PATH") })
  case variable {
    Ok(paths) -> string.split(paths, ":") |> list.filter(fn(p) { p != "" })
    Error(Nil) -> []
  }
}

// --- Calls (internal) -----------------------------------------------------

fn timeout_and_render(context: Context) -> #(Option(Int), Bool) {
  #(context.timeout(context), context.render_errors(context))
}

@internal
pub fn call_nil(
  context: Context,
  session: Session,
  request: Request,
) -> Result(Nil, Error) {
  let #(timeout, render) = timeout_and_render(context)
  ffi_call_nil(session, request, timeout)
  |> result.map_error(to_error(_, render))
}

@internal
pub fn call_handle(
  context: Context,
  session: Session,
  request: Request,
) -> Result(Handle, Error) {
  let #(timeout, render) = timeout_and_render(context)
  ffi_call_handle(session, request, timeout)
  |> result.map_error(to_error(_, render))
}

@internal
pub fn call_value(
  context: Context,
  session: Session,
  request: Request,
) -> Result(Value, Error) {
  let #(timeout, render) = timeout_and_render(context)
  ffi_call_value(session, request, timeout)
  |> result.map_error(to_error(_, render))
}

@internal
pub fn call_string(
  context: Context,
  session: Session,
  request: Request,
) -> Result(String, Error) {
  let #(timeout, render) = timeout_and_render(context)
  ffi_call_string(session, request, timeout)
  |> result.map_error(to_error(_, render))
}

@internal
pub fn call_view(
  context: Context,
  session: Session,
  request: Request,
) -> Result(RawView, Error) {
  let #(timeout, render) = timeout_and_render(context)
  ffi_call_view(session, request, timeout)
  |> result.map_error(to_error(_, render))
}

@internal
pub fn call_metadata(
  context: Context,
  session: Session,
  request: Request,
) -> Result(FieldMetadata, Error) {
  let #(timeout, render) = timeout_and_render(context)
  ffi_call_metadata(session, request, timeout)
  |> result.map_error(to_error(_, render))
}

@external(erlang, "ncl_native_ffi", "load_error")
fn ffi_load_error() -> Result(Nil, String)

@external(erlang, "ncl_native_ffi", "core_version")
fn ffi_core_version() -> Result(String, Failure)

@external(erlang, "ncl_native_ffi", "new_session")
fn ffi_new_session() -> Result(Session, Failure)

@external(erlang, "ncl_native_ffi", "call")
fn ffi_call_nil(
  session: Session,
  request: Request,
  timeout: Option(Int),
) -> Result(Nil, Failure)

@external(erlang, "ncl_native_ffi", "call")
fn ffi_call_handle(
  session: Session,
  request: Request,
  timeout: Option(Int),
) -> Result(Handle, Failure)

@external(erlang, "ncl_native_ffi", "call")
fn ffi_call_value(
  session: Session,
  request: Request,
  timeout: Option(Int),
) -> Result(Value, Failure)

@external(erlang, "ncl_native_ffi", "call")
fn ffi_call_string(
  session: Session,
  request: Request,
  timeout: Option(Int),
) -> Result(String, Failure)

@external(erlang, "ncl_native_ffi", "call")
fn ffi_call_view(
  session: Session,
  request: Request,
  timeout: Option(Int),
) -> Result(RawView, Failure)

@external(erlang, "ncl_native_ffi", "call")
fn ffi_call_metadata(
  session: Session,
  request: Request,
  timeout: Option(Int),
) -> Result(FieldMetadata, Failure)

@external(erlang, "ncl_ffi", "current_directory")
fn current_directory() -> String

@external(erlang, "ncl_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
