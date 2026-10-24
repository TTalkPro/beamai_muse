%% @doc Background maintenance, every 60 s and once at start
%% (OpenMuse service.ts `maintain`, engine spec §5.13). A pass that is still
%% running when the next one is due is skipped.
%%
%% OpenMuse jobs: re-publish task outcomes (crash between commit and
%% publication), re-activate monitors, recover accepted ideas whose task was
%% never created, refresh ideas every 15 minutes per owner.
%% Added here: drop expired sessions and OAuth states.
-module(muse_maintainer).
-behaviour(gen_server).

-export([start_link/0, run_once/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(INTERVAL, 60000).
-define(IDEAS_EVERY, 15 * 60000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Run one pass synchronously (tests and the first pass).
-spec run_once() -> ok.
run_once() ->
    gen_server:call(?MODULE, run, 120000).

init([]) ->
    self() ! tick,
    {ok, #{}}.

handle_call(run, _From, State) ->
    {reply, maintain(), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    _ = maintain(),
    erlang:send_after(application:get_env(muse_engine, maintain_ms, ?INTERVAL), self(), tick),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

maintain() ->
    Jobs = [fun publish_outcomes/0, fun activate_monitors/0, fun recover_ideas/0,
            fun refresh_ideas/0, fun purge/0],
    lists:foreach(fun(Job) ->
                          try Job()
                          catch Class:Reason:St ->
                              logger:warning("maintenance job failed: ~p:~p ~p", [Class, Reason, St])
                          end
                  end, Jobs).

publish_outcomes() ->
    [muse_agent_service:publish_outcome(O, T) || {O, T} <- muse_store:scan(<<"tasks">>)].

activate_monitors() ->
    [muse_monitors:activate(O, M) || {O, M} <- muse_store:scan(<<"monitors">>)].

recover_ideas() ->
    [recover_idea(O, I) || {O, I = #{<<"status">> := <<"accepted">>, <<"taskId">> := T}} <- muse_store:scan(<<"ideas">>),
                           is_binary(T), muse_store:get(O, <<"tasks">>, T) =:= undefined].

recover_idea(Owner, #{<<"id">> := Id}) ->
    case catch muse_ideas:decide(Owner, Id, <<"accept">>, undefined) of
        {ok, _} -> ok;
        _ ->
            muse_agent_service:notify(Owner, <<"Accepted idea needs attention">>,
                                      <<"Open the idea again after making room for another task.">>,
                                      undefined, <<"idea-recovery:", Id/binary>>)
    end.

refresh_ideas() ->
    Now = muse_time:now_ms(),
    [refresh(O, Now) || {O, S = #{<<"id">> := <<"identity">>}} <- muse_store:scan(<<"agent-settings">>),
                        stale(maps:get(<<"lastIdeasAt">>, S, undefined), Now)].

stale(undefined, _) -> true;
stale(At, Now) ->
    case muse_time:parse(At) of
        nan -> true;
        Ms -> Now - Ms > ?IDEAS_EVERY
    end.

refresh(Owner, Now) ->
    case catch muse_ideas:refresh(Owner) of
        {ok, _} -> ok;
        _ ->
            muse_agent_service:notify(Owner, <<"Source refresh needs attention">>,
                                      <<"Reconnect the source or refresh Ideas to see the error.">>, undefined,
                                      <<"source-error:", (integer_to_binary(Now div 3600000))/binary>>)
    end.

purge() ->
    _ = muse_auth:purge_expired(),
    Now = muse_time:now_ms(),
    [muse_store:remove(<<"system">>, <<"oauth">>, Id)
     || #{<<"id">> := Id, <<"expiresAt">> := Exp} <- muse_store:list(<<"system">>, <<"oauth">>),
        is_integer(Exp), Exp < Now],
    ok.
