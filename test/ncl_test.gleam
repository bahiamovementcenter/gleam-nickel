import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import ncl
import ncl/context
import ncl/contract
import ncl/error
import ncl/imports
import ncl/metadata
import ncl/runner
import ncl/source
import ncl/syntax
import ncl/value

pub fn main() -> Nil {
  gleeunit.main()
}

/// The suite runs against the command line backend, or against the native
/// one when `NCL_TEST_BACKEND=native` (CI runs both).
fn new_context() -> context.Context {
  case native() {
    True -> context.new() |> context.with_backend(context.Native)
    False -> context.new()
  }
}

fn native() -> Bool {
  getenv("NCL_TEST_BACKEND") == Ok("native")
}

/// Skips a test that is about running the `nickel` executable.
fn cli_only(test_body: fn() -> Nil) -> Nil {
  case native() {
    True -> Nil
    False -> test_body()
  }
}

@external(erlang, "ncl_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

fn fixtures() -> context.Context {
  new_context()
  |> context.with_working_directory("test/fixtures")
  |> context.add_import_path("lib")
}

// --- Evaluation -------------------------------------------------------------

pub fn eval_code_test() {
  let assert Ok(result) =
    ncl.eval(
      new_context(),
      source.code(
        "{ a = 1 + 2, b = [true, null, \"x\"], c = 1.5, d = { e = 'tag } }",
      ),
    )
  assert result
    == value.record([
      #("a", value.Int(3)),
      #("b", value.Array([value.Bool(True), value.Null, value.String("x")])),
      #("c", value.Float(1.5)),
      #("d", value.record([#("e", value.String("tag"))])),
    ])
}

pub fn eval_big_integer_test() {
  let assert Ok(value.Int(n)) =
    ncl.eval(new_context(), source.code("12345678901234567890 * 1"))
  assert n == 12_345_678_901_234_567_890
}

pub fn eval_file_with_imports_test() {
  let assert Ok(config) = ncl.eval(fixtures(), source.file("server.ncl"))
  assert value.get(config, ["server", "port"]) == Ok(value.Int(8080))
  assert value.get(config, ["banner"]) == Ok(value.String("welcome to nickel"))
  assert value.get(config, ["features"])
    == Ok(value.Array([value.String("metrics"), value.String("tracing")]))
}

pub fn eval_merges_several_files_test() {
  let assert Ok(config) =
    ncl.eval(fixtures(), source.files(["defaults.ncl", "lib/sub/helper.ncl"]))
  assert config
    == value.record([
      #("host", value.String("127.0.0.1")),
      #("name", value.String("nickel")),
    ])
}

type Server {
  Server(host: String, port: Int, environment: String)
}

fn server_decoder() -> decode.Decoder(Server) {
  use host <- decode.field("host", decode.string)
  use port <- decode.field("port", decode.int)
  use environment <- decode.field("environment", decode.string)
  decode.success(Server(host:, port:, environment:))
}

pub fn eval_as_test() {
  let assert Ok(server) =
    ncl.eval_as(
      fixtures(),
      source.file("server.ncl"),
      decode.at(["server"], server_decoder()),
    )
  assert server == Server("127.0.0.1", 8080, "development")
}

pub fn eval_as_decode_error_test() {
  let assert Error(error.DecodeError(errors)) =
    ncl.eval_as(new_context(), source.code("{ port = \"x\" }"), {
      use port <- decode.field("port", decode.int)
      decode.success(port)
    })
  let assert [
    decode.DecodeError(expected: "Int", found: "String", path: ["port"]),
  ] = errors
}

pub fn value_decode_test() {
  let assert Ok(config) = ncl.eval(fixtures(), source.file("server.ncl"))
  assert value.decode(config, decode.at(["server"], server_decoder()))
    == Ok(Server("127.0.0.1", 8080, "development"))
  assert value.decode(
      config,
      decode.at(["features"], decode.list(decode.string)),
    )
    == Ok(["metrics", "tracing"])
}

pub fn export_formats_test() {
  let program = source.code("{ name = \"demo\", replicas = 3 }")
  let assert Ok(yaml) = ncl.export(new_context(), program, ncl.Yaml)
  assert string.contains(yaml, "name: demo")
  let assert Ok(toml) = ncl.export(new_context(), program, ncl.Toml)
  assert string.contains(toml, "replicas = 3")
  let assert Ok(text) =
    ncl.export(new_context(), source.code("\"a\" ++ \"b\""), ncl.Text)
  assert text == "ab"
}

pub fn focus_test() {
  let ctx = fixtures() |> context.focus(["server", "host"])
  assert ncl.eval(ctx, source.file("server.ncl"))
    == Ok(value.String("127.0.0.1"))
}

// --- Context: assignments ---------------------------------------------------

pub fn assign_test() {
  let ctx =
    fixtures()
    |> context.assign(["server", "port"], value.Int(9000))
    |> context.assign_code(
      ["server", "environment"],
      syntax.enum_tag("production"),
    )
  let assert Ok(server) =
    ncl.eval_as(
      ctx,
      source.file("server.ncl"),
      decode.at(["server"], server_decoder()),
    )
  assert server == Server("127.0.0.1", 9000, "production")
}

pub fn assign_code_test() {
  let ctx = fixtures() |> context.assign_code(["server", "port"], "4000 + 443")
  let assert Ok(config) = ncl.eval(ctx, source.file("server.ncl"))
  assert value.get(config, ["server", "port"]) == Ok(value.Int(4443))
}

pub fn override_test() {
  let ctx =
    new_context()
    |> context.override(["name"], value.String("with \"quotes\" and %{braces}"))
  assert ncl.eval(ctx, source.code("{ name = \"fixed\" }"))
    == Ok(
      value.record([#("name", value.String("with \"quotes\" and %{braces}"))]),
    )
}

pub fn assignment_violating_contract_test() {
  let ctx = fixtures() |> context.assign(["server", "port"], value.Int(-1))
  let assert Error(error.NickelError(kind: error.ContractViolation, ..)) =
    ncl.eval(ctx, source.file("server.ncl"))
}

pub fn later_assignment_replaces_earlier_test() {
  let ctx =
    new_context()
    |> context.assign(["a"], value.Int(1))
    |> context.assign(["a"], value.Int(2))
  assert list.length(context.assignments(ctx)) == 1
  assert ncl.eval(ctx, source.code("{ a | default = 0 }"))
    == Ok(value.record([#("a", value.Int(2))]))
}

pub fn environment_import_path_test() {
  let ctx =
    new_context()
    |> context.with_working_directory("test/fixtures")
    |> context.set_env("NICKEL_IMPORT_PATH", "lib/sub")
  assert ncl.eval(ctx, source.code("(import \"helper.ncl\").name"))
    == Ok(value.String("nickel"))
}

// --- Contracts --------------------------------------------------------------

pub fn validate_with_contract_file_test() {
  let assert Ok(_) =
    ncl.validate(
      fixtures(),
      source.file("server.ncl"),
      contract.file("schema.ncl"),
    )
  let assert Error(error.NickelError(kind: error.ContractViolation, ..)) =
    ncl.validate(
      fixtures(),
      source.code("{ server = { host = 1, port = 80 } }"),
      contract.file("schema.ncl"),
    )
}

pub fn validate_with_inline_contract_test() {
  let schema = contract.code("{ port | std.number.PosNat, host | String }")
  let assert Ok(_) =
    ncl.validate(
      new_context(),
      source.code("{ port = 80, host = \"x\" }"),
      schema,
    )
  let assert Error(error.NickelError(
    kind: error.ContractViolation,
    diagnostics: [diagnostic, ..],
    rendered:,
  )) =
    ncl.validate(
      new_context(),
      source.code("{ port = 0, host = \"x\" }"),
      schema,
    )
  assert string.contains(diagnostic.message, "contract broken")
  assert string.contains(rendered, "port")
}

pub fn inline_contract_can_import_test() {
  let schema = contract.code("import \"schema.ncl\"")
  let ctx = new_context() |> context.with_working_directory("test/fixtures")
  let assert Ok(_) =
    ncl.validate(
      ctx,
      source.code("{ server = { host = \"h\", port = 1 } }"),
      schema,
    )
}

pub fn validate_value_test() {
  let schema =
    contract.code(
      "{ port | std.number.PosNat, host | String | default = \"localhost\" }",
    )
  assert ncl.validate_value(
      new_context(),
      value.record([#("port", value.Int(80))]),
      schema,
    )
    == Ok(
      value.record([
        #("host", value.String("localhost")),
        #("port", value.Int(80)),
      ]),
    )
  let assert Error(error.NickelError(kind: error.ContractViolation, ..)) =
    ncl.validate_value(
      new_context(),
      value.record([#("port", value.Int(-3))]),
      schema,
    )
}

pub fn context_contracts_apply_to_every_call_test() {
  let ctx = new_context() |> context.apply_contract(contract.code("Number"))
  let assert Ok(value.Int(1)) = ncl.eval(ctx, source.code("1"))
  let assert Error(error.NickelError(kind: error.ContractViolation, ..)) =
    ncl.eval(ctx, source.code("\"one\""))
  let assert Ok(_) =
    ncl.eval(context.without_contracts(ctx), source.code("\"one\""))
}

// --- Parsing and typechecking ----------------------------------------------

pub fn parse_test() {
  assert ncl.parse(new_context(), source.code("{ a = undefined_name }"))
    == Ok(Nil)
  let assert Error(error.NickelError(kind: error.ParseError, ..)) =
    ncl.parse(new_context(), source.code("{ a = 1 + }"))
}

pub fn typecheck_test() {
  assert ncl.typecheck(new_context(), source.code("{ a : Number = 1 }"))
    == Ok(Nil)
  let assert Error(error.NickelError(kind: error.TypeError, ..)) =
    ncl.typecheck(new_context(), source.code("{ a : Number = \"x\" }"))
}

// --- Errors -----------------------------------------------------------------

pub fn parse_error_test() {
  let assert Error(error.NickelError(
    kind: error.ParseError,
    diagnostics: [
      error.Diagnostic(
        severity: error.ErrorSeverity,
        labels: [error.Label(style: error.Primary, ..), ..],
        ..,
      ),
    ],
    rendered:,
  )) = ncl.eval(new_context(), source.code("{ a = 1 + }"))
  assert string.contains(rendered, "<stdin>")
}

pub fn missing_import_error_test() {
  let assert Error(error.NickelError(kind: error.ImportError, ..)) =
    ncl.eval(new_context(), source.code("import \"does-not-exist.ncl\""))
}

pub fn evaluation_error_test() {
  let assert Error(err) =
    ncl.eval(new_context(), source.code("{ a = 1 + \"x\" }"))
  let assert error.NickelError(kind: error.EvaluationError, ..) = err
  assert error.messages(err) == ["dynamic type error"]
}

pub fn unbound_identifier_error_test() {
  let assert Error(error.NickelError(kind: error.UnboundIdentifier, ..)) =
    ncl.eval(new_context(), source.code("{ a = b }"))
}

pub fn serialization_error_test() {
  let assert Error(error.NickelError(kind: error.SerializationError, ..)) =
    ncl.eval(new_context(), source.code("{ f = fun x => x }"))
}

pub fn missing_field_error_test() {
  let ctx = new_context() |> context.focus(["nope"])
  let assert Error(error.NickelError(kind: error.MissingField, ..)) =
    ncl.eval(ctx, source.code("{ a = 1 }"))
}

pub fn unrendered_errors_test() {
  let ctx = new_context() |> context.with_rendered_errors(False)
  let assert Error(err) = ncl.eval(ctx, source.code("{ a = 1 + }"))
  let assert error.NickelError(rendered: "", ..) = err
  assert string.starts_with(error.describe(err), "error: unexpected token")
}

pub fn executable_not_found_test() {
  use <- cli_only
  let ctx = new_context() |> context.with_executable("nickel-does-not-exist")
  assert ncl.eval(ctx, source.code("1"))
    == Error(
      error.ProcessError(runner.ExecutableNotFound("nickel-does-not-exist")),
    )
}

pub fn timeout_test() {
  let ctx = new_context() |> context.with_timeout(300)
  let program = "let rec loop = fun x => loop (x + 1) in loop 0"
  assert ncl.eval(ctx, source.code(program))
    == Error(error.ProcessError(runner.TimedOut(300)))
}

pub fn custom_runner_test() {
  use <- cli_only
  let fake = fn(command: runner.Command) {
    let assert ["export", ..] = command.arguments
    let assert Some("anything") = command.stdin
    Ok(runner.Output(exit_code: 0, stdout: "{\"stub\": true}", stderr: ""))
  }
  let ctx = new_context() |> context.with_runner(fake)
  assert ncl.eval(ctx, source.code("anything"))
    == Ok(value.record([#("stub", value.Bool(True))]))
}

// --- Metadata ---------------------------------------------------------------

pub fn query_test() {
  let assert Ok(meta) =
    ncl.query(fixtures(), source.file("server.ncl"), ["server", "host"])
  assert meta.doc == Some("Interface to listen on")
  assert meta.contracts == ["String"]
  assert meta.priority == metadata.DefaultPriority
  let assert Ok(meta) =
    ncl.query(fixtures(), source.file("server.ncl"), ["server"])
  assert meta.sub_fields == ["environment", "host", "port"]
  assert meta.doc == None
}

pub fn query_type_test() {
  let assert Ok(meta) =
    ncl.query(new_context(), source.code("{ a : Number | force = 1 }"), [
      "a",
    ])
  assert meta.type_annotation == Some("Number")
  assert meta.priority == metadata.ForcePriority
}

pub fn version_test() {
  let assert Ok(version) = ncl.version(new_context())
  let assert [_, _, _] = string.split(version, ".")
}

// --- Imports ----------------------------------------------------------------

pub fn scan_test() {
  let code =
    "
    # import \"commented.ncl\"
    let a = import \"a.ncl\" in
    let s = \"import \\\"not-an-import.ncl\\\"\" in
    let m = m%\"import \"also-not.ncl\" \"% in
    let important = 1 in
    { b = import \"data.yaml\" as 'Yaml, c = (import \"c.ncl\").x }
    "
  assert imports.scan(code)
    == [
      imports.Import("a.ncl", None),
      imports.Import("data.yaml", Some("Yaml")),
      imports.Import("c.ncl", None),
    ]
}

pub fn resolve_test() {
  let ctx = fixtures()
  let base = imports.base_directory(ctx)
  assert imports.resolve(ctx, base, "shared.ncl")
    == Ok(base <> "/lib/shared.ncl")
  assert imports.resolve(ctx, base, "defaults.ncl")
    == Ok(base <> "/defaults.ncl")
  let assert Error(imports.NotFound(name: "nope.ncl", searched:, ..)) =
    imports.resolve(ctx, base, "nope.ncl")
  assert searched == [base, base <> "/lib"]
}

pub fn dependencies_test() {
  let ctx = fixtures()
  let base = imports.base_directory(ctx)
  let assert Ok(files) = imports.dependencies(ctx, source.file("server.ncl"))
  assert files
    == [
      base <> "/server.ncl",
      base <> "/defaults.ncl",
      base <> "/features.json",
      base <> "/lib/shared.ncl",
      base <> "/lib/sub/helper.ncl",
    ]
}

pub fn dependencies_missing_test() {
  let assert Error(imports.NotFound(name: "missing.ncl", ..)) =
    imports.dependencies(new_context(), source.code("import \"missing.ncl\""))
}

pub fn normalize_test() {
  assert imports.normalize("/a/./b/../c//d") == "/a/c/d"
  assert imports.absolute("x/../y.ncl", "/base") == "/base/y.ncl"
}

// --- Values and syntax ------------------------------------------------------

pub fn value_round_trip_through_nickel_test() {
  let original =
    value.record([
      #("plain", value.String("tab\there \"q\" \\ %{x} 100%")),
      #("needs quoting", value.Int(-12)),
      #("if", value.Float(-0.25)),
      #("big", value.Float(1.0e20)),
      #("list", value.Array([value.Null, value.Bool(False), value.record([])])),
      #("unicode", value.String("héllo ✓\n")),
    ])
  let expected = case native() {
    // The native backend keeps whole numbers exact, where `nickel export`
    // turns those beyond 64 bits into floats.
    True ->
      value.merge(
        original,
        value.record([#("big", value.Int(100_000_000_000_000_000_000))]),
      )
    False -> original
  }
  assert ncl.eval(new_context(), source.from_value(original)) == Ok(expected)
}

pub fn value_json_test() {
  let v = value.record([#("b", value.Int(1)), #("a", value.Array([]))])
  assert value.from_json("{\"b\":1,\"a\":[]}") == Ok(v)
  assert value.to_json(v) |> json_to_string == "{\"a\":[],\"b\":1}"
  assert value.from_json("null") == Ok(value.Null)
}

fn json_to_string(j: json.Json) -> String {
  json.to_string(j)
}

pub fn value_accessors_test() {
  let v =
    value.record([
      #("xs", value.Array([value.Int(1), value.Int(2)])),
      #("r", value.record([#("k", value.Bool(True))])),
    ])
  assert value.get(v, ["r", "k"]) == Ok(value.Bool(True))
  assert value.get(v, []) == Ok(v)
  assert value.get(v, ["missing"]) == Error(Nil)
  let assert Ok(xs) = value.field(v, "xs")
  assert value.at(xs, 1) == Ok(value.Int(2))
  assert value.at(xs, 2) == Error(Nil)
  assert value.kind(xs) == "Array"
}

pub fn value_merge_test() {
  let a =
    value.record([
      #("x", value.Int(1)),
      #("n", value.record([#("p", value.Int(1)), #("q", value.Int(2))])),
    ])
  let b = value.record([#("n", value.record([#("q", value.Int(3))]))])
  let assert value.Record(fields) = value.merge(a, b)
  assert dict.get(fields, "n")
    == Ok(value.record([#("p", value.Int(1)), #("q", value.Int(3))]))
}

pub fn syntax_test() {
  assert syntax.field_path(["server", "tls port", "if"])
    == "server.\"tls port\".\"if\""
  assert syntax.is_identifier("snake_case-name'")
  assert !syntax.is_identifier("1abc")
  assert syntax.string_literal("a\"b") == "\"a\\\"b\""
}
