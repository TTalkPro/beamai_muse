%% @doc Scriptable `muse_task_runner` for engine tests. The script is read
%% from persistent_term on each run:
%%   {return, Patch} | {fail, Msg} | {wait, Ms, Patch} | {crash, Reason}
%%   | {checkpoint_wait, Patch, Ms, Result}
-module(muse_test_runner).
-behaviour(muse_task_runner).

-export([set/1, run/3]).

set(Script) ->
    persistent_term:put(?MODULE, Script).

run(_Owner, _Task, #{checkpoint := Checkpoint} = Ctx) ->
    persistent_term:put({?MODULE, last_ctx}, maps:with([task_id, lease_id, exec_pid], Ctx)),
    case persistent_term:get(?MODULE, {return, #{<<"status">> => <<"succeeded">>}}) of
        {return, Patch} -> Patch;
        {fail, Msg} -> throw({task_failed, Msg});
        {crash, Reason} -> error(Reason);
        {wait, Ms, Patch} -> timer:sleep(Ms), Patch;
        {checkpoint_wait, Patch, Ms, Result} ->
            _ = Checkpoint(Patch),
            timer:sleep(Ms),
            _ = Checkpoint(#{<<"result">> => <<"late write">>}),
            Result
    end.
