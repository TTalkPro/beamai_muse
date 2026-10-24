%% @doc Domain events -> live page updates (designs/02-engine.md §4,
%% 05-web-ui.md §3). One process per signed-in owner, joined to the
%% owner's muse_events group; each event is offered to every page module
%% that exports `on_event/2` (failures are logged, never fatal).
-module(muse_ui_bridge).
-behaviour(gen_server).

-export([start_link/1, ensure/1, child_spec/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => muse_ui_bridge_sup, type => supervisor,
      start => {supervisor, start_link, [{local, muse_ui_bridge_sup}, muse_ui_bridge_sup_cb, []]}}.

%% @doc Make sure the owner's bridge runs.
-spec ensure(binary()) -> ok.
ensure(Owner) ->
    case supervisor:start_child(muse_ui_bridge_sup, [Owner]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason} -> logger:warning("ui bridge for ~ts: ~p", [Owner, Reason]), ok
    end.

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(Owner) ->
    gen_server:start_link({via, global, {?MODULE, Owner}}, ?MODULE, Owner, []).

init(Owner) ->
    ok = muse_events:subscribe(Owner),
    {ok, Owner}.

handle_call(_Msg, _From, Owner) -> {reply, ok, Owner}.
handle_cast(_Msg, Owner) -> {noreply, Owner}.

handle_info({muse_event, Owner, Event}, Owner) ->
    lists:foreach(fun(M) ->
                          _ = code:ensure_loaded(M),
                          case erlang:function_exported(M, on_event, 2) of
                              true ->
                                  try M:on_event(Owner, Event)
                                  catch C:R:St -> logger:warning("ui ~p on_event ~0p: ~p:~p ~p", [M, Event, C, R, St])
                                  end;
                              false -> ok
                          end
                  end, [muse_ui_layout | [M || {_, M} <- muse_ui_page:modules()]]),
    {noreply, Owner};
handle_info(_Msg, Owner) ->
    {noreply, Owner}.
