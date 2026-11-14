%% Stubs for the NIF, loaded from $NCL_NIF (a path without the extension).
-module(ncl_nif).
-export([new_session/0, request/4, core_version/0]).
-on_load(init/0).

init() ->
    erlang:load_nif(os:getenv("NCL_NIF"), 0).

new_session() -> erlang:nif_error(not_loaded).
request(_Session, _Pid, _Ref, _Request) -> erlang:nif_error(not_loaded).
core_version() -> erlang:nif_error(not_loaded).
