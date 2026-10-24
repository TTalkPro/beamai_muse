-module(muse_actions_tests).
-include_lib("eunit/include/eunit.hrl").

-define(EMAIL, #{<<"kind">> => <<"email.send">>,
                 <<"data">> => #{<<"to">> => [<<"sam@example.com">>], <<"subject">> => <<"Visit">>,
                                 <<"body">> => <<"See attached.">>}}).
-define(WS, muse_workspace).

actions_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     {foreach, fun each/0, fun after_each/1,
      [{"sample approve and idempotent re-approve", fun sample_approve/0},
       {"deny never executes", fun deny/0},
       {"wrong owner and stale hash", fun owner_and_hash/0},
       {"expired review", fun expired/0},
       {"disconnected", fun disconnected/0},
       {"connection-bound invalidation", fun connection_changed/0},
       {"outcome_unknown is never retried", fun outcome_unknown/0},
       {"provider failure", fun failed/0},
       {"recover after restart", fun recover/0},
       {"idempotent replay", fun replay/0},
       {"concurrent idempotent proposals", fun concurrent_propose/0},
       {"concurrent approvals execute once", fun concurrent_approve/0},
       {"task must be runnable", fun task_gate/0},
       {"task cancelled after claim rolls back", fun cancel_race/0},
       {"calendar review binds target version", fun calendar_review/0},
       {"hash matches JSON.stringify of the original", fun node_vectors/0},
       {"worker tick helpers", fun worker_helpers/0},
       {"reject pending on task cancel", fun reject_pending/0},
       {"validation and attachment ownership", fun validation/0}]}}.

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
    meck:new(?WS, [passthrough]).

after_each(_) ->
    muse_time:set_offset(0),
    meck:unload(?WS).

owner() ->
    <<"user-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

activity(Owner) ->
    muse_store:list(Owner, <<"activity">>).

calls(F) ->
    meck:num_calls(?WS, F, '_').

live(Execute) ->
    meck:expect(?WS, connection, fun(_) -> #{id => <<"conn-a">>, account => <<"a@example.com">>} end),
    meck:expect(?WS, connected, fun(_) -> true end),
    meck:expect(?WS, prepare, fun(_, Input, _) -> {ok, #{input => Input}} end),
    meck:expect(?WS, execute, Execute).

sample_approve() ->
    O = owner(),
    {ok, P} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    #{<<"id">> := Id, <<"hash">> := Hash, <<"createdAt">> := C, <<"expiresAt">> := E} = P,
    ?assertMatch(#{<<"status">> := <<"awaiting_review">>, <<"title">> := <<"Send “Visit”"/utf8>>,
                   <<"kind">> := <<"email.send">>, <<"account">> := <<"alex@example.com">>,
                   <<"connectionId">> := <<"sample-google">>,
                   <<"data">> := #{<<"cc">> := [], <<"attachmentIds">> := []}}, P),
    ?assertNot(maps:is_key(<<"taskId">>, P)),
    ?assertNot(maps:is_key(<<"target">>, P)),
    ?assertEqual(30 * 60 * 1000, muse_time:parse(E) - muse_time:parse(C)),
    ?assertMatch([#{<<"detail">> := <<"Ready for your review">>, <<"actionId">> := Id,
                    <<"status">> := <<"awaiting_review">>}], activity(O)),
    {ok, Done} = muse_actions:decide(O, Id, Hash, approve),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"result">> := <<"Saved to local sent mail · "/utf8, _/binary>>}, Done),
    ?assertEqual(Done, muse_actions:get(O, Id)),
    ?assertEqual({ok, Done}, muse_actions:decide(O, Id, Hash, approve)),
    ?assertEqual({ok, Done}, muse_actions:decide(O, Id, Hash, deny)),
    ?assertEqual(1, calls(execute)),
    ?assertEqual([<<"Approved; execution started">>, <<"Ready for your review">>, maps:get(<<"result">>, Done)],
                 lists:sort([D || #{<<"detail">> := D} <- activity(O)])),
    [Sent] = [M || M = #{<<"label">> := <<"Sent · local"/utf8>>} <- muse_store:list(O, <<"mail">>)],
    ?assertMatch(#{<<"subject">> := <<"Visit">>}, Sent).

deny() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    {ok, Denied} = muse_actions:decide(O, Id, H, deny),
    ?assertMatch(#{<<"status">> := <<"denied">>}, Denied),
    ?assertEqual(0, calls(execute)),
    ?assertMatch([#{<<"detail">> := <<"Declined; no changes made">>, <<"status">> := <<"denied">>}, _],
                 activity(O)),
    ?assertEqual({ok, Denied}, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(0, calls(execute)).

owner_and_hash() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    ?assertEqual({error, {404, <<"Action not found">>}}, muse_actions:decide(<<"attacker">>, Id, H, approve)),
    ?assertEqual({error, {409, <<"This proposal changed. Open its latest review before deciding.">>}},
                 muse_actions:decide(O, Id, <<"stale">>, approve)),
    ?assertEqual(0, calls(execute)).

expired() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    {ok, #{<<"id">> := Id2, <<"hash">> := H2}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    muse_time:set_offset(31 * 60 * 1000),
    Expired = {error, {409, <<"This review expired. Create a fresh proposal.">>}},
    ?assertEqual(Expired, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(Expired, muse_actions:decide(O, Id2, H2, deny)),
    {ok, Rec} = muse_actions:decide(O, Id, H, approve),
    ?assertMatch(#{<<"status">> := <<"expired">>}, Rec),
    ?assertEqual(2, length(activity(O))),
    ?assertEqual(0, calls(execute)).

disconnected() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    _ = muse_store:put(O, <<"settings">>, #{<<"id">> => <<"google">>, <<"enabled">> => false}),
    ?assertEqual({error, {409, <<"Google is disconnected. Reconnect before approving this action.">>}},
                 muse_actions:decide(O, Id, H, approve)),
    ?assertEqual({error, {409, <<"Connect Google before preparing an action">>}},
                 muse_actions:propose(O, ?EMAIL, undefined, undefined)),
    %% denying still works while disconnected
    ?assertMatch({ok, #{<<"status">> := <<"denied">>}}, muse_actions:decide(O, Id, H, deny)),
    ?assertEqual(0, calls(execute)).

connection_changed() ->
    O = owner(),
    live(fun(_, _, _, _) -> {ok, <<"sent">>} end),
    {ok, #{<<"id">> := Id, <<"hash">> := H, <<"account">> := <<"a@example.com">>}} =
        muse_actions:propose(O, ?EMAIL, undefined, undefined),
    Changed = {error, {409, <<"Google account or connection changed. Prepare a new action for the connected account.">>}},
    meck:expect(?WS, connection, fun(_) -> #{id => <<"conn-b">>, account => <<"b@example.com">>} end),
    ?assertEqual(Changed, muse_actions:decide(O, Id, H, approve)),
    meck:expect(?WS, connection, fun(_) -> #{id => <<"conn-new-a">>, account => <<"a@example.com">>} end),
    ?assertEqual(Changed, muse_actions:decide(O, Id, H, approve)),
    meck:expect(?WS, connection, fun(_) -> #{id => <<"conn-a">>, account => <<"a@example.com">>} end),
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>, <<"result">> := <<"sent">>}},
                 muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(1, calls(execute)).

outcome_unknown() ->
    O = owner(),
    live(fun(_, _, _, _) -> {error, {outcome_unknown, <<"Provider response lost">>}} end),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    {ok, R} = muse_actions:decide(O, Id, H, approve),
    ?assertMatch(#{<<"status">> := <<"outcome_unknown">>, <<"error">> := <<"Provider response lost">>}, R),
    ?assertEqual({ok, R}, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(1, calls(execute)),
    ?assertMatch([#{<<"detail">> := <<"Provider response lost">>, <<"status">> := <<"outcome_unknown">>} | _],
                 activity(O)).

failed() ->
    O = owner(),
    live(fun(_, _, _, _) -> {error, {502, <<"Google API (500): boom">>}} end),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    ?assertMatch({ok, #{<<"status">> := <<"failed">>, <<"error">> := <<"Google API (500): boom">>}},
                 muse_actions:decide(O, Id, H, approve)),
    O2 = owner(),
    meck:expect(?WS, execute, fun(_, _, _, _) -> error(crash) end),
    {ok, #{<<"id">> := Id2, <<"hash">> := H2}} = muse_actions:propose(O2, ?EMAIL, undefined, undefined),
    ?assertMatch({ok, #{<<"status">> := <<"failed">>, <<"error">> := <<"Execution failed">>}},
                 muse_actions:decide(O2, Id2, H2, approve)).

recover() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    %% a restart while executing
    #{} = muse_store:cas(O, <<"actions">>, Id, #{}, #{<<"status">> => <<"executing">>}),
    ?assert(muse_store:recover_interrupted_actions() >= 1),
    {ok, R} = muse_actions:decide(O, Id, H, approve),
    ?assertMatch(#{<<"status">> := <<"outcome_unknown">>,
                   <<"error">> := <<"Server restarted during execution. Check the provider before creating another action.">>}, R),
    ?assertEqual(0, calls(execute)).

replay() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H} = P} = muse_actions:propose(O, ?EMAIL, <<"run/tool-1">>, undefined),
    ?assertEqual(muse_ids:sha256hex(<<"run/tool-1">>), Id),
    {ok, _} = muse_actions:decide(O, Id, H, approve),
    {ok, Replay} = muse_actions:propose(O, ?EMAIL, <<"run/tool-1">>, undefined),
    ?assertMatch(#{<<"id">> := Id, <<"status">> := <<"succeeded">>}, Replay),
    ?assertEqual(maps:get(<<"createdAt">>, P), maps:get(<<"createdAt">>, Replay)),
    ?assertEqual(1, calls(prepare)),
    {ok, Other} = muse_actions:propose(owner(), ?EMAIL, <<"run/tool-1">>, undefined),
    ?assertMatch(#{<<"id">> := Id, <<"status">> := <<"awaiting_review">>}, Other).

concurrent_propose() ->
    O = owner(),
    Self = self(),
    [spawn(fun() -> Self ! {done, muse_actions:propose(O, ?EMAIL, <<"run/tool-1">>, undefined)} end)
     || _ <- [1, 2]],
    [R1, R2] = [receive {done, R} -> R after 5000 -> timeout end || _ <- [1, 2]],
    ?assertMatch({ok, _}, R1),
    ?assertEqual(R1, R2),
    ?assertEqual(1, length(muse_store:list(O, <<"actions">>))),
    ?assertEqual(1, length(activity(O))).

concurrent_approve() ->
    O = owner(),
    live(fun(_, _, _, _) -> timer:sleep(100), {ok, <<"provider-receipt">>} end),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
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
        muse_actions:propose(O, ?EMAIL, undefined, <<"task-1">>),
    ?assertEqual(Resume, muse_actions:decide(O, Id, H, approve)),
    _ = muse_store:put(O, <<"tasks">>, #{<<"id">> => <<"task-1">>, <<"status">> => <<"cancelled">>}),
    ?assertEqual(Resume, muse_actions:decide(O, Id, H, approve)),
    %% the task is cancelled after the pre-checks but before the claim
    _ = muse_store:put(O, <<"tasks">>, #{<<"id">> => <<"task-1">>, <<"status">> => <<"waiting_approval">>}),
    meck:expect(?WS, connection,
                fun(Owner) ->
                        _ = muse_store:put(Owner, <<"tasks">>, #{<<"id">> => <<"task-1">>, <<"status">> => <<"cancelled">>}),
                        meck:passthrough([Owner])
                end),
    ?assertMatch({ok, #{<<"status">> := <<"awaiting_review">>}}, muse_actions:decide(O, Id, H, approve)),
    meck:expect(?WS, connection, fun(Owner) -> meck:passthrough([Owner]) end),
    _ = muse_store:put(O, <<"tasks">>, #{<<"id">> => <<"task-1">>, <<"status">> => <<"running">>}),
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>}}, muse_actions:decide(O, Id, H, approve)),
    ?assertEqual(1, calls(execute)),
    %% deny does not need a runnable task
    {ok, #{<<"id">> := Id2, <<"hash">> := H2}} = muse_actions:propose(O, ?EMAIL, undefined, <<"gone">>),
    ?assertMatch({ok, #{<<"status">> := <<"denied">>}}, muse_actions:decide(O, Id2, H2, deny)).

cancel_race() ->
    O = owner(),
    {ok, #{<<"id">> := Id, <<"hash">> := H}} = muse_actions:propose(O, ?EMAIL, undefined, <<"task-1">>),
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

calendar_review() ->
    O = owner(),
    Target = #{<<"id">> => <<"event-1">>, <<"calendarId">> => <<"primary">>, <<"title">> => <<"Provider title">>,
               <<"start">> => <<"2026-10-23">>, <<"end">> => <<"2026-10-24">>, <<"allDay">> => true,
               <<"timeZone">> => <<"America/Los_Angeles">>, <<"location">> => <<>>, <<"description">> => <<>>,
               <<"attendees">> => []},
    persistent_term:put({?MODULE, version}, <<"\"revision-1\"">>),
    meck:expect(?WS, connection, fun(_) -> #{id => <<"calendar-connection">>, account => <<"me@example.com">>} end),
    meck:expect(?WS, connected, fun(_) -> true end),
    meck:expect(?WS, prepare,
                fun(_, #{<<"kind">> := <<"calendar.delete">>, <<"data">> := D} = In, <<"calendar-connection">>) ->
                        {ok, #{input => In#{<<"data">> => D#{<<"title">> => <<"Provider title">>}},
                               target => Target, target_version => persistent_term:get({?MODULE, version})}}
                end),
    meck:expect(?WS, execute,
                fun(_, #{<<"kind">> := <<"calendar.delete">>, <<"data">> := #{<<"title">> := <<"Provider title">>}},
                    <<"calendar-connection">>, <<"\"revision-1\"">>) -> {ok, <<"Deleted">>}
                end),
    Input = #{<<"kind">> => <<"calendar.delete">>,
              <<"data">> => #{<<"eventId">> => <<"event-1">>, <<"calendarId">> => <<"primary">>,
                              <<"title">> => <<"Untrusted title">>}},
    {ok, P} = muse_actions:propose(O, Input, undefined, undefined),
    ?assertMatch(#{<<"title">> := <<"Delete Provider title">>, <<"target">> := Target,
                   <<"targetVersion">> := <<"\"revision-1\"">>}, P),
    persistent_term:put({?MODULE, version}, <<"\"revision-2\"">>),
    {ok, Newer} = muse_actions:propose(O, Input, undefined, undefined),
    ?assertNotEqual(maps:get(<<"hash">>, P), maps:get(<<"hash">>, Newer)),
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>, <<"result">> := <<"Deleted">>}},
                 muse_actions:decide(O, maps:get(<<"id">>, P), maps:get(<<"hash">>, P), approve)),
    persistent_term:erase({?MODULE, version}).

%% Reference hashes from Node running the original proposalSchema +
%% JSON.stringify({input, connection, target, targetVersion}).
node_vectors() ->
    Target = #{<<"id">> => <<"evt-9">>, <<"calendarId">> => <<"primary">>,
               <<"title">> => <<"Provider “title”"/utf8>>, <<"start">> => <<"2026-10-23">>,
               <<"end">> => <<"2026-10-24">>, <<"allDay">> => true, <<"timeZone">> => <<"UTC">>,
               <<"location">> => <<>>, <<"description">> => <<"Line1\nLine2">>,
               <<"attendees">> => [<<"a@example.com">>]},
    Me = fun(Id) -> #{id => Id, account => <<"me@example.com">>} end,
    Vectors =
        [{#{<<"kind">> => <<"email.send">>,
            <<"data">> => #{<<"body">> => <<"See attached.\x{1} é"/utf8>>, <<"subject">> => <<"  Visit 你好 "/utf8>>,
                            <<"to">> => [<<"sam@example.com">>], <<"replyToMessageId">> => <<"m1">>,
                            <<"extra">> => 1}},
          #{id => <<"sample-google">>, account => <<"alex@example.com">>}, #{},
          <<"6f7174b4fd4e94231604708be30107408af5c3d2984d16385b1082ca7f7d234d">>},
         {#{<<"kind">> => <<"calendar.create">>,
            <<"data">> => #{<<"title">> => <<"Coffee">>, <<"start">> => <<"2026-10-23T10:00:00-07:00">>,
                            <<"end">> => <<"2026-10-23T11:00:00-07:00">>}},
          Me(<<"c1">>), #{},
          <<"581ed49b95d0d1b9a3d8faf2a29f73ce8b378d96fe35a63a9787d7f80d13821f">>},
         {#{<<"kind">> => <<"calendar.update">>,
            <<"data">> => #{<<"eventId">> => <<"evt-9">>, <<"title">> => <<" Retitled ">>,
                            <<"start">> => <<"2026-10-23">>, <<"end">> => <<"2026-10-24">>, <<"allDay">> => true,
                            <<"attendees">> => [<<"b@example.com">>], <<"timeZone">> => <<"Europe/Paris">>}},
          Me(<<"c2">>), #{target => Target, target_version => <<"\"rev-1\"">>},
          <<"a4e280dc234a5c29bdc0bf793e19afad29fe152cd22971770cbc4602e1f29196">>},
         {#{<<"kind">> => <<"calendar.delete">>,
            <<"data">> => #{<<"title">> => <<"Provider “title”"/utf8>>, <<"eventId">> => <<"evt-9">>,
                            <<"calendarId">> => <<"primary">>}},
          Me(<<"c2">>), #{target => Target, target_version => <<"\"rev-2\"">>},
          <<"973fa54937dafab40011acf8387763b11145b430de171abb00747746c45e5eb6">>},
         {#{<<"kind">> => <<"calendar.delete">>,
            <<"data">> => #{<<"title">> => <<"x">>, <<"eventId">> => <<"evt-9">>, <<"calendarId">> => <<"primary">>}},
          #{id => <<"c3">>, account => undefined}, #{},
          <<"b337d73a1bb40a16b9756224812edd00392e9df4362717cb7260b5a0d6ddc77e">>}],
    lists:foreach(
      fun({Raw, Conn, Extra, Expected}) ->
              meck:expect(?WS, connection, fun(_) -> Conn end),
              meck:expect(?WS, prepare, fun(_, In, _) -> {ok, Extra#{input => In}} end),
              {ok, #{<<"hash">> := Hash}} = muse_actions:propose(owner(), Raw, undefined, undefined),
              ?assertEqual(Expected, Hash)
      end, Vectors).

worker_helpers() ->
    O = owner(),
    ?assertNot(muse_actions:awaits_review(O, undefined)),
    ?assertNot(muse_actions:awaits_review(O, <<"missing">>)),
    {ok, #{<<"id">> := Id} = P} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
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
    {ok, #{<<"id">> := Id}} = muse_actions:propose(O, ?EMAIL, undefined, <<"task-x">>),
    ?assertEqual(ok, muse_actions:reject_pending(O, Id)),
    ?assertMatch(#{<<"status">> := <<"denied">>}, muse_actions:get(O, Id)),
    ?assertEqual(ok, muse_actions:reject_pending(O, Id)),
    {ok, #{<<"id">> := Id2}} = muse_actions:propose(O, ?EMAIL, undefined, undefined),
    muse_time:set_offset(31 * 60 * 1000),
    ?assertEqual({error, {409, <<"This review expired. Create a fresh proposal.">>}},
                 muse_actions:reject_pending(O, Id2)),
    ?assertEqual(0, calls(execute)).

validation() ->
    O = owner(),
    ?assertMatch({error, {422, _}}, muse_actions:propose(O, #{<<"kind">> => <<"nope">>}, undefined, undefined)),
    ?assertMatch({error, {422, _}},
                 muse_actions:propose(O, #{<<"kind">> => <<"email.send">>,
                                           <<"data">> => #{<<"to">> => [], <<"subject">> => <<"x">>,
                                                           <<"body">> => <<"y">>}}, undefined, undefined)),
    ?assertMatch({error, {422, <<"End must be after a valid start">>}},
                 muse_actions:propose(O, #{<<"kind">> => <<"calendar.create">>,
                                           <<"data">> => #{<<"title">> => <<"T">>, <<"start">> => <<"2026-10-24">>,
                                                           <<"end">> => <<"2026-10-23">>, <<"allDay">> => true}},
                                      undefined, undefined)),
    ?assertMatch({error, {422, _}},
                 muse_actions:propose(O, #{<<"kind">> => <<"calendar.update">>,
                                           <<"data">> => #{<<"title">> => <<"T">>, <<"start">> => <<"2026-10-23">>,
                                                           <<"end">> => <<"2026-10-24">>, <<"allDay">> => true}},
                                      undefined, undefined)),
    Attach = ?EMAIL,
    #{<<"data">> := D} = Attach,
    ?assertMatch({error, {404, _}},
                 muse_actions:propose(O, Attach#{<<"data">> => D#{<<"attachmentIds">> => [muse_ids:uuid()]}},
                                      undefined, undefined)),
    ?assertEqual([], muse_store:list(O, <<"actions">>)),
    ?assertEqual(1, calls(prepare)).
