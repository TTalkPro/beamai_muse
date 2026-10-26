%% @doc Computer provider behaviour: OpenMuse `ComputerBackend` and
%% `ComputerSession` (computer-backend.ts; designs/ref/openmuse-integrations-spec.md
%% §6.3–§6.4; designs/04-integrations.md §3).
%%
%% `muse_computer` owns leases and receipts; a provider only manages the
%% sandboxes, one per computer of the pool (`muse_computer:ref()`). Errors
%% use the `{error, {HttpStatus, Message}}` contract.
-module(muse_computer_provider).

-export_type([state/0, session/0, error/0]).

-type state() :: missing | stopped | running.
%% Opaque to `muse_computer`; passed back to `exec/4`, `file/4`, `session_stop/1`.
-type session() :: term().
-type error() :: {error, {pos_integer(), binary()}}.

%% `<<"docker">>` (the only provider; OpenMuse's E2B desktop is not supported).
-callback provider() -> binary().
%% Record kind of the command receipts.
-callback receipts() -> binary().
-callback network() -> binary().
-callback state(Computer :: muse_computer:ref()) -> {ok, state()} | error().
-callback start(Computer :: muse_computer:ref()) -> ok | error().
-callback stop(Computer :: muse_computer:ref()) -> ok | error().
%% Removes the sandbox and its /workspace (the pool's delete; not in OpenMuse).
-callback remove(Computer :: muse_computer:ref()) -> ok | error().
%% A session on the running computer; 409 when it is not running.
-callback running(Computer :: muse_computer:ref()) -> {ok, session()} | error().
%% Runs a command; the provider applies its own timeouts. A dead `Cancel`
%% process interrupts it.
-callback exec(session(), Command :: binary(), Cwd :: binary(), Cancel :: [pid()]) ->
    muse_docker:result().
%% Runs files.py with `Input` on stdin.
-callback file(session(), Input :: binary(), Seconds :: pos_integer(),
               MaxOutputBytes :: pos_integer()) -> muse_docker:result().
-callback session_stop(session()) -> ok | error().
