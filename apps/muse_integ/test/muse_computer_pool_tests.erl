-module(muse_computer_pool_tests).
-include_lib("eunit/include/eunit.hrl").

%% The computer pool (muse_computers, muse_computer_pool, the pool parts of
%% muse_computer and muse_computer_docker; not in OpenMuse). `muse_docker:run/2`
%% is replaced by a small Docker simulator: containers and volumes live in
%% an ETS table and are created, started, stopped, listed, inspected and
%% removed from the exact argv the provider sends.

-define(O, <<"owner">>).
-define(T, muse_computer_pool_sim).
-define(MIN, 60000).
-define(DAY, 86400000).
%% An older version's default computer, which keeps OpenMuse's names.
-define(LEGACY(O), {O, muse_computers:legacy_id(O)}).

pool_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [{"two scopes get two containers and two volumes", fun per_scope/0},
      {"the legacy default computer keeps OpenMuse's names", fun default_names/0},
      {"auto-start on the first command", fun auto_start/0},
      {"ensure_running starts only a stopped computer", fun ensure_running/0},
      {"max running stops the least recently used idle computer", fun eviction/0},
      {"busy computers are never evicted; a full pool fails clearly", fun eviction_busy/0},
      {"idle computers are stopped, their volume kept", fun idle_stop/0},
      {"stopped computers past retention are deleted", fun retention/0},
      {"reconcile: records follow Docker", fun reconcile_records/0},
      {"reconcile: orphan containers are adopted or stopped", fun reconcile_orphans/0},
      {"delete removes container, volume and the computer's records", fun delete/0},
      {"COMPUTER_NETWORK: bridge argv, exact network verification", fun network/0},
      {"overview: running computers and docker stats", fun overview/0},
      {"an updated image recreates a stopped computer's container, keeping its volume", fun image_update/0}]}.

setup() ->
    ok = muse_store:init(#{storage => ram}),
    config(#{}),
    Holder = spawn(fun() -> receive stop -> ok end end),
    ?T = ets:new(?T, [named_table, public, {heir, none}]),
    ets:give_away(?T, Holder, none),
    ets:insert(?T, {exec_hook, fun(_) -> default end}),
    meck:new(muse_docker, [passthrough]),
    meck:expect(muse_docker, run, fun sim/2),
    Holder.

cleanup(Holder) ->
    meck:unload(),
    muse_time:set_offset(0),
    Holder ! stop,
    persistent_term:erase({muse_config, config}),
    muse_store:stop().

config(Extra) ->
    {ok, C} = muse_config:from_env(maps:merge(#{<<"COMPUTER_ENABLED">> => <<"true">>,
                                               <<"COMPUTER_DEPLOYMENT_ID">> => <<"pool-test">>},
                                             Extra)),
    muse_config:set(C).

%% Docker simulator

ok(Out) ->
    #{stdout => Out, stderr => <<>>, exit_code => 0, timed_out => false, interrupted => false,
      truncated => false}.

fail() ->
    (ok(<<>>))#{exit_code := 1, stderr := <<"Error: No such object">>}.

sim(Args, _Opts) ->
    ets:insert(?T, {{call, erlang:unique_integer([monotonic, positive])}, Args}),
    reply(Args).

calls() ->
    [A || {_, A} <- lists:sort([{N, A} || {{call, N}, A} <- ets:tab2list(?T)])].

container(Name) ->
    case ets:lookup(?T, {c, Name}) of
        [{_, C}] -> C;
        [] -> undefined
    end.

volume(Name) ->
    case ets:lookup(?T, {v, Name}) of
        [{_, V}] -> V;
        [] -> undefined
    end.

labels(Args) ->
    maps:from_list([list_to_tuple(binary:split(L, <<"=">>)) || L <- after_flag(<<"--label">>, Args)]).

after_flag(Flag, [Flag, V | Rest]) -> [V | after_flag(Flag, Rest)];
after_flag(Flag, [_ | Rest]) -> after_flag(Flag, Rest);
after_flag(_, []) -> [].

reply([<<"container">>, <<"ls">>, <<"--all">>, <<"--filter">>, <<"name=^/", Filter/binary>> | _]) ->
    Name = binary:part(Filter, 0, byte_size(Filter) - 1),
    case container(Name) of
        undefined -> ok(<<>>);
        _ -> ok(<<"id-", Name/binary, "\n">>)
    end;
reply([<<"container">>, <<"ls">> | Rest]) ->
    All = lists:member(<<"--all">>, Rest),
    [<<"label=dev.openmuse.deployment=", Dep/binary>>] =
        [F || F = <<"label=dev.openmuse.deployment=", _/binary>> <- Rest],
    Lines = [[N, $\t, case R of true -> <<"running">>; false -> <<"exited">> end, $\t,
              maps:get(<<"dev.openmuse.owner">>, L, <<>>), $\t,
              maps:get(<<"dev.openmuse.computer">>, L, <<>>), $\t,
              maps:get(<<"dev.openmuse.scope">>, L, <<>>), $\n]
             || {{c, N}, #{running := R, labels := L}} <- ets:tab2list(?T),
                maps:get(<<"dev.openmuse.deployment">>, L, <<>>) =:= Dep, All orelse R],
    ok(iolist_to_binary(Lines));
reply([<<"container">>, <<"inspect">>, Name]) ->
    case container(Name) of
        undefined -> fail();
        C -> ok(muse_json:encode([inspection(Name, C)]))
    end;
reply([<<"container">>, <<"create">> | Args]) ->
    [Name] = after_flag(<<"--name">>, Args),
    [<<"type=volume,source=", Mount/binary>>] = after_flag(<<"--mount">>, Args),
    [Volume, _] = binary:split(Mount, <<",">>),
    [Network] = after_flag(<<"--network">>, Args),
    ets:insert(?T, {{c, Name}, #{running => false, labels => labels(Args), volume => Volume,
                                 network => Network, image => image_id()}}),
    ok(<<"id-", Name/binary, "\n">>);
reply([<<"image">>, <<"inspect">>, <<"--format">>, <<"{{.Id}}">>, _Image]) ->
    ok(<<(image_id())/binary, "\n">>);
reply([<<"container">>, <<"start">>, Name]) ->
    set_running(Name, true);
reply([<<"container">>, <<"stop">>, <<"--time">>, _, Name]) ->
    set_running(Name, false);
reply([<<"container">>, <<"rm">>, <<"--force">>, Name]) ->
    ets:delete(?T, {c, Name}),
    ok(Name);
reply([<<"container">>, <<"stats">>, <<"--no-stream">>, <<"--format">>, _ | Names]) ->
    ok(iolist_to_binary([[N, <<"\t0.25%\t12MiB / 512MiB\n">>] || N <- Names]));
reply([<<"volume">>, <<"ls">>, <<"--filter">>, <<"name=^", Filter/binary>> | _]) ->
    Name = binary:part(Filter, 0, byte_size(Filter) - 1),
    case volume(Name) of
        undefined -> ok(<<>>);
        _ -> ok(<<Name/binary, "\n">>)
    end;
reply([<<"volume">>, <<"create">> | Args]) ->
    Name = lists:last(Args),
    ets:insert(?T, {{v, Name}, labels(Args)}),
    ok(Name);
reply([<<"volume">>, <<"inspect">>, Name]) ->
    case volume(Name) of
        undefined -> fail();
        L -> ok(muse_json:encode([#{<<"Name">> => Name, <<"Labels">> => L, <<"Driver">> => <<"local">>,
                                    <<"Options">> => null, <<"Scope">> => <<"local">>}]))
    end;
reply([<<"volume">>, <<"rm">>, Name]) ->
    ets:delete(?T, {v, Name}),
    ok(Name);
reply([<<"exec">> | _] = Args) ->
    [{exec_hook, Hook}] = ets:lookup(?T, exec_hook),
    case Hook(Args) of
        default -> ok(<<"hello\n">>);
        R -> R
    end.

%% The id of the current build of the image (tests change it to simulate
%% `make computer-image`).
image_id() ->
    case ets:lookup(?T, image_id) of
        [{_, I}] -> I;
        [] -> <<"sha256:build-1">>
    end.

set_running(Name, Running) ->
    case container(Name) of
        undefined -> fail();
        C -> ets:insert(?T, {{c, Name}, C#{running := Running}}), ok(Name)
    end.

inspection(Name, #{running := Running, labels := Labels, volume := Volume, network := Network} = C) ->
    #{<<"Id">> => <<"id-", Name/binary>>,
      <<"Name">> => <<"/", Name/binary>>,
      <<"Image">> => maps:get(image, C, <<"sha256:build-1">>),
      <<"Config">> => #{<<"Image">> => <<"openmuse-computer:local">>,
                        <<"User">> => <<"1000:1000">>,
                        <<"Labels">> => Labels,
                        <<"Env">> => [<<"PATH=/usr/bin:/bin">>, <<"HOME=/workspace">>, <<"LANG=C.UTF-8">>],
                        <<"Entrypoint">> => [<<"/usr/bin/sleep">>],
                        <<"Cmd">> => [<<"infinity">>],
                        <<"WorkingDir">> => <<"/workspace">>},
      <<"HostConfig">> => #{<<"ReadonlyRootfs">> => true, <<"Privileged">> => false,
                            <<"CapDrop">> => [<<"ALL">>], <<"CapAdd">> => null,
                            <<"SecurityOpt">> => [<<"no-new-privileges">>],
                            <<"NetworkMode">> => Network,
                            <<"Memory">> => 536870912, <<"MemorySwap">> => 536870912,
                            <<"PidsLimit">> => 128, <<"NanoCpus">> => 1000000000,
                            <<"Binds">> => null, <<"Devices">> => [], <<"DeviceRequests">> => null,
                            <<"PortBindings">> => #{}, <<"PidMode">> => <<>>,
                            <<"IpcMode">> => <<"private">>,
                            <<"Tmpfs">> => #{<<"/tmp">> =>
                                                 <<"rw,nosuid,nodev,noexec,size=67108864,mode=1777">>},
                            <<"RestartPolicy">> => #{<<"Name">> => <<"no">>}},
      <<"Mounts">> => [#{<<"Type">> => <<"volume">>, <<"Name">> => Volume,
                         <<"Destination">> => <<"/workspace">>, <<"RW">> => true}],
      <<"NetworkSettings">> => #{<<"Networks">> => #{Network => #{}}},
      <<"State">> => #{<<"Running">> => Running}}.

running(Ref) ->
    #{container := C} = muse_computer:identity(Ref),
    case container(C) of
        #{running := R} -> R;
        undefined -> missing
    end.

status(Ref) ->
    {Owner, Id} = muse_computer:resolve(Ref),
    maps:get(<<"status">>, muse_computers:get(Owner, Id)).

%% Hold the next exec until {finish, Result} (a command in flight).
block_exec() ->
    Test = self(),
    ets:insert(?T, {exec_hook, fun(_) -> Test ! {exec_started, self()},
                                         receive {finish, R} -> R end
                               end}).

async(Fun) ->
    Self = self(),
    Tag = make_ref(),
    spawn(fun() -> Self ! {Tag, Fun()} end),
    Tag.

await(Tag) ->
    receive {Tag, R} -> R after 10000 -> error(await_timeout) end.

advance(Ms) ->
    muse_time:set_offset(muse_time:offset() + Ms).

%% Cases

per_scope() ->
    A = muse_computer:ensure(?O, <<"thread:th-1">>),
    B = muse_computer:ensure(?O, <<"task:task-1">>),
    ?assertNotEqual(A, B),
    #{container := CA, volume := VA, labels := LA} = muse_computer:identity(A),
    #{container := CB, volume := VB} = muse_computer:identity(B),
    ?assertNotEqual(CA, CB),
    ?assertNotEqual(VA, VB),
    ?assert(lists:member({<<"dev.openmuse.computer">>, muse_computer:computer_id(A)}, LA)),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(A)),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(B)),
    ?assertMatch(#{running := true, volume := VA}, container(CA)),
    ?assertMatch(#{running := true, volume := VB}, container(CB)),
    %% the scope is a label of container and volume (for re-adoption)
    ?assertMatch(#{labels := #{<<"dev.openmuse.scope">> := <<"thread:th-1">>}}, container(CA)),
    ?assertMatch(#{<<"dev.openmuse.scope">> := <<"thread:th-1">>}, volume(VA)),
    %% receipts and files are per computer
    {ok, #{<<"computerId">> := IdA}} = muse_computer:execute(A, #{command => <<"echo a">>}),
    ?assertEqual(muse_computer:computer_id(A), IdA),
    ?assertMatch([#{<<"command">> := <<"echo a">>}], maps:get(<<"commands">>, muse_computer:snapshot(A))),
    ?assertEqual([], maps:get(<<"commands">>, muse_computer:snapshot(B))),
    ?assertEqual([], maps:get(<<"commands">>, muse_computer:snapshot(?LEGACY(?O)))),
    [ExecA] = [X || X = [<<"exec">> | _] <- calls()],
    ?assert(lists:member(CA, ExecA)),
    %% the pool records
    ?assertMatch([_, _], muse_computers:list(?O)),
    ?assertEqual(<<"running">>, status(A)),
    ?assertMatch(#{<<"scope">> := <<"task:task-1">>, <<"container">> := CB, <<"volume">> := VB,
                   <<"variant">> := <<"light">>, <<"createdAt">> := _, <<"lastUsedAt">> := _,
                   <<"startedAt">> := S} when is_binary(S),
                 muse_computers:get(?O, muse_computer:computer_id(B))),
    %% two leases
    ?assertNotEqual(muse_computer:lease_id(A), muse_computer:lease_id(B)).

default_names() ->
    ?assertEqual(?LEGACY(?O), muse_computer:ref(?O, <<"user">>)),
    #{container := C, volume := V, labels := L} = muse_computer:identity(?LEGACY(?O)),
    Dep = binary:part(muse_ids:sha256hex(<<"pool-test">>), 0, 16),
    Hash = binary:part(muse_ids:sha256hex(?O), 0, 24),
    ?assertEqual(<<"openmuse-", Dep/binary, "-", Hash/binary, "-computer">>, C),
    ?assertEqual(<<"openmuse-", Dep/binary, "-", Hash/binary, "-workspace">>, V),
    ?assertEqual(3, length(L)),
    ?assertEqual(<<"lease">>, muse_computer:lease_id(?LEGACY(?O))),
    %% an adopted legacy computer gets its record back on first use
    ?assertEqual([], muse_computers:list(?O)),
    {ok, _} = muse_computer:start(?LEGACY(?O)),
    ?assertMatch([#{<<"scope">> := <<"user">>, <<"title">> := <<"旧的默认电脑"/utf8>>}], muse_computers:list(?O)),
    ?assertEqual(?LEGACY(?O), muse_computer:ensure(?O, <<"user">>)),
    ?assertNot(maps:is_key(<<"computerId">>, element(2, muse_computer:execute(?LEGACY(?O), #{command => <<"pwd">>})))).

auto_start() ->
    A = muse_computer:ensure(?O, <<"thread:th-1">>),
    ?assertEqual(missing, running(A)),
    %% without auto_start: OpenMuse's 409
    ?assertEqual({error, {409, <<"Start the computer before using its terminal or files">>}},
                 muse_computer:execute(A, #{command => <<"pwd">>})),
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>, <<"stdout">> := <<"hello\n">>}},
                 muse_computer:execute(A, #{command => <<"pwd">>}, #{auto_start => true})),
    ?assertEqual(true, running(A)),
    ?assertEqual(<<"running">>, status(A)),
    %% running already: no second start
    N = length([x || [<<"container">>, <<"start">> | _] <- calls()]),
    {ok, _} = muse_computer:execute(A, #{command => <<"pwd">>}, #{auto_start => true}),
    ?assertEqual(N, length([x || [<<"container">>, <<"start">> | _] <- calls()])),
    %% disabled: the setup message, nothing created
    config(#{<<"COMPUTER_ENABLED">> => <<"false">>}),
    B = muse_computer:ensure(?O, <<"thread:th-2">>),
    ?assertMatch({error, {503, <<"Computer is not configured", _/binary>>}},
                 muse_computer:execute(B, #{command => <<"pwd">>}, #{auto_start => true})),
    ?assertEqual(missing, running(B)).

ensure_running() ->
    A = muse_computer:ensure(?O, <<"task:t">>),
    ?assertEqual(ok, muse_computer:ensure_running(A)),
    ?assertEqual(true, running(A)),
    {ok, _} = muse_computer:stop(A),
    ?assertEqual(false, running(A)),
    ?assertEqual(<<"stopped">>, status(A)),
    ?assertEqual(ok, muse_computer:ensure_running(A)),
    ?assertEqual(true, running(A)),
    %% files then work
    ?assertMatch({error, {502, _}}, muse_computer:list(A)).

eviction() ->
    config(#{<<"COMPUTER_MAX_RUNNING">> => <<"2">>}),
    [A, B, C] = [muse_computer:ensure(?O, S) || S <- [<<"task:a">>, <<"task:b">>, <<"task:c">>]],
    {ok, _} = muse_computer:start(A),
    advance(?MIN),
    {ok, _} = muse_computer:start(B),
    advance(?MIN),
    %% A is used again: B is now the least recently used
    {ok, _} = muse_computer:execute(A, #{command => <<"true">>}),
    advance(?MIN),
    {ok, #{<<"status">> := <<"running">>}} = muse_computer:start(C),
    ?assertEqual({true, false, true}, {running(A), running(B), running(C)}),
    ?assertEqual(<<"stopped">>, status(B)),
    %% B's volume is kept
    #{volume := VB} = muse_computer:identity(B),
    ?assertNotEqual(undefined, volume(VB)),
    %% restarting B evicts the least recently used of A and C (C was started last)
    {ok, _} = muse_computer:start(B),
    ?assertEqual({false, true, true}, {running(A), running(B), running(C)}).

eviction_busy() ->
    config(#{<<"COMPUTER_MAX_RUNNING">> => <<"1">>}),
    A = muse_computer:ensure(?O, <<"task:a">>),
    B = muse_computer:ensure(?O, <<"task:b">>),
    {ok, _} = muse_computer:start(A),
    block_exec(),
    Pending = async(fun() -> muse_computer:execute(A, #{command => <<"sleep 10">>}) end),
    Exec = receive {exec_started, P} -> P after 5000 -> error(no_exec) end,
    ?assert(muse_computer:busy(A)),
    {error, {503, Msg}} = muse_computer:start(B),
    ?assertMatch(<<"All 1 running computers are busy (COMPUTER_MAX_RUNNING).", _/binary>>, Msg),
    ?assertEqual({true, missing}, {running(A), running(B)}),
    %% the auto-start of a tool reports the same
    ?assertEqual({error, {503, Msg}}, muse_computer:execute(B, #{command => <<"ls">>}, #{auto_start => true})),
    Exec ! {finish, ok(<<"done\n">>)},
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>}}, await(Pending)),
    ets:insert(?T, {exec_hook, fun(_) -> default end}),
    {ok, _} = muse_computer:start(B),
    ?assertEqual({false, true}, {running(A), running(B)}).

idle_stop() ->
    A = muse_computer:ensure(?O, <<"thread:th-1">>),
    B = muse_computer:ensure(?O, <<"thread:th-2">>),
    {ok, _} = muse_computer:start(A),
    {ok, _} = muse_computer:start(B),
    advance(10 * ?MIN),
    {ok, _} = muse_computer:execute(B, #{command => <<"true">>}),
    advance(6 * ?MIN),
    ok = muse_computer_pool:sweep(),
    %% A: 16 minutes unused (default 15); B: 6 minutes
    ?assertEqual({false, true}, {running(A), running(B)}),
    ?assertEqual(<<"stopped">>, status(A)),
    #{volume := VA} = muse_computer:identity(A),
    ?assertNotEqual(undefined, volume(VA)),
    %% a busy computer is not stopped
    config(#{<<"COMPUTER_IDLE_MINUTES">> => <<"1">>}),
    advance(2 * ?MIN),
    block_exec(),
    Pending = async(fun() -> muse_computer:execute(B, #{command => <<"sleep 1">>}) end),
    Exec = receive {exec_started, P} -> P after 5000 -> error(no_exec) end,
    advance(2 * ?MIN),
    ok = muse_computer_pool:sweep(),
    ?assertEqual(true, running(B)),
    Exec ! {finish, ok(<<>>)},
    {ok, _} = await(Pending).

retention() ->
    A = muse_computer:ensure(?O, <<"task:old">>),
    {ok, _} = muse_computer:start(A),
    {ok, _} = muse_computer:execute(A, #{command => <<"true">>}),
    {ok, _} = muse_computer:start(?LEGACY(?O)),
    {ok, _} = muse_computer:stop(A),
    {ok, _} = muse_computer:stop(?LEGACY(?O)),
    #{container := CA, volume := VA} = muse_computer:identity(A),
    #{container := CD, volume := VD} = muse_computer:identity(?LEGACY(?O)),
    advance(6 * ?DAY),
    ok = muse_computer_pool:sweep(),
    ?assertNotEqual(undefined, container(CA)),
    advance(2 * ?DAY),
    ok = muse_computer_pool:sweep(),
    %% 8 days unused (default 7): container, volume, receipts and record are gone
    ?assertEqual({undefined, undefined}, {container(CA), volume(VA)}),
    ?assertEqual(undefined, muse_computers:get(?O, muse_computer:computer_id(A))),
    ?assertEqual([], [R || R = #{<<"computerId">> := _} <- muse_store:list(?O, <<"computer-commands">>)]),
    %% the default computer is exempt
    ?assertNotEqual(undefined, container(CD)),
    ?assertNotEqual(undefined, volume(VD)),
    ?assertMatch([#{<<"scope">> := <<"user">>}], muse_computers:list(?O)).

reconcile_records() ->
    A = muse_computer:ensure(?O, <<"task:a">>),
    {ok, _} = muse_computer:start(A),
    ?assertEqual(<<"running">>, status(A)),
    %% the container vanished behind our back
    #{container := CA} = muse_computer:identity(A),
    ets:delete(?T, {c, CA}),
    ok = muse_computer_pool:reconcile(),
    ?assertEqual(<<"stopped">>, status(A)),
    %% a record says stopped but the container runs
    {ok, _} = muse_computer:start(A),
    muse_computers:set_status(?O, muse_computer:computer_id(A), <<"stopped">>),
    ok = muse_computer_pool:sweep(),
    ?assertEqual(<<"running">>, status(A)).

reconcile_orphans() ->
    %% a known owner (it has a conversation) whose records were lost
    _ = muse_store:put(?O, <<"threads">>, #{<<"id">> => <<"th-9">>, <<"title">> => <<"Plans">>}),
    A = muse_computer:ensure(?O, <<"thread:th-9">>),
    {ok, _} = muse_computer:start(A),
    {ok, _} = muse_computer:start(?LEGACY(?O)),
    _ = [muse_store:remove(?O, <<"computers">>, Id) || #{<<"id">> := Id} <- muse_computers:list(?O)],
    %% and a container of an owner nobody knows
    Stranger = {<<"stranger">>, muse_computers:id(<<"stranger">>, <<"task:x">>)},
    #{container := CS, volume := VS, labels := LS} = muse_computer:identity(Stranger),
    ets:insert(?T, {{c, CS}, #{running => true, volume => VS, network => <<"bridge">>,
                               labels => maps:from_list(LS)}}),
    ok = muse_computer_pool:reconcile(),
    %% adopted as stopped computers, with their scopes and titles
    ?assertMatch([#{<<"status">> := <<"stopped">>}, #{<<"status">> := <<"stopped">>}], muse_computers:list(?O)),
    ?assertMatch(#{<<"scope">> := <<"thread:th-9">>, <<"title">> := <<"Plans">>},
                 muse_computers:get(?O, muse_computer:computer_id(A))),
    ?assertMatch(#{<<"scope">> := <<"user">>}, muse_computers:get(?O, muse_computers:legacy_id(?O))),
    ?assertEqual({false, false}, {running(A), running(?LEGACY(?O))}),
    %% the stranger's container is stopped and kept
    ?assertMatch(#{running := false}, container(CS)),
    ?assertEqual([], muse_store:list(<<"stranger">>, <<"computers">>)).

delete() ->
    A = muse_computer:ensure(?O, <<"task:a">>),
    B = muse_computer:ensure(?O, <<"task:b">>),
    {ok, _} = muse_computer:execute(A, #{command => <<"echo a">>}, #{auto_start => true}),
    {ok, _} = muse_computer:execute(B, #{command => <<"echo b">>}, #{auto_start => true}),
    #{container := CA, volume := VA} = muse_computer:identity(A),
    ?assertEqual(ok, muse_computer:delete(A)),
    ?assertEqual({undefined, undefined}, {container(CA), volume(VA)}),
    ?assert(lists:member([<<"volume">>, <<"rm">>, VA], calls())),
    ?assertEqual(undefined, muse_computers:get(?O, muse_computer:computer_id(A))),
    ?assertEqual(undefined, muse_store:get(?O, <<"computer-state">>, muse_computer:lease_id(A))),
    ?assertEqual([], maps:get(<<"commands">>, muse_computer:snapshot(A))),
    %% B is untouched
    ?assertEqual(true, running(B)),
    ?assertMatch([#{<<"command">> := <<"echo b">>}], maps:get(<<"commands">>, muse_computer:snapshot(B))),
    %% deleting again is harmless; the scope gets a fresh computer
    ?assertEqual(ok, muse_computer:delete(A)),
    A = muse_computer:ensure(?O, <<"task:a">>),
    ?assertEqual(missing, running(A)).

network() ->
    A = muse_computer:ensure(?O, <<"task:a">>),
    %% default: bridge
    ?assertEqual(<<"enabled">>, maps:get(<<"network">>, muse_computer:snapshot(A))),
    {ok, _} = muse_computer:start(A),
    [Create] = [X || X = [<<"container">>, <<"create">> | _] <- calls()],
    ?assertEqual([<<"bridge">>], after_flag(<<"--network">>, Create)),
    ?assertEqual(true, running(A)),
    %% the setting changed: the bridge container is refused
    config(#{<<"COMPUTER_NETWORK">> => <<"none">>}),
    ?assertEqual(<<"disabled">>, maps:get(<<"network">>, muse_computer:snapshot(A))),
    ?assertMatch(#{<<"status">> := <<"error">>,
                   <<"message">> := <<"The existing computer container was created with a different "
                                      "COMPUTER_NETWORK setting", _/binary>>},
                 muse_computer:snapshot(A)),
    ?assertMatch({error, {409, _}}, muse_computer:execute(A, #{command => <<"ls">>})),
    %% delete and recreate on `none`
    ok = muse_computer:delete(A),
    A = muse_computer:ensure(?O, <<"task:a">>),
    {ok, #{<<"status">> := <<"running">>}} = muse_computer:start(A),
    Last = lists:last([X || X = [<<"container">>, <<"create">> | _] <- calls()]),
    ?assertEqual([<<"none">>], after_flag(<<"--network">>, Last)),
    %% a container on another network (host) is refused with the generic message
    #{container := CA} = muse_computer:identity(A),
    ets:insert(?T, {{c, CA}, (container(CA))#{network := <<"host">>}}),
    ?assertMatch(#{<<"message">> := <<"Computer ownership or isolation does not match", _/binary>>},
                 muse_computer:snapshot(A)).

overview() ->
    A = muse_computer:ensure(?O, <<"task:a">>),
    {ok, _} = muse_computer:start(A),
    #{container := CA} = muse_computer:identity(A),
    %% no pool process: the records' states at once, without stats
    ?assertMatch(#{running := [CA], max := 4, idle_minutes := 15, stats := Empty} when map_size(Empty) =:= 0,
                 muse_computer_pool:overview()),
    %% with the pool: the first call still answers at once and asks for a
    %% refresh, which fills in the docker stats in the background
    application:set_env(muse_integ, computer_pool_timer, false),
    {ok, Pool} = muse_computer_pool:start_link(),
    unlink(Pool),
    try
        ?assertMatch(#{running := [CA]}, muse_computer_pool:overview()),
        Stats = wait_stats(CA, 50),
        ?assertEqual(#{cpu => <<"0.25%">>, memory => <<"12MiB / 512MiB">>}, Stats),
        %% invalidate: back to the records until the next refresh
        ok = muse_computer_pool:invalidate(),
        ?assertMatch(#{running := [CA]}, muse_computer_pool:overview())
    after
        gen_server:stop(Pool)
    end.

wait_stats(_CA, 0) ->
    error(no_stats);
wait_stats(CA, N) ->
    case muse_computer_pool:overview() of
        #{stats := #{CA := S}} -> S;
        _ -> timer:sleep(20), wait_stats(CA, N - 1)
    end.

image_update() ->
    A = muse_computer:ensure(?O, <<"thread:th-img">>),
    #{container := C, volume := V} = muse_computer:identity(A),
    {ok, _} = muse_computer:start(A),
    ?assertMatch(#{image := <<"sha256:build-1">>}, container(C)),
    %% a new build while it runs: left alone, even when started again
    ets:insert(?T, {image_id, <<"sha256:build-2">>}),
    {ok, _} = muse_computer:start(A),
    ?assertMatch(#{running := true, image := <<"sha256:build-1">>}, container(C)),
    %% stopped, then started: the container (not the volume) is recreated
    {ok, _} = muse_computer:stop(A),
    {ok, #{<<"status">> := <<"running">>}} = muse_computer:start(A),
    ?assertMatch(#{running := true, image := <<"sha256:build-2">>, volume := V}, container(C)),
    ?assertNotEqual(undefined, volume(V)),
    Calls = calls(),
    ?assert(lists:member([<<"container">>, <<"rm">>, <<"--force">>, C], Calls)),
    ?assertNot(lists:member([<<"volume">>, <<"rm">>, V], Calls)),
    %% the same build: a plain start
    {ok, _} = muse_computer:stop(A),
    N = length([X || X = [<<"container">>, <<"create">> | _] <- calls()]),
    {ok, _} = muse_computer:start(A),
    ?assertEqual(N, length([X || X = [<<"container">>, <<"create">> | _] <- calls()])).
