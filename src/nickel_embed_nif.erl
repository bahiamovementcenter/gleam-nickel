%% Loads the `nickel_embed_nif` native library, built from the `nickel-embed-nif`
%% crate of bahiamovementcenter/rust-nickel, and declares its functions.
%%
%% The library is looked for at `$NICKEL_EMBED_NIF` (a path, with or without
%% the `.so` extension), then as `libnickel_embed_nif.so` in this package's
%% `priv` directory. The Erlang VM loads `.so` files on every Unix, macOS
%% included, so rename a `.dylib`.
%%
%% Loading never fails the module: without the library, every function raises
%% `not_loaded` and `load_error/0` says why.
-module(nickel_embed_nif).
-export([new_session/0, request/4, core_version/0, load_error/0]).
-on_load(init/0).

-define(NAME, "libnickel_embed_nif").

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
    case os:getenv("NICKEL_EMBED_NIF") of
        Path when Path =/= false, Path =/= "" ->
            {ok, filename:rootname(Path, ".so")};
        _ ->
            case code:priv_dir(nickel) of
                {error, _} ->
                    {error, "NICKEL_EMBED_NIF is not set and the `nickel` "
                            "package has no priv directory"};
                Priv ->
                    Path = filename:join(Priv, ?NAME),
                    case filelib:is_regular(Path ++ ".so") of
                        true -> {ok, Path};
                        false ->
                            {error, "NICKEL_EMBED_NIF is not set and "
                                    ++ Path ++ ".so does not exist"}
                    end
            end
    end.

%% `none` when the library is loaded, otherwise why it isn't.
load_error() ->
    persistent_term:get({?MODULE, load_error}, <<"the library was not loaded">>).

new_session() -> erlang:nif_error(not_loaded).
request(_Session, _ReplyTo, _Ref, _Request) -> erlang:nif_error(not_loaded).
core_version() -> erlang:nif_error(not_loaded).
