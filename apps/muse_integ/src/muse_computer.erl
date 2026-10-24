%% @doc The owner's sandboxed computer: OpenMuse `ComputerService`
%% (computer.ts; designs/ref/openmuse-integrations-spec.md §6.1–§6.9;
%% designs/04-integrations.md §3).
%%
%% Mutual exclusion is the `computer-state/lease` record (180 s, never
%% renewed), claimed and released only through `muse_store` CAS so it holds
%% across nodes. Command receipts are written as `running` before docker is
%% invoked and finished by CAS, so a Stop that lands first wins.
%%
%% `execute/3` runs in a separate unlinked process that monitors the caller
%% (and `cancel` processes): if one of them dies mid-command the docker
%% client is killed and the whole container stopped, as OpenMuse does when
%% the HTTP client disconnects.
-module(muse_computer).

-export([snapshot/1, start/1, stop/1,
         execute/2, execute/3,
         list/1, list/2, read/2, write/3, mkdir/2,
         write_pdf/3, pdf_bytes/2, import_pdf/3, export_pdf/2,
         identity/1, workspace_path/1,
         provider/0, network/0, receipts/0, require_enabled/0, locked/2,
         command_schema/0, path_schema/0, write_schema/0, import_schema/0]).

-export_type([snapshot/0, command/0, identity/0, error/0]).

-type snapshot() :: #{binary() => term()}.
-type command() :: #{binary() => term()}.
-type identity() :: #{container := binary(), volume := binary(),
                      deployment := binary(), owner_hash := binary(),
                      labels := [{binary(), binary()}]}.
-type error() :: {error, {pos_integer(), binary()}}.

-define(ERR(Status, Msg), throw({muse_computer, Status, Msg})).
-define(LEASE_KIND, <<"computer-state">>).
-define(LEASE_ID, <<"lease">>).
-define(LEASE_MS, 180000).
-define(FILE_LIMIT, 262144).
-define(PDF_LIMIT, 10485760).
-define(MIB, 1048576).
-define(BUSY, <<"Computer is busy. Wait for the current operation to finish.">>).
-define(OUTSIDE, <<"Choose an absolute path inside /workspace">>).

%% @doc ComputerSnapshot (§2.5). Inspection failures become `status: "error"`.
-spec snapshot(binary()) -> snapshot().
snapshot(Owner) ->
    Enabled = muse_config:get(computer_enabled, false) =:= true,
    Base = #{<<"enabled">> => Enabled,
             <<"provider">> => provider(),
             <<"workspacePath">> => <<"/workspace">>,
             <<"network">> => network(),
             <<"commands">> => commands(Owner)},
    case Enabled of
        false ->
            Base#{<<"status">> => <<"unconfigured">>,
                  <<"message">> => <<"Enable the Docker computer on the server to use "
                                     "its terminal and workspace files.">>};
        true ->
            try (backend()):state(Owner) of
                {ok, running} -> Base#{<<"status">> => <<"running">>};
                {ok, _} -> Base#{<<"status">> => <<"stopped">>};
                {error, {_, Msg}} -> Base#{<<"status">> => <<"error">>, <<"message">> => Msg}
            catch
                _:_ ->
                    Base#{<<"status">> => <<"error">>,
                          <<"message">> =>
                              <<"Computer inspection failed. Check the computer provider setup.">>}
            end
    end.

-spec start(binary()) -> {ok, snapshot()} | error().
start(Owner) ->
    guard(fun() ->
                  exclusive(Owner, operation,
                            fun(_) -> unwrap((backend()):start(Owner)) end),
                  {ok, snapshot(Owner)}
          end).

%% @doc Stop the computer, interrupting a running command (§6.7 stop).
-spec stop(binary()) -> {ok, snapshot()} | error().
stop(Owner) ->
    guard(fun() -> do_stop(Owner), {ok, snapshot(Owner)} end).

-spec execute(binary(), map()) -> {ok, command()} | error().
execute(Owner, Args) ->
    execute(Owner, Args, #{}).

%% @doc Run one shell command in the computer (§6.8). `Args`: `command`,
%% optional `cwd` (binary or atom keys). `Opts`: `idempotency_key` (a replay
%% returns the stored receipt and never runs again) and `cancel`, a pid or
%% pids whose death interrupts the command; the caller is always included.
-spec execute(binary(), map(), #{idempotency_key => binary(), cancel => pid() | [pid()]}) ->
    {ok, command()} | error().
execute(Owner, Args, Opts) ->
    Cancel = [self() | cancel_pids(maps:get(cancel, Opts, []))],
    Key = maps:get(idempotency_key, Opts, undefined),
    detached(fun() -> guard(fun() -> {ok, do_execute(Owner, Args, Key, Cancel)} end) end).

%% @doc ComputerDirectory of `/workspace`.
-spec list(binary()) -> {ok, map()} | error().
list(Owner) ->
    list(Owner, <<"/workspace">>).

-spec list(binary(), binary()) -> {ok, map()} | error().
list(Owner, Path) ->
    guard(fun() -> {ok, file_op(Owner, <<"list">>, Path, undefined, undefined)} end).

%% @doc `{path, text}` of a UTF-8 file of at most 256 KiB.
-spec read(binary(), binary()) -> {ok, map()} | error().
read(Owner, Path) ->
    guard(fun() -> {ok, file_op(Owner, <<"read">>, Path, undefined, undefined)} end).

-spec write(binary(), binary(), binary()) -> {ok, map()} | error().
write(Owner, Path, Text) ->
    guard(fun() -> {ok, file_op(Owner, <<"write">>, Path, Text, undefined)} end).

-spec mkdir(binary(), binary()) -> {ok, map()} | error().
mkdir(Owner, Path) ->
    guard(fun() -> {ok, file_op(Owner, <<"mkdir">>, Path, undefined, undefined)} end).

-spec write_pdf(binary(), binary(), binary()) -> {ok, map()} | error().
write_pdf(Owner, Path, Bytes) ->
    guard(fun() ->
                  case byte_size(Bytes) =< ?PDF_LIMIT andalso is_pdf(Bytes) of
                      true -> ok;
                      false -> ?ERR(422, <<"Choose a PDF of 10 MB or smaller">>)
                  end,
                  {ok, file_op(Owner, <<"write_pdf">>, Path, undefined, base64:encode(Bytes))}
          end).

%% @doc OpenMuse `pdfBytes`: a workspace PDF and its basename.
-spec pdf_bytes(binary(), binary()) -> {ok, #{name := binary(), bytes := binary()}} | error().
pdf_bytes(Owner, Path) ->
    guard(fun() ->
                  #{<<"base64">> := B64} =
                      file_op(Owner, <<"read_pdf">>, Path, undefined, undefined),
                  {ok, #{name => filename:basename(Path), bytes => base64:decode(B64)}}
          end).

%% @doc Copy an owned Documents PDF into the workspace (`POST /files/import`).
-spec import_pdf(binary(), binary(), binary()) -> {ok, map()} | error().
import_pdf(Owner, Path, FileId) ->
    case muse_files:bytes(Owner, FileId) of
        {ok, Bytes} -> write_pdf(Owner, Path, Bytes);
        {error, _} = Error -> Error
    end.

%% @doc Import a workspace PDF into Documents as a new Artifact
%% (`POST /files/export`, HTTP 201).
-spec export_pdf(binary(), binary()) -> {ok, map()} | error().
export_pdf(Owner, Path) ->
    case pdf_bytes(Owner, Path) of
        {ok, #{name := Name, bytes := Bytes}} ->
            muse_files:import(Owner, Name, Bytes, <<"Computer: ", Path/binary>>);
        {error, _} = Error ->
            Error
    end.

%% @doc `computerIdentity` (§6.2). Labels are ordered as OpenMuse passes them.
-spec identity(binary()) -> identity().
identity(Owner) ->
    Source = case muse_config:get(computer_deployment_id, undefined) of
                 undefined -> muse_config:get(public_url);
                 Id -> Id
             end,
    Deployment = binary:part(muse_ids:sha256hex(Source), 0, 16),
    OwnerHash = binary:part(muse_ids:sha256hex(Owner), 0, 24),
    Name = <<"openmuse-", Deployment/binary, "-", OwnerHash/binary>>,
    #{container => <<Name/binary, "-computer">>,
      volume => <<Name/binary, "-workspace">>,
      deployment => Deployment,
      owner_hash => OwnerHash,
      labels => [{<<"dev.openmuse.managed">>, <<"computer-v1">>},
                 {<<"dev.openmuse.deployment">>, Deployment},
                 {<<"dev.openmuse.owner">>, OwnerHash}]}.

%% @doc `workspacePath` (§6.2): a normalised absolute path inside /workspace.
-spec workspace_path(term()) -> {ok, binary()} | error().
workspace_path(Path) ->
    guard(fun() -> {ok, ws_path(Path)} end).

%% @doc The provider name in status payloads: only the Docker computer is
%% supported (OpenMuse's E2B desktop is not).
-spec provider() -> binary().
provider() ->
    <<"docker">>.

%% The Docker computer runs with `--network none`.
-spec network() -> binary().
network() ->
    <<"disabled">>.

%% @doc Record kind of the command receipts.
-spec receipts() -> binary().
receipts() ->
    <<"computer-commands">>.

%% @doc `computerCommandSchema` for `muse_validate`.
-spec command_schema() -> muse_validate:schema().
command_schema() ->
    {object, [{<<"command">>, {string, #{trim => true, min => 1, max => 16000}}},
              {<<"cwd">>, {default, {string, #{}}, <<"/workspace">>}}]}.

-spec path_schema() -> muse_validate:schema().
path_schema() ->
    {object, [{<<"path">>, {string, #{min => 1, max => 2048}}}]}.

-spec write_schema() -> muse_validate:schema().
write_schema() ->
    {object, Fields} = path_schema(),
    {object, Fields ++ [{<<"text">>, {string, #{max => ?FILE_LIMIT}}}]}.

%% @doc Body of `POST /files/import`.
-spec import_schema() -> muse_validate:schema().
import_schema() ->
    {object, Fields} = path_schema(),
    {object, Fields ++ [{<<"fileId">>, {string, #{min => 1}}}]}.

%% @doc The COMPUTER_ENABLED check (503 with the setup message).
-spec require_enabled() -> ok | error().
require_enabled() ->
    guard(fun enabled/0).

%% @doc Run `Fun` under the computer lease as an operation (OpenMuse
%% `exclusive(owner, work)`), for the desktop actions (muse_computer_desktop).
%% Returns what `Fun` returns; `{error, {409, _}}` when the computer is busy,
%% 503 when it is disabled. Exceptions from `Fun` propagate after release.
-spec locked(binary(), fun(() -> T)) -> T | error().
locked(Owner, Fun) ->
    guard(fun() -> exclusive(Owner, operation, fun(_) -> Fun() end) end).

%% Internal

guard(Fun) ->
    try
        Fun()
    catch
        throw:{muse_computer, Status, Msg} -> {error, {Status, Msg}}
    end.

unwrap(ok) -> ok;
unwrap({ok, Value}) -> Value;
unwrap({error, {Status, Msg}}) -> ?ERR(Status, Msg).

backend() ->
    muse_computer_docker.

enabled() ->
    case muse_config:get(computer_enabled, false) of
        true ->
            ok;
        _ ->
            ?ERR(503, <<"Computer is not configured. Enable COMPUTER_ENABLED and "
                        "build the local computer image.">>)
    end.

ws_path(Path) when is_binary(Path) ->
    Bad = binary:match(Path, <<0>>) =/= nomatch
        orelse muse_validate:utf16_length(Path) > 2048
        orelse not is_prefix(<<"/workspace">>, Path)
        orelse lists:member(<<"..">>, binary:split(Path, <<"/">>, [global])),
    Bad andalso ?ERR(422, ?OUTSIDE),
    Normal = posix_normalize(Path),
    case Normal =:= <<"/workspace">> orelse is_prefix(<<"/workspace/">>, Normal) of
        true -> Normal;
        false -> ?ERR(422, ?OUTSIDE)
    end;
ws_path(_) ->
    ?ERR(422, ?OUTSIDE).

is_prefix(Prefix, Bin) ->
    binary:longest_common_prefix([Prefix, Bin]) =:= byte_size(Prefix).

%% `path.posix.normalize` for absolute paths without `..` segments.
posix_normalize(Path) ->
    Parts = [P || P <- binary:split(Path, <<"/">>, [global]), P =/= <<>>, P =/= <<".">>],
    Joined = iolist_to_binary([[<<"/">>, P] || P <- Parts]),
    case {Joined, binary:last(Path)} of
        {<<>>, _} -> <<"/">>;
        {_, $/} -> <<Joined/binary, "/">>;
        _ -> Joined
    end.

is_pdf(<<"%PDF-", _/binary>>) -> true;
is_pdf(_) -> false.

now_ms() -> muse_time:now_ms().

%% Lease

get_lease(Owner) ->
    muse_store:get(Owner, ?LEASE_KIND, ?LEASE_ID).

lease_cas(Owner, Expected, Patch) ->
    muse_store:cas(Owner, ?LEASE_KIND, ?LEASE_ID, Expected, Patch).

live(#{<<"expiresAt">> := Expires}) -> Expires > now_ms();
live(_) -> false.

acquire(Owner, Kind) ->
    enabled(),
    Previous = get_lease(Owner),
    Lease = #{<<"id">> => ?LEASE_ID,
              <<"token">> => muse_ids:uuid(),
              <<"expiresAt">> => now_ms() + ?LEASE_MS,
              <<"stopping">> => false,
              <<"stopInFlight">> => false,
              <<"stopAttempt">> => <<>>,
              <<"stopConfirmed">> => false,
              <<"executorDone">> => Kind =/= command,
              <<"operation">> => atom_to_binary(Kind)},
    live(Previous) andalso ?ERR(409, ?BUSY),
    Claimed = case Previous of
                  undefined ->
                      muse_store:insert_if_absent(Owner, ?LEASE_KIND, Lease);
                  _ ->
                      lease_cas(Owner, maps:with([<<"token">>, <<"expiresAt">>], Previous), Lease)
              end,
    Claimed =:= undefined andalso ?ERR(409, ?BUSY),
    Lease.

exclusive(Owner, Kind, Fun) ->
    Lease = #{<<"token">> := Token} = acquire(Owner, Kind),
    try
        Fun(Lease)
    after
        _ = case Kind of
                command -> lease_cas(Owner, #{<<"token">> => Token}, #{<<"executorDone">> => true});
                _ -> ok
            end,
        _ = lease_cas(Owner, #{<<"token">> => Token, <<"stopping">> => false},
                      #{<<"expiresAt">> => 0}),
        release_stopped(Owner, Token)
    end.

release_stopped(Owner, Token) ->
    _ = lease_cas(Owner,
                  #{<<"token">> => Token, <<"stopping">> => true, <<"stopConfirmed">> => true,
                    <<"executorDone">> => true, <<"stopInFlight">> => false},
                  #{<<"expiresAt">> => 0}),
    ok.

stopping_patch(Attempt) ->
    #{<<"stopping">> => true, <<"stopInFlight">> => true, <<"stopAttempt">> => Attempt,
      <<"stopConfirmed">> => false, <<"expiresAt">> => now_ms() + ?LEASE_MS}.

do_stop(Owner) ->
    enabled(),
    Lease = case get_lease(Owner) of
                Current = #{<<"operation">> := Op, <<"stopping">> := Stopping,
                            <<"stopInFlight">> := InFlight} ->
                    case live(Current) of
                        false ->
                            acquire(Owner, operation);
                        true when (Op =/= <<"command">> andalso not Stopping) orelse InFlight ->
                            ?ERR(409, <<"Computer is busy with another operation. "
                                        "Try Stop again shortly.">>);
                        true ->
                            Current
                    end;
                _ ->
                    acquire(Owner, operation)
            end,
    #{<<"token">> := Token} = Lease,
    Attempt = muse_ids:uuid(),
    Expected = maps:with([<<"token">>, <<"stopping">>, <<"stopAttempt">>], Lease),
    lease_cas(Owner, Expected, stopping_patch(Attempt)) =:= undefined
        andalso ?ERR(409, <<"Computer is busy with another Stop request">>),
    try
        Kind = receipts(),
        _ = [muse_store:cas(Owner, Kind, Id, #{<<"status">> => <<"running">>},
                            #{<<"status">> => <<"interrupted">>,
                              <<"completedAt">> => muse_time:now_iso(),
                              <<"stderr">> => <<"Stopped by the user. Inspect the workspace "
                                                "before repeating this command.">>})
             || #{<<"id">> := Id, <<"status">> := <<"running">>} <- muse_store:list(Owner, Kind)],
        unwrap((backend()):stop(Owner)),
        _ = lease_cas(Owner, #{<<"token">> => Token, <<"stopAttempt">> => Attempt},
                      #{<<"stopInFlight">> => false, <<"stopConfirmed">> => true}),
        release_stopped(Owner, Token)
    catch
        Class:Reason:Stack ->
            _ = lease_cas(Owner, #{<<"token">> => Token, <<"stopAttempt">> => Attempt},
                          #{<<"stopInFlight">> => false, <<"stopConfirmed">> => false}),
            erlang:raise(Class, Reason, Stack)
    end.

%% Receipts

commands(Owner) ->
    Kind = receipts(),
    All = muse_store:list(Owner, Kind),
    Checked = case live(get_lease(Owner)) of
                  true -> All;
                  false -> [recover(Owner, Kind, C) || C <- All]
              end,
    Sorted = lists:sort(fun(A, B) -> started(A) >= started(B) end, Checked),
    lists:sublist(Sorted, 100).

recover(Owner, Kind, C = #{<<"id">> := Id, <<"status">> := <<"running">>}) ->
    Patch = #{<<"status">> => <<"interrupted">>,
              <<"completedAt">> => muse_time:now_iso(),
              <<"stderr">> => <<"Execution was interrupted. Its outcome is unknown; "
                                "inspect files before running it again.">>},
    case muse_store:cas(Owner, Kind, Id, #{<<"status">> => <<"running">>}, Patch) of
        undefined -> C;
        Saved -> Saved
    end;
recover(_, _, C) ->
    C.

started(C) -> maps:get(<<"startedAt">>, C, <<>>).

%% Commands

cancel_pids(Pid) when is_pid(Pid) -> [Pid];
cancel_pids(Pids) when is_list(Pids) -> Pids.

detached(Fun) ->
    Caller = self(),
    Tag = make_ref(),
    {Pid, Ref} = spawn_monitor(fun() -> Caller ! {Tag, Fun()} end),
    receive
        {Tag, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            erlang:error({computer_worker_failed, Reason})
    end.

command_args(Raw) when is_map(Raw) ->
    maps:fold(fun(K, V, Acc) when is_atom(K) -> Acc#{atom_to_binary(K) => V};
                 (K, V, Acc) -> Acc#{K => V}
              end, #{}, Raw);
command_args(Raw) ->
    Raw.

do_execute(Owner, Raw, Key, Cancel) ->
    enabled(),
    #{<<"command">> := Command, <<"cwd">> := Cwd0} =
        unwrap(muse_validate:parse(command_schema(), command_args(Raw))),
    Cwd = ws_path(Cwd0),
    Id = case Key of
             undefined -> muse_ids:uuid();
             _ -> muse_ids:sha256hex(<<"computer-command:", Key/binary>>)
         end,
    Kind = receipts(),
    case muse_store:get(Owner, Kind, Id) of
        undefined ->
            exclusive(Owner, command,
                      fun(Lease) -> run_command(Owner, Kind, Id, Command, Cwd, Cancel, Lease) end);
        Previous = #{<<"command">> := Command, <<"cwd">> := Cwd} ->
            _ = commands(Owner),
            case muse_store:get(Owner, Kind, Id) of
                undefined -> Previous;
                Fresh -> Fresh
            end;
        _ ->
            ?ERR(409, <<"This operation ID already belongs to a different command">>)
    end.

run_command(Owner, Kind, Id, Command, Cwd, Cancel, Lease) ->
    Backend = backend(),
    Session = unwrap(Backend:running(Owner)),
    lists:any(fun(P) -> not is_process_alive(P) end, Cancel)
        andalso ?ERR(409, <<"Computer command was interrupted before execution">>),
    Receipt = #{<<"id">> => Id, <<"command">> => Command, <<"cwd">> => Cwd,
                <<"status">> => <<"running">>, <<"stdout">> => <<>>, <<"stderr">> => <<>>,
                <<"truncated">> => false, <<"startedAt">> => muse_time:now_iso()},
    case muse_store:insert_if_absent(Owner, Kind, Receipt) of
        undefined ->
            case muse_store:get(Owner, Kind, Id) of
                undefined -> ?ERR(500, <<"Computer receipt could not be saved">>);
                Existing -> Existing
            end;
        _ ->
            #{<<"token">> := Token} = Lease,
            case get_lease(Owner) of
                Active = #{<<"token">> := Token, <<"stopping">> := false} ->
                    case live(Active) of
                        true -> run_receipt(Owner, Kind, Receipt, Session, Cancel, Token);
                        false -> stopped_before(Owner, Kind, Receipt)
                    end;
                _ ->
                    stopped_before(Owner, Kind, Receipt)
            end
    end.

stopped_before(Owner, Kind, Receipt = #{<<"id">> := Id}) ->
    Patch = #{<<"status">> => <<"interrupted">>,
              <<"stderr">> => <<"Stopped before execution">>,
              <<"completedAt">> => muse_time:now_iso()},
    case muse_store:cas(Owner, Kind, Id, #{<<"status">> => <<"running">>}, Patch) of
        undefined ->
            case muse_store:get(Owner, Kind, Id) of
                undefined -> maps:merge(Receipt, Patch);
                Stored -> Stored
            end;
        Preserved ->
            Preserved
    end.

run_receipt(Owner, Kind, Receipt = #{<<"id">> := Id}, Session, Cancel, Token) ->
    case muse_store:get(Owner, Kind, Id) of
        Stored = #{<<"status">> := Status} when Status =/= <<"running">> ->
            Stored;
        _ ->
            Backend = backend(),
            #{<<"command">> := Command, <<"cwd">> := Cwd} = Receipt,
            Result0 = try
                          Backend:exec(Session, Command, Cwd, Cancel)
                      catch
                          _:_ ->
                              #{stdout => <<>>,
                                stderr => <<"Execution was interrupted; inspect the "
                                            "workspace before retrying.">>,
                                exit_code => null, interrupted => true,
                                timed_out => false, truncated => false}
                      end,
            #{timed_out := HostTimeout, interrupted := Interrupted, exit_code := Exit} = Result0,
            Result = case HostTimeout orelse Interrupted of
                         true -> cleanup(Owner, Backend, Session, Token, Result0);
                         false -> Result0
                     end,
            Status = if
                         Interrupted -> <<"interrupted">>;
                         HostTimeout orelse Exit =:= 124 -> <<"timed_out">>;
                         Exit =:= 0 -> <<"succeeded">>;
                         true -> <<"failed">>
                     end,
            #{stdout := Stdout, stderr := Stderr, truncated := Truncated} = Result,
            Final0 = Receipt#{<<"status">> => Status, <<"stdout">> => Stdout,
                              <<"stderr">> => Stderr, <<"truncated">> => Truncated,
                              <<"completedAt">> => muse_time:now_iso()},
            Final = case Exit of
                        null -> Final0;
                        _ -> Final0#{<<"exitCode">> => Exit}
                    end,
            case muse_store:cas(Owner, Kind, Id, #{<<"status">> => <<"running">>}, Final) of
                undefined ->
                    StoredErr = case muse_store:get(Owner, Kind, Id) of
                                    #{<<"stderr">> := E} when is_binary(E) -> E;
                                    _ -> <<>>
                                end,
                    Joined = lists:join(<<"\n">>, [S || S <- [Stderr, StoredErr], S =/= <<>>]),
                    muse_store:put(Owner, Kind,
                                   Final#{<<"status">> => <<"interrupted">>,
                                          <<"stderr">> => iolist_to_binary(Joined)});
                Finished ->
                    Finished
            end
    end.

%% A lost docker client cannot cancel exec reliably: stop the whole sandbox.
cleanup(Owner, Backend, Session, Token, Result = #{stderr := Stderr}) ->
    Attempt = muse_ids:uuid(),
    case lease_cas(Owner, #{<<"token">> => Token, <<"stopping">> => false},
                   stopping_patch(Attempt)) of
        undefined ->
            Result;
        _ ->
            Stopped = try Backend:session_stop(Session) of
                          ok -> true;
                          _ -> false
                      catch
                          _:_ -> false
                      end,
            Expected = #{<<"token">> => Token, <<"stopAttempt">> => Attempt},
            _ = lease_cas(Owner, Expected, #{<<"stopInFlight">> => false,
                                             <<"stopConfirmed">> => Stopped}),
            case Stopped of
                true -> Result;
                false -> Result#{stderr := <<Stderr/binary, "\nCould not confirm the computer "
                                             "stopped. It remains locked; retry Stop after "
                                             "checking the computer provider.">>}
            end
    end.

%% Files

file_op(Owner, Op, RawPath, Text, Base64) ->
    Path = ws_path(RawPath),
    is_binary(Text) andalso byte_size(Text) > ?FILE_LIMIT
        andalso ?ERR(413, <<"Text files must be 256 KB or smaller">>),
    exclusive(Owner, operation,
              fun(_) ->
                      enabled(),
                      Backend = backend(),
                      Session = unwrap(Backend:running(Owner)),
                      Input = muse_json:encode({obj, [{<<"operation">>, Op}, {<<"path">>, Path},
                                                      {<<"text">>, Text},
                                                      {<<"base64">>, Base64}]}),
                      {Max, Expected} = case Op of
                                            <<"read_pdf">> -> {15 * ?MIB, 15 * ?MIB};
                                            _ -> {2 * ?MIB, 0}
                                        end,
                      Seconds = 8 + ceil(max(byte_size(Input), Expected) / ?MIB),
                      case Backend:file(Session, Input, Seconds, Max) of
                          #{exit_code := 0, timed_out := false, interrupted := false,
                            truncated := false, stdout := Out} ->
                              case muse_json:decode(Out) of
                                  {ok, Json} -> Json;
                                  {error, _} ->
                                      ?ERR(502, <<"Computer returned an invalid file response">>)
                              end;
                          _ ->
                              ?ERR(422, <<"Computer file operation failed. Check the path, "
                                          "permissions and file size; symlinks cannot be "
                                          "opened.">>)
                      end
              end).
