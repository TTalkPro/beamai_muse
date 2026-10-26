-module(muse_browser_tests).
-include_lib("eunit/include/eunit.hrl").

-define(O, <<"local-user">>).

browser_test_() ->
    {setup,
     fun() ->
         {ok, _} = application:ensure_all_started(cowboy),
         {Url, Token} = muse_fake_worker:start(),
         Env = muse_integ_test_env:start(#{<<"BROWSER_WORKER_URL">> => Url, <<"WORKER_TOKEN">> => Token}),
         Env
     end,
     fun(Env) -> muse_fake_worker:stop(), muse_integ_test_env:stop(Env) end,
     [fun create_read_close/0, fun worker_errors/0, fun ownership/0, fun observe_for_thread/0,
      fun input_and_preview/0, fun revived_after_worker_restart/0, fun imports/0, fun console/0,
      fun reachable/0]}.

create_read_close() ->
    {ok, #{<<"id">> := Id, <<"status">> := <<"active">>, <<"consoleUrl">> := C, <<"previewUrl">> := P}} =
        muse_browser:create(?O, <<"https://example.com/">>),
    ?assertMatch(<<"http://localhost:8787/api/browsers/", _/binary>>, C),
    ?assertNotEqual(nomatch, binary:match(P, <<"/preview?owner=">>)),
    {ok, #{<<"title">> := <<"Example">>, <<"truncated">> := false} = Page} = muse_browser:read(?O, Id),
    ?assertEqual(30005, byte_size(maps:get(<<"text">>, Page))),
    ?assertMatch(#{<<"status">> := <<"active">>}, muse_store:get(?O, <<"browsers">>, Id)),
    {ok, #{<<"status">> := <<"closed">>}} = muse_browser:close(?O, Id).

worker_errors() ->
    {error, {502, <<"The page could not be loaded.">>}} = muse_browser:create(?O, <<"https://fail.example/">>),
    %% ownership was recorded first; the failed open marks it as error
    [Failed] = [S || S = #{<<"url">> := <<"https://fail.example/">>} <- muse_store:list(?O, <<"browsers">>)],
    ?assertMatch(#{<<"status">> := <<"error">>}, Failed),
    ?assertEqual({error, {502, <<"That destination is blocked.">>}},
                 muse_browser:navigate(?O, maps:get(<<"id">>, Failed), <<"http://blocked.local/">>)).

ownership() ->
    {ok, #{<<"id">> := Id}} = muse_browser:create(?O, <<"https://example.com/">>),
    ?assertEqual({error, {404, <<"Browser session not found">>}}, muse_browser:read(<<"other">>, Id)),
    ?assertEqual({error, {404, <<"Browser session not found">>}}, muse_browser:get(?O, <<"not-a-uuid">>)).

observe_for_thread() ->
    {ok, #{<<"sessionId">> := S1, <<"truncated">> := true, <<"text">> := T}} =
        muse_browser:observe_for_thread(?O, <<"thread-1">>, <<"https://example.com/a">>),
    ?assertEqual(30000, byte_size(T)),
    {ok, #{<<"sessionId">> := S2}} = muse_browser:observe_for_thread(?O, <<"thread-1">>, <<"https://example.com/b">>),
    ?assertEqual(S1, S2),
    {ok, #{<<"sessionId">> := S3}} = muse_browser:observe(?O, <<"https://example.com/c">>, undefined),
    ?assertNotEqual(S1, S3),
    {ok, #{<<"sessionId">> := S3}} = muse_browser:observe(?O, <<"https://example.com/d">>, S3).

input_and_preview() ->
    {ok, #{<<"id">> := Id}} = muse_browser:create(?O, <<"https://example.com/">>),
    {ok, #{<<"status">> := <<"active">>}} = muse_browser:input(?O, Id, #{<<"type">> => <<"click">>, <<"x">> => 1, <<"y">> => 2}),
    ?assertEqual({error, {422, <<"A JSON object is required for browser input">>}}, muse_browser:input(?O, Id, [1])),
    {ok, <<137, "PNG fake">>} = muse_browser:preview(?O, Id).

imports() ->
    {ok, #{<<"id">> := Id}} = muse_browser:create(?O, <<"https://example.com/">>),
    {ok, #{<<"files">> := [#{<<"id">> := F, <<"source">> := Src}], <<"failures">> := [#{<<"code">> := _}]}} =
        muse_browser:imports(?O, Id),
    ?assertEqual(<<"Browser · "/utf8, Id/binary>>, Src),
    {ok, #{<<"files">> := [#{<<"id">> := F}]}} = muse_browser:imports(?O, Id),
    Downloads = [C || C = {<<"GET">>, <<"/sessions/", _/binary>>} <- muse_fake_worker:calls(),
                      binary:match(element(2, C), <<"/downloads/d1">>) =/= nomatch],
    ?assertEqual(1, length(Downloads)).

console() ->
    {ok, #{<<"id">> := Id}} = muse_browser:create(?O, <<"https://example.com/">>),
    {ok, Html} = muse_browser:console(?O, Id),
    ?assertMatch(<<"<!doctype html>", _/binary>>, Html),
    ?assertEqual(nomatch, binary:match(Html, <<"__PREVIEW_URL__">>)),
    ?assertNotEqual(nomatch, binary:match(Html, <<"fetch(\"http://localhost:8787/api/browsers/", Id/binary, "/preview?owner=">>)).

reachable() ->
    ?assert(muse_browser:reachable()).

unconfigured_test_() ->
    {setup, fun() -> muse_integ_test_env:start(#{}) end, fun muse_integ_test_env:stop/1,
     [?_assertNot(muse_browser:reachable()),
      ?_assertEqual({error, {503, <<"Browser worker is not configured. Start it using the setup guide.">>}},
                    muse_browser:create(?O, <<"https://example.com/">>))]}.

%% The worker lost the session (restart): the console re-opens it at its
%% last URL and the screenshot, read and input work again.
revived_after_worker_restart() ->
    {ok, #{<<"id">> := Id}} = muse_browser:create(?O, <<"https://example.com/">>),
    ok = muse_fake_worker:forget(Id),
    %% the fake answers 409 SESSION_CLOSED until the session is opened again
    {ok, <<137, "PNG fake">>} = muse_browser:preview(?O, Id),
    ok = muse_fake_worker:forget(Id),
    {ok, #{<<"status">> := <<"active">>}} = muse_browser:input(?O, Id, #{<<"type">> => <<"scroll">>, <<"deltaY">> => 100}),
    ok = muse_fake_worker:forget(Id),
    {ok, #{<<"title">> := <<"Example">>}} = muse_browser:read(?O, Id).
