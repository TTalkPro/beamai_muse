%% @doc One sync process per mailbox account (邮件, designs/02-engine.md §9),
%% under muse_mail_sup; it runs where the task worker runs
%% (TASK_WORKER_ENABLED), so a separate API node never syncs twice.
%%
%% A pass (`run/2'):
%% 1. LIST with STATUS: folder records are added, renamed or removed (with
%%    their messages); one folder per role.
%% 2. Each selectable folder, inbox first: a `scan' gives the UIDs above the
%%    stored `lastUid' (a first sync, or a changed UIDVALIDITY, takes the
%%    UIDs of the last MAIL_SYNC_DAYS days instead, and drops what was
%%    stored) and the flags of the stored UID range. Flags that differ are
%%    written, stored messages the server no longer has are removed, new
%%    UIDs are fetched newest first in batches of 20 (headers, flags, parsed
%%    bodies, attachment list) and stored. `lastUid' only moves when every
%%    batch arrived, so an interrupted pass resumes; stored ids are skipped.
%%    Then the window is pruned to MAIL_SYNC_DAYS / MAIL_SYNC_MAX.
%%    A folder whose STATUS (UIDVALIDITY, UIDNEXT, count, unseen) did not
%%    change is skipped, except the inbox and every sixth pass, which also
%%    catch flag changes made in other clients.
%% 3. New unread inbox mail after the first sync raises a notification
%%    (muse_mail:notify_new/3); the pass emits `{mail, AccountId}'.
%%
%% Timing: a pass at start, then every MAIL_POLL_MINUTES. After a pass the
%% process holds an IMAP IDLE watch on the inbox (muse_mail_client:watch/4):
%% new mail, expunges and flag changes there start a pass after 1.5 s. A
%% failed pass is retried after 1, 2, 5, 10, 30, then every 60 minutes.
%% The state the page shows is the `mail-sync' record: `status' (`syncing',
%% `ok', `error'), `lastSyncAt', `lastSuccessAt', `lastError', `failures',
%% `nextSyncAt', `idle'.
-module(muse_mail_sync).
-behaviour(gen_server).

-export([start_link/2, ensure/2, stop/2, sync_now/2, request_sync/2, run/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(BATCH, 20).
-define(MAX_SOURCE, 2097152).
-define(DEBOUNCE_MS, 1500).
-define(BACKOFF_MIN, [1, 2, 5, 10, 30, 60]).
-define(FULL_EVERY, 6).

-record(st, {owner :: binary(),
             account :: binary(),
             timer :: reference() | undefined,
             failures = 0 :: non_neg_integer(),
             passes = 0 :: non_neg_integer(),
             watch :: binary() | undefined}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary(), binary()) -> {ok, pid()} | {error, term()}.
start_link(Owner, AccountId) ->
    gen_server:start_link({via, global, {?MODULE, Owner, AccountId}}, ?MODULE, {Owner, AccountId}, []).

%% @doc Start the account's process, or make a running one reload the
%% account and sync. No-op where sync does not run.
-spec ensure(binary(), binary()) -> ok.
ensure(Owner, AccountId) ->
    case whereis(muse_mail_sup) of
        undefined -> ok;
        _ ->
            case supervisor:start_child(muse_mail_sup, [Owner, AccountId]) of
                {ok, _} -> ok;
                {error, {already_started, Pid}} -> gen_server:cast(Pid, reload);
                {error, Reason} -> logger:warning("mail sync for ~ts: ~p", [AccountId, Reason]), ok
            end
    end.

-spec stop(binary(), binary()) -> ok.
stop(Owner, AccountId) ->
    case global:whereis_name({?MODULE, Owner, AccountId}) of
        Pid when is_pid(Pid), node(Pid) =:= node() ->
            _ = supervisor:terminate_child(muse_mail_sup, Pid),
            ok;
        _ -> ok
    end.

%% @doc Run a pass now and wait for it (in the account's process when it
%% runs, else here).
-spec sync_now(binary(), binary()) -> {ok, map()} | {error, {pos_integer(), binary()}}.
sync_now(Owner, AccountId) ->
    case global:whereis_name({?MODULE, Owner, AccountId}) of
        Pid when is_pid(Pid) -> gen_server:call(Pid, sync, 600000);
        _ -> pass(Owner, AccountId, 0)
    end.

%% @doc Ask for a pass soon (立即同步); returns at once.
-spec request_sync(binary(), binary()) -> ok.
request_sync(Owner, AccountId) ->
    case global:whereis_name({?MODULE, Owner, AccountId}) of
        Pid when is_pid(Pid) -> gen_server:cast(Pid, sync);
        _ -> ok
    end.

%% @doc One full pass, here (tests; `sync_now/2' records the state).
-spec run(binary(), binary()) -> {ok, map()} | {error, {pos_integer(), binary()}}.
run(Owner, AccountId) ->
    run(Owner, AccountId, true).

%%%===================================================================
%%% gen_server
%%%===================================================================

-spec init({binary(), binary()}) -> {ok, #st{}}.
init({Owner, AccountId}) ->
    process_flag(trap_exit, true),
    self() ! sync,
    {ok, #st{owner = Owner, account = AccountId}}.

-spec handle_call(term(), gen_server:from(), #st{}) -> {reply, term(), #st{}} | {stop, normal, term(), #st{}}.
handle_call(sync, _From, St) ->
    case do_pass(St) of
        {ok, Result, St1} -> {reply, Result, St1};
        {gone, Result, St1} -> {stop, normal, Result, St1}
    end;
handle_call(_Msg, _From, St) ->
    {reply, {error, unknown_call}, St}.

-spec handle_cast(term(), #st{}) -> {noreply, #st{}}.
handle_cast(reload, St) ->
    {noreply, schedule(0, drop_watch(St))};
handle_cast(sync, St) ->
    {noreply, schedule(0, St)};
handle_cast(_Msg, St) ->
    {noreply, St}.

-spec handle_info(term(), #st{}) -> {noreply, #st{}} | {stop, normal, #st{}}.
handle_info(sync, St) ->
    case do_pass(St) of
        {ok, _, St1} -> {noreply, St1};
        {gone, _, St1} -> {stop, normal, St1}
    end;
handle_info({muse_mail_watch, W, closed}, St = #st{watch = W, owner = O, account = A}) ->
    _ = muse_mail:put_sync_state(O, A, #{<<"idle">> => false}),
    {noreply, St#st{watch = undefined}};
handle_info({muse_mail_watch, W, _Kind}, St = #st{watch = W}) ->
    {noreply, soon(St)};
handle_info(_Msg, St) ->
    {noreply, St}.

-spec terminate(term(), #st{}) -> ok.
terminate(_Reason, St) ->
    _ = drop_watch(St),
    ok.

%%%===================================================================
%%% Scheduling
%%%===================================================================

do_pass(St = #st{owner = O, account = A, passes = N, failures = F}) ->
    St0 = cancel(St),
    flush_sync(),
    case muse_mail_accounts:get(O, A) of
        {error, _} = E ->
            {gone, E, St0};
        {ok, _} ->
            Result = pass(O, A, N),
            case Result of
                {ok, _} ->
                    St1 = ensure_watch(St0#st{failures = 0, passes = N + 1}),
                    {ok, Result, schedule(poll_ms(), St1)};
                {error, _} ->
                    Delay = backoff_ms(F + 1),
                    _ = muse_mail:put_sync_state(O, A, #{<<"nextSyncAt">> => muse_time:to_iso(muse_time:now_ms() + Delay)}),
                    {ok, Result, schedule(Delay, St0#st{failures = F + 1, passes = N + 1})}
            end
    end.

%% A pass with its state record.
pass(O, A, N) ->
    Now = muse_time:now_iso(),
    _ = muse_mail:put_sync_state(O, A, #{<<"status">> => <<"syncing">>, <<"startedAt">> => Now}),
    muse_events:emit(O, {mail, A}),
    Result = try run(O, A, N rem ?FULL_EVERY =:= 0)
             catch C:R:S ->
                     logger:warning("mail sync ~ts: ~p:~0p ~0p", [A, C, R, S]),
                     {error, {500, <<"同步时出现内部错误"/utf8>>}}
             end,
    Old = muse_mail:sync_state(O, A),
    Patch = case Result of
                {ok, _} ->
                    #{<<"status">> => <<"ok">>, <<"lastSyncAt">> => muse_time:now_iso(),
                      <<"lastSuccessAt">> => muse_time:now_iso(), <<"lastError">> => null, <<"failures">> => 0,
                      <<"nextSyncAt">> => muse_time:to_iso(muse_time:now_ms() + poll_ms())};
                {error, {_, Msg}} ->
                    #{<<"status">> => <<"error">>, <<"lastSyncAt">> => muse_time:now_iso(), <<"lastError">> => Msg,
                      <<"lastErrorAt">> => muse_time:now_iso(), <<"failures">> => maps:get(<<"failures">>, Old, 0) + 1}
            end,
    _ = muse_mail:put_sync_state(O, A, Patch),
    muse_events:emit(O, {mail, A}),
    Result.

poll_ms() ->
    muse_config:get(mail_poll_minutes, 5) * 60000.

backoff_ms(Failures) ->
    lists:nth(min(Failures, length(?BACKOFF_MIN)), ?BACKOFF_MIN) * 60000.

schedule(Ms, St) ->
    St1 = cancel(St),
    St1#st{timer = erlang:send_after(Ms, self(), sync)}.

%% A watch event: a pass soon, unless one is due sooner anyway.
soon(St = #st{timer = T}) ->
    Left = case T of
               undefined -> infinity;
               _ -> case erlang:read_timer(T) of false -> 0; L -> L end
           end,
    case Left =:= infinity orelse Left > ?DEBOUNCE_MS of
        true -> schedule(?DEBOUNCE_MS, St);
        false -> St
    end.

cancel(St = #st{timer = undefined}) -> St;
cancel(St = #st{timer = T}) -> _ = erlang:cancel_timer(T), St#st{timer = undefined}.

flush_sync() ->
    receive sync -> flush_sync() after 0 -> ok end.

ensure_watch(St = #st{watch = W}) when W =/= undefined ->
    St;
ensure_watch(St = #st{owner = O, account = A}) ->
    case {muse_mail:folder_by_role(O, A, <<"inbox">>), muse_mail_accounts:sidecar_account(O, A)} of
        {{ok, #{<<"path">> := Path}}, {ok, Acc}} ->
            WatchId = <<A/binary, ":", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
            case muse_mail_client:watch(WatchId, Acc, Path, self()) of
                {ok, #{<<"idle">> := Idle}} ->
                    _ = muse_mail:put_sync_state(O, A, #{<<"idle">> => Idle =:= true}),
                    St#st{watch = WatchId};
                _ ->
                    _ = muse_mail:put_sync_state(O, A, #{<<"idle">> => false}),
                    St
            end;
        _ ->
            St
    end.

drop_watch(St = #st{watch = undefined}) -> St;
drop_watch(St = #st{watch = W}) -> muse_mail_client:unwatch(W), St#st{watch = undefined}.

%%%===================================================================
%%% A pass
%%%===================================================================

run(Owner, AccountId, Full) ->
    maybe
        {ok, Account} ?= muse_mail_accounts:get(Owner, AccountId),
        {ok, #{<<"folders">> := Listed}} ?= muse_mail:request(Owner, AccountId, <<"folders">>, #{}, 60000),
        Folders = upsert_folders(Owner, Account, [F || F <- Listed, is_map(F)]),
        Order = lists:sort(fun(X, Y) -> sync_order(X) =< sync_order(Y) end,
                           [F || F <- Folders, maps:get(<<"noselect">>, F, false) =/= true]),
        Results = [{F, sync_folder(Owner, Account, F, Full)} || F <- Order],
        case [E || {_, {error, _} = E} <- Results] of
            [] ->
                {ok, #{<<"folders">> => length(Order),
                       <<"new">> => lists:sum([N || {_, {ok, N}} <- Results])}};
            [First | _] ->
                First
        end
    end.

sync_order(F) ->
    case maps:get(<<"role">>, F, null) of
        <<"inbox">> -> {0, <<>>};
        <<"sent">> -> {1, <<>>};
        <<"drafts">> -> {2, <<>>};
        <<"archive">> -> {3, <<>>};
        <<"junk">> -> {5, <<>>};
        <<"trash">> -> {6, <<>>};
        <<"all">> -> {7, <<>>};
        _ -> {4, maps:get(<<"path">>, F)}
    end.

%% Folder records from LIST; one folder per role; gone folders removed.
upsert_folders(Owner, #{<<"id">> := A}, Listed) ->
    Known = muse_mail:folders(Owner, A),
    {Saved, _} = lists:foldl(
                   fun(L = #{<<"path">> := Path}, {Acc, Roles}) ->
                           Fid = muse_mail:folder_id(Owner, A, Path),
                           Role0 = case maps:get(<<"role">>, L, null) of R when is_binary(R) -> R; _ -> null end,
                           Role = case lists:member(Role0, Roles) of true -> null; false -> Role0 end,
                           Status = case maps:get(<<"status">>, L, null) of S when is_map(S) -> S; _ -> #{} end,
                           Old = case [F || F = #{<<"id">> := I} <- Known, I =:= Fid] of [F] -> F; [] -> #{} end,
                           New = maps:merge(Old, #{<<"id">> => Fid, <<"accountId">> => A, <<"path">> => Path,
                                                   <<"name">> => maps:get(<<"name">>, L, Path),
                                                   <<"delimiter">> => maps:get(<<"delimiter">>, L, <<"/">>),
                                                   <<"role">> => Role,
                                                   <<"noselect">> => maps:get(<<"noselect">>, L, false) =:= true,
                                                   <<"total">> => int(<<"messages">>, Status),
                                                   <<"unread">> => int(<<"unseen">>, Status),
                                                   <<"statusUidNext">> => int(<<"uidNext">>, Status),
                                                   <<"statusUidValidity">> => maps:get(<<"uidValidity">>, Status, null)}),
                           Saved = case New =:= Old of
                                       true -> Old;
                                       false -> muse_store:put(Owner, <<"mail-folders">>, New)
                                   end,
                           {[Saved | Acc], [Role | Roles]}
                   end, {[], []}, lists:sort(fun(X, Y) -> listed_order(X) =< listed_order(Y) end, Listed)),
    Live = [I || #{<<"id">> := I} <- Saved],
    lists:foreach(fun(F = #{<<"id">> := I}) ->
                          case lists:member(I, Live) of
                              true -> ok;
                              false -> muse_mail:forget_folder(Owner, F)
                          end
                  end, Known),
    lists:reverse(Saved).

%% Folders flagged by the server come before name guesses of the same role.
listed_order(L) ->
    {maps:get(<<"specialUse">>, L, null) =:= null, maps:get(<<"path">>, L)}.

int(K, M) ->
    case maps:get(K, M, null) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

sync_folder(Owner, Account, Folder, Full) ->
    case Full orelse maps:get(<<"role">>, Folder, null) =:= <<"inbox">> orelse changed_status(Owner, Folder) of
        true -> do_sync_folder(Owner, Account, Folder);
        false -> {ok, 0}
    end.

changed_status(Owner, F = #{<<"id">> := Fid}) ->
    not (maps:get(<<"statusUidValidity">>, F, null) =:= maps:get(<<"uidValidity">>, F, undefined)
         andalso maps:get(<<"statusUidNext">>, F, 0) =:= maps:get(<<"uidNext">>, F, undefined)
         andalso maps:get(<<"unread">>, F, 0) =:= maps:get(<<"syncedUnread">>, F, undefined)
         andalso maps:get(<<"total">>, F, 0) =:= maps:get(<<"syncedTotal">>, F, undefined))
        orelse muse_mail:folder_messages(Owner, Fid) =:= [] andalso maps:get(<<"total">>, F, 0) > 0.

do_sync_folder(Owner, #{<<"id">> := A} = Account, #{<<"id">> := Fid, <<"path">> := Path} = Folder) ->
    Days = muse_config:get(mail_sync_days, 30),
    Max = muse_config:get(mail_sync_max, 500),
    SinceMs = muse_time:now_ms() - Days * 86400000,
    Since = muse_time:to_iso(SinceMs),
    Stored0 = muse_mail:folder_messages(Owner, Fid),
    Known = case Folder of
                #{<<"lastUid">> := L, <<"uidValidity">> := V} when is_integer(L), L > 0 ->
                    Uids = [U || #{<<"uid">> := U} <- Stored0],
                    #{<<"uidValidity">> => V, <<"lastUid">> => L, <<"minUid">> => lists:min([L | Uids])};
                _ -> null
            end,
    maybe
        {ok, #{<<"uidValidity">> := V1, <<"uids">> := Uids1, <<"flags">> := Flags} = Scan} ?=
            muse_mail:request(Owner, A, <<"scan">>, #{<<"path">> => Path, <<"known">> => Known,
                                                       <<"since">> => Since, <<"max">> => Max}, 120000),
        Fresh = maps:get(<<"fresh">>, Scan, false) =:= true,
        Stored = case Fresh andalso Stored0 =/= [] of
                     true -> lists:foreach(fun(M) -> muse_mail:remove_message(Owner, M) end, Stored0), [];
                     false -> Stored0
                 end,
        F1 = (maps:without([<<"lastUid">>], Folder))#{<<"uidValidity">> => V1},
        ByUid = maps:from_list([{U, M} || M = #{<<"uid">> := U} <- Stored]),
        %% flags and expunges in the stored range
        _ = case {Fresh, Known} of
                {false, #{<<"minUid">> := Lo, <<"lastUid">> := Hi}} ->
                    Present = maps:from_list([{U, Fl} || [U, Fl] <- Flags, is_integer(U), is_list(Fl)]),
                    [case maps:find(U, Present) of
                         {ok, Fl} -> muse_mail:update_message(Owner, M, Fl);
                         error when U >= Lo, U =< Hi -> muse_mail:remove_message(Owner, M);
                         error -> ok
                     end || U := M <- ByUid];
                _ -> ok
            end,
        Wanted = lists:reverse(lists:sort([U || U <- Uids1, is_integer(U), not maps:is_key(U, ByUid)])),
        {ok, New} ?= fetch_batches(Owner, Account, F1, Wanted, []),
        LastUid = lists:max([0, maps:get(<<"lastUid">>, case Known of null -> #{}; K -> K end, 0)
                             | [U || U <- Uids1, is_integer(U)]]),
        Pruned = muse_mail:prune(Owner, Fid, Since, Max),
        _ = muse_store:put(Owner, <<"mail-folders">>,
                           (current_folder(Owner, F1))#{<<"uidValidity">> => V1, <<"lastUid">> => LastUid,
                                                         <<"uidNext">> => maps:get(<<"statusUidNext">>, Folder, 0),
                                                         <<"syncedUnread">> => maps:get(<<"unread">>, Folder, 0),
                                                         <<"syncedTotal">> => maps:get(<<"total">>, Folder, 0),
                                                         <<"syncedAt">> => muse_time:now_iso()}),
        _ = Pruned,
        case {Known, maps:get(<<"role">>, Folder, null)} of
            {#{}, <<"inbox">>} when not Fresh -> muse_mail:notify_new(Owner, Account, New);
            _ -> ok
        end,
        {ok, length(New)}
    end.

%% The folder record as stored now (counts may have moved meanwhile).
current_folder(Owner, #{<<"id">> := Fid} = F) ->
    case muse_store:get(Owner, <<"mail-folders">>, Fid) of
        undefined -> F;
        Cur -> maps:merge(Cur, maps:with([<<"uidValidity">>], F))
    end.

fetch_batches(_Owner, _Account, _Folder, [], Acc) ->
    {ok, Acc};
fetch_batches(Owner, #{<<"id">> := A} = Account, #{<<"path">> := Path, <<"uidValidity">> := V} = Folder, Uids, Acc) ->
    {Batch, Rest} = lists:split(min(?BATCH, length(Uids)), Uids),
    case muse_mail:request(Owner, A, <<"fetch">>, #{<<"path">> => Path, <<"uidValidity">> => V, <<"uids">> => Batch,
                                                    <<"maxSource">> => ?MAX_SOURCE}, 180000) of
        {ok, #{<<"messages">> := Msgs}} ->
            Stored = [muse_mail:store_message(Owner, Account, Folder, M) || M <- Msgs, is_map(M),
                                                                         is_integer(maps:get(<<"uid">>, M, undefined))],
            muse_events:emit(Owner, {mail, A}),
            fetch_batches(Owner, Account, Folder, Rest, Acc ++ Stored);
        {error, _} = E ->
            E
    end.
