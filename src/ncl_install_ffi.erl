%% Downloads the prebuilt native library for this platform from this
%% version's GitHub release, checks it against the checksum published with
%% the package, and puts it where `ncl_nif` looks (see `ncl_nif:cache_path/0`).
-module(ncl_install_ffi).
-export([install/0, platform/0]).

-define(RELEASES, "https://github.com/bahiamovementcenter/gleam-ncl/releases/download/").

%% The platform name used in release asset names, such as `linux-x86_64`.
platform() ->
    Arch = erlang:system_info(system_architecture),
    [Cpu | _] = string:split(Arch, "-"),
    Os = case os:type() of
        {unix, linux} -> "linux";
        {unix, darwin} -> "macos";
        {_, Other} -> atom_to_list(Other)
    end,
    Cpu1 = case Cpu of
        "arm64" -> "aarch64";
        "amd64" -> "x86_64";
        _ -> Cpu
    end,
    unicode:characters_to_binary(Os ++ "-" ++ Cpu1).

install() ->
    Platform = platform(),
    Version = ncl_nif:version(),
    Target = ncl_nif:cache_path() ++ ".so",
    case lists:keyfind(Platform, 1, ncl_nif_checksums:checksums()) of
        false ->
            no_prebuilt(Platform, Version);
        {_, Expected} ->
            Url = ?RELEASES ++ "v" ++ Version ++ "/libncl_nif-"
                  ++ binary_to_list(Platform) ++ ".so",
            case fetch(Url) of
                {ok, Body} ->
                    Actual = binary:encode_hex(crypto:hash(sha256, Body), lowercase),
                    case Actual =:= Expected of
                        true -> write(Target, Body);
                        false ->
                            {error, <<"checksum mismatch for ", (list_to_binary(Url))/binary,
                                      ": expected ", Expected/binary, ", got ", Actual/binary>>}
                    end;
                {error, _} = E -> E
            end
    end.

no_prebuilt(Platform, Version) ->
    {error, iolist_to_binary(
        ["ncl ", Version, " has no prebuilt native library for ", Platform,
         ". Build native/ncl_nif from the gleam-ncl repository and set NCL_NIF to it."])}.

fetch(Url) ->
    _ = application:ensure_all_started([inets, ssl]),
    Ssl = [{verify, verify_peer},
           {cacerts, public_key:cacerts_get()},
           {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case httpc:request(get, {Url, []}, [{ssl, Ssl}, {autoredirect, true}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Status, _}, _, _}} ->
            {error, iolist_to_binary(io_lib:format("~s: HTTP ~b", [Url, Status]))};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~s: ~p", [Url, Reason]))}
    end.

write(Target, Body) ->
    ok = filelib:ensure_dir(Target),
    Temp = Target ++ ".part",
    case file:write_file(Temp, Body) of
        ok ->
            case file:rename(Temp, Target) of
                ok -> {ok, unicode:characters_to_binary(Target)};
                {error, R} -> {error, iolist_to_binary(io_lib:format("~s: ~p", [Target, R]))}
            end;
        {error, R} -> {error, iolist_to_binary(io_lib:format("~s: ~p", [Temp, R]))}
    end.
