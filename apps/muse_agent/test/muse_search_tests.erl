-module(muse_search_tests).
-include_lib("eunit/include/eunit.hrl").

-define(O, <<"local-user">>).
-define(ARGS, args()).

args() ->
    #{<<"objective">> => <<" find erlang news ">>,
      <<"search_queries">> => [<<" erlang otp 28 ">>]}.

search_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [fun texts_and_schema/0,
      fun result_mapping/0,
      fun text_payload/0,
      fun tool_and_payload_errors/0,
      fun session_reuse_and_headers/0,
      fun bearer_when_configured/0,
      fun transport_errors/0,
      fun caller_death_closes_connection/0]}.

setup() ->
    ok = muse_mcp_fake:start(),
    ok = muse_store:init(#{storage => ram}),
    config(#{}).

cleanup(_) ->
    stopped = muse_store:stop(),
    muse_mcp_fake:stop().

config(Env) ->
    {ok, C} = muse_config:from_env(Env),
    muse_config:set(C).

search(Key, Path) ->
    search(Key, Path, #{}).

search(Key, Path, Opts) ->
    muse_search:search(?O, Key, ?ARGS, Opts#{url => muse_mcp_fake:url(Path)}).

texts_and_schema() ->
    ?assertMatch(<<"Search the public web. Supply", _/binary>>, muse_search:description()),
    ?assertMatch(<<" For public-web research", _/binary>>, muse_search:instructions()),
    S = muse_search:schema(),
    ?assertEqual({ok, #{<<"objective">> => <<"find erlang news">>,
                        <<"search_queries">> => [<<"erlang otp 28">>]}},
                 muse_validate:check(S, ?ARGS)),
    ?assertMatch({error, _}, muse_validate:check(S, (?ARGS)#{<<"search_queries">> => []})),
    ?assertMatch({error, _}, muse_validate:check(S, (?ARGS)#{<<"search_queries">> =>
                                                               lists:duplicate(6, <<"q">>)})),
    ?assertMatch({error, _}, muse_validate:check(S, (?ARGS)#{<<"objective">> => <<"   ">>})),
    ?assertMatch({error, _}, muse_search:search(?O, <<"chat:x">>, (?ARGS)#{<<"objective">> => <<>>})).

source(Url, Title, Excerpts) ->
    #{<<"url">> => Url, <<"title">> => Title, <<"excerpts">> => Excerpts,
      <<"publish_date">> => <<"2026-01-01">>, <<"extra">> => 1}.

result_mapping() ->
    Long = binary:copy(<<"e">>, 29990),
    Payload = #{<<"results">> =>
                    [source(<<"https://a.example/">>, binary:copy(<<"t">>, 350), [Long, <<"0123456789abcdef">>, <<"lost">>]),
                     #{<<"url">> => <<"ftp://bad.example/">>, <<"excerpts">> => []},
                     #{<<"url">> => <<"https://no-excerpts.example/">>},
                     #{<<"url">> => <<"http://b.example/">>, <<"excerpts">> => [<<"x">>], <<"title">> => null}],
                <<"warnings">> => [<<"plain">>, #{<<"type">> => <<"rate">>, <<"message">> => <<"slow down">>}]},
    muse_mcp_fake:set_search_result(#{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"ignored">>}],
                                      <<"structuredContent">> => Payload}),
    {ok, R} = search(<<"chat:map">>, <<"json">>),
    ?assertEqual(#{<<"provider">> => <<"parallel">>,
                   <<"results">> =>
                       [#{<<"url">> => <<"https://a.example/">>,
                          <<"title">> => binary:copy(<<"t">>, 300),
                          <<"excerpts">> => [Long, <<"0123456789">>],
                          <<"publish_date">> => <<"2026-01-01">>},
                        #{<<"url">> => <<"http://b.example/">>, <<"title">> => null,
                          <<"excerpts">> => [], <<"publish_date">> => null}],
                   <<"warnings">> => [<<"Dropped 2 invalid search result entries">>,
                                      <<"plain">>, <<"rate: slow down">>],
                   <<"truncated">> => true}, R),
    %% Clean result: nothing truncated, at most 10 sources kept otherwise.
    Many = [source(<<"https://s", (integer_to_binary(I))/binary, ".example/">>, <<"T">>, [<<"x">>])
            || I <- lists:seq(1, 12)],
    muse_mcp_fake:set_search_result(#{<<"content">> => [], <<"structuredContent">> =>
                                          #{<<"results">> => lists:sublist(Many, 2), <<"warnings">> => null}}),
    ?assertMatch({ok, #{<<"truncated">> := false, <<"warnings">> := [], <<"results">> := [_, _]}},
                 search(<<"chat:map">>, <<"json">>)),
    muse_mcp_fake:set_search_result(#{<<"content">> => [], <<"structuredContent">> =>
                                          #{<<"results">> => Many}}),
    {ok, #{<<"truncated">> := true, <<"results">> := Ten}} = search(<<"chat:map">>, <<"json">>),
    ?assertEqual(10, length(Ten)).

text_payload() ->
    Text = iolist_to_binary(json:encode(#{<<"results">> => [source(<<"https://t.example/">>, <<"T">>, [<<"e">>])]})),
    muse_mcp_fake:set_search_result(#{<<"content">> => [#{<<"type">> => <<"image">>},
                                                        #{<<"type">> => <<"text">>, <<"text">> => Text}]}),
    ?assertMatch({ok, #{<<"results">> := [#{<<"url">> := <<"https://t.example/">>, <<"title">> := <<"T">>}]}},
                 search(<<"chat:text">>, <<"json">>)).

tool_and_payload_errors() ->
    muse_mcp_fake:set_search_result(#{<<"isError">> => true, <<"content">> =>
                                          [#{<<"type">> => <<"text">>, <<"text">> => <<"Rate limited">>}]}),
    ?assertEqual({error, <<"Parallel search failed: Rate limited">>}, search(<<"chat:e">>, <<"json">>)),
    muse_mcp_fake:set_search_result(#{<<"isError">> => true, <<"content">> => []}),
    ?assertEqual({error, <<"Parallel search failed: Search tool failed">>}, search(<<"chat:e">>, <<"json">>)),
    muse_mcp_fake:set_search_result(#{<<"content">> => [], <<"structuredContent">> => #{<<"hits">> => []}}),
    ?assertEqual({error, <<"Parallel search failed: Parallel returned an invalid search result">>},
                 search(<<"chat:e">>, <<"json">>)),
    muse_mcp_fake:set_search_result(#{<<"content">> => [], <<"structuredContent">> =>
                                          #{<<"results">> => [], <<"warnings">> => [1]}}),
    ?assertEqual({error, <<"Parallel search failed: Parallel returned an invalid search result">>},
                 search(<<"chat:e">>, <<"json">>)),
    muse_mcp_fake:set_search_result(#{<<"content">> => []}),
    ?assertEqual({error, <<"Parallel search failed: Parallel returned an invalid search result">>},
                 search(<<"chat:e">>, <<"json">>)).

session_reuse_and_headers() ->
    muse_mcp_fake:set_search_result(#{<<"content">> => [], <<"structuredContent">> => #{<<"results">> => []}}),
    muse_mcp_fake:reset(),
    {ok, _} = search(<<"chat:s1">>, <<"json">>),
    {ok, _} = search(<<"chat:s1">>, <<"sse">>),
    {ok, _} = search(<<"task:t1">>, <<"json">>),
    Calls = [R || #{method := <<"tools/call">>} = R <- muse_mcp_fake:requests()],
    [A1, A2, B] = [maps:get(<<"arguments">>, P) || #{params := P} <- Calls],
    #{<<"sessionId">> := Sid} = muse_store:get(?O, <<"search-sessions">>, <<"chat:s1">>),
    ?assert(muse_ids:is_uuid(Sid)),
    ?assertEqual(#{<<"objective">> => <<"find erlang news">>,
                   <<"search_queries">> => [<<"erlang otp 28">>],
                   <<"session_id">> => Sid}, A1),
    ?assertEqual(A1, A2),
    ?assertNotEqual(Sid, maps:get(<<"session_id">>, B)),
    [?assertMatch(#{user_agent := <<"openmuse/0.1.0">>, auth := undefined}, R)
     || R <- muse_mcp_fake:requests()],
    ?assertMatch([#{params := #{<<"clientInfo">> := #{<<"name">> := <<"openmuse">>,
                                                      <<"version">> := <<"0.1.0">>}}} | _],
                 muse_mcp_fake:requests()),
    ok.

bearer_when_configured() ->
    config(#{<<"PARALLEL_API_KEY">> => <<" pk-1 ">>}),
    muse_mcp_fake:reset(),
    try
        {ok, _} = search(<<"chat:k">>, <<"json">>),
        [?assertMatch(#{auth := <<"Bearer pk-1">>}, R) || R <- muse_mcp_fake:requests()]
    after
        config(#{})
    end.

transport_errors() ->
    ?assertEqual({error, <<"Parallel search timed out after 45 seconds">>},
                 search(<<"chat:x">>, <<"slow">>, #{timeout => 300})),
    ?assertEqual({error, <<"Parallel search failed: Search response exceeded 1 MiB">>},
                 search(<<"chat:x">>, <<"big">>)),
    ?assertEqual({error, <<"Parallel search failed: Streamable HTTP error: Error POSTing to endpoint: boom">>},
                 search(<<"chat:x">>, <<"status/401">>)),
    ?assertEqual({error, <<"Parallel search failed: MCP error -32602: bad args">>},
                 search(<<"chat:x">>, <<"rpcerror">>)).

caller_death_closes_connection() ->
    Before = length(supervisor:which_children(gun_conns_sup)),
    Pid = spawn(fun() -> search(<<"chat:kill">>, <<"slow">>) end),
    timer:sleep(300),
    ?assertEqual(Before + 1, length(supervisor:which_children(gun_conns_sup))),
    exit(Pid, kill),
    timer:sleep(500),
    ?assertEqual(Before, length(supervisor:which_children(gun_conns_sup))).
