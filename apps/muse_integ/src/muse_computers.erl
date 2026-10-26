%% @doc Registry of the computer pool (designs/04-integrations.md §3; not in
%% OpenMuse, which has one computer per owner).
%%
%% A computer belongs to a scope: a conversation (`thread:<threadId>`) or a
%% background task (`task:<taskId>`). Scope `user` is the legacy computer: an
%% older version's single default computer per owner, kept (never deleted
%% automatically, shown as 旧的默认电脑) but never created any more.
%% Its id is a hash of owner and scope, so the same scope
%% always finds the same computer and the agent never has to remember an id.
%%
%% Record `computers/<id>` per owner: `{id, scope, title, container, volume,
%% variant, status, createdAt, lastUsedAt, startedAt}`. `status` is the last
%% observed state (`running | stopped | error`); Docker stays the truth and
%% the pool sweeper (muse_computer_pool) reconciles the records with it.
%% Timestamps are ISO strings; `startedAt` is null while stopped.
%%
%% Titles are resolved when listed (conversation or task title from their
%% records, so renames show up), falling back to the stored title.
-module(muse_computers).

-export([kind/0, legacy_scope/0, id/2, legacy_id/1, ensure/2, get/2, list/1, all/0,
         touch/2, set_status/3, remove/2, title/2, scope_kind/1, valid_scope/1]).

-export_type([computer/0]).

-type computer() :: #{binary() => term()}.

-define(KIND, <<"computers">>).
-define(DEFAULT, <<"user">>).

-spec kind() -> binary().
kind() -> ?KIND.

%% @doc The scope of an older version's default computer.
-spec legacy_scope() -> binary().
legacy_scope() -> ?DEFAULT.

%% @doc The computer id of a scope: 16 hex characters.
-spec id(binary(), binary()) -> binary().
id(Owner, Scope) ->
    binary:part(muse_ids:sha256hex(<<"computer:", Owner/binary, 0, Scope/binary>>), 0, 16).

-spec legacy_id(binary()) -> binary().
legacy_id(Owner) ->
    id(Owner, ?DEFAULT).

%% @doc `user`, `thread:<id>` or `task:<id>` with a nonblank id of at most
%% 200 characters and no control characters.
-spec valid_scope(term()) -> boolean().
valid_scope(?DEFAULT) -> true;
valid_scope(<<"thread:", Id/binary>>) -> valid_ref(Id);
valid_scope(<<"task:", Id/binary>>) -> valid_ref(Id);
valid_scope(_) -> false.

valid_ref(Id) ->
    Id =/= <<>> andalso byte_size(Id) =< 200
        andalso re:run(Id, <<"[\\x00-\\x1f\\x7f]">>, [{capture, none}]) =:= nomatch.

%% @doc The record of `Scope`, created (stopped) when missing.
-spec ensure(binary(), binary()) -> computer().
ensure(Owner, Scope) ->
    valid_scope(Scope) orelse erlang:error({invalid_computer_scope, Scope}),
    Id = id(Owner, Scope),
    case muse_store:get(Owner, ?KIND, Id) of
        undefined ->
            #{container := Container, volume := Volume} = muse_computer:identity({Owner, Id}),
            Now = muse_time:now_iso(),
            New = #{<<"id">> => Id, <<"scope">> => Scope,
                    <<"title">> => stored_title(Owner, Scope),
                    <<"container">> => Container, <<"volume">> => Volume,
                    <<"variant">> => atom_to_binary(muse_computer_docker:variant()),
                    <<"status">> => <<"stopped">>,
                    <<"createdAt">> => Now, <<"lastUsedAt">> => Now, <<"startedAt">> => null},
            case muse_store:insert_if_absent(Owner, ?KIND, New) of
                undefined -> muse_store:get(Owner, ?KIND, Id);
                Inserted -> Inserted
            end;
        Existing ->
            Existing
    end.

-spec get(binary(), binary()) -> computer() | undefined.
get(Owner, Id) when is_binary(Id) ->
    muse_store:get(Owner, ?KIND, Id);
get(_, _) ->
    undefined.

%% @doc The owner's computers, most recently used first.
-spec list(binary()) -> [computer()].
list(Owner) ->
    lists:sort(fun(A, B) -> used(A) >= used(B) end, muse_store:list(Owner, ?KIND)).

%% @doc Every owner's computers (the sweeper; one deployment per store).
-spec all() -> [{binary(), computer()}].
all() ->
    muse_store:scan(?KIND).

%% @doc Mark the computer used now (idle stop and retention count from here).
-spec touch(binary(), binary()) -> ok.
touch(Owner, Id) ->
    _ = muse_store:cas(Owner, ?KIND, Id, #{}, #{<<"lastUsedAt">> => muse_time:now_iso()}),
    ok.

%% @doc Record an observed state; `startedAt` follows running.
-spec set_status(binary(), binary(), binary()) -> ok.
set_status(Owner, Id, Status) ->
    _ = muse_store:update(Owner, ?KIND, Id,
                          fun(#{<<"status">> := Current}) when Current =:= Status ->
                                  abort;
                             (C) ->
                                  Started = case Status of
                                                <<"running">> -> muse_time:now_iso();
                                                _ -> null
                                            end,
                                  {ok, C#{<<"status">> => Status, <<"startedAt">> => Started}}
                          end),
    ok.

-spec remove(binary(), binary()) -> ok.
remove(Owner, Id) ->
    muse_store:remove(Owner, ?KIND, Id).

%% @doc The display title: the conversation or task title, else the stored
%% title.
-spec title(binary(), computer()) -> binary().
title(Owner, #{<<"scope">> := Scope} = C) ->
    case live_title(Owner, Scope) of
        undefined -> maps:get(<<"title">>, C, Scope);
        T -> T
    end.

%% @doc `thread | task | user`.
-spec scope_kind(binary()) -> thread | task | user.
scope_kind(<<"thread:", _/binary>>) -> thread;
scope_kind(<<"task:", _/binary>>) -> task;
scope_kind(_) -> user.

%% Internal

used(C) -> maps:get(<<"lastUsedAt">>, C, <<>>).

stored_title(Owner, Scope) ->
    case live_title(Owner, Scope) of
        undefined when Scope =:= ?DEFAULT -> <<"旧的默认电脑"/utf8>>;
        undefined -> Scope;
        T -> T
    end.

%% The thread and task records belong to muse_agent and muse_engine; only
%% their stored `title` is read here.
live_title(_Owner, ?DEFAULT) ->
    <<"旧的默认电脑"/utf8>>;
live_title(Owner, <<"thread:", Id/binary>>) ->
    record_title(Owner, <<"threads">>, Id);
live_title(Owner, <<"task:", Id/binary>>) ->
    record_title(Owner, <<"tasks">>, Id);
live_title(_, _) ->
    undefined.

record_title(Owner, Kind, Id) ->
    case muse_store:get(Owner, Kind, Id) of
        #{<<"title">> := T} when is_binary(T), T =/= <<>> -> T;
        _ -> undefined
    end.
