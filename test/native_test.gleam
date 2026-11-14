//// Tests of what only the native backend does: lazy evaluation, exact
//// numbers, enum values. Skipped when the native library isn't loaded, unless
//// `NCL_NIF` is set, in which case it must load.

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import ncl
import ncl/context
import ncl/contract
import ncl/error
import ncl/lazy
import ncl/native
import ncl/source
import ncl/value

fn native_context() -> context.Context {
  context.new() |> context.with_backend(context.Native)
}

/// Runs a test if the native library is loaded.
fn with_native(test_body: fn() -> a) -> Nil {
  case native.load_error(), getenv("NCL_NIF") {
    Ok(Nil), _ -> {
      test_body()
      Nil
    }
    Error(reason), Ok(_) -> panic as reason
    Error(_), Error(Nil) -> Nil
  }
}

@external(erlang, "ncl_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

fn load(code: String) -> lazy.Program {
  let assert Ok(program) = lazy.new(native_context(), source.code(code))
  program
}

// --- Backend ----------------------------------------------------------------

pub fn exact_big_integer_test() {
  use <- with_native
  assert ncl.eval(native_context(), source.code("2 * 10000000000000000000000"))
    == Ok(value.Int(20_000_000_000_000_000_000_000))
}

pub fn core_version_test() {
  use <- with_native
  let assert Ok(version) = native.core_version()
  assert ncl.version(native_context()) == Ok(version)
}

pub fn inline_contract_test() {
  use <- with_native
  let ctx =
    native_context()
    |> context.apply_contract(contract.code("{ port | std.number.Nat }"))
  let assert Error(error.NickelError(kind: error.ContractViolation, ..)) =
    ncl.eval(ctx, source.code("{ port = -1 }"))
}

@external(erlang, "ncl_test_ffi", "package_fixture")
fn package_fixture() -> String

pub fn package_manifest_test() {
  use <- with_native
  let dir = package_fixture()
  let ctx =
    native_context()
    |> context.with_working_directory(dir <> "/app")
    |> context.with_manifest_path("Nickel-pkg.ncl")
    |> context.with_package_cache_dir(dir <> "/cache")
  assert ncl.eval(ctx, source.file("main.ncl"))
    == Ok(value.Record(dict.from_list([#("answer", value.Int(42))])))
  // In-memory code too.
  assert ncl.eval(ctx, source.code("(import lib).value + 1"))
    == Ok(value.Int(43))
  // Without the manifest, `lib` is unknown.
  let assert Error(error.NickelError(kind: error.ImportError, ..)) =
    ncl.eval(
      native_context() |> context.with_working_directory(dir <> "/app"),
      source.file("main.ncl"),
    )
}

pub fn bad_manifest_test() {
  use <- with_native
  let ctx =
    native_context()
    |> context.with_manifest_path(package_fixture() <> "/bad/Nickel-pkg.ncl")
  let assert Error(error.NickelError(kind: error.PackageError, ..)) =
    ncl.eval(ctx, source.code("1"))
}

fn one_to_fifty() -> List(Int) {
  list.repeat(Nil, 50) |> list.index_map(fn(_, i) { i + 1 })
}

pub fn concurrent_evaluations_test() {
  use <- with_native
  let subject = process.new_subject()
  one_to_fifty()
  |> list.each(fn(n) {
    process.spawn(fn() {
      let code = string.inspect(n) <> " * 2"
      process.send(subject, #(n, ncl.eval(native_context(), source.code(code))))
    })
  })
  one_to_fifty()
  |> list.each(fn(_) {
    let assert Ok(#(n, result)) = process.receive(subject, 10_000)
    assert result == Ok(value.Int(n * 2))
  })
}

// --- Lazy evaluation --------------------------------------------------------

pub fn lazy_reads_only_what_it_needs_test() {
  use <- with_native
  let program =
    load(
      "{ servers = { api = { port = 8000 + 80 }, broken = 1 + \"x\" }, other = std.fail_with \"never\" }",
    )
  let assert Ok(root) = lazy.eval_shallow(program)
  let assert Ok(port) = lazy.get(root, ["servers", "api", "port"])
  assert lazy.view(port) == Ok(lazy.Number(8080, 1))
  // The broken field only fails when it is read.
  let assert Ok(broken) = lazy.get(root, ["servers", "broken"])
  let assert Error(error.NickelError(..)) = lazy.force(broken)
  // Whole-program evaluation sees the error.
  let assert Error(error.NickelError(..)) = lazy.eval_deep(program)
}

pub fn lazy_view_test() {
  use <- with_native
  let program =
    load("{ n = 1 / 3, tag = 'Blue, variant = 'Some (1 + 1), opt | optional }")
  let assert Ok(root) = lazy.eval_shallow(program)
  let assert Ok(lazy.Record(fields)) = lazy.view(root)
  assert list.map(fields, fn(f) { f.0 }) |> list.sort(string.compare)
    == ["n", "opt", "tag", "variant"]
  let assert Ok(None) = list.key_find(fields, "opt")
  let assert Ok(n) = lazy.field(root, "n")
  assert lazy.view(n) == Ok(lazy.Number(1, 3))
  let assert Ok(tag) = lazy.field(root, "tag")
  assert lazy.view(tag) == Ok(lazy.EnumTag("Blue"))
  let assert Ok(variant) = lazy.field(root, "variant")
  let assert Ok(lazy.EnumVariant("Some", argument)) = lazy.view(variant)
  assert lazy.to_value(argument) == Ok(value.Int(2))
  let assert Error(error.NativeError(_)) = lazy.field(root, "missing")
}

pub fn lazy_arrays_test() {
  use <- with_native
  let assert Ok(root) = lazy.eval_shallow(load("[1, 2 + 3, \"x\"]"))
  let assert Ok(second) = lazy.index(root, 1)
  assert lazy.view(second) == Ok(lazy.Number(5, 1))
  let assert Error(_) = lazy.index(root, 3)
}

pub fn lazy_to_value_and_decode_test() {
  use <- with_native
  let assert Ok(root) =
    lazy.eval_shallow(load(
      "{ server = { host = \"a\" ++ \"b\", port = 80, secret | not_exported = 1 } }",
    ))
  let assert Ok(server) = lazy.field(root, "server")
  assert lazy.to_value(server)
    == Ok(
      value.record([#("host", value.String("ab")), #("port", value.Int(80))]),
    )
  assert lazy.decode(server, decode.at(["port"], decode.int)) == Ok(80)
}

pub fn lazy_pending_contract_test() {
  use <- with_native
  let assert Ok(root) =
    lazy.eval_shallow(load("{ port = -1 } | { port | std.number.Nat }"))
  let assert Ok(port) = lazy.field(root, "port")
  let assert Error(error.NickelError(kind: error.ContractViolation, ..)) =
    lazy.force(port)
}

pub fn lazy_serialization_test() {
  use <- with_native
  let assert Ok(root) = lazy.eval_deep(load("{ a = [1, 2] }"))
  let assert Ok(json) = lazy.to_json(root)
  assert string.replace(json, " ", "") |> string.replace("\n", "")
    == "{\"a\":[1,2]}"
  let assert Ok(toml) = lazy.to_toml(root)
  assert string.contains(toml, "a = [")
  let assert Ok(text) = lazy.to_string(root)
  assert string.contains(text, "a")
}

pub fn lazy_trace_test() {
  use <- with_native
  let program = load("std.trace \"hello\" 1")
  let assert Ok(_) = lazy.eval_deep(program)
  let assert Ok(trace) = lazy.take_trace(program)
  assert string.contains(trace, "hello")
  assert lazy.take_trace(program) == Ok("")
}

pub fn lazy_uses_context_test() {
  use <- with_native
  let ctx =
    native_context()
    |> context.with_working_directory("test/fixtures")
    |> context.add_import_path("lib")
    |> context.assign(["server", "port"], value.Int(9000))
  let assert Ok(program) = lazy.new(ctx, source.file("server.ncl"))
  let assert Ok(root) = lazy.eval_shallow(program)
  let assert Ok(port) = lazy.get(root, ["server", "port"])
  assert lazy.view(port) == Ok(lazy.Number(9000, 1))
  let assert Ok(banner) = lazy.field(root, "banner")
  assert lazy.to_value(banner) == Ok(value.String("welcome to nickel"))
}

pub fn lazy_errors_test() {
  use <- with_native
  let assert Error(error.NickelError(kind: error.ParseError, ..)) =
    lazy.eval_shallow(load("{ a = "))
  let assert Error(error.NickelError(..)) =
    lazy.new(native_context(), source.file("does-not-exist.ncl"))
  Nil
}
