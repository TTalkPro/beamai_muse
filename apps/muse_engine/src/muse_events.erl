%% @doc Domain change notifications for live UIs (designs/02-engine.md §4).
%%
%% The engine calls `emit/2` after writes; subscribers (the aihtml bridge in
%% muse_web) join the owner's group and receive `{muse_event, Owner, Event}`.
%% Events: `{task, Id}`, `{run_event, TaskId, Event}`, `{action, Id}`,
%% `{notification, Id}`, `{monitor | goal | idea | memory | identity, Id}`.
%% Emitting never fails the caller.
-module(muse_events).

-export([start_link/0, emit/2, subscribe/1, unsubscribe/1]).

-define(SCOPE, muse_events).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    pg:start_link(?SCOPE).

-spec emit(binary(), term()) -> ok.
emit(Owner, Event) ->
    try
        _ = [Pid ! {muse_event, Owner, Event} || Pid <- pg:get_members(?SCOPE, {owner, Owner})],
        ok
    catch
        _:_ -> ok
    end.

-spec subscribe(binary()) -> ok.
subscribe(Owner) ->
    pg:join(?SCOPE, {owner, Owner}, self()).

-spec unsubscribe(binary()) -> ok | not_joined.
unsubscribe(Owner) ->
    pg:leave(?SCOPE, {owner, Owner}, self()).
