%% @doc Page watches (OpenMuse service.ts monitors, engine spec §5.5).
%%
%% A monitor owns one `monitor` task that the worker re-runs on schedule.
%% Each run observes the page (the owner's browser, or the sample availability
%% page), compares it with the last observation and schedules the next
%% check. Failures back off 2^n minutes (capped at 60); the fifth failure in
%% a row pauses the watch. Alerts are deduplicated by notice key.
-module(muse_monitors).

-export([create/3, activate/2, control/3, follow_task_control/3, run/3]).

-type owner() :: binary().
-type error() :: {error, {pos_integer(), binary()}}.

-define(MONITORS, <<"monitors">>).
-define(TASKS, <<"tasks">>).

%% @doc `createMonitor(owner, raw, idempotencyKey?)`.
-spec create(owner(), term(), binary() | undefined) -> {ok, map()} | error().
create(Owner, Raw, Key) ->
    maybe
        {ok, #{<<"url">> := Url, <<"condition">> := Cond, <<"value">> := Value} = Input} ?=
            muse_validate:parse(muse_task:monitor_schema(), Raw),
        ok ?= check_url(Url),
        Id = case Key of
                 undefined -> muse_ids:uuid();
                 _ -> muse_ids:sha256hex(<<"monitor:", Key/binary>>)
             end,
        undefined ?= muse_store:get(Owner, ?MONITORS, Id),
        Prompt = <<"Watch ", Url/binary, " for ", Cond/binary,
                   (case Value of <<>> -> <<>>; _ -> <<": ", Value/binary>> end)/binary>>,
        {ok, #{<<"id">> := TaskId}} ?=
            muse_agent_service:create_task(Owner, #{<<"kind">> => <<"monitor">>,
                                                    <<"title">> => maps:get(<<"title">>, Input),
                                                    <<"prompt">> => Prompt,
                                                    <<"input">> => #{<<"monitorId">> => Id}},
                                           <<"monitor:", Id/binary>>, true),
        Monitor = Input#{<<"id">> => Id, <<"taskId">> => TaskId, <<"status">> => <<"active">>,
                         <<"nextCheckAt">> => muse_time:now_iso(), <<"checks">> => 0},
        _ = muse_store:insert_if_absent(Owner, ?MONITORS, Monitor),
        _ = activate(Owner, Monitor),
        muse_events:emit(Owner, {monitor, Id}),
        {ok, Monitor}
    else
        #{<<"id">> := _} = Existing ->
            _ = activate(Owner, Existing),
            {ok, Existing};
        {error, _} = Error ->
            Error
    end.

check_url(Url) ->
    Mode = muse_config:get(mode),
    #{scheme := Scheme} = Parsed = uri_string:parse(Url),
    HasUser = maps:is_key(userinfo, Parsed),
    if
        Scheme =:= <<"sample">>, Mode =/= sample ->
            {error, {422, <<"Sample sources are unavailable in live workspaces">>}};
        not (Scheme =:= <<"https">> orelse Scheme =:= <<"http">> orelse Scheme =:= <<"sample">>) orelse HasUser ->
            {error, {422, <<"Use a public HTTP(S) page">>}};
        Scheme =:= <<"sample">>, Url =/= <<"sample://availability">> ->
            {error, {422, <<"Unknown sample source">>}};
        true ->
            ok
    end.

%% @doc Queue the monitor's held task once (new watch, or resume handshake).
-spec activate(owner(), map()) -> map() | undefined.
activate(Owner, #{<<"status">> := <<"active">>, <<"taskId">> := TaskId}) ->
    case muse_store:get(Owner, ?TASKS, TaskId) of
        #{<<"status">> := <<"paused">>, <<"state">> := State} ->
            Result =
                case State of
                    #{<<"resumingMonitor">> := true} ->
                        muse_store:cas(Owner, ?TASKS, TaskId,
                                       #{<<"status">> => <<"paused">>, <<"state">> => #{<<"resumingMonitor">> => true}},
                                       #{<<"status">> => <<"queued">>, <<"nextRunAt">> => muse_time:now_iso(),
                                         <<"leaseId">> => null, <<"leaseUntil">> => null, <<"error">> => null,
                                         <<"state">> => State#{<<"resumingMonitor">> => false, <<"failures">> => 0,
                                                               <<"notice">> => null}});
                    #{<<"initializingMonitor">> := true} ->
                        muse_store:cas(Owner, ?TASKS, TaskId,
                                       #{<<"status">> => <<"paused">>, <<"attempts">> => 0,
                                         <<"state">> => #{<<"initializingMonitor">> => true}},
                                       #{<<"status">> => <<"queued">>,
                                         <<"state">> => State#{<<"initializingMonitor">> => false}});
                    _ ->
                        undefined
                end,
            Result =/= undefined andalso muse_events:emit(Owner, {task, TaskId}),
            Result;
        _ ->
            undefined
    end;
activate(_Owner, _Monitor) ->
    undefined.

%% @doc pause | resume | stop | check (spec §5.5 controlMonitor).
-spec control(owner(), binary(), binary()) -> {ok, map()} | error().
control(Owner, Id, Action) ->
    case muse_store:get(Owner, ?MONITORS, Id) of
        undefined ->
            {error, {404, <<"Monitor not found">>}};
        #{<<"status">> := <<"stopped">>} when Action =/= <<"stop">> ->
            {error, {409, <<"Create a new watch to restart this stopped monitor">>}};
        #{<<"taskId">> := TaskId} = Monitor when Action =:= <<"pause">>; Action =:= <<"stop">> ->
            Status = case Action of <<"pause">> -> <<"paused">>; _ -> <<"stopped">> end,
            Saved = muse_store:cas(Owner, ?MONITORS, Id, #{},
                                   #{<<"status">> => Status, <<"nextCheckAt">> => muse_time:now_iso()}),
            maybe
                {ok, _} ?= muse_agent_service:control(Owner, TaskId, case Action of
                                                                         <<"pause">> -> <<"pause">>;
                                                                         _ -> <<"cancel">>
                                                                     end),
                muse_events:emit(Owner, {monitor, Id}),
                {ok, case Saved of undefined -> Monitor; _ -> Saved end}
            end;
        Monitor when Action =:= <<"resume">>; Action =:= <<"check">> ->
            resume(Owner, Monitor, maps:get(<<"status">>, Monitor), 2);
        _ ->
            {error, {422, <<"Invalid option: expected one of \"pause\"|\"resume\"|\"stop\"|\"check\"">>}}
    end.

resume(_Owner, _Monitor, _Status, 0) ->
    changed();
resume(Owner, #{<<"id">> := Id, <<"taskId">> := TaskId} = Monitor, MonitorStatus, Attempts) ->
    {ok, Task} = muse_agent_service:get_task(Owner, TaskId),
    case Task of
        #{<<"status">> := <<"cancelled">>} ->
            changed();
        #{<<"status">> := <<"paused">>, <<"state">> := State} ->
            resume_paused(Owner, Monitor, Task, State);
        #{<<"status">> := Status} ->
            %% Only activate the monitor we read, so a concurrent stop is never undone.
            case muse_store:cas(Owner, ?MONITORS, Id, #{<<"status">> => MonitorStatus},
                                #{<<"status">> => <<"active">>, <<"nextCheckAt">> => muse_time:now_iso()}) of
                undefined -> changed();
                Saved ->
                    muse_task_worker:abort(TaskId),
                    %% updatedAt fences out a whole run finishing in between.
                    Queued = muse_store:cas(Owner, ?TASKS, TaskId,
                                            #{<<"status">> => Status,
                                              <<"leaseId">> => maps:get(<<"leaseId">>, Task, null),
                                              <<"updatedAt">> => maps:get(<<"updatedAt">>, Task)},
                                            #{<<"status">> => <<"queued">>, <<"nextRunAt">> => muse_time:now_iso(),
                                              <<"leaseId">> => null, <<"leaseUntil">> => null, <<"error">> => null,
                                              <<"state">> => (maps:get(<<"state">>, Task))#{<<"failures">> => 0,
                                                                                         <<"notice">> => null}}),
                    case Queued of
                        undefined -> resume(Owner, Monitor, <<"active">>, Attempts - 1);
                        _ ->
                            muse_events:emit(Owner, {task, TaskId}),
                            muse_events:emit(Owner, {monitor, Id}),
                            {ok, Saved}
                    end
            end
    end.

%% Mark the paused task before activating the monitor so no worker can claim
%% it in between; undo both halves if the activation does not take.
resume_paused(Owner, #{<<"id">> := Id, <<"status">> := MonitorStatus} = Monitor, Task, State) ->
    #{<<"id">> := TaskId} = Task,
    Marked = muse_store:cas(Owner, ?TASKS, TaskId,
                            #{<<"status">> => <<"paused">>, <<"leaseId">> => maps:get(<<"leaseId">>, Task, null)},
                            #{<<"state">> => State#{<<"resumingMonitor">> => true}}),
    case Marked of
        undefined ->
            changed();
        _ ->
            Activated = muse_store:cas(Owner, ?MONITORS, Id, #{<<"status">> => MonitorStatus},
                                       #{<<"status">> => <<"active">>, <<"nextCheckAt">> => muse_time:now_iso(),
                                         <<"error">> => null}),
            Saved = case Activated of undefined -> muse_store:get(Owner, ?MONITORS, Id); _ -> Activated end,
            Active = is_map(Saved) andalso maps:get(<<"status">>, Saved) =:= <<"active">>,
            case Active andalso activate(Owner, Saved) =/= undefined of
                true ->
                    muse_events:emit(Owner, {monitor, Id}),
                    {ok, Saved};
                false ->
                    Unmarked = muse_store:cas(Owner, ?TASKS, TaskId,
                                              #{<<"status">> => <<"paused">>,
                                                <<"state">> => #{<<"resumingMonitor">> => true}},
                                              #{<<"state">> => State#{<<"resumingMonitor">> => false}}),
                    Latest = maps:get(<<"status">>, muse_store:get(Owner, ?TASKS, TaskId)),
                    case Unmarked =:= undefined andalso Active
                        andalso lists:member(Latest, [<<"queued">>, <<"running">>, <<"scheduled">>]) of
                        true ->
                            {ok, Saved};
                        false ->
                            Activated =/= undefined andalso
                                muse_store:cas(Owner, ?MONITORS, Id, #{<<"status">> => <<"active">>},
                                               #{<<"status">> => MonitorStatus,
                                                 <<"error">> => maps:get(<<"error">>, Monitor, null)}),
                            changed()
                    end
            end
    end.

changed() ->
    {error, {409, <<"The watch changed while updating. Try again.">>}}.

%% @doc The monitor half of task control (pause/cancel/retry/resume).
-spec follow_task_control(owner(), binary(), binary()) -> boolean().
follow_task_control(Owner, MonitorId, Action) ->
    Status = case Action of
                 <<"cancel">> -> <<"stopped">>;
                 <<"pause">> -> <<"paused">>;
                 _ -> <<"active">>
             end,
    Patch0 = #{<<"status">> => Status, <<"nextCheckAt">> => muse_time:now_iso()},
    %% Clearing the error fences out a failure reconcile that read the task earlier.
    Patch = case Action =:= <<"resume">> orelse Action =:= <<"retry">> of
                true -> Patch0#{<<"error">> => null};
                false -> Patch0
            end,
    _ = muse_store:cas(Owner, ?MONITORS, MonitorId, #{}, Patch),
    muse_events:emit(Owner, {monitor, MonitorId}),
    true.

%% @doc The monitor task handler: observe, or schedule a retry on failure.
-spec run(owner(), map(), muse_task_run:ctx()) -> map().
run(Owner, #{<<"state">> := State} = Task, Ctx) ->
    try
        observe(Owner, Task, Ctx)
    catch
        throw:{task_failed, Detail} ->
            guard(Ctx),
            Failures = number(maps:get(<<"failures">>, State, 0)) + 1,
            Streak = number(maps:get(<<"failureStreak">>, State, 0)) + case Failures of 1 -> 1; _ -> 0 end,
            NextCheckAt = muse_time:to_iso(muse_time:now_ms() + min(60, pow2(Failures)) * 60000),
            MonitorId = monitor_id(Task),
            _ = muse_store:cas(Owner, ?MONITORS, MonitorId, #{<<"status">> => <<"active">>},
                               #{<<"error">> => Detail, <<"nextCheckAt">> => NextCheckAt}),
            muse_events:emit(Owner, {monitor, MonitorId}),
            Paused = Failures >= 5,
            event(Ctx, <<"error">>, case Paused of
                                        true -> <<"Watch paused after repeated failures">>;
                                        false -> <<"Check failed; retry scheduled">>
                                    end, Detail),
            #{<<"status">> => case Paused of true -> <<"paused">>; false -> <<"scheduled">> end,
              <<"error">> => Detail,
              <<"nextRunAt">> => NextCheckAt,
              <<"state">> => State#{<<"failures">> => Failures,
                                    <<"resumingMonitor">> => false,
                                    <<"failureStreak">> => Streak,
                                    <<"notice">> => #{<<"title">> => <<"Watch needs attention">>,
                                                      <<"body">> => Detail,
                                                      <<"key">> => iolist_to_binary(
                                                                     [<<"watch-error:">>, maps:get(<<"id">>, Task), ":",
                                                                      integer_to_binary(Streak), ":",
                                                                      case Paused of true -> "paused"; false -> "retry" end])}}}
    end.

observe(Owner, #{<<"id">> := TaskId, <<"state">> := State, <<"plan">> := Plan} = Task, Ctx) ->
    MonitorId = monitor_id(Task),
    Monitor = case muse_store:get(Owner, ?MONITORS, MonitorId) of
                  undefined -> muse_agent_service:fail(<<"Monitor not found">>);
                  M -> M
              end,
    case maps:get(<<"status">>, Monitor) of
        <<"active">> -> observe_active(Owner, TaskId, State, Plan, Monitor, Ctx);
        <<"paused">> -> #{<<"status">> => <<"paused">>};
        _ -> #{<<"status">> => <<"cancelled">>}
    end.

observe_active(Owner, TaskId, State, Plan, Monitor, Ctx) ->
    #{<<"id">> := Id, <<"url">> := Url, <<"condition">> := Cond, <<"value">> := Value,
      <<"title">> := MonitorTitle, <<"checks">> := Checks, <<"intervalMinutes">> := Interval} = Monitor,
    Obs = fetch(Owner, Url, State, Ctx),
    #{<<"url">> := ObsUrl, <<"title">> := ObsTitle, <<"text">> := Raw} = Obs,
    Text = muse_page_diff:collapse_text(Raw),
    CurrentHash = muse_ids:sha256hex(Text),
    PreviousHash = case maps:get(<<"lastHash">>, State, undefined) of
                       H when is_binary(H) -> H;
                       _ -> maps:get(<<"lastHash">>, Monitor, undefined)
                   end,
    Change = Cond =:= <<"change">>,
    Matched = case Cond of
                  <<"change">> -> is_binary(PreviousHash) andalso PreviousHash =/= CurrentHash;
                  <<"contains">> -> muse_page_diff:matches_contains(Text, Value);
                  _ -> muse_page_diff:matches_price(Text, Value)
              end,
    PreviouslyMatched = maps:get(<<"matched">>, State, false) =:= true,
    Lines = case Change of true -> muse_page_diff:page_lines(Raw); false -> [] end,
    TimelessHash = case Change of
                       true -> muse_ids:sha256hex(muse_page_diff:without_relative_times(Text));
                       false -> undefined
                   end,
    SavedPage = case Matched andalso Change of
                    true -> muse_store:get(Owner, <<"monitor-pages">>, Id);
                    false -> undefined
                end,
    %% Saved lines can run ahead of a lost task outcome; use only the committed baseline.
    Baseline = case SavedPage of
                   #{<<"hash">> := PreviousHash} -> SavedPage;
                   _ -> undefined
               end,
    %% Only relative times changed ("3 minutes ago"): keep watching quietly.
    Quiet = is_map(Baseline) andalso is_binary(maps:get(<<"timelessHash">>, Baseline, undefined))
        andalso maps:get(<<"timelessHash">>, Baseline) =:= TimelessHash,
    ShouldNotify = Matched andalso not Quiet andalso (Change orelse not PreviouslyMatched),
    Diff = case is_map(Baseline) andalso ShouldNotify of
               true -> muse_page_diff:diff_page(maps:get(<<"lines">>, Baseline, []), Lines);
               false -> undefined
           end,
    Changes = case Diff of undefined -> <<>>; _ -> muse_page_diff:describe_page_diff(Diff) end,
    AlertSequence = number(maps:get(<<"alertSequence">>, State, 0)) + case ShouldNotify of true -> 1; false -> 0 end,
    NextCheckAt = muse_time:to_iso(muse_time:now_ms() + Interval * 60000),
    guard(Ctx),
    %% The lease is checked before publishing; monitor control also invalidates it.
    case muse_store:cas(Owner, ?MONITORS, Id, #{<<"status">> => <<"active">>, <<"checks">> => Checks},
                        #{<<"checks">> => Checks + 1, <<"lastCheckedAt">> => muse_time:now_iso(),
                          <<"lastHash">> => CurrentHash, <<"lastValue">> => muse_js:slice(Text, 1000),
                          <<"nextCheckAt">> => NextCheckAt, <<"error">> => null}) of
        undefined -> throw({lost_lease, TaskId});
        _ -> muse_events:emit(Owner, {monitor, Id})
    end,
    Change andalso muse_store:put(Owner, <<"monitor-pages">>,
                                  #{<<"id">> => Id, <<"hash">> => CurrentHash,
                                    <<"timelessHash">> => TimelessHash, <<"lines">> => Lines}),
    event(Ctx, <<"observation">>, case PreviousHash of
                                      undefined -> <<"Saved the first observation">>;
                                      _ -> <<"Checked for changes">>
                                  end, muse_js:slice(Text, 1000)),
    case ShouldNotify of
        true ->
            guard(Ctx),
            event(Ctx, <<"result">>, <<"A meaningful change was found">>,
                  case Changes of <<>> -> muse_js:slice(Text, 500); _ -> Changes end);
        false ->
            ok
    end,
    Count = case Diff of undefined -> <<>>; _ -> muse_page_diff:count_page_diff(Diff) end,
    Result = case {ShouldNotify, Count} of
                 {true, <<>>} -> <<"Change found. A notification is ready.">>;
                 {true, _} -> <<"Change found: ", Count/binary, ". A notification is ready.">>;
                 {false, _} -> <<"Watching. I'll check again on schedule.">>
             end,
    Notice = case ShouldNotify of
                 false -> null;
                 true ->
                     #{<<"title">> => MonitorTitle,
                       <<"body">> => case Changes of
                                         <<>> -> <<"Condition met at ", ObsUrl/binary, ": ", (muse_js:slice(Text, 240))/binary>>;
                                         _ -> <<"Changed at ", ObsUrl/binary, "\n", Changes/binary>>
                                     end,
                       <<"key">> => iolist_to_binary([<<"monitor:">>, Id, ":", integer_to_binary(AlertSequence), ":",
                                                      CurrentHash])}
             end,
    State1 = maps:merge(State, #{<<"lastHash">> => CurrentHash, <<"resumingMonitor">> => false,
                                 <<"matched">> => Matched, <<"alertSequence">> => AlertSequence,
                                 <<"failures">> => 0, <<"notice">> => Notice}),
    State2 = case maps:get(<<"sessionId">>, Obs, undefined) of
                 undefined -> maps:remove(<<"sessionId">>, State1);
                 Sid -> State1#{<<"sessionId">> => Sid}
             end,
    #{<<"status">> => <<"scheduled">>,
      <<"nextRunAt">> => NextCheckAt,
      <<"result">> => Result,
      <<"state">> => State2,
      <<"error">> => null,
      <<"evidence">> => [#{<<"id">> => Id, <<"kind">> => <<"web">>, <<"title">> => ObsTitle, <<"url">> => ObsUrl,
                           <<"excerpt">> => muse_js:slice(Text, 600)}],
      <<"plan">> => [S#{<<"status">> => <<"succeeded">>} || S <- Plan]}.

fetch(Owner, <<"sample://availability">> = Url, _State, _Ctx) ->
    muse_config:get(mode) =:= sample orelse muse_agent_service:fail(<<"Sample source unavailable">>),
    Text = case muse_store:get(Owner, <<"sample-pages">>, <<"availability">>) of
               #{<<"text">> := T} -> T;
               _ -> <<"No tables available. Check again later.">>
           end,
    #{<<"url">> => Url, <<"title">> => <<"Sample dinner availability">>, <<"text">> => Text};
fetch(Owner, Url, State, Ctx) ->
    guard(Ctx),
    Existing = case maps:get(<<"sessionId">>, State, undefined) of
                   S when is_binary(S) -> S;
                   _ -> undefined
               end,
    muse_agent_service:must(muse_browser:observe(Owner, Url, Existing)).

monitor_id(#{<<"input">> := #{<<"monitorId">> := Id}}) when is_binary(Id) -> Id;
monitor_id(_) -> <<"undefined">>.

number(N) when is_number(N) -> N;
number(_) -> 0.

pow2(N) -> 1 bsl min(N, 16).

guard(#{guard := G}) -> G().
event(#{event := E}, Kind, Title, Detail) -> E(Kind, Title, Detail).
