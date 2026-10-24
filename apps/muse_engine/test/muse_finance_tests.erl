%% Ports of tests/finance.test.ts, tests/finance-headers.test.ts and the
%% finance case of tests/engine.test.ts, plus the size limits (E§5.7).
%% Byte-exact reference vectors live in muse_engine_ref_tests.
-module(muse_finance_tests).
-include_lib("eunit/include/eunit.hrl").

-define(H, "date,description,amount,category\n").

analyze(Csv) ->
    {ok, A} = muse_finance:analyze(Csv),
    A.

is_error(Pattern, Result) ->
    {error, Msg} = Result,
    re:run(Msg, Pattern, [caseless, {capture, none}]) =:= match.

%% finance.test.ts

characters_after_closing_quote_test() ->
    [?assertEqual({error, <<"Invalid quoted CSV field">>},
                  muse_finance:analyze(<<?H "2026-09-01,Coffee,", Amount/binary, ",Food">>))
     || Amount <- [<<"\"10\"0">>, <<"\"\"10">>, <<"\"10\".00">>, <<"\"10\" ">>]],
    ?assertEqual({error, <<"Invalid quoted CSV field">>},
                 muse_finance:analyze(<<?H "2026-09-01,\"Coffee\"shop,10,Food">>)).

quoted_fields_at_boundaries_test() ->
    [begin
         A = analyze(<<"\"date\",\"description\",\"amount\",\"category\"\r\n"
                       "\"2026-09-01\",\"Coffee, \"\"local\"\"\nshop\",\"10.10\",\"Food\"\r\n"
                       "\"2026-09-02\",\"\",\"20.20\",\"\"", Ending/binary>>),
         ?assertEqual(2, maps:get(<<"count">>, A)),
         ?assertEqual(30.3, maps:get(<<"spending">>, A)),
         [T0, T1] = maps:get(<<"transactions">>, A),
         ?assertEqual(<<"Coffee, \"local\"\nshop">>, maps:get(<<"description">>, T0)),
         ?assertEqual(<<>>, maps:get(<<"description">>, T1)),
         ?assertEqual(<<"Uncategorized">>, maps:get(<<"category">>, T1))
     end || Ending <- [<<>>, <<"\n">>, <<"\r\n">>, <<"\r">>]].

byte_order_mark_test() ->
    [begin
         A = analyze(<<16#FEFF/utf8, Header/binary, "\n2026-09-01,Coffee,10.10,Food">>),
         ?assertEqual(1, maps:get(<<"count">>, A)),
         ?assertEqual(10.1, maps:get(<<"spending">>, A))
     end || Header <- [<<"date,description,amount,category">>,
                       <<"\"date\",\"description\",\"amount\",\"category\"">>]].

%% finance-headers.test.ts

duplicate_required_headers_test() ->
    [?assert(is_error(<<"duplicate.*column">>,
                      muse_finance:analyze(<<"date,description,amount,category,", C/binary,
                                             "\n2026-09-01,Purchase,10,Food,1000">>)))
     || C <- [<<"date">>, <<"description">>, <<"amount">>, <<"category">>]].

header_uniqueness_after_normalization_test() ->
    ?assert(is_error(<<"duplicate.*column">>,
                     muse_finance:analyze(<<"date,description,amount,category, Amount \n"
                                            "2026-09-01,Purchase,10,Food,1000">>))).

reordered_and_extra_columns_test() ->
    A = analyze(<<"note,category,amount,description,date\nIgnored,Food,10,Purchase,2026-09-01">>),
    ?assertEqual(10, maps:get(<<"spending">>, A)),
    ?assertEqual(1, maps:get(<<"count">>, A)),
    [T] = maps:get(<<"transactions">>, A),
    ?assertEqual(<<"Purchase">>, maps:get(<<"description">>, T)).

duplicate_irrelevant_columns_test() ->
    A = analyze(<<"note,date,description,amount,category,note\n"
                  "First,2026-09-01,Purchase,10,Food,Second">>),
    ?assertEqual(10, maps:get(<<"spending">>, A)),
    ?assertEqual(1, maps:get(<<"count">>, A)).

%% engine.test.ts

cents_exact_and_ambiguous_rejected_test() ->
    A = analyze(<<"date,description,amount,category\n2026-09-01,Salary,-1000,Income\n"
                  "2026-09-02,\"Coffee, local\",10.10,Food\n2026-09-03,Lunch,20.20,Food">>),
    ?assertEqual(30.3, maps:get(<<"spending">>, A)),
    ?assertEqual(969.7, maps:get(<<"saved">>, A)),
    [#{<<"amount">> := 30.3, <<"name">> := <<"Food">>}] = maps:get(<<"categories">>, A),
    ?assertMatch({error, _}, muse_finance:analyze(<<?H "2026-02-31,Purchase,10,Food">>)),
    ?assertMatch({error, _}, muse_finance:analyze(<<?H "2026-09-01,Purchase,1.234,Food">>)).

%% Limits and shape

shape_test() ->
    A = analyze(<<?H "2026-09-02,Lunch,20.5,Food\n2026-09-01,Salary,-100,Income">>),
    ?assertEqual(#{<<"income">> => 100, <<"spending">> => 20.5, <<"saved">> => 79.5,
                   <<"count">> => 2,
                   <<"categories">> => [#{<<"name">> => <<"Food">>, <<"amount">> => 20.5}],
                   <<"transactions">> =>
                       [#{<<"id">> => <<"row-2">>, <<"date">> => <<"2026-09-02">>,
                          <<"description">> => <<"Lunch">>, <<"amount">> => 20.5,
                          <<"category">> => <<"Food">>},
                        #{<<"id">> => <<"row-3">>, <<"date">> => <<"2026-09-01">>,
                          <<"description">> => <<"Salary">>, <<"amount">> => -100,
                          <<"category">> => <<"Income">>}],
                   <<"period">> => #{<<"from">> => <<"2026-09-01">>, <<"to">> => <<"2026-09-02">>},
                   <<"amountConvention">> =>
                       <<"Positive expenses; negative income. Values use the source currency; "
                         "no currency conversion.">>},
                 A),
    ?assertEqual(<<"2 transactions \x{b7} 20.50 spent"/utf8>>, muse_finance:summary(A)),
    ?assertEqual(<<"2 rows; 2026-09-01 through 2026-09-02">>, muse_finance:excerpt(A)).

row_limit_test() ->
    Rows = fun(N) -> iolist_to_binary([?H | lists:duplicate(N, <<"2026-09-01,x,1.01,F\n">>)]) end,
    A = analyze(Rows(5000)),
    ?assertEqual(5000, maps:get(<<"count">>, A)),
    ?assertEqual(5050, maps:get(<<"spending">>, A)),
    ?assertEqual(<<"row-5001">>, maps:get(<<"id">>, lists:last(maps:get(<<"transactions">>, A)))),
    ?assertEqual({error, <<"Import between 1 and 5,000 transactions">>},
                 muse_finance:analyze(Rows(5001))).

size_limit_counts_utf16_units_test() ->
    Body = fun(Pad, N) -> <<?H "2026-09-01,", (binary:copy(Pad, N))/binary, ",1,F">> end,
    Fixed = byte_size(Body(<<>>, 0)),
    ?assertEqual({error, <<"Import at most 500 KB of transaction CSV">>},
                 muse_finance:analyze(Body(<<"a">>, 500001 - Fixed))),
    ?assertMatch({ok, _}, muse_finance:analyze(Body(<<"a">>, 500000 - Fixed))),
    %% 2 bytes, 1 unit each: over 500000 bytes but within the limit.
    ?assertMatch({ok, _}, muse_finance:analyze(Body(<<"\x{e9}"/utf8>>, 250000))),
    %% 4 bytes, 2 units each.
    ?assertEqual({error, <<"Import at most 500 KB of transaction CSV">>},
                 muse_finance:analyze(Body(<<"\x{1F642}"/utf8>>, 250000))),
    %% The BOM counts toward the limit before it is stripped.
    ?assertEqual({error, <<"Import at most 500 KB of transaction CSV">>},
                 muse_finance:analyze(<<16#FEFF/utf8, (Body(<<"a">>, 500000 - Fixed))/binary>>)).

amount_range_test() ->
    Csv = fun(Amount) -> <<?H "2026-09-01,x,", Amount/binary, ",F">> end,
    ?assertMatch({ok, #{<<"spending">> := 10000000000}}, muse_finance:analyze(Csv(<<"10000000000">>))),
    ?assertEqual({error, <<"Transaction amount is out of range">>},
                 muse_finance:analyze(Csv(<<"10000000000.01">>))),
    ?assertEqual({error, <<"Transaction amount is out of range">>},
                 muse_finance:analyze(Csv(binary:copy(<<"9">>, 100000)))),
    ?assertMatch({ok, #{<<"spending">> := 1}},
                 muse_finance:analyze(Csv(<<(binary:copy(<<"0">>, 1000))/binary, "1">>))).

to_fixed_test() ->
    ?assertEqual(<<"1.00">>, muse_finance:to_fixed(1.005, 2)),
    ?assertEqual(<<"0.13">>, muse_finance:to_fixed(0.125, 2)),
    ?assertEqual(<<"-0.13">>, muse_finance:to_fixed(-0.125, 2)),
    ?assertEqual(<<"-0.00">>, muse_finance:to_fixed(-0.001, 2)),
    ?assertEqual(<<"0.00">>, muse_finance:to_fixed(-0.0, 2)),
    ?assertEqual(<<"3">>, muse_finance:to_fixed(2.5, 0)),
    ?assertEqual(<<"1e+21">>, muse_finance:to_fixed(1.0e21, 2)),
    ?assertEqual(<<"12.00">>, muse_finance:to_fixed(12, 2)).
