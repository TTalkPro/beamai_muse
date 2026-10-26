%% @doc The engine application. Its start registers the built-in action
%% kinds: `calendar.event` (muse_calendar_action), the agent's reviewed
%% writes to the built-in calendar, and `mail.send` (muse_mail_action), the
%% agent's reviewed sends from the built-in mail.
-module(muse_engine_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    ok = muse_calendar_action:register(),
    ok = muse_mail_action:register(),
    muse_engine_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok = muse_calendar_action:unregister(),
    ok = muse_mail_action:unregister().
