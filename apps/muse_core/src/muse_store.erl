%% @doc Transactional record store on Mnesia (designs/01-store.md §1).
%%
%% The OpenMuse engine keeps every record as a JSON document in one table
%% and builds all concurrency control on a single compare-and-swap with
%% Postgres jsonb semantics: `data @> expected` (recursive containment,
%% arrays as subsets) and `data || patch` (shallow merge). This module keeps
%% that shape so engine code can be ported line by line.
%%
%% Reads are dirty; every write runs in a Mnesia transaction whose log is
%% fsynced before it returns.
-module(muse_store).

-export([init/1, stop/0,
         get/3, list/2, list_by_status/3, list_by_goal/3, scan/1,
         put/3, remove/3, take/3, insert_if_absent/3,
         cas/5, update/4,
         recover_interrupted_actions/0,
         contains/2]).

-record(muse_record, {
    key        :: {binary(), binary(), binary()},
    ok         :: {binary(), binary()},
    kind       :: binary(),
    status     :: binary() | undefined,
    goal_id    :: binary() | undefined,
    data       :: map(),
    updated_at :: integer()
}).

-record(muse_meta, {key :: atom(), value :: term()}).

-define(SCHEMA_VERSION, 1).
-define(CLOCK, {?MODULE, clock}).
-define(SYNC, {?MODULE, sync_log}).

-type owner() :: binary().
-type kind() :: binary().
-type id() :: binary().
-type doc() :: #{binary() => term()}.

%% @doc Start Mnesia and create the tables. `Opts`:
%% `dir` (required for disc storage) and `storage => disc | ram`.
%% Disc storage refuses to run on `nonode@nohost`, where Mnesia cannot keep
%% a disc schema.
-spec init(#{dir => file:filename_all(), storage => disc | ram}) -> ok | {error, term()}.
init(Opts) ->
    Storage = maps:get(storage, Opts, disc),
    init_clock(),
    persistent_term:put(?SYNC, Storage =:= disc),
    case {Storage, node()} of
        {disc, nonode@nohost} ->
            {error, <<"Mnesia disc storage needs a named node (set -name/-sname)">>};
        {disc, _} ->
            Dir = maps:get(dir, Opts),
            ok = filelib:ensure_path(Dir),
            stopped = mnesia_stop(),
            ok = application:set_env(mnesia, dir, to_list(Dir)),
            case mnesia:create_schema([node()]) of
                ok -> ok;
                {error, {_, {already_exists, _}}} -> ok
            end,
            ok = mnesia:start(),
            start_tables(disc_copies);
        {ram, _} ->
            ok = mnesia:start(),
            start_tables(ram_copies)
    end.

-spec stop() -> stopped.
stop() ->
    mnesia_stop().

-spec get(owner(), kind(), id()) -> doc() | undefined.
get(Owner, Kind, Id) ->
    case mnesia:dirty_read(muse_record, {Owner, Kind, Id}) of
        [#muse_record{data = Data}] -> Data;
        [] -> undefined
    end.

%% @doc Most recently updated first, ties by id (OpenMuse `ORDER BY updated_at DESC, id`).
-spec list(owner(), kind()) -> [doc()].
list(Owner, Kind) ->
    newest_first(mnesia:dirty_index_read(muse_record, {Owner, Kind}, #muse_record.ok)).

-spec list_by_status(owner(), kind(), binary()) -> [doc()].
list_by_status(Owner, Kind, Status) ->
    Rows = mnesia:dirty_index_read(muse_record, Status, #muse_record.status),
    newest_first([R || R = #muse_record{ok = {O, K}} <- Rows, O =:= Owner, K =:= Kind]).

-spec list_by_goal(owner(), kind(), binary()) -> [doc()].
list_by_goal(Owner, Kind, GoalId) ->
    Rows = mnesia:dirty_index_read(muse_record, GoalId, #muse_record.goal_id),
    newest_first([R || R = #muse_record{ok = {O, K}} <- Rows, O =:= Owner, K =:= Kind]).

%% @doc Every owner's records of `Kind`, least recently updated first (the
%% task worker relies on this order for fairness).
-spec scan(kind()) -> [{owner(), doc()}].
scan(Kind) ->
    Rows = mnesia:dirty_index_read(muse_record, Kind, #muse_record.kind),
    Sorted = lists:sort(fun(A, B) -> A#muse_record.updated_at =< B#muse_record.updated_at end,
                        Rows),
    [{Owner, Data} || #muse_record{key = {Owner, _, _}, data = Data} <- Sorted].

%% @doc Upsert: replace the whole document.
-spec put(owner(), kind(), doc()) -> doc().
put(Owner, Kind, #{<<"id">> := Id} = Data) ->
    transaction(fun() -> write(Owner, Kind, Id, Data) end),
    Data.

-spec remove(owner(), kind(), id()) -> ok.
remove(Owner, Kind, Id) ->
    transaction(fun() -> mnesia:delete({muse_record, {Owner, Kind, Id}}) end).

%% @doc Read and delete in one step (one-shot tokens such as OAuth state).
-spec take(owner(), kind(), id()) -> doc() | undefined.
take(Owner, Kind, Id) ->
    transaction(fun() ->
        case mnesia:read(muse_record, {Owner, Kind, Id}, write) of
            [#muse_record{data = Data}] ->
                ok = mnesia:delete({muse_record, {Owner, Kind, Id}}),
                Data;
            [] ->
                undefined
        end
    end).

%% @doc Insert unless a record with the same id exists. Returns the value when
%% inserted and `undefined` when it already existed.
-spec insert_if_absent(owner(), kind(), doc()) -> doc() | undefined.
insert_if_absent(Owner, Kind, #{<<"id">> := Id} = Data) ->
    transaction(fun() ->
        case mnesia:read(muse_record, {Owner, Kind, Id}, write) of
            [] -> write(Owner, Kind, Id, Data), Data;
            [_] -> undefined
        end
    end).

%% @doc `UPDATE ... SET data = data || Patch WHERE data @> Expected RETURNING data`.
%% Returns the new document, or `undefined` if the record is missing or does
%% not contain `Expected`. `#{}` as Expected means "update if it exists".
-spec cas(owner(), kind(), id(), map(), map()) -> doc() | undefined.
cas(Owner, Kind, Id, Expected, Patch) ->
    update(Owner, Kind, Id,
           fun(Data) ->
               case contains(Data, Expected) of
                   true -> {ok, maps:merge(Data, Patch)};
                   false -> abort
               end
           end).

%% @doc Transactional read-modify-write. `Fun(Data)` returns `{ok, NewData}`
%% to write or `abort` to leave the record untouched.
-spec update(owner(), kind(), id(), fun((doc()) -> {ok, doc()} | abort)) -> doc() | undefined.
update(Owner, Kind, Id, Fun) ->
    transaction(fun() ->
        case mnesia:read(muse_record, {Owner, Kind, Id}, write) of
            [#muse_record{data = Data}] ->
                case Fun(Data) of
                    {ok, New} -> write(Owner, Kind, Id, New), New;
                    abort -> undefined
                end;
            [] ->
                undefined
        end
    end).

%% @doc At API start: external writes interrupted by a restart become
%% `outcome_unknown` and are never retried automatically.
-spec recover_interrupted_actions() -> non_neg_integer().
recover_interrupted_actions() ->
    Patch = #{<<"status">> => <<"outcome_unknown">>,
              <<"error">> => <<"Server restarted during execution. Check the provider "
                               "before creating another action.">>},
    Rows = mnesia:dirty_index_read(muse_record, <<"executing">>, #muse_record.status),
    length([cas(O, K, I, #{<<"status">> => <<"executing">>}, Patch)
            || #muse_record{key = {O, K = <<"actions">>, I}} <- Rows]).

%% @doc jsonb `@>`: maps contain recursively, every element of an expected
%% array must be contained in some element of the actual array, numbers
%% compare by value, and `null` only matches `null` (a missing key does not).
-spec contains(term(), term()) -> boolean().
contains(Data, Expected) when is_map(Data), is_map(Expected) ->
    maps:fold(fun(K, V, Acc) ->
                  Acc andalso case maps:find(K, Data) of
                                  {ok, DV} -> contains(DV, V);
                                  error -> false
                              end
              end, true, Expected);
contains(Data, Expected) when is_list(Data), is_list(Expected) ->
    lists:all(fun(E) -> lists:any(fun(D) -> contains(D, E) end, Data) end, Expected);
contains(A, B) when is_number(A), is_number(B) ->
    A == B;
contains(A, B) ->
    A =:= B.

%% Internal

start_tables(Copies) ->
    ok = mnesia:wait_for_tables([schema], 30000),
    ok = ensure_table(muse_record, [{attributes, record_info(fields, muse_record)},
                                    {index, [ok, kind, status, goal_id]},
                                    {Copies, [node()]}]),
    ok = ensure_table(muse_meta, [{attributes, record_info(fields, muse_meta)},
                                  {Copies, [node()]}]),
    ok = mnesia:wait_for_tables([muse_record, muse_meta], 60000),
    case mnesia:dirty_read(muse_meta, schema_version) of
        [] -> ok = mnesia:dirty_write(#muse_meta{key = schema_version, value = ?SCHEMA_VERSION});
        [#muse_meta{value = ?SCHEMA_VERSION}] -> ok;
        [#muse_meta{value = Other}] -> error({unsupported_schema_version, Other})
    end.

ensure_table(Name, Def) ->
    case mnesia:create_table(Name, Def) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Name}} -> ok
    end.

write(Owner, Kind, Id, Data) ->
    mnesia:write(#muse_record{key = {Owner, Kind, Id},
                              ok = {Owner, Kind},
                              kind = Kind,
                              status = projection(<<"status">>, Data),
                              goal_id = projection(<<"goalId">>, Data),
                              data = Data,
                              updated_at = next_ts()}).

projection(Key, Data) ->
    case maps:get(Key, Data, undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

newest_first(Rows) ->
    Sorted = lists:sort(fun(#muse_record{updated_at = A, key = {_, _, IdA}},
                            #muse_record{updated_at = B, key = {_, _, IdB}}) ->
                            A > B orelse (A =:= B andalso IdA =< IdB)
                        end, Rows),
    [Data || #muse_record{data = Data} <- Sorted].

%% Mnesia buffers its transaction log in disk_log, so a node that is killed
%% (rather than stopped) loses recent commits even with sync_transaction.
%% `sync_log/0` fsyncs LATEST.LOG before the write is acknowledged, giving
%% the durability the engine's leases and approvals assume (verified by
%% muse_core_SUITE:app_boot_and_durability).
transaction(Fun) ->
    case mnesia:sync_transaction(Fun) of
        {atomic, Result} ->
            ok = sync_log(persistent_term:get(?SYNC, false)),
            Result;
        {aborted, Reason} -> error({store_aborted, Reason})
    end.

sync_log(true) -> mnesia:sync_log();
sync_log(false) -> ok.

mnesia_stop() ->
    case mnesia:stop() of
        stopped -> stopped;
        {error, _} -> stopped
    end.

init_clock() ->
    case persistent_term:get(?CLOCK, undefined) of
        undefined -> persistent_term:put(?CLOCK, atomics:new(1, [{signed, true}]));
        _ -> ok
    end.

%% Strictly increasing microsecond stamp: max(now, last + 1).
next_ts() ->
    Ref = persistent_term:get(?CLOCK),
    next_ts(Ref, atomics:get(Ref, 1)).

next_ts(Ref, Last) ->
    Next = max(erlang:system_time(microsecond), Last + 1),
    case atomics:compare_exchange(Ref, 1, Last, Next) of
        ok -> Next;
        Current -> next_ts(Ref, Current)
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.
