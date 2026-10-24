-module(muse_agent_app).
-behaviour(application).

-export([start/2, stop/1]).

%% Model tasks run through muse_task_model; the engine only knows the
%% muse_task_runner behaviour.
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case application:get_env(muse_engine, task_runner) of
        undefined -> ok = application:set_env(muse_engine, task_runner, muse_task_model);
        {ok, _} -> ok
    end,
    muse_agent_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
