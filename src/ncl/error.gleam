//// Errors reported by Nickel and by the bindings.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string
import ncl/runner

/// Everything that can go wrong when using Nickel.
pub type Error {
  /// Nickel rejected the program: a syntax error, a type error, a contract
  /// violation, a failed import, an evaluation error, and so on.
  NickelError(
    /// Best-effort classification of the error.
    kind: ErrorKind,
    /// The structured diagnostics emitted by Nickel.
    diagnostics: List(Diagnostic),
    /// Nickel's own human readable rendering of the error, with file names
    /// and source snippets. Empty if rendering was disabled in the context.
    rendered: String,
  )
  /// The program evaluated successfully, but its result did not match the
  /// decoder given to a typed evaluation.
  DecodeError(errors: List(decode.DecodeError))
  /// Nickel produced output the bindings could not interpret.
  UnexpectedOutput(reason: String, output: String)
  /// Nickel could not be run.
  ProcessError(runner.RunError)
  /// A temporary file needed for the call could not be written.
  TemporaryFileError(reason: String)
  /// The native backend could not do what was asked: its library is not
  /// loaded, the feature needs the command line backend, or a value has no
  /// Gleam representation. See `ncl/native`.
  NativeError(reason: String)
}

/// A broad classification of Nickel errors.
///
/// Nickel's machine readable diagnostics do not carry an error category, so
/// this is derived from the diagnostic message and may be `EvaluationError`
/// for errors whose message is not recognised.
pub type ErrorKind {
  /// The program is not syntactically valid.
  ParseError
  /// Static typechecking failed.
  TypeError
  /// A contract was violated, including contracts applied by the context.
  ContractViolation
  /// An imported file could not be found or loaded.
  ImportError
  /// A field that was accessed or selected does not exist.
  MissingField
  /// An identifier is not bound.
  UnboundIdentifier
  /// The result cannot be serialized (functions, numbers out of range…).
  SerializationError
  /// A package manifest couldn't be read, or its dependencies couldn't be
  /// resolved or fetched.
  PackageError
  /// Any other error that happened during evaluation.
  EvaluationError
}

/// A diagnostic emitted by Nickel.
pub type Diagnostic {
  Diagnostic(
    severity: Severity,
    code: Option(String),
    message: String,
    labels: List(Label),
    notes: List(String),
  )
}

pub type Severity {
  BugSeverity
  ErrorSeverity
  WarningSeverity
  NoteSeverity
  HelpSeverity
}

/// A source location attached to a diagnostic.
pub type Label {
  Label(
    style: LabelStyle,
    /// Nickel's internal identifier of the source file.
    file_id: Int,
    /// Byte offset of the start of the span.
    start: Int,
    /// Byte offset of the end of the span.
    end: Int,
    message: String,
  )
}

pub type LabelStyle {
  Primary
  Secondary
}

/// Parses the JSON error report produced by `nickel --error-format json`.
pub fn parse_diagnostics(
  report: String,
) -> Result(List(Diagnostic), json.DecodeError) {
  json.parse(
    report,
    decode.at(["diagnostics"], decode.list(diagnostic_decoder())),
  )
}

fn diagnostic_decoder() -> decode.Decoder(Diagnostic) {
  use severity <- decode.field("severity", severity_decoder())
  use code <- decode.optional_field(
    "code",
    option.None,
    decode.optional(
      decode.one_of(decode.string, [
        decode.map(decode.int, int.to_string),
      ]),
    ),
  )
  use message <- decode.field("message", decode.string)
  use labels <- decode.optional_field(
    "labels",
    [],
    decode.list(label_decoder()),
  )
  use notes <- decode.optional_field("notes", [], decode.list(decode.string))
  decode.success(Diagnostic(severity:, code:, message:, labels:, notes:))
}

fn severity_decoder() -> decode.Decoder(Severity) {
  use severity <- decode.then(decode.string)
  case string.lowercase(severity) {
    "bug" -> decode.success(BugSeverity)
    "error" -> decode.success(ErrorSeverity)
    "warning" -> decode.success(WarningSeverity)
    "note" -> decode.success(NoteSeverity)
    "help" -> decode.success(HelpSeverity)
    _ -> decode.failure(ErrorSeverity, "Severity")
  }
}

fn label_decoder() -> decode.Decoder(Label) {
  use style <- decode.field("style", {
    use style <- decode.then(decode.string)
    case string.lowercase(style) {
      "primary" -> decode.success(Primary)
      _ -> decode.success(Secondary)
    }
  })
  use file_id <- decode.optional_field("file_id", -1, decode.int)
  use start <- decode.subfield(["range", "start"], decode.int)
  use end <- decode.subfield(["range", "end"], decode.int)
  use message <- decode.optional_field("message", "", decode.string)
  decode.success(Label(style:, file_id:, start:, end:, message:))
}

/// Classifies diagnostics into an `ErrorKind`, based on the first diagnostic
/// with error severity.
pub fn classify(diagnostics: List(Diagnostic)) -> ErrorKind {
  let primary =
    list.find(diagnostics, fn(d) { d.severity == ErrorSeverity })
    |> option.from_result
    |> option.or(option.from_result(list.first(diagnostics)))
  case primary {
    option.None -> EvaluationError
    option.Some(diagnostic) -> classify_message(diagnostic)
  }
}

fn classify_message(diagnostic: Diagnostic) -> ErrorKind {
  let message = string.lowercase(diagnostic.message)
  let has = fn(fragment) { string.contains(message, fragment) }
  case message {
    "" -> EvaluationError
    _ -> {
      use <- when(
        has("unexpected token")
          || has("unexpected end of file")
          || has("invalid escape")
          || has("parse error")
          || has("lexing error")
          || has("unmatched"),
        ParseError,
      )
      use <- when(
        has("import of")
          || has("could not find import")
          || has("unknown package")
          || has("no package manifest"),
        ImportError,
      )
      use <- when(has("manifest") || has("package"), PackageError)
      use <- when(has("contract broken") || has("blame"), ContractViolation)
      use <- when(has("dynamic type error"), EvaluationError)
      use <- when(
        has("incompatible types")
          || has("incompatible row")
          || has("type error")
          || has("unbound type variable")
          || has("missing row")
          || has("extra row")
          || has("polymorphic"),
        TypeError,
      )
      use <- when(has("unbound identifier"), UnboundIdentifier)
      use <- when(has("missing field"), MissingField)
      use <- when(
        has("non serializable") || has("serialized") || has("serialization"),
        SerializationError,
      )
      EvaluationError
    }
  }
}

fn when(condition: Bool, kind: ErrorKind, otherwise: fn() -> ErrorKind) {
  case condition {
    True -> kind
    False -> otherwise()
  }
}

/// Describes an error in human readable form. For Nickel errors this is
/// Nickel's own rendering when available.
pub fn describe(error: Error) -> String {
  case error {
    NickelError(rendered:, ..) if rendered != "" -> string.trim_end(rendered)
    NickelError(diagnostics:, ..) ->
      diagnostics |> list.map(describe_diagnostic) |> string.join("\n")
    DecodeError(errors) ->
      "the evaluated configuration does not have the expected shape:\n"
      <> {
        errors
        |> list.map(fn(e) {
          "  expected "
          <> e.expected
          <> ", found "
          <> e.found
          <> case e.path {
            [] -> ""
            path -> " at " <> string.join(path, ".")
          }
        })
        |> string.join("\n")
      }
    UnexpectedOutput(reason:, ..) -> "unexpected output from nickel: " <> reason
    ProcessError(error) -> runner.describe_error(error)
    TemporaryFileError(reason) -> "could not write a temporary file: " <> reason
    NativeError(reason) -> "native Nickel backend: " <> reason
  }
}

/// Describes a single diagnostic without source context.
pub fn describe_diagnostic(diagnostic: Diagnostic) -> String {
  let severity = case diagnostic.severity {
    BugSeverity -> "bug"
    ErrorSeverity -> "error"
    WarningSeverity -> "warning"
    NoteSeverity -> "note"
    HelpSeverity -> "help"
  }
  let labels =
    diagnostic.labels
    |> list.filter(fn(l) { l.message != "" })
    |> list.map(fn(l) { "\n  - " <> l.message })
  let notes = list.map(diagnostic.notes, fn(n) { "\n  = " <> n })
  severity
  <> ": "
  <> diagnostic.message
  <> string.concat(labels)
  <> string.concat(notes)
}

/// The messages of all diagnostics with error severity.
pub fn messages(error: Error) -> List(String) {
  case error {
    NickelError(diagnostics:, ..) ->
      diagnostics
      |> list.filter(fn(d) { d.severity == ErrorSeverity })
      |> list.map(fn(d) { d.message })
    _ -> [describe(error)]
  }
}
