//// Lazy evaluation with the native backend, in the style of Nickel's Go
//// bindings: evaluate a program only as far as needed, then walk into the
//// parts you use. Nothing else is evaluated, so a configuration with an
//// error or an expensive computation in a field you never read still works.
////
//// ```gleam
//// import nickel/context
//// import nickel/lazy
//// import nickel/source
////
//// let assert Ok(program) =
////   lazy.new(context.new(), source.file("cluster.ncl"))
//// let assert Ok(root) = lazy.eval_shallow(program)
//// // Evaluates `servers`, then `servers.api`, then its `port`, and nothing else.
//// let assert Ok(port) = lazy.get(root, ["servers", "api", "port"])
//// let assert Ok(lazy.Number(8080, 1)) = lazy.view(port)
//// ```
////
//// Requires the native library: see `nickel/native`. The context's backend
//// setting is ignored here; its import paths, contracts, assignments, focused
//// field, working directory and timeout apply as for `nickel.eval`.
////
//// Programs and expressions are ordinary values: share them between
//// processes freely. Each program runs on its own thread, which handles one
//// request at a time, and is freed once the program and every expression
//// from it are garbage-collected.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nickel/context.{type Context}
import nickel/error.{type Error}
import nickel/native
import nickel/source.{type Source}
import nickel/value.{type Value}

/// A Nickel program, loaded and ready to evaluate.
pub opaque type Program {
  Program(context: Context, session: native.Session)
}

/// A Nickel expression from a program, evaluated or not.
pub opaque type Expr {
  Expr(program: Program, handle: native.Handle)
}

/// One level of an expression. Nested values are expressions themselves,
/// which may not be evaluated yet: pass them to `force` (or use `view`,
/// `get` and `to_value`, which force for you).
pub type View {
  Null
  Bool(Bool)
  /// Nickel numbers are exact rationals. Whole numbers have denominator 1.
  Number(numerator: Int, denominator: Int)
  String(String)
  /// An enum tag such as `'Blue`.
  EnumTag(String)
  /// An enum variant such as `'Some 1`.
  EnumVariant(tag: String, argument: Expr)
  /// Fields in source order. A field declared without a value (an optional
  /// field, for instance) has `None`.
  Record(fields: List(#(String, Option(Expr))))
  Array(items: List(Expr))
  /// A value with no view, such as a function. See `to_string`.
  Other
}

/// Loads a program. Like `nickel eval`, it applies the context's contracts,
/// assignments and focused field.
pub fn new(context: Context, program: Source) -> Result(Program, Error) {
  let parts =
    native.Parts(
      contracts: True,
      assignments: True,
      field: context.field(context),
      trace: True,
    )
  use session <- result.map(native.start(context, program, parts))
  Program(context:, session:)
}

/// Evaluates the program to its outermost constructor: for a record, its
/// fields are known but not evaluated.
pub fn eval_shallow(program: Program) -> Result(Expr, Error) {
  eval(program, native.Shallow)
}

/// Evaluates the whole program.
pub fn eval_deep(program: Program) -> Result(Expr, Error) {
  eval(program, native.Deep)
}

/// Evaluates the whole program, leaving out fields marked `not_exported`.
pub fn eval_deep_for_export(program: Program) -> Result(Expr, Error) {
  eval(program, native.DeepForExport)
}

/// Evaluates the program's nested records, but not the other values in them.
/// Fields that need something missing are left unevaluated rather than
/// failing, so this works on incomplete configurations.
pub fn eval_record_spine(program: Program) -> Result(Expr, Error) {
  eval(program, native.RecordSpine)
}

fn eval(program: Program, mode: native.EvalMode) -> Result(Expr, Error) {
  native.call_handle(program.context, program.session, native.Eval(mode))
  |> result.map(Expr(program, _))
}

/// Evaluates an expression to its outermost constructor, applying any
/// contracts that are pending on it. Evaluated expressions are returned as
/// they are.
pub fn force(expr: Expr) -> Result(Expr, Error) {
  let Expr(program:, handle:) = expr
  native.call_handle(program.context, program.session, native.ForceExpr(handle))
  |> result.map(Expr(program, _))
}

/// Forces an expression and shows its outermost constructor.
pub fn view(expr: Expr) -> Result(View, Error) {
  use Expr(program:, handle:) <- result.try(force(expr))
  use raw <- result.try(native.call_view(
    program.context,
    program.session,
    native.Inspect(handle),
  ))
  let wrap = Expr(program, _)
  Ok(case raw {
    native.Null -> Null
    native.Bool(b) -> Bool(b)
    native.Number(n, d) -> Number(n, d)
    native.String(s) -> String(s)
    native.EnumTag(t) -> EnumTag(t)
    native.EnumVariant(t, a) -> EnumVariant(t, wrap(a))
    native.Record(fields) ->
      Record(list.map(fields, fn(f) { #(f.0, option.map(f.1, wrap)) }))
    native.Array(items) -> Array(list.map(items, wrap))
    // Forced first, so never unevaluated.
    native.Other | native.Unevaluated -> Other
  })
}

/// Forces an expression, which must be a record, and returns one of its
/// fields, unevaluated.
pub fn field(expr: Expr, name: String) -> Result(Expr, Error) {
  use view <- result.try(view(expr))
  case view {
    Record(fields) ->
      case list.key_find(fields, name) {
        Ok(Some(value)) -> Ok(value)
        Ok(None) ->
          Error(error.NativeError("field `" <> name <> "` has no value"))
        Error(Nil) -> Error(error.NativeError("no field `" <> name <> "`"))
      }
    _ -> Error(error.NativeError("not a record: can't get `" <> name <> "`"))
  }
}

/// Forces an expression, which must be an array, and returns one of its
/// elements (from 0), unevaluated.
pub fn index(expr: Expr, position: Int) -> Result(Expr, Error) {
  use view <- result.try(view(expr))
  let missing = fn() {
    error.NativeError("no element at index " <> int.to_string(position))
  }
  case view {
    Array(items) if position >= 0 ->
      items
      |> list.drop(position)
      |> list.first
      |> result.replace_error(missing())
    Array(_) -> Error(missing())
    _ -> Error(error.NativeError("not an array"))
  }
}

/// Follows a path of field names through nested records, evaluating only
/// the records on the way. An empty path returns the expression itself.
pub fn get(expr: Expr, path: List(String)) -> Result(Expr, Error) {
  list.try_fold(path, expr, field)
}

/// Evaluates an expression fully and converts it to a `Value`, as
/// `nickel.eval` would: fields marked `not_exported` are left out and enum
/// tags become strings. Fails on enum variants and functions.
pub fn to_value(expr: Expr) -> Result(Value, Error) {
  let Expr(program:, handle:) = expr
  native.call_value(program.context, program.session, native.ToValue(handle))
}

/// Evaluates an expression fully and decodes it.
pub fn decode(expr: Expr, decoder: decode.Decoder(a)) -> Result(a, Error) {
  use data <- result.try(to_value(expr))
  value.decode(data, decoder) |> result.map_error(error.DecodeError)
}

/// Serializes an expression, which must already be fully evaluated (from
/// `eval_deep`, for instance), as JSON.
pub fn to_json(expr: Expr) -> Result(String, Error) {
  export(expr, native.Json)
}

/// Serializes a fully evaluated expression as YAML.
pub fn to_yaml(expr: Expr) -> Result(String, Error) {
  export(expr, native.Yaml)
}

/// Serializes a fully evaluated expression as TOML.
pub fn to_toml(expr: Expr) -> Result(String, Error) {
  export(expr, native.Toml)
}

fn export(expr: Expr, format: native.Format) -> Result(String, Error) {
  let Expr(program:, handle:) = expr
  native.call_string(
    program.context,
    program.session,
    native.ExportExpr(handle, format),
  )
}

/// Renders an expression as Nickel source code. Unevaluated parts are shown
/// as the code that would compute them.
pub fn to_string(expr: Expr) -> Result(String, Error) {
  let Expr(program:, handle:) = expr
  native.call_string(program.context, program.session, native.Display(handle))
}

/// The output of `std.trace` since the last call, then clears it.
pub fn take_trace(program: Program) -> Result(String, Error) {
  native.call_string(program.context, program.session, native.TakeTrace)
}
