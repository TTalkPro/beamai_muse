%% @doc The task scheduler (OpenMuse worker.ts `TaskWorker`, engine spec §4.1).
%%
%% Every second: record a heartbeat in `system/worker-status/tasks`, scan all
%% tasks (least recently updated first) and start runs for those that are
%% queued, scheduled and due, running with an expired lease (a crashed
%% worker), or waiting for an approval that has been decided or has expired.
%% At most 3 runs per worker; a run outlives the tick that started it.
%%
%% Several workers (nodes) may share the store: claims are CAS-guarded.
-module(muse_task_worker).
-behaviour(gen_server).

-export([start_link/0, abort/1, running/0, tick/0, in_flight/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_RUNS, 3).
-define(FLAGS, muse_task_flags).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Abort the local run of `TaskId`, if any (pause/cancel/control).
-spec abort(binary()) -> ok.
abort(TaskId) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:cast(?MODULE, {abort, TaskId})
    end.

-spec running() -> boolean().
running() ->
    whereis(?MODULE) =/= undefined.

%% @doc Run one scheduling pass now (tests); returns the started task ids.
-spec tick() -> [binary()].
tick() ->
    gen_server:call(?MODULE, tick, 30000).

-spec in_flight() -> [binary()].
in_flight() ->
    gen_server:call(?MODULE, in_flight).

%% gen_server

init([]) ->
    process_flag(trap_exit, true),
    _ = ets:new(?FLAGS, [named_table, public, set]),
    Poll = application:get_env(muse_engine, poll_ms, 1000),
    erlang:send_after(0, self(), tick),
    {ok, #{runs => #{}, poll => Poll}}.

handle_call(tick, _From, State) ->
    {Started, State1} = do_tick(State),
    {reply, Started, State1};
handle_call(in_flight, _From, #{runs := Runs} = State) ->
    {reply, maps:keys(Runs), State}.

handle_cast({abort, TaskId}, #{runs := Runs} = State) ->
    case maps:find(TaskId, Runs) of
        {ok, Pid} -> muse_task_run:abort(Pid);
        error -> ok
    end,
    {noreply, State}.

handle_info(tick, #{poll := Poll} = State) ->
    {_, State1} = try do_tick(State)
                  catch Class:Reason:St ->
                      logger:warning("task worker tick failed: ~p:~p ~p", [Class, Reason, St]),
                      {[], State}
                  end,
    erlang:send_after(Poll, self(), tick),
    {noreply, State1};
handle_info({'EXIT', Pid, _Reason}, #{runs := Runs} = State) ->
    {noreply, State#{runs := maps:filter(fun(_, P) -> P =/= Pid end, Runs)}};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #{runs := Runs}) ->
    [muse_task_run:abort(Pid) || Pid <- maps:values(Runs)],
    ok.

%% Internal

do_tick(#{runs := Runs} = State) ->
    _ = muse_store:put(<<"system">>, <<"worker-status">>,
                       #{<<"id">> => <<"tasks">>, <<"lastTickAt">> => muse_time:now_iso()}),
    Now = muse_time:now_ms(),
    Due = [{O, T} || {O, T = #{<<"id">> := Id}} <- muse_store:scan(<<"tasks">>),
                     not maps:is_key(Id, Runs), due(T, Now)],
    Eligible = eligible(Due, map_size(Runs), Now, []),
    Started = lists:filtermap(fun({Owner, Task}) ->
                                      case muse_task_run:start_link(Owner, Task) of
                                          {ok, Pid} -> {true, {maps:get(<<"id">>, Task), Pid}};
                                          _ -> false
                                      end
                              end, Eligible),
    {[Id || {Id, _} <- Started], State#{runs := maps:merge(Runs, maps:from_list(Started))}}.

due(#{<<"status">> := <<"queued">>}, _) -> true;
due(#{<<"status">> := <<"scheduled">>} = T, Now) -> muse_time:is_due(maps:get(<<"nextRunAt">>, T, null), Now);
due(#{<<"status">> := <<"running">>} = T, Now) -> muse_time:is_due(maps:get(<<"leaseUntil">>, T, null), Now);
due(#{<<"status">> := <<"waiting_approval">>}, _) -> true;
due(_, _) -> false.

eligible([], _, _, Acc) ->
    lists:reverse(Acc);
eligible(_, InFlight, _, Acc) when InFlight + length(Acc) >= ?MAX_RUNS ->
    lists:reverse(Acc);
eligible([{Owner, #{<<"status">> := <<"waiting_approval">>} = T} = Rec | Rest], InFlight, Now, Acc) ->
    %% Skip while the review is pending or executing; an overdue review is
    %% expired on the way and the task becomes eligible (spec §4.1 step 6).
    case muse_actions:awaits_review(Owner, maps:get(<<"actionId">>, T, null)) of
        true -> eligible(Rest, InFlight, Now, Acc);
        false -> eligible(Rest, InFlight, Now, [Rec | Acc])
    end;
eligible([Rec | Rest], InFlight, Now, Acc) ->
    eligible(Rest, InFlight, Now, [Rec | Acc]).
