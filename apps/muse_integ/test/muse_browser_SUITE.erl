%% Real browser worker round trip. Runs only with MUSE_TEST_BROWSER=1 and a
%% worker started by scripts/run-browser-worker.sh (BROWSER_WORKER_URL and
%% WORKER_TOKEN in the environment).
-module(muse_browser_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([open_read_click_screenshot/1, blocked_destinations/1]).

all() -> [open_read_click_screenshot, blocked_destinations].

init_per_suite(Config) ->
    case {os:getenv("MUSE_TEST_BROWSER"), os:getenv("BROWSER_WORKER_URL"), os:getenv("WORKER_TOKEN")} of
        {"1", Url, Token} when Url =/= false, Token =/= false ->
            Env = muse_integ_test_env:start(#{<<"BROWSER_WORKER_URL">> => list_to_binary(Url),
                                               <<"WORKER_TOKEN">> => list_to_binary(Token)}),
            [{env, Env} | Config];
        _ ->
            {skip, "set MUSE_TEST_BROWSER=1, BROWSER_WORKER_URL and WORKER_TOKEN"}
    end.

end_per_suite(Config) ->
    muse_integ_test_env:stop(?config(env, Config)).

open_read_click_screenshot(_Config) ->
    O = <<"local-user">>,
    true = muse_browser:reachable(),
    {ok, #{<<"id">> := Id, <<"status">> := <<"active">>}} = muse_browser:create(O, <<"https://example.com/">>),
    {ok, #{<<"title">> := <<"Example Domain">>, <<"text">> := Text}} = muse_browser:read(O, Id),
    ?assertNotEqual(nomatch, binary:match(Text, <<"documentation examples">>)),
    {ok, <<137, "PNG", _/binary>>} = muse_browser:preview(O, Id),
    {ok, _} = muse_browser:input(O, Id, #{<<"type">> => <<"scroll">>, <<"deltaY">> => 200}),
    {ok, #{<<"status">> := <<"closed">>}} = muse_browser:close(O, Id).

blocked_destinations(_Config) ->
    O = <<"local-user">>,
    {error, {502, _}} = muse_browser:create(O, <<"http://127.0.0.1:8790/health">>),
    {error, {502, _}} = muse_browser:create(O, <<"http://192.168.3.13/">>).
