%% @doc Docker CLI runner and the exact argv of the computer provider
%% (designs/ref/openmuse-integrations-spec.md §6.1, §6.3, §6.4;
%% designs/04-integrations.md §3).
%%
%% docker is spawned through erlexec with an argv list (never a shell) and an
%% environment cleared down to the whitelist in `muse_config` `docker_env`.
%% stdout and stderr are captured separately into one shared byte budget,
%% stdin carries the request (closed after writing), and the client is
%% SIGKILLed on timeout or when a monitored cancel process dies.
-module(muse_docker).

-export([run/2,
         output_limit/0, control_timeout/0,
         new_output/1, capture/3, finish/1, to_utf8/1,
         find_args/1, inspect_args/1, start_args/1, stop_args/1,
         volume_ls_args/1, volume_create_args/2, volume_inspect_args/1,
         create_args/2, create_args/3, create_args/4, exec_args/3, file_args/1,
         desktop_args/3, variant_label/0,
         rm_args/1, volume_rm_args/1, ps_args/2, stats_args/1, image_id_args/1]).

-export_type([result/0, run_opts/0, output/0, variant/0, network/0]).

-define(OUTPUT_LIMIT, 131072).
-define(HARD_CEILING, 15 * 1024 * 1024).
-define(CONTROL_TIMEOUT, 10000).
-define(SPAWN_FAILED, <<"Docker CLI could not be started. Install Docker and start its engine.">>).
-define(KILL_WAIT, 2000).

%% `light`: OpenMuse's computer (sleep as PID 1); `desktop`: the desktop
%% image (Xvfb + openbox), not in OpenMuse.
-type variant() :: light | desktop.
%% COMPUTER_NETWORK: `none` (OpenMuse) or Docker's default `bridge`.
-type network() :: none | bridge.
-type result() :: #{stdout := binary(), stderr := binary(),
                    exit_code := integer() | null,
                    timed_out := boolean(), interrupted := boolean(),
                    truncated := boolean()}.
-type run_opts() :: #{timeout := pos_integer(),
                      input => iodata(),
                      max_output => pos_integer(),
                      cancel => [pid()]}.
-opaque output() :: #{limit := non_neg_integer(), count := non_neg_integer(),
                      stdout := [binary()], stderr := [binary()],
                      result := result()}.

%% @doc Run `docker Args`. Never raises for docker failures; the outcome is
%% in the result flags (spawn failure: message in stderr, `exit_code` null).
-spec run([binary()], run_opts()) -> result().
run(Args, Opts) ->
    lists:foreach(fun check_arg/1, Args),
    Out = new_output(maps:get(max_output, Opts, ?OUTPUT_LIMIT)),
    Cancel = maps:get(cancel, Opts, []),
    case lists:any(fun(P) -> not is_process_alive(P) end, Cancel) of
        true ->
            finish(set(interrupted, Out));
        false ->
            Env = maps:to_list(muse_config:get(docker_env, #{})),
            case executable(Env) of
                false -> finish(capture(stderr, ?SPAWN_FAILED, Out));
                Exe -> spawn_docker(Exe, Args, Env, Opts, Out, Cancel)
            end
    end.

-spec output_limit() -> pos_integer().
output_limit() -> ?OUTPUT_LIMIT.

-spec control_timeout() -> pos_integer().
control_timeout() -> ?CONTROL_TIMEOUT.

%% @doc `computerOutput(maxOutputBytes)`: one budget for both streams,
%% capped at 15 MiB.
-spec new_output(pos_integer()) -> output().
new_output(Max) ->
    #{limit => min(Max, ?HARD_CEILING), count => 0, stdout => [], stderr => [],
      result => #{stdout => <<>>, stderr => <<>>, exit_code => null,
                  timed_out => false, interrupted => false, truncated => false}}.

%% @doc Take `min(remaining, size)` bytes of a chunk; an overflowing chunk
%% marks the result truncated.
-spec capture(stdout | stderr, binary(), output()) -> output().
capture(Stream, Chunk, Out = #{limit := Limit, count := Count}) ->
    Remaining = max(0, Limit - Count),
    Take = min(Remaining, byte_size(Chunk)),
    Out1 = case byte_size(Chunk) > Remaining of
               true -> set(truncated, Out);
               false -> Out
           end,
    Out1#{count := Count + Take,
          Stream := [binary:part(Chunk, 0, Take) | maps:get(Stream, Out1)]}.

-spec finish(output()) -> result().
finish(#{stdout := O, stderr := E, result := R}) ->
    R#{stdout := to_utf8(iolist_to_binary(lists:reverse(O))),
       stderr := to_utf8(iolist_to_binary(lists:reverse(E)))}.

%% @doc Node `Buffer.toString("utf8")`: each maximal ill-formed subsequence
%% becomes U+FFFD.
-spec to_utf8(binary()) -> binary().
to_utf8(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Good when is_binary(Good) -> Good;
        {_, Good, Rest} -> <<Good/binary, 16#FFFD/utf8, (to_utf8(skip_invalid(Rest)))/binary>>
    end.

-spec find_args(binary()) -> [binary()].
find_args(Container) ->
    [<<"container">>, <<"ls">>, <<"--all">>, <<"--filter">>,
     <<"name=^/", Container/binary, "$">>, <<"--format">>, <<"{{.ID}}">>].

-spec inspect_args(binary()) -> [binary()].
inspect_args(Container) -> [<<"container">>, <<"inspect">>, Container].

%% @doc The id of a local image (`sha256:…`), to compare with a container's.
-spec image_id_args(binary()) -> [binary()].
image_id_args(Image) -> [<<"image">>, <<"inspect">>, <<"--format">>, <<"{{.Id}}">>, Image].

-spec start_args(binary()) -> [binary()].
start_args(Container) -> [<<"container">>, <<"start">>, Container].

-spec stop_args(binary()) -> [binary()].
stop_args(Container) -> [<<"container">>, <<"stop">>, <<"--time">>, <<"2">>, Container].

-spec volume_ls_args(binary()) -> [binary()].
volume_ls_args(Volume) ->
    [<<"volume">>, <<"ls">>, <<"--filter">>, <<"name=^", Volume/binary, "$">>,
     <<"--format">>, <<"{{.Name}}">>].

-spec volume_create_args(binary(), [{binary(), binary()}]) -> [binary()].
volume_create_args(Volume, Labels) ->
    [<<"volume">>, <<"create">>] ++ label_args(Labels) ++ [Volume].

-spec volume_inspect_args(binary()) -> [binary()].
volume_inspect_args(Volume) -> [<<"volume">>, <<"inspect">>, Volume].

%% @doc Remove a computer container, running or not (computer pool delete).
-spec rm_args(binary()) -> [binary()].
rm_args(Container) -> [<<"container">>, <<"rm">>, <<"--force">>, Container].

-spec volume_rm_args(binary()) -> [binary()].
volume_rm_args(Volume) -> [<<"volume">>, <<"rm">>, Volume].

%% @doc The computer containers of one deployment (`running` or `all`), one
%% per line: name, state, owner hash, computer id, scope (tab separated,
%% the scope last; empty labels are empty fields).
-spec ps_args(binary(), running | all) -> [binary()].
ps_args(Deployment, Which) ->
    [<<"container">>, <<"ls">>]
    ++ [<<"--all">> || Which =:= all] ++
    [<<"--filter">>, <<"label=dev.openmuse.managed=computer-v1">>,
     <<"--filter">>, <<"label=dev.openmuse.deployment=", Deployment/binary>>,
     <<"--format">>,
     <<"{{.Names}}\t{{.State}}\t{{.Label \"dev.openmuse.owner\"}}\t"
       "{{.Label \"dev.openmuse.computer\"}}\t{{.Label \"dev.openmuse.scope\"}}">>].

%% @doc One `docker stats` sample of `Containers`: name, CPU %, memory usage.
-spec stats_args([binary()]) -> [binary()].
stats_args(Containers) ->
    [<<"container">>, <<"stats">>, <<"--no-stream">>, <<"--format">>,
     <<"{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}">> | Containers].

%% @doc `docker container create` for an owner's computer. `Identity` holds
%% `container`, `volume` and the ordered `labels`.
-spec create_args(#{container := binary(), volume := binary(),
                    labels := [{binary(), binary()}], _ => _},
                  binary()) -> [binary()].
create_args(Identity, Image) ->
    create_args(Identity, Image, light).

%% @doc `create_args/2` for a variant. `light` is OpenMuse's argv, byte for
%% byte. `desktop` keeps the same isolation (no network, read-only root, no
%% capabilities, no-new-privileges, `--init`, no published ports) with the
%% larger limits a desktop needs, `DISPLAY=:0` for every exec, the image's
%% init script as entrypoint, and the label `dev.openmuse.variant=desktop`.
-spec create_args(#{container := binary(), volume := binary(),
                    labels := [{binary(), binary()}], _ => _},
                  binary(), variant()) -> [binary()].
create_args(Identity, Image, Variant) ->
    create_args(Identity, Image, Variant, none).

%% @doc `create_args/3` on a network (COMPUTER_NETWORK, not in OpenMuse):
%% `none` is OpenMuse's argv; `bridge` only changes the `--network` value.
-spec create_args(#{container := binary(), volume := binary(),
                    labels := [{binary(), binary()}], _ => _},
                  binary(), variant(), network()) -> [binary()].
create_args(#{container := Container, volume := Volume, labels := Labels}, Image, Variant, Network) ->
    #{memory := Memory, cpus := Cpus, pids := Pids, tmpfs := Tmpfs, env := Env,
      entrypoint := Entrypoint, cmd := Cmd, labels := Extra} = limits(Variant),
    [<<"container">>, <<"create">>, <<"--pull">>, <<"never">>, <<"--name">>, Container]
    ++ label_args(Labels ++ Extra) ++
    [<<"--user">>, <<"1000:1000">>, <<"--workdir">>, <<"/workspace">>, <<"--read-only">>,
     <<"--cap-drop">>, <<"ALL">>,
     <<"--security-opt">>, <<"no-new-privileges">>, <<"--network">>, atom_to_binary(Network),
     <<"--ipc">>, <<"private">>,
     <<"--memory">>, Memory, <<"--memory-swap">>, Memory, <<"--cpus">>, Cpus,
     <<"--pids-limit">>, Pids, <<"--restart">>, <<"no">>,
     %% Not in OpenMuse: `sleep infinity` as PID 1 never reaps orphans, so
     %% processes left by killed or timed-out commands become zombies that
     %% count against the pids limit until no exec can fork. docker-init
     %% (tini) reaps them.
     <<"--init">>,
     <<"--tmpfs">>, <<"/tmp:", Tmpfs/binary>>,
     <<"--mount">>, <<"type=volume,source=", Volume/binary, ",target=/workspace">>,
     <<"--env">>, <<"HOME=/workspace">>, <<"--env">>, <<"LANG=C.UTF-8">>]
    ++ lists:append([[<<"--env">>, E] || E <- Env]) ++
    [<<"--entrypoint">>, Entrypoint, Image] ++ Cmd.

%% @doc The container label that marks the desktop variant.
-spec variant_label() -> binary().
variant_label() -> <<"dev.openmuse.variant">>.

-spec exec_args(binary(), binary(), binary()) -> [binary()].
exec_args(Container, Cwd, Command) ->
    [<<"exec">>, <<"--user">>, <<"1000:1000">>, <<"--workdir">>, Cwd, Container,
     <<"/usr/bin/timeout">>, <<"--signal=TERM">>, <<"--kill-after=2s">>, <<"30s">>,
     <<"/bin/bash">>, <<"--noprofile">>, <<"--norc">>, <<"-c">>, Command].

%% @doc A desktop action: the fixed `Script` run by bash with `Args` as its
%% positional parameters, so user text (typed text, key names) is always
%% an argv element and never part of a shell string.
-spec desktop_args(binary(), binary(), [binary()]) -> [binary()].
desktop_args(Container, Script, Args) ->
    [<<"exec">>, <<"--user">>, <<"1000:1000">>, <<"--env">>, <<"DISPLAY=:0">>, Container,
     <<"/usr/bin/timeout">>, <<"--signal=TERM">>, <<"--kill-after=2s">>, <<"30s">>,
     <<"/bin/bash">>, <<"--noprofile">>, <<"--norc">>, <<"-c">>, Script, <<"openmuse-desktop">>
     | Args].

-spec file_args(binary()) -> [binary()].
file_args(Container) ->
    [<<"exec">>, <<"-i">>, <<"--user">>, <<"1000:1000">>, Container,
     <<"/usr/bin/timeout">>, <<"--kill-after=1s">>, <<"8s">>,
     <<"/usr/bin/python3">>, <<"-I">>, <<"/opt/openmuse/files.py">>].

%% Internal

%% The variant settings `muse_computer_docker` also verifies on attach.
limits(light) ->
    #{memory => <<"512m">>, cpus => <<"1">>, pids => <<"128">>,
      tmpfs => <<"rw,nosuid,nodev,noexec,size=67108864,mode=1777">>, env => [],
      entrypoint => <<"/usr/bin/sleep">>, cmd => [<<"infinity">>], labels => []};
limits(desktop) ->
    #{memory => <<"1536m">>, cpus => <<"2">>, pids => <<"512">>,
      tmpfs => <<"rw,nosuid,nodev,noexec,size=268435456,mode=1777">>,
      env => [<<"DISPLAY=:0">>],
      entrypoint => <<"/opt/openmuse/desktop-init">>, cmd => [],
      labels => [{variant_label(), <<"desktop">>}]}.

label_args(Labels) ->
    lists:append([[<<"--label">>, <<K/binary, "=", V/binary>>] || {K, V} <- Labels]).

%% Node's spawn rejects NUL inside an argument before starting the process.
check_arg(Arg) when is_binary(Arg) ->
    case binary:match(Arg, <<0>>) of
        nomatch -> _ = chars(Arg), ok;
        _ -> erlang:error({invalid_argv, nul})
    end.

set(Flag, Out = #{result := R}) ->
    Out#{result := R#{Flag := true}}.

executable(Env) ->
    case proplists:get_value(<<"PATH">>, Env) of
        undefined -> false;
        Path -> os:find_executable("docker", binary_to_list(Path))
    end.

spawn_docker(Exe, Args, Env, Opts, Out, Cancel) ->
    ExecOpts = [stdin, {stdout, self()}, {stderr, self()}, monitor,
                {env, [clear | [{chars(K), chars(V)} || {K, V} <- Env]]}],
    Argv = [Exe | [chars(A) || A <- Args]],
    case exec:run(Argv, ExecOpts) of
        {ok, _Pid, OsPid} ->
            Refs = maps:from_keys([erlang:monitor(process, P) || P <- Cancel], cancel),
            _ = (catch exec:send(OsPid, iolist_to_binary(maps:get(input, Opts, <<>>)))),
            _ = (catch exec:send(OsPid, eof)),
            Deadline = erlang:monotonic_time(millisecond) + maps:get(timeout, Opts),
            Result = collect(OsPid, Refs, Deadline, Out),
            _ = [erlang:demonitor(R, [flush]) || R <- maps:keys(Refs)],
            Result;
        {error, _} ->
            finish(capture(stderr, ?SPAWN_FAILED, Out))
    end.

%% erlexec UTF-8-encodes charlists itself.
chars(Bin) ->
    case unicode:characters_to_list(Bin) of
        L when is_list(L) -> L;
        _ -> erlang:error({invalid_argv, utf8})
    end.

collect(OsPid, Refs, Deadline, Out) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {stdout, OsPid, Data} ->
            collect(OsPid, Refs, Deadline, capture(stdout, Data, Out));
        {stderr, OsPid, Data} ->
            collect(OsPid, Refs, Deadline, capture(stderr, Data, Out));
        {'DOWN', OsPid, process, _, Reason} ->
            #{result := R} = Out,
            finish(Out#{result := R#{exit_code := exit_code(Reason)}});
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Refs) ->
            kill(OsPid, set(interrupted, Out))
    after Wait ->
        kill(OsPid, set(timed_out, Out))
    end.

%% Like the original, the result is settled at kill time (exit code null);
%% the remaining messages of the killed client are drained.
kill(OsPid, Out) ->
    _ = (catch exec:kill(OsPid, 9)),
    receive
        {'DOWN', OsPid, process, _, _} -> ok
    after ?KILL_WAIT -> ok
    end,
    drain(OsPid),
    finish(Out).

drain(OsPid) ->
    receive
        {stdout, OsPid, _} -> drain(OsPid);
        {stderr, OsPid, _} -> drain(OsPid)
    after 0 -> ok
    end.

exit_code(normal) -> 0;
exit_code({exit_status, Status}) ->
    case exec:status(Status) of
        {status, Code} -> Code;
        {signal, _, _} -> null
    end;
exit_code(_) -> null.

%% Drop one maximal ill-formed subsequence (WHATWG UTF-8 decoder).
skip_invalid(<<Lead, Rest/binary>>) ->
    {Ranges, N} = if
                      Lead >= 16#C2, Lead =< 16#DF -> {[{16#80, 16#BF}], 1};
                      Lead =:= 16#E0 -> {[{16#A0, 16#BF}, {16#80, 16#BF}], 2};
                      Lead =:= 16#ED -> {[{16#80, 16#9F}, {16#80, 16#BF}], 2};
                      Lead >= 16#E1, Lead =< 16#EF -> {[{16#80, 16#BF}, {16#80, 16#BF}], 2};
                      Lead =:= 16#F0 -> {[{16#90, 16#BF}, {16#80, 16#BF}, {16#80, 16#BF}], 3};
                      Lead >= 16#F1, Lead =< 16#F3 ->
                          {[{16#80, 16#BF}, {16#80, 16#BF}, {16#80, 16#BF}], 3};
                      Lead =:= 16#F4 -> {[{16#80, 16#8F}, {16#80, 16#BF}, {16#80, 16#BF}], 3};
                      true -> {[], 0}
                  end,
    skip_continuations(Ranges, N, Rest).

skip_continuations([{Lo, Hi} | More], N, <<C, Rest/binary>>) when C >= Lo, C =< Hi, N > 0 ->
    skip_continuations(More, N - 1, Rest);
skip_continuations(_, _, Rest) ->
    Rest.
