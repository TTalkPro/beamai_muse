%% @doc Minimal stand-in for the Playwright browser worker HTTP API, enough
%% to exercise muse_browser: sessions, read, screenshot, input, close,
%% downloads, and scripted failures (`url` containing "fail" -> 502 error,
%% "blocked" -> 400 BLOCKED_URL). Like the real worker it keeps the open
%% sessions in memory: `forget/1` drops one (a worker restart), after which
%% its screenshot, read and input answer 409 SESSION_CLOSED.
-module(muse_fake_worker).
-behaviour(cowboy_handler).

-export([start/0, stop/0, calls/0, forget/1, init/2]).

-define(TOKEN, <<"fake-worker-token-0123456789abcdef0123">>).

start() ->
    ets:new(?MODULE, [named_table, public, bag, {heir, whereis(init), none}]),
    Dispatch = cowboy_router:compile([{'_', [{"/[...]", ?MODULE, #{}}]}]),
    {ok, _} = cowboy:start_clear(?MODULE, [{port, 0}], #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(?MODULE),
    {<<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>, ?TOKEN}.

stop() ->
    cowboy:stop_listener(?MODULE),
    ets:delete(?MODULE).

calls() ->
    [C || {call, C} <- ets:tab2list(?MODULE)].

forget(Id) ->
    true = ets:delete_object(?MODULE, {open, Id}),
    ok.

open(Id) ->
    ets:member(?MODULE, open) andalso lists:member({open, Id}, ets:lookup(?MODULE, open)).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path(Req0),
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    ets:insert(?MODULE, {call, {Method, Path}}),
    Auth = cowboy_req:header(<<"authorization">>, Req),
    Reply = case {Auth =:= <<"Bearer ", ?TOKEN/binary>>, Method, binary:split(Path, <<"/">>, [global])} of
                {_, <<"GET">>, [<<>>, <<"health">>]} -> json(200, #{status => ok});
                {false, _, _} -> error_reply(401, <<"UNAUTHORIZED">>, <<"nope">>);
                {true, <<"POST">>, [<<>>, <<"sessions">>]} ->
                    #{<<"id">> := Id, <<"url">> := Url} = json:decode(Body),
                    case {binary:match(Url, <<"fail">>), binary:match(Url, <<"blocked">>)} of
                        {nomatch, nomatch} ->
                            true = ets:insert(?MODULE, {open, Id}),
                            json(201, session(Id, Url, <<"active">>));
                        {nomatch, _} ->
                            error_reply(400, <<"BLOCKED_URL">>, <<"That destination is blocked.">>);
                        _ ->
                            error_reply(502, <<"NAVIGATION_FAILED">>, <<"The page could not be loaded.">>)
                    end;
                {true, _, [<<>>, <<"sessions">>, Id, Op]}
                  when Op =:= <<"read">>; Op =:= <<"screenshot">>; Op =:= <<"input">> ->
                    case open(Id) of
                        true -> worker_op(Method, Id, Op);
                        false -> error_reply(409, <<"SESSION_CLOSED">>,
                                             <<"Open this browser session before using its console.">>)
                    end;
                {true, <<"POST">>, [<<>>, <<"sessions">>, Id, <<"close">>]} ->
                    json(200, session(Id, <<"https://example.com/">>, <<"closed">>));
                {true, <<"GET">>, [<<>>, <<"sessions">>, _Id, <<"downloads">>]} ->
                    json(200, #{downloads => [#{id => <<"d1">>, name => <<"slip.pdf">>, size => 10,
                                                mimeType => <<"application/pdf">>}],
                                failures => [#{id => <<"d2">>, name => <<"x.exe">>, code => <<"UNSUPPORTED_DOWNLOAD">>,
                                               message => <<"Only PDF">>, createdAt => <<"2026-01-01T00:00:00.000Z">>}]});
                {true, <<"GET">>, [<<>>, <<"sessions">>, _Id, <<"downloads">>, <<"d1">>]} ->
                    {ok, Pdf} = muse_pdf:sample(),
                    {200, #{<<"content-type">> => <<"application/pdf">>}, Pdf};
                _ ->
                    error_reply(404, <<"NOT_FOUND">>, <<"Worker endpoint not found.">>)
            end,
    {Status, Headers, RespBody} = Reply,
    {ok, cowboy_req:reply(Status, Headers, RespBody, Req), State}.

worker_op(<<"GET">>, Id, <<"read">>) ->
    json(200, #{url => <<"https://example.com/">>, title => <<"Example">>,
                text => binary:copy(<<"x">>, 30005), truncated => false, id => Id});
worker_op(<<"GET">>, _Id, <<"screenshot">>) ->
    {200, #{<<"content-type">> => <<"image/png">>}, <<137, "PNG fake">>};
worker_op(<<"POST">>, Id, <<"input">>) ->
    json(200, session(Id, <<"https://example.com/">>, <<"active">>));
worker_op(_, _, _) ->
    error_reply(404, <<"NOT_FOUND">>, <<"Worker endpoint not found.">>).

session(Id, Url, Status) ->
    #{id => Id, title => <<"Example">>, url => Url, status => Status,
      updatedAt => <<"2026-10-22T00:00:00.000Z">>}.

json(Status, Map) ->
    {Status, #{<<"content-type">> => <<"application/json; charset=utf-8">>},
     iolist_to_binary(json:encode(Map))}.

error_reply(Status, Code, Msg) ->
    json(Status, #{error => #{code => Code, message => Msg}}).
