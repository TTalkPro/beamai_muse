%% @doc The durable task service (OpenMuse engine/service.ts, engine spec §5).
%%
%% Public functions return `{ok, Value} | {error, {Status, Message}}` with
%% OpenMuse's HTTP statuses and texts. Code that runs inside a task
%% (`execute/3` and the handlers it dispatches to) instead throws
%% `{task_failed, Message}` (the task becomes `failed` with that message) or
%% `{lost_lease, _}` (via the run context); see muse_task_run.
%%
%% Monitors live in muse_monitors and ideas in muse_ideas.
-module(muse_agent_service).

-export([ensure/1, snapshot/1, get_task/2, detail/2,
         create_task/2, create_task/4, control/3, answer/4,
         create_goal/2, create_goal/3, update_goal/3, set_milestone_done/4,
         notify/5, artifact/7, prepare/5, finish/3,
         execute/3, publish_outcome/2,
         memories/1, add_memory/2, update_memory/3, forget_memory/2,
         set_identity/2, notifications/1, read_notification/2, set_sample_page/2,
         must/1, fail/1]).

-type owner() :: binary().
-type error() :: {error, {pos_integer(), binary()}}.

-define(TASKS, <<"tasks">>).

%% Identity and snapshot

%% @doc Create the identity record on first use.
-spec ensure(owner()) -> ok.
ensure(Owner) ->
    _ = muse_store:insert_if_absent(Owner, <<"agent-settings">>,
                                    (muse_task:default_identity())#{<<"id">> => <<"identity">>}),
    ok.

%% @doc `GET /api/agent` (AgentWorkspace, spec §2.16).
-spec snapshot(owner()) -> {ok, map()}.
snapshot(Owner) ->
    ok = ensure(Owner),
    L = fun(K) -> muse_store:list(Owner, K) end,
    Heartbeat = muse_store:get(<<"system">>, <<"worker-status">>, <<"tasks">>),
    LastTick = case Heartbeat of
                   #{<<"lastTickAt">> := At} -> At;
                   _ -> undefined
               end,
    Recent = LastTick =/= undefined andalso muse_time:now_ms() - muse_time:parse(LastTick) < 15000,
    Identity = case muse_store:get(Owner, <<"agent-settings">>, <<"identity">>) of
                   undefined -> muse_task:default_identity();
                   I -> maps:without([<<"id">>, <<"lastIdeasAt">>], I)
               end,
    Worker0 = #{<<"running">> => muse_task_worker:running() orelse Recent},
    {ok, #{<<"tasks">> => L(?TASKS),
           <<"goals">> => L(<<"goals">>),
           <<"monitors">> => L(<<"monitors">>),
           <<"ideas">> => L(<<"ideas">>),
           <<"memories">> => L(<<"memories">>),
           <<"artifacts">> => L(<<"agent-artifacts">>),
           <<"notifications">> => L(<<"notifications">>),
           <<"identity">> => Identity,
           <<"worker">> => case LastTick of
                                undefined -> Worker0;
                                _ -> Worker0#{<<"lastTickAt">> => LastTick}
                            end}}.

-spec get_task(owner(), binary()) -> {ok, map()} | error().
get_task(Owner, Id) ->
    case muse_store:get(Owner, ?TASKS, Id) of
        undefined -> {error, {404, <<"Task not found">>}};
        Task -> {ok, Task}
    end.

%% @doc `GET /tasks/:id`: the task with its files, browsers, events and artifacts.
-spec detail(owner(), binary()) -> {ok, map()} | error().
detail(Owner, Id) ->
    maybe
        {ok, #{<<"artifactIds">> := ArtifactIds, <<"state">> := State} = Task} ?= get_task(Owner, Id),
        Files = [muse_files:signed(Owner, F) || F = #{<<"id">> := FId} <- muse_store:list(Owner, <<"files">>),
                                                 lists:member(FId, ArtifactIds)],
        BrowserIds = [maps:get(K, State, undefined) || K <- [<<"browserId">>, <<"sessionId">>]],
        Browsers = [muse_browser:decorate(Owner, B) || B = #{<<"id">> := BId} <- muse_store:list(Owner, <<"browsers">>),
                                                       lists:member(BId, BrowserIds)],
        {ok, #{<<"task">> => Task,
               <<"files">> => Files,
               <<"browsers">> => Browsers,
               <<"events">> => muse_events_log:list(Owner, Id),
               <<"artifacts">> => [A || A = #{<<"taskId">> := T} <- muse_store:list(Owner, <<"agent-artifacts">>),
                                        T =:= Id]}}
    end.

%% Tasks

-spec create_task(owner(), term()) -> {ok, map()} | error().
create_task(Owner, Raw) ->
    create_task(Owner, Raw, undefined, false).

%% @doc `createTask(owner, raw, idempotencyKey?, held=false)` (spec §5.1).
%% With a key the task id is `sha256hex("task:" ++ Key)` and an existing task
%% is returned unchanged before any other validation.
-spec create_task(owner(), term(), binary() | undefined, boolean()) -> {ok, map()} | error().
create_task(Owner, Raw, Key, Held) ->
    maybe
        {ok, Input} ?= muse_validate:parse(muse_task:create_schema(), Raw),
        Id = case Key of
                 undefined -> muse_ids:uuid();
                 _ -> muse_ids:sha256hex(<<"task:", Key/binary>>)
             end,
        undefined ?= muse_store:get(Owner, ?TASKS, Id),
        {ok, Goal} ?= task_goal(Owner, Input),
        ok ?= check_capacity(Owner),
        Paused = Held orelse (is_map(Goal) andalso maps:get(<<"status">>, Goal) =:= <<"paused">>),
        ConnId = case muse_workspace:connection(Owner) of
                     #{id := C} -> C;
                     undefined -> null
                 end,
        State = case Held andalso maps:get(<<"kind">>, Input) =:= <<"monitor">> of
                    true -> #{<<"connectionId">> => ConnId, <<"initializingMonitor">> => true};
                    false -> #{<<"connectionId">> => ConnId}
                end,
        Task = muse_task:new(Id, Input, case Paused of true -> <<"paused">>; false -> <<"queued">> end, State),
        ok = ensure(Owner),
        _ = muse_store:insert_if_absent(Owner, ?TASKS, Task),
        muse_events:emit(Owner, {task, Id}),
        {ok, case muse_store:get(Owner, ?TASKS, Id) of undefined -> Task; Saved -> Saved end}
    else
        #{<<"id">> := _} = Existing -> {ok, Existing};
        {error, _} = Error -> Error
    end.

task_goal(Owner, Input) ->
    GoalId = maps:get(<<"goalId">>, Input, undefined),
    Milestone = maps:get(<<"milestoneId">>, Input, undefined),
    Goal = case GoalId of
               undefined -> undefined;
               _ -> muse_store:get(Owner, <<"goals">>, GoalId)
           end,
    if
        Milestone =/= undefined, GoalId =:= undefined ->
            {error, {422, <<"A milestone requires a goal">>}};
        GoalId =/= undefined, Goal =:= undefined ->
            {error, {404, <<"Goal not found">>}};
        Milestone =/= undefined ->
            case [M || #{<<"id">> := M} <- maps:get(<<"milestones">>, Goal, []), M =:= Milestone] of
                [] -> {error, {404, <<"Milestone not found in this goal">>}};
                _ -> {ok, Goal}
            end;
        true ->
            {ok, Goal}
    end.

check_capacity(Owner) ->
    Open = [T || #{<<"status">> := S} = T <- muse_store:list(Owner, ?TASKS), not muse_task:is_terminal(S)],
    case length(Open) >= 100 of
        true -> {error, {409, <<"Finish or cancel some tasks before adding more">>}};
        false -> ok
    end.

%% @doc pause | resume | cancel | retry (spec §5.2).
-spec control(owner(), binary(), binary()) -> {ok, map()} | error().
control(Owner, Id, Action) ->
    maybe
        {ok, #{<<"status">> := Status, <<"kind">> := Kind} = Task} ?= get_task(Owner, Id),
        ok ?= control_allowed(Action, Status),
        case {Action, Kind} of
            {<<"pause">>, _} when Status =:= <<"paused">> -> {ok, Task};
            {<<"pause">>, _} ->
                case muse_task:is_terminal(Status) of
                    true -> {ok, Task};
                    false -> do_control(Owner, Task, Action)
                end;
            {<<"resume">>, <<"monitor">>} ->
                %% The monitor must be active before a worker can claim its task.
                maybe
                    {ok, _} ?= muse_monitors:control(Owner, monitor_id(Task), <<"resume">>),
                    {ok, #{<<"status">> := NewStatus} = Resumed} ?= get_task(Owner, Id),
                    status_event(Owner, Id, NewStatus),
                    {ok, Resumed}
                end;
            _ ->
                do_control(Owner, Task, Action)
        end
    end.

control_allowed(<<"cancel">>, <<"succeeded">>) -> {error, {409, <<"This task is already complete">>}};
control_allowed(<<"retry">>, S) when S =/= <<"failed">> -> {error, {409, <<"Only failed tasks can be retried">>}};
control_allowed(<<"resume">>, S) when S =/= <<"paused">> -> {error, {409, <<"Only paused tasks can be resumed">>}};
control_allowed(A, _) ->
    case lists:member(A, [<<"pause">>, <<"resume">>, <<"cancel">>, <<"retry">>]) of
        true -> ok;
        false -> {error, {422, <<"Invalid option: expected one of \"pause\"|\"resume\"|\"cancel\"|\"retry\"">>}}
    end.

do_control(Owner, #{<<"id">> := Id, <<"status">> := Status, <<"kind">> := Kind} = Task, Action) ->
    ActionId = maps:get(<<"actionId">>, Task, null),
    NewStatus = case Action of
                    <<"cancel">> -> <<"cancelled">>;
                    <<"pause">> -> <<"paused">>;
                    _ when is_binary(ActionId) -> <<"waiting_approval">>;
                    _ -> <<"queued">>
                end,
    maybe
        ok ?= retry_allowed(Owner, Action, ActionId),
        Result = case Action of
                     <<"cancel">> -> <<"Stopped by you.">>;
                     <<"pause">> -> <<"Paused. Resume when you're ready.">>;
                     _ -> <<>>
                 end,
        #{} = Updated ?= muse_store:cas(Owner, ?TASKS, Id,
                                        #{<<"status">> => Status, <<"leaseId">> => maps:get(<<"leaseId">>, Task, null)},
                                        #{<<"status">> => NewStatus, <<"leaseId">> => null, <<"leaseUntil">> => null,
                                          <<"error">> => null, <<"updatedAt">> => muse_time:now_iso(),
                                          <<"result">> => Result}),
        muse_task_worker:abort(Id),
        Kind =:= <<"monitor">> andalso
            muse_monitors:follow_task_control(Owner, monitor_id(Task), Action),
        %% Cancelling rejects a still-pending review (errors propagate, as in OpenMuse).
        ok ?= case Action of
                  <<"cancel">> -> muse_actions:reject_pending(Owner, ActionId);
                  _ -> ok
              end,
        status_event(Owner, Id, NewStatus),
        muse_events:emit(Owner, {task, Id}),
        {ok, Updated}
    else
        undefined -> {error, {409, <<"Task changed; refresh and try again">>}};
        {error, _} = Error -> Error
    end.

retry_allowed(Owner, <<"retry">>, ActionId) when is_binary(ActionId) ->
    case muse_store:get(Owner, <<"actions">>, ActionId) of
        #{<<"status">> := S} when S =/= <<"succeeded">> ->
            {error, {409, <<"Check the reviewed action before retrying; its outcome may be uncertain. "
                            "Start a new task when reconciled.">>}};
        _ -> ok
    end;
retry_allowed(_, _, _) ->
    ok.

status_event(Owner, TaskId, Status) ->
    {ok, Ev} = muse_events_log:append(Owner, TaskId, #{<<"kind">> => <<"status">>,
                                                      <<"title">> => <<"Task ", Status/binary>>,
                                                      <<"detail">> => <<"Changed by you">>}),
    muse_events:emit(Owner, {run_event, TaskId, Ev}).

%% @doc Answer a task waiting for input; the answer goes to `state.answer`
%% and form fields to `input.fields`.
-spec answer(owner(), binary(), binary(), map() | undefined) -> {ok, map()} | error().
answer(Owner, Id, Answer, Fields) ->
    maybe
        {ok, #{<<"status">> := <<"waiting_input">>, <<"input">> := Input, <<"state">> := State}} ?=
            case get_task(Owner, Id) of
                {ok, #{<<"status">> := <<"waiting_input">>}} = Ok -> Ok;
                {ok, _} -> {error, {409, <<"This task is not waiting for input">>}};
                Error -> Error
            end,
        NewInput = case Fields of
                       undefined -> Input;
                       _ -> Input#{<<"fields">> => Fields}
                   end,
        #{} = Next ?= muse_store:cas(Owner, ?TASKS, Id, #{<<"status">> => <<"waiting_input">>},
                                     #{<<"status">> => <<"queued">>, <<"question">> => null,
                                       <<"input">> => NewInput, <<"state">> => State#{<<"answer">> => Answer},
                                       <<"updatedAt">> => muse_time:now_iso()}),
        muse_events:emit(Owner, {task, Id}),
        {ok, Next}
    else
        undefined -> {error, {409, <<"Task changed; refresh and try again">>}};
        {error, _} = E -> E
    end.

%% Goals

-spec create_goal(owner(), term()) -> {ok, map()} | error().
create_goal(Owner, Raw) ->
    create_goal(Owner, Raw, undefined).

-spec create_goal(owner(), term(), binary() | undefined) -> {ok, map()} | error().
create_goal(Owner, Raw, Id0) ->
    maybe
        {ok, #{<<"milestones">> := Titles} = Input} ?= muse_validate:parse(muse_task:goal_schema(), Raw),
        Id = case Id0 of undefined -> muse_ids:uuid(); _ -> Id0 end,
        Goal = #{<<"id">> => Id,
                 <<"title">> => maps:get(<<"title">>, Input),
                 <<"description">> => maps:get(<<"description">>, Input),
                 <<"category">> => maps:get(<<"category">>, Input),
                 <<"status">> => <<"active">>,
                 <<"milestones">> => [#{<<"id">> => muse_ids:uuid(), <<"title">> => T, <<"done">> => false}
                                      || T <- Titles],
                 <<"createdAt">> => muse_time:now_iso()},
        _ = muse_store:insert_if_absent(Owner, <<"goals">>, Goal),
        muse_events:emit(Owner, {goal, Id}),
        {ok, case muse_store:get(Owner, <<"goals">>, Id) of undefined -> Goal; G -> G end}
    end.

%% @doc Patch status and/or milestones; pausing a goal pauses its open tasks.
-spec update_goal(owner(), binary(), map()) -> {ok, map()} | error().
update_goal(Owner, Id, Patch) ->
    case muse_store:cas(Owner, <<"goals">>, Id, #{}, Patch) of
        undefined ->
            {error, {404, <<"Goal not found">>}};
        Saved ->
            _ = case maps:get(<<"status">>, Patch, undefined) of
                <<"paused">> ->
                    [control(Owner, T, <<"pause">>)
                     || #{<<"id">> := T, <<"status">> := S} <- muse_store:list_by_goal(Owner, ?TASKS, Id),
                        not muse_task:is_terminal(S), S =/= <<"paused">>];
                _ -> ok
            end,
            muse_events:emit(Owner, {goal, Id}),
            {ok, Saved}
    end.

-spec set_milestone_done(owner(), binary(), binary(), boolean()) -> {ok, map()} | error().
set_milestone_done(Owner, GoalId, MilestoneId, Done) ->
    Update = fun(#{<<"milestones">> := Ms} = Goal) ->
                     case lists:any(fun(#{<<"id">> := M}) -> M =:= MilestoneId end, Ms) of
                         false -> abort;
                         true ->
                             {ok, Goal#{<<"milestones">> =>
                                            [case M of
                                                 #{<<"id">> := MilestoneId} -> M#{<<"done">> => Done};
                                                 _ -> M
                                             end || M <- Ms]}}
                     end;
                (_) -> abort
             end,
    case muse_store:update(Owner, <<"goals">>, GoalId, Update) of
        undefined -> {error, {404, <<"Goal or milestone not found">>}};
        Saved -> muse_events:emit(Owner, {goal, GoalId}), {ok, Saved}
    end.

%% Notifications and artifacts

%% @doc Insert a notification once per key (id = sha256hex(Key)).
-spec notify(owner(), binary(), binary(), binary() | undefined, binary() | undefined) -> ok.
notify(Owner, Title, Body, TaskId, Key) ->
    Id = case Key of undefined -> muse_ids:uuid(); _ -> muse_ids:sha256hex(Key) end,
    N0 = #{<<"id">> => Id, <<"title">> => Title, <<"body">> => Body,
           <<"createdAt">> => muse_time:now_iso(), <<"read">> => false},
    N = case TaskId of undefined -> N0; _ -> N0#{<<"taskId">> => TaskId} end,
    case muse_store:insert_if_absent(Owner, <<"notifications">>, N) of
        undefined -> ok;
        _ -> muse_events:emit(Owner, {notification, Id})
    end,
    ok.

%% @doc Save (overwrite by key) a task artifact; id = sha256hex(TaskId:Key).
-spec artifact(owner(), map(), binary(), binary(), binary(), map(), binary()) -> map().
artifact(Owner, #{<<"id">> := TaskId}, Kind, Title, Summary, Data, Key) ->
    muse_store:put(Owner, <<"agent-artifacts">>,
                   #{<<"id">> => muse_ids:sha256hex(<<TaskId/binary, ":", Key/binary>>),
                     <<"taskId">> => TaskId, <<"kind">> => Kind, <<"title">> => Title,
                     <<"summary">> => Summary, <<"data">> => Data,
                     <<"createdAt">> => muse_time:now_iso()}).

%% Task execution (runs in the executor process; throws on failure)

%% @doc Propose an external write from inside a task (spec §5.11). Returns
%% the proposal; `succeeded` means an earlier run's approval already ran.
-spec prepare(owner(), map(), map(), binary(), muse_task_run:ctx()) -> map().
prepare(Owner, #{<<"id">> := TaskId, <<"state">> := State}, Input, Key, Ctx) ->
    guard(Ctx),
    ConnId = case muse_workspace:connection(Owner) of
                 #{id := C} -> C;
                 undefined -> null
             end,
    ConnId =:= maps:get(<<"connectionId">>, State, null) orelse
        fail(<<"Google connection changed during this task. Start a new task using the current account.">>),
    Proposal = must(muse_actions:propose(Owner, Input, <<TaskId/binary, ":", Key/binary>>, TaskId)),
    #{<<"id">> := ActionId, <<"status">> := Status} = Proposal,
    case Status of
        <<"succeeded">> ->
            Proposal;
        _ when Status =/= <<"awaiting_review">>, Status =/= <<"executing">> ->
            fail(<<"Reviewed action ", Status/binary, ": ",
                   (error_or(Proposal, <<"No further action was taken">>))/binary>>);
        _ ->
            _ = try checkpoint(Ctx, #{<<"actionId">> => ActionId})
            catch throw:{lost_lease, _} = Lost ->
                _ = case muse_store:get(Owner, ?TASKS, TaskId) of
                    #{<<"status">> := S} when Status =:= <<"awaiting_review">>,
                                              (S =:= <<"paused">> orelse S =:= <<"cancelled">>) ->
                        _ = muse_actions:decide(Owner, ActionId, maps:get(<<"hash">>, Proposal), deny);
                    _ -> ok
                end,
                throw(Lost)
            end,
            Status =:= <<"awaiting_review">> andalso
                event(Ctx, <<"approval">>, maps:get(<<"title">>, Proposal),
                      <<"Review prepared for ", (maps:get(<<"account">>, Proposal, <<"the connected account">>))/binary>>),
            Proposal
    end.

%% @doc The worker's task handler (spec §5.8).
-spec execute(owner(), map(), muse_task_run:ctx()) -> map().
execute(Owner, #{<<"attempts">> := Attempts, <<"prompt">> := Prompt} = Task0, Ctx) ->
    event(Ctx, <<"status">>, case Attempts of 1 -> <<"Started working">>; _ -> <<"Resumed work">> end, Prompt),
    case approval_gate(Owner, Task0, Ctx) of
        {stop, Patch} -> Patch;
        {continue, Task} ->
            case maps:get(<<"kind">>, Task) of
                <<"document">> -> muse_document_flow:run(Owner, Task, Ctx);
                <<"monitor">> -> muse_monitors:run(Owner, Task, Ctx);
                <<"finance">> -> finance(Owner, Task, Ctx);
                _ -> muse_task_runner:run(Owner, Task, Ctx)
            end
    end.

approval_gate(Owner, #{<<"kind">> := Kind, <<"state">> := State} = Task, Ctx) ->
    case maps:get(<<"actionId">>, Task, null) of
        ActionId when is_binary(ActionId) ->
            case muse_store:get(Owner, <<"actions">>, ActionId) of
                undefined ->
                    fail(<<"The linked review could not be found">>);
                #{<<"status">> := <<"succeeded">>} = Action ->
                    Result = maps:get(<<"result">>, Action, null),
                    event(Ctx, <<"result">>, <<"Approved action completed">>, text_or(Result, <<>>)),
                    case Kind of
                        <<"document">> ->
                            {stop, finish(Task, Ctx, text_or(Result, <<"Reply completed">>))};
                        _ ->
                            {continue, checkpoint(Ctx, #{<<"state">> => State#{<<"approvalResult">> => Result},
                                                         <<"actionId">> => null})}
                    end;
                #{<<"status">> := S} when S =:= <<"awaiting_review">>; S =:= <<"executing">> ->
                    {stop, #{<<"status">> => <<"waiting_approval">>}};
                #{<<"status">> := S} = Action ->
                    fail(<<"Reviewed action ", S/binary, ": ",
                           (error_or(Action, <<"No further action was taken">>))/binary>>)
            end;
        _ ->
            {continue, Task}
    end.

finance(Owner, #{<<"id">> := TaskId, <<"input">> := Input} = Task, Ctx) ->
    event(Ctx, <<"step">>, <<"Analyzing the imported transactions">>, <<>>),
    Csv = case maps:get(<<"csv">>, Input, undefined) of
              C when is_binary(C) -> C;
              Other -> {error, [TypeMsg | _]} = muse_validate:check({string, #{}}, Other), fail(TypeMsg)
          end,
    Data = case muse_finance:analyze(Csv) of
               {ok, D} -> D;
               {error, Msg} -> fail(Msg)
           end,
    Summary = muse_finance:summary(Data),
    #{<<"id">> := ArtifactId} = artifact(Owner, Task, <<"finance">>, <<"Spending tracker">>, Summary, Data,
                                         <<"finance">>),
    #{<<"count">> := Count, <<"period">> := #{<<"from">> := From, <<"to">> := To}} = Data,
    Task1 = checkpoint(Ctx, #{<<"artifactIds">> => [ArtifactId],
                              <<"evidence">> => [#{<<"id">> => TaskId, <<"kind">> => <<"user">>,
                                                   <<"title">> => <<"Your transaction CSV">>,
                                                   <<"excerpt">> => iolist_to_binary(
                                                                      [integer_to_binary(Count), " rows; ",
                                                                       From, " through ", To])}]}),
    finish(Task1, Ctx, Summary).

%% @doc Complete the task: every plan step succeeded.
-spec finish(map(), muse_task_run:ctx(), binary()) -> map().
finish(#{<<"plan">> := Plan}, Ctx, Result) ->
    guard(Ctx),
    event(Ctx, <<"result">>, <<"Work completed">>, Result),
    #{<<"status">> => <<"succeeded">>, <<"result">> => Result,
      <<"plan">> => [S#{<<"status">> => <<"succeeded">>} || S <- Plan]}.

%% @doc Notifications, goal progress and monitor pausing after a run has
%% committed (spec §5.9). Idempotent; maintenance re-runs it.
-spec publish_outcome(owner(), map()) -> ok.
publish_outcome(Owner, #{<<"id">> := Id}) ->
    case muse_store:get(Owner, ?TASKS, Id) of
        undefined -> ok;
        Task -> publish(Owner, Task)
    end.

publish(Owner, #{<<"id">> := Id, <<"status">> := Status, <<"title">> := Title} = Task) ->
    case Status of
        <<"succeeded">> ->
            notify(Owner, Title, text_or(maps:get(<<"result">>, Task, null), <<"Work completed">>), Id,
                   <<"task-done:", Id/binary>>),
            case {maps:get(<<"goalId">>, Task, undefined), maps:get(<<"milestoneId">>, Task, undefined)} of
                {GoalId, undefined} when is_binary(GoalId) -> append_milestone(Owner, GoalId, Task, 8);
                _ -> ok
            end;
        <<"failed">> ->
            notify(Owner, <<"Task needs attention">>, text_or(maps:get(<<"error">>, Task, null), Title), Id,
                   <<"task-error:", Id/binary, ":", (integer_to_binary(maps:get(<<"attempts">>, Task, 0)))/binary>>);
        <<"waiting_input">> ->
            Question = maps:get(<<"question">>, Task, null),
            notify(Owner, <<"Your details are needed">>, text_or(Question, Title), Id,
                   <<"input:", Id/binary, ":", (muse_ids:sha256hex(text_or(Question, <<>>)))/binary>>);
        <<"waiting_approval">> ->
            ActionKey = case maps:get(<<"actionId">>, Task, null) of
                            A when is_binary(A) -> A;
                            _ -> <<"undefined">>
                        end,
            notify(Owner, <<"Ready for your review">>, Title, Id, <<"review:", ActionKey/binary>>);
        _ ->
            ok
    end,
    Error = maps:get(<<"error">>, Task, null),
    case maps:get(<<"notice">>, maps:get(<<"state">>, Task, #{}), null) of
        #{<<"title">> := NT, <<"body">> := NB, <<"key">> := NK}
          when is_binary(NT), is_binary(NB), is_binary(NK),
               (Status =:= <<"scheduled">> orelse (Status =:= <<"paused">> andalso is_binary(Error))) ->
            notify(Owner, NT, NB, Id, NK);
        _ ->
            ok
    end,
    case Task of
        #{<<"kind">> := <<"monitor">>, <<"status">> := <<"paused">>} when is_binary(Error) ->
            _ = muse_store:cas(Owner, <<"monitors">>, monitor_id(Task),
                               #{<<"status">> => <<"active">>, <<"error">> => Error},
                               #{<<"status">> => <<"paused">>}),
            muse_events:emit(Owner, {monitor, monitor_id(Task)});
        _ ->
            ok
    end,
    ok.

append_milestone(_Owner, _GoalId, _Task, 0) ->
    ok;
append_milestone(Owner, GoalId, #{<<"id">> := Id, <<"title">> := Title} = Task, N) ->
    case muse_store:get(Owner, <<"goals">>, GoalId) of
        undefined -> ok;
        #{<<"milestones">> := Ms} ->
            case lists:any(fun(#{<<"id">> := M}) -> M =:= Id end, Ms) of
                true -> ok;
                false ->
                    %% jsonb array containment: an equal-or-larger list matches,
                    %% so a lost race (another append) retries.
                    case muse_store:cas(Owner, <<"goals">>, GoalId, #{<<"milestones">> => Ms},
                                        #{<<"milestones">> => Ms ++ [#{<<"id">> => Id, <<"title">> => Title,
                                                                      <<"done">> => true}]}) of
                        undefined -> append_milestone(Owner, GoalId, Task, N - 1);
                        _ -> muse_events:emit(Owner, {goal, GoalId}), ok
                    end
            end
    end.

%% Memories, identity, notifications, sample page (engine routes, spec §12.1)

-spec memories(owner()) -> [map()].
memories(Owner) ->
    muse_store:list(Owner, <<"memories">>).

-spec add_memory(owner(), term()) -> {ok, map()} | error().
add_memory(Owner, Raw) ->
    maybe
        {ok, #{<<"text">> := Text} = Input} ?= muse_validate:parse(muse_task:memory_schema(), Raw),
        Memory = #{<<"id">> => muse_ids:uuid(), <<"text">> => Text,
                   <<"source">> => maps:get(<<"source">>, Input, <<"You">>),
                   <<"createdAt">> => muse_time:now_iso()},
        _ = muse_store:put(Owner, <<"memories">>, Memory),
        muse_events:emit(Owner, {memory, maps:get(<<"id">>, Memory)}),
        {ok, Memory}
    end.

-spec update_memory(owner(), binary(), term()) -> {ok, map()} | error().
update_memory(Owner, Id, Raw) ->
    maybe
        {ok, Input} ?= muse_validate:parse(muse_task:memory_schema(), Raw),
        #{} = Saved ?= muse_store:cas(Owner, <<"memories">>, Id, #{}, Input),
        muse_events:emit(Owner, {memory, Id}),
        {ok, Saved}
    else
        undefined -> {error, {404, <<"Memory not found">>}};
        {error, _} = E -> E
    end.

-spec forget_memory(owner(), binary()) -> ok | error().
forget_memory(Owner, Id) ->
    case muse_store:take(Owner, <<"memories">>, Id) of
        undefined -> {error, {404, <<"Memory not found">>}};
        _ -> muse_events:emit(Owner, {memory, Id}), ok
    end.

-spec set_identity(owner(), term()) -> {ok, map()} | error().
set_identity(Owner, Raw) ->
    maybe
        {ok, Input} ?= muse_validate:parse(muse_task:identity_schema(), Raw),
        ok = ensure(Owner),
        #{} = Saved ?= muse_store:cas(Owner, <<"agent-settings">>, <<"identity">>, #{}, Input),
        muse_events:emit(Owner, {identity, <<"identity">>}),
        {ok, Saved}
    else
        undefined -> {error, {409, <<"Agent identity changed; refresh and try again">>}};
        {error, _} = E -> E
    end.

-spec notifications(owner()) -> [map()].
notifications(Owner) ->
    muse_store:list(Owner, <<"notifications">>).

-spec read_notification(owner(), binary()) -> {ok, map()} | error().
read_notification(Owner, Id) ->
    case muse_store:cas(Owner, <<"notifications">>, Id, #{}, #{<<"read">> => true}) of
        undefined -> {error, {404, <<"Notification not found">>}};
        Saved -> muse_events:emit(Owner, {notification, Id}), {ok, Saved}
    end.

%% @doc Sample mode's editable availability page for monitor demos.
-spec set_sample_page(owner(), binary()) -> ok | error().
set_sample_page(Owner, Text) ->
    case muse_config:get(mode) of
        sample ->
            _ = muse_store:put(Owner, <<"sample-pages">>, #{<<"id">> => <<"availability">>, <<"text">> => Text}),
            ok;
        live ->
            {error, {404, <<"Not found">>}}
    end.

%% Helpers for code running inside a task

%% @doc Unwrap `{ok, V}`; any error fails the task with its message.
-spec must({ok, T} | {error, term()}) -> T.
must({ok, V}) -> V;
must({error, {Status, Msg}}) when is_integer(Status), is_binary(Msg) -> fail(Msg);
must({error, {outcome_unknown, Msg}}) -> fail(Msg);
must({error, {internal, Msg}}) -> fail(Msg);
must({error, Msg}) when is_binary(Msg) -> fail(Msg);
must({error, Other}) -> error({unexpected_error, Other}).

-spec fail(binary()) -> no_return().
fail(Msg) ->
    throw({task_failed, Msg}).

guard(#{guard := G}) -> G().
checkpoint(#{checkpoint := C}, Patch) -> C(Patch).
event(#{event := E}, Kind, Title, Detail) -> E(Kind, Title, Detail).

%% `String(task.input.monitorId)`.
monitor_id(#{<<"input">> := #{<<"monitorId">> := Id}}) when is_binary(Id) -> Id;
monitor_id(_) -> <<"undefined">>.

text_or(V, _) when is_binary(V) -> V;
text_or(_, Default) -> Default.

error_or(Map, Default) ->
    text_or(maps:get(<<"error">>, Map, null), Default).
