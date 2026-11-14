%% Tests of the NIF from Erlang, the way gleam-nickel uses it. Run with ./test/run.sh.
-module(nif_test).
-include_lib("eunit/include/eunit.hrl").

call(Session, Request) ->
    Ref = make_ref(),
    ok = ncl_nif:request(Session, self(), Ref, Request),
    receive {Ref, Reply} -> Reply after 60000 -> error(timeout) end.

session(Code) -> session(Code, []).
session(Code, Overrides) ->
    S = ncl_nif:new_session(),
    {ok, nil} = call(S, {build, options([{code, Code, <<>>}], Overrides)}),
    S.

options(Inputs, Overrides) -> options(Inputs, Overrides, none, none).
options(Inputs, Overrides, Manifest, CacheDir) ->
    {options, Inputs, [], [], [], Overrides, [], true, Manifest, CacheDir}.

core_version_test() ->
    ?assertMatch(<<"0.", _/binary>>, ncl_nif:core_version()).

eval_value_test() ->
    S = session(<<"{ a = 1, b = [true, null, 1.5, \"x\", 'Tag], c = 2 * 10000000000000000000000 }">>),
    {ok, {record, M}} = call(S, eval_value),
    ?assertEqual({int, 1}, maps:get(<<"a">>, M)),
    ?assertEqual({array, [{bool, true}, null, {float, 1.5}, {string, <<"x">>}, {string, <<"Tag">>}]},
                 maps:get(<<"b">>, M)),
    ?assertEqual({int, 20000000000000000000000}, maps:get(<<"c">>, M)).

export_test() ->
    S = session(<<"{ a = 1 }">>),
    {ok, Json} = call(S, {export, json}),
    ?assertEqual(<<"{\n  \"a\": 1\n}">>, Json),
    {ok, Toml} = call(S, {export, toml}),
    ?assertEqual(<<"a = 1\n">>, Toml).

error_test() ->
    S = session(<<"{ port | Number = \"80\" }">>),
    {error, {nickel_failure, {some, contract_violation}, [D | _], Rendered}} = call(S, eval_value),
    {diagnostic, error_severity, _Code, Message, _Labels, _Notes} = D,
    ?assert(is_binary(Message)),
    ?assertNotEqual(nomatch, binary:match(Rendered, <<"contract">>)).

parse_error_test() ->
    S = ncl_nif:new_session(),
    {ok, nil} = call(S, {build, options([{code, <<"{ a = ">>, <<>>}], [])}),
    ?assertMatch({error, {nickel_failure, {some, parse_error}, _, _}}, call(S, parse)).

enum_variant_value_is_an_export_error_test() ->
    S = session(<<"'Some 1">>),
    ?assertMatch({error, {nickel_failure, _, [_ | _], _}}, call(S, eval_value)).

override_test() ->
    S = session(<<"{ port | default = 80, host = \"a\" }">>,
                [{assign, [<<"port">>], <<"8080">>}, {force, [<<"host">>], <<"\"b\"">>}]),
    {ok, {record, M}} = call(S, eval_value),
    ?assertEqual({int, 8080}, maps:get(<<"port">>, M)),
    ?assertEqual({string, <<"b">>}, maps:get(<<"host">>, M)).

lazy_test() ->
    S = session(<<"{ foo = [1, 2 + 3], bar = \"hi\", baz = 'Tag (1 + 1), bad = 1 + \"x\" }">>),
    {ok, E} = call(S, {eval, shallow}),
    {ok, {record, Fields}} = call(S, {inspect, E}),
    ?assertEqual([<<"bad">>, <<"bar">>, <<"baz">>, <<"foo">>], lists:sort([K || {K, _} <- Fields])),
    {some, Foo} = proplists:get_value(<<"foo">>, Fields),
    ?assertEqual({ok, unevaluated}, call(S, {inspect, Foo})),
    {ok, Foo1} = call(S, {force_expr, Foo}),
    {ok, {array, [One, Five]}} = call(S, {inspect, Foo1}),
    ?assertEqual({ok, {number, 1, 1}}, call(S, {inspect, One})),
    {ok, Five1} = call(S, {force_expr, Five}),
    ?assertEqual({ok, {number, 5, 1}}, call(S, {inspect, Five1})),
    {some, Baz} = proplists:get_value(<<"baz">>, Fields),
    {ok, Baz1} = call(S, {force_expr, Baz}),
    {ok, {enum_variant, <<"Tag">>, Arg}} = call(S, {inspect, Baz1}),
    {ok, Arg1} = call(S, {force_expr, Arg}),
    ?assertEqual({ok, {int, 2}}, call(S, {to_value, Arg1})),
    %% An error in one field doesn't stop the others being used.
    {some, Bad} = proplists:get_value(<<"bad">>, Fields),
    ?assertMatch({error, {nickel_failure, _, _, _}}, call(S, {force_expr, Bad})),
    {ok, Foo2} = call(S, {force_expr, Foo1}),
    ?assertMatch({ok, <<"[", _/binary>>}, call(S, {display, Foo2})).

rational_test() ->
    S = session(<<"1/3">>),
    {ok, E} = call(S, {eval, deep}),
    ?assertEqual({ok, {number, 1, 3}}, call(S, {inspect, E})).

foreign_expression_test() ->
    S1 = session(<<"1">>),
    S2 = session(<<"2">>),
    {ok, E} = call(S1, {eval, deep}),
    ?assertMatch({error, _}, ncl_nif:request(S2, self(), make_ref(), {inspect, E})).

query_test() ->
    S = ncl_nif:new_session(),
    Code = <<"{ server | doc \"The server\" = { port | Number | default = 80 } }">>,
    {ok, nil} = call(S, {build, {options, [{code, Code, <<>>}], [], [], [], [], [<<"server">>], false, none, none}}),
    {ok, {field_metadata, {some, <<"The server">>}, none, [], false, false, {numeric_priority, <<"0">>},
          [<<"port">>], {some, _}}} = call(S, query).

trace_test() ->
    S = session(<<"std.trace \"hello\" 1">>),
    {ok, _} = call(S, eval_value),
    {ok, Trace} = call(S, take_trace),
    ?assertNotEqual(nomatch, binary:match(Trace, <<"hello">>)).

file_and_import_test() ->
    Dir = string:trim(os:cmd("mktemp -d")),
    ok = file:write_file(filename:join(Dir, "lib.ncl"), <<"{ x = 41 }">>),
    ok = file:write_file(filename:join(Dir, "main.ncl"), <<"{ y = (import \"lib.ncl\").x + 1 }">>),
    S = ncl_nif:new_session(),
    {ok, nil} = call(S, {build, options([{file, list_to_binary(filename:join(Dir, "main.ncl"))}], [])}),
    ?assertEqual({ok, {record, #{<<"y">> => {int, 42}}}}, call(S, eval_value)),
    %% In-memory code named after a file in a directory imports relative to that directory.
    S2 = ncl_nif:new_session(),
    Name = list_to_binary(filename:join(Dir, "<stdin>")),
    {ok, nil} = call(S2, {build, options([{code, <<"(import \"lib.ncl\").x">>, Name}], [])}),
    ?assertEqual({ok, {int, 41}}, call(S2, eval_value)).

typecheck_test() ->
    S = session(<<"let f : Number -> Number = fun x => x ++ \"a\" in f">>),
    ?assertMatch({error, {nickel_failure, {some, type_error}, _, _}}, call(S, {typecheck, false})).

many_sessions_test() ->
    Parent = self(),
    Pids = [spawn(fun() ->
                S = session(integer_to_binary(N)),
                Parent ! {self(), call(S, eval_value)}
            end) || N <- lists:seq(1, 50)],
    Results = [receive {P, R} -> R end || P <- Pids],
    ?assertEqual([{ok, {int, N}} || N <- lists:seq(1, 50)], Results).

lazy_to_value_test() ->
    S = session(<<"{ a = 1 + 1, b = { c = [3 * 2], hidden | not_exported = 0 }, d = 'V 1 }">>),
    {ok, E} = call(S, {eval, shallow}),
    {ok, {record, Fields}} = call(S, {inspect, E}),
    {some, B} = proplists:get_value(<<"b">>, Fields),
    ?assertEqual({ok, {record, #{<<"c">> => {array, [{int, 6}]}}}}, call(S, {to_value, B})),
    {error, {native_failure, Why}} = call(S, {to_value, E}),
    ?assertNotEqual(nomatch, binary:match(Why, <<"`d`">>)).

inline_contract_test() ->
    S = ncl_nif:new_session(),
    Opts = {options, [{code, <<"{ port = -1 }">>, <<>>}], [], [], [<<"{ port | std.number.Nat }">>], [], [], false, none, none},
    {ok, nil} = call(S, {build, Opts}),
    ?assertMatch({error, {nickel_failure, {some, contract_violation}, _, _}}, call(S, eval_value)).

negative_numbers_test() ->
    S = session(<<"{ i = -12, r = -1/3 }">>),
    {ok, {record, M}} = call(S, eval_value),
    ?assertEqual({int, -12}, maps:get(<<"i">>, M)),
    {ok, E} = call(S, {eval, deep}),
    {ok, {record, Fields}} = call(S, {inspect, E}),
    {some, R} = proplists:get_value(<<"r">>, Fields),
    ?assertEqual({ok, {number, -1, 3}}, call(S, {inspect, R})).

pending_contract_test() ->
    S = session(<<"{ port = -1 } | { port | std.number.Nat }">>),
    {ok, E} = call(S, {eval, shallow}),
    {ok, {record, [{<<"port">>, {some, Port}}]}} = call(S, {inspect, E}),
    ?assertMatch({error, {nickel_failure, {some, contract_violation}, _, _}},
                 call(S, {force_expr, Port})).

manifest(Name, Dependencies) ->
    <<"{ name = \"", Name/binary, "\", description = \"test\", version = \"0.1.0\", ",
      "authors = [\"nif\"], minimal_nickel_version = \"1.9.0\", ",
      "dependencies = { ", Dependencies/binary, " } } | std.package.Manifest">>.

package_manifest_test() ->
    Dir = string:trim(os:cmd("mktemp -d")),
    App = filename:join(Dir, "app"),
    Lib = filename:join(Dir, "lib"),
    ok = filelib:ensure_path(App),
    ok = filelib:ensure_path(Lib),
    ok = file:write_file(filename:join(App, "Nickel-pkg.ncl"), manifest(<<"app">>, <<"lib = 'Path \"../lib\"">>)),
    ok = file:write_file(filename:join(App, "main.ncl"), <<"(import lib).value">>),
    ok = file:write_file(filename:join(Lib, "Nickel-pkg.ncl"), manifest(<<"lib">>, <<>>)),
    ok = file:write_file(filename:join(Lib, "main.ncl"), <<"{ value = 42 }">>),
    S = ncl_nif:new_session(),
    Main = list_to_binary(filename:join(App, "main.ncl")),
    ManifestPath = list_to_binary(filename:join(App, "Nickel-pkg.ncl")),
    Cache = list_to_binary(filename:join(Dir, "cache")),
    {ok, nil} = call(S, {build, options([{file, Main}], [], {some, ManifestPath}, {some, Cache})}),
    ?assertEqual({ok, {int, 42}}, call(S, eval_value)),
    ?assert(filelib:is_regular(filename:join(App, "Nickel-pkg.lock"))),
    %% Without the manifest, the package import fails.
    S2 = ncl_nif:new_session(),
    {ok, nil} = call(S2, {build, options([{file, Main}], [])}),
    ?assertMatch({error, {nickel_failure, {some, import_error}, _, _}}, call(S2, eval_value)).

bad_manifest_test() ->
    Dir = string:trim(os:cmd("mktemp -d")),
    ok = file:write_file(filename:join(Dir, "Nickel-pkg.ncl"), <<"{ name = 1 } | std.package.Manifest">>),
    S = ncl_nif:new_session(),
    Opts = options([{code, <<"1">>, <<>>}], [], {some, list_to_binary(filename:join(Dir, "Nickel-pkg.ncl"))}, none),
    ?assertMatch({error, {nickel_failure, {some, package_error}, [_ | _], _}}, call(S, {build, Opts})).
