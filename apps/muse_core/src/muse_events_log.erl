%% @doc Task run events (OpenMuse `run-events`) as an append-only bitcask log.
%%
%% Key: `ev/<Owner>/<TaskId>/<Seq>`; value: the event JSON
%% `{id, taskId, date, kind, title, detail}` (designs/ref/openmuse-engine-spec.md §2.3).
%% Owner and task ids never contain `/` (uuid / hex / "local-user").
-module(muse_events_log).

-export([append/3, list/2, delete_task/2]).

-define(CASK, events).

-spec append(binary(), binary(), map()) -> {ok, map()} | {error, term()}.
append(Owner, TaskId, Event0) ->
    Event = maps:merge(#{<<"id">> => muse_ids:uuid(),
                         <<"taskId">> => TaskId,
                         <<"date">> => muse_time:now_iso()}, Event0),
    Prefix = prefix(Owner, TaskId),
    case muse_cask:append(?CASK, fun(Seq) ->
                                     [{put, <<Prefix/binary, Seq/binary>>, muse_json:encode(Event)}]
                                 end, no_sync) of
        {ok, _Seq} -> {ok, Event};
        Error -> Error
    end.

%% @doc Events of one task, oldest first.
-spec list(binary(), binary()) -> [map()].
list(Owner, TaskId) ->
    [decode(V) || {_K, V} <- muse_cask:range_prefix(?CASK, prefix(Owner, TaskId))].

-spec delete_task(binary(), binary()) -> ok | {error, term()}.
delete_task(Owner, TaskId) ->
    Keys = muse_cask:keys_prefix(?CASK, prefix(Owner, TaskId)),
    muse_cask:commit(?CASK, [{remove, K} || K <- Keys]).

prefix(Owner, TaskId) ->
    <<"ev/", Owner/binary, "/", TaskId/binary, "/">>.

decode(V) ->
    {ok, Event} = muse_json:decode(V),
    Event.
