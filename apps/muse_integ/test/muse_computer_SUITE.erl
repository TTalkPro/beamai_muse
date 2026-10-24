%% Real Docker computer (OpenMuse apps/computer/smoke.test.ts). Runs only with
%% MUSE_TEST_DOCKER=1; builds openmuse-computer:local from computer/ when it
%% is missing. Uses a unique deployment id and removes its container and
%% volume afterwards.
-module(muse_computer_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([isolation/1, output/1, files/1, symlinks_and_traversal/1, idempotent/1,
         pdf_bridge/1, command_timeout/1, stop_interrupts/1, caller_death/1,
         restart_keeps_workspace/1]).

-define(O, <<"local-user">>).
-define(IMAGE, <<"openmuse-computer:local">>).

all() -> [{group, computer}].

groups() ->
    [{computer, [sequence],
      [isolation, output, files, symlinks_and_traversal, idempotent, pdf_bridge,
       command_timeout, stop_interrupts, caller_death, restart_keeps_workspace]}].

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
    {ok, C} = muse_config:from_env(Env#{<<"COMPUTER_ENABLED">> => <<"true">>,
                                        <<"COMPUTER_DEPLOYMENT_ID">> => Deployment}),
    muse_config:set(C),
    ensure_image(),
    [{identity, muse_computer:identity(?O)} | Config].

end_per_suite(Config) ->
    #{container := Container, volume := Volume} = proplists:get_value(identity, Config),
    Removed = muse_docker:run([<<"container">>, <<"rm">>, <<"--force">>, Container],
                              #{timeout => 20000}),
    Vol = muse_docker:run([<<"volume">>, <<"rm">>, Volume], #{timeout => 20000}),
    muse_store:stop(),
    ?assertMatch(#{exit_code := 0}, Removed),
    ?assertMatch(#{exit_code := 0}, Vol),
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
    {ok, R} = muse_computer:execute(?O, #{command => Command}),
    R.

container(Config) ->
    maps:get(container, proplists:get_value(identity, Config)).

%% Cases

isolation(Config) ->
    ?assertMatch(#{<<"status">> := <<"stopped">>, <<"network">> := <<"disabled">>},
                 muse_computer:snapshot(?O)),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)),
    Ok = run(<<"id -u; id -g; node --version; python3 --version; git --version; "
               "printf 'persisted from bash\\n' > receipt.txt">>),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"exitCode">> := 0,
                   <<"stdout">> := <<"1000\n1000\nv22.", _/binary>>}, Ok),
    persistent_term:put({?MODULE, first}, maps:get(<<"id">>, Ok)),
    ?assertMatch(#{<<"status">> := <<"failed">>}, run(<<"touch /etc/openmuse-must-fail">>)),
    ?assertMatch(#{<<"status">> := <<"failed">>}, run(<<"touch /usr/bin/openmuse-must-fail">>)),
    ?assertMatch(#{<<"status">> := <<"failed">>},
                 run(<<"python3 -c 'import socket; socket.create_connection((\"1.1.1.1\", 443), 1)'">>)),
    ?assertMatch(#{<<"stdout">> := <<"lo\n">>}, run(<<"ls /sys/class/net">>)),
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
    ?assertMatch(#{<<"ReadonlyRootfs">> := true, <<"NetworkMode">> := <<"none">>,
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
                     {ok, R} = muse_computer:execute(?O, #{command => <<"pwd">>,
                                                           cwd => <<"/workspace/./sub">>}),
                     R
                 end).

files(_Config) ->
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes">>}},
                 muse_computer:mkdir(?O, <<"/workspace/notes">>)),
    Text = <<"Hello from the API ✓"/utf8>>,
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes/hello.txt">>}},
                 muse_computer:write(?O, <<"/workspace/notes/hello.txt">>, Text)),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes/hello.txt">>, <<"text">> => Text}},
                 muse_computer:read(?O, <<"/workspace/notes/hello.txt">>)),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/notes">>,
                        <<"entries">> => [#{<<"name">> => <<"hello.txt">>,
                                            <<"path">> => <<"/workspace/notes/hello.txt">>,
                                            <<"type">> => <<"file">>,
                                            <<"size">> => byte_size(Text)}]}},
                 muse_computer:list(?O, <<"/workspace/notes">>)),
    {ok, #{<<"entries">> := Entries}} = muse_computer:list(?O),
    [#{<<"type">> := <<"directory">>} | _] = Entries,
    ?assert(lists:member(<<"receipt.txt">>, [N || #{<<"name">> := N} <- Entries])),
    ?assertMatch({error, {422, _}}, muse_computer:read(?O, <<"/workspace/missing.txt">>)),
    ?assertMatch({ok, _}, muse_computer:mkdir(?O, <<"/workspace/a/b/c">>)),
    ?assertMatch(#{<<"stdout">> := <<"drwx------\n">>}, run(<<"stat -c %A a/b/c">>)).

symlinks_and_traversal(_Config) ->
    #{<<"status">> := <<"succeeded">>} =
        run(<<"ln -s /etc /workspace/escape && ln -s /etc/passwd /workspace/pw">>),
    Failed = {error, {422, <<"Computer file operation failed. Check the path, permissions and "
                             "file size; symlinks cannot be opened.">>}},
    ?assertEqual(Failed, muse_computer:read(?O, <<"/workspace/escape/passwd">>)),
    ?assertEqual(Failed, muse_computer:list(?O, <<"/workspace/escape">>)),
    ?assertEqual(Failed, muse_computer:write(?O, <<"/workspace/escape/x">>, <<"x">>)),
    ?assertEqual(Failed, muse_computer:read(?O, <<"/workspace/pw">>)),
    ?assertEqual(Failed, muse_computer:write(?O, <<"/workspace/pw">>, <<"x">>)),
    ?assertEqual(Failed, muse_computer:mkdir(?O, <<"/workspace/escape/sub">>)),
    Outside = {error, {422, <<"Choose an absolute path inside /workspace">>}},
    ?assertEqual(Outside, muse_computer:read(?O, <<"/workspace/../etc/passwd">>)),
    ?assertEqual(Outside, muse_computer:read(?O, <<"/etc/passwd">>)),
    {ok, #{<<"entries">> := Entries}} = muse_computer:list(?O),
    ?assertMatch([#{<<"type">> := <<"symlink">>}],
                 [E || E = #{<<"name">> := <<"escape">>} <- Entries]),
    ?assertMatch(#{<<"stdout">> := <<"root:", _/binary>>}, run(<<"head -c 5 /etc/passwd">>)).

idempotent(_Config) ->
    Key = <<"once-", (muse_ids:uuid())/binary>>,
    Args = #{command => <<"echo run >> /workspace/once.txt">>},
    {ok, First} = muse_computer:execute(?O, Args, #{idempotency_key => Key}),
    {ok, Second} = muse_computer:execute(?O, Args, #{idempotency_key => Key}),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, First),
    ?assertEqual(First, Second),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/once.txt">>, <<"text">> => <<"run\n">>}},
                 muse_computer:read(?O, <<"/workspace/once.txt">>)).

pdf_bridge(_Config) ->
    Pdf = <<"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n">>,
    meck:new(muse_files, [non_strict]),
    try
        meck:expect(muse_files, bytes, fun(?O, <<"file-1">>) -> {ok, Pdf} end),
        meck:expect(muse_files, import,
                    fun(?O, Name, Bytes, Source) ->
                            {ok, #{<<"id">> => <<"file-2">>, <<"name">> => Name,
                                   <<"size">> => byte_size(Bytes), <<"source">> => Source,
                                   <<"bytes">> => Bytes}}
                    end),
        ?assertEqual({ok, #{<<"path">> => <<"/workspace/source.pdf">>}},
                     muse_computer:import_pdf(?O, <<"/workspace/source.pdf">>, <<"file-1">>)),
        #{<<"status">> := <<"succeeded">>} = run(<<"cp source.pdf output.pdf">>),
        ?assertEqual({ok, #{<<"id">> => <<"file-2">>, <<"name">> => <<"output.pdf">>,
                            <<"size">> => byte_size(Pdf), <<"bytes">> => Pdf,
                            <<"source">> => <<"Computer: /workspace/output.pdf">>}},
                     muse_computer:export_pdf(?O, <<"/workspace/output.pdf">>)),
        ?assertMatch({error, {422, _}}, muse_computer:export_pdf(?O, <<"/workspace/once.txt">>))
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
    ?assertMatch(#{<<"status">> := <<"running">>}, muse_computer:snapshot(?O)).

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
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?O)),
    receive
        {pending, Result} ->
            ?assertMatch({ok, #{<<"status">> := <<"interrupted">>}}, Result)
    after 15000 ->
        error(no_result)
    end,
    ?assertMatch(#{<<"status">> := <<"stopped">>}, muse_computer:snapshot(?O)).

caller_death(Config) ->
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)),
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
    wait_for(fun() -> maps:get(<<"status">>, muse_computer:snapshot(?O)) =:= <<"stopped">> end),
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
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?O)),
    ?assertEqual({ok, #{<<"path">> => <<"/workspace/receipt.txt">>,
                        <<"text">> => <<"persisted from bash\n">>}},
                 muse_computer:read(?O, <<"/workspace/receipt.txt">>)),
    ?assertMatch({ok, #{<<"text">> := <<"Hello from the API ✓"/utf8>>}},
                 muse_computer:read(?O, <<"/workspace/notes/hello.txt">>)),
    First = persistent_term:get({?MODULE, first}),
    #{<<"commands">> := Commands} = muse_computer:snapshot(?O),
    ?assertMatch([#{<<"status">> := <<"succeeded">>}],
                 [C || C = #{<<"id">> := Id} <- Commands, Id =:= First]),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?O)),
    persistent_term:erase({?MODULE, first}).
