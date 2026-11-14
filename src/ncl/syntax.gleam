//// Helpers for producing fragments of Nickel source code safely.

import gleam/list
import gleam/string

/// Returns `True` if `name` can be written as a bare Nickel identifier,
/// e.g. as a record field name without quotes.
pub fn is_identifier(name: String) -> Bool {
  case string.to_graphemes(name) {
    [] -> False
    [first, ..rest] ->
      { is_alpha(first) || first == "_" }
      && list.all(rest, fn(c) {
        is_alpha(c) || is_digit(c) || c == "_" || c == "'" || c == "-"
      })
      && !list.contains(keywords, name)
  }
}

const keywords = [
  "if", "then", "else", "forall", "in", "let", "rec", "match", "null", "true",
  "false", "fun", "import", "merge", "default", "doc", "optional", "priority",
  "force", "not_exported", "include",
]

/// Renders a string as a Nickel string literal, escaping quotes, backslashes,
/// control characters and interpolation sequences.
///
/// ```gleam
/// string_literal("say \"hi\"") // -> "\"say \\\"hi\\\"\""
/// ```
pub fn string_literal(value: String) -> String {
  "\"" <> escape(string.to_graphemes(value), "") <> "\""
}

fn escape(chars: List(String), acc: String) -> String {
  case chars {
    [] -> acc
    // `%{` starts an interpolation: emit the `%` through an interpolated
    // string literal so that the result contains a literal `%{`.
    ["%", "{", ..rest] -> escape(rest, acc <> "%{\"%\"}{")
    ["\"", ..rest] -> escape(rest, acc <> "\\\"")
    ["\\", ..rest] -> escape(rest, acc <> "\\\\")
    ["\n", ..rest] -> escape(rest, acc <> "\\n")
    ["\r\n", ..rest] -> escape(rest, acc <> "\\r\\n")
    ["\r", ..rest] -> escape(rest, acc <> "\\r")
    ["\t", ..rest] -> escape(rest, acc <> "\\t")
    [c, ..rest] -> escape(rest, acc <> c)
  }
}

/// Renders an enum tag, such as `'production`. Exported enum tags become
/// strings, so use this to inject a tag with `context.assign_code`.
pub fn enum_tag(name: String) -> String {
  "'" <> field_name(name)
}

/// Renders a record field name, quoting it when it is not a bare identifier.
pub fn field_name(name: String) -> String {
  case is_identifier(name) {
    True -> name
    False -> string_literal(name)
  }
}

/// Renders a field path such as `["server", "tls port"]` as
/// `server."tls port"`, the syntax used by the Nickel CLI for `--field`
/// and for customize-mode assignments.
pub fn field_path(path: List(String)) -> String {
  path |> list.map(field_name) |> string.join(".")
}

fn is_alpha(c: String) -> Bool {
  case c {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m" -> True
    "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> True
    "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M" -> True
    "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z" -> True
    _ -> False
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
