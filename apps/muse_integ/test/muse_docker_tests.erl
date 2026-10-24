-module(muse_docker_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pure parts

output_budget_is_shared_test() ->
    O1 = muse_docker:capture(stdout, <<"abcdef">>, muse_docker:new_output(10)),
    O2 = muse_docker:capture(stderr, <<"ghijkl">>, O1),
    O3 = muse_docker:capture(stdout, <<"m">>, O2),
    ?assertMatch(#{stdout := <<"abcdef">>, stderr := <<"ghij">>, truncated := true,
                   exit_code := null, timed_out := false, interrupted := false},
                 muse_docker:finish(O3)).

exact_fit_is_not_truncated_test() ->
    O = muse_docker:capture(stdout, <<"12345">>, muse_docker:new_output(5)),
    ?assertMatch(#{stdout := <<"12345">>, truncated := false}, muse_docker:finish(O)).

hard_ceiling_test() ->
    Big = binary:copy(<<"x">>, 15 * 1024 * 1024 + 10),
    #{stdout := Out, truncated := true} =
        muse_docker:finish(muse_docker:capture(stdout, Big, muse_docker:new_output(1 bsl 30))),
    ?assertEqual(15 * 1024 * 1024, byte_size(Out)).

utf8_replacement_test_() ->
    R = <<16#FFFD/utf8>>,
    [?_assertEqual(<<"é✓"/utf8>>, muse_docker:to_utf8(<<"é✓"/utf8>>)),
     ?_assertEqual(<<"a", R/binary, "b">>, muse_docker:to_utf8(<<"a", 16#FF, "b">>)),
     ?_assertEqual(<<"a", R/binary>>, muse_docker:to_utf8(<<"a", 16#E2, 16#82>>)),
     ?_assertEqual(<<R/binary, "A">>, muse_docker:to_utf8(<<16#E2, 16#82, "A">>)),
     ?_assertEqual(<<R/binary, R/binary>>, muse_docker:to_utf8(<<16#C0, 16#80>>)),
     ?_assertEqual(<<R/binary, R/binary, R/binary>>, muse_docker:to_utf8(<<16#ED, 16#A0, 16#80>>))].

argv_test_() ->
    Id = #{container => <<"c">>, volume => <<"v">>,
           labels => [{<<"dev.openmuse.managed">>, <<"computer-v1">>},
                      {<<"dev.openmuse.deployment">>, <<"d">>},
                      {<<"dev.openmuse.owner">>, <<"o">>}]},
    Labels = ["--label", "dev.openmuse.managed=computer-v1", "--label",
              "dev.openmuse.deployment=d", "--label", "dev.openmuse.owner=o"],
    B = fun(L) -> [list_to_binary(S) || S <- L] end,
    [?_assertEqual(B(["container", "ls", "--all", "--filter", "name=^/c$", "--format", "{{.ID}}"]),
                   muse_docker:find_args(<<"c">>)),
     ?_assertEqual(B(["container", "inspect", "c"]), muse_docker:inspect_args(<<"c">>)),
     ?_assertEqual(B(["container", "start", "c"]), muse_docker:start_args(<<"c">>)),
     ?_assertEqual(B(["container", "stop", "--time", "2", "c"]), muse_docker:stop_args(<<"c">>)),
     ?_assertEqual(B(["volume", "ls", "--filter", "name=^v$", "--format", "{{.Name}}"]),
                   muse_docker:volume_ls_args(<<"v">>)),
     ?_assertEqual(B(["volume", "create"] ++ Labels ++ ["v"]),
                   muse_docker:volume_create_args(<<"v">>, maps:get(labels, Id))),
     ?_assertEqual(B(["volume", "inspect", "v"]), muse_docker:volume_inspect_args(<<"v">>)),
     ?_assertEqual(B(["container", "create", "--pull", "never", "--name", "c"] ++ Labels ++
                     ["--user", "1000:1000", "--workdir", "/workspace", "--read-only",
                      "--cap-drop", "ALL",
                      "--security-opt", "no-new-privileges", "--network", "none",
                      "--ipc", "private",
                      "--memory", "512m", "--memory-swap", "512m", "--cpus", "1",
                      "--pids-limit", "128", "--restart", "no", "--init",
                      "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=67108864,mode=1777",
                      "--mount", "type=volume,source=v,target=/workspace",
                      "--env", "HOME=/workspace", "--env", "LANG=C.UTF-8",
                      "--entrypoint", "/usr/bin/sleep", "img:1", "infinity"]),
                   muse_docker:create_args(Id, <<"img:1">>)),
     ?_assertEqual(B(["exec", "--user", "1000:1000", "--workdir", "/workspace/x", "c",
                      "/usr/bin/timeout", "--signal=TERM", "--kill-after=2s", "30s",
                      "/bin/bash", "--noprofile", "--norc", "-c", "echo $HOME"]),
                   muse_docker:exec_args(<<"c">>, <<"/workspace/x">>, <<"echo $HOME">>)),
     ?_assertEqual(B(["exec", "-i", "--user", "1000:1000", "c",
                      "/usr/bin/timeout", "--kill-after=1s", "8s",
                      "/usr/bin/python3", "-I", "/opt/openmuse/files.py"]),
                   muse_docker:file_args(<<"c">>))].

%% The desktop variant (not in OpenMuse): same isolation, larger limits,
%% DISPLAY, the init script and the variant label. The light argv above is
%% also what create_args/3 gives for `light`.
desktop_argv_test_() ->
    Id = #{container => <<"c">>, volume => <<"v">>,
           labels => [{<<"dev.openmuse.managed">>, <<"computer-v1">>},
                      {<<"dev.openmuse.deployment">>, <<"d">>},
                      {<<"dev.openmuse.owner">>, <<"o">>}]},
    B = fun(L) -> [list_to_binary(S) || S <- L] end,
    Desktop = muse_docker:create_args(Id, <<"desk:1">>, desktop),
    [?_assertEqual(muse_docker:create_args(Id, <<"img:1">>),
                   muse_docker:create_args(Id, <<"img:1">>, light)),
     ?_assertEqual(B(["container", "create", "--pull", "never", "--name", "c",
                      "--label", "dev.openmuse.managed=computer-v1", "--label",
                      "dev.openmuse.deployment=d", "--label", "dev.openmuse.owner=o",
                      "--label", "dev.openmuse.variant=desktop",
                      "--user", "1000:1000", "--workdir", "/workspace", "--read-only",
                      "--cap-drop", "ALL",
                      "--security-opt", "no-new-privileges", "--network", "none",
                      "--ipc", "private",
                      "--memory", "1536m", "--memory-swap", "1536m", "--cpus", "2",
                      "--pids-limit", "512", "--restart", "no", "--init",
                      "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=268435456,mode=1777",
                      "--mount", "type=volume,source=v,target=/workspace",
                      "--env", "HOME=/workspace", "--env", "LANG=C.UTF-8",
                      "--env", "DISPLAY=:0",
                      "--entrypoint", "/opt/openmuse/desktop-init", "desk:1"]),
                   Desktop),
     ?_assertEqual([], [A || A <- Desktop, lists:member(A, [<<"--publish">>, <<"-p">>,
                                                             <<"--publish-all">>, <<"-P">>,
                                                             <<"--privileged">>, <<"--cap-add">>])]),
     ?_assertEqual(<<"dev.openmuse.variant">>, muse_docker:variant_label()),
     ?_assertEqual(B(["exec", "--user", "1000:1000", "--env", "DISPLAY=:0", "c",
                      "/usr/bin/timeout", "--signal=TERM", "--kill-after=2s", "30s",
                      "/bin/bash", "--noprofile", "--norc", "-c", "\"$@\"", "openmuse-desktop",
                      "xdotool", "type", "--", "$(rm -rf /) 'x'"]),
                   muse_docker:desktop_args(<<"c">>, <<"\"$@\"">>,
                                            [<<"xdotool">>, <<"type">>, <<"--">>,
                                             <<"$(rm -rf /) 'x'">>]))].

%% The runner against a fake `docker` (OpenMuse tests/computer-runner.test.ts)

-define(FAKE,
"#!/bin/sh
mode=\"$1\"
case \"$mode\" in
hang) exec sleep 30 ;;
output) head -c 500000 /dev/zero | tr '\\000' x; head -c 500000 /dev/zero | tr '\\000' y >&2 ;;
fail) printf failure >&2; exit 17 ;;
stdin) cat ;;
signal) kill -9 $$ ;;
*) exec python3 -c 'import json, os, sys; print(json.dumps({\"args\": sys.argv[1:], \"secret\": os.environ.get(\"MUSE_TEST_SECRET\")}), end=\"\")' \"$@\" ;;
esac
").

runner_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(erlexec),
             Dir = filename:join(os:getenv("TMPDIR", "/tmp"),
                                 "muse-docker-runner-" ++ integer_to_list(erlang:unique_integer([positive]))),
             ok = filelib:ensure_dir(filename:join(Dir, "x")),
             Fake = filename:join(Dir, "docker"),
             ok = file:write_file(Fake, ?FAKE),
             ok = file:change_mode(Fake, 8#700),
             true = os:putenv("MUSE_TEST_SECRET", "must-not-reach-docker-process"),
             set_path(list_to_binary(Dir ++ ":/usr/bin:/bin")),
             Dir
     end,
     fun(Dir) ->
             os:unsetenv("MUSE_TEST_SECRET"),
             _ = file:del_dir_r(Dir),
             persistent_term:erase({muse_config, config})
     end,
     fun(_) ->
             [{"literal argv, credentials stripped", fun literal_argv/0},
              {"exit code and stderr", fun failed/0},
              {"output cap", fun output_cap/0},
              {"stdin input", fun stdin_input/0},
              {"timeout kills", fun hang_timeout/0},
              {"cancel process death interrupts", fun cancelled/0},
              {"dead cancel process never spawns", fun already_cancelled/0},
              {"signal exit has no code", fun signalled/0},
              {"NUL in argv rejected", fun nul_arg/0},
              {"spawn failure", fun spawn_failure/0}]
     end}.

set_path(Path) ->
    {ok, Config} = muse_config:from_env(#{<<"PATH">> => Path, <<"HOME">> => <<"/tmp">>}),
    muse_config:set(Config).

literal_argv() ->
    Literal = <<"$(touch /must-not-run) ; echo $HOME ✓"/utf8>>,
    R = muse_docker:run([<<"exec">>, Literal], #{timeout => 5000}),
    ?assertMatch(#{exit_code := 0, timed_out := false, truncated := false}, R),
    ?assertEqual({ok, #{<<"args">> => [<<"exec">>, Literal], <<"secret">> => null}},
                 muse_json:decode(maps:get(stdout, R))).

failed() ->
    ?assertMatch(#{exit_code := 17, stderr := <<"failure">>, stdout := <<>>},
                 muse_docker:run([<<"fail">>], #{timeout => 5000})).

output_cap() ->
    #{stdout := O, stderr := E, truncated := T, exit_code := 0} =
        muse_docker:run([<<"output">>], #{timeout => 5000, max_output => 1000}),
    ?assert(T),
    ?assertEqual(1000, byte_size(O) + byte_size(E)),
    #{stdout := O2, stderr := E2, truncated := T2} =
        muse_docker:run([<<"output">>], #{timeout => 5000, max_output => 2000000}),
    ?assertNot(T2),
    ?assertEqual({500000, 500000}, {byte_size(O2), byte_size(E2)}).

stdin_input() ->
    ?assertMatch(#{stdout := <<"{\"a\":\"é\"}"/utf8>>, exit_code := 0},
                 muse_docker:run([<<"stdin">>], #{timeout => 5000,
                                                  input => <<"{\"a\":\"é\"}"/utf8>>})).

hang_timeout() ->
    T0 = erlang:monotonic_time(millisecond),
    R = muse_docker:run([<<"hang">>], #{timeout => 100}),
    ?assertMatch(#{timed_out := true, exit_code := null, interrupted := false}, R),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1500),
    assert_clean_mailbox().

cancelled() ->
    Canceller = spawn(fun() -> receive stop -> ok end end),
    timer:apply_after(100, erlang, exit, [Canceller, kill]),
    T0 = erlang:monotonic_time(millisecond),
    R = muse_docker:run([<<"hang">>], #{timeout => 5000, cancel => [Canceller]}),
    ?assertMatch(#{interrupted := true, timed_out := false, exit_code := null}, R),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1500),
    assert_clean_mailbox().

already_cancelled() ->
    {Dead, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, _, _, _} -> ok end,
    ?assertMatch(#{interrupted := true, exit_code := null},
                 muse_docker:run([<<"hang">>], #{timeout => 5000, cancel => [Dead]})).

signalled() ->
    ?assertMatch(#{exit_code := null, timed_out := false, interrupted := false},
                 muse_docker:run([<<"signal">>], #{timeout => 5000})).

nul_arg() ->
    ?assertError({invalid_argv, nul}, muse_docker:run([<<"a", 0, "b">>], #{timeout => 5000})).

spawn_failure() ->
    Saved = muse_config:all(),
    try
        set_path(<<"/nonexistent-muse-dir">>),
        ?assertEqual(#{stdout => <<>>, exit_code => null, timed_out => false,
                       interrupted => false, truncated => false,
                       stderr => <<"Docker CLI could not be started. Install Docker and "
                                   "start its engine.">>},
                     muse_docker:run([<<"x">>], #{timeout => 5000}))
    after
        muse_config:set(Saved)
    end.

assert_clean_mailbox() ->
    receive
        Msg -> ?assertEqual(no_message, Msg)
    after 50 -> ok
    end.
