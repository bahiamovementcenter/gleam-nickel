-module(ncl_ffi).

-export([run/6, write_temp_file/2, delete_file/1, read_file/1, is_file/1,
         getenv/1, current_directory/0]).

%% Run an executable with separated stdout/stderr capture and optional stdin.
%%
%% Erlang ports cannot close a child's stdin independently nor separate
%% stderr from stdout, so the child is started through `/bin/sh`, which
%% redirects the three standard streams to files in a private temporary
%% directory. `exec` replaces the shell, so the OS pid of the port is the
%% pid of the program itself, which lets a timeout kill it.
run(Executable, Args, Cwd, Env, Stdin, Timeout) ->
    case find_executable(Executable) of
        {error, nil} ->
            {error, {executable_not_found, Executable}};
        {ok, ExePath} ->
            case find_executable(<<"sh">>) of
                {error, nil} ->
                    {error, {spawn_failed, <<"could not find `sh` on the PATH">>}};
                {ok, Sh} ->
                    with_temp_dir(fun(Dir) ->
                        run_in(Dir, Sh, ExePath, Args, Cwd, Env, Stdin, Timeout)
                    end)
            end
    end.

run_in(Dir, Sh, ExePath, Args, Cwd, Env, Stdin, Timeout) ->
    InPath = filename:join(Dir, "stdin"),
    OutPath = filename:join(Dir, "stdout"),
    ErrPath = filename:join(Dir, "stderr"),
    In = case Stdin of
        {some, Data} -> ok = file:write_file(InPath, Data), InPath;
        none -> "/dev/null"
    end,
    Script = <<"in=$1; out=$2; err=$3; shift 3; "
               "exec \"$@\" <\"$in\" >\"$out\" 2>\"$err\"">>,
    ShArgs = [<<"-c">>, Script, <<"gleam_ncl">>,
              to_bin(In), to_bin(OutPath), to_bin(ErrPath),
              to_bin(ExePath) | Args],
    CdOpt = case Cwd of
        {some, C} -> [{cd, unicode:characters_to_list(C)}];
        none -> []
    end,
    EnvOpt = [{env, [{unicode:characters_to_list(K), unicode:characters_to_list(V)}
                     || {K, V} <- Env]}],
    try open_port({spawn_executable, Sh},
                  [{args, ShArgs}, exit_status, binary, hide, use_stdio]
                  ++ CdOpt ++ EnvOpt) of
        Port ->
            Deadline = case Timeout of
                {some, Ms} -> erlang:monotonic_time(millisecond) + Ms;
                none -> infinity
            end,
            case await(Port, Deadline) of
                {exit, Status} ->
                    {ok, {Status, read_or_empty(OutPath), read_or_empty(ErrPath)}};
                timeout ->
                    kill(Port),
                    {some, Ms2} = Timeout,
                    {error, {timed_out, Ms2}}
            end
    catch
        error:Reason ->
            {error, {spawn_failed, to_bin(io_lib:format("~p", [Reason]))}}
    end.

await(Port, Deadline) ->
    Remaining = case Deadline of
        infinity -> infinity;
        _ -> max(0, Deadline - erlang:monotonic_time(millisecond))
    end,
    receive
        {Port, {exit_status, Status}} -> {exit, Status};
        {Port, {data, _}} -> await(Port, Deadline)
    after Remaining ->
        timeout
    end.

kill(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} -> os:cmd("kill -9 " ++ integer_to_list(Pid));
        _ -> ok
    end,
    catch port_close(Port),
    receive {Port, {exit_status, _}} -> ok after 0 -> ok end.

find_executable(Name) ->
    N = unicode:characters_to_list(Name),
    case lists:member($/, N) of
        true ->
            case filelib:is_regular(N) of
                true -> {ok, filename:absname(N)};
                false -> {error, nil}
            end;
        false ->
            case os:find_executable(N) of
                false -> {error, nil};
                Path -> {ok, Path}
            end
    end.

with_temp_dir(Fun) ->
    Dir = filename:join(temp_root(), "gleam_ncl_" ++ os:getpid() ++ "_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    case file:make_dir(Dir) of
        ok ->
            try Fun(Dir) after file:del_dir_r(Dir) end;
        {error, Reason} ->
            {error, {spawn_failed, to_bin(io_lib:format(
                "could not create temporary directory ~s: ~p", [Dir, Reason]))}}
    end.

temp_root() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        T -> T
    end.

read_or_empty(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, _} -> <<>>
    end.

%% Write a file with a unique name in the temporary directory.
write_temp_file(Contents, Extension) ->
    Path = filename:join(temp_root(), "gleam_ncl_" ++ os:getpid() ++ "_"
                         ++ integer_to_list(erlang:unique_integer([positive]))
                         ++ unicode:characters_to_list(Extension)),
    case file:write_file(Path, Contents) of
        ok -> {ok, to_bin(Path)};
        {error, Reason} -> {error, to_bin(io_lib:format("~p", [Reason]))}
    end.

delete_file(Path) ->
    _ = file:delete(Path),
    nil.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case unicode:characters_to_binary(Bin) of
                Utf8 when is_binary(Utf8) -> {ok, Utf8};
                _ -> {error, <<"file is not valid UTF-8">>}
            end;
        {error, Reason} -> {error, to_bin(io_lib:format("~p", [Reason]))}
    end.

is_file(Path) -> filelib:is_regular(Path).

getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

current_directory() ->
    {ok, Dir} = file:get_cwd(),
    unicode:characters_to_binary(Dir).

to_bin(X) when is_binary(X) -> X;
to_bin(X) -> unicode:characters_to_binary(X).
