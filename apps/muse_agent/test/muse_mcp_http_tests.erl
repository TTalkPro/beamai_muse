-module(muse_mcp_http_tests).
-include_lib("eunit/include/eunit.hrl").

mcp_http_test_() ->
    {setup, fun muse_mcp_fake:start/0, fun(_) -> muse_mcp_fake:stop() end,
     [fun json_round_trip/0,
      fun sse_round_trip/0,
      fun http_status_errors/0,
      fun jsonrpc_error/0,
      fun timeout/0,
      fun size_cap/0,
      fun unsupported_protocol/0,
      fun connection_refused/0,
      fun caller_death_closes_connection/0]}.

open(Path) ->
    open(Path, #{}).

open(Path, Opts) ->
    muse_mcp_http:open(muse_mcp_fake:url(Path), Opts).

json_round_trip() ->
    muse_mcp_fake:reset(),
    {ok, C} = open(<<"json">>, #{headers => [{<<"authorization">>, <<"Bearer k">>}]}),
    ?assertEqual(<<"sess-1">>, muse_mcp_http:session_id(C)),
    ?assertMatch(#{<<"serverInfo">> := #{<<"name">> := <<"fake">>}}, muse_mcp_http:server_result(C)),
    {ok, Tools} = muse_mcp_http:list_tools(C),
    ?assertEqual([<<"a">>, <<"b">>], [maps:get(<<"name">>, T) || T <- Tools]),
    {ok, #{<<"content">> := [#{<<"text">> := Text}]}} =
        muse_mcp_http:call_tool(C, <<"echo">>, #{<<"q">> => <<"hi">>}),
    ?assertEqual(#{<<"q">> => <<"hi">>}, json:decode(Text)),
    ok = muse_mcp_http:close(C),
    [Init, Initialized, List1, List2, Call] = muse_mcp_fake:requests(),
    ?assertMatch(#{method := <<"initialize">>, session := undefined, version := undefined,
                   accept := <<"application/json, text/event-stream">>,
                   auth := <<"Bearer k">>,
                   params := #{<<"protocolVersion">> := <<"2025-11-25">>}}, Init),
    ?assertMatch(#{method := <<"notifications/initialized">>, session := <<"sess-1">>,
                   version := <<"2025-11-25">>}, Initialized),
    ?assertMatch(#{params := #{}}, List1),
    ?assertMatch(#{params := #{<<"cursor">> := <<"p2">>}}, List2),
    [?assertMatch(#{session := <<"sess-1">>, version := <<"2025-11-25">>, auth := <<"Bearer k">>}, R)
     || R <- [List1, List2, Call]].

sse_round_trip() ->
    muse_mcp_fake:reset(),
    {ok, C} = open(<<"sse">>),
    ?assertEqual(<<"sess-1">>, muse_mcp_http:session_id(C)),
    {ok, Tools} = muse_mcp_http:list_tools(C),
    ?assertEqual(2, length(Tools)),
    {ok, #{<<"content">> := [#{<<"text">> := Text}]}} =
        muse_mcp_http:call_tool(C, <<"echo">>, #{<<"n">> => 1}),
    ?assertEqual(#{<<"n">> => 1}, json:decode(Text)),
    muse_mcp_http:close(C).

http_status_errors() ->
    {error, {http, 401, <<"boom">>} = E} = open(<<"status/401">>),
    ?assertEqual(<<"Streamable HTTP error: Error POSTing to endpoint: boom">>,
                 muse_mcp_http:error_message(E)),
    ?assertMatch({error, {http, 503, <<"boom">>}}, open(<<"status/503">>)),
    ?assertMatch({error, {redirect, 302}}, open(<<"status/302">>)).

jsonrpc_error() ->
    {ok, C} = open(<<"rpcerror">>),
    {error, {jsonrpc, -32602, <<"bad args">>, undefined} = E} =
        muse_mcp_http:call_tool(C, <<"x">>, #{}),
    ?assertEqual(<<"MCP error -32602: bad args">>, muse_mcp_http:error_message(E)),
    muse_mcp_http:close(C).

timeout() ->
    {ok, C} = open(<<"slow">>, #{timeout => 300}),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, timeout}, muse_mcp_http:call_tool(C, <<"x">>, #{})),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 2000),
    muse_mcp_http:close(C),
    %% An absolute deadline also bounds the handshake.
    Deadline = erlang:monotonic_time(millisecond) + 300,
    ?assertEqual({error, timeout}, open(<<"slowinit">>, #{deadline => Deadline})).

size_cap() ->
    {ok, C} = open(<<"big">>, #{max_body => 1024 * 1024}),
    ?assertEqual({error, too_large}, muse_mcp_http:call_tool(C, <<"x">>, #{})),
    muse_mcp_http:close(C).

unsupported_protocol() ->
    ?assertMatch({error, {unsupported_protocol, <<"1999-01-01">>}},
                 open(<<"json">>, #{protocol_version => <<"1999-01-01">>})).

connection_refused() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    ok = gen_tcp:close(L),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/mcp">>,
    {error, {transport, _} = E} = muse_mcp_http:open(Url, #{timeout => 2000}),
    ?assertEqual(<<"fetch failed">>, muse_mcp_http:error_message(E)).

caller_death_closes_connection() ->
    Before = gun_conns(),
    Self = self(),
    Pid = spawn(fun() ->
                    {ok, C} = open(<<"slow">>),
                    Self ! opened,
                    muse_mcp_http:call_tool(C, <<"x">>, #{})
                end),
    receive opened -> ok after 5000 -> error(not_opened) end,
    ?assertEqual(Before + 1, gun_conns()),
    exit(Pid, kill),
    wait_until(fun() -> gun_conns() =:= Before end, 50).

gun_conns() ->
    length(supervisor:which_children(gun_conns_sup)).

wait_until(F, 0) -> ?assert(F());
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(20), wait_until(F, N - 1)
    end.
