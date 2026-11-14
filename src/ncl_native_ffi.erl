%% Calls into the native library: requests are queued on a session's thread,
%% which replies with a message `{Ref, Reply}`.
-module(ncl_native_ffi).
-export([load_error/0, core_version/0, new_session/0, call/3]).

load_error() ->
    case ncl_nif:load_error() of
        none -> {ok, nil};
        Reason -> {error, Reason}
    end.

core_version() ->
    try {ok, ncl_nif:core_version()}
    catch error:not_loaded -> {error, not_loaded_failure()}
    end.

new_session() ->
    try ncl_nif:new_session() of
        {error, Reason} -> {error, {native_failure, Reason}};
        Session -> {ok, Session}
    catch error:not_loaded -> {error, not_loaded_failure()}
    end.

%% Without a timeout, the reply comes straight to the caller. With one, it
%% goes through a short-lived process that is killed on timeout, so a late
%% reply can't land in the caller's mailbox.
call(Session, Request, none) ->
    Ref = make_ref(),
    case send(Session, self(), Ref, Request) of
        ok -> receive {Ref, Reply} -> Reply end;
        Error -> Error
    end;
call(Session, Request, {some, Ms}) ->
    Caller = self(),
    Ref = make_ref(),
    Waiter = spawn(fun() -> receive {Ref, _} = Reply -> Caller ! Reply end end),
    case send(Session, Waiter, Ref, Request) of
        ok ->
            receive {Ref, Reply} -> Reply
            after Ms ->
                exit(Waiter, kill),
                receive {Ref, Reply} -> Reply
                after 0 -> {error, {timed_out, Ms}}
                end
            end;
        Error ->
            exit(Waiter, kill),
            Error
    end.

send(Session, ReplyTo, Ref, Request) ->
    try ncl_nif:request(Session, ReplyTo, Ref, Request) of
        ok -> ok;
        {error, Reason} -> {error, {native_failure, Reason}}
    catch
        error:not_loaded -> {error, not_loaded_failure()};
        error:badarg -> {error, {native_failure, <<"the native library rejected the request">>}}
    end.

not_loaded_failure() ->
    {native_failure, <<"the native library is not loaded: ",
                       (ncl_nif:load_error())/binary>>}.
