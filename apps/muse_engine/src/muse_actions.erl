%% @doc Action review: proposals for external writes and their decisions
%% (OpenMuse `actions.ts`; engine spec §2.13, §2.14, §6; integrations spec
%% §2.5, §4.7; designs/02-engine.md §5).
%%
%% What can be written is pluggable: each proposal `kind` is a
%% `muse_action_kind` module registered with `register_kind/2`, which gives
%% the schema of its `data`, the review card (`display/1`) and the executor.
%% Production registers `calendar.event` (muse_calendar_action, the built-in
%% calendar) and `mail.send` (muse_mail_action, the built-in mail) at
%% muse_engine's start.
%%
%% A proposal is validated against the registered kinds, prepared by its
%% kind (optional: owner checks, the reviewed target and its version),
%% hashed over `{input, target, targetVersion}` like `JSON.stringify` in the
%% original, and expires after 30 minutes. Approval claims the record
%% atomically (`awaiting_review` to `executing`), runs the kind's
%% `execute/3` and stores `succeeded`, `failed` or `outcome_unknown`; an
%% uncertain write is never retried. Each transition writes an `activity`
%% record, except expiry.
%%
%% Waiting tasks are not pushed (spec §6.4): the task worker polls
%% `awaits_review/2` and re-runs the task once the action is settled.
-module(muse_actions).

-export([propose/4, decide/4, get/2,
         awaits_review/2, expire_if_due/2, reject_pending/2,
         proposal_schema/0,
         register_kind/2, unregister_kind/1, kinds/0, tools/0, display/1]).

-type owner() :: binary().
-type action() :: #{binary() => term()}.
-type error() :: {error, {pos_integer(), binary()}}.
-export_type([action/0]).

%% muse_events is written by the integrator; until then notify/2 is a no-op.
-ignore_xref([{muse_events, emit, 2}]).
-dialyzer({no_unknown, notify/2}).

-define(ACTIONS, <<"actions">>).
-define(KINDS, {?MODULE, kinds}).
-define(TTL_MS, 30 * 60 * 1000).
-define(RUNNABLE, [<<"running">>, <<"waiting_approval">>]).
-define(RESUME_TASK, <<"Resume the task before approving this action. Cancelled tasks cannot execute.">>).
-define(UNAVAILABLE, <<"This kind of action is not available on this server. Prepare a new action.">>).

%% Kind registry

%% @doc Register (or replace) the `muse_action_kind` module for `Kind`.
-spec register_kind(binary(), module()) -> ok.
register_kind(Kind, Module) when is_binary(Kind), is_atom(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    persistent_term:put(?KINDS, (kinds())#{Kind => Module}).

-spec unregister_kind(binary()) -> ok.
unregister_kind(Kind) ->
    Kinds = kinds(),
    case maps:is_key(Kind, Kinds) of
        true -> persistent_term:put(?KINDS, maps:remove(Kind, Kinds));
        false -> ok
    end.

%% @doc The registered kinds (`calendar.event` and `mail.send` in production).
-spec kinds() -> #{binary() => module()}.
kinds() ->
    persistent_term:get(?KINDS, #{}).

kind_module(Kind) ->
    maps:get(Kind, kinds(), undefined).

%% @doc Task-model tools of the registered kinds that define `tool/0`.
-spec tools() -> [#{kind := binary(), name := binary(), description := binary(),
                    schema := muse_validate:schema()}].
tools() ->
    [(Mod:tool())#{kind => Kind, schema => Mod:schema()}
     || {Kind, Mod} <- lists:sort(maps:to_list(kinds())), erlang:function_exported(Mod, tool, 0)].

%% @doc The review card of a stored proposal: its kind's `display/1`, or
%% the stored title and the scalar data fields when the kind is not (or no
%% longer) registered.
-spec display(action()) -> muse_action_kind:display().
display(#{<<"kind">> := Kind} = Action) ->
    Data = maps:get(<<"data">>, Action, #{}),
    Fallback = #{title => maps:get(<<"title">>, Action, Kind), fields => generic_fields(Data)},
    case kind_module(Kind) of
        undefined -> Fallback;
        Mod ->
            try Mod:display(Data) of
                #{title := _, fields := _} = D -> D
            catch _:_ -> Fallback
            end
    end;
display(Action) ->
    #{title => maps:get(<<"title">>, Action, <<>>), fields => []}.

generic_fields(Data) when is_map(Data) ->
    [{K, field_text(V)} || {K, V} <- lists:sort(maps:to_list(Data)), is_binary(K)];
generic_fields(_) ->
    [].

field_text(V) when is_binary(V) -> V;
field_text(V) when is_integer(V) -> integer_to_binary(V);
field_text(V) when is_boolean(V) -> atom_to_binary(V);
field_text(L) when is_list(L) ->
    case lists:all(fun is_binary/1, L) of
        true -> iolist_to_binary(lists:join(<<", ">>, L));
        false -> muse_json:encode(L)
    end;
field_text(V) -> muse_json:encode(V).

%% Proposals

%% @doc Prepare a proposal for review (spec §6.1). With an idempotency key
%% the id is `sha256hex(Key)` and an existing record is returned as is,
%% whatever its status.
-spec propose(owner(), term(), binary() | undefined, binary() | undefined) ->
          {ok, action()} | error().
propose(Owner, Raw, Key, TaskId) ->
    Id = case Key of
             undefined -> muse_ids:uuid();
             _ -> muse_ids:sha256hex(Key)
         end,
    case Key =/= undefined andalso get(Owner, Id) of
        #{} = Existing -> {ok, Existing};
        _ -> prepare_new(Owner, Raw, Key, TaskId, Id)
    end.

prepare_new(Owner, Raw, Key, TaskId, Id) ->
    maybe
        {ok, #{<<"kind">> := Kind, <<"data">> := Data} = Parsed} ?= muse_validate:parse(proposal_schema(), Raw),
        Mod = kind_module(Kind),
        {ok, Prepared} ?= case erlang:function_exported(Mod, prepare, 2) of
                              true -> Mod:prepare(Owner, Data);
                              false -> {ok, #{data => Data}}
                          end,
        {ok, Input} ?= muse_validate:parse(proposal_schema(), Parsed#{<<"data">> => maps:get(data, Prepared, Data)}),
        Target = maps:get(target, Prepared, undefined),
        Version = maps:get(target_version, Prepared, undefined),
        #{title := Title} = Mod:display(maps:get(<<"data">>, Input)),
        Now = muse_time:now_ms(),
        Proposal = compact(#{<<"id">> => Id,
                             <<"taskId">> => TaskId,
                             <<"title">> => Title,
                             <<"kind">> => Kind,
                             <<"data">> => maps:get(<<"data">>, Input),
                             <<"target">> => Target,
                             <<"targetVersion">> => Version,
                             <<"status">> => <<"awaiting_review">>,
                             <<"hash">> => hash(Input, Target, Version),
                             <<"createdAt">> => muse_time:to_iso(Now),
                             <<"expiresAt">> => muse_time:to_iso(Now + ?TTL_MS)}),
        Saved = case Key of
                    undefined -> muse_store:put(Owner, ?ACTIONS, Proposal);
                    _ -> muse_store:insert_if_absent(Owner, ?ACTIONS, Proposal)
                end,
        case Saved of
            undefined ->
                case get(Owner, Id) of
                    undefined -> {error, {409, <<"Prepared action could not be loaded">>}};
                    Existing -> {ok, Existing}
                end;
            _ ->
                record(Owner, Saved, <<"Ready for your review">>),
                {ok, Saved}
        end
    end.

%% sha256hex(JSON.stringify({input, target, targetVersion})); the target is a
%% plain map, which muse_json writes with sorted keys.
hash(Input, Target, Version) ->
    Json = {obj, [{<<"input">>, muse_validate:ordered(proposal_schema(), Input)},
                  {<<"target">>, Target},
                  {<<"targetVersion">>, Version}]},
    muse_ids:sha256hex(muse_json:encode(Json)).

%% @doc Approve or deny (spec §6.2, checks in the original order). A
%% proposal that is no longer awaiting review is returned unchanged.
-spec decide(owner(), binary(), binary(), approve | deny) -> {ok, action()} | error().
decide(Owner, Id, Hash, Decision) ->
    case get(Owner, Id) of
        undefined ->
            not_found();
        Proposal ->
            decide_matching(same_hash(maps:get(<<"hash">>, Proposal, Hash), Hash),
                            Owner, Hash, Decision, Proposal)
    end.

%% The review hash is compared in constant time.
same_hash(H, Hash) when is_binary(H), is_binary(Hash), byte_size(H) =:= byte_size(Hash) ->
    crypto:hash_equals(H, Hash);
same_hash(_, _) ->
    false.

decide_matching(false, _Owner, _Hash, _Decision, _Proposal) ->
    {error, {409, <<"This proposal changed. Open its latest review before deciding.">>}};
decide_matching(true, Owner, Hash, Decision, Proposal0) ->
    case Proposal0 of
        #{<<"status">> := S} = Proposal when S =/= <<"awaiting_review">> ->
            {ok, Proposal};
        Proposal ->
            decide_pending(Owner, Proposal, Hash, Decision)
    end.

decide_pending(Owner, #{<<"id">> := Id, <<"expiresAt">> := Expires} = Proposal, Hash, Decision) ->
    TaskId = maps:get(<<"taskId">>, Proposal, undefined),
    maybe
        ok ?= case Decision =:= approve andalso not task_runnable(Owner, TaskId) of
                  true -> {error, {409, ?RESUME_TASK}};
                  false -> ok
              end,
        ok ?= case muse_time:is_due(Expires, muse_time:now_ms()) of
                  true -> expire(Owner, Id, #{<<"status">> => <<"awaiting_review">>,
                                              <<"hash">> => Hash, <<"expiresAt">> => Expires});
                  false -> ok
              end,
        ok ?= case Decision =:= approve andalso kind_module(maps:get(<<"kind">>, Proposal, undefined)) of
                  undefined -> {error, {409, ?UNAVAILABLE}};
                  _ -> ok
              end,
        Status = case Decision of
                     approve -> <<"executing">>;
                     deny -> <<"denied">>
                 end,
        #{} = Claimed ?= case claim(Owner, Id, Status, muse_time:now_ms()) of
                             undefined -> current(Owner, Id);
                             C -> C
                         end,
        record(Owner, Claimed, case Decision of
                                   deny -> <<"Declined; no changes made">>;
                                   approve -> <<"Approved; execution started">>
                               end),
        case Decision of
            deny -> {ok, Claimed};
            approve -> run(Owner, Claimed)
        end
    end.

%% Expired review: CAS to `expired` (no activity). A lost CAS returns the
%% current record instead of the error.
expire(Owner, Id, Expected) ->
    case muse_store:cas(Owner, ?ACTIONS, Id, Expected, #{<<"status">> => <<"expired">>}) of
        undefined -> current(Owner, Id);
        _ ->
            notify(Owner, {action, Id}),
            {error, {409, <<"This review expired. Create a fresh proposal.">>}}
    end.

%% `Store.claim` (spec §6.3): set the status only while the action awaits
%% review, has not expired and, for `executing`, its task (if any) is
%% runnable. The task row is read dirty inside the transaction, which is
%% what the original's READ COMMITTED subquery sees as well.
claim(Owner, Id, Status, NowMs) ->
    muse_store:update(Owner, ?ACTIONS, Id,
                      fun(#{<<"status">> := <<"awaiting_review">>, <<"expiresAt">> := Expires} = A) ->
                              Live = case muse_time:parse(Expires) of
                                         nan -> false;
                                         Ms -> Ms > NowMs
                                     end,
                              TaskOk = Status =/= <<"executing">>
                                  orelse task_runnable(Owner, maps:get(<<"taskId">>, A, undefined)),
                              case Live andalso TaskOk of
                                  true -> {ok, A#{<<"status">> => Status}};
                                  false -> abort
                              end;
                         (_) ->
                              abort
                      end).

run(Owner, #{<<"id">> := Id} = Claimed) ->
    case task_runnable(Owner, maps:get(<<"taskId">>, Claimed, undefined)) of
        false ->
            %% The task was cancelled between the claim and execution.
            _ = muse_store:cas(Owner, ?ACTIONS, Id, #{<<"status">> => <<"executing">>},
                               #{<<"status">> => <<"awaiting_review">>}),
            notify(Owner, {action, Id}),
            {error, {409, ?RESUME_TASK}};
        true ->
            Finished = execute(Owner, Claimed),
            Saved = muse_store:put(Owner, ?ACTIONS, Finished),
            Detail = maps:get(<<"result">>, Saved, maps:get(<<"error">>, Saved, maps:get(<<"status">>, Saved))),
            record(Owner, Saved, Detail),
            {ok, Saved}
    end.

execute(Owner, Claimed) ->
    Result = try
                 maybe
                     {ok, #{<<"kind">> := Kind, <<"data">> := Data}} ?=
                         muse_validate:parse(proposal_schema(), maps:with([<<"kind">>, <<"data">>], Claimed)),
                     Review = compact(#{target => maps:get(<<"target">>, Claimed, undefined),
                                        target_version => maps:get(<<"targetVersion">>, Claimed, undefined)}),
                     (kind_module(Kind)):execute(Owner, Data, Review)
                 end
             catch
                 _:_ -> {error, {internal, <<"Execution failed">>}}
             end,
    case Result of
        {ok, Receipt} -> Claimed#{<<"status">> => <<"succeeded">>, <<"result">> => Receipt};
        {error, {outcome_unknown, Msg}} -> failed(Claimed, <<"outcome_unknown">>, Msg);
        {error, {_, Msg}} -> failed(Claimed, <<"failed">>, Msg);
        {error, _} -> failed(Claimed, <<"failed">>, <<>>)
    end.

failed(Claimed, Status, Msg) ->
    Claimed#{<<"status">> => Status,
             <<"error">> => case Msg of
                                B when is_binary(B), B =/= <<>> -> B;
                                _ -> <<"Execution failed">>
                            end}.

%% @doc The proposal, or `undefined`.
-spec get(owner(), binary()) -> action() | undefined.
get(Owner, Id) ->
    muse_store:get(Owner, ?ACTIONS, Id).

%% @doc Worker tick, spec §4.1 step 6: true while the task's action still
%% awaits a decision or is executing (skip the task). An overdue review is
%% expired on the way and the task becomes eligible again.
-spec awaits_review(owner(), binary() | undefined | null) -> boolean().
awaits_review(_Owner, Id) when not is_binary(Id) ->
    false;
awaits_review(Owner, Id) ->
    case get(Owner, Id) of
        #{<<"status">> := <<"awaiting_review">>} = Action -> not expire_if_due(Owner, Action);
        #{<<"status">> := <<"executing">>} -> true;
        _ -> false
    end.

%% @doc If `Action` awaits review and `expiresAt <= now`, CAS
%% `{status: "awaiting_review", expiresAt}` to `{status: "expired"}` without
%% an activity record and return true (whether or not the CAS won).
-spec expire_if_due(owner(), action()) -> boolean().
expire_if_due(Owner, #{<<"id">> := Id, <<"status">> := <<"awaiting_review">>} = Action) ->
    Expires = maps:get(<<"expiresAt">>, Action, undefined),
    case muse_time:is_due(Expires, muse_time:now_ms()) of
        true ->
            case muse_store:cas(Owner, ?ACTIONS, Id,
                                #{<<"status">> => <<"awaiting_review">>, <<"expiresAt">> => Expires},
                                #{<<"status">> => <<"expired">>}) of
                undefined -> ok;
                _ -> notify(Owner, {action, Id})
            end,
            true;
        false ->
            false
    end;
expire_if_due(_Owner, _Action) ->
    false.

%% @doc Task cancel (spec §5.2 step 9): deny the task's proposal if it still
%% awaits review. Errors from `decide/4` (e.g. "This review expired") are
%% returned, as the original lets them propagate out of `control()`.
-spec reject_pending(owner(), binary() | undefined | null) -> ok | error().
reject_pending(Owner, Id) when is_binary(Id) ->
    case get(Owner, Id) of
        #{<<"status">> := <<"awaiting_review">>, <<"hash">> := Hash} ->
            case decide(Owner, Id, Hash, deny) of
                {ok, _} -> ok;
                Error -> Error
            end;
        _ ->
            ok
    end;
reject_pending(_Owner, _Id) ->
    ok.

%% @doc proposalSchema (spec §2.13): discriminated on `kind`, one variant
%% per registered kind.
-spec proposal_schema() -> muse_validate:schema().
proposal_schema() ->
    {tagged, <<"kind">>,
     maps:map(fun(Kind, Mod) -> {object, [{<<"kind">>, {literal, Kind}}, {<<"data">>, Mod:schema()}]} end,
              kinds())}.

%% Helpers

task_runnable(_Owner, undefined) ->
    true;
task_runnable(Owner, TaskId) ->
    case muse_store:get(Owner, <<"tasks">>, TaskId) of
        #{<<"status">> := S} -> lists:member(S, ?RUNNABLE);
        _ -> false
    end.

current(Owner, Id) ->
    case get(Owner, Id) of
        undefined -> not_found();
        Current -> {ok, Current}
    end.

not_found() ->
    {error, {404, <<"Action not found">>}}.

compact(Map) ->
    maps:filter(fun(_, V) -> V =/= undefined end, Map).

record(Owner, #{<<"id">> := Id, <<"title">> := Title, <<"status">> := Status}, Detail) ->
    _ = muse_store:put(Owner, <<"activity">>,
                       #{<<"id">> => muse_ids:uuid(), <<"actionId">> => Id, <<"title">> => Title,
                         <<"detail">> => Detail, <<"date">> => muse_time:now_iso(),
                         <<"status">> => Status}),
    notify(Owner, {action, Id}).

%% Domain event for live UIs; harmless while muse_events does not exist.
notify(Owner, Event) ->
    _ = (catch muse_events:emit(Owner, Event)),
    ok.
