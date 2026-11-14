# Changelog

## v0.1.0 - Unreleased

- The package is `ncl` (repository gleam-ncl): modules are `ncl`, `ncl/context` and so
  on, and the environment variables are `NCL_NIF` and `NCL_TEST_BACKEND`.
- The native library is built from this repository (`native/ncl_nif`, moved here from
  rust-nickel) and released with each version: `gleam run -m ncl/install` downloads the one
  for this platform and checks its checksum.
- Native backend: `context.with_backend(context.Native)` runs Nickel inside the VM
  through the `ncl_nif` library, for every function of `ncl`, with exact integers of
  any size. See `ncl/native`.
- `ncl/lazy`: evaluate a program only as far as needed and walk into the parts
  you read (`eval_shallow`, `force`, `view`, `field`, `get`, `to_value`), like
  Nickel's Go bindings. Native backend only.
- `error.NativeError` for failures of the native backend.

- Initial release: parsing, evaluation, export, typechecking, contract validation,
  field metadata queries, import resolution, value conversion and typed decoding,
  structured errors, and configuration contexts.
