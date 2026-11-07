//// Contracts used to validate configurations.

/// A Nickel contract applied to the result of an evaluation, as with the
/// `--apply-contract` option of the Nickel CLI.
pub type Contract {
  /// A file whose content evaluates to a contract.
  ContractFile(path: String)
  /// Nickel source code evaluating to a contract, such as
  /// `{ port | Number, host | String }`. Imports inside it are resolved
  /// through the context's import paths and then its working directory.
  ContractCode(code: String)
}

/// A contract stored in a file.
pub fn file(path: String) -> Contract {
  ContractFile(path)
}

/// A contract given as Nickel source code.
///
/// ```gleam
/// contract.code("{ port | std.number.PosNat, host | String }")
/// ```
pub fn code(code: String) -> Contract {
  ContractCode(code)
}
