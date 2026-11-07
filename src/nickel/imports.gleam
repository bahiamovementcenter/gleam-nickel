//// Import resolution.
////
//// Nickel resolves `import "name"` by looking for `name` relative to the
//// importing file, then in each import path given on the command line, then
//// in the colon-separated directories of the `NICKEL_IMPORT_PATH`
//// environment variable. This module reproduces that search so that
//// applications can find the files a configuration depends on, for example
//// to watch them for changes, bundle them, or report missing files before
//// evaluating.
////
//// Import discovery is lexical: imports whose path is computed at runtime
//// cannot be detected, and imports inside string interpolations are ignored.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import nickel/context.{type Context}
import nickel/source.{type Source}

/// An `import` expression found in Nickel source code.
pub type Import {
  Import(
    /// The path as written in the source.
    path: String,
    /// The explicit format annotation (`import "x" as 'Json`), if any.
    format: option.Option(String),
  )
}

pub type ImportError {
  /// No file with this name exists in any of the searched directories.
  NotFound(name: String, importer: String, searched: List(String))
  /// The file exists but could not be read.
  ReadFailed(path: String, reason: String)
}

/// Describes an import error in a single human readable line.
pub fn describe_error(error: ImportError) -> String {
  case error {
    NotFound(name:, importer:, searched:) ->
      "could not find import `"
      <> name
      <> "` from "
      <> importer
      <> " (looked in "
      <> string.join(searched, ", ")
      <> ")"
    ReadFailed(path:, reason:) -> "could not read " <> path <> ": " <> reason
  }
}

/// The absolute directory Nickel runs in for this context.
pub fn base_directory(context: Context) -> String {
  let cwd = current_directory()
  case context.working_directory(context) {
    Some(dir) -> absolute(dir, cwd)
    None -> cwd
  }
}

/// The directories searched, in order, for an import made from a file in
/// `importer_directory` (an import from inline code uses the working
/// directory).
pub fn search_path(context: Context, importer_directory: String) -> List(String) {
  let base = base_directory(context)
  let configured = context.import_paths(context) |> list.map(absolute(_, base))
  let from_env =
    env_import_path(context)
    |> string.split(":")
    |> list.filter(fn(p) { p != "" })
    |> list.map(absolute(_, base))
  [absolute(importer_directory, base), ..list.append(configured, from_env)]
}

fn env_import_path(context: Context) -> String {
  case list.key_find(context.environment(context), "NICKEL_IMPORT_PATH") {
    Ok(value) -> value
    Error(Nil) -> getenv("NICKEL_IMPORT_PATH") |> result.unwrap("")
  }
}

/// Resolves the import `name` made from a file located in
/// `importer_directory`, returning the absolute path of the imported file.
pub fn resolve(
  context: Context,
  importer_directory: String,
  name: String,
) -> Result(String, ImportError) {
  let candidates = case string.starts_with(name, "/") {
    True -> [normalize(name)]
    False ->
      search_path(context, importer_directory)
      |> list.map(fn(dir) { normalize(dir <> "/" <> name) })
  }
  case list.find(candidates, is_file) {
    Ok(path) -> Ok(path)
    Error(Nil) ->
      Error(NotFound(
        name:,
        importer: importer_directory,
        searched: search_path(context, importer_directory),
      ))
  }
}

/// Finds the `import` expressions in Nickel source code, in order of
/// appearance.
pub fn scan(code: String) -> List(Import) {
  do_scan(code, False, []) |> list.reverse
}

/// Computes the files a program depends on through imports, transitively.
/// The result contains absolute paths, without duplicates, in discovery
/// order. For a `Files` source the files themselves are included.
///
/// Imported files that are not Nickel files (JSON, YAML, TOML, text) are
/// included but not scanned further.
pub fn dependencies(
  context: Context,
  program: Source,
) -> Result(List(String), ImportError) {
  let base = base_directory(context)
  case program {
    source.Code(code) -> {
      use #(found, _) <- result.map(follow(context, base, code, [], set.new()))
      list.reverse(found)
    }
    source.Files(paths) -> {
      let roots = list.map(paths, fn(p) { normalize(absolute(p, base)) })
      use #(found, _) <- result.map(
        list.try_fold(roots, #([], set.new()), fn(acc, path) {
          visit(context, path, acc.0, acc.1)
        }),
      )
      list.reverse(found)
    }
  }
}

fn visit(
  context: Context,
  path: String,
  found: List(String),
  seen: set.Set(String),
) -> Result(#(List(String), set.Set(String)), ImportError) {
  case set.contains(seen, path) {
    True -> Ok(#(found, seen))
    False -> {
      let found = [path, ..found]
      let seen = set.insert(seen, path)
      case is_nickel_file(path) {
        False -> Ok(#(found, seen))
        True -> {
          use code <- result.try(
            read_file(path) |> result.map_error(ReadFailed(path, _)),
          )
          follow(context, dirname(path), code, found, seen)
        }
      }
    }
  }
}

fn follow(
  context: Context,
  directory: String,
  code: String,
  found: List(String),
  seen: set.Set(String),
) -> Result(#(List(String), set.Set(String)), ImportError) {
  scan(code)
  |> list.try_fold(#(found, seen), fn(acc, import_) {
    use path <- result.try(resolve(context, directory, import_.path))
    // Imports annotated with a data format are recorded but not scanned.
    case import_.format {
      Some(format) if format != "Nickel" ->
        case set.contains(acc.1, path) {
          True -> Ok(acc)
          False -> Ok(#([path, ..acc.0], set.insert(acc.1, path)))
        }
      _ -> visit(context, path, acc.0, acc.1)
    }
  })
}

fn is_nickel_file(path: String) -> Bool {
  let lower = string.lowercase(path)
  !{
    string.ends_with(lower, ".json")
    || string.ends_with(lower, ".yaml")
    || string.ends_with(lower, ".yml")
    || string.ends_with(lower, ".toml")
    || string.ends_with(lower, ".txt")
  }
}

// --- Lexical scanner -------------------------------------------------------

fn do_scan(input: String, after_import: Bool, acc: List(Import)) -> List(Import) {
  case input {
    "" -> acc
    "#" <> rest -> do_scan(skip_line(rest), after_import, acc)
    "\"" <> rest -> {
      let #(content, rest) = read_string(rest, "")
      case after_import {
        True -> {
          let #(format, rest2) = read_format(rest)
          do_scan(rest2, False, [Import(content, format), ..acc])
        }
        False -> do_scan(rest, False, acc)
      }
    }
    _ ->
      case string.pop_grapheme(input) {
        Error(Nil) -> acc
        Ok(#(c, rest)) ->
          case is_space(c) {
            True -> do_scan(rest, after_import, acc)
            False ->
              case is_ident_start(c) {
                True -> {
                  let #(word, rest) = read_ident(rest, c)
                  case count_percent(rest, 0) {
                    // Multiline or symbolic string: `m%"..."%`.
                    #(n, "\"" <> after) if n > 0 ->
                      do_scan(skip_multiline(after, n), False, acc)
                    _ -> do_scan(rest, word == "import", acc)
                  }
                }
                False -> do_scan(rest, False, acc)
              }
          }
      }
  }
}

fn read_format(input: String) -> #(option.Option(String), String) {
  let trimmed = string.trim_start(input)
  case trimmed {
    "as" <> rest -> {
      case string.trim_start(rest) {
        "'" <> rest -> {
          let #(name, rest) = read_ident(rest, "")
          #(Some(name), rest)
        }
        _ -> #(None, input)
      }
    }
    _ -> #(None, input)
  }
}

fn skip_line(input: String) -> String {
  case string.split_once(input, "\n") {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> ""
  }
}

fn read_string(input: String, acc: String) -> #(String, String) {
  case input {
    "" -> #(acc, "")
    "\\" <> rest ->
      case string.pop_grapheme(rest) {
        Ok(#(c, rest)) -> read_string(rest, acc <> unescape(c))
        Error(Nil) -> #(acc, "")
      }
    "\"" <> rest -> #(acc, rest)
    _ ->
      case string.pop_grapheme(input) {
        Ok(#(c, rest)) -> read_string(rest, acc <> c)
        Error(Nil) -> #(acc, "")
      }
  }
}

fn unescape(c: String) -> String {
  case c {
    "n" -> "\n"
    "t" -> "\t"
    "r" -> "\r"
    other -> other
  }
}

fn skip_multiline(input: String, percents: Int) -> String {
  let terminator = "\"" <> string.repeat("%", percents)
  case string.split_once(input, terminator) {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> ""
  }
}

fn count_percent(input: String, n: Int) -> #(Int, String) {
  case input {
    "%" <> rest -> count_percent(rest, n + 1)
    _ -> #(n, input)
  }
}

fn read_ident(input: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(input) {
    Ok(#(c, rest)) ->
      case is_ident_char(c) {
        True -> read_ident(rest, acc <> c)
        False -> #(acc, input)
      }
    Error(Nil) -> #(acc, input)
  }
}

fn is_space(c: String) -> Bool {
  c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\r\n"
}

fn is_ident_start(c: String) -> Bool {
  c == "_" || is_letter(c)
}

fn is_ident_char(c: String) -> Bool {
  is_ident_start(c) || is_digit(c) || c == "'" || c == "-"
}

fn is_letter(c: String) -> Bool {
  string.lowercase(c) != string.uppercase(c)
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

// --- Paths -----------------------------------------------------------------

/// Makes `path` absolute relative to `base` and removes `.` and `..`
/// segments.
pub fn absolute(path: String, base: String) -> String {
  case string.starts_with(path, "/") {
    True -> normalize(path)
    False -> normalize(base <> "/" <> path)
  }
}

/// Removes `.` and `..` segments and duplicate separators from an absolute
/// path.
pub fn normalize(path: String) -> String {
  let segments =
    path
    |> string.split("/")
    |> list.fold([], fn(acc, segment) {
      case segment, acc {
        "", _ | ".", _ -> acc
        "..", [_, ..rest] -> rest
        "..", [] -> []
        s, _ -> [s, ..acc]
      }
    })
    |> list.reverse
  "/" <> string.join(segments, "/")
}

fn dirname(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] ->
      case list.reverse(rest) |> string.join("/") {
        "" -> "/"
        dir -> dir
      }
    [] -> "/"
  }
}

@external(erlang, "nickel_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "nickel_ffi", "is_file")
fn is_file(path: String) -> Bool

@external(erlang, "nickel_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "nickel_ffi", "current_directory")
fn current_directory() -> String
