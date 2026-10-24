%% The live Jev adapter against a fake transport (OpenMuse tests/jev.test.ts,
%% "live adapter ..." and "real client ..." cases).
-module(muse_jev_typesafe_tests).
-include_lib("eunit/include/eunit.hrl").

option(Id) ->
    #{<<"id">> => Id, <<"label">> => <<"Option ", Id/binary>>, <<"details">> => [<<"Detail">>],
      <<"sources">> => [#{<<"title">> => <<"Source">>, <<"url">> => <<"https://example.org">>}]}.

input() ->
    #{<<"userMessage">> => <<"Something hands-on">>, <<"message">> => <<"compare">>, <<"context">> => <<"source">>,
      <<"options">> => [option(<<"a">>)], <<"allowedControls">> => [<<"comparison">>, <<"agent">>]}.

choice(C) -> choice(C, 0.8).
choice(C, Conf) -> #{<<"type">> => <<"choice">>, <<"choice">> => C, <<"confidence">> => Conf}.
score(S) -> #{<<"type">> => <<"score">>, <<"score">> => S, <<"confidence">> => 0.8}.

result(Answers) -> #{<<"model">> => <<"jev-1.13.0">>, <<"answers">> => Answers}.

%% A fake transport answering with Responses in turn; sent requests go to self().
fake(Responses) ->
    Counter = counters:new(1, []),
    Self = self(),
    fun(Url, Headers, Body, Timeout) ->
            counters:add(Counter, 1, 1),
            N = counters:get(Counter, 1),
            Self ! {sent, Url, Headers, Body, Timeout},
            case lists:nth(min(N, length(Responses)), Responses) of
                {error, _} = E -> E;
                {Status, Json} -> {ok, Status, [{<<"x-typesafe-request-id">>, <<"req_live">>}], muse_json:encode(Json)}
            end
    end.

decide(Input, Responses) ->
    _ = sent(),
    muse_jev_typesafe:decide(Input, #{api_key => <<"test-key">>, model => <<"jev-1.13.0">>,
                                      base_url => <<"https://api.typesafe.ai">>, request => fake(Responses),
                                      sleep => fun(_) -> ok end}).

sent() ->
    receive {sent, U, H, B, T} -> [{U, H, B, T} | sent()] after 0 -> [] end.

request_shape_test() ->
    ?assertEqual({ok, #{<<"control">> => <<"comparison">>, <<"scores">> => #{<<"a">> => 3}}},
                 decide(input(), [{200, result(#{<<"control">> => choice(<<"comparison">>), <<"fit_0">> => score(3)})}])),
    [{Url, Headers, Body, Timeout}] = sent(),
    ?assertEqual(<<"https://api.typesafe.ai/v1/systemone">>, Url),
    ?assertEqual(5000, Timeout),
    ?assertEqual(<<"Bearer test-key">>, proplists:get_value(<<"authorization">>, Headers)),
    {ok, #{<<"model">> := <<"jev-1.13.0">>, <<"state">> := State, <<"questions">> := Qs}} = muse_json:decode(Body),
    ?assertMatch(#{<<"userMessage">> := <<"Something hands-on">>, <<"agentSummary">> := <<"compare">>,
                   <<"selectedId">> := null, <<"options">> := [#{<<"id">> := <<"a">>}]}, State),
    ?assertEqual([<<"control">>, <<"fit_0">>], lists:sort(maps:keys(Qs))),
    #{<<"control">> := #{<<"type">> := <<"choice">>, <<"criteria">> := Criteria},
      <<"fit_0">> := #{<<"type">> := <<"score">>, <<"instructions">> := Fit, <<"criteria">> := Levels}} = Qs,
    ?assertEqual([<<"agent">>, <<"comparison">>], lists:sort(maps:keys(Criteria))),
    ?assertEqual(<<"Answer the user in prose without choice cards">>, maps:get(<<"agent">>, Criteria)),
    ?assertEqual([<<"Does not fit">>, <<"Some fit">>, <<"Good fit">>, <<"Best fit">>], Levels),
    %% options are referenced by position, never by their (untrusted) label
    ?assertNotEqual(nomatch, binary:match(Fit, <<"`options[0]`">>)),
    ?assertEqual(nomatch, binary:match(Fit, <<"Option a">>)).

low_confidence_keeps_prepared_control_test() ->
    ?assertMatch({ok, #{<<"control">> := <<"comparison">>}},
                 decide(input(), [{200, result(#{<<"control">> => choice(<<"agent">>, 0.49), <<"fit_0">> => score(2)})}])),
    ?assertMatch({ok, #{<<"control">> := <<"agent">>}},
                 decide(input(), [{200, result(#{<<"control">> => choice(<<"agent">>, 0.5), <<"fit_0">> => score(2)})}])),
    _ = sent().

fractional_score_kept_test() ->
    ?assertMatch({ok, #{<<"scores">> := #{<<"a">> := 1.93}}},
                 decide(input(), [{200, result(#{<<"control">> => choice(<<"comparison">>), <<"fit_0">> => score(1.93)})}])),
    _ = sent().

invalid_answers_test_() ->
    Bad = fun(Answers) -> decide(input(), [{200, #{<<"answers">> => Answers}}]) end,
    [?_assertEqual({error, <<"Jev returned invalid answers">>}, Bad(M)) || M <- [null, [], <<"invalid">>]] ++
    [?_assertEqual({error, <<"Jev returned invalid answers">>}, decide(input(), [{200, #{}}])),
     ?_assertEqual({error, <<"Jev returned an invalid control">>},
                   Bad(#{<<"control">> => choice(<<"clarification">>), <<"fit_0">> => score(2)})),
     ?_assertEqual({error, <<"Jev returned an invalid control">>},
                   Bad(#{<<"control">> => choice(<<"comparison">>, 1.5), <<"fit_0">> => score(2)})),
     ?_assertEqual({error, <<"Jev returned an invalid score">>},
                   Bad(#{<<"control">> => choice(<<"comparison">>), <<"fit_0">> => score(4)})),
     ?_assertEqual({error, <<"Jev returned an invalid score">>},
                   Bad(#{<<"control">> => choice(<<"comparison">>)}))].

server_error_retried_once_test() ->
    ?assertEqual({error, <<"Jev could not evaluate these choices. Please retry.">>},
                 decide(input(), [{503, #{<<"error">> => <<"unavailable">>}}])),
    [{_, H1, _, _}, {_, H2, _, _}] = sent(),
    ?assertEqual(undefined, proplists:get_value(<<"x-typesafe-retry-count">>, H1)),
    ?assertEqual(<<"1">>, proplists:get_value(<<"x-typesafe-retry-count">>, H2)).

retry_then_success_test() ->
    ?assertMatch({ok, _}, decide(input(), [{error, timeout},
                                           {200, result(#{<<"control">> => choice(<<"comparison">>),
                                                          <<"fit_0">> => score(1)})}])),
    ?assertEqual(2, length(sent())).

auth_failure_not_retried_test() ->
    ?assertEqual({error, <<"Jev is unavailable for these choices. Do not retry; answer the user in prose.">>},
                 decide(input(), [{401, #{<<"error">> => <<"bad key">>}}])),
    ?assertEqual(1, length(sent())).

rate_limit_is_retryable_test() ->
    ?assertEqual({error, <<"Jev could not evaluate these choices. Please retry.">>},
                 decide(input(), [{429, #{}}])),
    ?assertEqual(2, length(sent())).

no_controls_test() ->
    ?assertEqual({error, <<"Jev has no allowed controls">>},
                 decide((input())#{<<"allowedControls">> => []}, [])).

%% Live smoke test against the real API (TYPESAFE_BASE_URL, JEV_MODEL may
%% point elsewhere); skipped without TYPESAFE_API_KEY.
live_smoke_test_() ->
    case os:getenv("TYPESAFE_API_KEY") of
        Key when is_list(Key), Key =/= "" ->
            {timeout, 30,
             fun() ->
                     {ok, _} = application:ensure_all_started([ssl, inets, gun, beamai_core]),
                     Base = list_to_binary(os:getenv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")),
                     Input = (input())#{<<"options">> => [option(<<"a">>), option(<<"b">>)]},
                     ?assertMatch({ok, #{<<"control">> := _, <<"scores">> := #{<<"a">> := _, <<"b">> := _}}},
                                  muse_jev_typesafe:decide(Input, #{api_key => list_to_binary(Key),
                                                                    model => list_to_binary(os:getenv("JEV_MODEL", "jev-1.13.0")),
                                                                    base_url => Base}))
             end};
        _ -> []
    end.
