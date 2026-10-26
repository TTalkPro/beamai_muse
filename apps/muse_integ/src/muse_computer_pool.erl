%% @doc Lifecycle of the computer pool (designs/04-integrations.md §3; not in
%% OpenMuse, which has one computer per owner and never stops it by itself).
%%
%% - Admission (`admit/2`): starting a stopped computer while
%%   COMPUTER_MAX_RUNNING (default 4) computers of this deployment are
%%   running first stops the least recently used idle one (no lease held,
%%   see `muse_computer:stop_if_idle/1`). When every running computer is busy
%%   the start fails with 503. Admissions of a deployment are serialised with
%%   a `global` lock, so two concurrent starts cannot both take the last slot.
%%   Running containers are counted with `docker container ls` by this
%%   deployment's labels, so the count holds even when records are stale.
%% - Idle stop: a running computer unused (muse_computers `lastUsedAt`) for
%%   COMPUTER_IDLE_MINUTES (default 15) is stopped; its volume is kept.
%% - Retention: a stopped computer unused for COMPUTER_RETENTION_DAYS
%%   (default 7) is deleted with its container and volume. An older
%%   version's default computer (scope `user`, the legacy computer) is
%%   exempt: it may hold the only copy of files from before the pool.
%% - Reconcile (at start, then every sweep for the records): a record whose
%%   container is not running becomes `stopped`; a running container with a
%%   record becomes `running`. Containers with this deployment's labels but
%%   no record are adopted as stopped computers when their owner (one of the
%%   owners known to the store) and scope can be recovered from the labels;
%%   otherwise they are stopped and left in place (never removed: their
%%   volume may hold the only copy of someone's files) with a warning.
%%
%% The gen_server drives the timer (60 s, app env `computer_sweep_ms`;
%% `computer_pool_timer = false` turns it off) and owns the overview cache:
%% `overview/0` never waits for docker (`docker stats --no-stream` alone
%% takes about two seconds). It answers from the cache, or from the records
%% when there is none yet, and asks for a refresh when the cache is older
%% than 10 s; the refresh runs in a separate process and then emits
%% `{computers, overview}` to the owners with computers, so open management
%% pages update themselves. `sweep/0` and `reconcile/0` can be called
%% directly (tests).
-module(muse_computer_pool).
-behaviour(gen_server).

-export([start_link/0, admit/2, sweep/0, reconcile/0, overview/0, invalidate/0,
         max_running/0, idle_minutes/0, retention_days/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(INTERVAL, 60000).
-define(CACHE, muse_computer_pool_cache).
-define(CACHE_MS, 10000).
-define(MINUTE, 60000).
-define(DAY, 86400000).

-type overview() :: #{running := [binary()], max := pos_integer(),
                      idle_minutes := pos_integer(),
                      stats := #{binary() => #{cpu := binary(), memory := binary()}}}.
-export_type([overview/0]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec max_running() -> pos_integer().
max_running() -> muse_config:get(computer_max_running, 4).

-spec idle_minutes() -> pos_integer().
idle_minutes() -> muse_config:get(computer_idle_minutes, 15).

-spec retention_days() -> pos_integer().
retention_days() -> muse_config:get(computer_retention_days, 7).

%% @doc Run `Start` (the provider start of `Ref`) once there is room for one
%% more running computer.
-spec admit(muse_computer:ref(), fun(() -> ok | {error, {pos_integer(), binary()}})) ->
    ok | {error, {pos_integer(), binary()}}.
admit(Ref, Start) ->
    Lock = {?MODULE, muse_computer:deployment()},
    global:trans(Lock,
                 fun() ->
                         case make_room(Ref) of
                             ok -> Start();
                             Error -> Error
                         end
                 end, [node() | nodes()], infinity).

%% @doc Idle stop, retention and record states, once. Disabled computers: nothing.
-spec sweep() -> ok.
sweep() ->
    case enabled() of
        true -> do_sweep();
        false -> ok
    end.

%% @doc Adopt or stop the containers without a record, then sweep.
-spec reconcile() -> ok.
reconcile() ->
    case enabled() of
        true -> adopt(), do_sweep();
        false -> ok
    end.

%% @doc What the management page shows: running container names, the
%% limits and a `docker stats` sample of the running ones. Never waits for
%% docker: the cached sample (refreshed in the background when older than
%% 10 s), else the records' states without stats.
-spec overview() -> overview().
overview() ->
    Now = muse_time:now_ms(),
    Cached = case ets:whereis(?CACHE) of
                 undefined -> [];
                 _ -> ets:lookup(?CACHE, overview)
             end,
    case Cached of
        [{overview, At, Value}] when Now - At < ?CACHE_MS, Now >= At ->
            Value;
        [{overview, _, Value}] ->
            refresh(),
            Value;
        [] ->
            refresh(),
            from_records()
    end.

%% @doc Drop the cached overview (after a start, stop or delete); the next
%% `overview/0` answers from the records and refreshes.
-spec invalidate() -> ok.
invalidate() ->
    _ = ets:whereis(?CACHE) =/= undefined andalso ets:delete(?CACHE, overview),
    ok.

refresh() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, refresh)
    end.

%% Running according to the records (kept in step with docker by the sweeps).
from_records() ->
    #{running => [maps:get(<<"container">>, C, <<>>)
                  || {_, C = #{<<"status">> := <<"running">>}} <- muse_computers:all()],
      max => max_running(), idle_minutes => idle_minutes(), stats => #{}}.

%% gen_server

init([]) ->
    _ = ets:new(?CACHE, [named_table, public, set, {read_concurrency, true}]),
    %% `computer_pool_timer = false` (test environments): no automatic passes
    _ = application:get_env(muse_integ, computer_pool_timer, true) andalso (self() ! reconcile),
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%% One refresh at a time, outside the gen_server (docker stats is slow).
handle_cast(refresh, #{refreshing := true} = State) ->
    {noreply, State};
handle_cast(refresh, State) ->
    {_, Ref} = spawn_monitor(fun() ->
                                     Value = fetch_overview(),
                                     _ = ets:insert(?CACHE, {overview, muse_time:now_ms(), Value}),
                                     [muse_events:emit(O, {computers, overview})
                                      || O <- lists:usort([O || {O, _} <- muse_computers:all()])]
                             end),
    {noreply, State#{refreshing => true, refresh_ref => Ref}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reconcile, State) ->
    safely(fun reconcile/0),
    schedule(),
    {noreply, State};
handle_info(tick, State) ->
    safely(fun sweep/0),
    refresh(),
    schedule(),
    {noreply, State};
handle_info({'DOWN', Ref, process, _, Reason}, #{refresh_ref := Ref} = State) ->
    Reason =:= normal orelse logger:warning("computer pool overview refresh failed: ~p", [Reason]),
    {noreply, maps:without([refresh_ref], State#{refreshing => false})};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Internal

schedule() ->
    erlang:send_after(application:get_env(muse_integ, computer_sweep_ms, ?INTERVAL), self(), tick).

safely(Fun) ->
    try Fun()
    catch Class:Reason:St ->
        logger:warning("computer pool sweep failed: ~p:~p ~p", [Class, Reason, St])
    end.

enabled() ->
    muse_config:get(computer_enabled, false) =:= true.

full(Max) ->
    <<"All ", (integer_to_binary(Max))/binary, " running computers are busy "
      "(COMPUTER_MAX_RUNNING). Wait for a running command to finish, or stop a computer "
      "on the Computer page, then try again.">>.

make_room(Ref) ->
    case muse_computer_docker:containers(running) of
        {ok, Running} ->
            #{container := Own} = muse_computer:identity(Ref),
            Others = [N || #{name := N} <- Running, N =/= Own],
            Max = max_running(),
            case length(Others) - Max + 1 of
                Need when Need =< 0 -> ok;
                Need -> evict(Need, candidates(Others), Max)
            end;
        Error ->
            Error
    end.

%% Running computers with a record, least recently used first. Running
%% containers without a record count against the limit but are not
%% stopped here (the reconcile handles them).
candidates(Names) ->
    Running = sets:from_list(Names),
    Known = [{maps:get(<<"lastUsedAt">>, C, <<>>), muse_computer:ref_of(Owner, Id)}
             || {Owner, C = #{<<"id">> := Id, <<"container">> := Name}} <- muse_computers:all(),
                sets:is_element(Name, Running)],
    [R || {_, R} <- lists:sort(Known)].

evict(0, _, _) ->
    ok;
evict(_, [], Max) ->
    {error, {503, full(Max)}};
evict(Need, [Ref | Rest], Max) ->
    case muse_computer:busy(Ref) of
        true ->
            evict(Need, Rest, Max);
        false ->
            case muse_computer:stop_if_idle(Ref) of
                ok ->
                    logger:info("computer pool: stopped ~s to start another computer",
                                [muse_computer:computer_id(Ref)]),
                    evict(Need - 1, Rest, Max);
                {error, _} ->
                    evict(Need, Rest, Max)
            end
    end.

do_sweep() ->
    case muse_computer_docker:containers(running) of
        {ok, Running} ->
            Names = sets:from_list([N || #{name := N} <- Running]),
            Now = muse_time:now_ms(),
            Idle = idle_minutes() * ?MINUTE,
            Retain = retention_days() * ?DAY,
            lists:foreach(fun({Owner, C}) -> sweep_one(Owner, C, Names, Now, Idle, Retain) end,
                          muse_computers:all());
        {error, {_, Msg}} ->
            logger:warning("computer pool: cannot list containers: ~ts", [Msg])
    end.

sweep_one(Owner, C = #{<<"id">> := Id, <<"container">> := Name}, Names, Now, Idle, Retain) ->
    Ref = muse_computer:ref_of(Owner, Id),
    Unused = case muse_time:parse(maps:get(<<"lastUsedAt">>, C, <<>>)) of
                 nan -> 0;
                 Used -> Now - Used
             end,
    case sets:is_element(Name, Names) of
        true when Unused >= Idle ->
            case muse_computer:busy(Ref) of
                true -> ok;
                false ->
                    case muse_computer:stop_if_idle(Ref) of
                        ok -> logger:info("computer pool: idle stop of ~s", [Id]);
                        {error, _} -> ok
                    end
            end;
        true ->
            muse_computers:set_status(Owner, Id, <<"running">>);
        false ->
            muse_computers:set_status(Owner, Id, <<"stopped">>),
            Default = muse_computer:is_legacy(Ref),
            case not Default andalso Unused >= Retain of
                true ->
                    case muse_computer:delete(Ref) of
                        ok -> logger:info("computer pool: deleted ~s after retention", [Id]);
                        {error, {_, Msg}} ->
                            logger:warning("computer pool: retention delete of ~s failed: ~ts",
                                           [Id, Msg])
                    end;
                false ->
                    ok
            end
    end;
sweep_one(_, _, _, _, _, _) ->
    ok.

adopt() ->
    case muse_computer_docker:containers(all) of
        {ok, Containers} ->
            Recorded = sets:from_list([N || {_, #{<<"container">> := N}} <- muse_computers:all()]),
            Orphans = [C || C = #{name := N} <- Containers, not sets:is_element(N, Recorded)],
            case Orphans of
                [] -> ok;
                _ -> lists:foreach(fun(C) -> adopt_one(C, owners()) end, Orphans)
            end;
        {error, {_, Msg}} ->
            logger:warning("computer pool: cannot list containers: ~ts", [Msg])
    end.

%% Owners known to this deployment's store.
owners() ->
    lists:usort([O || Kind <- [muse_computers:kind(), <<"computer-state">>, <<"threads">>, <<"tasks">>],
                      {O, _} <- muse_store:scan(Kind)]).

adopt_one(#{name := Name, state := State, owner_hash := Hash, computer := Cid, scope := Scope0}, Owners) ->
    Matching = [O || O <- Owners, binary:part(muse_ids:sha256hex(O), 0, 24) =:= Hash],
    Scope = case Cid of
                <<>> -> muse_computers:legacy_scope();
                _ -> Scope0
            end,
    Adopt = [O || O <- Matching, muse_computers:valid_scope(Scope),
                  muse_computers:id(O, Scope) =:= case Cid of
                                                      <<>> -> muse_computers:legacy_id(O);
                                                      _ -> Cid
                                                  end,
                  maps:get(container, muse_computer:identity(muse_computer:ref_of(O, muse_computers:id(O, Scope))))
                      =:= Name],
    case Adopt of
        [Owner | _] ->
            Ref = muse_computer:ensure(Owner, Scope),
            _ = State =:= <<"running">> andalso muse_computer:stop_if_idle(Ref),
            logger:info("computer pool: adopted container ~ts as a stopped computer", [Name]);
        [] ->
            _ = State =:= <<"running">>
                andalso muse_docker:run(muse_docker:stop_args(Name),
                                        #{timeout => muse_docker:control_timeout()}),
            logger:warning("computer pool: container ~ts has no record and no known owner; "
                           "stopped and kept (remove it by hand if it is not needed)", [Name])
    end.

fetch_overview() ->
    Base = #{running => [], max => max_running(), idle_minutes => idle_minutes(), stats => #{}},
    case enabled() andalso muse_computer_docker:containers(running) of
        {ok, Running} ->
            Names = [N || #{name := N} <- Running],
            Base#{running := Names, stats := muse_computer_docker:stats(Names)};
        _ ->
            Base
    end.
