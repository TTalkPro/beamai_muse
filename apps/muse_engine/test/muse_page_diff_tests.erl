%% Port of tests/page-diff.test.ts plus the monitor condition helpers
%% (E§5.5, E§5.6). Byte-exact reference vectors live in muse_engine_ref_tests.
-module(muse_page_diff_tests).
-include_lib("eunit/include/eunit.hrl").

-define(EMPTY, #{added => [], updated => [], removed => []}).

page_lines_test() ->
    ?assertEqual([<<"Jobs">>, <<"Siemens AI">>],
                 muse_page_diff:page_lines(<<"  Jobs \n\n Siemens   AI\r\nSiemens AI\n">>)),
    ?assertEqual(2, length(muse_page_diff:page_lines(<<"a\nb\nc">>, 2))),
    [Long] = muse_page_diff:page_lines(binary:copy(<<"x">>, 500)),
    ?assertEqual(300, byte_size(Long)).

page_lines_limit_test() ->
    Text = iolist_to_binary([[integer_to_binary(I), $\n] || I <- lists:seq(1, 2500)]),
    Lines = muse_page_diff:page_lines(Text),
    ?assertEqual(2000, length(Lines)),
    ?assertEqual(<<"2000">>, lists:last(Lines)).

new_lines_vs_number_changes_test() ->
    Before = [<<"AI jobs in Munich">>,
              <<"Siemens \x{b7} Werkstudent AI \x{b7} 2 openings \x{b7} posted 1 day ago"/utf8>>,
              <<"BCG \x{b7} Intern"/utf8>>],
    After = [<<"AI jobs in Munich">>,
             <<"SAP \x{b7} Working Student AI Engineer"/utf8>>,
             <<"Siemens \x{b7} Werkstudent AI \x{b7} 3 openings \x{b7} posted 2 days ago"/utf8>>],
    ?assertEqual(#{added => [<<"SAP \x{b7} Working Student AI Engineer"/utf8>>],
                   updated => [<<"Siemens \x{b7} Werkstudent AI \x{b7} 3 openings \x{b7} "
                                 "posted 2 days ago"/utf8>>],
                   removed => [<<"BCG \x{b7} Intern"/utf8>>]},
                 muse_page_diff:diff_page(Before, After)),
    ?assertEqual(?EMPTY, muse_page_diff:diff_page(Before, Before)).

price_stock_count_version_updates_test_() ->
    [?_assertEqual(#{added => [], updated => [After], removed => []},
                   muse_page_diff:diff_page([<<"Shop">>, Before], [<<"Shop">>, After]))
     || {Before, After} <- [{<<"Price: $399.99">>, <<"Price: $279.99">>},
                            {<<"Only 3 left">>, <<"Only 0 left">>},
                            {<<"Tickets available: 12">>, <<"Tickets available: 0">>},
                            {<<"Latest release 1.2.3">>, <<"Latest release 2.0.0">>},
                            {<<"1 comment">>, <<"2 comments">>}]].

removed_numbered_line_test() ->
    ?assertEqual(#{added => [], updated => [], removed => [<<"Listing 101 \x{b7} 2 bed"/utf8>>]},
                 muse_page_diff:diff_page([<<"Listing 101 \x{b7} 2 bed"/utf8>>,
                                           <<"Listing 102 \x{b7} 2 bed"/utf8>>],
                                          [<<"Listing 102 \x{b7} 2 bed"/utf8>>])),
    ?assertEqual(#{added => [], updated => [<<"2. Cherry">>], removed => [<<"2. Banana">>]},
                 muse_page_diff:diff_page([<<"1. Apple">>, <<"2. Banana">>, <<"3. Cherry">>],
                                          [<<"1. Apple">>, <<"2. Cherry">>])).

summary_and_count_test() ->
    Diff = #{added => [<<"Role ", (integer_to_binary(I))/binary>> || I <- lists:seq(0, 9)],
             updated => [<<"Price $12">>], removed => []},
    Text = muse_page_diff:describe_page_diff(Diff),
    ?assertMatch({match, _}, re:run(Text, <<"^New:\n\x{2022} Role 0\n"/utf8>>, [unicode])),
    ?assertMatch({match, _}, re:run(Text, <<"\\+2 more\nUpdated:\n\x{2022} Price \\$12$"/utf8>>,
                                    [unicode])),
    ?assertEqual(nomatch, re:run(Text, <<"Removed">>)),
    ?assertEqual(<<"11 lines changed (10 new, 1 updated)">>, muse_page_diff:count_page_diff(Diff)),
    ?assertEqual(<<"1 line changed (1 new)">>,
                 muse_page_diff:count_page_diff(#{added => [<<"a">>], updated => [], removed => []})),
    ?assertEqual(<<>>, muse_page_diff:describe_page_diff(?EMPTY)),
    ?assertEqual(<<>>, muse_page_diff:count_page_diff(?EMPTY)).

only_relative_time_changed_test() ->
    Before = [<<"3 points by ada 58 minutes ago | hide">>,
              <<"Vor 2 Stunden ver\x{f6}ffentlicht"/utf8>>, <<"Show HN: A new tool">>],
    After = [<<"3 points by ada 1 hour ago | hide">>,
             <<"Vor einer Stunde ver\x{f6}ffentlicht"/utf8>>, <<"Show HN: A new tool">>],
    ?assertEqual(?EMPTY, muse_page_diff:diff_page(Before, After)),
    ?assertEqual(#{added => [], updated => [<<"4 points by ada 1 hour ago | hide">>], removed => []},
                 muse_page_diff:diff_page(Before, [<<"4 points by ada 1 hour ago | hide">>
                                                   | tl(After)])).

only_relative_times_blanked_test() ->
    Page = fun(Time, Price) ->
                   muse_page_diff:without_relative_times(
                     <<"Posted ", Time/binary, " \x{b7} Price "/utf8, Price/binary>>)
           end,
    ?assertEqual(Page(<<"58 minutes ago">>, <<"$399">>), Page(<<"1 hour ago">>, <<"$399">>)),
    ?assertNotEqual(Page(<<"1 hour ago">>, <<"$399">>), Page(<<"1 hour ago">>, <<"$279">>)).

conditions_test() ->
    Text = muse_page_diff:collapse_text(<<"  No tables\n\n available.\t">>),
    ?assertEqual(<<"No tables available.">>, Text),
    ?assert(muse_page_diff:matches_contains(Text, <<"TABLES AVAILABLE">>)),
    ?assert(muse_page_diff:matches_contains(Text, <<>>)),
    ?assertNot(muse_page_diff:matches_contains(Text, <<"booked">>)),
    ?assert(muse_page_diff:matches_price(<<"Now $1,299.99">>, 1300)),
    ?assert(muse_page_diff:matches_price(<<"Now USD 12">>, <<"12.5">>)),
    ?assertNot(muse_page_diff:matches_price(<<"Now $1,299.99">>, <<"1299.99">>)),
    ?assertNot(muse_page_diff:matches_price(<<"Now $5">>, <<"abc">>)),
    ?assertNot(muse_page_diff:matches_price(<<"No price">>, 100)).

slice_test() ->
    ?assertEqual(<<"ab">>, muse_page_diff:slice(<<"abc">>, 2)),
    ?assertEqual(<<"\x{e9}\x{e9}"/utf8>>, muse_page_diff:slice(<<"\x{e9}\x{e9}\x{e9}"/utf8>>, 2)),
    ?assertEqual(<<"a\x{1F642}"/utf8>>, muse_page_diff:slice(<<"a\x{1F642}b"/utf8>>, 3)),
    ?assertEqual(<<"a">>, muse_page_diff:slice(<<"a\x{1F642}b"/utf8>>, 2)),
    ?assertEqual(<<"abc">>, muse_page_diff:slice(<<"abc">>, 10)).
