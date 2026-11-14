//// Installs the native backend's library: `gleam run -m ncl/install`.
////
//// Downloads the prebuilt `ncl_nif` library for this platform from this
//// version's GitHub release, checks its SHA-256 against the checksum published
//// with the package, and saves it in the user cache directory, where the
//// `Native` backend finds it. Prebuilt libraries exist for Linux (x86_64,
//// aarch64) and macOS (aarch64); elsewhere, build `native/ncl_nif` from the
//// repository and point `NCL_NIF` at it.

import gleam/io

pub fn main() -> Nil {
  case install() {
    Ok(path) -> io.println("Installed the ncl native library at " <> path)
    Error(reason) -> {
      io.println_error("Could not install the ncl native library: " <> reason)
      halt(1)
    }
  }
}

/// Downloads and installs the library, returning where it was saved.
@external(erlang, "ncl_install_ffi", "install")
pub fn install() -> Result(String, String)

/// This platform's name in release assets, such as `linux-x86_64`.
@external(erlang, "ncl_install_ffi", "platform")
pub fn platform() -> String

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil
