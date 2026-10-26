%% Real Docker computer (OpenMuse apps/computer/smoke.test.ts). Runs only with
%% MUSE_TEST_DOCKER=1; builds openmuse-computer:local from computer/ when it
%% is missing. Uses a unique deployment id and removes every container and
%% volume of that deployment afterwards.
%%
%% The `computer` group runs on the default COMPUTER_NETWORK (`bridge`: the
%% container reaches the internet); `no_network` checks `none`; `pool`
%% covers the computer pool (one computer per scope, auto-start, eviction,
%% idle stop, retention, reconcile, delete).
-module(muse_computer_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([isolation/1, output/1, files/1, symlinks_and_traversal/1, idempotent/1,
         pdf_bridge/1, command_timeout/1, stop_interrupts/1, caller_death/1,
         restart_keeps_workspace/1, no_network/1,
         pool_scopes/1, pool_eviction/1, pool_idle_and_retention/1, pool_reconcile/1,
         pool_delete/1]).

-define(O, <<"local-user">>).
-define(IMAGE, <<"openmuse-computer:local">>).
%% An older version's default computer, which keeps OpenMuse's names.
-define(LEGACY(O), {O, muse_computers:legacy_id(O)}).

all() -> [{group, computer}, {group, no_network}, {group, pool}].

groups() ->
    [{computer, [sequence],
      [isolation, output, files, symlinks_and_traversal, idempotent, pdf_bridge,
       command_timeout, stop_interrupts, caller_death, restart_keeps_workspace]},
     {no_network, [sequence], [no_network]},
     {pool, [sequence],
      [pool_scopes, pool_eviction, pool_idle_and_retention, pool_reconcile, pool_delete]}].

init_per_group(no_network, Config) ->
    set_config(Config, #{<<"COMPUTER_NETWORK">> => <<"none">>}),
    Config;
init_per_group(_, Config) ->
    set_config(Config, #{}),
    Config.

end_per_group(_, Config) ->
    muse_time:set_offset(0),
    set_config(Config, #{}),
    ok.

set_config(Config, Extra) ->
    {ok, C} = muse_config:from_env(maps:merge(proplists:get_value(env, Config), Extra)),
    muse_config:set(C).

init_per_suite(Config) ->
    case os:getenv("MUSE_TEST_DOCKER") of
        "1" -> setup(Config);
        _ -> {skip, "Set MUSE_TEST_DOCKER=1 to run the Docker computer suite"}
    end.

setup(Config) ->
    {ok, _} = application:ensure_all_started(erlexec),
    ok = muse_store:init(#{storage => ram}),
    Passthrough = [<<"PATH">>, <<"HOME">>, <<"DOCKER_HOST">>, <<"DOCKER_CONTEXT">>,
                   <<"DOCKER_CONFIG">>, <<"DOCKER_TLS_VERIFY">>, <<"DOCKER_CERT_PATH">>],
    Env = maps:from_list([{K, list_to_binary(V)} || K <- Passthrough,
                                                    V <- [os:getenv(binary_to_list(K))],
                                                    V =/= false]),
    Deployment = <<"ct-", (muse_ids:uuid())/binary>>,
    Full = Env#{<<"COMPUTER_ENABLED">> => <<"true">>, <<"COMPUTER_DEPLOYMENT_ID">> => Deployment},
    {ok, C} = muse_config:from_env(Full),
    muse_config:set(C),
    ensure_image(),
    [{identity, muse_computer:identity(?LEGACY(?O))}, {env, Full} | Config].

%% Every container and volume of this run's deployment.
end_per_suite(Config) ->
    muse_time:set_offset(0),
    #{container := Container, volume := Volume} = proplists:get_value(identity, Config),
    ct:pal("default computer ~s / ~s", [Container, Volume]),
    Label = <<"label=dev.openmuse.deployment=", (muse_computer:deployment())/binary>>,
    #{stdout := Cs} = muse_docker:run([<<"container">>, <<"ls">>, <<"--all">>, <<"--filter">>, Label,
                                       <<"--format">>, <<"{{.Names}}">>], #{timeout => 20000}),
    Containers = binary:split(Cs, <<"\n">>, [global, trim_all]),
    _ = [muse_docker:run([<<"container">>, <<"rm">>, <<"--force">>, N], #{timeout => 20000}) || N <- Containers],
    #{stdout := Vs} = muse_docker:run([<<"volume">>, <<"ls">>, <<"--filter">>, Label,
                                       <<"--format">>, <<"{{.Name}}">>], #{timeout => 20000}),
    Volumes = binary:split(Vs, <<"\n">>, [global, trim_all]),
    _ = [muse_docker:run([<<"volume">>, <<"rm">>, V], #{timeout => 20000}) || V <- Volumes],
    muse_store:stop(),
    ct:pal("removed containers ~p and volumes ~p", [Containers, Volumes]),
    _ = {Container, Volume},
    #{stdout := Left} = muse_docker:run([<<"volume">>, <<"ls">>, <<"--filter">>, Label, <<"--format">>,
                                         <<"{{.Name}}">>], #{timeout => 20000}),
    ?assertEqual(<<>>, Left),
    ok.

ensure_image() ->
    case muse_docker:run([<<"image">>, <<"inspect">>, ?IMAGE], #{timeout => 20000}) of
        #{exit_code := 0} ->
            ok;
        _ ->
            Dir = computer_dir(),
            ct:pal("building ~s from ~s", [?IMAGE, Dir]),
            ?assertMatch(#{exit_code := 0},
                         muse_docker:run([<<"build">>, <<"-t">>, ?IMAGE, list_to_binary(Dir)],
                                         #{timeout => 600000}))
    end.

computer_dir() ->
    Starts = [filename:dirname(code:which(?MODULE)), element(2, file:get_cwd())],
    hd([D || S <- Starts, D <- [find_up(filename:absname(S))], D =/= false]).

find_up("/") -> false;
find_up(Dir) ->
    Candidate = filename:join(Dir, "computer"),
    case filelib:is_regular(filename:join(Candidate, "Dockerfile")) of
        true -> Candidate;
        false -> find_up(filename:dirname(Dir))
    end.

run(Command) ->
    {ok, R} = muse_computer:execute(?LEGACY(?O), #{command => Command}),
    R.

container(Config) ->
    maps:get(container, proplists:get_value(identity, Config)).

%% Cases

isolation(Config) ->
    ?assertMatch(#{<<"status">> := <<"stopped">>, <<"network">> := <<"enabled">>},
                 muse_computer:snapshot(?LEGACY(?O))),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?LEGACY(?O))),
    Ok = run(<<"id -u; id -g; node --version; python3 --version; git --version; "
               "printf 'persisted from bash\\n' > receipt.txt">>),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"exitCode">> := 0,
                   <<"stdout">> := <<"1000\n1000\nv22.", _/binary>>}, Ok),
    persistent_term:put({?MODULE, first}, maps:get(<<"id">>, Ok)),
    ?assertMatch(#{<<"status">> := <<"failed">>}, run(<<"touch /etc/openmuse-must-fail">>)),
    ?assertMatch(#{<<"status">> := <<"failed">>}, run(<<"touch /usr/bin/openmuse-must-fail">>)),
    %% COMPUTER_NETWORK=bridge (the default): the internet is reachable (no
    %% curl in the image; node has its own CA store, python only does http here)
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"stdout">> := <<"200\n">>},
                 run(<<"node -e 'fetch(\"https://example.com\").then(r => console.log(r.status))'">>)),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"stdout">> := <<"200\n">>},
                 run(<<"python3 -c 'import urllib.request as u; "
                      "print(u.urlopen(\"http://example.com\", timeout=10).status)'">>)),
    ?assertMatch(#{<<"stdout">> := <<"eth0\nlo\n">>}, run(<<"ls /sys/class/net">>)),
    ?assertMatch(#{<<"stdout">> := <<"128\n">>}, run(<<"cat /sys/fs/cgroup/pids.max">>)),
    Fork = run(<<"for i in $(seq 1 200); do sleep 2 & done; wait">>),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"stderr">>, Fork),
                                          [<<"fork">>, <<"Resource temporarily unavailable">>])),
    ?assertMatch(#{<<"stdout">> := <<"0000000000000000\n">>},
                 run(<<"grep CapEff /proc/self/status | cut -f2">>)),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, run(<<"touch /tmp/ok && touch /workspace/ok">>)),
    #{stdout := Json} = muse_docker:run(muse_docker:inspect_args(container(Config)),
                                        #{timeout => 10000}),
    {ok, [#{<<"HostConfig">> := H, <<"Config">> := C}]} = muse_json:decode(Json),
    ?assertMatch(#{<<"ReadonlyRootfs">> := true, <<"NetworkMode">> := <<"bridge">>,
                   <<"PidsLimit">> := 128, <<"Privileged">> := false, <<"Init">> := true,
                   <<"CapDrop">> := [<<"ALL">>], <<"Memory">> := 536870912}, H),
    ?assertMatch(#{<<"User">> := <<"1000:1000">>}, C).

output(_Config) ->
    Big = run(<<"python3 -c 'print(\"x\" * 300000)'">>),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"truncated">> := true}, Big),
    ?assertEqual(131072, byte_size(maps:get(<<"stdout">>, Big))),
    ?assertMatch(#{<<"stdout">> := <<"out ✓\n"/utf8>>, <<"stderr">> := <<"err\n">>,
                   <<"truncated">> := false},
                 run(<<"echo 'out ✓'; echo err >&2"/utf8>>)),
    ?assertMatch(#{<<"stdout">> := <<"/workspace/sub\n">>, <<"cwd">> := <<"/workspace/sub">>},
                 begin
                     run(<<"mkdir -p sub">>),
                     {ok, R} = muse_computer:execute(?LEGACY(?O), #{command => <<"pwd">>,
                                                           cwd => <<"/workspace/./sub">>}),
                     R
                 end).

files(_Config) ->
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes">>}},
                 muse_computer:mkdir(?LEGACY(?O), <<"/workspace/notes">>)),
    Text = <<"Hello from the API ✓"/utf8>>,
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes/hello.txt">>}},
                 muse_computer:write(?LEGACY(?O), <<"/workspace/notes/hello.txt">>, Text)),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes/hello.txt">>, <<"text">> => Text}},
                 muse_computer:read(?LEGACY(?O), <<"/workspace/notes/hello.txt">>)),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes">>,
                        <<"entries">> => [#{<<"name">> => <<"hello.txt">>,
                                            <<"path">> => <<"/workspace/notes/hello.txt">>,
                                            <<"type">> => <<"file">>,
                                            <<"size">> => byte_size(Text)}]}},
                 muse_computer:list(?LEGACY(?O), <<"/workspace/notes">>)),
    {ok, #{<<"entries">> := Entries}} = muse_computer:list(?LEGACY(?O)),
    [#{<<"type">> := <<"directory">>} | _] = Entries,
    ?assert(lists:member(<<"receipt.txt">>, [N || #{<<"name">> := N} <- Entries])),
    ?assertMatch({error, {422, _}}, muse_computer:read(?LEGACY(?O), <<"/workspace/missing.txt">>)),
    ?assertMatch({ok, _}, muse_computer:mkdir(?LEGACY(?O), <<"/workspace/a/b/c">>)),
    ?assertMatch(#{<<"stdout">> := <<"drwx------\n">>}, run(<<"stat -c %A a/b/c">>)).

symlinks_and_traversal(_Config) ->
    #{<<"status">> := <<"succeeded">>} =
        run(<<"ln -s /etc /workspace/escape && ln -s /etc/passwd /workspace/pw">>),
    Failed = {error, {422, <<"Computer file operation failed. Check the path, permissions and "
                             "file size; symlinks cannot be opened.">>}},
    ?assertEqual(Failed, muse_computer:read(?LEGACY(?O), <<"/workspace/escape/passwd">>)),
    ?assertEqual(Failed, muse_computer:list(?LEGACY(?O), <<"/workspace/escape">>)),
    ?assertEqual(Failed, muse_computer:write(?LEGACY(?O), <<"/workspace/escape/x">>, <<"x">>)),
    ?assertEqual(Failed, muse_computer:read(?LEGACY(?O), <<"/workspace/pw">>)),
    ?assertEqual(Failed, muse_computer:write(?LEGACY(?O), <<"/workspace/pw">>, <<"x">>)),
    ?assertEqual(Failed, muse_computer:mkdir(?LEGACY(?O), <<"/workspace/escape/sub">>)),
    Outside = {error, {422, <<"Choose an absolute path inside /workspace">>}},
    ?assertEqual(Outside, muse_computer:read(?LEGACY(?O), <<"/workspace/../etc/passwd">>)),
    ?assertEqual(Outside, muse_computer:read(?LEGACY(?O), <<"/etc/passwd">>)),
    {ok, #{<<"entries">> := Entries}} = muse_computer:list(?LEGACY(?O)),
    ?assertMatch([#{<<"type">> := <<"symlink">>}],
                 [E || E = #{<<"name">> := <<"escape">>} <- Entries]),
    ?assertMatch(#{<<"stdout">> := <<"root:", _/binary>>}, run(<<"head -c 5 /etc/passwd">>)).

idempotent(_Config) ->
    Key = <<"once-", (muse_ids:uuid())/binary>>,
    Args = #{command => <<"echo run >> /workspace/once.txt">>},
    {ok, First} = muse_computer:execute(?LEGACY(?O), Args, #{idempotency_key => Key}),
    {ok, Second} = muse_computer:execute(?LEGACY(?O), Args, #{idempotency_key => Key}),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, First),
    ?assertEqual(First, Second),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/once.txt">>, <<"text">> => <<"run\n">>}},
                 muse_computer:read(?LEGACY(?O), <<"/workspace/once.txt">>)).

pdf_bridge(_Config) ->
    Pdf = <<"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n">>,
    meck:new(muse_files, [non_strict]),
    try
        meck:expect(muse_files, pdf_bytes, fun(?O, <<"file-1">>) -> {ok, Pdf} end),
        meck:expect(muse_files, import,
                    fun(?O, Name, Bytes, Source) ->
                            {ok, #{<<"id">> => <<"file-2">>, <<"name">> => Name,
                                   <<"size">> => byte_size(Bytes), <<"source">> => Source,
                                   <<"bytes">> => Bytes}}
                    end),
        ?assertEqual({ok, #{<<"path">> => <<"/workspace/source.pdf">>}},
                     muse_computer:import_pdf(?LEGACY(?O), <<"/workspace/source.pdf">>, <<"file-1">>)),
        #{<<"status">> := <<"succeeded">>} = run(<<"cp source.pdf output.pdf">>),
        ?assertEqual({ok, #{<<"id">> => <<"file-2">>, <<"name">> => <<"output.pdf">>,
                            <<"size">> => byte_size(Pdf), <<"bytes">> => Pdf,
                            <<"source">> => <<"Computer: /workspace/output.pdf">>}},
                     muse_computer:export_pdf(?LEGACY(?O), <<"/workspace/output.pdf">>)),
        ?assertMatch({error, {422, _}}, muse_computer:export_pdf(?LEGACY(?O), <<"/workspace/once.txt">>))
    after
        meck:unload(muse_files)
    end.

command_timeout(_Config) ->
    T0 = erlang:monotonic_time(millisecond),
    R = run(<<"echo started; sleep 40">>),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assertMatch(#{<<"status">> := <<"timed_out">>, <<"exitCode">> := 124,
                   <<"stdout">> := <<"started\n">>}, R),
    ?assert(Elapsed >= 29000 andalso Elapsed < 35000),
    ?assertMatch(#{<<"status">> := <<"running">>}, muse_computer:snapshot(?LEGACY(?O))).

wait_ready(Config) ->
    wait_ready(Config, 500).

wait_ready(_Config, 0) ->
    %% Surface an early execute/3 result (e.g. a lease error) instead of a bare timeout.
    Early = receive {pending, R} -> R after 0 -> none end,
    error({command_did_not_start, Early});
wait_ready(Config, N) ->
    case muse_docker:run([<<"exec">>, container(Config), <<"/usr/bin/cat">>,
                          <<"/workspace/.running">>], #{timeout => 3000}) of
        #{exit_code := 0, stdout := <<"ready">>} -> ok;
        _ -> timer:sleep(20), wait_ready(Config, N - 1)
    end.

%% Earlier cases (the fork limit check, the 30 s timeout) can leave
%% processes behind for a moment; wait until the container's pid count is
%% back to a handful so the next exec can fork.
wait_quiet(Config) ->
    wait_quiet(Config, 100).

wait_quiet(Config, 0) ->
    %% The image has no ps; list the container's processes from the host.
    Ps = muse_docker:run([<<"top">>, container(Config), <<"-eo">>, <<"pid,etimes,args">>],
                         #{timeout => 5000}),
    error({container_not_quiet, maps:get(stdout, Ps)});
wait_quiet(Config, N) ->
    case muse_docker:run([<<"exec">>, container(Config), <<"/usr/bin/cat">>,
                          <<"/sys/fs/cgroup/pids.current">>], #{timeout => 3000}) of
        #{exit_code := 0, stdout := Out} ->
            case string:to_integer(string:trim(Out)) of
                {Count, _} when is_integer(Count), Count < 16 -> ok;
                _ -> timer:sleep(200), wait_quiet(Config, N - 1)
            end;
        _ ->
            timer:sleep(200), wait_quiet(Config, N - 1)
    end.

stop_interrupts(Config) ->
    wait_quiet(Config),
    _ = run(<<"rm -f /workspace/.running">>),
    Self = self(),
    spawn(fun() ->
                  Self ! {pending, muse_computer:execute(
                                     ?O, #{command => <<"printf ready > /workspace/.running; "
                                                        "sleep 30">>})}
          end),
    wait_ready(Config),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?LEGACY(?O))),
    receive
        {pending, Result} ->
            ?assertMatch({ok, #{<<"status">> := <<"interrupted">>}}, Result)
    after 15000 ->
        error(no_result)
    end,
    ?assertMatch(#{<<"status">> := <<"stopped">>}, muse_computer:snapshot(?LEGACY(?O))).

caller_death(Config) ->
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?LEGACY(?O))),
    _ = run(<<"rm -f /workspace/.running">>),
    Key = <<"dies-", (muse_ids:uuid())/binary>>,
    Caller = spawn(fun() ->
                           muse_computer:execute(
                             ?O, #{command => <<"printf ready > /workspace/.running; sleep 30">>},
                             #{idempotency_key => Key})
                   end),
    wait_ready(Config),
    exit(Caller, kill),
    Id = muse_ids:sha256hex(<<"computer-command:", Key/binary>>),
    wait_for(fun() ->
                     case muse_store:get(?O, <<"computer-commands">>, Id) of
                         #{<<"status">> := <<"interrupted">>} -> true;
                         _ -> false
                     end
             end),
    wait_for(fun() -> maps:get(<<"status">>, muse_computer:snapshot(?LEGACY(?O))) =:= <<"stopped">> end),
    wait_for(fun() ->
                     maps:get(<<"expiresAt">>,
                              muse_store:get(?O, <<"computer-state">>, <<"lease">>)) =:= 0
             end).

wait_for(Fun) -> wait_for(Fun, 1000).
wait_for(Fun, 0) -> ?assert(Fun());
wait_for(Fun, N) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(20), wait_for(Fun, N - 1)
    end.

restart_keeps_workspace(_Config) ->
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?LEGACY(?O))),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/receipt.txt">>,
                        <<"text">> => <<"persisted from bash\n">>}},
                 muse_computer:read(?LEGACY(?O), <<"/workspace/receipt.txt">>)),
    ?assertMatch({ok, #{<<"text">> := <<"Hello from the API ✓"/utf8>>}},
                 muse_computer:read(?LEGACY(?O), <<"/workspace/notes/hello.txt">>)),
    First = persistent_term:get({?MODULE, first}),
    #{<<"commands">> := Commands} = muse_computer:snapshot(?LEGACY(?O)),
    ?assertMatch([#{<<"status">> := <<"succeeded">>}],
                 [C || C = #{<<"id">> := Id} <- Commands, Id =:= First]),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?LEGACY(?O))),
    persistent_term:erase({?MODULE, first}).

%% Docker helpers

inspect(Name) ->
    case muse_docker:run(muse_docker:inspect_args(Name), #{timeout => 10000}) of
        #{exit_code := 0, stdout := Json} -> {ok, [I]} = muse_json:decode(Json), I;
        _ -> undefined
    end.

docker_running(Ref) ->
    #{container := C} = muse_computer:identity(Ref),
    case inspect(C) of
        #{<<"State">> := #{<<"Running">> := R}} -> R;
        undefined -> missing
    end.

volume_exists(Ref) ->
    #{volume := V} = muse_computer:identity(Ref),
    maps:get(exit_code, muse_docker:run(muse_docker:volume_inspect_args(V), #{timeout => 10000})) =:= 0.

on(Ref, Command) ->
    {ok, R} = muse_computer:execute(Ref, #{command => Command}, #{auto_start => true}),
    R.

%% COMPUTER_NETWORK=none: OpenMuse's isolation.
no_network(_Config) ->
    N = muse_computer:ensure(?O, <<"task:ct-offline">>),
    ?assertEqual(<<"disabled">>, maps:get(<<"network">>, muse_computer:snapshot(N))),
    ?assertMatch(#{<<"status">> := <<"failed">>},
                 on(N, <<"python3 -c 'import socket; socket.create_connection((\"1.1.1.1\", 443), 1)'">>)),
    ?assertMatch(#{<<"status">> := <<"failed">>},
                 on(N, <<"node -e 'fetch(\"https://example.com\").then(() => 0, () => process.exit(1))'">>)),
    ?assertMatch(#{<<"stdout">> := <<"lo\n">>}, on(N, <<"ls /sys/class/net">>)),
    #{container := C} = muse_computer:identity(N),
    ?assertMatch(#{<<"HostConfig">> := #{<<"NetworkMode">> := <<"none">>}}, inspect(C)),
    ?assertEqual(ok, muse_computer:delete(N)),
    ?assertEqual(missing, docker_running(N)),
    ?assertNot(volume_exists(N)).

%% Pool

pool_scopes(_Config) ->
    A = muse_computer:ensure(?O, <<"thread:ct-a">>),
    B = muse_computer:ensure(?O, <<"task:ct-b">>),
    %% the first command starts each computer
    ?assertEqual({missing, missing}, {docker_running(A), docker_running(B)}),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, on(A, <<"echo from-a > /workspace/a.txt">>)),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, on(B, <<"echo from-b > /workspace/b.txt">>)),
    ?assertEqual({true, true}, {docker_running(A), docker_running(B)}),
    ?assertMatch(#{<<"stdout">> := <<"a.txt\n">>}, on(A, <<"ls /workspace">>)),
    ?assertMatch(#{<<"stdout">> := <<"b.txt\n">>}, on(B, <<"ls /workspace">>)),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/a.txt">>, <<"text">> => <<"from-a\n">>}},
                 muse_computer:read(A, <<"/workspace/a.txt">>)),
    ?assertMatch({error, {422, _}}, muse_computer:read(B, <<"/workspace/a.txt">>)),
    #{container := CA, volume := VA} = muse_computer:identity(A),
    #{container := CB, volume := VB} = muse_computer:identity(B),
    ?assertMatch(#{<<"Mounts">> := [#{<<"Name">> := VA}],
                   <<"Config">> := #{<<"Labels">> := #{<<"dev.openmuse.scope">> := <<"thread:ct-a">>}}},
                 inspect(CA)),
    ?assertMatch(#{<<"Mounts">> := [#{<<"Name">> := VB}]}, inspect(CB)),
    %% the default computer is a third one, untouched
    ?assertNotEqual(true, docker_running(?LEGACY(?O))).

pool_eviction(Config) ->
    set_config(Config, #{<<"COMPUTER_MAX_RUNNING">> => <<"2">>}),
    A = muse_computer:ensure(?O, <<"thread:ct-a">>),
    B = muse_computer:ensure(?O, <<"task:ct-b">>),
    C = muse_computer:ensure(?O, <<"task:ct-c">>),
    %% B is used last, so A is the least recently used
    _ = on(B, <<"true">>),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, on(C, <<"echo c">>)),
    ?assertEqual({false, true, true}, {docker_running(A), docker_running(B), docker_running(C)}),
    ?assert(volume_exists(A)),
    %% A comes back with its files, B (now the least recently used) goes
    ?assertMatch(#{<<"stdout">> := <<"from-a\n">>}, on(A, <<"cat /workspace/a.txt">>)),
    ?assertEqual({true, false, true}, {docker_running(A), docker_running(B), docker_running(C)}).

pool_idle_and_retention(Config) ->
    set_config(Config, #{<<"COMPUTER_MAX_RUNNING">> => <<"2">>}),
    A = muse_computer:ensure(?O, <<"thread:ct-a">>),
    B = muse_computer:ensure(?O, <<"task:ct-b">>),
    C = muse_computer:ensure(?O, <<"task:ct-c">>),
    muse_time:set_offset(16 * 60000),
    _ = on(C, <<"true">>),
    ok = muse_computer_pool:sweep(),
    %% A idled out (16 minutes); C was just used
    ?assertEqual({false, false, true}, {docker_running(A), docker_running(B), docker_running(C)}),
    ?assert(volume_exists(A)),
    %% 8 days later, the stopped A and B are deleted; C is idle-stopped
    muse_time:set_offset(8 * 86400000),
    ok = muse_computer_pool:sweep(),
    ?assertEqual({missing, missing, false}, {docker_running(A), docker_running(B), docker_running(C)}),
    ?assertNot(volume_exists(A)),
    ?assertNot(volume_exists(B)),
    ?assert(volume_exists(C)),
    ?assertEqual(undefined, muse_computers:get(?O, muse_computer:computer_id(A))),
    %% the default computer is exempt from retention
    ?assert(volume_exists(?LEGACY(?O))),
    muse_time:set_offset(0).

pool_reconcile(_Config) ->
    C = muse_computer:ensure(?O, <<"task:ct-c">>),
    ok = muse_computer:ensure_running(C),
    %% the record is lost; the running container is adopted as stopped
    muse_computers:remove(?O, muse_computer:computer_id(C)),
    ok = muse_computer_pool:reconcile(),
    ?assertMatch(#{<<"scope">> := <<"task:ct-c">>, <<"status">> := <<"stopped">>},
                 muse_computers:get(?O, muse_computer:computer_id(C))),
    ?assertEqual(false, docker_running(C)),
    ?assertMatch(#{<<"stdout">> := <<"c\n">>}, on(C, <<"echo c">>)).

pool_delete(_Config) ->
    C = muse_computer:ensure(?O, <<"task:ct-c">>),
    ?assertEqual(true, docker_running(C)),
    ?assertEqual(ok, muse_computer:delete(C)),
    ?assertEqual(missing, docker_running(C)),
    ?assertNot(volume_exists(C)),
    ?assertEqual(undefined, muse_computers:get(?O, muse_computer:computer_id(C))).
