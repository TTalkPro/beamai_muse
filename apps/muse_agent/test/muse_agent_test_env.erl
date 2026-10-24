%% @doc muse_agent test environment: sample config, Mnesia in RAM, casks,
%% PDF helper, domain events, beamai apps, a manually ticked task worker
%% running muse_task_model against the scripted provider.
-module(muse_agent_test_env).

-export([start/0, start/1, stop/1, run_pending/0, wait_for/2]).

start() ->
    start(#{}).

start(Env) ->
    Dir = "/tmp/muse_agent_" ++ integer_to_list(erlang:unique_integer([positive])),
    Env1 = maps:merge(#{<<"WEB_SEARCH_ENABLED">> => <<"false">>}, Env),
    {ok, Config} = muse_config:from_env(Env1#{<<"DATA_DIR">> => list_to_binary(Dir)}),
    muse_config:set(Config),
    {ok, _} = application:ensure_all_started([bitcask, beamai_core, beamai_llm, beamai_agent, beamai_agui]),
    ok = muse_store:init(#{storage => ram}),
    ok = muse_signing:init(Dir),
    Casks = [begin
                 Opts = case N of chat_index -> [{analyzer, jieba}]; _ -> [] end,
                 {ok, P} = muse_cask:start_link(N, filename:join(Dir, atom_to_list(N)), Opts),
                 unlink(P), N
             end || N <- [events, blobs, chat, chat_index]],
    {ok, Pdf} = muse_pdf:start_link(), unlink(Pdf),
    Events = case muse_events:start_link() of
                 {ok, E} -> unlink(E), E;
                 {error, {already_started, E}} -> E
             end,
    ok = application:set_env(muse_engine, poll_ms, 3600000),
    ok = application:set_env(muse_engine, task_runner, muse_task_model),
    ok = application:set_env(muse_agent, llm, muse_script_llm:model()),
    {ok, Worker} = muse_task_worker:start_link(), unlink(Worker),
    #{dir => Dir, casks => Casks, pdf => Pdf, events => Events, worker => Worker}.

stop(#{dir := Dir, casks := Casks, pdf := Pdf, events := Events, worker := Worker}) ->
    gen_server:stop(Worker),
    exit(Events, kill),
    gen_server:stop(Pdf),
    [muse_cask:stop(C) || C <- Casks],
    muse_store:stop(),
    application:unset_env(muse_engine, task_runner),
    application:unset_env(muse_agent, llm),
    application:unset_env(muse_agent, task_model_timeout_ms),
    os:cmd("rm -rf " ++ Dir),
    ok.

run_pending() ->
    run_pending(50).

run_pending(0) -> error(runs_did_not_settle);
run_pending(N) ->
    Started = muse_task_worker:tick(),
    wait_for(fun() -> muse_task_worker:in_flight() =:= [] end, 20000),
    case Started of
        [] -> ok;
        _ -> run_pending(N - 1)
    end.

wait_for(Fun, Ms) when Ms =< 0 ->
    Fun() orelse error(timeout_waiting);
wait_for(Fun, Ms) ->
    case Fun() of
        true -> true;
        false -> timer:sleep(20), wait_for(Fun, Ms - 20)
    end.
