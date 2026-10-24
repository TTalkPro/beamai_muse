%% @doc Docker computer provider: OpenMuse `DockerComputer`
%% (computer-backend.ts; designs/ref/openmuse-integrations-spec.md §6.3–§6.5).
%%
%% Attaching to an existing container fails closed: the container and its
%% volume must carry this deployment's owner labels and the exact isolation
%% settings `create_args/3` produces for the configured variant
%% (COMPUTER_DESKTOP; the desktop variant is not in OpenMuse). A container
%% of the other variant is refused with its own message.
-module(muse_computer_docker).
-behaviour(muse_computer_provider).

-export([provider/0, receipts/0, network/0,
         state/1, start/1, stop/1, running/1,
         exec/4, file/4, session_stop/1,
         image/0, variant/0, desktop/3]).

-define(ERR(Status, Msg), throw({muse_computer_docker, Status, Msg})).
-define(OPERATION_FAILED, <<"Docker operation failed. Check that the engine is running "
                            "and the computer image is built locally.">>).
-define(IMAGE_RE, "^[a-zA-Z0-9][a-zA-Z0-9._/:@-]{0,250}$").
-define(ALLOWED_ENV, [<<"PATH">>, <<"HOME">>, <<"LANG">>, <<"NODE_VERSION">>,
                      <<"YARN_VERSION">>]).
-define(TMPFS, <<"rw,nosuid,nodev,noexec,size=67108864,mode=1777">>).
-define(DESKTOP_TMPFS, <<"rw,nosuid,nodev,noexec,size=268435456,mode=1777">>).

-spec provider() -> binary().
provider() -> <<"docker">>.

-spec receipts() -> binary().
receipts() -> <<"computer-commands">>.

-spec network() -> binary().
network() -> <<"disabled">>.

-spec state(binary()) -> {ok, muse_computer_provider:state()} | muse_computer_provider:error().
state(Owner) ->
    guard(fun() -> {ok, state_of(inspect(Owner))} end).

-spec start(binary()) -> ok | muse_computer_provider:error().
start(Owner) ->
    guard(fun() -> do_start(Owner) end).

-spec stop(binary()) -> ok | muse_computer_provider:error().
stop(Owner) ->
    guard(fun() ->
                  case state_of(inspect(Owner)) of
                      running -> _ = checked(muse_docker:stop_args(container(Owner))), ok;
                      _ -> ok
                  end
          end).

-spec running(binary()) -> {ok, muse_computer_provider:session()} | muse_computer_provider:error().
running(Owner) ->
    guard(fun() ->
                  case state_of(inspect(Owner)) of
                      running -> {ok, #{container => container(Owner)}};
                      _ -> ?ERR(409, <<"Start the computer before using its terminal or files">>)
                  end
          end).

-spec exec(muse_computer_provider:session(), binary(), binary(), [pid()]) -> muse_docker:result().
exec(#{container := Container}, Command, Cwd, Cancel) ->
    retry_unstarted(fun() ->
                        muse_docker:run(muse_docker:exec_args(Container, Cwd, Command),
                                        #{timeout => 35000, cancel => Cancel})
                    end, 2).

%% The in-container timeout is fixed at 8 s; the provider callback's
%% `Seconds` is not used.
-spec file(muse_computer_provider:session(), binary(), pos_integer(), pos_integer()) ->
    muse_docker:result().
file(#{container := Container}, Input, _Seconds, MaxOutputBytes) ->
    retry_unstarted(fun() ->
                        muse_docker:run(muse_docker:file_args(Container),
                                        #{timeout => 10000, input => Input, max_output => MaxOutputBytes})
                    end, 2).

%% runc occasionally fails to start the exec'd process under load
%% ("OCI runtime exec failed: ... read init-p: connection reset by peer",
%% exit 126). The command never ran, so retrying is safe; a 126 from the
%% command itself has no such message and is returned as is.
retry_unstarted(Run, Retries) ->
    case Run() of
        #{exit_code := 126, stdout := Out, stderr := Err} = Result when Retries > 0 ->
            case binary:match(<<Out/binary, Err/binary>>, <<"OCI runtime exec failed">>) of
                nomatch -> Result;
                _ -> timer:sleep(200), retry_unstarted(Run, Retries - 1)
            end;
        Result ->
            Result
    end.

-spec session_stop(muse_computer_provider:session()) -> ok | muse_computer_provider:error().
session_stop(#{container := Container}) ->
    guard(fun() -> _ = checked(muse_docker:stop_args(Container)), ok end).

%% @doc Run one desktop action script (`muse_docker:desktop_args/3`) in the
%% running desktop computer. The screenshot comes back as base64 on stdout.
-spec desktop(muse_computer_provider:session(), binary(), [binary()]) -> muse_docker:result().
desktop(#{container := Container}, Script, Args) ->
    retry_unstarted(fun() ->
                        muse_docker:run(muse_docker:desktop_args(Container, Script, Args),
                                        #{timeout => 35000, max_output => 8 * 1048576})
                    end, 2).

%% @doc The configured variant: `desktop` with COMPUTER_DESKTOP=true.
-spec variant() -> muse_docker:variant().
variant() ->
    case muse_config:get(computer_desktop, false) of
        true -> desktop;
        _ -> light
    end.

%% @doc COMPUTER_IMAGE (or COMPUTER_DESKTOP_IMAGE for the desktop variant),
%% validated (503 `COMPUTER_IMAGE is invalid`).
-spec image() -> {ok, binary()} | muse_computer_provider:error().
image() ->
    guard(fun() -> {ok, image_name()} end).

%% Internal

guard(Fun) ->
    try
        Fun()
    catch
        throw:{muse_computer_docker, Status, Msg} -> {error, {Status, Msg}}
    end.

container(Owner) ->
    maps:get(container, muse_computer:identity(Owner)).

image_name() ->
    {Image, Invalid} =
        case variant() of
            light -> {muse_config:get(computer_image, <<"openmuse-computer:local">>),
                      <<"COMPUTER_IMAGE is invalid">>};
            desktop -> {muse_config:get(computer_desktop_image, <<"openmuse-computer-desktop:local">>),
                        <<"COMPUTER_DESKTOP_IMAGE is invalid">>}
        end,
    case re:run(Image, ?IMAGE_RE, [{capture, none}]) of
        match -> Image;
        nomatch -> ?ERR(503, Invalid)
    end.

checked(Args) ->
    case muse_docker:run(Args, #{timeout => muse_docker:control_timeout()}) of
        #{timed_out := true} ->
            ?ERR(503, <<"Docker did not respond within 10 seconds. Check the Docker engine.">>);
        #{interrupted := false, exit_code := 0, truncated := false, stdout := Out} ->
            Out;
        _ ->
            ?ERR(503, ?OPERATION_FAILED)
    end.

%% JSON.parse failures surface as generic errors in OpenMuse (HTTP 500).
decode(Bin) ->
    case muse_json:decode(Bin) of
        {ok, Json} -> Json;
        {error, _} -> erlang:error(invalid_docker_json)
    end.

state_of(undefined) -> missing;
state_of(#{<<"State">> := #{<<"Running">> := true}}) -> running;
state_of(_) -> stopped.

do_start(Owner) ->
    Id = #{container := Container, volume := Volume, labels := Labels} =
        muse_computer:identity(Owner),
    case inspect(Owner) of
        undefined ->
            case string:trim(checked(muse_docker:volume_ls_args(Volume))) of
                <<>> -> _ = checked(muse_docker:volume_create_args(Volume, Labels)), ok;
                _ -> ok
            end,
            verify_volume(Owner),
            _ = checked(muse_docker:create_args(Id, image_name(), variant())),
            _ = inspect(Owner),
            _ = checked(muse_docker:start_args(Container)),
            ok;
        Info ->
            case state_of(Info) of
                running -> ok;
                _ -> _ = checked(muse_docker:start_args(Container)), ok
            end
    end.

inspect(Owner) ->
    #{container := Container, volume := Volume, labels := Labels} =
        muse_computer:identity(Owner),
    case string:trim(checked(muse_docker:find_args(Container))) of
        <<>> ->
            undefined;
        _ ->
            Raw = decode(checked(muse_docker:inspect_args(Container))),
            C = case muse_validate:check({array, inspection_schema(), #{}}, Raw) of
                    {ok, [One]} -> One;
                    _ -> ?ERR(409, <<"Computer isolation inspection failed; refusing to attach">>)
                end,
            Variant = variant(),
            case safe(C, Container, Volume, Labels, Variant) of
                true ->
                    ok;
                false ->
                    case owned(C, Container, Labels) andalso variant_of(C) of
                        Other when Other =/= false, Other =/= Variant ->
                            ?ERR(409, variant_mismatch(Other));
                        _ ->
                            ?ERR(409, <<"Computer ownership or isolation does not match this "
                                        "deployment; refusing to attach">>)
                    end
            end,
            verify_volume(Owner),
            C
    end.

safe(C, Container, Volume, Labels, Variant) ->
    #{<<"Config">> := Cfg, <<"HostConfig">> := H,
      <<"Mounts">> := Mounts, <<"NetworkSettings">> := #{<<"Networks">> := Networks}} = C,
    Image = image_name(),
    {Entrypoint, Cmd, Env} = case Variant of
                                 light -> {[<<"/usr/bin/sleep">>], [<<"infinity">>], ?ALLOWED_ENV};
                                 desktop -> {[<<"/opt/openmuse/desktop-init">>], [],
                                             [<<"DISPLAY">> | ?ALLOWED_ENV]}
                             end,
    owned(C, Container, Labels)
        andalso variant_of(C) =:= Variant
        andalso maps:get(<<"Image">>, Cfg) =:= Image
        andalso maps:get(<<"User">>, Cfg) =:= <<"1000:1000">>
        andalso maps:get(<<"WorkingDir">>, Cfg) =:= <<"/workspace">>
        andalso lists:all(fun(E) -> lists:member(env_name(E), Env) end,
                          maps:get(<<"Env">>, Cfg))
        andalso maps:get(<<"Entrypoint">>, Cfg) =:= Entrypoint
        andalso list(maps:get(<<"Cmd">>, Cfg)) =:= Cmd
        andalso host_safe(H, Variant)
        andalso mounts_safe(Mounts, Volume)
        andalso lists:all(fun(N) -> N =:= <<"none">> end, maps:keys(Networks)).

%% The container name and this deployment's owner labels.
owned(#{<<"Name">> := Name, <<"Config">> := Cfg}, Container, Labels) ->
    Name =:= <<"/", Container/binary>>
        andalso labels_match(Labels, maps:get(<<"Labels">>, Cfg)).

%% `light` without the variant label; `false` for an unknown value.
variant_of(#{<<"Config">> := Cfg}) ->
    case maps:get(muse_docker:variant_label(), map(maps:get(<<"Labels">>, Cfg)), undefined) of
        undefined -> light;
        <<"desktop">> -> desktop;
        _ -> false
    end.

variant_mismatch(desktop) ->
    <<"The existing computer container is the desktop variant but COMPUTER_DESKTOP is not "
      "enabled; refusing to attach. Remove the container to switch variants "
      "(the /workspace volume is kept).">>;
variant_mismatch(light) ->
    <<"The existing computer container is not the desktop variant but COMPUTER_DESKTOP is "
      "enabled; refusing to attach. Remove the container to switch variants "
      "(the /workspace volume is kept).">>.

%% Upper bounds of the variant's limits (create_args/3).
host_limits(light) ->
    #{memory => 536870912, pids => 128, cpus => 1000000000, tmpfs => ?TMPFS};
host_limits(desktop) ->
    #{memory => 1610612736, pids => 512, cpus => 2000000000, tmpfs => ?DESKTOP_TMPFS}.

host_safe(H, Variant) ->
    #{memory := MaxMemory, pids := MaxPids, cpus := MaxCpus, tmpfs := Tmpfs} =
        host_limits(Variant),
    G = fun(K) -> maps:get(K, H) end,
    Memory = G(<<"Memory">>),
    Pids = G(<<"PidsLimit">>),
    Cpus = G(<<"NanoCpus">>),
    G(<<"ReadonlyRootfs">>) =:= true
        andalso G(<<"Privileged">>) =:= false
        andalso lists:member(<<"ALL">>, list(G(<<"CapDrop">>)))
        andalso list(G(<<"CapAdd">>)) =:= []
        andalso list(G(<<"SecurityOpt">>)) =:= [<<"no-new-privileges">>]
        andalso G(<<"NetworkMode">>) =:= <<"none">>
        andalso Memory > 0 andalso Memory =< MaxMemory
        andalso G(<<"MemorySwap">>) == Memory
        andalso Pids =/= null andalso Pids > 0 andalso Pids =< MaxPids
        andalso Cpus > 0 andalso Cpus =< MaxCpus
        andalso list(G(<<"Binds">>)) =:= []
        andalso list(G(<<"Devices">>)) =:= []
        andalso list(G(<<"DeviceRequests">>)) =:= []
        andalso map_size(map(G(<<"PortBindings">>))) =:= 0
        andalso G(<<"PidMode">>) =:= <<>>
        andalso G(<<"IpcMode">>) =:= <<"private">>
        andalso maps:get(<<"Name">>, G(<<"RestartPolicy">>)) =:= <<"no">>
        andalso map(G(<<"Tmpfs">>)) =:= #{<<"/tmp">> => Tmpfs}.

mounts_safe([#{<<"Type">> := <<"volume">>, <<"Destination">> := <<"/workspace">>,
               <<"RW">> := true} = M], Volume) ->
    maps:get(<<"Name">>, M, undefined) =:= Volume;
mounts_safe(_, _) ->
    false.

verify_volume(Owner) ->
    #{volume := Volume, labels := Labels} = muse_computer:identity(Owner),
    Raw = decode(checked(muse_docker:volume_inspect_args(Volume))),
    V = case muse_validate:check({array, volume_schema(), #{}}, Raw) of
            {ok, [One]} -> One;
            _ -> ?ERR(409, <<"Computer workspace ownership inspection failed">>)
        end,
    case maps:get(<<"Name">>, V) =:= Volume
        andalso maps:get(<<"Driver">>, V) =:= <<"local">>
        andalso maps:get(<<"Scope">>, V) =:= <<"local">>
        andalso map_size(map(maps:get(<<"Options">>, V))) =:= 0
        andalso labels_match(Labels, maps:get(<<"Labels">>, V)) of
        true -> ok;
        false -> ?ERR(409, <<"Computer workspace ownership or isolation does not match">>)
    end.

labels_match(Expected, Actual) ->
    Map = map(Actual),
    lists:all(fun({K, V}) -> maps:get(K, Map, undefined) =:= V end, Expected).

env_name(Entry) ->
    hd(binary:split(Entry, <<"=">>)).

list(null) -> [];
list(L) -> L.

map(null) -> #{};
map(M) -> M.

str() -> {string, #{}}.
num() -> {number, #{}}.
strings() -> {array, str(), #{}}.
nullable_list(Item) -> {nullable, {array, Item, #{}}}.

inspection_schema() ->
    {object,
     [{<<"Id">>, str()},
      {<<"Name">>, str()},
      {<<"Config">>,
       {object, [{<<"Image">>, str()},
                 {<<"User">>, str()},
                 {<<"Labels">>, {nullable, {record, str(), #{}}}},
                 {<<"Env">>, strings()},
                 {<<"Entrypoint">>, {nullable, strings()}},
                 {<<"Cmd">>, {nullable, strings()}},
                 {<<"WorkingDir">>, str()}]}},
      {<<"HostConfig">>,
       {object, [{<<"ReadonlyRootfs">>, boolean},
                 {<<"Privileged">>, boolean},
                 {<<"CapDrop">>, {nullable, strings()}},
                 {<<"CapAdd">>, {nullable, strings()}},
                 {<<"SecurityOpt">>, {nullable, strings()}},
                 {<<"NetworkMode">>, str()},
                 {<<"Memory">>, num()},
                 {<<"MemorySwap">>, num()},
                 {<<"PidsLimit">>, {nullable, num()}},
                 {<<"NanoCpus">>, num()},
                 {<<"Binds">>, {nullable, strings()}},
                 {<<"Devices">>, nullable_list(any)},
                 {<<"DeviceRequests">>, nullable_list(any)},
                 {<<"PortBindings">>, {nullable, {record, any, #{}}}},
                 {<<"PidMode">>, str()},
                 {<<"IpcMode">>, str()},
                 {<<"Tmpfs">>, {nullable, {record, str(), #{}}}},
                 {<<"RestartPolicy">>, {object, [{<<"Name">>, str()}]}}]}},
      {<<"Mounts">>,
       {array, {object, [{<<"Type">>, str()},
                         {<<"Name">>, {optional, str()}},
                         {<<"Destination">>, str()},
                         {<<"RW">>, boolean}]}, #{}}},
      {<<"NetworkSettings">>, {object, [{<<"Networks">>, {record, any, #{}}}]}},
      {<<"State">>, {object, [{<<"Running">>, boolean}]}}]}.

volume_schema() ->
    {object, [{<<"Name">>, str()},
              {<<"Labels">>, {nullable, {record, str(), #{}}}},
              {<<"Driver">>, str()},
              {<<"Options">>, {nullable, {record, any, #{}}}},
              {<<"Scope">>, str()}]}.
