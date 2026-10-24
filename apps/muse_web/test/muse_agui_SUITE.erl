%% The AG-UI SSE endpoint `/api/agui/*` over real HTTP (muse_agui_handler,
%% muse_agui_proxy): sample and scripted-model runs, auth, 503/409, stop,
%% resume with Last-Event-ID, thread ownership, the Jev RUN_ERROR-only path,
%% and the `AGENT_BACKEND=agui` relay against an upstream served by this
%% module (it is also the upstream's cowboy handler).
-module(muse_agui_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).
-define(MODEL_ENV, #{<<"AGENT_BACKEND">> => <<"model">>, <<"MODEL">> => <<"openai/gpt-4o-mini">>,
                     <<"OPENAI_API_KEY">> => <<"sk-test">>}).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [sample_permission_slip, unauthenticated, not_configured, concurrent_run_conflict,
     stop_cancels_run, resume_with_last_event_id, other_owner_thread_hidden,
     jev_off_choice_is_run_error, bad_input,
     proxy_relays_events, proxy_upstream_error, proxy_unreachable, proxy_client_disconnect_cancels].

env_for(not_configured) -> #{<<"AGENT_BACKEND">> => <<"model">>};
env_for(concurrent_run_conflict) -> ?MODEL_ENV;
env_for(stop_cancels_run) -> ?MODEL_ENV;
env_for(resume_with_last_event_id) -> ?MODEL_ENV;
env_for(_) -> #{}.

init_per_testcase(Case, Config) ->
    case atom_to_list(Case) of
        "proxy_" ++ _ ->
            {ok, _} = application:ensure_all_started(cowboy),
            Dispatch = cowboy_router:compile([{'_', [{"/agui", ?MODULE, #{}}]}]),
            {ok, _} = cowboy:start_clear(muse_agui_upstream, [{ip, {127, 0, 0, 1}}, {port, 0}],
                                         #{env => #{dispatch => Dispatch}}),
            persistent_term:put({?MODULE, test}, self()),
            Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(ranch:get_port(muse_agui_upstream)),
                                    "/agui"]),
            start(#{<<"AGENT_BACKEND">> => <<"agui">>, <<"AGENT_URL">> => Url,
                    <<"AGENT_TOKEN">> => <<"up-token">>}, Config);
        _ ->
            start(env_for(Case), Config)
    end.

%% A data dir of our own: the default /tmp/muse_web_<n> can collide with
%% other nodes running the web suites at the same time.
start(EnvMap, Config) ->
    Dir = "/tmp/muse_agui_ct_" ++ os:getpid() ++ "_" ++ integer_to_list(erlang:unique_integer([positive])),
    Env = muse_web_test_env:start(EnvMap#{<<"DATA_DIR">> => list_to_binary(Dir)}),
    [{env, Env}, {data_dir_own, Dir} | Config].

end_per_testcase(Case, Config) ->
    _ = case atom_to_list(Case) of
            "proxy_" ++ _ -> cowboy:stop_listener(muse_agui_upstream);
            _ -> ok
        end,
    ok = muse_web_test_env:stop(?config(env, Config)),
    _ = os:cmd("rm -rf " ++ ?config(data_dir_own, Config)),
    ok.

%% Helpers

input(ThreadId, Text) ->
    input(ThreadId, Text, muse_ids:uuid()).

input(ThreadId, Text, MsgId) ->
    #{<<"threadId">> => ThreadId, <<"runId">> => muse_ids:uuid(),
      <<"messages">> => [#{<<"id">> => MsgId, <<"role">> => <<"user">>, <<"content">> => Text}],
      <<"tools">> => [], <<"context">> => [], <<"state">> => #{}, <<"forwardedProps">> => #{}}.

auth(Token) -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}].

%% Open an SSE request; `{sse, Conn, Stream, Headers}` or `{Status, Body}`.
open(Env, Method, Path, Headers, Body) ->
    {ok, C} = gun:open("127.0.0.1", maps:get(port, Env), #{retry => 0, protocols => [http]}),
    {ok, _} = gun:await_up(C, 5000),
    S = case Method of
            post -> gun:post(C, Path, [{<<"content-type">>, <<"application/json">>} | Headers],
                             muse_json:encode(Body));
            get -> gun:get(C, Path, Headers)
        end,
    case gun:await(C, S, 15000) of
        {response, nofin, 200, RH} ->
            case proplists:get_value(<<"content-type">>, RH) of
                <<"text/event-stream", _/binary>> -> {sse, C, S, RH};
                _ -> {ok, B} = gun:await_body(C, S, 15000), gun:close(C), {200, decode(B)}
            end;
        {response, nofin, Status, _} ->
            {ok, B} = gun:await_body(C, S, 15000), gun:close(C), {Status, decode(B)};
        {response, fin, Status, _} ->
            gun:close(C), {Status, <<>>}
    end.

decode(B) ->
    case muse_json:decode(B) of
        {ok, J} -> J;
        _ -> B
    end.

%% Read frames until `Stop(Frames)` holds or the response ends; returns
%% `{Frames, Raw, fin | open}`. Frames: `{Id | undefined, Event}`.
read(C, S, Stop) ->
    read(C, S, Stop, <<>>, []).

read(C, S, Stop, Raw, Acc) ->
    case Stop(Acc) of
        true -> {Acc, Raw, open};
        false ->
            receive
                {gun_data, C, S, IsFin, Data} ->
                    Raw1 = <<Raw/binary, Data/binary>>,
                    Frames = frames(Raw1),
                    case IsFin of
                        fin -> gun:close(C), {Frames, Raw1, fin};
                        nofin -> read(C, S, Stop, Raw1, Frames)
                    end
            after 20000 -> error({sse_timeout, types(Acc)})
            end
    end.

read_all(C, S) ->
    {Frames, Raw, fin} = read(C, S, fun(_) -> false end),
    {Frames, Raw}.

until_type(Type) ->
    fun(Frames) -> lists:member(Type, types(Frames)) end.

frames(Raw) ->
    Parts = binary:split(Raw, <<"\n\n">>, [global]),
    lists:filtermap(
      fun(Part) ->
              Lines = binary:split(Part, <<"\n">>, [global]),
              Id = case [I || <<"id: ", I/binary>> <- Lines] of
                       [I] -> binary_to_integer(I);
                       [] -> undefined
                   end,
              case [D || <<"data: ", D/binary>> <- Lines] of
                  [] -> false;
                  Ds ->
                      case muse_json:decode(lists:join(<<"\n">>, Ds)) of
                          {ok, E} -> {true, {Id, E}};
                          _ -> false
                      end
              end
      end, lists:droplast(Parts)).

types(Frames) -> [T || {_, #{<<"type">> := T}} <- Frames].

events(Frames) -> [E || {_, E} <- Frames].

text(Frames) ->
    iolist_to_binary([D || {_, #{<<"type">> := <<"TEXT_MESSAGE_CONTENT">>, <<"delta">> := D}} <- Frames]).

index(X, L) -> length(lists:takewhile(fun(Y) -> Y =/= X end, L)) + 1.

run_sse(Env, Token, Body) ->
    {sse, C, S, _} = open(Env, post, "/api/agui/agent/default/run", auth(Token), Body),
    read_all(C, S).

forge_session(Owner) ->
    Token = muse_ids:uuid(),
    _ = muse_store:put(<<"system">>, <<"sessions">>,
                       #{<<"id">> => muse_ids:sha256hex(Token), <<"owner">> => Owner,
                         <<"expiresAt">> => muse_time:now_ms() + 3600000}),
    Token.

%% Session runs

sample_permission_slip(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    Tid = muse_ids:uuid(),
    {sse, C, S, RH} = open(Env, post, "/api/agui/agent/default/run", auth(Token),
                           input(Tid, <<"Complete the permission slip">>, <<"m1">>)),
    ?assertMatch(<<_/binary>>, proplists:get_value(<<"x-agui-run-id">>, RH)),
    ?assertEqual(<<"no-cache">>, proplists:get_value(<<"cache-control">>, RH)),
    {Frames, _} = read_all(C, S),
    Types = types(Frames),
    ?assertEqual(<<"RUN_STARTED">>, hd(Types)),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(Types)),
    ?assert(index(<<"TEXT_MESSAGE_CONTENT">>, Types) < index(<<"TOOL_CALL_START">>, Types)),
    ?assert(lists:member(<<"TOOL_CALL_ARGS">>, Types) andalso lists:member(<<"TOOL_CALL_END">>, Types)),
    [#{<<"toolCallName">> := <<"delegate_task">>}] =
        [E || #{<<"type">> := <<"TOOL_CALL_START">>} = E <- events(Frames)],
    ?assertMatch(<<"I found the permission slip.", _/binary>>, text(Frames)),
    %% every frame carries the session sequence number, increasing
    Ids = [I || {I, _} <- Frames],
    ?assert(lists:all(fun is_integer/1, Ids)),
    ?assertEqual(Ids, lists:usort(Ids)),
    TaskId = muse_ids:sha256hex(<<"task:", Tid/binary, ":m1">>),
    ?assertMatch(#{<<"kind">> := <<"document">>, <<"title">> := <<"Complete the permission slip">>},
                 muse_store:get(?O, <<"tasks">>, TaskId)),
    ?assertMatch(#{<<"owner">> := ?O}, muse_store:get(<<"system">>, <<"agui-threads">>, Tid)),
    %% the plain /run route and the thread surface
    {Frames2, _} = run_sse(Env, Token, input(Tid, <<"hello">>)),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(types(Frames2))),
    {200, #{<<"messages">> := [_ | _]}} = muse_web_test_env:http(Env, get, "/api/agui/threads/" ++ binary_to_list(Tid) ++ "/messages", Token),
    {200, #{<<"events">> := [_ | _]}} = muse_web_test_env:http(Env, get, "/api/agui/threads/" ++ binary_to_list(Tid) ++ "/events", Token),
    {200, #{<<"threadId">> := Tid}} = muse_web_test_env:http(Env, get, "/api/agui/threads/" ++ binary_to_list(Tid) ++ "/state", Token),
    {200, #{}} = muse_web_test_env:http(Env, get, "/api/agui/threads/" ++ binary_to_list(Tid), Token),
    {sse, C3, S3, _} = open(Env, post, "/api/agui/run", auth(Token), input(Tid, <<"hello">>)),
    {Frames3, _} = read_all(C3, S3),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(types(Frames3))).

unauthenticated(Config) ->
    Env = ?config(env, Config),
    ?assertEqual({401, #{<<"error">> => <<"Sign in to OpenMuse">>}},
                 open(Env, post, "/api/agui/agent/default/run", [], input(muse_ids:uuid(), <<"hi">>))),
    ?assertMatch({401, _}, open(Env, get, "/api/agui/threads/x/stream", auth(<<"bogus">>), undefined)),
    ?assertMatch({401, _}, open(Env, post, "/api/agui/threads/x/stop", [], #{})).

not_configured(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    ?assertEqual({503, #{<<"error">> =>
                             <<"Configure a model and provider API key, or a valid AG-UI endpoint, to start chat">>}},
                 open(Env, post, "/api/agui/agent/default/run", auth(Token), input(muse_ids:uuid(), <<"hi">>))).

bad_input(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    ?assertEqual({400, #{<<"error">> => <<"Invalid request data">>}},
                 open(Env, post, "/api/agui/run", auth(Token), [1, 2])),
    ?assertMatch({404, _}, open(Env, post, "/api/agui/agent/other/run", auth(Token), input(muse_ids:uuid(), <<"hi">>))).

concurrent_run_conflict(Config) ->
    Env = ?config(env, Config),
    muse_script_llm:set([{sleep, 3000}]),
    Token = muse_web_test_env:login(Env),
    Tid = muse_ids:uuid(),
    {sse, C, S, _} = open(Env, post, "/api/agui/agent/default/run", auth(Token), input(Tid, <<"slow">>)),
    _ = read(C, S, until_type(<<"RUN_STARTED">>)),
    ?assertMatch({409, #{<<"error">> := <<"agent_thread_locked">>, <<"runId">> := _}},
                 open(Env, post, "/api/agui/agent/default/run", auth(Token), input(Tid, <<"again">>))),
    {Frames, _} = read_all(C, S),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(types(Frames))).

stop_cancels_run(Config) ->
    Env = ?config(env, Config),
    muse_script_llm:set([{sleep, 10000}]),
    Token = muse_web_test_env:login(Env),
    Tid = muse_ids:uuid(),
    {sse, C, S, _} = open(Env, post, "/api/agui/agent/default/run", auth(Token), input(Tid, <<"slow">>)),
    _ = read(C, S, until_type(<<"RUN_STARTED">>)),
    timer:sleep(200),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({200, #{<<"threadId">> => Tid, <<"stopped">> => true}},
                 muse_web_test_env:http(Env, post, "/api/agui/threads/" ++ binary_to_list(Tid) ++ "/stop", Token)),
    {Frames, _} = read_all(C, S),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 5000),
    [#{<<"result">> := #{<<"status">> := <<"cancelled">>}}] =
        [E || #{<<"type">> := <<"RUN_FINISHED">>} = E <- events(Frames)].

resume_with_last_event_id(Config) ->
    Env = ?config(env, Config),
    muse_script_llm:set([{sleep, 1500}]),
    Token = muse_web_test_env:login(Env),
    Tid = muse_ids:uuid(),
    {sse, C, S, _} = open(Env, post, "/api/agui/agent/default/run", auth(Token), input(Tid, <<"slow">>)),
    {Seen, _, open} = read(C, S, until_type(<<"RUN_STARTED">>)),
    LastId = lists:max([I || {I, _} <- Seen]),
    %% the client goes away; the run keeps going in the session
    gun:close(C),
    Path = "/api/agui/threads/" ++ binary_to_list(Tid) ++ "/stream",
    {sse, C2, S2, _} = open(Env, get, Path, auth(Token) ++ [{<<"last-event-id">>, integer_to_binary(LastId)}],
                            undefined),
    {Frames, _} = read_all(C2, S2),
    ?assert(lists:all(fun({I, _}) -> I > LastId end, Frames)),
    ?assertNot(lists:member(<<"RUN_STARTED">>, types(Frames))),
    ?assertEqual(<<"late">>, text(Frames)),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(types(Frames))),
    %% a finished run replays from ?since and closes at once
    {sse, C3, S3, _} = open(Env, get, Path ++ "?since=" ++ integer_to_list(LastId), auth(Token), undefined),
    {Frames3, _} = read_all(C3, S3),
    ?assertEqual(types(Frames), types(Frames3)).

other_owner_thread_hidden(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    Other = forge_session(<<"other-user">>),
    Tid = muse_ids:uuid(),
    {Frames, _} = run_sse(Env, Token, input(Tid, <<"hello">>)),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(types(Frames))),
    T = "/api/agui/threads/" ++ binary_to_list(Tid),
    NotFound = {404, #{<<"error">> => <<"Thread not found">>}},
    ?assertEqual(NotFound, open(Env, get, T ++ "/stream", auth(Other), undefined)),
    ?assertEqual(NotFound, muse_web_test_env:http(Env, get, T ++ "/messages", Other)),
    ?assertEqual(NotFound, muse_web_test_env:http(Env, get, T ++ "/events", Other)),
    ?assertEqual(NotFound, muse_web_test_env:http(Env, get, T, Other)),
    ?assertEqual(NotFound, muse_web_test_env:http(Env, post, T ++ "/stop", Other)),
    ?assertEqual(NotFound, muse_web_test_env:http(Env, delete, T, Other)),
    ?assertEqual(NotFound, open(Env, post, "/api/agui/run", auth(Other), input(Tid, <<"mine now">>))),
    %% a conversation thread of the first owner cannot be claimed either
    {ok, #{<<"id">> := Main}} = muse_threads:main_thread(?O),
    ?assertEqual(NotFound, open(Env, post, "/api/agui/run", auth(Other), input(Main, <<"hi">>))),
    %% the owner still sees it; its own conversation thread runs too
    {200, #{<<"messages">> := [_ | _]}} = muse_web_test_env:http(Env, get, T ++ "/messages", Token),
    {MainFrames, _} = run_sse(Env, Token, input(Main, <<"hello">>)),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(types(MainFrames))),
    ?assertEqual(undefined, muse_store:get(<<"system">>, <<"agui-threads">>, Main)),
    {200, #{<<"deleted">> := true}} = muse_web_test_env:http(Env, delete, T, Token).

jev_off_choice_is_run_error(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    {Frames, Raw} = run_sse(Env, Token, input(muse_ids:uuid(), <<"[OpenMuse choice] {}">>)),
    ?assertMatch([{undefined, #{<<"type">> := <<"RUN_ERROR">>,
                                <<"message">> := <<"Choices are unavailable in this conversation">>}}], Frames),
    ?assertMatch(<<"data: ", _/binary>>, Raw).

%% AGENT_BACKEND=agui

proxy_relays_events(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    Tid = muse_ids:uuid(),
    Body = (input(Tid, <<"hi">>))#{<<"forwardedProps">> => #{<<"mode">> => <<"canned">>}},
    {sse, C, S, _} = open(Env, post, "/api/agui/agent/default/run", auth(Token), Body),
    {Frames, Raw} = read_all(C, S),
    receive
        {upstream_request, _, Auth, Accept, UpBody} ->
            ?assertEqual(<<"Bearer up-token">>, Auth),
            ?assertEqual(<<"text/event-stream">>, Accept),
            {ok, Up} = muse_json:decode(UpBody),
            ?assertEqual(maps:with([<<"threadId">>, <<"runId">>, <<"messages">>], Body),
                         maps:with([<<"threadId">>, <<"runId">>, <<"messages">>], Up))
    after 5000 -> error(no_upstream_request)
    end,
    ?assertEqual([<<"RUN_STARTED">>, <<"TEXT_MESSAGE_START">>, <<"TEXT_MESSAGE_CONTENT">>,
                  <<"TEXT_MESSAGE_END">>, <<"RUN_FINISHED">>], types(Frames)),
    ?assertEqual([1, 2, 3, undefined, 5], [I || {I, _} <- Frames]),
    ?assertEqual(<<"Hello from upstream">>, text(Frames)),
    %% payloads pass through byte for byte; comments and the post-terminal event do not
    ?assertNotEqual(nomatch, binary:match(Raw, <<"data: {\"type\":\"TEXT_MESSAGE_START\",\"messageId\":\"u1\",\"role\":\"assistant\"}\n">>)),
    ?assertEqual(nomatch, binary:match(Raw, <<"after the end">>)),
    ?assertMatch(#{<<"owner">> := ?O}, muse_store:get(<<"system">>, <<"agui-threads">>, Tid)).

proxy_upstream_error(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    Body = (input(muse_ids:uuid(), <<"hi">>))#{<<"forwardedProps">> => #{<<"mode">> => <<"fail">>}},
    {Frames, Raw} = run_sse(Env, Token, Body),
    ?assertMatch([{undefined, #{<<"type">> := <<"RUN_ERROR">>,
                                <<"message">> := <<"The AG-UI agent rejected the request (HTTP 500)">>}}], Frames),
    ?assertEqual(nomatch, binary:match(Raw, <<"secret">>)).

proxy_unreachable(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    ok = muse_config:set((muse_config:all())#{agent_url => <<"http://127.0.0.1:1/agui">>}),
    {Frames, _} = run_sse(Env, Token, input(muse_ids:uuid(), <<"hi">>)),
    ?assertMatch([{undefined, #{<<"type">> := <<"RUN_ERROR">>,
                                <<"message">> := <<"Could not reach the AG-UI agent">>}}], Frames).

proxy_client_disconnect_cancels(Config) ->
    Env = ?config(env, Config),
    Token = muse_web_test_env:login(Env),
    Body = (input(muse_ids:uuid(), <<"hi">>))#{<<"forwardedProps">> => #{<<"mode">> => <<"slow">>}},
    {sse, C, S, _} = open(Env, post, "/api/agui/agent/default/run", auth(Token), Body),
    _ = read(C, S, until_type(<<"RUN_STARTED">>)),
    Upstream = receive {upstream_request, Pid, _, _, _} -> Pid after 5000 -> error(no_upstream_request) end,
    MRef = erlang:monitor(process, Upstream),
    gun:close(C),
    receive {'DOWN', MRef, process, Upstream, _} -> ok
    after 5000 -> error(upstream_not_cancelled)
    end.

%% The upstream AG-UI agent (cowboy handler for the proxy tests)

init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    persistent_term:get({?MODULE, test}) !
        {upstream_request, self(), cowboy_req:header(<<"authorization">>, Req),
         cowboy_req:header(<<"accept">>, Req), Body},
    {ok, #{<<"threadId">> := T, <<"runId">> := R} = In} = muse_json:decode(Body),
    Mode = maps:get(<<"mode">>, maps:get(<<"forwardedProps">>, In, #{}), <<"canned">>),
    {ok, upstream(Mode, T, R, Req), State}.

upstream(<<"fail">>, _T, _R, Req) ->
    cowboy_req:reply(500, #{<<"content-type">> => <<"text/plain">>}, <<"secret upstream detail">>, Req);
upstream(<<"slow">>, T, R, Req0) ->
    Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req0),
    ok = cowboy_req:stream_body(sse(1, #{<<"type">> => <<"RUN_STARTED">>, <<"threadId">> => T, <<"runId">> => R}),
                                nofin, Req),
    receive never -> Req after 60000 -> Req end;
upstream(_Canned, T, R, Req0) ->
    Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req0),
    Send = fun(Bin) -> ok = cowboy_req:stream_body(Bin, nofin, Req) end,
    Send(<<": upstream comment\n\n">>),
    Send(sse(1, #{<<"type">> => <<"RUN_STARTED">>, <<"threadId">> => T, <<"runId">> => R})),
    %% CRLF line endings
    Send(<<"id: 2\r\ndata: {\"type\":\"TEXT_MESSAGE_START\",\"messageId\":\"u1\",\"role\":\"assistant\"}\r\n\r\n">>),
    %% one frame split across chunks, in the middle of a CRLF
    Frame = <<"id: 3\r\ndata: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"messageId\":\"u1\",\"delta\":\"Hello from upstream\"}\r\n\r\n">>,
    {A, B} = split_binary(Frame, byte_size(Frame) - 3),
    Send(A), timer:sleep(50), Send(B),
    Send(<<"data: {\"type\":\"TEXT_MESSAGE_END\",\n", "data: \"messageId\":\"u1\"}\n\n">>),
    Send(sse(5, #{<<"type">> => <<"RUN_FINISHED">>, <<"threadId">> => T, <<"runId">> => R})),
    Send(sse(6, #{<<"type">> => <<"CUSTOM">>, <<"name">> => <<"after the end">>})),
    ok = cowboy_req:stream_body(<<>>, fin, Req),
    Req.

sse(Id, Event) ->
    iolist_to_binary(["id: ", integer_to_list(Id), "\ndata: ", muse_json:encode(Event), "\n\n"]).
