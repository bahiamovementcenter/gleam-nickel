//// A Gleam representation of fully evaluated, serializable Nickel values,
//// with conversions to and from JSON, Nickel source code, and `Dynamic`
//// (for use with `gleam/dynamic/decode` decoders).

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import ncl/syntax

/// An evaluated Nickel value.
///
/// Nickel numbers are arbitrary precision rationals. When exported they
/// become `Int` if they are whole numbers that fit in 64 bits and `Float`
/// otherwise. Enum tags are exported as `String`; to pass an enum tag *to*
/// Nickel, write it as code with `syntax.enum_tag`.
pub type Value {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  Array(List(Value))
  Record(Dict(String, Value))
}

/// Builds a record from a list of fields.
pub fn record(fields: List(#(String, Value))) -> Value {
  Record(dict.from_list(fields))
}

/// A decoder that accepts any JSON-like dynamic data and produces a `Value`.
pub fn decoder() -> decode.Decoder(Value) {
  use <- decode.recursive
  use option <- decode.then(decode.optional(decode.dynamic))
  case option {
    option.None -> decode.success(Null)
    option.Some(_) ->
      decode.one_of(decode.map(decode.bool, Bool), [
        decode.map(decode.int, Int),
        decode.map(decode.float, Float),
        decode.map(decode.string, String),
        decode.map(decode.list(decoder()), Array),
        decode.map(decode.dict(decode.string, decoder()), Record),
      ])
  }
}

/// Parses a JSON document into a `Value`.
pub fn from_json(json_text: String) -> Result(Value, json.DecodeError) {
  json.parse(json_text, decoder())
}

/// Converts a value to JSON.
pub fn to_json(value: Value) -> json.Json {
  case value {
    Null -> json.null()
    Bool(b) -> json.bool(b)
    Int(i) -> json.int(i)
    Float(f) -> json.float(f)
    String(s) -> json.string(s)
    Array(items) -> json.array(items, to_json)
    Record(fields) ->
      fields
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.map(fn(field) { #(field.0, to_json(field.1)) })
      |> json.object
  }
}

/// Renders a value as Nickel source code.
///
/// The output is a valid Nickel expression evaluating to the same value, so it
/// can be embedded in programs, passed as a customize-mode assignment, or
/// checked against a contract.
pub fn to_nickel(value: Value) -> String {
  case value {
    Null -> "null"
    Bool(True) -> "true"
    Bool(False) -> "false"
    Int(i) -> int.to_string(i)
    Float(f) -> float.to_string(f)
    String(s) -> syntax.string_literal(s)
    Array(items) ->
      "[" <> { items |> list.map(to_nickel) |> string.join(", ") } <> "]"
    Record(fields) ->
      case dict.is_empty(fields) {
        True -> "{}"
        False ->
          "{ "
          <> {
            fields
            |> dict.to_list
            |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
            |> list.map(fn(field) {
              syntax.field_name(field.0) <> " = " <> to_nickel(field.1)
            })
            |> string.join(", ")
          }
          <> " }"
      }
  }
}

/// Converts a value to `Dynamic`, so it can be decoded with any
/// `gleam/dynamic/decode` decoder.
pub fn to_dynamic(value: Value) -> Dynamic {
  case value {
    Null -> dynamic.nil()
    Bool(b) -> dynamic.bool(b)
    Int(i) -> dynamic.int(i)
    Float(f) -> dynamic.float(f)
    String(s) -> dynamic.string(s)
    Array(items) -> dynamic.list(list.map(items, to_dynamic))
    Record(fields) ->
      fields
      |> dict.to_list
      |> list.map(fn(field) { #(dynamic.string(field.0), to_dynamic(field.1)) })
      |> dynamic.properties
  }
}

/// Decodes a value into a typed Gleam value.
///
/// ```gleam
/// let port_decoder = decode.at(["server", "port"], decode.int)
/// value.decode(config, port_decoder)
/// ```
pub fn decode(
  value: Value,
  decoder: decode.Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  decode.run(to_dynamic(value), decoder)
}

/// Looks up a field of a record.
pub fn field(value: Value, name: String) -> Result(Value, Nil) {
  case value {
    Record(fields) -> dict.get(fields, name)
    _ -> Error(Nil)
  }
}

/// Looks up a nested field of a record by path. An empty path returns the
/// value itself.
pub fn get(value: Value, path: List(String)) -> Result(Value, Nil) {
  list.try_fold(path, value, field)
}

/// Looks up an element of an array by zero-based index.
pub fn at(value: Value, index: Int) -> Result(Value, Nil) {
  case value {
    Array(items) if index >= 0 -> items |> list.drop(index) |> list.first
    _ -> Error(Nil)
  }
}

/// The name of the kind of a value, for use in messages.
pub fn kind(value: Value) -> String {
  case value {
    Null -> "Null"
    Bool(_) -> "Bool"
    Int(_) | Float(_) -> "Number"
    String(_) -> "String"
    Array(_) -> "Array"
    Record(_) -> "Record"
  }
}

/// Recursively merges two records. Fields of `override` take precedence;
/// nested records are merged. For anything other than two records,
/// `override` is returned.
///
/// This is a plain data operation and does not follow Nickel's merge
/// semantics (priorities, contracts); use it to combine already exported
/// values.
pub fn merge(base: Value, override: Value) -> Value {
  case base, override {
    Record(a), Record(b) -> Record(dict.combine(a, b, merge))
    _, _ -> override
  }
}
