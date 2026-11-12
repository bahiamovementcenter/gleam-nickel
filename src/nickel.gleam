//// Bindings to the [Nickel](https://nickel-lang.org) configuration language.
////
//// Every operation takes a `Context` (see `nickel/context`) describing how
//// Nickel should run, and a `Source` (see `nickel/source`) describing the
//// program:
////
//// ```gleam
//// import gleam/dynamic/decode
//// import nickel
//// import nickel/context
//// import nickel/source
////
//// pub fn main() {
////   let ctx = context.new()
////   let assert Ok(port) =
////     nickel.eval_as(
////       ctx,
////       source.code("{ server = { port = 8000 + 80 } }"),
////       decode.at(["server", "port"], decode.int),
////     )
////   // port == 8080
//// }
//// ```
////
//// By default the bindings drive the `nickel` command line program, which
//// must be installed (version 1.5 or later; tested with 1.14). With
//// `context.with_backend(context.Native)` they run Nickel inside the VM
//// instead: see `nickel/native`.

import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nickel/context.{type Context}
import nickel/contract.{type Contract}
import nickel/error.{type Error}
import nickel/metadata.{type FieldMetadata}
import nickel/native
import nickel/runner
import nickel/source.{type Source}
import nickel/syntax
import nickel/value.{type Value}

/// Serialization formats supported by `export`.
pub type Format {
  Json
  Yaml
  Toml
  /// The program must evaluate to a string, which is output as is.
  Text
}

// --- Parsing ---------------------------------------------------------------

/// Checks that a program is syntactically valid, without evaluating or
/// typechecking it. Imports are not followed.
pub fn parse(context: Context, program: Source) -> Result(Nil, Error) {
  use <- native_or_cli(context, program, no_parts(), fn(session) {
    native.call_nil(context, session, native.Parse)
  })
  invoke(
    context,
    program,
    Invocation(
      subcommand: "pprint-ast",
      options: [],
      contracts: False,
      field: False,
      assignments: False,
    ),
  )
  |> result.replace(Nil)
}

// --- Evaluation ------------------------------------------------------------

/// Evaluates a program fully, applying the context's contracts and
/// assignments, and returns the result.
///
/// The result must be serializable: functions are not, and fields marked
/// `not_exported` are left out.
pub fn eval(context: Context, program: Source) -> Result(Value, Error) {
  use <- native_or_cli(context, program, export_parts(context), fn(session) {
    native.call_value(context, session, native.EvalValue)
  })
  use output <- result.try(export(context, program, Json))
  value.from_json(output)
  |> result.map_error(fn(e) { json_error(e, output) })
}

/// Evaluates a program and decodes the result with a decoder.
///
/// ```gleam
/// type Server {
///   Server(host: String, port: Int)
/// }
///
/// let server_decoder = {
///   use host <- decode.field("host", decode.string)
///   use port <- decode.field("port", decode.int)
///   decode.success(Server(host:, port:))
/// }
///
/// nickel.eval_as(ctx, source.file("server.ncl"), server_decoder)
/// ```
pub fn eval_as(
  context: Context,
  program: Source,
  decoder: decode.Decoder(a),
) -> Result(a, Error) {
  use <- native_or_cli(context, program, export_parts(context), fn(session) {
    use data <- result.try(native.call_value(context, session, native.EvalValue))
    value.decode(data, decoder) |> result.map_error(error.DecodeError)
  })
  use output <- result.try(export(context, program, Json))
  json.parse(output, decoder)
  |> result.map_error(fn(e) { json_error(e, output) })
}

/// Evaluates a program and serializes the result in the given format.
pub fn export(
  context: Context,
  program: Source,
  format: Format,
) -> Result(String, Error) {
  use <- native_or_cli(context, program, export_parts(context), fn(session) {
    let format = case format {
      Json -> native.Json
      Yaml -> native.Yaml
      Toml -> native.Toml
      Text -> native.Text
    }
    native.call_string(context, session, native.Export(format))
  })
  let format = case format {
    Json -> "json"
    Yaml -> "yaml"
    Toml -> "toml"
    Text -> "text"
  }
  invoke(
    context,
    program,
    Invocation(
      subcommand: "export",
      options: ["--format", format],
      contracts: True,
      field: True,
      assignments: True,
    ),
  )
}

// --- Typechecking ----------------------------------------------------------

/// Typechecks a program without evaluating it. Contracts of the context are
/// typechecked too.
pub fn typecheck(context: Context, program: Source) -> Result(Nil, Error) {
  let parts =
    native.Parts(contracts: True, assignments: False, field: [], trace: False)
  use <- native_or_cli(context, program, parts, fn(session) {
    let strict = context.strict_typechecking(context)
    native.call_nil(context, session, native.Typecheck(strict))
  })
  invoke(
    context,
    program,
    Invocation(
      subcommand: "typecheck",
      options: case context.strict_typechecking(context) {
        True -> ["--strict-typechecking"]
        False -> []
      },
      contracts: True,
      field: False,
      assignments: False,
    ),
  )
  |> result.replace(Nil)
}

// --- Contracts -------------------------------------------------------------

/// Evaluates a program and checks the result against a contract, in addition
/// to the contracts of the context. Returns the evaluated result, which may
/// differ from the unchecked one when the contract sets default values.
///
/// A violation is reported as an `error.NickelError` whose kind is
/// `error.ContractViolation`.
pub fn validate(
  context: Context,
  program: Source,
  contract: Contract,
) -> Result(Value, Error) {
  eval(context.apply_contract(context, contract), program)
}

/// Checks a Gleam value against a Nickel contract. Returns the value as
/// produced by the contract (with defaults filled in, for instance).
///
/// ```gleam
/// let schema = contract.code("{ port | std.number.PosNat, host | String }")
/// nickel.validate_value(ctx, value.record([#("port", value.Int(-1))]), schema)
/// // -> Error(NickelError(kind: ContractViolation, ..))
/// ```
pub fn validate_value(
  context: Context,
  data: Value,
  contract: Contract,
) -> Result(Value, Error) {
  validate(
    context |> context.without_assignments |> context.unfocus,
    source.from_value(data),
    contract,
  )
}

/// Checks that a program satisfies the contracts of the context (and its own
/// annotations), discarding the result.
pub fn check(context: Context, program: Source) -> Result(Nil, Error) {
  export(context, program, Json) |> result.replace(Nil)
}

// --- Metadata --------------------------------------------------------------

/// Retrieves the metadata (documentation, type, contracts, priority…) of a
/// field. The path is relative to the context's focused field.
pub fn query(
  context: Context,
  program: Source,
  path: List(String),
) -> Result(FieldMetadata, Error) {
  let full_path = list.append(context.field(context), path)
  let parts =
    native.Parts(
      contracts: True,
      assignments: False,
      field: full_path,
      trace: False,
    )
  use <- native_or_cli(context, program, parts, fn(session) {
    native.call_metadata(context, session, native.Query)
  })
  use output <- result.try(invoke(
    context,
    program,
    Invocation(
      subcommand: "query",
      options: case full_path {
        [] -> ["--format", "json"]
        _ -> ["--format", "json", "--field", syntax.field_path(full_path)]
      },
      contracts: True,
      field: False,
      assignments: False,
    ),
  ))
  json.parse(output, metadata.decoder())
  |> result.map_error(fn(e) { json_error(e, output) })
}

// --- Miscellaneous ---------------------------------------------------------

/// The version of the Nickel executable, e.g. `"1.14.0"`. With the native
/// backend, the version of the `nickel-lang-core` library linked in, e.g.
/// `"0.19.0"`.
pub fn version(context: Context) -> Result(String, Error) {
  use <- bool.lazy_guard(
    context.backend(context) == context.Native,
    native.core_version,
  )
  use output <- result.try(
    run(context, ["--version"], None) |> result.map_error(error.ProcessError),
  )
  case output.exit_code {
    0 ->
      // "nickel-lang-cli nickel 1.14.0 (rev 9aaf291)"
      output.stdout
      |> string.split(" ")
      |> list.find(fn(word) {
        case string.first(word) {
          Ok("0") | Ok("1") | Ok("2") | Ok("3") | Ok("4") -> True
          Ok("5") | Ok("6") | Ok("7") | Ok("8") | Ok("9") -> True
          _ -> False
        }
      })
      |> result.map(string.trim)
      |> result.replace_error(error.UnexpectedOutput(
        "could not find a version number",
        output.stdout,
      ))
    _ ->
      Error(error.UnexpectedOutput(
        "`nickel --version` failed",
        output.stdout <> output.stderr,
      ))
  }
}

// --- Backends --------------------------------------------------------------

/// Runs `native_body` in a native session when the context selects the
/// native backend, and `cli_body` otherwise.
fn native_or_cli(
  context: Context,
  program: Source,
  parts: native.Parts,
  native_body: fn(native.Session) -> Result(a, Error),
  cli_body: fn() -> Result(a, Error),
) -> Result(a, Error) {
  case context.backend(context) {
    context.Cli -> cli_body()
    context.Native -> {
      use session <- result.try(native.start(context, program, parts))
      native_body(session)
    }
  }
}

fn no_parts() -> native.Parts {
  native.Parts(contracts: False, assignments: False, field: [], trace: False)
}

/// What `nickel export` uses: contracts, assignments and the focused field.
fn export_parts(context: Context) -> native.Parts {
  native.Parts(
    contracts: True,
    assignments: True,
    field: context.field(context),
    trace: False,
  )
}

// --- Invocation ------------------------------------------------------------

type Invocation {
  Invocation(
    subcommand: String,
    options: List(String),
    contracts: Bool,
    field: Bool,
    assignments: Bool,
  )
}

fn invoke(
  context: Context,
  program: Source,
  invocation: Invocation,
) -> Result(String, Error) {
  let contracts = case invocation.contracts {
    True -> context.contracts(context)
    False -> []
  }
  use contract_files <- with_contract_files(contracts)

  let import_paths = case list.any(contracts, is_inline_contract) {
    // Inline contracts live in temporary files: let their imports fall back
    // to the working directory.
    True -> list.append(context.import_paths(context), ["."])
    False -> context.import_paths(context)
  }
  let arguments = fn(error_format) {
    list.flatten([
      [invocation.subcommand],
      invocation.options,
      ["--error-format", error_format, "--color", "never"],
      list.flat_map(import_paths, fn(p) { ["--import-path", p] }),
      case context.manifest_path(context) {
        Some(path) -> ["--manifest-path", path]
        None -> []
      },
      case context.package_cache_dir(context) {
        Some(path) -> ["--package-cache-dir", path]
        None -> []
      },
      list.flat_map(contract_files, fn(p) { ["--apply-contract", p] }),
      case invocation.field, context.field(context) {
        True, [_, ..] as path -> ["--field", syntax.field_path(path)]
        _, _ -> []
      },
      case program {
        source.Files(paths) -> paths
        source.Code(_) -> []
      },
      case invocation.assignments, context.assignments(context) {
        True, [_, ..] as assignments -> [
          "--",
          ..list.flat_map(assignments, context.assignment_arguments)
        ]
        _, _ -> []
      },
    ])
  }
  let stdin = case program {
    source.Code(code) -> Some(code)
    source.Files(_) -> None
  }

  use output <- result.try(
    run(context, arguments("json"), stdin)
    |> result.map_error(error.ProcessError),
  )
  case output.exit_code {
    0 -> Ok(output.stdout)
    _ -> {
      let diagnostics = error.parse_diagnostics(output.stderr)
      let rendered = case diagnostics, context.render_errors(context) {
        Ok(_), True ->
          case run(context, arguments("text"), stdin) {
            Ok(rendered) -> rendered.stderr
            Error(_) -> ""
          }
        Ok(_), False -> ""
        // Not a structured report (a crash, or a CLI usage error): keep the
        // raw output as the rendering.
        Error(_), _ -> output.stderr
      }
      let diagnostics = result.unwrap(diagnostics, [])
      Error(error.NickelError(
        kind: error.classify(diagnostics),
        diagnostics:,
        rendered:,
      ))
    }
  }
}

fn run(
  context: Context,
  arguments: List(String),
  stdin: Option(String),
) -> Result(runner.Output, runner.RunError) {
  let run = context.runner(context)
  run(runner.Command(
    executable: context.executable(context),
    arguments:,
    working_directory: context.working_directory(context),
    environment: context.environment(context),
    stdin:,
    timeout: context.timeout(context),
  ))
}

fn is_inline_contract(contract: Contract) -> Bool {
  case contract {
    contract.ContractCode(_) -> True
    contract.ContractFile(_) -> False
  }
}

/// Writes inline contracts to temporary files for the duration of `body`.
fn with_contract_files(
  contracts: List(Contract),
  body: fn(List(String)) -> Result(a, Error),
) -> Result(a, Error) {
  let #(paths, temporary, failure) =
    list.fold(contracts, #([], [], None), fn(acc, contract) {
      let #(paths, temporary, failure) = acc
      case failure, contract {
        Some(_), _ -> acc
        None, contract.ContractFile(path) -> #([path, ..paths], temporary, None)
        None, contract.ContractCode(code) ->
          case write_temp_file(code, ".ncl") {
            Ok(path) -> #([path, ..paths], [path, ..temporary], None)
            Error(reason) -> #(paths, temporary, Some(reason))
          }
      }
    })
  let outcome = case failure {
    Some(reason) -> Error(error.TemporaryFileError(reason))
    None -> body(list.reverse(paths))
  }
  list.each(temporary, delete_file)
  outcome
}

fn json_error(error: json.DecodeError, output: String) -> Error {
  case error {
    json.UnableToDecode(errors) -> error.DecodeError(errors)
    json.UnexpectedEndOfInput ->
      error.UnexpectedOutput("unexpected end of JSON input", output)
    json.UnexpectedByte(byte) ->
      error.UnexpectedOutput("unexpected byte in JSON: " <> byte, output)
    json.UnexpectedSequence(sequence) ->
      error.UnexpectedOutput(
        "unexpected sequence in JSON: " <> sequence,
        output,
      )
  }
}

@external(erlang, "nickel_ffi", "write_temp_file")
fn write_temp_file(
  contents: String,
  extension: String,
) -> Result(String, String)

@external(erlang, "nickel_ffi", "delete_file")
fn delete_file(path: String) -> Nil
