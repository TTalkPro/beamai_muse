%% @doc The per-user browser container (not in OpenMuse, whose browser is a
%% Playwright worker; designs/04-integrations.md §4).
%%
%% Each owner has one container of the browser image (BROWSER_IMAGE,
%% `make browser-image`): a real Google Chrome on a virtual display with
%% the bridge extension, browserd and the egress proxy (browser/). Its
%% Chrome profile (cookies, sign-ins), downloads and per-session files live
%% on the owner's volume, so logins are shared by all of that owner's
%% conversations and tasks and survive container restarts.
%%
%% - Transport (`call/3`, the muse_browser transport): one request per
%%   `docker exec -i <container> python3 -I /opt/muse-browser/ctl.py`, JSON
%%   on stdin, one JSON reply line on stdout. ctl.py talks to browserd over
%%   a unix socket in the container's /tmp; nothing is published or
%%   mounted from the host.
%% - Lifecycle: started on first use (`call/3` starts it when the exec
%%   finds no running container, then retries once). Idle containers are
%%   stopped by muse_browser_pool after BROWSER_IDLE_MINUTES; the volume
%%   is kept. A stopped container created from an older build of the image
%%   (`docker image inspect` id differs, as muse_computer_docker) or with
%%   other settings is removed and created again on the same volume;
%%   a running one with other settings (an upgrade) too.
%% - Ownership: a container or volume with the expected name but not this
%%   deployment's owner labels is refused (409).
%% - Hardening (`create_args/2`): user 1000, read-only root, tmpfs /tmp,
%%   `--cap-drop ALL` and no capability added, no-new-privileges, the
%%   seccomp profile priv/browser-seccomp.json (Docker's default plus
%%   clone/unshare/chroot for Chrome's user-namespace sandbox, which stays
%%   on), memory/CPU/pids limits, `--init`, private IPC, no host mounts,
%%   no published ports, BROWSER_NETWORK (default bridge).
%%
%% Browser containers are not computers: they carry the label
%% `dev.openmuse.managed=browser-v1`, so the computer pool neither counts
%% them against COMPUTER_MAX_RUNNING nor adopts them.
-module(muse_browser_docker).
-behaviour(muse_browser).

-export([call/3, identity/1, create_args/2, exec_args/1, image/0, network/0,
         ensure_running/1, stop/1, remove/1, containers/0, state/1,
         seccomp_profile/0, touch/1, last_used/1, ps_args/1]).

-define(ERR(Status, Msg), throw({?MODULE, Status, Msg})).
-define(MANAGED, <<"browser-v1">>).
-define(ENTRYPOINT, <<"/opt/muse-browser/init.sh">>).
-define(MEMORY, <<"2g">>).
-define(MEMORY_BYTES, 2147483648).
-define(CPUS, <<"2">>).
-define(NANO_CPUS, 2000000000).
-define(PIDS, <<"1024">>).
-define(PIDS_N, 1024).
-define(SHM, <<"536870912">>).
-define(SHM_N, 536870912).
-define(TMPFS, <<"rw,nosuid,nodev,noexec,size=268435456,mode=1777">>).
-define(ENV, [<<"TZ=Asia/Shanghai">>, <<"LANG=zh_CN.UTF-8">>]).
-define(ALLOWED_ENV, [<<"PATH">>, <<"HOME">>, <<"LANG">>, <<"LANGUAGE">>, <<"TZ">>, <<"DISPLAY">>,
                      <<"DEBIAN_FRONTEND">>]).
-define(TOUCH_MS, 30000).
-define(ACTIVITY, muse_browser_activity).
-define(UNAVAILABLE, <<"The browser container could not be started. Check that Docker is running and the "
                       "browser image is built (make browser-image).">>).

-type identity() :: #{container := binary(), volume := binary(), owner_hash := binary(),
                      labels := [{binary(), binary()}]}.

%% @doc Send one request to the owner's browser, starting its container
%% when needed. Replies `{ok, Result}`; a browser error is `{error, {502 or
%% 503, Message}}`; Docker failures are 503.
-spec call(binary(), map(), pos_integer()) -> {ok, term()} | {error, {pos_integer(), binary()}}.
call(Owner, Request, Timeout) ->
    guard(fun() ->
                  touch(Owner),
                  #{container := Container} = identity(Owner),
                  Input = muse_json:encode(Request),
                  %% the first request of this node checks the container
                  %% (ownership, settings, image); later ones just exec
                  _ = verified(Owner) orelse ensure_running(Owner),
                  case exec(Container, Input, Timeout) of
                      not_running ->
                          ensure_running(Owner),
                          case exec(Container, Input, Timeout) of
                              not_running -> ?ERR(503, ?UNAVAILABLE);
                              Reply -> Reply
                          end;
                      Reply ->
                          Reply
                  end
          end).

verified(Owner) ->
    ets:whereis(?ACTIVITY) =/= undefined andalso ets:member(?ACTIVITY, {verified, Owner}).

verify(Owner) ->
    _ = ets:whereis(?ACTIVITY) =/= undefined andalso ets:insert(?ACTIVITY, {{verified, Owner}, true}),
    ok.

%% @doc Container, volume and labels of the owner's browser.
-spec identity(binary()) -> identity().
identity(Owner) ->
    Deployment = muse_computer:deployment(),
    Hash = binary:part(muse_ids:sha256hex(Owner), 0, 24),
    Base = <<"openmuse-", Deployment/binary, "-", Hash/binary>>,
    #{container => <<Base/binary, "-browser">>,
      volume => <<Base/binary, "-browser-profile">>,
      owner_hash => Hash,
      labels => [{<<"dev.openmuse.managed">>, ?MANAGED},
                 {<<"dev.openmuse.deployment">>, Deployment},
                 {<<"dev.openmuse.owner">>, Hash}]}.

%% @doc `docker container create` of an owner's browser.
-spec create_args(identity(), binary()) -> [binary()].
create_args(#{container := Container, volume := Volume, labels := Labels}, Image) ->
    [<<"container">>, <<"create">>, <<"--pull">>, <<"never">>, <<"--name">>, Container]
    ++ lists:append([[<<"--label">>, <<K/binary, "=", V/binary>>] || {K, V} <- Labels]) ++
    [<<"--user">>, <<"1000:1000">>, <<"--workdir">>, <<"/data">>, <<"--read-only">>,
     <<"--cap-drop">>, <<"ALL">>,
     <<"--security-opt">>, <<"no-new-privileges">>,
     <<"--security-opt">>, <<"seccomp=", (seccomp_profile())/binary>>,
     <<"--network">>, network(), <<"--ipc">>, <<"private">>, <<"--shm-size">>, ?SHM,
     <<"--memory">>, ?MEMORY, <<"--memory-swap">>, ?MEMORY, <<"--cpus">>, ?CPUS,
     <<"--pids-limit">>, ?PIDS, <<"--restart">>, <<"no">>, <<"--init">>,
     <<"--tmpfs">>, <<"/tmp:", ?TMPFS/binary>>,
     <<"--mount">>, <<"type=volume,source=", Volume/binary, ",target=/data">>]
    ++ lists:append([[<<"--env">>, E] || E <- ?ENV]) ++
    [<<"--entrypoint">>, ?ENTRYPOINT, Image].

%% @doc The request runner: browser/ctl.py reads the request on stdin.
-spec exec_args(binary()) -> [binary()].
exec_args(Container) ->
    [<<"exec">>, <<"-i">>, <<"--user">>, <<"1000:1000">>, Container,
     <<"/usr/bin/python3">>, <<"-I">>, <<"/opt/muse-browser/ctl.py">>].

%% @doc The browser containers of this deployment (`docker container ls`).
-spec ps_args(running | all) -> [binary()].
ps_args(Which) ->
    [<<"container">>, <<"ls">>] ++ [<<"--all">> || Which =:= all] ++
    [<<"--filter">>, <<"label=dev.openmuse.managed=", ?MANAGED/binary>>,
     <<"--filter">>, <<"label=dev.openmuse.deployment=", (muse_computer:deployment())/binary>>,
     <<"--format">>, <<"{{.Names}}\t{{.State}}\t{{.Label \"dev.openmuse.owner\"}}">>].

%% @doc BROWSER_IMAGE (validated by muse_config).
-spec image() -> binary().
image() ->
    muse_config:get(browser_image, <<"muse-browser:local">>).

%% @doc BROWSER_NETWORK (default bridge).
-spec network() -> binary().
network() ->
    muse_config:get(browser_network, <<"bridge">>).

%% @doc The seccomp profile file shipped in priv (absolute path; the Docker
%% CLI reads it and sends its content).
-spec seccomp_profile() -> binary().
seccomp_profile() ->
    unicode:characters_to_binary(filename:join(code:priv_dir(muse_integ), "browser-seccomp.json")).

%% @doc Start the owner's container unless it is running (serialised per
%% owner). Creates container and volume when missing.
-spec ensure_running(binary()) -> ok.
ensure_running(Owner) ->
    Id = identity(Owner),
    global:trans({?MODULE, Owner},
                 fun() ->
                         case inspect(Id) of
                             undefined ->
                                 create_and_start(Id);
                             Info ->
                                 Running = running(Info),
                                 case safe(Info, Id) of
                                     true when Running -> ok;
                                     true ->
                                         case outdated(Info) of
                                             true ->
                                                 logger:notice("browser ~s: image updated, recreating its "
                                                               "container (the profile volume is kept)",
                                                               [maps:get(container, Id)]),
                                                 recreate(Id);
                                             false ->
                                                 _ = checked(muse_docker:start_args(maps:get(container, Id))),
                                                 ok
                                         end;
                                     false ->
                                         logger:notice("browser ~s: settings changed, recreating its "
                                                       "container (the profile volume is kept)",
                                                       [maps:get(container, Id)]),
                                         recreate(Id)
                                 end
                         end
                 end, [node()], infinity),
    verify(Owner).

%% @doc Stop the owner's container (its volume is kept).
-spec stop(binary()) -> ok | {error, {pos_integer(), binary()}}.
stop(Owner) ->
    guard(fun() ->
                  #{container := Container} = identity(Owner),
                  _ = checked(muse_docker:stop_args(Container)),
                  ok
          end).

%% @doc Remove the owner's container and profile volume.
-spec remove(binary()) -> ok | {error, {pos_integer(), binary()}}.
remove(Owner) ->
    guard(fun() ->
                  #{container := Container, volume := Volume} = identity(Owner),
                  case string:trim(checked(muse_docker:find_args(Container))) of
                      <<>> -> ok;
                      _ -> _ = checked(muse_docker:rm_args(Container)), ok
                  end,
                  case string:trim(checked(muse_docker:volume_ls_args(Volume))) of
                      <<>> -> ok;
                      _ -> _ = checked(muse_docker:volume_rm_args(Volume)), ok
                  end
          end).

%% @doc `running | stopped | missing` of the owner's container.
-spec state(binary()) -> running | stopped | missing | {error, {pos_integer(), binary()}}.
state(Owner) ->
    guard(fun() ->
                  case inspect_raw(maps:get(container, identity(Owner))) of
                      undefined -> missing;
                      Info -> case running(Info) of true -> running; false -> stopped end
                  end
          end).

%% @doc This deployment's browser containers: `{Name, State, OwnerHash}`.
-spec containers() -> {ok, [{binary(), binary(), binary()}]} | {error, {pos_integer(), binary()}}.
containers() ->
    guard(fun() ->
                  Out = checked(ps_args(all)),
                  {ok, [list_to_tuple(pad(binary:split(L, <<"\t">>, [global]), 3))
                        || L <- binary:split(Out, <<"\n">>, [global, trim_all]), string:trim(L) =/= <<>>]}
          end).

%% @doc Record browser activity of `Owner` (idle stop counts from here):
%% in memory at once, in the store at most every 30 s.
-spec touch(binary()) -> ok.
touch(Owner) ->
    Now = muse_time:now_ms(),
    Write = case ets:whereis(?ACTIVITY) of
                undefined -> true;
                _ ->
                    Last = case ets:lookup(?ACTIVITY, {stored, Owner}) of
                               [{_, At}] -> At;
                               [] -> 0
                           end,
                    ets:insert(?ACTIVITY, {Owner, Now}),
                    Now - Last >= ?TOUCH_MS andalso ets:insert(?ACTIVITY, {{stored, Owner}, Now})
            end,
    _ = Write andalso muse_store:put(Owner, <<"browser-hosts">>,
                                     #{<<"id">> => <<"default">>, <<"lastUsedAt">> => muse_time:now_iso()}),
    ok.

%% @doc When `Owner` last used the browser (ms), 0 when unknown.
-spec last_used(binary()) -> non_neg_integer().
last_used(Owner) ->
    Memory = case ets:whereis(?ACTIVITY) =/= undefined andalso ets:lookup(?ACTIVITY, Owner) of
                 [{_, At}] -> At;
                 _ -> 0
             end,
    Stored = case muse_store:get(Owner, <<"browser-hosts">>, <<"default">>) of
                 #{<<"lastUsedAt">> := Iso} ->
                     case muse_time:parse(Iso) of
                         nan -> 0;
                         Ms -> Ms
                     end;
                 _ -> 0
             end,
    max(Memory, Stored).

%% Internal

guard(Fun) ->
    try
        Fun()
    catch
        throw:{?MODULE, Status, Msg} -> {error, {Status, Msg}}
    end.

pad(L, N) when length(L) >= N -> lists:sublist(L, N);
pad(L, N) -> L ++ lists:duplicate(N - length(L), <<>>).

%% One ctl request. `not_running` when there is no running container.
exec(Container, Input, Timeout) ->
    Result = muse_docker:run(exec_args(Container),
                             #{timeout => Timeout + 10000, input => Input, max_output => 15 * 1048576}),
    case Result of
        #{timed_out := true} ->
            {error, {503, <<"The browser did not answer in time. Try again.">>}};
        #{exit_code := Code, stdout := Out, stderr := Err, truncated := false}
          when Code =:= 0; Code =:= 3 ->
            case muse_json:decode(string:trim(Out)) of
                {ok, #{<<"ok">> := true} = Reply} ->
                    {ok, maps:get(<<"result">>, Reply, null)};
                {ok, #{<<"ok">> := false, <<"message">> := Msg} = Reply} when is_binary(Msg) ->
                    {error, {status(maps:get(<<"status">>, Reply, 502)), Msg}};
                _ ->
                    logger:warning("browser: unreadable reply: ~ts", [binary:part(<<Out/binary, Err/binary>>, 0,
                                                                             min(300, byte_size(Out) + byte_size(Err)))]),
                    {error, {502, <<"Browser request failed">>}}
            end;
        #{stderr := Err, stdout := Out} ->
            Text = <<Out/binary, Err/binary>>,
            case binary:match(Text, [<<"is not running">>, <<"No such container">>,
                                     <<"is restarting">>, <<"is paused">>]) of
                nomatch ->
                    case binary:match(Text, <<"OCI runtime exec failed">>) of
                        nomatch ->
                            logger:warning("browser: docker exec failed: ~ts", [binary:part(Text, 0, min(300, byte_size(Text)))]),
                            {error, {503, ?UNAVAILABLE}};
                        _ -> not_running
                    end;
                _ -> not_running
            end
    end.

%% Browser errors become 502 like the worker's; "not ready / restarted /
%% timed out" stay 503.
status(S) when S =:= 503; S =:= 504 -> 503;
status(_) -> 502.

checked(Args) ->
    case muse_docker:run(Args, #{timeout => muse_docker:control_timeout()}) of
        #{timed_out := true} ->
            ?ERR(503, <<"Docker did not respond within 10 seconds. Check the Docker engine.">>);
        #{interrupted := false, exit_code := 0, truncated := false, stdout := Out} ->
            Out;
        #{stderr := Err} ->
            logger:warning("browser: docker ~ts failed: ~ts", [hd(Args), binary:part(Err, 0, min(300, byte_size(Err)))]),
            ?ERR(503, ?UNAVAILABLE)
    end.

inspect_raw(Container) ->
    case string:trim(checked(muse_docker:find_args(Container))) of
        <<>> -> undefined;
        _ ->
            case muse_json:decode(checked(muse_docker:inspect_args(Container))) of
                {ok, [Info]} when is_map(Info) -> Info;
                _ -> ?ERR(409, <<"Browser container inspection failed; refusing to attach">>)
            end
    end.

%% The container, refused when it is not this owner's (labels, name).
inspect(#{container := Container, labels := Labels}) ->
    case inspect_raw(Container) of
        undefined -> undefined;
        Info ->
            case owned(Info, Container, Labels) of
                true -> Info;
                false -> ?ERR(409, <<"Browser container ownership does not match this deployment; "
                                     "refusing to attach">>)
            end
    end.

running(#{<<"State">> := #{<<"Running">> := true}}) -> true;
running(_) -> false.

create_and_start(#{container := Container, volume := Volume, labels := Labels} = Id) ->
    case string:trim(checked(muse_docker:volume_ls_args(Volume))) of
        <<>> -> _ = checked(muse_docker:volume_create_args(Volume, Labels)), ok;
        _ -> ok
    end,
    verify_volume(Id),
    _ = checked(create_args(Id, image())),
    _ = checked(muse_docker:start_args(Container)),
    ok.

recreate(#{container := Container} = Id) ->
    _ = checked(muse_docker:rm_args(Container)),
    create_and_start(Id).

%% Whether the container was created from an older build of the image.
outdated(#{<<"Image">> := Have}) when is_binary(Have), Have =/= <<>> ->
    case muse_docker:run(muse_docker:image_id_args(image()), #{timeout => muse_docker:control_timeout()}) of
        #{exit_code := 0, timed_out := false, interrupted := false, truncated := false, stdout := Out} ->
            case string:trim(Out) of
                <<"sha256:", _/binary>> = Want -> Want =/= Have;
                _ -> false
            end;
        _ ->
            false
    end;
outdated(_) ->
    false.

owned(#{<<"Name">> := Name, <<"Config">> := #{<<"Labels">> := Actual}}, Container, Labels) ->
    Name =:= <<"/", Container/binary>> andalso labels_match(Labels, Actual);
owned(_, _, _) ->
    false.

labels_match(Expected, Actual) when is_map(Actual) ->
    lists:all(fun({K, V}) -> maps:get(K, Actual, undefined) =:= V end, Expected);
labels_match(_, _) ->
    false.

%% The container has exactly the settings create_args/2 gives it.
safe(Info, #{volume := Volume}) ->
    try
        #{<<"Config">> := Cfg, <<"HostConfig">> := H, <<"Mounts">> := Mounts} = Info,
        G = fun(K) -> maps:get(K, H, null) end,
        maps:get(<<"Image">>, Cfg) =:= image()
            andalso maps:get(<<"User">>, Cfg) =:= <<"1000:1000">>
            andalso maps:get(<<"Entrypoint">>, Cfg) =:= [?ENTRYPOINT]
            andalso list(maps:get(<<"Cmd">>, Cfg, null)) =:= []
            andalso lists:all(fun(E) -> lists:member(hd(binary:split(E, <<"=">>)), ?ALLOWED_ENV) end,
                              list(maps:get(<<"Env">>, Cfg, null)))
            andalso G(<<"ReadonlyRootfs">>) =:= true
            andalso G(<<"Privileged">>) =:= false
            andalso list(G(<<"CapDrop">>)) =:= [<<"ALL">>]
            andalso list(G(<<"CapAdd">>)) =:= []
            andalso security_opts(list(G(<<"SecurityOpt">>)))
            andalso G(<<"NetworkMode">>) =:= network()
            andalso G(<<"Memory">>) =:= ?MEMORY_BYTES
            andalso G(<<"MemorySwap">>) =:= ?MEMORY_BYTES
            andalso G(<<"NanoCpus">>) =:= ?NANO_CPUS
            andalso G(<<"PidsLimit">>) =:= ?PIDS_N
            andalso G(<<"ShmSize">>) =:= ?SHM_N
            andalso G(<<"Init">>) =:= true
            andalso list(G(<<"Binds">>)) =:= []
            andalso list(G(<<"Devices">>)) =:= []
            andalso list(G(<<"DeviceRequests">>)) =:= []
            andalso map(G(<<"PortBindings">>)) =:= #{}
            andalso G(<<"PidMode">>) =:= <<>>
            andalso G(<<"IpcMode">>) =:= <<"private">>
            andalso maps:get(<<"Name">>, map(G(<<"RestartPolicy">>)), <<>>) =:= <<"no">>
            andalso map(G(<<"Tmpfs">>)) =:= #{<<"/tmp">> => ?TMPFS}
            andalso mounts_safe(Mounts, Volume)
    catch
        _:_ -> false
    end.

%% no-new-privileges and our seccomp profile (the CLI stores its content).
security_opts(Opts) ->
    case lists:sort(Opts) of
        [<<"no-new-privileges">>, <<"seccomp=", Profile/binary>>] ->
            {ok, Want} = file:read_file(seccomp_profile()),
            muse_json:decode(Profile) =:= muse_json:decode(Want);
        _ ->
            false
    end.

mounts_safe([#{<<"Type">> := <<"volume">>, <<"Destination">> := <<"/data">>, <<"RW">> := true} = M], Volume) ->
    maps:get(<<"Name">>, M, undefined) =:= Volume;
mounts_safe(_, _) ->
    false.

verify_volume(#{volume := Volume, labels := Labels}) ->
    V = case muse_json:decode(checked(muse_docker:volume_inspect_args(Volume))) of
            {ok, [One]} when is_map(One) -> One;
            _ -> ?ERR(409, <<"Browser profile volume inspection failed">>)
        end,
    case maps:get(<<"Name">>, V, undefined) =:= Volume
        andalso maps:get(<<"Driver">>, V, undefined) =:= <<"local">>
        andalso map(maps:get(<<"Options">>, V, null)) =:= #{}
        andalso labels_match(Labels, maps:get(<<"Labels">>, V, null)) of
        true -> ok;
        false -> ?ERR(409, <<"Browser profile volume ownership does not match this deployment">>)
    end.

list(null) -> [];
list(L) when is_list(L) -> L.

map(null) -> #{};
map(M) when is_map(M) -> M.
