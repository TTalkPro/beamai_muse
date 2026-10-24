%% @doc One leased run of one task (OpenMuse worker.ts `run`, engine spec §4.2).
%%
%% The run process claims the task with a CAS (status + lease), then starts
%% a linked executor process for the task handler and stays in charge of:
%% - the heartbeat (every lease/3; a failed renewal aborts the run),
%% - aborts from `muse_task_worker:abort/1` (pause/cancel/control),
%% - the outcome: success writes the result and clears the lease; a lost
%%   lease or abort puts the task back to `queued` (usually a no-op because
%%   the controller already moved it); any other failure marks it `failed`,
%% - the `runs` record, and finally `publish_outcome` (the settle hook).
%%
%% Aborting kills the executor: with Erlang processes that is the
%% AbortSignal. Long-running tools link to the executor so they die with it.
-module(muse_task_run).
-behaviour(gen_server).

-export([start_link/2, abort/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([ctx/0]).

-type ctx() :: #{owner := binary(),
                 task_id := binary(),
                 lease_id := binary(),
                 exec_pid := pid(),
                 guard := fun(() -> ok),
                 checkpoint := fun((map()) -> map()),
                 event := fun((binary(), binary(), binary()) -> ok),
                 aborted := fun(() -> boolean())}.

-define(FLAGS, muse_task_flags).

%% @doc Claim and run `Task` (the record as scanned by the worker). Returns
%% `ignore` when another worker won the claim.
-spec start_link(binary(), map()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Owner, Task) ->
    gen_server:start_link(?MODULE, {Owner, Task}, []).

-spec abort(pid()) -> ok.
abort(Pid) ->
    gen_server:cast(Pid, abort).

%% gen_server

init({Owner, Prev}) ->
    process_flag(trap_exit, true),
    LeaseMs = lease_ms(),
    LeaseId = muse_ids:uuid(),
    #{<<"id">> := TaskId, <<"status">> := PrevStatus} = Prev,
    Expected0 = #{<<"status">> => PrevStatus, <<"leaseId">> => maps:get(<<"leaseId">>, Prev, null)},
    Expected = case PrevStatus of
                   <<"running">> -> Expected0#{<<"leaseUntil">> => maps:get(<<"leaseUntil">>, Prev, null)};
                   _ -> Expected0
               end,
    Now = muse_time:now_ms(),
    Patch = #{<<"status">> => <<"running">>,
              <<"leaseId">> => LeaseId,
              <<"leaseUntil">> => muse_time:to_iso(Now + LeaseMs),
              <<"updatedAt">> => muse_time:to_iso(Now),
              <<"attempts">> => maps:get(<<"attempts">>, Prev, 0) + 1},
    case muse_store:cas(Owner, <<"tasks">>, TaskId, Expected, Patch) of
        undefined ->
            ignore;
        Task ->
            muse_events:emit(Owner, {task, TaskId}),
            StartedAt = muse_time:to_iso(Now),
            _ = muse_store:put(Owner, <<"runs">>, #{<<"id">> => LeaseId, <<"taskId">> => TaskId,
                                                     <<"startedAt">> => StartedAt,
                                                     <<"status">> => <<"running">>}),
            Self = self(),
            Exec = spawn_link(fun() -> execute(Self, Owner, Task, LeaseId) end),
            erlang:send_after(max(10, LeaseMs div 3), self(), heartbeat),
            {ok, #{owner => Owner, task_id => TaskId, lease_id => LeaseId, lease_ms => LeaseMs,
                   started_at => StartedAt, exec => Exec, result => undefined, aborted => false}}
    end.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(abort, State) ->
    {noreply, do_abort(State)}.

handle_info(heartbeat, #{aborted := true} = State) ->
    {noreply, State};
handle_info(heartbeat, #{owner := O, task_id := T, lease_id := L, lease_ms := Ms} = State) ->
    Renewed = try muse_store:cas(O, <<"tasks">>, T, #{<<"leaseId">> => L, <<"status">> => <<"running">>},
                                 #{<<"leaseUntil">> => muse_time:to_iso(muse_time:now_ms() + Ms)})
              catch _:_ -> undefined
              end,
    case Renewed of
        undefined -> {noreply, do_abort(State)};
        _ ->
            erlang:send_after(max(10, Ms div 3), self(), heartbeat),
            {noreply, State}
    end;
handle_info({exec_result, Result}, State) ->
    {noreply, State#{result := Result}};
handle_info({'EXIT', Exec, Reason}, #{exec := Exec} = State) ->
    settle(outcome(Reason, State), State),
    {stop, normal, State};
handle_info({'EXIT', _Other, _Reason}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Internal

do_abort(#{aborted := true} = State) ->
    State;
do_abort(#{exec := Exec, lease_id := L} = State) ->
    ets:insert(?FLAGS, {L, aborted}),
    exit(Exec, kill),
    State#{aborted := true}.

outcome(_Reason, #{aborted := true}) -> lost;
outcome(normal, #{result := {done, Patch}}) -> {done, Patch};
outcome(normal, #{result := lost}) -> lost;
outcome(normal, #{result := {failed, Detail}}) -> {failed, Detail};
outcome(_Reason, _State) -> {failed, <<"Task execution failed">>}.

settle(Outcome, #{owner := O, task_id := T, lease_id := L, started_at := StartedAt} = State) ->
    Fence = #{<<"leaseId">> => L, <<"status">> => <<"running">>},
    Final = case Outcome of
                {done, Patch} ->
                    Now = muse_time:now_iso(),
                    case muse_store:cas(O, <<"tasks">>, T, Fence,
                                        Patch#{<<"leaseId">> => null, <<"leaseUntil">> => null,
                                               <<"updatedAt">> => Now}) of
                        undefined -> lost;
                        Saved ->
                            _ = muse_store:put(O, <<"runs">>,
                                               #{<<"id">> => L, <<"taskId">> => T, <<"startedAt">> => StartedAt,
                                                 <<"finishedAt">> => Now,
                                                 <<"status">> => maps:get(<<"status">>, Saved)}),
                            done
                    end;
                Other ->
                    Other
            end,
    case Final of
        done -> ok;
        lost ->
            _ = muse_store:cas(O, <<"tasks">>, T, Fence,
                               #{<<"status">> => <<"queued">>, <<"leaseId">> => null, <<"leaseUntil">> => null}),
            finish_run(O, L, <<"interrupted">>);
        {failed, Detail} ->
            _ = catch muse_events_log:append(O, T, #{<<"kind">> => <<"error">>,
                                                    <<"title">> => <<"Task needs attention">>,
                                                    <<"detail">> => Detail}),
            _ = muse_store:cas(O, <<"tasks">>, T, Fence,
                               #{<<"status">> => <<"failed">>, <<"error">> => Detail,
                                 <<"leaseId">> => null, <<"leaseUntil">> => null,
                                 <<"updatedAt">> => muse_time:now_iso()}),
            finish_run(O, L, case maps:get(aborted, State) of true -> <<"interrupted">>; false -> <<"failed">> end)
    end,
    ets:delete(?FLAGS, L),
    muse_events:emit(O, {task, T}),
    case muse_store:get(O, <<"tasks">>, T) of
        undefined -> ok;
        Settled ->
            try muse_agent_service:publish_outcome(O, Settled)
            catch Class:Reason:St ->
                logger:warning("publishing task ~ts outcome failed: ~p:~p ~p", [T, Class, Reason, St])
            end
    end.

finish_run(O, L, Status) ->
    _ = muse_store:cas(O, <<"runs">>, L, #{<<"status">> => <<"running">>},
                       #{<<"status">> => Status, <<"finishedAt">> => muse_time:now_iso()}),
    ok.

%% Executor process

execute(Run, Owner, Task, LeaseId) ->
    TaskId = maps:get(<<"id">>, Task),
    Ctx = ctx(Owner, TaskId, LeaseId),
    Result = try muse_agent_service:execute(Owner, Task, Ctx) of
                 Patch when is_map(Patch) -> {done, Patch}
             catch
                 throw:{lost_lease, _} -> lost;
                 throw:{task_failed, Msg} -> {failed, Msg};
                 Class:Reason:St ->
                     logger:error("task ~ts crashed: ~p:~p ~p", [TaskId, Class, Reason, St]),
                     {failed, <<"Task execution failed">>}
             end,
    Run ! {exec_result, Result}.

-spec ctx(binary(), binary(), binary()) -> ctx().
ctx(Owner, TaskId, LeaseId) ->
    Aborted = fun() -> ets:member(?FLAGS, LeaseId) end,
    Guard = fun() ->
                case {Aborted(), muse_store:get(Owner, <<"tasks">>, TaskId)} of
                    {false, #{<<"leaseId">> := LeaseId, <<"status">> := <<"running">>}} -> ok;
                    _ -> throw({lost_lease, TaskId})
                end
            end,
    Checkpoint = fun(Patch) ->
                     Aborted() andalso throw({lost_lease, TaskId}),
                     case muse_store:cas(Owner, <<"tasks">>, TaskId,
                                         #{<<"leaseId">> => LeaseId, <<"status">> => <<"running">>},
                                         Patch#{<<"updatedAt">> => muse_time:now_iso()}) of
                         undefined -> throw({lost_lease, TaskId});
                         Next -> muse_events:emit(Owner, {task, TaskId}), Next
                     end
                 end,
    Event = fun(Kind, Title, Detail) ->
                Guard(),
                {ok, Ev} = muse_events_log:append(Owner, TaskId, #{<<"kind">> => Kind, <<"title">> => Title,
                                                                   <<"detail">> => Detail}),
                muse_events:emit(Owner, {run_event, TaskId, Ev}),
                ok
            end,
    #{owner => Owner, task_id => TaskId, lease_id => LeaseId, exec_pid => self(),
      guard => Guard, checkpoint => Checkpoint, event => Event, aborted => Aborted}.

lease_ms() ->
    application:get_env(muse_engine, lease_ms, 60000).
