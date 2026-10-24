%% @doc Shared eunit environment for muse_integ: config from an env map,
%% Mnesia in RAM, signing key, the blobs cask and the PDF helper.
-module(muse_integ_test_env).

-export([start/1, stop/1]).

-spec start(#{binary() => binary()}) -> map().
start(Env) ->
    Dir = "/tmp/muse_integ_" ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, Config} = muse_config:from_env(Env#{<<"DATA_DIR">> => list_to_binary(Dir)}),
    muse_config:set(Config),
    {ok, _} = application:ensure_all_started([bitcask, beamai_core]),
    ok = muse_store:init(#{storage => ram}),
    ok = muse_signing:init(Dir),
    {ok, Cask} = muse_cask:start_link(blobs, filename:join(Dir, "blobs"), []),
    unlink(Cask),
    {ok, Pdf} = muse_pdf:start_link(),
    unlink(Pdf),
    #{dir => Dir, pdf => Pdf}.

-spec stop(map()) -> ok.
stop(#{dir := Dir, pdf := Pdf}) ->
    gen_server:stop(Pdf),
    muse_cask:stop(blobs),
    muse_store:stop(),
    os:cmd("rm -rf " ++ Dir),
    ok.
