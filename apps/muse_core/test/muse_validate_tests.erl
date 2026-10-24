-module(muse_validate_tests).
-include_lib("eunit/include/eunit.hrl").

task_schema() ->
    {object, [{<<"title">>, {optional, {string, #{trim => true, min => 1, max => 160}}}},
              {<<"prompt">>, {string, #{trim => true, min => 1, max => 12000}}},
              {<<"kind">>, {default, {enum, [<<"agent">>, <<"document">>]}, <<"agent">>}},
              {<<"input">>, {default, {record, any, #{}}, #{}}}]}.

object_defaults_and_strip_test() ->
    ?assertEqual({ok, #{<<"prompt">> => <<"do it">>, <<"kind">> => <<"agent">>, <<"input">> => #{}}},
                 muse_validate:check(task_schema(), #{<<"prompt">> => <<"  do it ">>,
                                                      <<"extra">> => 1})).

object_errors_test() ->
    {error, Msgs} = muse_validate:check(task_schema(), #{<<"title">> => <<"   ">>, <<"kind">> => <<"x">>}),
    ?assertEqual([<<"Too small: expected string to have >=1 characters">>,
                  <<"Invalid input: expected string, received undefined">>,
                  <<"Invalid option: expected one of \"agent\"|\"document\"">>], Msgs),
    ?assertMatch({error, {422, <<"Too small", _/binary>>}},
                 muse_validate:parse(task_schema(), #{<<"title">> => <<>>, <<"prompt">> => <<"p">>})).

utf16_length_test() ->
    ?assertEqual(2, muse_validate:utf16_length(<<"🙂"/utf8>>)),
    ?assertEqual(2, muse_validate:utf16_length(<<"中文"/utf8>>)),
    ?assertMatch({error, _}, muse_validate:check({string, #{max => 1}}, <<"🙂"/utf8>>)).

trim_test() ->
    ?assertEqual({ok, <<"a b">>},
                 muse_validate:check({string, #{trim => true}}, <<"\t a b \n", 16#e3, 16#80, 16#80>>)).

custom_message_test() ->
    S = {string, #{single_line => true, message => <<"Subject must be a single line">>}},
    ?assertEqual({error, [<<"Subject must be a single line">>]}, muse_validate:check(S, <<"a\nb">>)).

email_url_test_() ->
    E = {string, #{email => true}},
    U = {string, #{url => true}},
    [?_assertMatch({ok, _}, muse_validate:check(E, <<"a.b+c@example.org">>)),
     ?_assertMatch({error, [<<"Invalid email address">>]}, muse_validate:check(E, <<"nope">>)),
     ?_assertMatch({ok, _}, muse_validate:check(U, <<"https://example.com/x?y=1">>)),
     ?_assertMatch({error, [<<"Invalid URL">>]}, muse_validate:check(U, <<"not a url">>))].

array_and_numbers_test_() ->
    A = {array, {string, #{min => 1}}, #{min => 1, max => 2}},
    [?_assertMatch({ok, [<<"a">>]}, muse_validate:check(A, [<<"a">>])),
     ?_assertMatch({error, [<<"Too small: expected array to have >=1 items">>]}, muse_validate:check(A, [])),
     ?_assertMatch({error, [<<"Too big", _/binary>>]}, muse_validate:check(A, [<<"a">>, <<"b">>, <<"c">>])),
     ?_assertMatch({ok, 3}, muse_validate:check({integer, #{min => 1, max => 15}}, 3)),
     ?_assertMatch({ok, 3}, muse_validate:check({integer, #{}}, 3.0)),
     ?_assertMatch({error, _}, muse_validate:check({integer, #{}}, 3.5)),
     ?_assertMatch({error, [<<"Too big: expected number to be <=10">>]},
                   muse_validate:check({number, #{max => 10}}, 10.5))].

tagged_union_test_() ->
    S = {tagged, <<"kind">>,
         #{<<"a">> => {object, [{<<"kind">>, {literal, <<"a">>}}, {<<"x">>, boolean}]},
           <<"b">> => {object, [{<<"kind">>, {literal, <<"b">>}}]}}},
    [?_assertEqual({ok, #{<<"kind">> => <<"a">>, <<"x">> => true}},
                   muse_validate:check(S, #{<<"kind">> => <<"a">>, <<"x">> => true})),
     ?_assertMatch({error, [<<"Invalid input: expected kind to be one of", _/binary>>]},
                   muse_validate:check(S, #{<<"kind">> => <<"c">>}))].

refine_test() ->
    S = {refine, {string, #{}}, fun(<<"ok">>) -> ok; (_) -> {error, <<"must be ok">>} end},
    ?assertEqual({ok, <<"ok">>}, muse_validate:check(S, <<"ok">>)),
    ?assertEqual({error, [<<"must be ok">>]}, muse_validate:check(S, <<"no">>)).

record_test() ->
    S = {record, {union, [{string, #{max => 3}}, boolean]}, #{key => {string, #{min => 1}}, max => 2}},
    ?assertEqual({ok, #{<<"a">> => true, <<"b">> => <<"x">>}},
                 muse_validate:check(S, #{<<"a">> => true, <<"b">> => <<"x">>})),
    ?assertMatch({error, _}, muse_validate:check(S, #{<<"a">> => 1})),
    ?assertMatch({error, _}, muse_validate:check(S, #{<<"a">> => 1, <<"b">> => 2, <<"c">> => 3})).

nullable_optional_test() ->
    S = {object, [{<<"a">>, {optional, boolean}}, {<<"b">>, {nullable, boolean}}]},
    ?assertEqual({ok, #{<<"b">> => null}}, muse_validate:check(S, #{<<"b">> => null})),
    ?assertMatch({error, _}, muse_validate:check(S, #{<<"a">> => null, <<"b">> => true})).

ordered_test() ->
    S = {object, [{<<"to">>, {array, {string, #{}}, #{}}}, {<<"subject">>, {string, #{}}}]},
    {ok, V} = muse_validate:check(S, #{<<"subject">> => <<"s">>, <<"to">> => [<<"a">>]}),
    ?assertEqual(<<"{\"to\":[\"a\"],\"subject\":\"s\"}">>,
                 muse_json:encode(muse_validate:ordered(S, V))).
