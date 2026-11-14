//// Configuration contexts.
////
//// A `Context` gathers everything that influences how a Nickel program is
//// evaluated, apart from the program itself: where the `nickel` executable
//// is, which directory relative paths are resolved against, where imports
//// are searched, which contracts are applied to the result, which field
//// values are injected from the application, and so on.
////
//// Contexts are immutable values. Derive specialised contexts from a shared
//// base by piping it through the builder functions:
////
//// ```gleam
//// let base =
////   context.new()
////   |> context.with_working_directory("config")
////   |> context.add_import_path("config/lib")
////
//// let production =
////   base
////   |> context.assign(["environment"], value.String("production"))
////   |> context.apply_contract(contract.file("schema.ncl"))
//// ```

import gleam/list
import gleam/option.{type Option, None, Some}
import ncl/contract.{type Contract}
import ncl/runner.{type Runner}
import ncl/syntax
import ncl/value.{type Value}

pub opaque type Context {
  Context(
    executable: String,
    working_directory: Option(String),
    import_paths: List(String),
    environment: List(#(String, String)),
    contracts: List(Contract),
    assignments: List(Assignment),
    field: List(String),
    timeout: Option(Int),
    runner: Runner,
    render_errors: Bool,
    manifest_path: Option(String),
    package_cache_dir: Option(String),
    strict_typechecking: Bool,
    backend: Backend,
  )
}

/// How Nickel is run.
pub type Backend {
  /// Run the `nickel` command line program for every call (the default).
  /// Isolated from the VM and can be timed out, but each call starts a
  /// process.
  Cli
  /// Run Nickel inside the VM, through the `ncl_nif` native library
  /// (see `ncl/native`). Much faster per call and needs no `nickel`
  /// executable, but a crash in native code stops the VM and a timed out
  /// evaluation keeps running in the background.
  Native
}

/// A value injected into the program through Nickel's customize mode.
pub type Assignment {
  /// Sets a field that has no definition or only a default value, as with
  /// `nickel export config.ncl -- path=expression`.
  Assign(path: List(String), expression: String)
  /// Forces the value of a field even if it is already defined, as with
  /// `nickel export config.ncl -- --override path=expression`.
  Override(path: List(String), expression: String)
}

/// A context with default settings: the `nickel` executable from the `PATH`,
/// the current directory, no extra import paths and no contracts.
pub fn new() -> Context {
  Context(
    executable: "nickel",
    working_directory: None,
    import_paths: [],
    environment: [],
    contracts: [],
    assignments: [],
    field: [],
    timeout: None,
    runner: runner.system(),
    render_errors: True,
    manifest_path: None,
    package_cache_dir: None,
    strict_typechecking: False,
    backend: Cli,
  )
}

// --- Backend ---------------------------------------------------------------

/// Chooses how Nickel is run. Settings that only make sense for one backend
/// (the executable and runner for `Cli`) are ignored by the other.
pub fn with_backend(context: Context, backend: Backend) -> Context {
  Context(..context, backend:)
}

pub fn backend(context: Context) -> Backend {
  context.backend
}

// --- Process ---------------------------------------------------------------

/// Uses a specific `nickel` executable, by name or by path.
pub fn with_executable(context: Context, executable: String) -> Context {
  Context(..context, executable:)
}

pub fn executable(context: Context) -> String {
  context.executable
}

/// Sets the directory in which Nickel runs. Relative file paths, relative
/// import paths and imports from inline code are resolved against it.
pub fn with_working_directory(context: Context, directory: String) -> Context {
  Context(..context, working_directory: Some(directory))
}

pub fn working_directory(context: Context) -> Option(String) {
  context.working_directory
}

/// Sets an environment variable for the Nickel process, for instance
/// `NICKEL_IMPORT_PATH`.
pub fn set_env(context: Context, name: String, value: String) -> Context {
  let environment =
    context.environment
    |> list.filter(fn(entry) { entry.0 != name })
    |> list.append([#(name, value)])
  Context(..context, environment:)
}

/// The environment variables set for the Nickel process.
pub fn environment(context: Context) -> List(#(String, String)) {
  context.environment
}

/// Kills Nickel if a single call takes longer than this many milliseconds.
///
/// With the `Native` backend, a call that times out returns the same error,
/// but the evaluation can't be interrupted: it keeps a thread busy until it
/// ends.
pub fn with_timeout(context: Context, milliseconds: Int) -> Context {
  Context(..context, timeout: Some(milliseconds))
}

pub fn without_timeout(context: Context) -> Context {
  Context(..context, timeout: None)
}

pub fn timeout(context: Context) -> Option(Int) {
  context.timeout
}

/// Replaces the strategy used to run the Nickel executable.
pub fn with_runner(context: Context, runner: Runner) -> Context {
  Context(..context, runner:)
}

pub fn runner(context: Context) -> Runner {
  context.runner
}

/// Whether to ask Nickel for a human readable rendering of errors, at the
/// cost of running Nickel a second time when a call fails. Enabled by
/// default.
pub fn with_rendered_errors(context: Context, enabled: Bool) -> Context {
  Context(..context, render_errors: enabled)
}

pub fn render_errors(context: Context) -> Bool {
  context.render_errors
}

// --- Imports ---------------------------------------------------------------

/// Adds a directory searched for imports, after the directory of the
/// importing file and after previously added import paths.
pub fn add_import_path(context: Context, directory: String) -> Context {
  Context(
    ..context,
    import_paths: list.append(context.import_paths, [directory]),
  )
}

/// Replaces the list of import paths.
pub fn with_import_paths(
  context: Context,
  directories: List(String),
) -> Context {
  Context(..context, import_paths: directories)
}

/// The import paths, in search order.
pub fn import_paths(context: Context) -> List(String) {
  context.import_paths
}

/// Resolves package imports (`import foo`) with the dependencies of a Nickel
/// package manifest (`Nickel-pkg.ncl`). A relative path is resolved against
/// the working directory.
///
/// Before evaluating, Nickel resolves the dependencies' versions, fetches git
/// and index packages that aren't cached yet, and writes or updates
/// `Nickel-pkg.lock` next to the manifest. Failures have the kind
/// `error.PackageError`.
///
/// Package management is experimental in Nickel. The `Native` backend always
/// supports it; with the `Cli` backend, the `nickel` executable must be built
/// with its `package-experimental` feature (released binaries aren't, and
/// ignore the manifest).
pub fn with_manifest_path(context: Context, path: String) -> Context {
  Context(..context, manifest_path: Some(path))
}

pub fn manifest_path(context: Context) -> Option(String) {
  context.manifest_path
}

/// Caches fetched packages in this directory instead of the platform's cache
/// directory (such as `~/.cache/nickel`), like `--package-cache-dir`.
pub fn with_package_cache_dir(context: Context, directory: String) -> Context {
  Context(..context, package_cache_dir: Some(directory))
}

pub fn package_cache_dir(context: Context) -> Option(String) {
  context.package_cache_dir
}

// --- Contracts -------------------------------------------------------------

/// Applies a contract to the result of every evaluation in this context.
/// Contracts are applied in the order they are added.
pub fn apply_contract(context: Context, contract: Contract) -> Context {
  Context(..context, contracts: list.append(context.contracts, [contract]))
}

/// Removes all contracts.
pub fn without_contracts(context: Context) -> Context {
  Context(..context, contracts: [])
}

pub fn contracts(context: Context) -> List(Contract) {
  context.contracts
}

/// Makes `ncl.typecheck` also typecheck code that has no type
/// annotations (Nickel's `--strict-typechecking`).
pub fn with_strict_typechecking(context: Context, enabled: Bool) -> Context {
  Context(..context, strict_typechecking: enabled)
}

pub fn strict_typechecking(context: Context) -> Bool {
  context.strict_typechecking
}

// --- Field values ----------------------------------------------------------

/// Sets the value of a field that the configuration leaves undefined or
/// gives a default value. The value is subject to the field's contracts.
///
/// Only applies to evaluation and export. This uses Nickel's customize mode,
/// which requires the program to evaluate to a record.
pub fn assign(context: Context, path: List(String), value: Value) -> Context {
  assign_code(context, path, value.to_nickel(value))
}

/// Like `assign`, with the value given as a Nickel expression.
pub fn assign_code(
  context: Context,
  path: List(String),
  expression: String,
) -> Context {
  add_assignment(context, Assign(path, expression))
}

/// Forces the value of a field, even one the configuration already defines.
pub fn override(context: Context, path: List(String), value: Value) -> Context {
  override_code(context, path, value.to_nickel(value))
}

/// Like `override`, with the value given as a Nickel expression.
pub fn override_code(
  context: Context,
  path: List(String),
  expression: String,
) -> Context {
  add_assignment(context, Override(path, expression))
}

fn add_assignment(context: Context, assignment: Assignment) -> Context {
  let assignments =
    context.assignments
    |> list.filter(fn(a) { a.path != assignment.path })
    |> list.append([assignment])
  Context(..context, assignments:)
}

/// Removes all assignments and overrides.
pub fn without_assignments(context: Context) -> Context {
  Context(..context, assignments: [])
}

pub fn assignments(context: Context) -> List(Assignment) {
  context.assignments
}

/// Renders an assignment as customize-mode command line arguments.
pub fn assignment_arguments(assignment: Assignment) -> List(String) {
  case assignment {
    Assign(path, expression) -> [syntax.field_path(path) <> "=" <> expression]
    Override(path, expression) -> [
      "--override",
      syntax.field_path(path) <> "=" <> expression,
    ]
  }
}

// --- Field selection -------------------------------------------------------

/// Restricts evaluation, export and queries to a field of the
/// configuration. Paths given to `ncl.query` are relative to this field.
pub fn focus(context: Context, path: List(String)) -> Context {
  Context(..context, field: path)
}

/// Selects the whole configuration again.
pub fn unfocus(context: Context) -> Context {
  Context(..context, field: [])
}

/// The selected field path; empty when the whole configuration is used.
pub fn field(context: Context) -> List(String) {
  context.field
}
