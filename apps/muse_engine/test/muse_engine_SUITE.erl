%% Task engine behaviour (engine spec §3–§6) on a sample workspace, with a
%% scripted model runner and a manually ticked worker.
-module(muse_engine_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [create_validation, idempotent_create, model_task_without_runner, runner_success_and_failure,
     crash_is_generic_failure, control_rules, abort_running_task, lost_lease, lease_takeover,
     document_flow, cancel_rejects_review, monitor_contains, monitor_backoff_and_pause,
     ideas_refresh_and_accept, goals_and_milestones, memories_identity_notifications,
     maintenance, snapshot_shape, finance_task, monitor_change, heartbeat_loss, events_broadcast].

init_per_testcase(Case, Config) ->
    %% heartbeat_loss needs a short lease (heartbeat every 100 ms)
    Case =:= heartbeat_loss andalso application:set_env(muse_engine, lease_ms, 300),
    Env = muse_engine_test_env:start(),
    ok = muse_workspace:ensure_sample(?O, fun(O, I) -> muse_actions:propose(O, I, undefined, undefined) end),
    muse_test_runner:set({return, #{<<"status">> => <<"succeeded">>, <<"result">> => <<"done">>}}),
    [{env, Env} | Config].

end_per_testcase(_Case, Config) ->
    muse_time:set_offset(0),
    application:unset_env(muse_engine, lease_ms),
    muse_engine_test_env:stop(?config(env, Config)).

task(Id) ->
    muse_store:get(?O, <<"tasks">>, Id).

new_task(Raw) ->
    {ok, T} = muse_agent_service:create_task(?O, Raw),
    T.

notifications() ->
    [T || #{<<"title">> := T} <- muse_store:list(?O, <<"notifications">>)].

%% Cases

create_validation(_) ->
    ?assertMatch({error, {422, <<"Too small", _/binary>>}}, muse_agent_service:create_task(?O, #{<<"prompt">> => <<"  ">>})),
    ?assertEqual({error, {422, <<"A milestone requires a goal">>}},
                 muse_agent_service:create_task(?O, #{<<"prompt">> => <<"p">>, <<"milestoneId">> => <<"m">>})),
    ?assertEqual({error, {404, <<"Goal not found">>}},
                 muse_agent_service:create_task(?O, #{<<"prompt">> => <<"p">>, <<"goalId">> => <<"g">>})),
    T = new_task(#{<<"prompt">> => binary:copy(<<"x">>, 100)}),
    ?assertMatch(#{<<"status">> := <<"queued">>, <<"kind">> := <<"agent">>, <<"leaseId">> := null,
                   <<"leaseUntil">> := null, <<"attempts">> := 0, <<"artifactIds">> := [], <<"evidence">> := [],
                   <<"state">> := #{<<"connectionId">> := <<"sample-google">>}}, T),
    ?assertEqual(90, byte_size(maps:get(<<"title">>, T))),
    ?assertEqual(4, length(maps:get(<<"plan">>, T))),
    %% capacity: 100 open tasks
    [new_task(#{<<"prompt">> => integer_to_binary(N)}) || N <- lists:seq(1, 99)],
    ?assertEqual({error, {409, <<"Finish or cancel some tasks before adding more">>}},
                 muse_agent_service:create_task(?O, #{<<"prompt">> => <<"one more">>})).

idempotent_create(_) ->
    {ok, A} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"p">>}, <<"req-1">>, false),
    {ok, B} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"different">>}, <<"req-1">>, false),
    ?assertEqual(A, B),
    ?assertEqual(muse_ids:sha256hex(<<"task:req-1">>), maps:get(<<"id">>, A)),
    %% the schema is still checked first (createTaskSchema.parse runs before the lookup)
    ?assertMatch({error, {422, _}}, muse_agent_service:create_task(?O, #{<<"prompt">> => <<>>}, <<"req-1">>, false)).

model_task_without_runner(_) ->
    application:unset_env(muse_engine, task_runner),
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"Plan a trip">>}),
    muse_engine_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"waiting_input">>, <<"question">> := <<"A model is required", _/binary>>,
                   <<"leaseId">> := null, <<"attempts">> := 1}, task(Id)),
    ?assert(lists:member(<<"Your details are needed">>, notifications())),
    [#{<<"kind">> := <<"status">>, <<"title">> := <<"Started working">>}] = muse_events_log:list(?O, Id),
    [#{<<"status">> := <<"waiting_input">>, <<"finishedAt">> := _}] = muse_store:list(?O, <<"runs">>).

runner_success_and_failure(_) ->
    #{<<"id">> := Ok} = new_task(#{<<"prompt">> => <<"ok">>}),
    muse_engine_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"result">> := <<"done">>}, task(Ok)),
    muse_test_runner:set({fail, <<"Out of coffee">>}),
    #{<<"id">> := Bad} = new_task(#{<<"prompt">> => <<"bad">>}),
    muse_engine_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"error">> := <<"Out of coffee">>, <<"leaseId">> := null}, task(Bad)),
    ?assertMatch([_, #{<<"kind">> := <<"error">>, <<"title">> := <<"Task needs attention">>,
                       <<"detail">> := <<"Out of coffee">>}], muse_events_log:list(?O, Bad)),
    ?assert(lists:member(<<"Task needs attention">>, notifications())),
    %% retry is allowed for failed tasks and resumes work
    muse_test_runner:set({return, #{<<"status">> => <<"succeeded">>, <<"result">> => <<"second">>}}),
    {ok, #{<<"status">> := <<"queued">>, <<"error">> := null}} = muse_agent_service:control(?O, Bad, <<"retry">>),
    muse_engine_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"attempts">> := 2}, task(Bad)),
    [_, _, #{<<"title">> := <<"Task queued">>}, #{<<"title">> := <<"Resumed work">>}] = muse_events_log:list(?O, Bad).

crash_is_generic_failure(_) ->
    muse_test_runner:set({crash, boom}),
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"crash">>}),
    muse_engine_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"error">> := <<"Task execution failed">>}, task(Id)).

control_rules(_) ->
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"p">>}),
    ?assertEqual({error, {409, <<"Only failed tasks can be retried">>}}, muse_agent_service:control(?O, Id, <<"retry">>)),
    ?assertEqual({error, {409, <<"Only paused tasks can be resumed">>}}, muse_agent_service:control(?O, Id, <<"resume">>)),
    {ok, #{<<"status">> := <<"paused">>, <<"result">> := <<"Paused. Resume when you're ready.">>}} =
        muse_agent_service:control(?O, Id, <<"pause">>),
    %% pausing again is a no-op
    {ok, #{<<"status">> := <<"paused">>}} = muse_agent_service:control(?O, Id, <<"pause">>),
    ?assertEqual([], muse_task_worker:tick()),
    {ok, #{<<"status">> := <<"queued">>}} = muse_agent_service:control(?O, Id, <<"resume">>),
    muse_engine_test_env:run_pending(),
    ?assertEqual({error, {409, <<"This task is already complete">>}}, muse_agent_service:control(?O, Id, <<"cancel">>)),
    {ok, #{<<"status">> := <<"succeeded">>}} = muse_agent_service:control(?O, Id, <<"pause">>),
    ?assertEqual({error, {404, <<"Task not found">>}}, muse_agent_service:control(?O, <<"nope">>, <<"pause">>)),
    #{<<"id">> := C} = new_task(#{<<"prompt">> => <<"c">>}),
    {ok, #{<<"status">> := <<"cancelled">>, <<"result">> := <<"Stopped by you.">>}} =
        muse_agent_service:control(?O, C, <<"cancel">>).

abort_running_task(_) ->
    muse_test_runner:set({wait, 30000, #{<<"status">> => <<"succeeded">>}}),
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"slow">>}),
    [Id] = muse_task_worker:tick(),
    muse_engine_test_env:wait_for(fun() -> maps:get(<<"status">>, task(Id)) =:= <<"running">> end, 5000),
    {ok, #{<<"status">> := <<"paused">>}} = muse_agent_service:control(?O, Id, <<"pause">>),
    muse_engine_test_env:wait_idle(),
    ?assertMatch(#{<<"status">> := <<"paused">>, <<"leaseId">> := null}, task(Id)),
    [#{<<"status">> := <<"interrupted">>}] = muse_store:list(?O, <<"runs">>).

lost_lease(_) ->
    muse_test_runner:set({checkpoint_wait, #{<<"result">> => <<"early">>}, 500, #{<<"status">> => <<"succeeded">>}}),
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"steal">>}),
    [Id] = muse_task_worker:tick(),
    muse_engine_test_env:wait_for(fun() -> maps:get(<<"result">>, task(Id), undefined) =:= <<"early">> end, 5000),
    %% another worker takes the lease
    _ = muse_store:cas(?O, <<"tasks">>, Id, #{}, #{<<"leaseId">> => <<"other-worker">>}),
    muse_engine_test_env:wait_idle(),
    %% the late checkpoint failed, the run did not overwrite the new owner's lease
    ?assertMatch(#{<<"status">> := <<"running">>, <<"leaseId">> := <<"other-worker">>, <<"result">> := <<"early">>},
                 task(Id)),
    [#{<<"status">> := <<"interrupted">>}] = muse_store:list(?O, <<"runs">>).

lease_takeover(_) ->
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"orphan">>}),
    Past = muse_time:to_iso(muse_time:now_ms() - 1000),
    _ = muse_store:cas(?O, <<"tasks">>, Id, #{}, #{<<"status">> => <<"running">>, <<"leaseId">> => <<"dead">>,
                                                  <<"leaseUntil">> => Past, <<"attempts">> => 1}),
    muse_engine_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"attempts">> := 2}, task(Id)),
    %% a live lease is not taken over
    #{<<"id">> := Live} = new_task(#{<<"prompt">> => <<"live">>}),
    _ = muse_store:cas(?O, <<"tasks">>, Live, #{}, #{<<"status">> => <<"running">>, <<"leaseId">> => <<"alive">>,
                                                    <<"leaseUntil">> => muse_time:to_iso(muse_time:now_ms() + 60000)}),
    ?assertEqual([], muse_task_worker:tick()).

document_flow(_) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"kind">> => <<"document">>,
                                                                   <<"prompt">> => <<"Complete the permission slip">>,
                                                                   <<"input">> => #{<<"messageId">> => <<"mail-fieldtrip">>}}),
    muse_engine_test_env:run_pending(),
    #{<<"status">> := <<"waiting_input">>, <<"question">> := Q, <<"state">> := #{<<"source">> := _}} = task(Id),
    ?assertMatch(<<"Enter the form values you want to use. Supported fields: participant_name", _/binary>>, Q),
    {ok, _} = muse_agent_service:answer(?O, Id, <<"Here you go">>,
                                        #{<<"participant_name">> => <<"Sam">>, <<"permission_granted">> => true}),
    muse_engine_test_env:run_pending(),
    #{<<"status">> := <<"waiting_approval">>, <<"actionId">> := ActionId, <<"artifactIds">> := [Filled],
      <<"plan">> := Plan} = task(Id),
    ?assertEqual([<<"succeeded">>, <<"succeeded">>, <<"succeeded">>, <<"waiting">>, <<"pending">>],
                 [S || #{<<"status">> := S} <- Plan]),
    ?assert(lists:member(<<"Ready for your review">>, notifications())),
    #{<<"hash">> := Hash, <<"data">> := Data} = muse_actions:get(?O, ActionId),
    ?assertMatch(#{<<"subject">> := <<"Re: A little reminder: permission slips are due Friday">>,
                   <<"to">> := [<<"office@lincoln.example">>], <<"attachmentIds">> := [Filled]}, Data),
    %% still pending: the worker leaves it alone
    ?assertEqual([], muse_task_worker:tick()),
    {ok, #{<<"status">> := <<"succeeded">>}} = muse_actions:decide(?O, ActionId, Hash, approve),
    muse_engine_test_env:run_pending(),
    #{<<"status">> := <<"succeeded">>, <<"result">> := <<"Saved to local sent mail · "/utf8, _/binary>>} = task(Id),
    Titles = [T || #{<<"title">> := T} <- muse_events_log:list(?O, Id)],
    ?assert(lists:member(<<"Saved a filled copy">>, Titles)),
    ?assert(lists:member(<<"Approved action completed">>, Titles)),
    %% the reply is no longer an idea source
    {ok, Ideas} = muse_ideas:refresh(?O),
    ?assertEqual([], [I || I = #{<<"kind">> := <<"document">>, <<"status">> := <<"new">>} <- Ideas]).

cancel_rejects_review(_) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"kind">> => <<"document">>, <<"prompt">> => <<"p">>,
                                                                   <<"input">> => #{<<"messageId">> => <<"mail-fieldtrip">>,
                                                                                    <<"fields">> => #{<<"participant_name">> => <<"A">>}}}),
    muse_engine_test_env:run_pending(),
    #{<<"status">> := <<"waiting_approval">>, <<"actionId">> := ActionId} = task(Id),
    {ok, #{<<"status">> := <<"cancelled">>}} = muse_agent_service:control(?O, Id, <<"cancel">>),
    ?assertMatch(#{<<"status">> := <<"denied">>}, muse_actions:get(?O, ActionId)),
    %% a denied review blocks retry of a failed document task
    _ = muse_store:cas(?O, <<"tasks">>, Id, #{}, #{<<"status">> => <<"failed">>}),
    ?assertMatch({error, {409, <<"Check the reviewed action before retrying", _/binary>>}},
                 muse_agent_service:control(?O, Id, <<"retry">>)).

monitor_contains(_) ->
    ok = muse_agent_service:set_sample_page(?O, <<"Tables: none left">>),
    {ok, #{<<"id">> := Mid, <<"taskId">> := TaskId}} =
        muse_monitors:create(?O, #{<<"title">> => <<"Dinner">>, <<"url">> => <<"sample://availability">>,
                                   <<"condition">> => <<"contains">>, <<"value">> => <<"TABLE FOR 2">>,
                                   <<"intervalMinutes">> => 5}, undefined),
    muse_engine_test_env:run_pending(),
    #{<<"status">> := <<"scheduled">>, <<"nextRunAt">> := Next, <<"state">> := #{<<"matched">> := false}} = task(TaskId),
    ?assertMatch(#{<<"checks">> := 1, <<"error">> := null}, muse_store:get(?O, <<"monitors">>, Mid)),
    ?assertEqual([], muse_task_worker:tick()),
    ok = muse_agent_service:set_sample_page(?O, <<"One table for 2 at 7pm">>),
    muse_time:set_offset(muse_time:parse(Next) - erlang:system_time(millisecond) + 1),
    muse_engine_test_env:run_pending(),
    #{<<"state">> := #{<<"matched">> := true, <<"notice">> := #{<<"key">> := Key}},
      <<"result">> := <<"Change found. A notification is ready.">>} = task(TaskId),
    ?assertMatch(<<"monitor:", _/binary>>, Key),
    ?assert(lists:member(<<"Dinner">>, notifications())),
    %% invalid inputs
    ?assertEqual({error, {422, <<"Enter a condition value">>}},
                 muse_monitors:create(?O, #{<<"title">> => <<"x">>, <<"url">> => <<"https://example.com">>,
                                            <<"condition">> => <<"contains">>}, undefined)),
    ?assertEqual({error, {422, <<"Enter a positive price">>}},
                 muse_monitors:create(?O, #{<<"title">> => <<"x">>, <<"url">> => <<"https://example.com">>,
                                            <<"condition">> => <<"price_below">>, <<"value">> => <<"abc">>}, undefined)),
    ?assertEqual({error, {422, <<"Unknown sample source">>}},
                 muse_monitors:create(?O, #{<<"title">> => <<"x">>, <<"url">> => <<"sample://other">>}, undefined)),
    ?assertEqual({error, {422, <<"Use a public HTTP(S) page">>}},
                 muse_monitors:create(?O, #{<<"title">> => <<"x">>, <<"url">> => <<"ftp://example.com">>}, undefined)),
    {ok, #{<<"status">> := <<"stopped">>}} = muse_monitors:control(?O, Mid, <<"stop">>),
    ?assertMatch(#{<<"status">> := <<"cancelled">>}, task(TaskId)),
    ?assertEqual({error, {409, <<"Create a new watch to restart this stopped monitor">>}},
                 muse_monitors:control(?O, Mid, <<"resume">>)).

monitor_backoff_and_pause(_) ->
    %% no browser worker is configured: every check fails
    {ok, #{<<"id">> := Mid, <<"taskId">> := TaskId}} =
        muse_monitors:create(?O, #{<<"title">> => <<"Shop">>, <<"url">> => <<"https://example.com/item">>}, undefined),
    Check = fun(Expected) ->
                    muse_engine_test_env:run_pending(),
                    #{<<"status">> := Status, <<"state">> := #{<<"failures">> := F}} = T = task(TaskId),
                    ?assertEqual(Expected, {Status, F}),
                    T
            end,
    T1 = Check({<<"scheduled">>, 1}),
    %% first failure backs off 2^1 = 2 minutes
    Delay = muse_time:parse(maps:get(<<"nextRunAt">>, T1)) - muse_time:now_ms(),
    ?assert(Delay > 2 * 60000 - 10000 andalso Delay =< 2 * 60000),
    ?assertMatch(#{<<"error">> := <<"Browser worker is not configured", _/binary>>},
                 muse_store:get(?O, <<"monitors">>, Mid)),
    Advance = fun(T) -> muse_time:set_offset(muse_time:offset() + muse_time:parse(maps:get(<<"nextRunAt">>, T))
                                             - muse_time:now_ms() + 1) end,
    Advance(T1), T2 = Check({<<"scheduled">>, 2}),
    Advance(T2), T3 = Check({<<"scheduled">>, 3}),
    Advance(T3), T4 = Check({<<"scheduled">>, 4}),
    Advance(T4), _ = Check({<<"paused">>, 5}),
    ?assertMatch(#{<<"status">> := <<"paused">>}, muse_store:get(?O, <<"monitors">>, Mid)),
    Alerts = [N || N = #{<<"title">> := <<"Watch needs attention">>} <- muse_store:list(?O, <<"notifications">>)],
    ?assertEqual(2, length(Alerts)),
    %% resume clears the failure count and queues a check
    {ok, #{<<"status">> := <<"active">>}} = muse_monitors:control(?O, Mid, <<"resume">>),
    ?assertMatch(#{<<"status">> := <<"queued">>, <<"state">> := #{<<"failures">> := 0}}, task(TaskId)).

ideas_refresh_and_accept(_) ->
    {ok, Ideas} = muse_ideas:refresh(?O),
    Kinds = lists:sort([K || #{<<"kind">> := K} <- Ideas]),
    ?assertEqual([<<"agent">>, <<"document">>], Kinds),
    [#{<<"id">> := DocIdea}] = [I || I = #{<<"kind">> := <<"document">>} <- Ideas],
    {ok, Again} = muse_ideas:refresh(?O),
    ?assertEqual(length(Ideas), length(Again)),
    {ok, #{<<"status">> := <<"accepted">>, <<"taskId">> := TaskId}} =
        muse_ideas:decide(?O, DocIdea, <<"accept">>, <<"Use my edited prompt">>),
    %% the task uses the prompt as edited when the idea was accepted
    #{<<"goalId">> := GoalId, <<"prompt">> := <<"Use my edited prompt">>} = task(TaskId),
    ?assertMatch(#{<<"title">> := <<"I can help with A little reminder", _/binary>>},
                 muse_store:get(?O, <<"goals">>, GoalId)),
    {ok, #{<<"status">> := <<"accepted">>}} = muse_ideas:decide(?O, DocIdea, <<"dismiss">>, undefined),
    [#{<<"id">> := Other}] = [I || I = #{<<"kind">> := <<"agent">>} <- Ideas],
    {ok, #{<<"status">> := <<"dismissed">>}} = muse_ideas:decide(?O, Other, <<"dismiss">>, undefined),
    ?assertEqual({error, {404, <<"Idea not found">>}}, muse_ideas:decide(?O, <<"x">>, <<"accept">>, undefined)),
    %% goals without milestones suggest a plan: the one created for the
    %% accepted idea and a new one
    {ok, _} = muse_agent_service:create_goal(?O, #{<<"title">> => <<"Run a 10k">>}),
    {ok, Ideas2} = muse_ideas:refresh(?O),
    ?assertMatch([_, _], [I || I = #{<<"kind">> := <<"plan">>} <- Ideas2]).

goals_and_milestones(_) ->
    {ok, #{<<"id">> := G, <<"milestones">> := [#{<<"id">> := M1}, _]}} =
        muse_agent_service:create_goal(?O, #{<<"title">> => <<"Garden">>, <<"milestones">> => [<<"Soil">>, <<"Seeds">>]}),
    {ok, #{<<"milestones">> := [#{<<"done">> := true}, #{<<"done">> := false}]}} =
        muse_agent_service:set_milestone_done(?O, G, M1, true),
    ?assertEqual({error, {404, <<"Goal or milestone not found">>}},
                 muse_agent_service:set_milestone_done(?O, G, <<"nope">>, true)),
    {ok, #{<<"id">> := T1}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"Buy soil">>, <<"goalId">> => G}),
    muse_engine_test_env:run_pending(),
    #{<<"milestones">> := Ms} = muse_store:get(?O, <<"goals">>, G),
    ?assertMatch([_, _, #{<<"id">> := T1, <<"done">> := true}], Ms),
    %% pausing the goal pauses its open tasks; new tasks start paused
    {ok, #{<<"id">> := T2}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"Plant">>, <<"goalId">> => G}),
    {ok, _} = muse_agent_service:update_goal(?O, G, #{<<"status">> => <<"paused">>}),
    ?assertMatch(#{<<"status">> := <<"paused">>}, task(T2)),
    {ok, #{<<"status">> := <<"paused">>}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"Water">>, <<"goalId">> => G}).

memories_identity_notifications(_) ->
    {ok, #{<<"id">> := M, <<"source">> := <<"You">>}} = muse_agent_service:add_memory(?O, #{<<"text">> => <<" Likes tea ">>}),
    {ok, #{<<"text">> := <<"Likes green tea">>}} = muse_agent_service:update_memory(?O, M, #{<<"text">> => <<"Likes green tea">>}),
    ok = muse_agent_service:forget_memory(?O, M),
    ?assertEqual({error, {404, <<"Memory not found">>}}, muse_agent_service:forget_memory(?O, M)),
    {ok, #{<<"name">> := <<"Muse">>, <<"tone">> := <<"concise">>}} =
        muse_agent_service:set_identity(?O, #{<<"name">> => <<"Muse">>, <<"tone">> => <<"concise">>}),
    ?assertMatch({error, {422, _}}, muse_agent_service:set_identity(?O, #{<<"name">> => <<"x">>, <<"tone">> => <<"rude">>})),
    ok = muse_agent_service:notify(?O, <<"Hi">>, <<"Body">>, undefined, <<"k1">>),
    ok = muse_agent_service:notify(?O, <<"Hi again">>, <<"Body">>, undefined, <<"k1">>),
    [#{<<"id">> := N, <<"title">> := <<"Hi">>, <<"read">> := false}] = muse_agent_service:notifications(?O),
    {ok, #{<<"read">> := true}} = muse_agent_service:read_notification(?O, N).

maintenance(_) ->
    ok = muse_agent_service:ensure(?O),
    {ok, Pid} = muse_maintainer:start_link(), unlink(Pid),
    ok = muse_maintainer:run_once(),
    %% no Ideas refresh: the UI has no Ideas
    ?assertEqual([], muse_store:list(?O, <<"ideas">>)),
    ?assertNot(maps:is_key(<<"lastIdeasAt">>, muse_store:get(?O, <<"agent-settings">>, <<"identity">>))),
    gen_server:stop(Pid).

snapshot_shape(_) ->
    _ = muse_task_worker:tick(),
    {ok, S} = muse_agent_service:snapshot(?O),
    ?assertEqual(lists:sort([<<"tasks">>, <<"goals">>, <<"monitors">>, <<"ideas">>, <<"memories">>, <<"artifacts">>,
                             <<"notifications">>, <<"identity">>, <<"worker">>]), lists:sort(maps:keys(S))),
    ?assertMatch(#{<<"identity">> := #{<<"name">> := <<"OpenMuse">>, <<"tone">> := <<"warm">>},
                   <<"worker">> := #{<<"running">> := true, <<"lastTickAt">> := _}}, S),
    {ok, D} = muse_agent_service:detail(?O, maps:get(<<"id">>, new_task(#{<<"prompt">> => <<"x">>}))),
    ?assertEqual([<<"artifacts">>, <<"browsers">>, <<"events">>, <<"files">>, <<"task">>], lists:sort(maps:keys(D))).

%% The UI's "Try example transactions" CSV (apps/mobile/src/agent-ui.tsx).
-define(EXAMPLE_CSV, <<"date,description,amount,category\n2026-09-01,Salary,-4200,Income\n"
                      "2026-09-02,Groceries,84.50,Food\n2026-09-03,Subscription,19.99,Subscriptions\n"
                      "2026-09-04,Coffee,6.50,Food">>).

finance_task(_) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"kind">> => <<"finance">>, <<"prompt">> => <<"Track">>,
                                                                   <<"input">> => #{<<"csv">> => ?EXAMPLE_CSV}}),
    muse_engine_test_env:run_pending(),
    #{<<"status">> := <<"succeeded">>, <<"result">> := Result, <<"artifactIds">> := [ArtifactId],
      <<"evidence">> := [#{<<"excerpt">> := Excerpt}]} = task(Id),
    ?assertEqual(<<"4 transactions · 110.99 spent"/utf8>>, Result),
    ?assertEqual(<<"4 rows; 2026-09-01 through 2026-09-04">>, Excerpt),
    ?assertEqual(muse_ids:sha256hex(<<Id/binary, ":finance">>), ArtifactId),
    #{<<"kind">> := <<"finance">>, <<"title">> := <<"Spending tracker">>, <<"data">> := #{<<"count">> := 4}} =
        muse_store:get(?O, <<"agent-artifacts">>, ArtifactId),
    %% invalid CSV fails the task with the parser's message
    {ok, #{<<"id">> := Bad}} = muse_agent_service:create_task(?O, #{<<"kind">> => <<"finance">>, <<"prompt">> => <<"x">>,
                                                                    <<"input">> => #{<<"csv">> => <<"nonsense">>}}),
    {ok, #{<<"id">> := Missing}} = muse_agent_service:create_task(?O, #{<<"kind">> => <<"finance">>, <<"prompt">> => <<"y">>}),
    muse_engine_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"error">> := <<_/binary>>}, task(Bad)),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"error">> := <<"Invalid input: expected string, received undefined">>},
                 task(Missing)).

monitor_change(_) ->
    ok = muse_agent_service:set_sample_page(?O, <<"Menu\nSoup of the day: tomato\nUpdated 3 minutes ago">>),
    {ok, #{<<"taskId">> := TaskId}} =
        muse_monitors:create(?O, #{<<"title">> => <<"Menu">>, <<"url">> => <<"sample://availability">>}, undefined),
    Next = fun() ->
                   #{<<"nextRunAt">> := N} = task(TaskId),
                   muse_time:set_offset(muse_time:offset() + muse_time:parse(N) - muse_time:now_ms() + 1),
                   muse_engine_test_env:run_pending(),
                   task(TaskId)
           end,
    muse_engine_test_env:run_pending(),
    #{<<"result">> := <<"Watching. I'll check again on schedule.">>} = task(TaskId),
    %% only a relative time changed: quiet
    ok = muse_agent_service:set_sample_page(?O, <<"Menu\nSoup of the day: tomato\nUpdated 5 minutes ago">>),
    #{<<"result">> := <<"Watching. I'll check again on schedule.">>} = Next(),
    ok = muse_agent_service:set_sample_page(?O, <<"Menu\nSoup of the day: lentil\nUpdated 1 minute ago">>),
    #{<<"result">> := <<"Change found: ", _/binary>>,
      <<"state">> := #{<<"notice">> := #{<<"body">> := Body}}} = Next(),
    ?assertMatch(<<"Changed at sample://availability\n", _/binary>>, Body),
    ?assertNotEqual(nomatch, binary:match(Body, <<"lentil">>)),
    ?assert(lists:member(<<"Menu">>, notifications())).

heartbeat_loss(_) ->
    muse_test_runner:set({wait, 20000, #{<<"status">> => <<"succeeded">>}}),
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"long">>}),
    _ = muse_task_worker:tick(),
    muse_engine_test_env:wait_for(fun() -> maps:get(<<"status">>, task(Id)) =:= <<"running">> end, 5000),
    T0 = erlang:monotonic_time(millisecond),
    _ = muse_store:cas(?O, <<"tasks">>, Id, #{}, #{<<"leaseId">> => <<"stolen">>}),
    muse_engine_test_env:wait_idle(),
    %% the failed renewal aborts the run within a heartbeat or two
    ?assert(erlang:monotonic_time(millisecond) - T0 < 2000),
    [#{<<"status">> := <<"interrupted">>}] = muse_store:list(?O, <<"runs">>).

events_broadcast(_) ->
    ok = muse_events:subscribe(?O),
    #{<<"id">> := Id} = new_task(#{<<"prompt">> => <<"watch me">>}),
    receive {muse_event, ?O, {task, Id}} -> ok after 1000 -> error(no_task_event) end,
    muse_engine_test_env:run_pending(),
    receive {muse_event, ?O, {run_event, Id, #{<<"title">> := <<"Started working">>}}} -> ok
    after 1000 -> error(no_run_event)
    end,
    receive {muse_event, ?O, {notification, _}} -> ok after 1000 -> error(no_notification_event) end.
