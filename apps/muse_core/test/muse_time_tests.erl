-module(muse_time_tests).
-include_lib("eunit/include/eunit.hrl").

iso_format_test() ->
    ?assertEqual(<<"2026-10-21T09:00:00.000Z">>, muse_time:to_iso(1792573200000)),
    ?assertEqual(<<"1970-01-01T00:00:00.007Z">>, muse_time:to_iso(7)).

parse_test_() ->
    [?_assertEqual(1792573200000, muse_time:parse(<<"2026-10-21T09:00:00.000Z">>)),
     ?_assertEqual(1792573200000, muse_time:parse(<<"2026-10-21T09:00:00Z">>)),
     %% Node: Date.parse("2026-10-21T09:00:00+08:00") -> 2026-10-21T01:00:00.000Z
     ?_assertEqual(muse_time:parse(<<"2026-10-21T01:00:00.000Z">>),
                   muse_time:parse(<<"2026-10-21T09:00:00+08:00">>)),
     ?_assertEqual(1792540800000, muse_time:parse(<<"2026-10-21">>)),
     ?_assertEqual(1792573200120, muse_time:parse(<<"2026-10-21T09:00:00.12Z">>)),
     ?_assertEqual(1792573200000, muse_time:parse(<<"2026-10-21T09:00Z">>)),
     ?_assertEqual(nan, muse_time:parse(<<"2026-02-30">>)),
     ?_assertEqual(nan, muse_time:parse(<<"tomorrow">>)),
     ?_assertEqual(nan, muse_time:parse(undefined)),
     ?_assertEqual(nan, muse_time:parse(null)),
     ?_assertEqual(nan, muse_time:parse(<<"2026-10-21T25:00:00Z">>))].

roundtrip_test() ->
    Now = muse_time:now_ms(),
    ?assertEqual(Now, muse_time:parse(muse_time:to_iso(Now))).

due_test() ->
    ?assert(muse_time:is_due(<<"2026-10-21T09:00:00.000Z">>, 1792573200000)),
    ?assertNot(muse_time:is_due(<<"2026-10-21T09:00:00.001Z">>, 1792573200000)),
    ?assertNot(muse_time:is_due(undefined, 1792573200000)).

offset_test() ->
    Before = muse_time:now_ms(),
    ok = muse_time:set_offset(3600000),
    try
        ?assert(muse_time:now_ms() >= Before + 3600000)
    after
        muse_time:set_offset(0)
    end,
    ?assertEqual(0, muse_time:offset()).
