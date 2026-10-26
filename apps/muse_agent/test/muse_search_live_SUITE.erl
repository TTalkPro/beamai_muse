%% Live MCP smoke tests against public servers. Runs only with
%% MUSE_TEST_LIVE_SEARCH=1; PARALLEL_API_KEY is passed on when set.
-module(muse_search_live_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([deepwiki_list_tools/1, parallel_search/1]).

all() -> [deepwiki_list_tools, parallel_search].

init_per_suite(Config) ->
    case os:getenv("MUSE_TEST_LIVE_SEARCH") of
        "1" ->
            {ok, _} = application:ensure_all_started(gun),
            ok = muse_store:init(#{storage => ram}),
            Env = case os:getenv("PARALLEL_API_KEY") of
                      false -> #{};
                      Key -> #{<<"PARALLEL_API_KEY">> => list_to_binary(Key)}
                  end,
            {ok, C} = muse_config:from_env(Env),
            ok = muse_config:set(C),
            Config;
        _ ->
            {skip, "set MUSE_TEST_LIVE_SEARCH=1"}
    end.

end_per_suite(_Config) ->
    stopped = muse_store:stop(),
    ok.

deepwiki_list_tools(_Config) ->
    {ok, C} = beamai_mcp_client:start_link(#{transport => http,
                                             url => <<"https://mcp.deepwiki.com/mcp">>,
                                             timeout => 30000}),
    try
        ok = beamai_mcp_client:await_connected(C, 30000),
        {ok, #{<<"tools">> := Tools}} = beamai_mcp_client:list_tools(C),
        Names = [maps:get(<<"name">>, T) || T <- Tools],
        ct:pal("deepwiki capabilities=~p tools=~p",
               [beamai_mcp_client:get_capabilities(C), Names]),
        ?assertNotEqual([], Names)
    after
        beamai_mcp_client:stop(C)
    end.

parallel_search(_Config) ->
    Args = #{<<"objective">> => <<"What is the latest Erlang/OTP major release?">>,
             <<"search_queries">> => [<<"Erlang OTP latest release">>]},
    Result = muse_search:search(<<"local-user">>, <<"chat:live">>, Args),
    ct:pal("parallel search: ~tp", [Result]),
    case Result of
        {ok, #{<<"results">> := Results}} -> ?assert(is_list(Results));
        {error, Msg} -> {comment, binary_to_list(Msg)}
    end.
