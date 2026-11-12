# Changelog

## v0.1.0 - Unreleased

- Native backend: `context.with_backend(context.Native)` runs Nickel inside the VM
  through the `nickel_embed_nif` library from rust-nickel, for every function of
  `nickel`, with exact integers of any size. See `nickel/native`.
- `nickel/lazy`: evaluate a program only as far as needed and walk into the parts
  you read (`eval_shallow`, `force`, `view`, `field`, `get`, `to_value`), like
  Nickel's Go bindings. Native backend only.
- `error.NativeError` for failures of the native backend.

- Initial release: parsing, evaluation, export, typechecking, contract validation,
  field metadata queries, import resolution, value conversion and typed decoding,
  structured errors, and configuration contexts.
