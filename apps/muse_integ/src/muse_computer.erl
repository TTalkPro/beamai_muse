%% @doc A sandboxed computer of the pool: OpenMuse `ComputerService`
%% (computer.ts; designs/ref/openmuse-integrations-spec.md §6.1–§6.9;
%% designs/04-integrations.md §3).
%%
%% Every function takes a computer `ref()`, `{Owner, ComputerId}`: one
%% computer of the pool (muse_computers: one per conversation and per task).
%% `ref/2` and `ensure/2` build refs from a scope. There is no default
%% computer any more; a computer created by an older version as the owner's
%% single computer (scope `user`, OpenMuse's names for its container,
%% volume, lease and receipts) is still recognised as the legacy computer
%% (`is_legacy/1`), shown as 旧的默认电脑 and never deleted automatically.
%%
%% Mutual exclusion is a lease record per computer (`computer-state/lease`
%% for the legacy computer, `computer-state/lease:<id>` for the others; 180 s,
%% never renewed), claimed and released only through `muse_store` CAS so it
%% holds across nodes. Command receipts are written as `running` before docker is
%% invoked and finished by CAS, so a Stop that lands first wins.
%%
%% `execute/3` runs in a separate unlinked process that monitors the caller
%% (and `cancel` processes): if one of them dies mid-command the docker
%% client is killed and the whole container stopped, as OpenMuse does when
%% the HTTP client disconnects.
%%
%% Pool additions (not in OpenMuse): commands and file operations mark the
%% computer used (muse_computers `lastUsedAt`, for idle stop and retention);
%% starting a stopped computer goes through `muse_computer_pool:admit/2`
%% (COMPUTER_MAX_RUNNING); `ensure_running/1` and the `auto_start` option
%% start the computer on first use; `delete/1` removes container, volume and
%% the computer's records. Receipts of the pool computers carry
%% `computerId`; those without it belong to the legacy computer.
-module(muse_computer).

-export([snapshot/1, start/1, stop/1, ensure_running/1, delete/1, stop_if_idle/1,
         execute/2, execute/3,
         list/1, list/2, read/2, write/3, mkdir/2, changed_since/3,
         write_pdf/3, pdf_bytes/2, import_pdf/3, export_pdf/2, download/2, upload/3,
         identity/1, workspace_path/1, deployment/0,
         ref/2, ensure/2, ref_of/2, resolve/1, owner/1, computer_id/1, is_legacy/1,
         belongs/2, lease_id/1, busy/1,
         provider/0, network/0, receipts/0, require_enabled/0, locked/2,
         command_schema/0, path_schema/0, write_schema/0, import_schema/0]).

-export_type([snapshot/0, command/0, identity/0, error/0, ref/0]).

-type snapshot() :: #{binary() => term()}.
-type command() :: #{binary() => term()}.
%% `{Owner, ComputerId}`.
-type ref() :: {binary(), binary()}.
-type identity() :: #{container := binary(), volume := binary(),
                      deployment := binary(), owner_hash := binary(),
                      computer := binary(),
                      labels := [{binary(), binary()}]}.
-type error() :: {error, {pos_integer(), binary()}}.

-define(ERR(Status, Msg), throw({muse_computer, Status, Msg})).
-define(LEASE_KIND, <<"computer-state">>).
-define(LEASE_ID, <<"lease">>).
-define(COMPUTER_LABEL, <<"dev.openmuse.computer">>).
-define(LEASE_MS, 180000).
-define(FILE_LIMIT, 262144).
-define(PDF_LIMIT, 10485760).
-define(MIB, 1048576).
-define(BUSY, <<"Computer is busy. Wait for the current operation to finish.">>).
-define(OUTSIDE, <<"Choose an absolute path inside /workspace">>).

%% @doc ComputerSnapshot (§2.5). Inspection failures become `status: "error"`.
%% The observed state is also recorded on the pool record.
-spec snapshot(ref()) -> snapshot().
snapshot(Ref) ->
    Enabled = muse_config:get(computer_enabled, false) =:= true,
    Base = #{<<"enabled">> => Enabled,
             <<"provider">> => provider(),
             <<"workspacePath">> => <<"/workspace">>,
             <<"network">> => network(),
             <<"commands">> => commands(Ref)},
    case Enabled of
        false ->
            Base#{<<"status">> => <<"unconfigured">>,
                  <<"message">> => <<"Enable the Docker computer on the server to use "
                                     "its terminal and workspace files.">>};
        true ->
            Snapshot = try (backend()):state(Ref) of
                           {ok, running} -> Base#{<<"status">> => <<"running">>};
                           {ok, _} -> Base#{<<"status">> => <<"stopped">>};
                           {error, {_, Msg}} -> Base#{<<"status">> => <<"error">>, <<"message">> => Msg}
                       catch
                           _:_ ->
                               Base#{<<"status">> => <<"error">>,
                                     <<"message">> =>
                                         <<"Computer inspection failed. Check the computer provider setup.">>}
                       end,
            {Owner, Id} = resolve(Ref),
            _ = catch muse_computers:set_status(Owner, Id, maps:get(<<"status">>, Snapshot)),
            Snapshot
    end.

%% @doc Start the computer. Starting a stopped one may first stop the least
%% recently used idle computer of the deployment (COMPUTER_MAX_RUNNING).
-spec start(ref()) -> {ok, snapshot()} | error().
start(Ref) ->
    guard(fun() ->
                  exclusive(Ref, operation, fun(_) -> used(Ref), do_start(Ref) end),
                  {ok, snapshot(Ref)}
          end).

%% @doc Stop the computer, interrupting a running command (§6.7 stop).
-spec stop(ref()) -> {ok, snapshot()} | error().
stop(Ref) ->
    guard(fun() -> do_stop(Ref), {ok, snapshot(Ref)} end).

%% @doc Start the computer unless it is running (the agent tools' auto-start).
-spec ensure_running(ref()) -> ok | error().
ensure_running(Ref) ->
    guard(fun() ->
                  enabled(),
                  case unwrap((backend()):state(Ref)) of
                      running ->
                          ok;
                      _ ->
                          case start(Ref) of
                              {ok, _} -> ok;
                              {error, {S, M}} -> ?ERR(S, M)
                          end
                  end
          end).

%% @doc Stop the computer only if nothing holds its lease (idle stop and
%% eviction): a running command or file operation makes it 409 busy.
-spec stop_if_idle(ref()) -> ok | error().
stop_if_idle(Ref) ->
    guard(fun() ->
                  exclusive(Ref, operation, fun(_) -> unwrap((backend()):stop(Ref)) end),
                  {Owner, Id} = resolve(Ref),
                  muse_computers:set_status(Owner, Id, <<"stopped">>)
          end).

%% @doc Delete the computer: interrupt a running command (Stop), remove its
%% container and `/workspace` volume, then its receipts, lease, desktop
%% screenshot and pool record. The container is removed by name without the
%% attach verification, so a container refused after a configuration change
%% (variant, COMPUTER_NETWORK) can be deleted to recreate it.
-spec delete(ref()) -> ok | error().
delete(Ref) ->
    guard(fun() ->
                  enabled(),
                  _ = busy(Ref) andalso do_stop(Ref),
                  exclusive(Ref, operation, fun(_) -> unwrap((backend()):remove(Ref)) end),
                  {Owner, Id} = resolve(Ref),
                  Kind = receipts(),
                  _ = [muse_store:remove(Owner, Kind, C) || R = #{<<"id">> := C} <- muse_store:list(Owner, Kind),
                                                            belongs(Ref, R)],
                  muse_computer_desktop:forget(Ref),
                  muse_store:remove(Owner, ?LEASE_KIND, lease_id(Ref)),
                  muse_computers:remove(Owner, Id)
          end).

-spec execute(ref(), map()) -> {ok, command()} | error().
execute(Ref, Args) ->
    execute(Ref, Args, #{}).

%% @doc Run one shell command in the computer (§6.8). `Args`: `command`,
%% optional `cwd` (binary or atom keys). `Opts`: `idempotency_key` (a replay
%% returns the stored receipt and never runs again) and `cancel`, a pid or
%% pids whose death interrupts the command; the caller is always included.
%% `auto_start` (not in OpenMuse) starts a stopped computer first.
-spec execute(ref(), map(), #{idempotency_key => binary(), cancel => pid() | [pid()],
                              auto_start => boolean()}) ->
    {ok, command()} | error().
execute(Ref, Args, Opts) ->
    Cancel = [self() | cancel_pids(maps:get(cancel, Opts, []))],
    Key = maps:get(idempotency_key, Opts, undefined),
    case maps:get(auto_start, Opts, false) andalso ensure_running(Ref) of
        Started when Started =:= ok; Started =:= false ->
            detached(fun() -> guard(fun() -> {ok, do_execute(Ref, Args, Key, Cancel)} end) end);
        Error ->
            Error
    end.

%% @doc ComputerDirectory of `/workspace`.
-spec list(ref()) -> {ok, map()} | error().
list(Ref) ->
    list(Ref, <<"/workspace">>).

-spec list(ref(), binary()) -> {ok, map()} | error().
list(Ref, Path) ->
    guard(fun() -> {ok, file_op(Ref, <<"list">>, Path, undefined, undefined)} end).

%% @doc `{path, text}` of a UTF-8 file of at most 256 KiB.
-spec read(ref(), binary()) -> {ok, map()} | error().
read(Ref, Path) ->
    guard(fun() -> {ok, file_op(Ref, <<"read">>, Path, undefined, undefined)} end).

-spec write(ref(), binary(), binary()) -> {ok, map()} | error().
write(Ref, Path, Text) ->
    guard(fun() -> {ok, file_op(Ref, <<"write">>, Path, Text, undefined)} end).

-spec mkdir(ref(), binary()) -> {ok, map()} | error().
mkdir(Ref, Path) ->
    guard(fun() -> {ok, file_op(Ref, <<"mkdir">>, Path, undefined, undefined)} end).

%% @doc Regular files under /workspace modified at or after `SinceMs`
%% (files.py `changed_since`, not in OpenMuse; the chat's reply products,
%% muse_chat_products). `Opts`: `limit` (default 50), `max_bytes` (larger
%% files are listed under `skipped` instead), `depth` (default 8). Hidden
%% entries, `node_modules`, `__pycache__`, `venv`, `site-packages` and
%% `*.pyc` are skipped; symlinks are never followed. Never starts the
%% computer: a stopped one is a 409 from the backend. Returns
%% `{path, files: [{path, size, mtime}], skipped, truncated}`.
-spec changed_since(ref(), integer(), #{limit => pos_integer(), max_bytes => non_neg_integer(),
                                       depth => pos_integer()}) -> {ok, map()} | error().
changed_since(Ref, SinceMs, Opts) ->
    Extra = [{<<"since">>, max(0, SinceMs)},
             {<<"limit">>, maps:get(limit, Opts, 50)},
             {<<"maxBytes">>, maps:get(max_bytes, Opts, ?PDF_LIMIT)},
             {<<"depth">>, maps:get(depth, Opts, 8)}],
    guard(fun() -> {ok, file_op(Ref, <<"changed_since">>, <<"/workspace">>, undefined, undefined, Extra)} end).

-spec write_pdf(ref(), binary(), binary()) -> {ok, map()} | error().
write_pdf(Ref, Path, Bytes) ->
    guard(fun() ->
                  case byte_size(Bytes) =< ?PDF_LIMIT andalso is_pdf(Bytes) of
                      true -> ok;
                      false -> ?ERR(422, <<"Choose a PDF of 10 MB or smaller">>)
                  end,
                  {ok, file_op(Ref, <<"write_pdf">>, Path, undefined, base64:encode(Bytes))}
          end).

%% @doc Any workspace file of 10 MB or less, and its basename (the
%% computer page's download; not in OpenMuse).
-spec download(ref(), binary()) -> {ok, #{name := binary(), bytes := binary()}} | error().
download(Ref, Path) ->
    guard(fun() ->
                  #{<<"base64">> := B64} = file_op(Ref, <<"read_file">>, Path, undefined, undefined),
                  {ok, #{name => filename:basename(Path), bytes => base64:decode(B64)}}
          end).

%% @doc Write any file of 10 MB or less into the workspace (the computer
%% page's upload; not in OpenMuse).
-spec upload(ref(), binary(), binary()) -> {ok, map()} | error().
upload(Ref, Path, Bytes) ->
    guard(fun() ->
                  byte_size(Bytes) =< ?PDF_LIMIT orelse ?ERR(413, <<"Files must be 10 MB or smaller">>),
                  {ok, file_op(Ref, <<"write_file">>, Path, undefined, base64:encode(Bytes))}
          end).

%% @doc OpenMuse `pdfBytes`: a workspace PDF and its basename.
-spec pdf_bytes(ref(), binary()) -> {ok, #{name := binary(), bytes := binary()}} | error().
pdf_bytes(Ref, Path) ->
    guard(fun() ->
                  #{<<"base64">> := B64} =
                      file_op(Ref, <<"read_pdf">>, Path, undefined, undefined),
                  {ok, #{name => filename:basename(Path), bytes => base64:decode(B64)}}
          end).

%% @doc Copy an owned Documents PDF into the workspace (`POST /files/import`);
%% other kinds of file are refused (muse_files:pdf_bytes/2, 422).
-spec import_pdf(ref(), binary(), binary()) -> {ok, map()} | error().
import_pdf(Ref, Path, FileId) ->
    case muse_files:pdf_bytes(owner(Ref), FileId) of
        {ok, Bytes} -> write_pdf(Ref, Path, Bytes);
        {error, _} = Error -> Error
    end.

%% @doc Import a workspace PDF into Documents as a new Artifact
%% (`POST /files/export`, HTTP 201).
-spec export_pdf(ref(), binary()) -> {ok, map()} | error().
export_pdf(Ref, Path) ->
    case pdf_bytes(Ref, Path) of
        {ok, #{name := Name, bytes := Bytes}} ->
            muse_files:import(owner(Ref), Name, Bytes, <<"Computer: ", Path/binary>>);
        {error, _} = Error ->
            Error
    end.

%% @doc `computerIdentity` (§6.2). Labels are ordered as OpenMuse passes them.
%% The default computer keeps OpenMuse's names; a pool computer adds its id
%% to both names and the label `dev.openmuse.computer`.
-spec identity(ref()) -> identity().
identity(Ref) ->
    {Owner, Id} = resolve(Ref),
    Deployment = deployment(),
    OwnerHash = binary:part(muse_ids:sha256hex(Owner), 0, 24),
    Labels = [{<<"dev.openmuse.managed">>, <<"computer-v1">>},
              {<<"dev.openmuse.deployment">>, Deployment},
              {<<"dev.openmuse.owner">>, OwnerHash}],
    Base = <<"openmuse-", Deployment/binary, "-", OwnerHash/binary>>,
    {Name, AllLabels} = case is_legacy(Ref) of
                            true -> {Base, Labels};
                            false -> {<<Base/binary, "-", Id/binary>>, Labels ++ [{?COMPUTER_LABEL, Id}]}
                        end,
    #{container => <<Name/binary, "-computer">>,
      volume => <<Name/binary, "-workspace">>,
      deployment => Deployment,
      owner_hash => OwnerHash,
      computer => Id,
      labels => AllLabels}.

%% @doc This deployment's label value: a hash of COMPUTER_DEPLOYMENT_ID
%% (else PUBLIC_API_URL).
-spec deployment() -> binary().
deployment() ->
    Source = case muse_config:get(computer_deployment_id, undefined) of
                 undefined -> muse_config:get(public_url);
                 Id -> Id
             end,
    binary:part(muse_ids:sha256hex(Source), 0, 16).

%% @doc The ref of `Scope`'s computer, without creating its record.
-spec ref(binary(), binary()) -> ref().
ref(Owner, Scope) ->
    ref_of(Owner, muse_computers:id(Owner, Scope)).

%% @doc The ref of `Scope`'s computer, creating its pool record if missing.
-spec ensure(binary(), binary()) -> ref().
ensure(Owner, Scope) ->
    #{<<"id">> := Id} = muse_computers:ensure(Owner, Scope),
    ref_of(Owner, Id).

%% @doc The ref of one of the owner's computer ids.
-spec ref_of(binary(), binary()) -> ref().
ref_of(Owner, Id) ->
    {Owner, Id}.

-spec resolve(ref()) -> {binary(), binary()}.
resolve({Owner, Id}) when is_binary(Owner), is_binary(Id) -> {Owner, Id}.

-spec owner(ref()) -> binary().
owner(Ref) -> element(1, resolve(Ref)).

-spec computer_id(ref()) -> binary().
computer_id(Ref) -> element(2, resolve(Ref)).

-spec is_legacy(ref()) -> boolean().
is_legacy(Ref) ->
    {Owner, Id} = resolve(Ref),
    Id =:= muse_computers:legacy_id(Owner).

%% @doc Whether a receipt (command or desktop action) belongs to the
%% computer: pool receipts carry `computerId`, the legacy computer's do not.
-spec belongs(ref(), map()) -> boolean().
belongs(Ref, Receipt) ->
    {Owner, Id} = resolve(Ref),
    maps:get(<<"computerId">>, Receipt, muse_computers:legacy_id(Owner)) =:= Id.

%% @doc The id of the computer's lease record (kind `computer-state`).
-spec lease_id(ref()) -> binary().
lease_id(Ref) ->
    case is_legacy(Ref) of
        true -> ?LEASE_ID;
        false -> <<?LEASE_ID/binary, ":", (computer_id(Ref))/binary>>
    end.

%% @doc A live lease: a command or operation is in flight.
-spec busy(ref()) -> boolean().
busy(Ref) ->
    live(get_lease(Ref)).

%% @doc `workspacePath` (§6.2): a normalised absolute path inside /workspace.
-spec workspace_path(term()) -> {ok, binary()} | error().
workspace_path(Path) ->
    guard(fun() -> {ok, ws_path(Path)} end).

%% @doc The provider name in status payloads: only the Docker computer is
%% supported (OpenMuse's E2B desktop is not).
-spec provider() -> binary().
provider() ->
    <<"docker">>.

%% `disabled` (`--network none`, OpenMuse) or `enabled` (COMPUTER_NETWORK=bridge).
-spec network() -> binary().
network() ->
    muse_computer_docker:network().

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
-spec locked(ref(), fun(() -> T)) -> T | error().
locked(Ref, Fun) ->
    guard(fun() -> exclusive(Ref, operation, fun(_) -> used(Ref), Fun() end) end).

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

%% Mark the computer used (its pool record; the default computer's record is
%% created on first use).
used(Ref) ->
    {Owner, Id} = resolve(Ref),
    case muse_computers:get(Owner, Id) of
        undefined ->
            case is_legacy(Ref) of
                true -> _ = muse_computers:ensure(Owner, muse_computers:legacy_scope()), ok;
                false -> ok
            end;
        _ ->
            muse_computers:touch(Owner, Id)
    end.

do_start(Ref) ->
    Backend = backend(),
    case unwrap(Backend:state(Ref)) of
        running -> ok;
        _ -> unwrap(muse_computer_pool:admit(Ref, fun() -> Backend:start(Ref) end))
    end.

%% Pool receipts carry their computer.
tag(Ref, Receipt) ->
    case is_legacy(Ref) of
        true -> Receipt;
        false -> Receipt#{<<"computerId">> => computer_id(Ref)}
    end.

%% Lease

get_lease(Ref) ->
    muse_store:get(owner(Ref), ?LEASE_KIND, lease_id(Ref)).

lease_cas(Ref, Expected, Patch) ->
    muse_store:cas(owner(Ref), ?LEASE_KIND, lease_id(Ref), Expected, Patch).

live(#{<<"expiresAt">> := Expires}) -> Expires > now_ms();
live(_) -> false.

acquire(Ref, Kind) ->
    enabled(),
    Previous = get_lease(Ref),
    Lease = #{<<"id">> => lease_id(Ref),
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
                      muse_store:insert_if_absent(owner(Ref), ?LEASE_KIND, Lease);
                  _ ->
                      lease_cas(Ref, maps:with([<<"token">>, <<"expiresAt">>], Previous), Lease)
              end,
    Claimed =:= undefined andalso ?ERR(409, ?BUSY),
    Lease.

exclusive(Ref, Kind, Fun) ->
    Lease = #{<<"token">> := Token} = acquire(Ref, Kind),
    try
        Fun(Lease)
    after
        _ = case Kind of
                command -> lease_cas(Ref, #{<<"token">> => Token}, #{<<"executorDone">> => true});
                _ -> ok
            end,
        _ = lease_cas(Ref, #{<<"token">> => Token, <<"stopping">> => false},
                      #{<<"expiresAt">> => 0}),
        release_stopped(Ref, Token)
    end.

release_stopped(Ref, Token) ->
    _ = lease_cas(Ref,
                  #{<<"token">> => Token, <<"stopping">> => true, <<"stopConfirmed">> => true,
                    <<"executorDone">> => true, <<"stopInFlight">> => false},
                  #{<<"expiresAt">> => 0}),
    ok.

stopping_patch(Attempt) ->
    #{<<"stopping">> => true, <<"stopInFlight">> => true, <<"stopAttempt">> => Attempt,
      <<"stopConfirmed">> => false, <<"expiresAt">> => now_ms() + ?LEASE_MS}.

do_stop(Ref) ->
    enabled(),
    Lease = case get_lease(Ref) of
                Current = #{<<"operation">> := Op, <<"stopping">> := Stopping,
                            <<"stopInFlight">> := InFlight} ->
                    case live(Current) of
                        false ->
                            acquire(Ref, operation);
                        true when (Op =/= <<"command">> andalso not Stopping) orelse InFlight ->
                            ?ERR(409, <<"Computer is busy with another operation. "
                                        "Try Stop again shortly.">>);
                        true ->
                            Current
                    end;
                _ ->
                    acquire(Ref, operation)
            end,
    #{<<"token">> := Token} = Lease,
    Attempt = muse_ids:uuid(),
    Expected = maps:with([<<"token">>, <<"stopping">>, <<"stopAttempt">>], Lease),
    lease_cas(Ref, Expected, stopping_patch(Attempt)) =:= undefined
        andalso ?ERR(409, <<"Computer is busy with another Stop request">>),
    try
        Kind = receipts(),
        _ = [muse_store:cas(owner(Ref), Kind, Id, #{<<"status">> => <<"running">>},
                            #{<<"status">> => <<"interrupted">>,
                              <<"completedAt">> => muse_time:now_iso(),
                              <<"stderr">> => <<"Stopped by the user. Inspect the workspace "
                                                "before repeating this command.">>})
             || R = #{<<"id">> := Id, <<"status">> := <<"running">>} <- muse_store:list(owner(Ref), Kind),
                belongs(Ref, R)],
        unwrap((backend()):stop(Ref)),
        _ = lease_cas(Ref, #{<<"token">> => Token, <<"stopAttempt">> => Attempt},
                      #{<<"stopInFlight">> => false, <<"stopConfirmed">> => true}),
        release_stopped(Ref, Token)
    catch
        Class:Reason:Stack ->
            _ = lease_cas(Ref, #{<<"token">> => Token, <<"stopAttempt">> => Attempt},
                          #{<<"stopInFlight">> => false, <<"stopConfirmed">> => false}),
            erlang:raise(Class, Reason, Stack)
    end.

%% Receipts

commands(Ref) ->
    Kind = receipts(),
    All = [C || C <- muse_store:list(owner(Ref), Kind), belongs(Ref, C)],
    Checked = case live(get_lease(Ref)) of
                  true -> All;
                  false -> [recover(Ref, Kind, C) || C <- All]
              end,
    Sorted = lists:sort(fun(A, B) -> started(A) >= started(B) end, Checked),
    lists:sublist(Sorted, 100).

recover(Ref, Kind, C = #{<<"id">> := Id, <<"status">> := <<"running">>}) ->
    Patch = #{<<"status">> => <<"interrupted">>,
              <<"completedAt">> => muse_time:now_iso(),
              <<"stderr">> => <<"Execution was interrupted. Its outcome is unknown; "
                                "inspect files before running it again.">>},
    case muse_store:cas(owner(Ref), Kind, Id, #{<<"status">> => <<"running">>}, Patch) of
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

do_execute(Ref, Raw, Key, Cancel) ->
    enabled(),
    #{<<"command">> := Command, <<"cwd">> := Cwd0} =
        unwrap(muse_validate:parse(command_schema(), command_args(Raw))),
    Cwd = ws_path(Cwd0),
    Id = case Key of
             undefined -> muse_ids:uuid();
             _ -> muse_ids:sha256hex(<<"computer-command:", Key/binary>>)
         end,
    Kind = receipts(),
    case muse_store:get(owner(Ref), Kind, Id) of
        undefined ->
            exclusive(Ref, command,
                      fun(Lease) -> used(Ref), run_command(Ref, Kind, Id, Command, Cwd, Cancel, Lease) end);
        Previous = #{<<"command">> := Command, <<"cwd">> := Cwd} ->
            belongs(Ref, Previous)
                orelse ?ERR(409, <<"This operation ID already belongs to a different command">>),
            _ = commands(Ref),
            case muse_store:get(owner(Ref), Kind, Id) of
                undefined -> Previous;
                Fresh -> Fresh
            end;
        _ ->
            ?ERR(409, <<"This operation ID already belongs to a different command">>)
    end.

run_command(Ref, Kind, Id, Command, Cwd, Cancel, Lease) ->
    Backend = backend(),
    Session = unwrap(Backend:running(Ref)),
    lists:any(fun(P) -> not is_process_alive(P) end, Cancel)
        andalso ?ERR(409, <<"Computer command was interrupted before execution">>),
    Receipt = tag(Ref, #{<<"id">> => Id, <<"command">> => Command, <<"cwd">> => Cwd,
                         <<"status">> => <<"running">>, <<"stdout">> => <<>>, <<"stderr">> => <<>>,
                         <<"truncated">> => false, <<"startedAt">> => muse_time:now_iso()}),
    case muse_store:insert_if_absent(owner(Ref), Kind, Receipt) of
        undefined ->
            case muse_store:get(owner(Ref), Kind, Id) of
                undefined -> ?ERR(500, <<"Computer receipt could not be saved">>);
                Existing -> Existing
            end;
        _ ->
            #{<<"token">> := Token} = Lease,
            case get_lease(Ref) of
                Active = #{<<"token">> := Token, <<"stopping">> := false} ->
                    case live(Active) of
                        true -> run_receipt(Ref, Kind, Receipt, Session, Cancel, Token);
                        false -> stopped_before(Ref, Kind, Receipt)
                    end;
                _ ->
                    stopped_before(Ref, Kind, Receipt)
            end
    end.

stopped_before(Ref, Kind, Receipt = #{<<"id">> := Id}) ->
    Patch = #{<<"status">> => <<"interrupted">>,
              <<"stderr">> => <<"Stopped before execution">>,
              <<"completedAt">> => muse_time:now_iso()},
    case muse_store:cas(owner(Ref), Kind, Id, #{<<"status">> => <<"running">>}, Patch) of
        undefined ->
            case muse_store:get(owner(Ref), Kind, Id) of
                undefined -> maps:merge(Receipt, Patch);
                Stored -> Stored
            end;
        Preserved ->
            Preserved
    end.

run_receipt(Ref, Kind, Receipt = #{<<"id">> := Id}, Session, Cancel, Token) ->
    case muse_store:get(owner(Ref), Kind, Id) of
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
                         true -> cleanup(Ref, Backend, Session, Token, Result0);
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
            case muse_store:cas(owner(Ref), Kind, Id, #{<<"status">> => <<"running">>}, Final) of
                undefined ->
                    StoredErr = case muse_store:get(owner(Ref), Kind, Id) of
                                    #{<<"stderr">> := E} when is_binary(E) -> E;
                                    _ -> <<>>
                                end,
                    Joined = lists:join(<<"\n">>, [S || S <- [Stderr, StoredErr], S =/= <<>>]),
                    muse_store:put(owner(Ref), Kind,
                                   Final#{<<"status">> => <<"interrupted">>,
                                          <<"stderr">> => iolist_to_binary(Joined)});
                Finished ->
                    Finished
            end
    end.

%% A lost docker client cannot cancel exec reliably: stop the whole sandbox.
cleanup(Ref, Backend, Session, Token, Result = #{stderr := Stderr}) ->
    Attempt = muse_ids:uuid(),
    case lease_cas(Ref, #{<<"token">> => Token, <<"stopping">> => false},
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
            _ = lease_cas(Ref, Expected, #{<<"stopInFlight">> => false,
                                             <<"stopConfirmed">> => Stopped}),
            case Stopped of
                true -> Result;
                false -> Result#{stderr := <<Stderr/binary, "\nCould not confirm the computer "
                                             "stopped. It remains locked; retry Stop after "
                                             "checking the computer provider.">>}
            end
    end.

%% Files

file_op(Ref, Op, RawPath, Text, Base64) ->
    file_op(Ref, Op, RawPath, Text, Base64, []).

file_op(Ref, Op, RawPath, Text, Base64, Extra) ->
    Path = ws_path(RawPath),
    is_binary(Text) andalso byte_size(Text) > ?FILE_LIMIT
        andalso ?ERR(413, <<"Text files must be 256 KB or smaller">>),
    exclusive(Ref, operation,
              fun(_) ->
                      enabled(),
                      used(Ref),
                      Backend = backend(),
                      Session = unwrap(Backend:running(Ref)),
                      Input = muse_json:encode({obj, [{<<"operation">>, Op}, {<<"path">>, Path},
                                                      {<<"text">>, Text},
                                                      {<<"base64">>, Base64} | Extra]}),
                      {Max, Expected} = case Op of
                                            <<"read_pdf">> -> {15 * ?MIB, 15 * ?MIB};
                                            <<"read_file">> -> {15 * ?MIB, 15 * ?MIB};
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
