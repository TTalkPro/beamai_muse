-module(muse_workspace_tests).
-include_lib("eunit/include/eunit.hrl").

-define(O, <<"local-user">>).

workspace_test_() ->
    {setup,
     fun() ->
         Env = muse_integ_test_env:start(#{}),
         ok = muse_workspace:ensure_sample(?O),
         Env
     end,
     fun muse_integ_test_env:stop/1,
     [fun seeded/0, fun seed_once/0, fun snapshot_shape/0, fun sections/0]}.

seeded() ->
    [#{<<"name">> := <<"Field trip permission slip.pdf">>, <<"fields">> := [_ | _]} = File] =
        muse_store:list(?O, <<"files">>),
    ?assertNot(maps:is_key(<<"parentId">>, File)),
    ?assertEqual([], muse_store:list(?O, <<"actions">>)),
    [?assertEqual([], muse_store:list(?O, C)) || C <- [<<"mail">>, <<"events">>, <<"drafts">>]].

seed_once() ->
    ok = muse_workspace:ensure_sample(?O),
    ?assertEqual(1, length(muse_store:list(?O, <<"files">>))).

snapshot_shape() ->
    {ok, S} = muse_workspace:snapshot(?O),
    ?assertMatch(#{<<"mode">> := <<"sample">>,
                   <<"profile">> := #{<<"name">> := <<"Alex">>, <<"email">> := <<>>},
                   <<"files">> := [#{<<"url">> := <<_, _/binary>>}],
                   <<"actions">> := [],
                   <<"runtime">> := #{<<"provider">> := <<"sample">>, <<"configured">> := true,
                                      <<"openbotConfigured">> := false, <<"richThreads">> := true}}, S),
    ?assertNot(maps:is_key(<<"mail">>, S)),
    ?assertNot(maps:is_key(<<"events">>, S)),
    [Browser, Openbot] = maps:get(<<"connections">>, S),
    ?assertMatch(#{<<"id">> := <<"browser">>, <<"status">> := <<"unconfigured">>}, Browser),
    ?assertMatch(#{<<"id">> := <<"openbot">>}, Openbot).

sections() ->
    {ok, A} = muse_workspace:section_snapshot(?O, <<"all">>),
    ?assertEqual([<<"files">>], maps:keys(A)),
    [F] = maps:get(<<"files">>, A),
    ?assertNot(maps:is_key(<<"url">>, F)),
    ?assertEqual({ok, A}, muse_workspace:section_snapshot(?O, <<"files">>)).
