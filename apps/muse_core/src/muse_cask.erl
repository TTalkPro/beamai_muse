%% @doc Owner of one bitcask directory (designs/01-store.md §2).
%%
%% bitcask allows a single writer per directory, so every write goes through
%% this gen_server. Reads and searches use the shared handle directly
%% (`handle/1`, kept in persistent_term); bitcask handles are safe to share
%% between reader processes.
%%
%% Ordered logs use `append/3`: the server stamps each entry with a strictly
%% increasing 20-digit sequence (microseconds, bumped on collision), so keys
%% under one prefix sort by write order and survive restarts.
-module(muse_cask).
-behaviour(gen_server).

-export([start_link/3, handle/1, dir/1,
         put/3, delete/2, commit/2, append/3,
         range_prefix/2, keys_prefix/2, prefix_end/1, seq/1,
         stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MERGE_CHECK_MS, 3600 * 1000).

-type name() :: atom().
-type op() :: {put, binary(), binary() | map()} | {remove, binary()}.

-spec start_link(name(), file:filename_all(), list()) -> {ok, pid()} | {error, term()}.
start_link(Name, Dir, Opts) ->
    gen_server:start_link({local, server(Name)}, ?MODULE, {Name, Dir, Opts}, []).

-spec stop(name()) -> ok.
stop(Name) ->
    gen_server:stop(server(Name)).

-spec handle(name()) -> term().
handle(Name) ->
    persistent_term:get({?MODULE, Name}).

-spec dir(name()) -> binary().
dir(Name) ->
    persistent_term:get({?MODULE, Name, dir}).

-spec put(name(), binary(), binary() | map()) -> ok | {error, term()}.
put(Name, Key, Value) ->
    gen_server:call(server(Name), {commit, [{put, Key, Value}], no_sync}).

-spec delete(name(), binary()) -> ok | {error, term()}.
delete(Name, Key) ->
    gen_server:call(server(Name), {delete, Key}).

%% @doc Atomic batch (all or nothing after a crash). Duplicate keys allowed;
%% the last one wins.
-spec commit(name(), [op()]) -> ok | {error, term()}.
commit(_Name, []) ->
    ok;
commit(Name, Ops) ->
    gen_server:call(server(Name), {commit, Ops, no_sync}).

%% @doc Allocate the next sequence and write `OpsFun(Seq)` atomically.
%% `Seq` is the 20-digit zero-padded binary to put in keys.
-spec append(name(), fun((binary()) -> [op()]), sync | no_sync) -> {ok, binary()} | {error, term()}.
append(Name, OpsFun, Sync) ->
    gen_server:call(server(Name), {append, OpsFun, Sync}).

%% @doc `[{Key, Value}]` for every key starting with `Prefix`, in key order.
-spec range_prefix(name(), binary()) -> [{binary(), term()}].
range_prefix(Name, Prefix) ->
    case bitcask:range(handle(Name), {Prefix, prefix_end(Prefix)}) of
        List when is_list(List) -> List;
        {error, Reason} -> error({cask_range, Name, Reason})
    end.

-spec keys_prefix(name(), binary()) -> [binary()].
keys_prefix(Name, Prefix) ->
    Fun = fun(K, _V, _Ts, _Ord, Acc) -> [K | Acc] end,
    case bitcask:range_fold(handle(Name), {Prefix, prefix_end(Prefix)}, [], Fun, []) of
        Keys when is_list(Keys) -> lists:reverse(Keys);
        {error, Reason} -> error({cask_range, Name, Reason})
    end.

%% @doc Exclusive upper bound of a prefix scan: the prefix with its last
%% byte incremented (trailing 0xFF bytes dropped).
-spec prefix_end(binary()) -> binary() | undefined.
prefix_end(<<>>) ->
    undefined;
prefix_end(Prefix) ->
    Size = byte_size(Prefix) - 1,
    <<Head:Size/binary, Last>> = Prefix,
    case Last of
        255 -> prefix_end(Head);
        _ -> <<Head/binary, (Last + 1)>>
    end.

-spec seq(integer()) -> binary().
seq(N) ->
    iolist_to_binary(io_lib:format("~20..0B", [N])).

%% gen_server

init({Name, Dir, Opts}) ->
    process_flag(trap_exit, true),
    DirBin = unicode:characters_to_binary(Dir),
    ok = filelib:ensure_path(DirBin),
    case bitcask:open(binary_to_list(DirBin), [read_write | Opts]) of
        {error, Reason} ->
            {stop, {cask_open_failed, Name, Reason}};
        Handle ->
            persistent_term:put({?MODULE, Name}, Handle),
            persistent_term:put({?MODULE, Name, dir}, DirBin),
            erlang:send_after(?MERGE_CHECK_MS, self(), merge_check),
            {ok, #{name => Name, dir => DirBin, handle => Handle,
                   last => 0, merging => undefined}}
    end.

handle_call({commit, Ops, Sync}, _From, #{handle := H} = State) ->
    {reply, txn(H, Ops, Sync), State};
handle_call({delete, Key}, _From, #{handle := H} = State) ->
    {reply, bitcask:delete(H, Key), State};
handle_call({append, OpsFun, Sync}, _From, #{handle := H, last := Last} = State) ->
    N = max(erlang:system_time(microsecond), Last + 1),
    Seq = seq(N),
    Reply = try OpsFun(Seq) of
                Ops ->
                    case txn(H, Ops, Sync) of
                        ok -> {ok, Seq};
                        Error -> Error
                    end
            catch
                Class:Reason -> {error, {Class, Reason}}
            end,
    {reply, Reply, State#{last := N}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(merge_check, #{handle := H, dir := Dir, merging := undefined} = State) ->
    erlang:send_after(?MERGE_CHECK_MS, self(), merge_check),
    case bitcask:needs_merge(H) of
        {true, _} ->
            Pid = spawn_link(fun() -> _ = bitcask:merge(binary_to_list(Dir)) end),
            {noreply, State#{merging := Pid}};
        false ->
            {noreply, State}
    end;
handle_info(merge_check, State) ->
    erlang:send_after(?MERGE_CHECK_MS, self(), merge_check),
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, #{merging := Pid, name := Name} = State) ->
    Reason =:= normal orelse logger:warning("bitcask merge of ~p failed: ~p", [Name, Reason]),
    {noreply, State#{merging := undefined}};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #{name := Name, handle := H}) ->
    _ = bitcask:sync(H),
    _ = bitcask:close(H),
    _ = persistent_term:erase({?MODULE, Name}),
    _ = persistent_term:erase({?MODULE, Name, dir}),
    ok.

%% Internal

server(Name) ->
    list_to_atom("muse_cask_" ++ atom_to_list(Name)).

txn(H, Ops, sync) -> bitcask:txn_commit(H, Ops, sync_on_commit);
txn(H, Ops, no_sync) -> bitcask:put_batch_atomic(H, Ops).
