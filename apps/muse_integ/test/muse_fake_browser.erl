%% @doc Fake browser transport (the `muse_browser` behaviour), standing in
%% for muse_browser_docker + browserd so the browser features are tested
%% without Docker: sessions, open, read, screenshot, input, close,
%% downloads, and scripted failures (`url` containing "fail" -> the
%% NAVIGATION_FAILED message, "blocked" -> a blocked destination). Like
%% browserd it keeps the open sessions (windows) in memory: `forget/1` drops
%% one (a container or Chrome restart), after which its screenshot, read
%% and input answer SESSION_CLOSED.
%%
%% `start/0` installs it as the transport (app env `browser_transport`).
-module(muse_fake_browser).
-behaviour(muse_browser).

-export([start/0, stop/0, calls/0, reset_calls/0, forget/1, call/3]).

-define(T, ?MODULE).
-define(SESSION_CLOSED, <<"Open this browser session before using its console.">>).

start() ->
    _ = ets:new(?T, [named_table, public, duplicate_bag, {heir, whereis(init), none}]),
    ok = application:set_env(muse_integ, browser_transport, ?MODULE),
    persistent_term:erase({muse_browser, health}),
    ok.

stop() ->
    application:unset_env(muse_integ, browser_transport),
    ets:delete(?T),
    ok.

%% @doc The requests so far, oldest first: `{Op, Session}`.
calls() ->
    [C || {call, C} <- ets:tab2list(?T)].

reset_calls() ->
    true = ets:match_delete(?T, {call, '_'}),
    ok.

forget(Id) ->
    true = ets:delete_object(?T, {open, Id}),
    ok.

open(Id) ->
    lists:member({open, Id}, ets:lookup(?T, open)).

call(Owner, #{<<"op">> := Op} = Request, Timeout) when is_binary(Owner), is_integer(Timeout) ->
    Session = maps:get(<<"session">>, Request, undefined),
    ets:insert(?T, {call, {Op, Session}}),
    reply(Op, Session, Request).

reply(<<"open">>, Id, #{<<"url">> := Url}) ->
    case {binary:match(Url, <<"fail">>), binary:match(Url, <<"blocked">>)} of
        {nomatch, nomatch} ->
            true = ets:insert(?T, {open, Id}),
            {ok, #{<<"url">> => Url, <<"title">> => <<"Example">>}};
        {nomatch, _} ->
            {error, {502, <<"That destination is blocked.">>}};
        _ ->
            {error, {502, <<"The page could not be loaded.">>}}
    end;
reply(Op, Id, Request) when Op =:= <<"read">>; Op =:= <<"screenshot">>; Op =:= <<"input">> ->
    case open(Id) of
        true -> window(Op, Request);
        false -> {error, {502, ?SESSION_CLOSED}}
    end;
reply(<<"close">>, Id, _) ->
    _ = ets:delete_object(?T, {open, Id}),
    {ok, #{<<"closed">> => true}};
reply(<<"downloads">>, _Id, _) ->
    {ok, #{<<"downloads">> => [#{<<"id">> => <<"d1">>, <<"name">> => <<"slip.pdf">>, <<"size">> => 10,
                                 <<"mimeType">> => <<"application/pdf">>}],
           <<"failures">> => [#{<<"id">> => <<"d2">>, <<"name">> => <<"x.exe">>,
                                <<"code">> => <<"UNSUPPORTED_DOWNLOAD">>, <<"message">> => <<"Only PDF">>,
                                <<"createdAt">> => <<"2026-01-01T00:00:00.000Z">>}]}};
reply(<<"download">>, _Id, #{<<"download">> := <<"d1">>}) ->
    {ok, Pdf} = muse_pdf:sample(),
    {ok, #{<<"name">> => <<"slip.pdf">>, <<"data">> => base64:encode(Pdf)}};
reply(_, _, _) ->
    {error, {502, <<"Unknown browser operation.">>}}.

window(<<"read">>, _) ->
    {ok, #{<<"url">> => <<"https://example.com/">>, <<"title">> => <<"Example">>,
           <<"text">> => binary:copy(<<"x">>, 30005), <<"truncated">> => false}};
window(<<"screenshot">>, _) ->
    {ok, #{<<"png">> => base64:encode(<<137, "PNG fake">>)}};
window(<<"input">>, #{<<"input">> := Input, <<"mode">> := Mode}) when is_map(Input) ->
    true = lists:member(Mode, [<<"human">>, <<"direct">>]),
    {ok, #{<<"url">> => <<"https://example.com/">>, <<"title">> => <<"Example">>}}.
