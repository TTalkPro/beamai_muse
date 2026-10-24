-module(muse_json_tests).
-include_lib("eunit/include/eunit.hrl").

%% Expected strings were produced by Node 24 (`String(n)`, `JSON.stringify`).
numbers_test_() ->
    Cases = [{0, <<"0">>}, {0.0, <<"0">>}, {-0.0, <<"0">>}, {1, <<"1">>}, {1.0, <<"1">>},
             {1.5, <<"1.5">>}, {-2.25, <<"-2.25">>}, {0.1, <<"0.1">>},
             {0.000001, <<"0.000001">>}, {0.0000001, <<"1e-7">>}, {1.0e21, <<"1e+21">>},
             {1.0e20, <<"100000000000000000000">>},
             {123456789012345680000.0, <<"123456789012345680000">>},
             {1.7976931348623157e308, <<"1.7976931348623157e+308">>},
             {5.0e-324, <<"5e-324">>}, {1 / 3, <<"0.3333333333333333">>},
             {100.0, <<"100">>}, {12345.6789, <<"12345.6789">>},
             {9007199254740992.0, <<"9007199254740992">>}],
    [?_assertEqual(Exp, muse_json:encode(N)) || {N, Exp} <- Cases].

strings_test_() ->
    Cases = [{<<"plain">>, <<"\"plain\"">>},
             {<<"quote\"back\\slash">>, <<"\"quote\\\"back\\\\slash\"">>},
             {<<"ctl", 1, 31, "\b\f\n\r\t">>, <<"\"ctl\\u0001\\u001f\\b\\f\\n\\r\\t\"">>},
             {<<"中文🙂"/utf8>>, <<"\"中文🙂\""/utf8>>},
             {<<"/slash">>, <<"\"/slash\"">>},
             {<<127, 16#e2, 16#80, 16#a8>>, <<"\"", 127, 16#e2, 16#80, 16#a8, "\"">>}],
    [?_assertEqual(Exp, muse_json:encode(S)) || {S, Exp} <- Cases].

ordered_object_test() ->
    ?assertEqual(<<"{\"b\":1,\"a\":[1,\"x\",null,true,{\"z\":false}],\"c\":{}}">>,
                 muse_json:encode({obj, [{b, 1}, {a, [1, <<"x">>, null, true, #{z => false}]},
                                         {c, #{}}]})).

undefined_members_dropped_test() ->
    ?assertEqual(<<"{\"a\":1}">>, muse_json:encode({obj, [{a, 1}, {b, undefined}]})),
    ?assertEqual(<<"[null]">>, muse_json:encode([undefined])).

map_keys_sorted_test() ->
    ?assertEqual(<<"{\"a\":1,\"b\":2}">>, muse_json:encode(#{<<"b">> => 2, <<"a">> => 1})).

decode_test() ->
    ?assertEqual({ok, #{<<"a">> => null, <<"b">> => [1, 2.5]}},
                 muse_json:decode(<<"{\"a\":null,\"b\":[1,2.5]}">>)),
    ?assertEqual({error, invalid_json}, muse_json:decode(<<"{">>)),
    ?assertEqual({error, not_object}, muse_json:decode_object(<<"[1]">>)),
    ?assertEqual({ok, #{}}, muse_json:decode_object(<<"{}">>)).

roundtrip_test() ->
    Doc = #{<<"id">> => <<"x">>, <<"n">> => 3, <<"f">> => 0.5, <<"l">> => [true, null],
            <<"s">> => <<"中文"/utf8>>},
    ?assertEqual({ok, Doc}, muse_json:decode(muse_json:encode(Doc))).
