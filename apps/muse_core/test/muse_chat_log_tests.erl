%% The model's view of a conversation is repaired (muse_chat_log:repair/1):
%% a tool call cut off by a restart gets an "interrupted" result, so the
%% provider does not refuse every later request with HTTP 400.
-module(muse_chat_log_tests).
-include_lib("eunit/include/eunit.hrl").

call(Id) -> #{id => Id, type => function, function => #{name => <<"run">>, arguments => <<"{}">>}}.
result(Id) -> #{role => tool, tool_call_id => Id, content => <<"ok">>}.

intact_history_is_unchanged_test() ->
    H = [#{role => user, content => <<"hi">>},
         #{role => assistant, content => <<>>, tool_calls => [call(<<"a">>), call(<<"b">>)]},
         result(<<"a">>), result(<<"b">>),
         #{role => assistant, content => <<"done">>}],
    ?assertEqual(H, muse_chat_log:repair(H)).

interrupted_call_gets_a_result_test() ->
    H = [#{role => user, content => <<"go">>},
         #{role => assistant, content => <<>>, tool_calls => [call(<<"a">>), call(<<"b">>)]},
         result(<<"a">>),
         %% the run was cut off here; later the person writes again
         #{role => user, content => <<"继续任务"/utf8>>},
         #{role => user, content => <<"继续任务"/utf8>>}],
    [U, A, Ra, #{role := tool, tool_call_id := <<"b">>, content := Interrupted}, U1, U2] = muse_chat_log:repair(H),
    ?assertEqual([U, A, Ra, U1, U2], [lists:nth(N, H) || N <- [1, 2, 3, 4, 5]]),
    ?assertNotEqual(nomatch, binary:match(Interrupted, <<"interrupted">>)).

last_message_cut_off_test() ->
    H = [#{role => user, content => <<"go">>},
         #{role => assistant, content => <<>>, tool_calls => [#{<<"id">> => <<"x">>}]}],
    ?assertMatch([_, _, #{role := tool, tool_call_id := <<"x">>}], muse_chat_log:repair(H)).

orphan_result_is_dropped_test() ->
    H = [#{role => user, content => <<"go">>}, result(<<"ghost">>), #{role => assistant, content => <<"ok">>}],
    ?assertEqual([lists:nth(1, H), lists:nth(3, H)], muse_chat_log:repair(H)).
