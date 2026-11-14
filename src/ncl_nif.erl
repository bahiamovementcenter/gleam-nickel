%% Loads the `ncl_nif` native library, built from this repository's
%% `native/ncl_nif` crate, and declares its functions.
%%
%% The library is looked for, in order:
%%
%% 1. at `$NCL_NIF` (a path, with or without the `.so` extension);
%% 2. as `libncl_nif.so` in this package's `priv` directory;
%% 3. where `gleam run -m ncl/install` puts it: `libncl_nif.so` in a folder
%%    named after this package's version, in the user cache directory
%%    (`$XDG_CACHE_HOME/ncl`, `~/.cache/ncl` or `~/Library/Caches/ncl`).
%%
%% The Erlang VM loads `.so` files on every Unix, macOS included, so rename a
%% `.dylib`.
%%
%% Loading never fails the module: without the library, every function raises
%% `not_loaded` and `load_error/0` says why.
-module(ncl_nif).
-export([new_session/0, request/4, core_version/0, load_error/0]).
-export([cache_path/0, version/0]).
-on_load(init/0).

-define(NAME, "libncl_nif").

init() ->
    Result = case library_path() of
        {ok, Path} ->
            case erlang:load_nif(Path, 0) of
                ok -> ok;
                {error, {_, Text}} -> {error, Path ++ ": " ++ Text}
            end;
        {error, _} = E -> E
    end,
    case Result of
        ok -> persistent_term:put({?MODULE, load_error}, none);
        {error, Reason} ->
            persistent_term:put({?MODULE, load_error},
                                unicode:characters_to_binary(Reason))
    end,
    ok.

library_path() ->
    case os:getenv("NCL_NIF") of
        Path when Path =/= false, Path =/= "" ->
            {ok, filename:rootname(Path, ".so")};
        _ ->
            Candidates = priv_path() ++ [cache_path()],
            case [P || P <- Candidates, filelib:is_regular(P ++ ".so")] of
                [Found | _] -> {ok, Found};
                [] ->
                    {error, "the native library isn't installed: run "
                            "`gleam run -m ncl/install`, or set NCL_NIF to "
                            "a build of native/ncl_nif (looked in "
                            ++ lists:join(", ", [P ++ ".so" || P <- Candidates])
                            ++ ")"}
            end
    end.

priv_path() ->
    case code:priv_dir(ncl) of
        {error, _} -> [];
        Priv -> [filename:join(Priv, ?NAME)]
    end.

%% Where `ncl/install` puts the library, without the `.so` extension.
cache_path() ->
    filename:join([filename:basedir(user_cache, "ncl"), version(), ?NAME]).

%% This package's version, as a string.
version() ->
    _ = application:load(ncl),
    case application:get_key(ncl, vsn) of
        {ok, Vsn} -> Vsn;
        undefined -> "dev"
    end.

%% `none` when the library is loaded, otherwise why it isn't.
load_error() ->
    persistent_term:get({?MODULE, load_error}, <<"the library was not loaded">>).

new_session() -> erlang:nif_error(not_loaded).
request(_Session, _ReplyTo, _Ref, _Request) -> erlang:nif_error(not_loaded).
core_version() -> erlang:nif_error(not_loaded).
