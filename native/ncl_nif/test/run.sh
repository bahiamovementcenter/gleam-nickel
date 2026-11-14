#!/bin/sh
# Builds the NIF and runs the Erlang tests against it. Needs cargo, erlc and erl.
set -eu
cd "$(dirname "$0")/.."
cargo build --release --manifest-path Cargo.toml
target_dir=$(cargo metadata --format-version 1 --no-deps | sed 's/.*"target_directory":"\([^"]*\)".*/\1/')
lib="$target_dir/release/libncl_nif"
# The VM loads `<path>.so` on every Unix, macOS included.
[ -f "$lib.dylib" ] && cp "$lib.dylib" "$lib.so"
out=$(mktemp -d)
erlc -o "$out" test/*.erl
NCL_NIF="$lib" erl -noshell -pa "$out" -eval '
    case eunit:test(nif_test, [verbose]) of ok -> halt(0); _ -> halt(1) end.'
