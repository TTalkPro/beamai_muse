-module(muse_computer_tests).
-include_lib("eunit/include/eunit.hrl").

%% Port of OpenMuse tests/computer.test.ts: `muse_docker:run/2` is replaced
%% by the fixture runner of tests/helpers/computer.ts.

-define(O, <<"owner">>).
-define(T, muse_computer_fixture).
-define(RECEIPTS, <<"computer-commands">>).

%% Pure

workspace_path_test_() ->
    {setup, fun() -> config(true) end, fun(_) -> ok end,
     fun(_) ->
             P = fun muse_computer:workspace_path/1,
             Bad = {error, {422, <<"Choose an absolute path inside /workspace">>}},
             [?_assertEqual({ok, <<"/workspace">>}, P(<<"/workspace">>)),
              ?_assertEqual({ok, <<"/workspace">>}, P(<<"/workspace/.">>)),
              ?_assertEqual({ok, <<"/workspace/">>}, P(<<"/workspace/">>)),
              ?_assertEqual({ok, <<"/workspace/a/b">>}, P(<<"/workspace//a/./b">>)),
              ?_assertEqual({ok, <<"/workspace/a/">>}, P(<<"/workspace/a//">>)),
              ?_assertEqual(Bad, P(<<"/etc/passwd">>)),
              ?_assertEqual(Bad, P(<<"/workspace/../secret">>)),
              ?_assertEqual(Bad, P(<<"/workspace/a/..">>)),
              ?_assertEqual(Bad, P(<<"relative">>)),
              ?_assertEqual(Bad, P(<<"/workspacefoo">>)),
              ?_assertEqual(Bad, P(<<"/workspace", 0, "/file">>)),
              ?_assertEqual(Bad, P(<<"/workspace/", (binary:copy(<<"a">>, 2048))/binary>>)),
              ?_assertEqual(Bad, P(42))]
     end}.

identity_test() ->
    config(true),
    Dep = binary:part(muse_ids:sha256hex(<<"http://localhost:8787">>), 0, 16),
    OwnerHash = binary:part(muse_ids:sha256hex(<<"local-user">>), 0, 24),
    Name = <<"openmuse-", Dep/binary, "-", OwnerHash/binary>>,
    ?assertMatch(#{container := <<Name:50/binary, "-computer">>,
                   volume := <<Name:50/binary, "-workspace">>,
                   labels := [{<<"dev.openmuse.managed">>, <<"computer-v1">>},
                              {<<"dev.openmuse.deployment">>, Dep},
                              {<<"dev.openmuse.owner">>, OwnerHash}]},
                 muse_computer:identity(<<"local-user">>)),
    config(true, #{<<"COMPUTER_DEPLOYMENT_ID">> => <<"dep-1">>}),
    #{deployment := Dep2} = muse_computer:identity(<<"local-user">>),
    ?assertEqual(binary:part(muse_ids:sha256hex(<<"dep-1">>), 0, 16), Dep2).

%% Service

service_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [{"disabled computer reports setup without invoking Docker", fun disabled/0},
      {"commands run solely as docker argv and persist failed receipts", fun failed_receipt/0},
      {"a running command holds the lease", fun lease_busy/0},
      {"timeouts are durable and idempotent commands never replay", fun timeout_replay/0},
      {"replay with a different command is refused", fun replay_mismatch/0},
      {"attaching fails closed on unsafe isolation or labels", fun isolation/0},
      {"volume ownership is verified", fun volume_mismatch/0},
      {"paths cannot escape and contents travel on stdin", fun paths_and_stdin/0},
      {"file operation failures map to 422/502/413", fun file_errors/0},
      {"Stop interrupts an active command", fun stop_interrupts/0},
      {"exit 137 without a stop is failed", fun exit_137/0},
      {"exit 124 is timed_out without stopping", fun exit_124/0},
      {"restart waits for the delayed executor", fun restart_waits/0},
      {"failed Stop keeps the quarantine and can be retried", fun failed_stop/0},
      {"timeout with unconfirmed cleanup stays quarantined", fun unconfirmed_cleanup/0},
      {"expired lease of a dead executor recovers as interrupted", fun dead_executor/0},
      {"Stop quarantine before the lease check keeps its record", fun quarantine_race/0},
      {"command marked dead after the lease check never runs", fun dead_row/0},
      {"caller death stops the container", fun caller_death/0},
      {"cancel pid death stops the container", fun cancel_death/0},
      {"stopped computer refuses commands", fun not_running/0},
      {"start creates volume and container with exact argv", fun start_missing/0},
      {"snapshot reports inspection errors", fun snapshot_error/0},
      {"PDF import and export", fun pdf_bridge/0}]}.

setup() ->
    ok = muse_store:init(#{storage => ram}),
    config(true),
    Holder = spawn(fun() -> receive stop -> ok end end),
    ets:new(?T, [named_table, public, {heir, none}]) =:= ?T orelse error(ets),
    ets:give_away(?T, Holder, none),
    ets:insert(?T, [{hook, fun(_, _) -> default end}, {inspect, sandbox(true)},
                    {missing, false}, {test, self()}]),
    meck:new(muse_docker, [passthrough]),
    meck:expect(muse_docker, run, fun runner/2),
    meck:new(muse_files, [non_strict]),
    Holder.

cleanup(Holder) ->
    meck:unload(),
    Holder ! stop,
    muse_store:stop().

config(Enabled) ->
    config(Enabled, #{}).

config(Enabled, Extra) ->
    Env = maps:merge(#{<<"COMPUTER_ENABLED">> => atom_to_binary(Enabled)}, Extra),
    {ok, C} = muse_config:from_env(Env),
    muse_config:set(C).

ok(Stdout) ->
    #{stdout => Stdout, stderr => <<>>, exit_code => 0, timed_out => false,
      interrupted => false, truncated => false}.

hook(Fun) -> ets:insert(?T, {hook, Fun}).

set_running(Bool) ->
    [{inspect, I = #{<<"State">> := S}}] = ets:lookup(?T, inspect),
    ets:insert(?T, {inspect, I#{<<"State">> := S#{<<"Running">> := Bool}}}).

calls() ->
    lists:sort([{N, A, Opts} || {{call, N}, A, Opts} <- ets:tab2list(?T)]).

exec_calls() ->
    [C || C = {_, [<<"exec">> | _], _} <- calls()].

runner(Args, Opts) ->
    ets:insert(?T, {{call, erlang:unique_integer([monotonic, positive])}, Args, Opts}),
    [{hook, Hook}] = ets:lookup(?T, hook),
    case Hook(Args, Opts) of
        default -> default_reply(Args);
        Result -> Result
    end.

default_reply([<<"container">>, <<"ls">> | _]) ->
    case ets:lookup(?T, missing) of
        [{missing, true}] -> ok(<<>>);
        _ -> ok(<<"container-id\n">>)
    end;
default_reply([<<"container">>, <<"inspect">> | _]) ->
    [{inspect, I}] = ets:lookup(?T, inspect),
    ok(muse_json:encode([I]));
default_reply([<<"volume">>, <<"ls">> | _]) ->
    ok(maps:get(volume, muse_computer:identity(?O)));
default_reply([<<"volume">>, <<"inspect">> | _]) ->
    #{volume := V, labels := L} = muse_computer:identity(?O),
    ok(muse_json:encode([#{<<"Name">> => V, <<"Labels">> => maps:from_list(L),
                           <<"Driver">> => <<"local">>, <<"Options">> => null,
                           <<"Scope">> => <<"local">>}]));
default_reply([<<"exec">> | _]) ->
    ok(<<"hello\n">>);
default_reply(_) ->
    ok(<<>>).

sandbox(Running) ->
    #{container := C, volume := V, labels := L} = muse_computer:identity(?O),
    #{<<"Id">> => <<"container-id">>,
      <<"Name">> => <<"/", C/binary>>,
      <<"Config">> => #{<<"Image">> => <<"openmuse-computer:local">>,
                        <<"User">> => <<"1000:1000">>,
                        <<"Labels">> => maps:from_list(L),
                        <<"Env">> => [<<"PATH=/usr/local/bin:/usr/bin:/bin">>,
                                      <<"HOME=/workspace">>, <<"LANG=C.UTF-8">>],
                        <<"Entrypoint">> => [<<"/usr/bin/sleep">>],
                        <<"Cmd">> => [<<"infinity">>],
                        <<"WorkingDir">> => <<"/workspace">>},
      <<"HostConfig">> => #{<<"ReadonlyRootfs">> => true, <<"Privileged">> => false,
                            <<"CapDrop">> => [<<"ALL">>], <<"CapAdd">> => null,
                            <<"SecurityOpt">> => [<<"no-new-privileges">>],
                            <<"NetworkMode">> => <<"none">>,
                            <<"Memory">> => 536870912, <<"MemorySwap">> => 536870912,
                            <<"PidsLimit">> => 128, <<"NanoCpus">> => 1000000000,
                            <<"Binds">> => null, <<"Devices">> => [],
                            <<"DeviceRequests">> => null, <<"PortBindings">> => #{},
                            <<"PidMode">> => <<>>, <<"IpcMode">> => <<"private">>,
                            <<"Tmpfs">> => #{<<"/tmp">> =>
                                                 <<"rw,nosuid,nodev,noexec,size=67108864,mode=1777">>},
                            <<"RestartPolicy">> => #{<<"Name">> => <<"no">>}},
      <<"Mounts">> => [#{<<"Type">> => <<"volume">>, <<"Name">> => V,
                         <<"Destination">> => <<"/workspace">>, <<"RW">> => true}],
      <<"NetworkSettings">> => #{<<"Networks">> => #{<<"none">> => #{}}},
      <<"State">> => #{<<"Running">> => Running}}.

%% Block `exec` until the test releases it: {exec_started, Pid}, then {finish, Result}.
blocking_exec() ->
    Test = self(),
    fun([<<"exec">> | _], _) ->
            Test ! {exec_started, self()},
            receive {finish, R} -> R end;
       (_, _) ->
            default
    end.

async(Fun) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> Self ! {Ref, Fun()} end),
    {Pid, Ref}.

await({_, Ref}) ->
    receive {Ref, R} -> R after 10000 -> error(await_timeout) end.

started() ->
    receive {exec_started, Pid} -> Pid after 5000 -> error(exec_not_started) end.

wait_until(Fun) -> wait_until(Fun, 200).
wait_until(Fun, 0) -> ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(10), wait_until(Fun, N - 1)
    end.

%% Cases

disabled() ->
    config(false),
    ?assertMatch(#{<<"status">> := <<"unconfigured">>, <<"enabled">> := false,
                   <<"provider">> := <<"docker">>, <<"network">> := <<"disabled">>,
                   <<"workspacePath">> := <<"/workspace">>, <<"commands">> := [],
                   <<"message">> := <<"Enable the Docker computer on the server to use its "
                                      "terminal and workspace files.">>},
                 muse_computer:snapshot(?O)),
    ?assertEqual({error, {503, <<"Computer is not configured. Enable COMPUTER_ENABLED and "
                                 "build the local computer image.">>}},
                 muse_computer:execute(?O, #{command => <<"pwd">>})),
    ?assertMatch({error, {503, _}}, muse_computer:start(?O)),
    ?assertMatch({error, {503, _}}, muse_computer:stop(?O)),
    ?assertEqual([], calls()).

failed_receipt() ->
    hook(fun([<<"exec">> | _], _) ->
                 (ok(<<"partial output">>))#{stderr := <<"bad input">>, exit_code := 7};
            (_, _) -> default
         end),
    Command = <<"printf '$HOME'; exit 7; $(touch /host-must-not-run)">>,
    {ok, R} = muse_computer:execute(?O, #{<<"command">> => Command}),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"exitCode">> := 7,
                   <<"stdout">> := <<"partial output">>, <<"stderr">> := <<"bad input">>,
                   <<"cwd">> := <<"/workspace">>, <<"truncated">> := false,
                   <<"command">> := Command, <<"startedAt">> := _, <<"completedAt">> := _}, R),
    ?assertEqual(R, muse_store:get(?O, ?RECEIPTS, maps:get(<<"id">>, R))),
    [{_, Args, _}] = exec_calls(),
    ?assertEqual(Command, lists:last(Args)),
    ?assert(lists:member(<<"/usr/bin/timeout">>, Args)),
    ?assert(lists:member(<<"/bin/bash">>, Args)),
    ?assert(lists:all(fun({_, _, #{timeout := T}}) -> T > 0 andalso T =< 35000 end, calls())),
    ?assertMatch(#{<<"commands">> := [R]}, muse_computer:snapshot(?O)),
    ?assertMatch(#{<<"commands">> := []}, muse_computer:snapshot(<<"other-owner">>)),
    ?assertMatch(#{<<"expiresAt">> := 0}, muse_store:get(?O, <<"computer-state">>, <<"lease">>)),
    ?assertMatch({error, {422, _}}, muse_computer:execute(?O, #{<<"command">> => <<"  ">>})),
    ?assertMatch({error, {422, <<"Choose an absolute path inside /workspace">>}},
                 muse_computer:execute(?O, #{command => <<"ls">>, cwd => <<"/etc">>})).

lease_busy() ->
    hook(blocking_exec()),
    Run = async(fun() -> muse_computer:execute(?O, #{command => <<"sleep 1">>}) end),
    Exec = started(),
    ?assertEqual({error, {409, <<"Computer is busy. Wait for the current operation to finish.">>}},
                 muse_computer:execute(?O, #{command => <<"pwd">>})),
    ?assertMatch({error, {409, _}}, muse_computer:read(?O, <<"/workspace/x">>)),
    ?assertMatch({error, {409, _}}, muse_computer:start(?O)),
    ?assertMatch({error, {409, <<"Computer is busy with another operation. Try Stop again shortly.">>}},
                 begin
                     %% an operation lease (not a command) refuses Stop
                     L = muse_store:get(?O, <<"computer-state">>, <<"lease">>),
                     _ = muse_store:put(?O, <<"computer-state">>, L#{<<"operation">> => <<"operation">>}),
                     R = muse_computer:stop(?O),
                     _ = muse_store:put(?O, <<"computer-state">>, L),
                     R
                 end),
    Exec ! {finish, ok(<<>>)},
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>}}, await(Run)).

timeout_replay() ->
    hook(fun([<<"exec">> | _], _) ->
                 (ok(<<"partial">>))#{timed_out := true, exit_code := null};
            (_, _) -> default
         end),
    Opts = #{idempotency_key => <<"timeout-case">>},
    {ok, First} = muse_computer:execute(?O, #{command => <<"sleep 999">>}, Opts),
    ?assertMatch(#{<<"status">> := <<"timed_out">>, <<"stdout">> := <<"partial">>}, First),
    ?assertNot(maps:is_key(<<"exitCode">>, First)),
    ?assertEqual(muse_ids:sha256hex(<<"computer-command:timeout-case">>), maps:get(<<"id">>, First)),
    %% the sandbox was stopped after the host-side timeout
    ?assertMatch([_], [x || {_, [<<"container">>, <<"stop">> | _], _} <- calls()]),
    Count = length(calls()),
    ?assertEqual({ok, First}, muse_computer:execute(?O, #{command => <<"sleep 999">>}, Opts)),
    ?assertEqual(Count, length(calls())),
    hook(fun([<<"exec">> | _], _) -> (ok(<<>>))#{interrupted := true, exit_code := null};
            (_, _) -> default
         end),
    ?assertMatch({ok, #{<<"status">> := <<"interrupted">>}},
                 muse_computer:execute(?O, #{command => <<"sleep 2">>})).

replay_mismatch() ->
    Opts = #{idempotency_key => <<"k">>},
    {ok, _} = muse_computer:execute(?O, #{command => <<"echo a">>}, Opts),
    ?assertEqual({error, {409, <<"This operation ID already belongs to a different command">>}},
                 muse_computer:execute(?O, #{command => <<"echo b">>}, Opts)),
    ?assertMatch({error, {409, _}},
                 muse_computer:execute(?O, #{command => <<"echo a">>, cwd => <<"/workspace/x">>},
                                       Opts)),
    ?assertEqual(1, length(exec_calls())).

isolation() ->
    Mods = [fun(I) -> put_in(I, [<<"HostConfig">>, <<"Privileged">>], true) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"NetworkMode">>], <<"bridge">>) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"SecurityOpt">>],
                             [<<"no-new-privileges">>, <<"seccomp=unconfined">>]) end,
            fun(I) -> put_in(I, [<<"Config">>, <<"Labels">>], #{}) end,
            fun(I = #{<<"Mounts">> := [M]}) -> I#{<<"Mounts">> := [M#{<<"Type">> := <<"bind">>}]} end,
            fun(I = #{<<"Config">> := C = #{<<"Env">> := E}}) ->
                    I#{<<"Config">> := C#{<<"Env">> := E ++ [<<"OPENAI_API_KEY=must-not-enter">>]}}
            end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"PidsLimit">>], null) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"Memory">>], 1073741824) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"Tmpfs">>], #{<<"/tmp">> => <<"rw">>}) end,
            fun(I) -> put_in(I, [<<"Config">>, <<"Image">>], <<"other:latest">>) end],
    lists:foreach(
      fun(Mod) ->
              ets:insert(?T, {inspect, Mod(sandbox(true))}),
              ?assertEqual({error, {409, <<"Computer ownership or isolation does not match this "
                                           "deployment; refusing to attach">>}},
                           muse_computer:execute(?O, #{command => <<"pwd">>}))
      end, Mods),
    ets:insert(?T, {inspect, maps:remove(<<"State">>, sandbox(true))}),
    ?assertEqual({error, {409, <<"Computer isolation inspection failed; refusing to attach">>}},
                 muse_computer:execute(?O, #{command => <<"pwd">>})),
    ?assertEqual([], exec_calls()).

volume_mismatch() ->
    hook(fun([<<"volume">>, <<"inspect">> | _], _) ->
                 ok(muse_json:encode([#{<<"Name">> => <<"x">>, <<"Labels">> => null,
                                        <<"Driver">> => <<"local">>, <<"Options">> => null,
                                        <<"Scope">> => <<"local">>}]));
            (_, _) -> default
         end),
    ?assertEqual({error, {409, <<"Computer workspace ownership or isolation does not match">>}},
                 muse_computer:execute(?O, #{command => <<"pwd">>})),
    hook(fun([<<"volume">>, <<"inspect">> | _], _) -> ok(<<"[]">>);
            (_, _) -> default
         end),
    ?assertEqual({error, {409, <<"Computer workspace ownership inspection failed">>}},
                 muse_computer:execute(?O, #{command => <<"pwd">>})).

put_in(Map, [K], V) -> Map#{K => V};
put_in(Map, [K | Rest], V) -> Map#{K => put_in(maps:get(K, Map), Rest, V)}.

paths_and_stdin() ->
    hook(fun([<<"exec">> | _], _) -> ok(<<"{\"path\":\"/workspace/note.txt\"}">>);
            (_, _) -> default
         end),
    [?assertMatch({error, {422, _}}, muse_computer:read(?O, P))
     || P <- [<<"/etc/passwd">>, <<"/workspace/../secret">>, <<"relative">>,
              <<"/workspace", 0, "/file">>]],
    Text = <<"$(touch /host-must-not-run)\nquoted ' content ✓"/utf8>>,
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/note.txt">>}},
                 muse_computer:write(?O, <<"/workspace/note.txt">>, Text)),
    [{_, Args, #{input := Input, timeout := 10000, max_output := 2097152}}] = exec_calls(),
    ?assertEqual(<<"{\"operation\":\"write\",\"path\":\"/workspace/note.txt\",\"text\":",
                   (muse_json:encode(Text))/binary, "}">>, Input),
    ?assertNot(lists:any(fun(A) -> binary:match(A, <<"touch">>) =/= nomatch end, Args)),
    ?assertEqual(muse_docker:file_args(maps:get(container, muse_computer:identity(?O))), Args),
    {ok, _} = muse_computer:list(?O),
    {_, _, #{input := ListInput}} = lists:last(exec_calls()),
    ?assertEqual(<<"{\"operation\":\"list\",\"path\":\"/workspace\"}">>, ListInput),
    {ok, _} = muse_computer:mkdir(?O, <<"/workspace/a/">>),
    {_, _, #{input := MkInput}} = lists:last(exec_calls()),
    ?assertEqual(<<"{\"operation\":\"mkdir\",\"path\":\"/workspace/a/\"}">>, MkInput).

file_errors() ->
    Failed = {error, {422, <<"Computer file operation failed. Check the path, permissions and "
                             "file size; symlinks cannot be opened.">>}},
    hook(fun([<<"exec">> | _], _) -> (ok(<<>>))#{exit_code := 1, stderr := <<"Too many levels">>};
            (_, _) -> default
         end),
    ?assertEqual(Failed, muse_computer:read(?O, <<"/workspace/escape/passwd">>)),
    hook(fun([<<"exec">> | _], _) -> (ok(<<"{}">>))#{truncated := true};
            (_, _) -> default
         end),
    ?assertEqual(Failed, muse_computer:read(?O, <<"/workspace/a">>)),
    hook(fun([<<"exec">> | _], _) -> ok(<<"not json">>);
            (_, _) -> default
         end),
    ?assertEqual({error, {502, <<"Computer returned an invalid file response">>}},
                 muse_computer:read(?O, <<"/workspace/a">>)),
    N = length(calls()),
    ?assertEqual({error, {413, <<"Text files must be 256 KB or smaller">>}},
                 muse_computer:write(?O, <<"/workspace/a">>, binary:copy(<<"é"/utf8>>, 131073))),
    ?assertEqual(N, length(calls())).

stop_interrupts() ->
    hook(blocking_exec()),
    Run = async(fun() -> muse_computer:execute(?O, #{command => <<"sleep 30">>}) end),
    Exec = started(),
    hook(fun([<<"exec">> | _], _) -> error(unexpected);
            ([<<"container">>, <<"stop">> | _], _) -> set_running(false), default;
            (_, _) -> default
         end),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?O)),
    Exec ! {finish, (ok(<<"partial before stop">>))#{exit_code := 137}},
    {ok, R} = await(Run),
    ?assertMatch(#{<<"status">> := <<"interrupted">>, <<"stdout">> := <<"partial before stop">>,
                   <<"exitCode">> := 137,
                   <<"stderr">> := <<"Stopped by the user. Inspect the workspace before "
                                     "repeating this command.">>}, R),
    ?assertEqual(R, muse_store:get(?O, ?RECEIPTS, maps:get(<<"id">>, R))).

exit_137() ->
    hook(fun([<<"exec">> | _], _) -> (ok(<<>>))#{exit_code := 137}; (_, _) -> default end),
    ?assertMatch({ok, #{<<"status">> := <<"failed">>, <<"exitCode">> := 137}},
                 muse_computer:execute(?O, #{command => <<"exit 137">>})).

exit_124() ->
    hook(fun([<<"exec">> | _], _) -> (ok(<<>>))#{exit_code := 124}; (_, _) -> default end),
    ?assertMatch({ok, #{<<"status">> := <<"timed_out">>, <<"exitCode">> := 124}},
                 muse_computer:execute(?O, #{command => <<"sleep 99">>})),
    ?assertEqual([], [x || {_, [<<"container">>, <<"stop">> | _], _} <- calls()]).

lifecycle_hook(Exec) ->
    fun([<<"exec">> | _] = A, O) -> Exec(A, O);
       ([<<"container">>, <<"stop">> | _], _) -> set_running(false), default;
       ([<<"container">>, <<"start">> | _], _) -> set_running(true), default;
       (_, _) -> default
    end.

restart_waits() ->
    Test = self(),
    Counter = counters:new(1, []),
    hook(lifecycle_hook(
           fun(_, _) ->
                   Test ! {exec_started, self()},
                   receive go -> ok end,
                   [{inspect, #{<<"State">> := #{<<"Running">> := Running}}}] = ets:lookup(?T, inspect),
                   case Running of
                       false -> (ok(<<>>))#{exit_code := 125};
                       true -> counters:add(Counter, 1, 1), ok(<<"executed">>)
                   end
           end)),
    Run = async(fun() -> muse_computer:execute(?O, #{command => <<"echo delayed">>}) end),
    Exec = started(),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?O)),
    ?assertMatch({error, {409, <<"Computer is busy", _/binary>>}}, muse_computer:start(?O)),
    Exec ! go,
    ?assertMatch({ok, #{<<"status">> := <<"interrupted">>}}, await(Run)),
    ?assertEqual(0, counters:get(Counter, 1)),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)).

failed_stop() ->
    Test = self(),
    Attempts = counters:new(1, []),
    hook(fun([<<"exec">> | _], _) ->
                 Test ! {exec_started, self()},
                 receive go -> (ok(<<>>))#{exit_code := 137} end;
            ([<<"container">>, <<"stop">> | _], _) ->
                 counters:add(Attempts, 1, 1),
                 case counters:get(Attempts, 1) of
                     1 -> (ok(<<>>))#{exit_code := 1};
                     _ -> set_running(false), default
                 end;
            ([<<"container">>, <<"start">> | _], _) -> set_running(true), default;
            (_, _) -> default
         end),
    Run = async(fun() -> muse_computer:execute(?O, #{command => <<"sleep 30">>}) end),
    Exec = started(),
    ?assertMatch({error, {503, <<"Docker operation failed", _/binary>>}}, muse_computer:stop(?O)),
    ?assertMatch({error, {409, <<"Computer is busy", _/binary>>}}, muse_computer:start(?O)),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?O)),
    Exec ! go,
    ?assertMatch({ok, #{<<"status">> := <<"interrupted">>}}, await(Run)),
    ?assertEqual(2, counters:get(Attempts, 1)),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)).

unconfirmed_cleanup() ->
    FailStop = atomics:new(1, []),
    atomics:put(FailStop, 1, 1),
    hook(fun([<<"exec">> | _], _) -> (ok(<<"partial">>))#{timed_out := true, exit_code := null};
            ([<<"container">>, <<"stop">> | _], _) ->
                 case atomics:get(FailStop, 1) of
                     1 -> (ok(<<>>))#{timed_out := true, exit_code := null};
                     0 -> set_running(false), default
                 end;
            ([<<"container">>, <<"start">> | _], _) -> set_running(true), default;
            (_, _) -> default
         end),
    {ok, R} = muse_computer:execute(?O, #{command => <<"sleep 99">>}),
    ?assertMatch(#{<<"status">> := <<"timed_out">>}, R),
    ?assertEqual(<<"\nCould not confirm the computer stopped. It remains locked; retry Stop "
                   "after checking the computer provider.">>, maps:get(<<"stderr">>, R)),
    ?assertMatch({error, {409, <<"Computer is busy", _/binary>>}}, muse_computer:start(?O)),
    atomics:put(FailStop, 1, 0),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?O)),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)).

dead_executor() ->
    Id = muse_ids:sha256hex(<<"computer-command:dead-executor">>),
    _ = muse_store:put(?O, ?RECEIPTS,
                       #{<<"id">> => Id, <<"command">> => <<"echo unknown">>,
                         <<"cwd">> => <<"/workspace">>, <<"status">> => <<"running">>,
                         <<"stdout">> => <<>>, <<"stderr">> => <<>>, <<"truncated">> => false,
                         <<"startedAt">> => muse_time:to_iso(muse_time:now_ms() - 200000)}),
    _ = muse_store:put(?O, <<"computer-state">>,
                       #{<<"id">> => <<"lease">>, <<"token">> => <<"dead-process">>,
                         <<"expiresAt">> => muse_time:now_ms() - 1, <<"stopping">> => true,
                         <<"stopInFlight">> => true, <<"stopAttempt">> => <<"dead-attempt">>,
                         <<"stopConfirmed">> => false, <<"executorDone">> => false,
                         <<"operation">> => <<"command">>}),
    #{<<"commands">> := Cmds} = muse_computer:snapshot(?O),
    ?assertMatch([#{<<"status">> := <<"interrupted">>,
                    <<"stderr">> := <<"Execution was interrupted. Its outcome is unknown; "
                                      "inspect files before running it again.">>}],
                 [C || C = #{<<"id">> := I} <- Cmds, I =:= Id]),
    ?assertMatch({ok, #{<<"status">> := <<"interrupted">>}},
                 muse_computer:execute(?O, #{command => <<"echo unknown">>},
                                       #{idempotency_key => <<"dead-executor">>})),
    ?assertEqual([], exec_calls()),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)).

%% Intercept the first lease read after the receipt exists (the lease check).
intercept_lease_check(CmdId, Action) ->
    Flag = atomics:new(1, []),
    meck:new(muse_store, [passthrough]),
    meck:expect(muse_store, get,
                fun(O, <<"computer-state">> = K, <<"lease">> = I) ->
                        Lease = meck:passthrough([O, K, I]),
                        Row = meck:passthrough([O, ?RECEIPTS, CmdId]),
                        case Lease =/= undefined andalso Row =/= undefined
                            andalso atomics:compare_exchange(Flag, 1, 0, 1) =:= ok of
                            true -> Action(O, Lease);
                            false -> ok
                        end,
                        meck:passthrough([O, K, I]);
                   (O, K, I) ->
                        meck:passthrough([O, K, I])
                end).

quarantine_race() ->
    CmdId = muse_ids:sha256hex(<<"computer-command:quarantine-case">>),
    intercept_lease_check(
      CmdId,
      fun(O, #{<<"token">> := Token}) ->
              _ = muse_store:cas(O, <<"computer-state">>, <<"lease">>,
                                 #{<<"token">> => Token, <<"stopping">> => false},
                                 #{<<"stopping">> => true, <<"stopInFlight">> => true,
                                   <<"stopAttempt">> => <<"stop-attempt-1">>,
                                   <<"stopConfirmed">> => false,
                                   <<"expiresAt">> => muse_time:now_ms() + 180000}),
              _ = muse_store:cas(O, ?RECEIPTS, CmdId, #{<<"status">> => <<"running">>},
                                 #{<<"status">> => <<"interrupted">>,
                                   <<"completedAt">> => muse_time:now_iso(),
                                   <<"stderr">> => <<"Stopped by the user. Inspect the workspace "
                                                     "before repeating this command.">>})
      end),
    {ok, R} = muse_computer:execute(?O, #{command => <<"sleep 30">>},
                                    #{idempotency_key => <<"quarantine-case">>}),
    ?assertMatch(#{<<"status">> := <<"interrupted">>, <<"stderr">> := <<"Stopped by the user", _/binary>>}, R),
    ?assertEqual([], exec_calls()).

dead_row() ->
    hook(fun([<<"exec">> | _], _) -> ok(<<"should never run">>); (_, _) -> default end),
    CmdId = muse_ids:sha256hex(<<"computer-command:dead-row-case">>),
    intercept_lease_check(
      CmdId,
      fun(O, _) ->
              _ = muse_store:cas(O, ?RECEIPTS, CmdId, #{<<"status">> => <<"running">>},
                                 #{<<"status">> => <<"interrupted">>,
                                   <<"completedAt">> => muse_time:now_iso(),
                                   <<"stderr">> => <<"Execution was interrupted.">>})
      end),
    {ok, R} = muse_computer:execute(?O, #{command => <<"touch /tmp/should-not-run">>},
                                    #{idempotency_key => <<"dead-row-case">>}),
    ?assertMatch(#{<<"status">> := <<"interrupted">>, <<"stdout">> := <<>>}, R),
    ?assertEqual([], exec_calls()).

%% A fake exec honouring `cancel` like muse_docker:run/2.
cancellable_exec() ->
    Test = self(),
    lifecycle_hook(
      fun(_, #{cancel := Cancel}) ->
              [erlang:monitor(process, P) || P <- Cancel],
              Test ! {exec_started, self()},
              receive
                  {'DOWN', _, process, _, _} -> (ok(<<"partial">>))#{interrupted := true,
                                                                     exit_code := null}
              after 5000 -> ok(<<"not cancelled">>)
              end
      end).

caller_death() ->
    hook(cancellable_exec()),
    Caller = spawn(fun() -> muse_computer:execute(?O, #{command => <<"sleep 30">>},
                                                  #{idempotency_key => <<"dies">>}) end),
    _ = started(),
    exit(Caller, kill),
    Id = muse_ids:sha256hex(<<"computer-command:dies">>),
    wait_until(fun() ->
                       case muse_store:get(?O, ?RECEIPTS, Id) of
                           #{<<"status">> := <<"interrupted">>} -> true;
                           _ -> false
                       end
               end),
    ?assertMatch([_], [x || {_, [<<"container">>, <<"stop">> | _], _} <- calls()]),
    wait_until(fun() -> maps:get(<<"expiresAt">>, muse_store:get(?O, <<"computer-state">>,
                                                                  <<"lease">>)) =:= 0 end),
    ?assertMatch(#{<<"status">> := <<"stopped">>}, muse_computer:snapshot(?O)).

cancel_death() ->
    hook(cancellable_exec()),
    Canceller = spawn(fun() -> receive stop -> ok end end),
    Run = async(fun() -> muse_computer:execute(?O, #{command => <<"sleep 30">>},
                                               #{cancel => Canceller}) end),
    _ = started(),
    exit(Canceller, kill),
    ?assertMatch({ok, #{<<"status">> := <<"interrupted">>, <<"stdout">> := <<"partial">>}},
                 await(Run)),
    ?assertMatch(#{<<"status">> := <<"stopped">>}, muse_computer:snapshot(?O)),
    {Dead, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, _, _, _} -> ok end,
    set_running(true),
    ?assertEqual({error, {409, <<"Computer command was interrupted before execution">>}},
                 muse_computer:execute(?O, #{command => <<"pwd">>}, #{cancel => [Dead]})).

not_running() ->
    set_running(false),
    Msg = {error, {409, <<"Start the computer before using its terminal or files">>}},
    ?assertEqual(Msg, muse_computer:execute(?O, #{command => <<"pwd">>})),
    ?assertEqual(Msg, muse_computer:list(?O)),
    ets:insert(?T, {missing, true}),
    ?assertEqual(Msg, muse_computer:read(?O, <<"/workspace/a">>)),
    ?assertMatch(#{<<"status">> := <<"stopped">>}, muse_computer:snapshot(?O)),
    ?assertEqual([], exec_calls()).

start_missing() ->
    Created = atomics:new(1, []),
    hook(fun([<<"container">>, <<"ls">> | _], _) ->
                 case atomics:get(Created, 1) of
                     0 -> ok(<<>>);
                     1 -> default
                 end;
            ([<<"volume">>, <<"ls">> | _], _) -> ok(<<>>);
            ([<<"container">>, <<"create">> | _], _) ->
                 set_running(false), atomics:put(Created, 1, 1), default;
            ([<<"container">>, <<"start">> | _], _) -> set_running(true), default;
            (_, _) -> default
         end),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)),
    Id = #{volume := V, labels := L} = muse_computer:identity(?O),
    Ops = [A || {_, A, _} <- calls(),
                lists:member(hd(tl(A)), [<<"create">>, <<"start">>])],
    ?assertEqual([muse_docker:volume_create_args(V, L),
                  muse_docker:create_args(Id, <<"openmuse-computer:local">>),
                  muse_docker:start_args(maps:get(container, Id))], Ops),
    ?assert(lists:all(fun({_, _, #{timeout := T}}) -> T =:= 10000 end, calls())),
    %% already running: no further start
    N = length(calls()),
    {ok, _} = muse_computer:start(?O),
    ?assertEqual([], [A || {_, A = [_, <<"start">> | _], _} <- lists:nthtail(N, calls())]),
    config(true, #{<<"COMPUTER_IMAGE">> => <<"-bad image">>}),
    ?assertEqual({error, {503, <<"COMPUTER_IMAGE is invalid">>}}, muse_computer:start(?O)).

snapshot_error() ->
    hook(fun([<<"container">>, <<"ls">> | _], _) -> (ok(<<>>))#{exit_code := 1}; (_, _) -> default end),
    ?assertMatch(#{<<"status">> := <<"error">>,
                   <<"message">> := <<"Docker operation failed. Check that the engine is running "
                                      "and the computer image is built locally.">>},
                 muse_computer:snapshot(?O)),
    hook(fun([<<"container">>, <<"ls">> | _], _) -> (ok(<<>>))#{timed_out := true}; (_, _) -> default end),
    ?assertEqual({error, {503, <<"Docker did not respond within 10 seconds. Check the Docker engine.">>}},
                 muse_computer:start(?O)),
    hook(fun([<<"container">>, <<"inspect">> | _], _) -> ok(<<"{oops">>); (_, _) -> default end),
    ?assertMatch(#{<<"status">> := <<"error">>,
                   <<"message">> := <<"Computer inspection failed. Check the computer provider setup.">>},
                 muse_computer:snapshot(?O)).

pdf_bridge() ->
    Pdf = <<"%PDF-1.7\nfake">>,
    meck:expect(muse_files, bytes,
                fun(_, <<"good">>) -> {ok, Pdf};
                   (_, <<"text">>) -> {ok, <<"hello">>};
                   (_, _) -> {error, {404, <<"File not found">>}}
                end),
    meck:expect(muse_files, import,
                fun(Owner, Name, Bytes, Source) ->
                        {ok, #{<<"id">> => <<"new">>, <<"owner">> => Owner, <<"name">> => Name,
                               <<"size">> => byte_size(Bytes), <<"source">> => Source}}
                end),
    hook(fun([<<"exec">> | _], #{input := Input}) ->
                 case muse_json:decode(Input) of
                     {ok, #{<<"operation">> := <<"write_pdf">>, <<"path">> := P}} ->
                         ok(muse_json:encode(#{<<"path">> => P}));
                     {ok, #{<<"operation">> := <<"read_pdf">>, <<"path">> := P}} ->
                         ok(muse_json:encode(#{<<"path">> => P, <<"base64">> => base64:encode(Pdf)}))
                 end;
            (_, _) -> default
         end),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/in.pdf">>}},
                 muse_computer:import_pdf(?O, <<"/workspace/in.pdf">>, <<"good">>)),
    {_, _, #{input := In}} = lists:last(exec_calls()),
    ?assertEqual(<<"{\"operation\":\"write_pdf\",\"path\":\"/workspace/in.pdf\",\"base64\":\"",
                   (base64:encode(Pdf))/binary, "\"}">>, In),
    ?assertEqual({error, {404, <<"File not found">>}},
                 muse_computer:import_pdf(?O, <<"/workspace/in.pdf">>, <<"missing">>)),
    ?assertEqual({error, {422, <<"Choose a PDF of 10 MB or smaller">>}},
                 muse_computer:import_pdf(?O, <<"/workspace/in.pdf">>, <<"text">>)),
    ?assertEqual({ok, #{<<"id">> => <<"new">>, <<"owner">> => ?O, <<"name">> => <<"out.pdf">>,
                        <<"size">> => byte_size(Pdf),
                        <<"source">> => <<"Computer: /workspace/sub/out.pdf">>}},
                 muse_computer:export_pdf(?O, <<"/workspace/sub/out.pdf">>)),
    {_, _, #{max_output := Max}} = lists:last(exec_calls()),
    ?assertEqual(15 * 1024 * 1024, Max),
    ?assertMatch({error, {422, _}}, muse_computer:export_pdf(?O, <<"/tmp/x.pdf">>)).
