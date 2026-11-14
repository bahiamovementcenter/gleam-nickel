//// Process execution for the Nickel command line interface.
////
//// The library talks to Nickel by running the `nickel` executable. Running a
//// process is isolated behind the `Runner` type so that applications can
//// substitute their own strategy: running Nickel inside a container, through
//// `nix run`, on a remote machine, or replacing it with a stub in tests.

import gleam/bit_array
import gleam/int
import gleam/option.{type Option}

/// A request to run an external program.
pub type Command {
  Command(
    /// Program name (looked up on the `PATH`) or path to the executable.
    executable: String,
    arguments: List(String),
    /// Directory to run in. `None` means the current directory of the VM.
    working_directory: Option(String),
    /// Variables added to (or overriding) the inherited environment.
    environment: List(#(String, String)),
    /// Data written to the program's standard input. `None` means empty.
    stdin: Option(String),
    /// Kill the program if it runs longer than this many milliseconds.
    timeout: Option(Int),
  )
}

/// The result of a program that ran to completion.
pub type Output {
  Output(exit_code: Int, stdout: String, stderr: String)
}

/// Why a program could not be run to completion.
pub type RunError {
  /// The executable was not found on the `PATH` or at the given path.
  ExecutableNotFound(executable: String)
  /// The program was killed after running for the given number of milliseconds.
  TimedOut(milliseconds: Int)
  /// The program could not be started.
  SpawnFailed(reason: String)
  /// The program wrote output that is not valid UTF-8.
  InvalidUtf8Output
}

/// A strategy for running commands.
pub type Runner =
  fn(Command) -> Result(Output, RunError)

/// The default runner: spawns the program as an operating system process.
///
/// Requires a POSIX `sh`, used to redirect the standard streams.
pub fn system() -> Runner {
  run
}

/// Runs a command with the default system runner.
pub fn run(command: Command) -> Result(Output, RunError) {
  case
    ffi_run(
      command.executable,
      command.arguments,
      command.working_directory,
      command.environment,
      command.stdin,
      command.timeout,
    )
  {
    Ok(#(code, stdout, stderr)) ->
      case bit_array.to_string(stdout), bit_array.to_string(stderr) {
        Ok(stdout), Ok(stderr) -> Ok(Output(code, stdout, stderr))
        _, _ -> Error(InvalidUtf8Output)
      }
    Error(error) -> Error(error)
  }
}

/// Describes a run error in a single human readable line.
pub fn describe_error(error: RunError) -> String {
  case error {
    ExecutableNotFound(executable) ->
      "could not find the executable `" <> executable <> "`"
    TimedOut(ms) -> "the process timed out after " <> int.to_string(ms) <> "ms"
    SpawnFailed(reason) -> "the process could not be started: " <> reason
    InvalidUtf8Output -> "the process produced output that is not valid UTF-8"
  }
}

@external(erlang, "ncl_ffi", "run")
fn ffi_run(
  executable: String,
  arguments: List(String),
  working_directory: Option(String),
  environment: List(#(String, String)),
  stdin: Option(String),
  timeout: Option(Int),
) -> Result(#(Int, BitArray, BitArray), RunError)
