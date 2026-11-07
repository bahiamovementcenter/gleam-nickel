//// Where a Nickel program comes from.

import nickel/value.{type Value}

/// A Nickel program to evaluate.
pub type Source {
  /// Source code given as a string. Relative imports inside it are resolved
  /// against the context's working directory.
  Code(String)
  /// One or more files. Several files are merged (combined with `&`), as the
  /// Nickel CLI does. Relative paths are resolved against the context's
  /// working directory; imports inside a file are resolved relative to that
  /// file first.
  Files(List(String))
}

/// A program given as source code.
pub fn code(code: String) -> Source {
  Code(code)
}

/// A program stored in a file.
pub fn file(path: String) -> Source {
  Files([path])
}

/// Several files whose contents are merged together.
pub fn files(paths: List(String)) -> Source {
  Files(paths)
}

/// A program that evaluates to the given value. Useful to check Gleam data
/// against Nickel contracts.
pub fn from_value(value: Value) -> Source {
  Code(value.to_nickel(value))
}
