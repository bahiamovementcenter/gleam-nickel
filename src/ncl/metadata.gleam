//// Field metadata, as reported by `nickel query`.

import gleam/dynamic/decode
import gleam/option.{type Option, None}

/// The metadata attached to a field of a configuration.
pub type FieldMetadata {
  FieldMetadata(
    /// The documentation of the field (`| doc "..."`).
    doc: Option(String),
    /// The static type annotation (`: Type`), as source code.
    type_annotation: Option(String),
    /// The contracts attached to the field (`| Contract`), as source code.
    contracts: List(String),
    /// Whether the field is optional (`| optional`).
    optional: Bool,
    /// Whether the field is excluded from exports (`| not_exported`).
    not_exported: Bool,
    priority: Priority,
    /// The names of the sub-fields, if the value is a record.
    sub_fields: List(String),
    /// The field's value rendered as Nickel source code, if it has one.
    /// Nested values may be elided.
    value: Option(String),
  )
}

/// The merge priority of a field.
pub type Priority {
  /// `| default`: the lowest priority.
  DefaultPriority
  /// `| priority n`. Fields without annotation have priority `0`. The number
  /// is kept as written by Nickel, as it may be an arbitrary rational.
  NumericPriority(String)
  /// `| force`: the highest priority.
  ForcePriority
}

/// Decodes the JSON output of `nickel query --format json`.
pub fn decoder() -> decode.Decoder(FieldMetadata) {
  use doc <- decode.optional_field("doc", None, decode.optional(decode.string))
  use typ <- decode.optional_field("typ", None, decode.optional(decode.string))
  use type_annotation <- decode.optional_field(
    "type",
    typ,
    decode.optional(decode.string),
  )
  use contracts <- decode.optional_field(
    "contracts",
    [],
    decode.list(decode.string),
  )
  use optional <- decode.optional_field("optional", False, decode.bool)
  use not_exported <- decode.optional_field("not_exported", False, decode.bool)
  use priority <- decode.optional_field(
    "priority",
    NumericPriority("0"),
    decode.map(decode.string, fn(p) {
      case p {
        "default" | "bottom" -> DefaultPriority
        "force" | "top" -> ForcePriority
        n -> NumericPriority(n)
      }
    }),
  )
  use sub_fields <- decode.optional_field(
    "sub_fields",
    [],
    decode.list(decode.string),
  )
  use value <- decode.optional_field(
    "value",
    None,
    decode.optional(decode.string),
  )
  decode.success(FieldMetadata(
    doc:,
    type_annotation:,
    contracts:,
    optional:,
    not_exported:,
    priority:,
    sub_fields:,
    value:,
  ))
}
