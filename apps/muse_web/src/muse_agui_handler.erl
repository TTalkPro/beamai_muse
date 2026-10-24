%% @doc The AG-UI SSE endpoint mounted at `/api/agui/[...]` (designs/00-overview.md
%% §5, designs/03-agent.md §5–§7; replaces OpenMuse app.ts `/api/copilotkit/*`
%% and agent.ts `makeRuntime`, engine spec §9.2).
%%
%% Routes (the surface of beamai_agui_cowboy_handler, minus `/info` and the
%% thread list):
%%   POST   /api/agui/run, /api/agui/agent/default/run   RunAgentInput → SSE
%%   GET    /api/agui/threads/:id                         thread summary
%%   GET    /api/agui/threads/:id/{messages,events,state}
%%   GET    /api/agui/threads/:id/stream                  resume (`Last-Event-ID`,
%%                                                        `?since=`, `?lastEventId=`)
%%   POST   /api/agui/threads/:id/stop
%%   DELETE /api/agui/threads/:id                          forget the session
%%
%% Every route needs `muse_api:authenticate/1`. Runs additionally need
%% `muse_config:agent_configured()` (503 otherwise, as OpenMuse). A thread is
%% visible only to its owner: a `muse_threads` record of the caller, or an
%% ad-hoc thread id claimed on first run in `system/agui-threads`
%% (`{id, owner, createdAt}`, `insert_if_absent`, so a claim is global and
%% atomic). Any other thread is 404 `Thread not found`.
%%
%% Model/sample backends run on the thread's beamai_agui session: the request
%% process only subscribes, so a client disconnect never stops the run. Each
%% frame is `id: <seq>\ndata: <json>\n\n`; `: ping` comments every 25 s keep
%% proxies from closing an idle stream. A Jev failure in
%% `muse_chat:prepare_input/2` streams a single `RUN_ERROR` frame (no
%% RUN_STARTED, no id). A second run on a busy thread is 409
%% `agent_thread_locked`. `AGENT_BACKEND=agui` relays the run through
%% `muse_agui_proxy` instead.
-module(muse_agui_handler).
-behaviour(cowboy_handler).

-export([init/2, owns/2, claim/2]).

-define(CLAIMS, <<"agui-threads">>).
-define(HEARTBEAT, 25000).
-define(NOT_CONFIGURED,
        <<"Configure a model and provider API key, or a valid AG-UI endpoint, to start chat">>).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req = try
              case muse_api:authenticate(Req0) of
                  {ok, Owner} ->
                      route(cowboy_req:method(Req0), cowboy_req:path_info(Req0), Owner, Req0);
                  {error, {Status, Msg}} ->
                      muse_http:error_reply(Status, Msg, Req0)
              end
          catch Class:Reason ->
              logger:error("[OpenMuse] AG-UI ~p ~0p", [Class, muse_http:class(Reason)]),
              try muse_http:error_reply(502, muse_http:generic_error(), Req0)
              catch _:_ -> Req0
              end
          end,
    {ok, Req, State}.

route(<<"POST">>, [<<"run">>], Owner, Req) ->
    run(Owner, Req);
route(<<"POST">>, [<<"agent">>, <<"default">>, <<"run">>], Owner, Req) ->
    run(Owner, Req);
route(Method, [<<"threads">>, ThreadId | Sub], Owner, Req) when length(Sub) =< 1 ->
    case owns(Owner, ThreadId) of
        false -> not_found(Req);
        {true, _} -> thread(Method, Sub, ThreadId, Req)
    end;
route(_Method, _Path, _Owner, Req) ->
    muse_http:error_reply(404, <<"Not found">>, Req).

not_found(Req) ->
    muse_http:error_reply(404, <<"Thread not found">>, Req).

%% Thread ownership

%% @doc Whether `Owner` may see `ThreadId`: its own conversation thread or an
%% AG-UI thread it claimed.
-spec owns(binary(), binary()) -> {true, muse | agui} | false.
owns(Owner, ThreadId) ->
    case muse_threads:get(Owner, ThreadId) of
        {ok, _} -> {true, muse};
        _ ->
            case muse_store:get(<<"system">>, ?CLAIMS, ThreadId) of
                #{<<"owner">> := Owner} -> {true, agui};
                _ -> false
            end
    end.

%% @doc Ownership for a run: owned threads pass; an unknown id is claimed for
%% `Owner`; a thread of another owner is `not_found`.
-spec claim(binary(), binary()) -> {ok, muse | agui} | not_found.
claim(Owner, ThreadId) ->
    case owns(Owner, ThreadId) of
        {true, Kind} -> {ok, Kind};
        false ->
            Taken = muse_store:get(<<"system">>, ?CLAIMS, ThreadId) =/= undefined orelse
                lists:any(fun({_, #{<<"id">> := Id}}) -> Id =:= ThreadId;
                             (_) -> false
                          end, muse_store:scan(<<"threads">>)),
            Claim = #{<<"id">> => ThreadId, <<"owner">> => Owner,
                      <<"createdAt">> => muse_time:now_iso()},
            case Taken of
                true -> not_found;
                false ->
                    case muse_store:insert_if_absent(<<"system">>, ?CLAIMS, Claim) of
                        undefined ->
                            case owns(Owner, ThreadId) of
                                {true, Kind} -> {ok, Kind};
                                false -> not_found
                            end;
                        _ -> {ok, agui}
                    end
            end
    end.

%% Runs

run(Owner, Req0) ->
    case muse_config:agent_configured() of
        false ->
            muse_http:error_reply(503, ?NOT_CONFIGURED, Req0);
        true ->
            case read_input(Req0) of
                {error, {Status, Msg}, Req} ->
                    muse_http:error_reply(Status, Msg, Req);
                {ok, Payload, Input, Req} ->
                    ThreadId = beamai_agui_types:thread_id(Input),
                    case claim(Owner, ThreadId) of
                        not_found ->
                            not_found(Req);
                        {ok, Kind} ->
                            case muse_config:get(agent_backend) of
                                agui -> proxy(Payload, Req);
                                _ -> session_run(Owner, Kind, Input, Req)
                            end
                    end
            end
    end.

%% The parsed input plus the JSON payload with the ids it was given (missing
%% ids are generated, so the proxy forwards the same ones).
read_input(Req0) ->
    case muse_http:json_body(Req0) of
        {ok, Json, Req} when is_map(Json), map_size(Json) > 0 ->
            case beamai_agui_types:parse_run_input(Json) of
                {ok, #{thread_id := T, run_id := R} = Input}
                  when is_binary(T), T =/= <<>>, is_binary(R), R =/= <<>> ->
                    {ok, Json#{<<"threadId">> => T, <<"runId">> => R}, Input, Req};
                _ ->
                    {error, {400, <<"Invalid request data">>}, Req}
            end;
        {ok, _, Req} ->
            {error, {400, <<"Invalid request data">>}, Req};
        {error, E, Req} ->
            {error, E, Req}
    end.

session_run(Owner, Kind, Input0, Req) ->
    ThreadId = beamai_agui_types:thread_id(Input0),
    case muse_chat:prepare_input(Owner, Input0) of
        {error, Msg} ->
            Req1 = cowboy_req:stream_reply(200, sse_headers(), Req),
            ok = cowboy_req:stream_body(beamai_agui_event:to_sse(
                                          beamai_agui_event:new(<<"RUN_ERROR">>, #{<<"message">> => Msg})),
                                        fin, Req1),
            Req1;
        {ok, Input} ->
            {ok, Session} = beamai_agui_sessions:ensure(ThreadId),
            case beamai_agui_session:start_run(Session, Input, muse_chat_agent:factory(Owner),
                                               #{run_opts => muse_chat_agent:run_opts(Owner),
                                                 agent => <<"default">>}) of
                {started, RunId, Since} ->
                    _ = Kind =:= muse andalso muse_threads:touch(Owner, ThreadId) =:= ok,
                    Req1 = cowboy_req:stream_reply(200, (sse_headers())#{<<"x-agui-run-id">> => RunId}, Req),
                    stream_from(Session, Since, Req1);
                {busy, RunId} ->
                    muse_http:reply({409, #{<<"error">> => <<"agent_thread_locked">>, <<"runId">> => RunId}}, Req);
                {error, Reason} ->
                    logger:error("[OpenMuse] AG-UI run did not start: ~0p", [Reason]),
                    muse_http:error_reply(500, <<"Could not start the reply">>, Req)
            end
    end.

proxy(Payload, Req) ->
    Req1 = cowboy_req:stream_reply(200, sse_headers(), Req),
    ok = muse_agui_proxy:run(Payload, fun(Item) -> write_item(Item, Req1) end),
    ok = cowboy_req:stream_body(<<>>, fin, Req1),
    Req1.

write_item(ping, Req) -> cowboy_req:stream_body(<<": ping\n\n">>, nofin, Req);
write_item({event, _Event, Frame}, Req) -> cowboy_req:stream_body(Frame, nofin, Req).

%% Session subscription → SSE

stream_from(Session, Since, Req) ->
    case beamai_agui_session:subscribe(Session, Since) of
        {ok, Ref, Replay, Resync} ->
            _ = is_list(Resync) andalso
                cowboy_req:stream_body(beamai_agui_event:to_sse(beamai_agui_event:messages_snapshot(Resync)),
                                       nofin, Req) =:= ok,
            case replay(Replay, Req) of
                terminal ->
                    ok = beamai_agui_session:unsubscribe(Session, Ref),
                    finish(Req);
                ok ->
                    forward(Session, Ref, Req)
            end;
        {error, Reason} ->
            logger:warning("[OpenMuse] AG-UI subscribe failed: ~0p", [Reason]),
            ok = cowboy_req:stream_body(beamai_agui_event:to_sse(
                                          beamai_agui_event:run_error(<<"The reply stream is unavailable">>,
                                                                      <<"subscribe_failed">>)), nofin, Req),
            finish(Req)
    end.

replay([], _Req) ->
    ok;
replay([{Seq, Event} | Rest], Req) ->
    ok = cowboy_req:stream_body(beamai_agui_event:to_sse(Event, Seq), nofin, Req),
    case beamai_agui_event:is_terminal(Event) of
        true -> terminal;
        false -> replay(Rest, Req)
    end.

forward(Session, Ref, Req) ->
    receive
        {agui_event, Ref, Seq, Event} ->
            ok = cowboy_req:stream_body(beamai_agui_event:to_sse(Event, Seq), nofin, Req),
            case beamai_agui_event:is_terminal(Event) of
                true ->
                    ok = beamai_agui_session:unsubscribe(Session, Ref),
                    finish(Req);
                false ->
                    forward(Session, Ref, Req)
            end;
        {agui_closed, Ref, _Reason} ->
            ok = cowboy_req:stream_body(beamai_agui_event:to_sse(
                                          beamai_agui_event:run_error(<<"session closed">>, <<"session_closed">>)),
                                        nofin, Req),
            finish(Req)
    after ?HEARTBEAT ->
        ok = cowboy_req:stream_body(<<": ping\n\n">>, nofin, Req),
        forward(Session, Ref, Req)
    end.

finish(Req) ->
    ok = cowboy_req:stream_body(<<>>, fin, Req),
    Req.

-spec sse_headers() -> map().
sse_headers() ->
    #{<<"content-type">> => <<"text/event-stream">>,
      <<"cache-control">> => <<"no-cache">>,
      <<"x-accel-buffering">> => <<"no">>}.

%% Thread surface (owner already checked)

thread(<<"GET">>, [<<"stream">>], ThreadId, Req) ->
    case beamai_agui_sessions:whereis_session(ThreadId) of
        {ok, Session} ->
            Query = maps:from_list([KV || {_, V} = KV <- cowboy_req:parse_qs(Req), is_binary(V)]),
            Since = beamai_agui_http_handler:since_of(
                      Query#{<<"last-event-id">> => cowboy_req:header(<<"last-event-id">>, Req)}, undefined),
            stream_from(Session, Since, cowboy_req:stream_reply(200, sse_headers(), Req));
        {error, _} ->
            not_found(Req)
    end;
thread(<<"GET">>, [<<"messages">>], ThreadId, Req) ->
    result(beamai_agui_http_handler:handle_thread_messages(ThreadId, #{}), Req);
thread(<<"GET">>, [<<"events">>], ThreadId, Req) ->
    Query = maps:from_list([KV || {_, V} = KV <- cowboy_req:parse_qs(Req), is_binary(V)]),
    result(beamai_agui_http_handler:handle_thread_events(ThreadId, Query), Req);
thread(<<"GET">>, [<<"state">>], ThreadId, Req) ->
    result(beamai_agui_http_handler:handle_thread_state(ThreadId, #{}), Req);
thread(<<"POST">>, [<<"stop">>], ThreadId, Req) ->
    result(beamai_agui_http_handler:handle_thread_stop(ThreadId, #{}), Req);
thread(<<"GET">>, [], ThreadId, Req) ->
    result(beamai_agui_http_handler:handle_thread(ThreadId, #{}), Req);
thread(<<"DELETE">>, [], ThreadId, Req) ->
    result(beamai_agui_http_handler:handle_thread_delete(ThreadId, #{}), Req);
thread(_Method, _Sub, _ThreadId, Req) ->
    muse_http:error_reply(404, <<"Not found">>, Req).

%% beamai_agui's own CORS headers are dropped: muse_mw owns CORS.
result({ok, Body, _Headers}, Req) ->
    json(200, Body, Req);
result({error, 404, _Body, _Headers}, Req) ->
    not_found(Req);
result({error, Status, Body, _Headers}, Req) ->
    json(Status, Body, Req).

json(Status, Body, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, Body, Req).
