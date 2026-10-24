%% @doc Engine test environment: sample-mode config, Mnesia in RAM, signing
%% key, the casks, the PDF helper, domain events and a manually ticked
%% task worker (poll interval of an hour; tests call muse_task_worker:tick/0).
-module(muse_engine_test_env).

-export([start/0, start/1, stop/1, wait_idle/0, wait_for/2, run_pending/0]).

start() ->
    start(#{}).

start(Env) ->
    Dir = "/tmp/muse_engine_" ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, Config} = muse_config:from_env(Env#{<<"DATA_DIR">> => list_to_binary(Dir)}),
    muse_config:set(Config),
    {ok, _} = application:ensure_all_started([bitcask, beamai_core]),
    ok = muse_store:init(#{storage => ram}),
    ok = muse_signing:init(Dir),
    Casks = [begin
                 {ok, P} = muse_cask:start_link(N, filename:join(Dir, atom_to_list(N)), []),
                 unlink(P), N
             end || N <- [events, blobs]],
    {ok, Pdf} = muse_pdf:start_link(), unlink(Pdf),
    {ok, Events} = muse_events:start_link(), unlink(Events),
    ok = application:set_env(muse_engine, poll_ms, 3600000),
    ok = application:set_env(muse_engine, task_runner, muse_test_runner),
    {ok, Worker} = muse_task_worker:start_link(), unlink(Worker),
    #{dir => Dir, casks => Casks, pdf => Pdf, events => Events, worker => Worker}.

stop(#{dir := Dir, casks := Casks, pdf := Pdf, events := Events, worker := Worker}) ->
    gen_server:stop(Worker),
    exit(Events, kill),
    gen_server:stop(Pdf),
    [muse_cask:stop(C) || C <- Casks],
    muse_store:stop(),
    application:unset_env(muse_engine, task_runner),
    os:cmd("rm -rf " ++ Dir),
    ok.

%% @doc Tick until nothing is due and no run is in flight.
run_pending() ->
    run_pending(50).

run_pending(0) -> error(runs_did_not_settle);
run_pending(N) ->
    Started = muse_task_worker:tick(),
    wait_idle(),
    case Started of
        [] -> ok;
        _ -> run_pending(N - 1)
    end.

wait_idle() ->
    wait_for(fun() -> muse_task_worker:in_flight() =:= [] end, 10000).

wait_for(Fun, Ms) when Ms =< 0 ->
    Fun() orelse error(timeout_waiting);
wait_for(Fun, Ms) ->
    case Fun() of
        true -> true;
        false -> timer:sleep(20), wait_for(Fun, Ms - 20)
    end.
