-module(muse_store_tests).
-include_lib("eunit/include/eunit.hrl").

-define(O, <<"local-user">>).

contains_test_() ->
    C = fun muse_store:contains/2,
    Task = #{<<"status">> => <<"running">>, <<"leaseId">> => null, <<"n">> => 1,
             <<"state">> => #{<<"resumingMonitor">> => true, <<"x">> => 1},
             <<"tags">> => [<<"a">>, <<"b">>], <<"ms">> => [#{<<"id">> => 1, <<"done">> => false}]},
    [?_assert(C(Task, #{})),
     ?_assert(C(Task, #{<<"status">> => <<"running">>})),
     ?_assertNot(C(Task, #{<<"status">> => <<"queued">>})),
     ?_assert(C(Task, #{<<"leaseId">> => null})),
     ?_assertNot(C(Task, #{<<"missing">> => null})),
     ?_assertNot(C(Task, #{<<"leaseId">> => <<"x">>})),
     ?_assert(C(Task, #{<<"state">> => #{<<"resumingMonitor">> => true}})),
     ?_assertNot(C(Task, #{<<"state">> => #{<<"resumingMonitor">> => false}})),
     ?_assert(C(Task, #{<<"state">> => #{}})),
     ?_assertNot(C(Task, #{<<"state">> => true})),
     ?_assert(C(Task, #{<<"n">> => 1.0})),
     ?_assertNot(C(Task, #{<<"n">> => <<"1">>})),
     ?_assert(C(Task, #{<<"tags">> => [<<"b">>]})),
     ?_assert(C(Task, #{<<"tags">> => [<<"b">>, <<"a">>]})),
     ?_assert(C(Task, #{<<"tags">> => []})),
     ?_assertNot(C(Task, #{<<"tags">> => [<<"c">>]})),
     ?_assert(C(Task, #{<<"ms">> => [#{<<"id">> => 1}]})),
     ?_assertNot(C(Task, #{<<"ms">> => [#{<<"id">> => 2}]})),
     ?_assertNot(C(Task, #{<<"tags">> => <<"a">>})),
     ?_assert(C(null, null)),
     ?_assert(C(true, true)),
     ?_assertNot(C(true, false)),
     ?_assertNot(C(#{}, #{<<"a">> => 1})),
     ?_assert(C([1, 2, 3], [3, 1])),
     ?_assertNot(C([1, 2], [[1]]))].

store_test_() ->
    {setup,
     fun() -> ok = muse_store:init(#{storage => ram}) end,
     fun(_) -> muse_store:stop() end,
     [fun put_get_list/0, fun insert_if_absent/0, fun take/0, fun cas_semantics/0,
      fun cas_concurrency/0, fun scan_and_indexes/0, fun update_abort/0,
      fun recover_actions/0]}.

put_get_list() ->
    K = <<"t1">>,
    muse_store:put(?O, K, #{<<"id">> => <<"a">>, <<"v">> => 1}),
    muse_store:put(?O, K, #{<<"id">> => <<"b">>, <<"v">> => 2}),
    ?assertEqual(#{<<"id">> => <<"a">>, <<"v">> => 1}, muse_store:get(?O, K, <<"a">>)),
    ?assertEqual(undefined, muse_store:get(?O, K, <<"zz">>)),
    ?assertEqual([<<"b">>, <<"a">>], ids(muse_store:list(?O, K))),
    muse_store:put(?O, K, #{<<"id">> => <<"a">>, <<"v">> => 3}),
    ?assertEqual([<<"a">>, <<"b">>], ids(muse_store:list(?O, K))),
    ?assertEqual([], muse_store:list(<<"other">>, K)),
    ok = muse_store:remove(?O, K, <<"a">>),
    ?assertEqual([<<"b">>], ids(muse_store:list(?O, K))).

insert_if_absent() ->
    V = #{<<"id">> => <<"x">>, <<"n">> => 1},
    ?assertEqual(V, muse_store:insert_if_absent(?O, <<"t2">>, V)),
    ?assertEqual(undefined, muse_store:insert_if_absent(?O, <<"t2">>, V#{<<"n">> => 2})),
    ?assertEqual(V, muse_store:get(?O, <<"t2">>, <<"x">>)).

take() ->
    muse_store:put(?O, <<"t3">>, #{<<"id">> => <<"s">>}),
    ?assertEqual(#{<<"id">> => <<"s">>}, muse_store:take(?O, <<"t3">>, <<"s">>)),
    ?assertEqual(undefined, muse_store:take(?O, <<"t3">>, <<"s">>)).

cas_semantics() ->
    muse_store:put(?O, <<"tasks">>, #{<<"id">> => <<"c">>, <<"status">> => <<"queued">>,
                                      <<"leaseId">> => null, <<"state">> => #{<<"a">> => 1}}),
    ?assertEqual(undefined, muse_store:cas(?O, <<"tasks">>, <<"c">>, #{<<"status">> => <<"running">>},
                                           #{<<"x">> => 1})),
    New = muse_store:cas(?O, <<"tasks">>, <<"c">>, #{<<"status">> => <<"queued">>, <<"leaseId">> => null},
                         #{<<"status">> => <<"running">>, <<"leaseId">> => <<"L">>,
                           <<"state">> => #{<<"b">> => 2}, <<"error">> => null}),
    %% shallow merge: state replaced wholesale, null stored (not deleted)
    ?assertEqual(#{<<"id">> => <<"c">>, <<"status">> => <<"running">>, <<"leaseId">> => <<"L">>,
                   <<"state">> => #{<<"b">> => 2}, <<"error">> => null}, New),
    ?assertEqual(undefined, muse_store:cas(?O, <<"tasks">>, <<"missing">>, #{}, #{<<"a">> => 1})),
    ?assertMatch(#{<<"z">> := 1}, muse_store:cas(?O, <<"tasks">>, <<"c">>, #{}, #{<<"z">> => 1})).

cas_concurrency() ->
    muse_store:put(?O, <<"tasks">>, #{<<"id">> => <<"race">>, <<"leaseId">> => null}),
    Self = self(),
    Pids = [spawn(fun() ->
                      R = muse_store:cas(?O, <<"tasks">>, <<"race">>, #{<<"leaseId">> => null},
                                         #{<<"leaseId">> => integer_to_binary(N)}),
                      Self ! {done, R =/= undefined}
                  end) || N <- lists:seq(1, 50)],
    Wins = [receive {done, W} -> W end || _ <- Pids],
    ?assertEqual(1, length([W || W <- Wins, W])).

scan_and_indexes() ->
    K = <<"scan-kind">>,
    muse_store:put(<<"u1">>, K, #{<<"id">> => <<"1">>, <<"status">> => <<"queued">>, <<"goalId">> => <<"g">>}),
    muse_store:put(<<"u2">>, K, #{<<"id">> => <<"2">>, <<"status">> => <<"running">>}),
    muse_store:put(<<"u1">>, K, #{<<"id">> => <<"3">>, <<"status">> => <<"queued">>}),
    ?assertEqual([{<<"u1">>, <<"1">>}, {<<"u2">>, <<"2">>}, {<<"u1">>, <<"3">>}],
                 [{O, Id} || {O, #{<<"id">> := Id}} <- muse_store:scan(K)]),
    ?assertEqual([<<"3">>, <<"1">>], ids(muse_store:list_by_status(<<"u1">>, K, <<"queued">>))),
    ?assertEqual([<<"1">>], ids(muse_store:list_by_goal(<<"u1">>, K, <<"g">>))),
    %% projections follow the data
    muse_store:cas(<<"u1">>, K, <<"1">>, #{}, #{<<"status">> => <<"running">>}),
    ?assertEqual([<<"3">>], ids(muse_store:list_by_status(<<"u1">>, K, <<"queued">>))).

update_abort() ->
    muse_store:put(?O, <<"t4">>, #{<<"id">> => <<"u">>, <<"n">> => 1}),
    ?assertEqual(undefined, muse_store:update(?O, <<"t4">>, <<"u">>, fun(_) -> abort end)),
    ?assertMatch(#{<<"n">> := 2},
                 muse_store:update(?O, <<"t4">>, <<"u">>, fun(D) -> {ok, D#{<<"n">> => 2}} end)).

recover_actions() ->
    muse_store:put(?O, <<"actions">>, #{<<"id">> => <<"a1">>, <<"status">> => <<"executing">>}),
    muse_store:put(?O, <<"actions">>, #{<<"id">> => <<"a2">>, <<"status">> => <<"succeeded">>}),
    muse_store:put(?O, <<"tasks">>, #{<<"id">> => <<"t">>, <<"status">> => <<"executing">>}),
    ?assertEqual(1, muse_store:recover_interrupted_actions()),
    ?assertMatch(#{<<"status">> := <<"outcome_unknown">>, <<"error">> := <<"Server restarted", _/binary>>},
                 muse_store:get(?O, <<"actions">>, <<"a1">>)),
    ?assertMatch(#{<<"status">> := <<"executing">>}, muse_store:get(?O, <<"tasks">>, <<"t">>)).

ids(Docs) -> [Id || #{<<"id">> := Id} <- Docs].
