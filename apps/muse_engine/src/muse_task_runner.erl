%% @doc Behaviour for open-ended (model) task execution, injected by
%% muse_agent at boot so the engine does not depend on it
%% (`application:set_env(muse_engine, task_runner, Module)`).
%%
%% Without a runner the task waits for input with OpenMuse's
%% "A model is required" question (engine spec §7 step 1).
-module(muse_task_runner).

-export([run/3]).

-callback run(Owner :: binary(), Task :: map(), Ctx :: muse_task_run:ctx()) -> map().

-spec run(binary(), map(), muse_task_run:ctx()) -> map().
run(Owner, Task, Ctx) ->
    case application:get_env(muse_engine, task_runner) of
        {ok, Module} -> Module:run(Owner, Task, Ctx);
        undefined ->
            #{<<"status">> => <<"waiting_input">>,
              <<"question">> => <<"A model is required for this open-ended task. Configure MODEL and its "
                                  "provider key on the server, then reply ‘continue’. The document, "
                                  "monitor and finance workflows can run without a model."/utf8>>}
    end.
