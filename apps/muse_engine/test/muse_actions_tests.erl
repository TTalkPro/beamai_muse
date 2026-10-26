%% The review machinery with the test-only kind `test.note`
%% (muse_test_action_kind); production registers no kinds yet.
-module(muse_actions_tests).
-include_lib("eunit/include/eunit.hrl").

-define(NOTE, #{<<"kind">> => <<"test.note">>, <<"data">> => #{<<"text">> => <<"Visit">>}}).
-define(KIND, muse_test_action_kind).

actions_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     {foreach, fun each/0, fun after_each/1,
      [{"approve and idempotent re-approve", fun approve/0},
       {"deny never executes", fun deny/0},
       {"wrong owner and stale hash", fun owner_and_hash/0},
       {"expired review", fun expired/0},
       {"unregistered kind", fun unregistered/0},
       {"outcome_unknown is never retried", fun outcome_unknown/0},
       {"provider failure", fun failed/0},
       {"recover after restart", fun recover/0},
       {"idempotent replay", fun replay/0},
       {"concurrent idempotent proposals", fun concurrent_propose/0},
       {"concurrent approvals execute once", fun concurrent_approve/0},
       {"task must be runnable", fun task_gate/0},
       {"task cancelled after claim rolls back", fun cancel_race/0},
       {"review binds target version", fun target_review/0},
       {"hash is JSON.stringify of input, target and version", fun hash_vectors/0},
       {"display and tools", fun display/0},
       {"worker tick helpers", fun worker_helpers/0},
       {"reject pending on task cancel", fun reject_pending/0},
       {"validation and file ownership", fun validation/0}]}}.

setup() ->
    Dir = "/tmp/muse_actions_" ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, Config} = muse_config:from_env(#{<<"DATA_DIR">> => list_to_binary(Dir),
                                          <<"WORKSPACE_MODE">> => <<"sample">>}),
    muse_config:set(Config),
    ok = muse_store:init(#{storage => ram}),
    Dir.

cleanup(Dir) ->
    muse_store:stop(),
    os:cmd("rm -rf " ++ Dir).

each() ->
    ok = ?KIND:register(),
    meck:new(?KIND, [passthrough]).

after_each(_) ->
    muse_time:set_offset(0),
    meck:unload(?KIND),
    persistent_term:erase({?KIND, target}),
    ok = ?KIND:unregister().

owner() ->
    <<"user-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

activity(Owner) ->
    muse_store:list(Owner, <<"activity">>).

calls(F) ->
    meck:num_calls(?KIND, F, '_').

executes(Fun) ->
    meck:expect(?KIND, execute, Fun).

approve() ->
    O = owner(),
    {ok, P} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    #{<<"id">> := Id, <<"hash">> := Hash, <<"createdAt">> := C, <<"expiresAt">> := E} = P,
    ?assertMatch(#{<<"status">> := <<"awaiting_review">>, <<"title">> := <<"Write “Visit”"/utf8>>,
                   <<"kind">> := <<"test.note">>, <<"data">> := #{<<"text">> := <<"Visit">>, <<"fileIds">> := []}}, P),
    [?assertNot(maps:is_key(K, P)) || K <- [<<"taskId">>, <<"target">>, <<"account">>, <<"connectionId">>]],
    ?assertEqual(30 * 60 * 1000, muse_time:parse(E) - muse_time:parse(C)),
    ?assertMatch([#{<<"detail">> := <<"Ready for your review">>, <<"actionId">> := Id,
                    <<"status">> := <<"awaiting_review">>}], activity(O)),
    {ok, Done} = muse_actions:decide(O, Id, Hash, approve),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"result">> := <<"Saved note · "/utf8, _/binary>>}, Done),
    ?assertEqual(Done, muse_actions:get(O, Id)),
    ?assertEqual({ok, Done}, muse_actions:decide(O, Id, Hash, approve)),
    ?assertEqual({ok, Done}, muse_actions:decide(O, Id, Hash, deny)),
    ?assertEqual(1, calls(execute)),
    ?assertEqual([<<"Approved; execution started">>, <<"Ready for your review">>, maps:get(<<"result">>, Done)],
                 lists:sort([D || #{<<"detail">> := D} <- activity(O)])),
    ?assertMatch([#{<<"text">> := <<"Visit">>}], muse_store:list(O, <<"test-notes">>)).

deny() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    {ok, Denied} = muse_actions:decide(O, Id, H, deny),
    ?assertMatch(#{<<"status">> := <<"denied">>}, Denied),
    ?assertEqual(0, calls(execute)),
    ?assertMatch([#{<<"detail">> := <<"Declined; no changes made">>, <<"status">> := <<"denied">>}, _],
                 activity(O)),
    ?assertEqual({ok, Denied}, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(0, calls(execute)).

owner_and_hash() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    ?assertEqual({error, {404, <<"Action not found">>}}, muse_actions:decide(<<"attacker">>, Id, H, approve)),
    ?assertEqual({error, {409, <<"This proposal changed. Open its latest review before deciding.">>}},
                 muse_actions:decide(O, Id, <<"stale">>, approve)),
    ?assertEqual(0, calls(execute)).

expired() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    {ok, #{<<"id">> := Id2, <<"hash">> := H2}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    muse_time:set_offset(31 * 60 * 1000),
    Expired = {error, {409, <<"This review expired. Create a fresh proposal.">>}},
    ?assertEqual(Expired, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(Expired, muse_actions:decide(O, Id2, H2, deny)),
    {ok, Rec} = muse_actions:decide(O, Id, H, approve),
    ?assertMatch(#{<<"status">> := <<"expired">>}, Rec),
    ?assertEqual(2, length(activity(O))),
    ?assertEqual(0, calls(execute)).

%% A proposal whose kind is no longer registered (e.g. an email.send left
%% from before mail was removed) can be denied but not approved; new
%% proposals of that kind are invalid.
unregistered() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    ok = ?KIND:unregister(),
    ?assertEqual(#{}, muse_actions:kinds()),
    ?assertEqual({error, {409, <<"This kind of action is not available on this server. Prepare a new action.">>}},
                 muse_actions:decide(O, Id, H, approve)),
    ?assertMatch({error, {422, <<"Invalid input: expected kind to be one of ", _/binary>>}},
                 muse_actions:propose(O, ?NOTE, undefined, undefined)),
    ?assertMatch({ok, #{<<"status">> := <<"denied">>}}, muse_actions:decide(O, Id, H, deny)),
    ?assertEqual(0, calls(execute)).

outcome_unknown() ->
    O = owner(),
    executes(fun(_, _, _) -> {error, {outcome_unknown, <<"Provider response lost">>}} end),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    {ok, R} = muse_actions:decide(O, Id, H, approve),
    ?assertMatch(#{<<"status">> := <<"outcome_unknown">>, <<"error">> := <<"Provider response lost">>}, R),
    ?assertEqual({ok, R}, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(1, calls(execute)),
    ?assertMatch([#{<<"detail">> := <<"Provider response lost">>, <<"status">> := <<"outcome_unknown">>} | _],
                 activity(O)).

failed() ->
    O = owner(),
    executes(fun(_, _, _) -> {error, {502, <<"Provider (500): boom">>}} end),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    ?assertMatch({ok, #{<<"status">> := <<"failed">>, <<"error">> := <<"Provider (500): boom">>}},
                 muse_actions:decide(O, Id, H, approve)),
    O2 = owner(),
    executes(fun(_, _, _) -> error(crash) end),
    {ok, #{<<"id">> := Id2, <<"hash">> := H2}} = muse_actions:propose(O2, ?NOTE, undefined, undefined),
    ?assertMatch({ok, #{<<"status">> := <<"failed">>, <<"error">> := <<"Execution failed">>}},
                 muse_actions:decide(O2, Id2, H2, approve)).

recover() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    %% a restart while executing
    #{} = muse_store:cas(O, <<"actions">>, Id, #{}, #{<<"status">> => <<"executing">>}),
    ?assert(muse_store:recover_interrupted_actions() >= 1),
    {ok, R} = muse_actions:decide(O, Id, H, approve),
    ?assertMatch(#{<<"status">> := <<"outcome_unknown">>,
                   <<"error">> := <<"Server restarted during execution. Check the provider before creating another action.">>}, R),
    ?assertEqual(0, calls(execute)).

replay() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H} = P} = muse_actions:propose(O, ?NOTE, <<"run/tool-1">>, undefined),
    ?assertEqual(muse_ids:sha256hex(<<"run/tool-1">>), Id),
    {ok, _} = muse_actions:decide(O, Id, H, approve),
    {ok, Replay} = muse_actions:propose(O, ?NOTE, <<"run/tool-1">>, undefined),
    ?assertMatch(#{<<"id">> := Id, <<"status">> := <<"succeeded">>}, Replay),
    ?assertEqual(maps:get(<<"createdAt">>, P), maps:get(<<"createdAt">>, Replay)),
    ?assertEqual(1, calls(prepare)),
    {ok, Other} = muse_actions:propose(owner(), ?NOTE, <<"run/tool-1">>, undefined),
    ?assertMatch(#{<<"id">> := Id, <<"status">> := <<"awaiting_review">>}, Other).

concurrent_propose() ->
    O = owner(),
    Self = self(),
    [spawn(fun() -> Self ! {done, muse_actions:propose(O, ?NOTE, <<"run/tool-1">>, undefined)} end)
     || _ <- [1, 2]],
    [R1, R2] = [receive {done, R} -> R after 5000 -> timeout end || _ <- [1, 2]],
    ?assertMatch({ok, _}, R1),
    ?assertEqual(R1, R2),
    ?assertEqual(1, length(muse_store:list(O, <<"actions">>))),
    ?assertEqual(1, length(activity(O))).

concurrent_approve() ->
    O = owner(),
    executes(fun(_, _, _) -> timer:sleep(100), {ok, <<"provider-receipt">>} end),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    Self = self(),
    [spawn(fun() -> Self ! {done, muse_actions:decide(O, Id, H, approve)} end) || _ <- [1, 2]],
    Results = [receive {done, R} -> R after 5000 -> timeout end || _ <- [1, 2]],
    ?assertEqual(1, calls(execute)),
    ?assert(lists:member({ok, muse_actions:get(O, Id)}, Results)),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"result">> := <<"provider-receipt">>},
                 muse_actions:get(O, Id)).

task_gate() ->
    O = owner(),
    Resume = {error, {409, <<"Resume the task before approving this action. Cancelled tasks cannot execute.">>}},
    {ok, #{<<"id">> := Id, <<"hash">> := H, <<"taskId">> := <<"task-1">>}} =
        muse_actions:propose(O, ?NOTE, undefined, <<"task-1">>),
    ?assertEqual(Resume, muse_actions:decide(O, Id, H, approve)),
    _ = muse_store:put(O, <<"tasks">>, #{<<"id">> => <<"task-1">>, <<"status">> => <<"cancelled">>}),
    ?assertEqual(Resume, muse_actions:decide(O, Id, H, approve)),
    _ = muse_store:put(O, <<"tasks">>, #{<<"id">> => <<"task-1">>, <<"status">> => <<"running">>}),
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>}}, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(1, calls(execute)),
    %% deny does not need a runnable task
    {ok, #{<<"id">> := Id2, <<"hash">> := H2}} = muse_actions:propose(O, ?NOTE, undefined, <<"gone">>),
    ?assertMatch({ok, #{<<"status">> := <<"denied">>}}, muse_actions:decide(O, Id2, H2, deny)).

cancel_race() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?NOTE, undefined, <<"task-1">>),
    _ = muse_store:put(O, <<"tasks">>, #{<<"id">> => <<"task-1">>, <<"status">> => <<"running">>}),
    meck:new(muse_store, [passthrough]),
    try
        meck:expect(muse_store, update,
                    fun(Owner, <<"actions">> = K, I, Fun) ->
                            R = meck:passthrough([Owner, K, I, Fun]),
                            _ = muse_store:cas(Owner, <<"tasks">>, <<"task-1">>,
                                               #{<<"status">> => <<"running">>},
                                               #{<<"status">> => <<"cancelled">>}),
                            R;
                       (Owner, K, I, Fun) ->
                            meck:passthrough([Owner, K, I, Fun])
                    end),
        ?assertEqual({error, {409, <<"Resume the task before approving this action. Cancelled tasks cannot execute.">>}},
                     muse_actions:decide(O, Id, H, approve))
    after
        meck:unload(muse_store)
    end,
    ?assertEqual(0, calls(execute)),
    ?assertMatch(#{<<"status">> := <<"awaiting_review">>}, muse_actions:get(O, Id)).

target_review() ->
    O = owner(),
    Target = #{<<"id">> => <<"t-1">>, <<"text">> => <<"Provider text">>},
    persistent_term:put({?KIND, target}, #{target => Target, version => <<"\"revision-1\"">>}),
    executes(fun(_, #{<<"text">> := <<"Provider text">>},
                 #{target := #{<<"id">> := <<"t-1">>}, target_version := <<"\"revision-1\"">>}) ->
                     {ok, <<"Written">>}
             end),
    Input = #{<<"kind">> => <<"test.note">>,
              <<"data">> => #{<<"text">> => <<"Untrusted text">>, <<"targetId">> => <<"t-1">>}},
    {ok, P} = muse_actions:propose(O, Input, undefined, undefined),
    ?assertMatch(#{<<"title">> := <<"Write “Provider text”"/utf8>>, <<"target">> := Target,
                   <<"targetVersion">> := <<"\"revision-1\"">>}, P),
    persistent_term:put({?KIND, target}, #{target => Target, version => <<"\"revision-2\"">>}),
    {ok, Newer} = muse_actions:propose(O, Input, undefined, undefined),
    ?assertNotEqual(maps:get(<<"hash">>, P), maps:get(<<"hash">>, Newer)),
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>, <<"result">> := <<"Written">>}},
                 muse_actions:decide(O, maps:get(<<"id">>, P), maps:get(<<"hash">>, P), approve)).

%% Expected values: sha256 of Node-style JSON.stringify({input, target,
%% targetVersion}) with the parsed input in schema order and the target's
%% keys sorted (undefined members dropped).
hash_vectors() ->
    O = owner(),
    {ok, #{<<"hash">> := H1}} =
        muse_actions:propose(O, #{<<"kind">> => <<"test.note">>,
                                  <<"data">> => #{<<"text">> => <<"  Visit 你好 "/utf8>>, <<"extra">> => 1}},
                             undefined, undefined),
    ?assertEqual(<<"56fb9fd084805e2579df16fcd31b987b2e03c37c65a28edc1d64ce568307841e">>, H1),
    persistent_term:put({?KIND, target},
                        #{target => #{<<"when">> => <<"2026-10-23">>, <<"text">> => <<"Provider “title”"/utf8>>,
                                      <<"id">> => <<"t-9">>},
                          version => <<"\"rev-1\"">>}),
    {ok, #{<<"hash">> := H2}} =
        muse_actions:propose(O, #{<<"kind">> => <<"test.note">>,
                                  <<"data">> => #{<<"targetId">> => <<"t-9">>, <<"text">> => <<"x">>}},
                             undefined, undefined),
    ?assertEqual(<<"f5365478303f8ead1aaf03000cd77a2f7bb59da25d5c06918a2189357bc40222">>, H2).

display() ->
    O = owner(),
    {ok, P} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    ?assertEqual(#{title => <<"Write “Visit”"/utf8>>, fields => [{<<"内容"/utf8>>, <<"Visit">>}, {<<"附件"/utf8>>, <<>>}]},
                 muse_actions:display(P)),
    ?assertMatch([#{kind := <<"test.note">>, name := <<"prepare_note">>, schema := {object, _}}], muse_actions:tools()),
    %% a stored proposal of an unknown kind shows its title and scalar data
    Old = #{<<"kind">> => <<"email.send">>, <<"title">> => <<"Send “Visit”"/utf8>>,
            <<"data">> => #{<<"to">> => [<<"sam@example.com">>], <<"subject">> => <<"Visit">>, <<"n">> => 2}},
    ?assertEqual(#{title => <<"Send “Visit”"/utf8>>,
                   fields => [{<<"n">>, <<"2">>}, {<<"subject">>, <<"Visit">>}, {<<"to">>, <<"sam@example.com">>}]},
                 muse_actions:display(Old)).

worker_helpers() ->
    O = owner(),
    ?assertNot(muse_actions:awaits_review(O, undefined)),
    ?assertNot(muse_actions:awaits_review(O, <<"missing">>)),
    {ok, #{<<"id">> := Id} = P} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    ?assert(muse_actions:awaits_review(O, Id)),
    ?assertNot(muse_actions:expire_if_due(O, P)),
    #{} = muse_store:cas(O, <<"actions">>, Id, #{}, #{<<"status">> => <<"executing">>}),
    ?assert(muse_actions:awaits_review(O, Id)),
    #{} = muse_store:cas(O, <<"actions">>, Id, #{}, #{<<"status">> => <<"awaiting_review">>}),
    muse_time:set_offset(30 * 60 * 1000 + 1000),
    ?assertNot(muse_actions:awaits_review(O, Id)),
    ?assertMatch(#{<<"status">> := <<"expired">>}, muse_actions:get(O, Id)),
    ?assertNot(muse_actions:awaits_review(O, Id)),
    ?assertEqual(1, length(activity(O))).

reject_pending() ->
    O = owner(),
    ?assertEqual(ok, muse_actions:reject_pending(O, undefined)),
    ?assertEqual(ok, muse_actions:reject_pending(O, <<"missing">>)),
    {ok, #{<<"id">> := Id}} = muse_actions:propose(O, ?NOTE, undefined, <<"task-x">>),
    ?assertEqual(ok, muse_actions:reject_pending(O, Id)),
    ?assertMatch(#{<<"status">> := <<"denied">>}, muse_actions:get(O, Id)),
    ?assertEqual(ok, muse_actions:reject_pending(O, Id)),
    {ok, #{<<"id">> := Id2}} = muse_actions:propose(O, ?NOTE, undefined, undefined),
    muse_time:set_offset(31 * 60 * 1000),
    ?assertEqual({error, {409, <<"This review expired. Create a fresh proposal.">>}},
                 muse_actions:reject_pending(O, Id2)),
    ?assertEqual(0, calls(execute)).

validation() ->
    O = owner(),
    ?assertMatch({error, {422, _}}, muse_actions:propose(O, #{<<"kind">> => <<"nope">>}, undefined, undefined)),
    ?assertMatch({error, {422, _}},
                 muse_actions:propose(O, #{<<"kind">> => <<"test.note">>, <<"data">> => #{<<"text">> => <<"  ">>}},
                                      undefined, undefined)),
    ?assertMatch({error, {404, _}},
                 muse_actions:propose(O, #{<<"kind">> => <<"test.note">>,
                                           <<"data">> => #{<<"text">> => <<"x">>, <<"fileIds">> => [muse_ids:uuid()]}},
                                      undefined, undefined)),
    ?assertEqual([], muse_store:list(O, <<"actions">>)),
    ?assertEqual(1, calls(prepare)).
