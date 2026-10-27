-module(muse_browser_docker_tests).
-include_lib("eunit/include/eunit.hrl").

%% The per-user browser container (muse_browser_docker) and its idle stop
%% (muse_browser_pool) without Docker: `muse_docker:run/2` is replaced by a
%% small simulator that creates, starts, stops, lists, inspects and removes
%% containers and volumes from the exact argv sent, and answers `docker
%% exec ... ctl.py` with a scripted browserd reply.

-define(O, <<"owner@example.com">>).
-define(O2, <<"other@example.com">>).
-define(T, muse_browser_docker_sim).
-define(MIN, 60000).

docker_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [{"create args: hardened, labelled, no host mounts", fun create_args/0},
      {"first use creates volume and container, then runs the request", fun first_use/0},
      {"a running container is used as is", fun running/0},
      {"a stopped container is started; the request retried", fun stopped/0},
      {"an updated image recreates a stopped container on the same volume", fun outdated/0},
      {"another deployment's container is refused", fun foreign/0},
      {"weaker settings (e.g. no seccomp profile) recreate the container", fun weaker/0},
      {"browserd replies map to the muse_browser errors", fun replies/0},
      {"idle containers are stopped, their volume kept", fun idle_stop/0},
      {"activity is recorded for idle stop", fun touch/0},
      {"the live view shows the window's rectangle of the owner's container", fun vnc_args/0}]}.

setup() ->
    ok = muse_store:init(#{storage => ram}),
    config(#{}),
    Holder = spawn(fun() -> receive stop -> ok end end),
    ?T = ets:new(?T, [named_table, public, {heir, none}]),
    ets:give_away(?T, Holder, none),
    ets:insert(?T, {exec_hook, fun(_) -> default end}),
    meck:new(muse_docker, [passthrough]),
    meck:expect(muse_docker, run, fun sim/2),
    %% the activity table (no sweep timer; tests call sweep/0)
    application:set_env(muse_integ, browser_pool_timer, false),
    {ok, Pool} = muse_browser_pool:start_link(),
    unlink(Pool),
    {Holder, Pool}.

cleanup({Holder, Pool}) ->
    gen_server:stop(Pool),
    application:unset_env(muse_integ, browser_pool_timer),
    meck:unload(),
    muse_time:set_offset(0),
    Holder ! stop,
    persistent_term:erase({muse_config, config}),
    muse_store:stop().

config(Extra) ->
    {ok, C} = muse_config:from_env(maps:merge(#{<<"BROWSER_ENABLED">> => <<"true">>,
                                               <<"COMPUTER_DEPLOYMENT_ID">> => <<"browser-test">>},
                                             Extra)),
    muse_config:set(C).

%% Simulator

ok(Out) ->
    #{stdout => Out, stderr => <<>>, exit_code => 0, timed_out => false, interrupted => false,
      truncated => false}.

fail(Err) ->
    (ok(<<>>))#{exit_code := 1, stderr := Err}.

sim(Args, Opts) ->
    ets:insert(?T, {{call, erlang:unique_integer([monotonic, positive])}, Args}),
    reply(Args, Opts).

calls() ->
    [A || {_, A} <- lists:sort([{N, A} || {{call, N}, A} <- ets:tab2list(?T)])].

verbs() ->
    [case A of
         [<<"exec">> | _] -> exec;
         [<<"container">>, <<"ls">>, <<"--all">>, <<"--filter">>, <<"name=", _/binary>> | _] -> find;
         [<<"container">>, V | _] -> binary_to_atom(V);
         [<<"volume">>, V | _] -> binary_to_atom(<<"volume_", V/binary>>);
         [<<"image">>, <<"inspect">> | _] -> image_inspect
     end || A <- calls()].

reset_calls() ->
    ets:match_delete(?T, {{call, '_'}, '_'}).

container(Name) ->
    case ets:lookup(?T, {c, Name}) of
        [{_, C}] -> C;
        [] -> undefined
    end.

after_flag(Flag, [Flag, V | Rest]) -> [V | after_flag(Flag, Rest)];
after_flag(Flag, [_ | Rest]) -> after_flag(Flag, Rest);
after_flag(_, []) -> [].

first(Flag, Args, Default) ->
    case after_flag(Flag, Args) of
        [V | _] -> V;
        [] -> Default
    end.

labels(Args) ->
    maps:from_list([list_to_tuple(binary:split(L, <<"=">>)) || L <- after_flag(<<"--label">>, Args)]).

image_id() ->
    case ets:lookup(?T, image_id) of
        [{_, I}] -> I;
        [] -> <<"sha256:build-1">>
    end.

reply([<<"container">>, <<"ls">>, <<"--all">>, <<"--filter">>, <<"name=^/", Filter/binary>> | _], _) ->
    Name = binary:part(Filter, 0, byte_size(Filter) - 1),
    case container(Name) of
        undefined -> ok(<<>>);
        _ -> ok(<<"id-", Name/binary, "\n">>)
    end;
reply([<<"container">>, <<"ls">> | Rest], _) ->
    All = lists:member(<<"--all">>, Rest),
    ?assert(lists:member(<<"label=dev.openmuse.managed=browser-v1">>, Rest)),
    Lines = [[N, $\t, case R of true -> <<"running">>; false -> <<"exited">> end, $\t,
              maps:get(<<"dev.openmuse.owner">>, L, <<>>), $\n]
             || {{c, N}, #{running := R, labels := L}} <- ets:tab2list(?T), All orelse R],
    ok(iolist_to_binary(Lines));
reply([<<"container">>, <<"inspect">>, Name], _) ->
    case container(Name) of
        undefined -> fail(<<"Error: No such object">>);
        C -> ok(muse_json:encode([inspection(Name, C)]))
    end;
reply([<<"container">>, <<"create">> | Args], _) ->
    [Name] = after_flag(<<"--name">>, Args),
    [<<"type=volume,source=", Mount/binary>>] = after_flag(<<"--mount">>, Args),
    [Volume, <<"target=/data">>] = binary:split(Mount, <<",">>),
    ets:insert(?T, {{c, Name}, #{running => false, labels => labels(Args), volume => Volume,
                                 image => image_id(), args => Args, host => #{}}}),
    ok(<<"id-", Name/binary, "\n">>);
reply([<<"image">>, <<"inspect">>, <<"--format">>, <<"{{.Id}}">>, _Image], _) ->
    ok(<<(image_id())/binary, "\n">>);
reply([<<"container">>, <<"start">>, Name], _) ->
    set_running(Name, true);
reply([<<"container">>, <<"stop">>, <<"--time">>, _, Name], _) ->
    set_running(Name, false);
reply([<<"container">>, <<"rm">>, <<"--force">>, Name], _) ->
    ets:delete(?T, {c, Name}),
    ok(Name);
reply([<<"volume">>, <<"ls">>, <<"--filter">>, <<"name=^", Filter/binary>> | _], _) ->
    Name = binary:part(Filter, 0, byte_size(Filter) - 1),
    case ets:lookup(?T, {v, Name}) of
        [] -> ok(<<>>);
        _ -> ok(<<Name/binary, "\n">>)
    end;
reply([<<"volume">>, <<"create">> | Args], _) ->
    Name = lists:last(Args),
    ets:insert(?T, {{v, Name}, labels(Args)}),
    ok(Name);
reply([<<"volume">>, <<"inspect">>, Name], _) ->
    case ets:lookup(?T, {v, Name}) of
        [] -> fail(<<"Error: No such volume">>);
        [{_, L}] -> ok(muse_json:encode([#{<<"Name">> => Name, <<"Labels">> => L, <<"Driver">> => <<"local">>,
                                           <<"Options">> => null, <<"Scope">> => <<"local">>}]))
    end;
reply([<<"exec">>, <<"-i">>, <<"--user">>, <<"1000:1000">>, Name, <<"/usr/bin/python3">>, <<"-I">>,
       <<"/opt/muse-browser/ctl.py">>] = Args, #{input := Input}) ->
    case container(Name) of
        undefined -> fail(<<"Error response from daemon: No such container: ", Name/binary>>);
        #{running := false} -> fail(<<"Error response from daemon: container ", Name/binary, " is not running">>);
        _ ->
            [{exec_hook, Hook}] = ets:lookup(?T, exec_hook),
            case Hook(Args) of
                default ->
                    {ok, Req} = muse_json:decode(Input),
                    ok(muse_json:encode(#{<<"ok">> => true, <<"result">> => #{<<"echo">> => Req}}));
                R -> R
            end
    end.

set_running(Name, Running) ->
    case container(Name) of
        undefined -> fail(<<"Error: No such container">>);
        C -> ets:insert(?T, {{c, Name}, C#{running := Running}}), ok(Name)
    end.

%% What `docker container inspect` reports for a container created with
%% `Args` (the fields muse_browser_docker checks), plus test overrides.
inspection(Name, #{running := Running, labels := Labels, volume := Volume, args := Args, host := Over} = C) ->
    [Image | _] = lists:reverse(Args),
    {ok, Profile} = file:read_file(muse_browser_docker:seccomp_profile()),
    {ok, Json} = muse_json:decode(Profile),
    Host = #{<<"ReadonlyRootfs">> => lists:member(<<"--read-only">>, Args), <<"Privileged">> => false,
             <<"CapDrop">> => after_flag(<<"--cap-drop">>, Args), <<"CapAdd">> => null,
             <<"SecurityOpt">> => [case O of
                                       <<"seccomp=", _/binary>> -> <<"seccomp=", (muse_json:encode(Json))/binary>>;
                                       _ -> O
                                   end || O <- after_flag(<<"--security-opt">>, Args)],
             <<"NetworkMode">> => first(<<"--network">>, Args, <<"bridge">>),
             <<"Memory">> => 2147483648, <<"MemorySwap">> => 2147483648, <<"NanoCpus">> => 2000000000,
             <<"PidsLimit">> => binary_to_integer(first(<<"--pids-limit">>, Args, <<"0">>)),
             <<"ShmSize">> => binary_to_integer(first(<<"--shm-size">>, Args, <<"67108864">>)),
             <<"Init">> => lists:member(<<"--init">>, Args),
             <<"Binds">> => null, <<"Devices">> => [], <<"DeviceRequests">> => null,
             <<"PortBindings">> => #{}, <<"PidMode">> => <<>>,
             <<"IpcMode">> => first(<<"--ipc">>, Args, <<"private">>),
             <<"Tmpfs">> => maps:from_list([list_to_tuple(binary:split(T, <<":">>))
                                            || T <- after_flag(<<"--tmpfs">>, Args)]),
             <<"RestartPolicy">> => #{<<"Name">> => <<"no">>, <<"MaximumRetryCount">> => 0}},
    #{<<"Id">> => <<"id-", Name/binary>>,
      <<"Name">> => <<"/", Name/binary>>,
      <<"Image">> => maps:get(image, C),
      <<"Config">> => #{<<"Image">> => Image,
                        <<"User">> => first(<<"--user">>, Args, <<>>),
                        <<"Labels">> => Labels,
                        <<"Env">> => after_flag(<<"--env">>, Args) ++ [<<"PATH=/usr/bin:/bin">>, <<"HOME=/data/home">>],
                        <<"Entrypoint">> => after_flag(<<"--entrypoint">>, Args),
                        <<"Cmd">> => null,
                        <<"WorkingDir">> => <<"/data">>},
      <<"HostConfig">> => maps:merge(Host, Over),
      <<"Mounts">> => [#{<<"Type">> => <<"volume">>, <<"Name">> => Volume,
                         <<"Destination">> => <<"/data">>, <<"RW">> => true}],
      <<"State">> => #{<<"Running">> => Running}}.

name(Owner) -> maps:get(container, muse_browser_docker:identity(Owner)).
vol(Owner) -> maps:get(volume, muse_browser_docker:identity(Owner)).

echo() -> #{<<"op">> => <<"health">>}.

%% Cases

create_args() ->
    Id = muse_browser_docker:identity(?O),
    #{container := C, volume := V} = Id,
    ?assertMatch(<<"openmuse-", _/binary>>, C),
    ?assertNotEqual(nomatch, binary:match(C, <<"-browser">>)),
    ?assertNotEqual(nomatch, binary:match(V, <<"-browser-profile">>)),
    Args = muse_browser_docker:create_args(Id, <<"muse-browser:local">>),
    Has = fun(Flag, Value) -> lists:member(Value, after_flag(Flag, Args)) end,
    ?assert(lists:member(<<"--read-only">>, Args)),
    ?assert(lists:member(<<"--init">>, Args)),
    ?assertEqual([<<"ALL">>], after_flag(<<"--cap-drop">>, Args)),
    ?assertEqual([], after_flag(<<"--cap-add">>, Args)),
    ?assertEqual([], after_flag(<<"--privileged">>, Args) ++ after_flag(<<"--volume">>, Args)
                     ++ after_flag(<<"-v">>, Args) ++ after_flag(<<"--publish">>, Args)
                     ++ after_flag(<<"-p">>, Args) ++ after_flag(<<"--device">>, Args)),
    ?assert(Has(<<"--security-opt">>, <<"no-new-privileges">>)),
    [Seccomp] = [S || <<"seccomp=", S/binary>> <- after_flag(<<"--security-opt">>, Args)],
    ?assertNotEqual(<<"unconfined">>, Seccomp),
    ?assert(filelib:is_regular(Seccomp)),
    ?assert(Has(<<"--user">>, <<"1000:1000">>)),
    ?assert(Has(<<"--network">>, <<"bridge">>)),
    ?assert(Has(<<"--ipc">>, <<"private">>)),
    ?assert(Has(<<"--memory">>, <<"2g">>)),
    ?assert(Has(<<"--memory-swap">>, <<"2g">>)),
    ?assert(Has(<<"--cpus">>, <<"2">>)),
    ?assert(Has(<<"--pids-limit">>, <<"1024">>)),
    ?assert(Has(<<"--restart">>, <<"no">>)),
    ?assert(Has(<<"--tmpfs">>, <<"/tmp:rw,nosuid,nodev,noexec,size=268435456,mode=1777">>)),
    ?assertEqual([<<"type=volume,source=", V/binary, ",target=/data">>], after_flag(<<"--mount">>, Args)),
    ?assert(Has(<<"--env">>, <<"TZ=Asia/Shanghai">>)),
    ?assert(Has(<<"--env">>, <<"LANG=zh_CN.UTF-8">>)),
    ?assert(Has(<<"--label">>, <<"dev.openmuse.managed=browser-v1">>)),
    ?assertEqual([<<"/opt/muse-browser/init.sh">>], after_flag(<<"--entrypoint">>, Args)),
    ?assertEqual(<<"muse-browser:local">>, lists:last(Args)),
    %% the Chrome sandbox needs user namespaces; the profile allows only that
    {ok, Profile} = muse_json:decode(element(2, file:read_file(Seccomp))),
    ?assertEqual(<<"SCMP_ACT_ERRNO">>, maps:get(<<"defaultAction">>, Profile)),
    [Added] = [S || S = #{<<"names">> := N} <- maps:get(<<"syscalls">>, Profile),
                    N =:= [<<"clone">>, <<"unshare">>, <<"chroot">>]],
    ?assertEqual(<<"SCMP_ACT_ALLOW">>, maps:get(<<"action">>, Added)),
    %% BROWSER_NETWORK
    config(#{<<"BROWSER_NETWORK">> => <<"muse-egress">>}),
    ?assertEqual([<<"muse-egress">>], after_flag(<<"--network">>, muse_browser_docker:create_args(Id, <<"i">>))).

first_use() ->
    {ok, #{<<"echo">> := #{<<"op">> := <<"health">>}}} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertEqual([find, volume_ls, volume_create, volume_inspect, create, start, exec], verbs()),
    ?assertMatch(#{running := true}, container(name(?O))),
    ?assertEqual(muse_browser_docker:image(), lists:last(maps:get(args, container(name(?O))))),
    %% the exec runs ctl.py as user 1000 with the request on stdin
    [<<"exec">>, <<"-i">>, <<"--user">>, <<"1000:1000">>, N | _] = lists:last(calls()),
    ?assertEqual(name(?O), N),
    %% one container per owner
    {ok, _} = muse_browser_docker:call(?O2, echo(), 1000),
    ?assertNotEqual(name(?O), name(?O2)),
    ?assertMatch(#{running := true}, container(name(?O2))).

running() ->
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    reset_calls(),
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertEqual([exec], verbs()).

stopped() ->
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ok = muse_browser_docker:stop(?O),
    ?assertEqual(stopped, muse_browser_docker:state(?O)),
    reset_calls(),
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertEqual([exec, find, inspect, image_inspect, start, exec], verbs()),
    ?assertEqual(running, muse_browser_docker:state(?O)).

outdated() ->
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ok = muse_browser_docker:stop(?O),
    ets:insert(?T, {image_id, <<"sha256:build-2">>}),
    reset_calls(),
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertEqual([exec, find, inspect, image_inspect, rm, volume_ls, volume_inspect, create, start, exec], verbs()),
    ?assertMatch(#{image := <<"sha256:build-2">>, running := true}, container(name(?O))),
    ?assertEqual([{{v, vol(?O)}, labels_of(?O)}], ets:lookup(?T, {v, vol(?O)})),
    %% a running container is not recreated for a new image
    ets:insert(?T, {image_id, <<"sha256:build-3">>}),
    reset_calls(),
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertEqual([exec], verbs()).

labels_of(Owner) ->
    maps:from_list(maps:get(labels, muse_browser_docker:identity(Owner))).

foreign() ->
    Name = name(?O),
    Args = [<<"container">>, <<"create">>, <<"--name">>, Name, <<"--label">>, <<"dev.openmuse.owner=someone">>,
            <<"--mount">>, <<"type=volume,source=x,target=/data">>, <<"--network">>, <<"bridge">>, <<"img">>],
    _ = reply(Args, #{}),
    ?assertEqual({error, {409, <<"Browser container ownership does not match this deployment; refusing to attach">>}},
                 muse_browser_docker:call(?O, echo(), 1000)),
    ?assertMatch(#{running := false}, container(Name)).

weaker() ->
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    Name = name(?O),
    C = container(Name),
    %% the same container but with Docker's default seccomp (or unconfined)
    ets:insert(?T, {{c, Name}, C#{running := false, host := #{<<"SecurityOpt">> => [<<"no-new-privileges">>]}}}),
    reset_calls(),
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertEqual([exec, find, inspect, rm, volume_ls, volume_inspect, create, start, exec], verbs()),
    ?assertMatch(#{host := H} when map_size(H) =:= 0, container(Name)),
    %% even a running one (an upgrade changed the settings): checked by
    %% the first request after the node starts
    ets:insert(?T, {{c, Name}, (container(Name))#{host := #{<<"PidsLimit">> => 4096}}}),
    ets:match_delete(muse_browser_activity, {{verified, '_'}, '_'}),
    reset_calls(),
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertEqual([find, inspect, rm, volume_ls, volume_inspect, create, start, exec], verbs()).

replies() ->
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    Reply = fun(Json) -> ets:insert(?T, {exec_hook, fun(_) -> ok(Json) end}),
                         muse_browser_docker:call(?O, echo(), 1000) end,
    ?assertEqual({ok, #{<<"url">> => <<"https://example.com/">>}},
                 Reply(<<"{\"ok\":true,\"result\":{\"url\":\"https://example.com/\"}}\n">>)),
    ?assertEqual({error, {502, <<"Open this browser session before using its console.">>}},
                 Reply(<<"{\"ok\":false,\"status\":409,\"code\":\"SESSION_CLOSED\","
                         "\"message\":\"Open this browser session before using its console.\"}">>)),
    ?assertEqual({error, {502, <<"Only public HTTP(S) destinations on ports 80 and 443 are allowed.">>}},
                 Reply(<<"{\"ok\":false,\"status\":400,\"code\":\"BLOCKED_URL\","
                         "\"message\":\"Only public HTTP(S) destinations on ports 80 and 443 are allowed.\"}">>)),
    ?assertEqual({error, {503, <<"The browser is still starting. Try again in a moment.">>}},
                 Reply(<<"{\"ok\":false,\"status\":503,\"code\":\"BROWSER_STARTING\","
                         "\"message\":\"The browser is still starting. Try again in a moment.\"}">>)),
    ?assertEqual({error, {502, <<"Browser request failed">>}}, Reply(<<"garbage">>)),
    ets:insert(?T, {exec_hook, fun(_) -> (ok(<<>>))#{timed_out := true, exit_code := null} end}),
    ?assertEqual({error, {503, <<"The browser did not answer in time. Try again.">>}},
                 muse_browser_docker:call(?O, echo(), 1000)),
    ets:insert(?T, {exec_hook, fun(_) -> fail(<<"permission denied while trying to connect to the Docker daemon">>) end}),
    ?assertMatch({error, {503, <<"The browser container could not be started.", _/binary>>}},
                 muse_browser_docker:call(?O, echo(), 1000)).

idle_stop() ->
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    {ok, _} = muse_browser_docker:call(?O2, echo(), 1000),
    %% a running browser container nobody in this store owns
    Stray = <<(name(?O))/binary, "-stray">>,
    _ = reply([<<"container">>, <<"create">>, <<"--name">>, Stray, <<"--label">>, <<"dev.openmuse.owner=ffff">>,
               <<"--mount">>, <<"type=volume,source=s,target=/data">>, <<"--network">>, <<"bridge">>, <<"img">>], #{}),
    _ = set_running(Stray, true),
    muse_browser_pool:sweep(),
    ?assertMatch(#{running := true}, container(name(?O))),
    ?assertMatch(#{running := true}, container(name(?O2))),
    ?assertMatch(#{running := false}, container(Stray)),
    %% 31 minutes later ?O2 used it again
    muse_time:set_offset(31 * ?MIN),
    muse_browser_docker:touch(?O2),
    muse_browser_pool:sweep(),
    ?assertMatch(#{running := false}, container(name(?O))),
    ?assertMatch(#{running := true}, container(name(?O2))),
    ?assertMatch([_], ets:lookup(?T, {v, vol(?O)})),
    %% BROWSER_IDLE_MINUTES
    config(#{<<"BROWSER_IDLE_MINUTES">> => <<"90">>}),
    muse_time:set_offset(100 * ?MIN),
    muse_browser_pool:sweep(),
    ?assertMatch(#{running := true}, container(name(?O2))),
    muse_time:set_offset(200 * ?MIN),
    muse_browser_pool:sweep(),
    ?assertMatch(#{running := false}, container(name(?O2))),
    %% the next use starts it again
    {ok, _} = muse_browser_docker:call(?O, echo(), 1000),
    ?assertMatch(#{running := true}, container(name(?O))),
    %% disabled: the sweep leaves Docker alone
    config(#{<<"BROWSER_ENABLED">> => <<"false">>}),
    reset_calls(),
    muse_browser_pool:sweep(),
    ?assertEqual([], calls()).

touch() ->
    ?assertEqual(0, muse_browser_docker:last_used(?O)),
    ok = muse_browser_docker:touch(?O),
    Used = muse_browser_docker:last_used(?O),
    ?assert(abs(muse_time:now_ms() - Used) < 5000),
    ?assertMatch(#{<<"lastUsedAt">> := _}, muse_store:get(?O, <<"browser-hosts">>, <<"default">>)).

%% The console's live view: the owner's container, the window's rectangle.
vnc_args() ->
    #{container := C} = muse_browser_docker:identity(?O),
    Sid = muse_ids:uuid(),
    Rect = #{<<"left">> => 0, <<"top">> => 10, <<"width">> => 1280, <<"height">> => 890},
    ?assertEqual(muse_docker:vnc_args(C, #{view_only => false, clip => <<"1280x890+0+10">>}),
                 muse_browser_docker:vnc_args(?O, Sid, Rect)),
    %% a session placed in a desktop computer: that computer's container
    Cid = <<"0123456789abcdef">>,
    _ = muse_store:put(?O, <<"browser-placement">>, #{<<"id">> => Sid, <<"host">> => <<"computer:", Cid/binary>>}),
    #{container := Computer} = muse_computer:identity(muse_computer:ref_of(?O, Cid)),
    ?assertEqual(muse_docker:vnc_args(Computer, #{view_only => false, clip => <<"1280x890+0+10">>}),
                 muse_browser_docker:vnc_args(?O, Sid, Rect)).
