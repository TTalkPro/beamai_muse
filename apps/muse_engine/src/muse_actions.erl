%% @doc Action review: proposals for external writes and their decisions
%% (OpenMuse `actions.ts`; engine spec §2.13, §2.14, §6; integrations spec
%% §2.5, §4.7; designs/02-engine.md §5).
%%
%% A proposal is validated, prepared by `muse_workspace` (attachment
%% ownership, live calendar target and version), hashed over
%% `{input, connection, target, targetVersion}` exactly like
%% `JSON.stringify` in the original, and expires after 30 minutes.
%% Approval claims the record atomically (`awaiting_review` to `executing`),
%% runs `muse_workspace:execute/4` and stores `succeeded`, `failed` or
%% `outcome_unknown`; an uncertain write is never retried. Each transition
%% writes an `activity` record, except expiry.
%%
%% Waiting tasks are not pushed (spec §6.4): the task worker polls
%% `awaits_review/2` and re-runs the task once the action is settled.
-module(muse_actions).

-export([propose/4, decide/4, get/2,
         awaits_review/2, expire_if_due/2, reject_pending/2,
         proposal_schema/0]).

-type owner() :: binary().
-type action() :: #{binary() => term()}.
-type error() :: {error, {pos_integer(), binary()}}.
-export_type([action/0]).

%% muse_events is written by the integrator; until then notify/2 is a no-op.
-ignore_xref([{muse_events, emit, 2}]).
-dialyzer({no_unknown, notify/2}).

-define(ACTIONS, <<"actions">>).
-define(TTL_MS, 30 * 60 * 1000).
-define(RUNNABLE, [<<"running">>, <<"waiting_approval">>]).
-define(RESUME_TASK, <<"Resume the task before approving this action. Cancelled tasks cannot execute.">>).
-define(TARGET_KEYS, [<<"id">>, <<"calendarId">>, <<"title">>, <<"start">>, <<"end">>, <<"allDay">>,
                      <<"timeZone">>, <<"location">>, <<"description">>, <<"attendees">>]).

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
        {ok, Parsed} ?= muse_validate:parse(proposal_schema(), Raw),
        #{id := ConnId} = Connection ?=
            case muse_workspace:connection(Owner) of
                undefined -> {error, {409, <<"Connect Google before preparing an action">>}};
                C -> C
            end,
        {ok, Prepared} ?= http_result(muse_workspace:prepare(Owner, Parsed, ConnId)),
        {ok, Input} ?= muse_validate:parse(proposal_schema(), maps:get(input, Prepared, Parsed)),
        Target = maps:get(target, Prepared, undefined),
        Version = maps:get(target_version, Prepared, undefined),
        Now = muse_time:now_ms(),
        Proposal = compact(#{<<"id">> => Id,
                             <<"taskId">> => TaskId,
                             <<"title">> => title(Input),
                             <<"kind">> => maps:get(<<"kind">>, Input),
                             <<"data">> => maps:get(<<"data">>, Input),
                             <<"account">> => maps:get(account, Connection, undefined),
                             <<"connectionId">> => ConnId,
                             <<"target">> => Target,
                             <<"targetVersion">> => Version,
                             <<"status">> => <<"awaiting_review">>,
                             <<"hash">> => hash(Input, Connection, Target, Version),
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

title(#{<<"kind">> := <<"email.send">>, <<"data">> := #{<<"subject">> := S}}) ->
    <<"Send “"/utf8, S/binary, "”"/utf8>>;
title(#{<<"kind">> := <<"calendar.delete">>, <<"data">> := #{<<"title">> := T}}) ->
    <<"Delete ", T/binary>>;
title(#{<<"kind">> := <<"calendar.create">>, <<"data">> := #{<<"title">> := T}}) ->
    <<"Create ", T/binary>>;
title(#{<<"data">> := #{<<"title">> := T}}) ->
    <<"Update ", T/binary>>.

%% sha256hex(JSON.stringify({input, connection, target, targetVersion})).
hash(Input, Connection, Target, Version) ->
    Conn = {obj, [{<<"id">>, maps:get(id, Connection)},
                  {<<"account">>, maps:get(account, Connection, undefined)}]},
    Json = {obj, [{<<"input">>, muse_validate:ordered(proposal_schema(), Input)},
                  {<<"connection">>, Conn},
                  {<<"target">>, ordered_target(Target)},
                  {<<"targetVersion">>, Version}]},
    muse_ids:sha256hex(muse_json:encode(Json)).

%% CalendarEvent in `mapEvent` key order.
ordered_target(undefined) ->
    undefined;
ordered_target(Event) ->
    Extra = lists:sort(maps:keys(maps:without(?TARGET_KEYS, Event))),
    {obj, [{K, maps:get(K, Event)} || K <- ?TARGET_KEYS ++ Extra, maps:is_key(K, Event)]}.

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
        ok ?= case Decision =:= approve andalso not muse_workspace:connected(Owner) of
                  true -> {error, {409, <<"Google is disconnected. Reconnect before approving this action.">>}};
                  false -> ok
              end,
        ok ?= case Decision of
                  approve -> same_connection(Owner, Proposal);
                  deny -> ok
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

same_connection(Owner, Proposal) ->
    case muse_workspace:connection(Owner) of
        #{id := ConnId} = C when is_map_key(<<"connectionId">>, Proposal) ->
            case ConnId =:= maps:get(<<"connectionId">>, Proposal)
                andalso maps:get(account, C, undefined) =:= maps:get(<<"account">>, Proposal, undefined) of
                true -> ok;
                false -> connection_changed()
            end;
        _ ->
            connection_changed()
    end.

connection_changed() ->
    {error, {409, <<"Google account or connection changed. Prepare a new action for the connected account.">>}}.

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
                     {ok, Input} ?= muse_validate:parse(proposal_schema(),
                                                        maps:with([<<"kind">>, <<"data">>], Claimed)),
                     muse_workspace:execute(Owner, Input, maps:get(<<"connectionId">>, Claimed, undefined),
                                            maps:get(<<"targetVersion">>, Claimed, undefined))
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

%% @doc proposalSchema (spec §2.13): discriminated on `kind`.
-spec proposal_schema() -> muse_validate:schema().
proposal_schema() ->
    {refine, {object, EventFields}, RefineEvent} = Event = muse_gcal:event_draft_schema(),
    Variant = fun(Kind, Data) -> {object, [{<<"kind">>, {literal, Kind}}, {<<"data">>, Data}]} end,
    {tagged, <<"kind">>,
     #{<<"email.send">> => Variant(<<"email.send">>, muse_gmail:email_draft_schema()),
       <<"calendar.create">> => Variant(<<"calendar.create">>, Event),
       <<"calendar.update">> =>
           Variant(<<"calendar.update">>,
                   {refine, {object, EventFields ++ [{<<"eventId">>, {string, #{min => 1}}}]}, RefineEvent}),
       <<"calendar.delete">> =>
           Variant(<<"calendar.delete">>,
                   {object, [{<<"calendarId">>, {string, #{}}},
                             {<<"eventId">>, {string, #{min => 1}}},
                             {<<"title">>, {string, #{}}}]})}}.

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

http_result({error, E}) -> {error, muse_google_api:http_error(E)};
http_result(Ok) -> Ok.

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
