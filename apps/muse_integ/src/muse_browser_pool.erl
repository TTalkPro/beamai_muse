%% @doc Idle stop of the per-user browser containers (muse_browser_docker;
%% not in OpenMuse).
%%
%% Every minute (app env `browser_sweep_ms`; `browser_pool_timer = false`
%% turns the timer off, tests call `sweep/0`) the running browser
%% containers of this deployment are listed by label; one whose owner has
%% not used the browser (muse_browser_docker:touch/1: every request,
%% including the console's screenshot poll) for BROWSER_IDLE_MINUTES
%% (default 30) is stopped. Its profile volume is kept, and the next use
%% starts it again. A running container whose owner is unknown to the store
%% is stopped too. Browser containers do not count against
%% COMPUTER_MAX_RUNNING.
%%
%% The gen_server owns the in-memory activity table, and the console's
%% pressed points (`press/3`, `release/2`): a press on the console's picture
%% and its release arrive as two actions, so a drag (a slider captcha) is
%% the release's point together with the stored press, kept 15 s.
-module(muse_browser_pool).
-behaviour(gen_server).

-export([start_link/0, sweep/0, idle_minutes/0, press/3, release/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(INTERVAL, 60000).
-define(MINUTE, 60000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec idle_minutes() -> pos_integer().
idle_minutes() ->
    muse_config:get(browser_idle_minutes, 30).

%% @doc Stop the idle browser containers once. Without BROWSER_ENABLED: nothing.
-spec sweep() -> ok.
sweep() ->
    case muse_config:browser_configured() of
        false -> ok;
        true ->
            case muse_browser_docker:containers() of
                {ok, Containers} ->
                    Owners = owners(),
                    Now = muse_time:now_ms(),
                    Idle = idle_minutes() * ?MINUTE,
                    lists:foreach(fun(C) -> sweep_one(C, Owners, Now, Idle) end, Containers);
                {error, {_, Msg}} ->
                    logger:warning("browser pool: cannot list containers: ~ts", [Msg])
            end
    end.

sweep_one({Name, <<"running">>, Hash}, Owners, Now, Idle) ->
    Unused = case maps:get(Hash, Owners, undefined) of
                 undefined -> Idle;
                 Owner -> Now - muse_browser_docker:last_used(Owner)
             end,
    case Unused >= Idle of
        true ->
            case muse_docker:run(muse_docker:stop_args(Name), #{timeout => muse_docker:control_timeout()}) of
                #{exit_code := 0} -> logger:info("browser pool: idle stop of ~ts", [Name]);
                _ -> logger:warning("browser pool: could not stop ~ts", [Name])
            end;
        false ->
            ok
    end;
sweep_one(_, _, _, _) ->
    ok.

%% Owner hash -> owner, for the owners that used the browser.
owners() ->
    maps:from_list([{binary:part(muse_ids:sha256hex(O), 0, 24), O}
                    || {O, _} <- muse_store:scan(<<"browser-hosts">>)]).

%% @doc Remember where the person pressed on a session's console picture
%% (viewport coordinates).
-spec press(binary(), binary(), {number(), number()}) -> ok.
press(Owner, Session, Point) ->
    true = ets:insert(muse_browser_press, {{Owner, Session}, Point, erlang:monotonic_time(millisecond)}),
    ok.

%% @doc The pressed point of the session's console, once (`undefined` when
%% there was none in the last 15 s).
-spec release(binary(), binary()) -> {number(), number()} | undefined.
release(Owner, Session) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:take(muse_browser_press, {Owner, Session}) of
        [{_, Point, At}] when Now - At =< 15000 -> Point;
        _ -> undefined
    end.

%% gen_server

init([]) ->
    _ = ets:new(muse_browser_activity, [named_table, public, set, {write_concurrency, true}]),
    _ = ets:new(muse_browser_press, [named_table, public, set]),
    _ = application:get_env(muse_integ, browser_pool_timer, true) andalso schedule(),
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    try sweep()
    catch Class:Reason:St ->
        logger:warning("browser pool sweep failed: ~p:~p ~p", [Class, Reason, St])
    end,
    schedule(),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

schedule() ->
    erlang:send_after(application:get_env(muse_integ, browser_sweep_ms, ?INTERVAL), self(), tick).
