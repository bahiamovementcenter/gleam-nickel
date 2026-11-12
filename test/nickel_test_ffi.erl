%% Helpers for the tests.
-module(nickel_test_ffi).
-export([package_fixture/0]).

%% A fresh directory holding two packages: `app`, whose manifest depends on
%% `lib` by path, and `lib`. Returns the directory. Manifests get a lock file
%% written next to them, so they can't live in test/fixtures.
package_fixture() ->
    Dir = string:trim(os:cmd("mktemp -d")),
    Write = fun(Path, Contents) ->
        Full = filename:join(Dir, Path),
        ok = filelib:ensure_dir(Full),
        ok = file:write_file(Full, Contents)
    end,
    Write("app/Nickel-pkg.ncl", manifest(<<"app">>, <<"lib = 'Path \"../lib\"">>)),
    Write("app/main.ncl", <<"{ answer = (import lib).value }">>),
    Write("lib/Nickel-pkg.ncl", manifest(<<"lib">>, <<>>)),
    Write("lib/main.ncl", <<"{ value = 42 }">>),
    Write("bad/Nickel-pkg.ncl", <<"{ name = 1 } | std.package.Manifest">>),
    unicode:characters_to_binary(Dir).

manifest(Name, Dependencies) ->
    <<"{ name = \"", Name/binary, "\", description = \"test\", version = \"0.1.0\", ",
      "authors = [\"gleam-nickel\"], minimal_nickel_version = \"1.9.0\", ",
      "dependencies = { ", Dependencies/binary, " } } | std.package.Manifest">>.
