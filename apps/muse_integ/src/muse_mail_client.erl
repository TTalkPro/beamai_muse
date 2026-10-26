%% @doc IMAP and SMTP through the Node port program `sidecars/mail/index.mjs'
%% (imapflow, mailparser, nodemailer; designs/04-integrations.md §7).
%%
%% Why a sidecar: mail is mostly MIME and charsets (GBK and Big5 bodies,
%% RFC 2047 headers, quoted-printable, nested multiparts, HTML-only mail
%% that needs a text version) and a resilient IMAP client (literals, IDLE,
%% CONDSTORE, server quirks). The three Node libraries are the maintained
%% reference implementations of exactly that; OTP has no charset tables
%% beyond UTF-8/Latin-1, and gen_smtp would cover sending only. The cost is
%% a Node process, which the PDF helper already requires.
%%
%% One gen_server owns one long-lived port, spawned on first use (a node
%% without `node' still boots; calls then fail with code `unavailable').
%% Requests are multiplexed: the caller encodes its frame with a unique
%% `id', the server writes it to the port and keeps `{From, Timer}'; the
%% reply frame goes back to the caller undecoded (only its `{"id":N' prefix
%% is read here), so large message batches are decoded in the calling
%% process and the server never blocks. Each request has its own deadline;
%% on expiry the caller gets `timeout' (with `definite => false' for a send)
%% and the sidecar is told to drop that account's connection. If the port
%% dies, every caller in flight gets `unavailable' and every watch `closed';
%% the next request starts a new port.
%%
%% Watches (IMAP IDLE on one folder) send `{muse_mail_watch, WatchId,
%% Kind}' to the registered process (Kind `exists | expunge | flags |
%% closed'); a watch ends when that process exits.
%%
%% The command is `muse_config:get(mail_sidecar)' (MAIL_SIDECAR, default
%% `node sidecars/mail/index.mjs'), started like the PDF helper
%% (muse_pdf:sidecar_port/2) with a scrubbed environment; the account
%% passwords travel only inside request frames.
-module(muse_mail_client).
-behaviour(gen_server).

-export([start_link/0, request/3, watch/4, unwatch/1, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_CMD, <<"node sidecars/mail/index.mjs">>).
%% CA settings a deployment may need for its mail servers
-define(KEEP_ENV, ["NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR"]).

-type error() :: #{code := binary(), message := binary(), definite => boolean()}.
-export_type([error/0]).

-record(state, {port :: port() | undefined,
                os_pid :: integer() | undefined,
                pending = #{} :: #{integer() => {gen_server:from(), reference(), binary() | undefined, binary()}},
                watches = #{} :: #{binary() => {pid(), reference()}}}).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Run `Op' with `Args' (a map; `account' is the sidecar account) and
%% wait at most `Timeout' ms.
-spec request(binary(), map(), pos_integer()) -> {ok, map()} | {error, error()}.
request(Op, Args, Timeout) ->
    Id = erlang:unique_integer([positive]),
    Frame = muse_json:encode(Args#{<<"id">> => Id, <<"op">> => Op}),
    AccountId = case Args of
                    #{<<"account">> := #{<<"id">> := A}} -> A;
                    _ -> undefined
                end,
    case catch gen_server:call(?MODULE, {request, Id, Op, AccountId, Frame, Timeout}, Timeout + 5000) of
        {reply, Data} -> decode(Id, Data);
        {error, #{} = E} -> {error, E};
        {'EXIT', _} -> {error, err(<<"unavailable">>, <<"Mail helper did not answer">>, Op)}
    end.

%% @doc IDLE on `Path' of `Account'; events go to `Pid' until it exits or
%% `unwatch/1'.
-spec watch(binary(), map(), binary(), pid()) -> {ok, map()} | {error, error()}.
watch(WatchId, Account, Path, Pid) ->
    ok = gen_server:call(?MODULE, {watch_register, WatchId, Pid}),
    case request(<<"watch">>, #{<<"watchId">> => WatchId, <<"account">> => Account, <<"path">> => Path}, 60000) of
        {ok, _} = Ok -> Ok;
        Error -> unwatch(WatchId), Error
    end.

-spec unwatch(binary()) -> ok.
unwatch(WatchId) ->
    gen_server:cast(?MODULE, {unwatch, WatchId}).

%% @doc Stop the port (tests switch MAIL_SIDECAR with it); the next request
%% starts a new one.
-spec reset() -> ok.
reset() ->
    gen_server:call(?MODULE, reset).

decode(Id, Data) ->
    case muse_json:decode(Data) of
        {ok, #{<<"id">> := Id, <<"ok">> := Ok}} when is_map(Ok) -> {ok, Ok};
        {ok, #{<<"id">> := Id, <<"error">> := #{<<"code">> := C} = E}} ->
            Msg = case maps:get(<<"message">>, E, <<>>) of
                      M when is_binary(M) -> M;
                      _ -> <<>>
                  end,
            Base = #{code => C, message => Msg},
            {error, case maps:get(<<"definite">>, E, undefined) of
                        D when is_boolean(D) -> Base#{definite => D};
                        _ -> Base
                    end};
        _ ->
            {error, #{code => <<"error">>, message => <<"Mail helper returned an invalid response">>}}
    end.

err(Code, Msg, Op) ->
    E = #{code => Code, message => Msg},
    case Op of
        <<"send">> -> E#{definite => false};
        _ -> E
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

-spec init([]) -> {ok, #state{}}.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {noreply, #state{}} | {reply, term(), #state{}}.
handle_call({request, Id, Op, AccountId, Frame, Timeout}, From, State0) ->
    case ensure_port(State0) of
        {ok, State = #state{port = Port, pending = P}} ->
            true = port_command(Port, Frame),
            TRef = erlang:start_timer(Timeout, self(), {request, Id}),
            {noreply, State#state{pending = P#{Id => {From, TRef, AccountId, Op}}}};
        {error, State} ->
            {reply, {error, err(<<"unavailable">>, <<"Mail helper is unavailable">>, Op)}, State}
    end;
handle_call({watch_register, WatchId, Pid}, _From, State = #state{watches = W}) ->
    W1 = case maps:take(WatchId, W) of
             {{_, Old}, Rest} -> erlang:demonitor(Old, [flush]), Rest;
             error -> W
         end,
    {reply, ok, State#state{watches = W1#{WatchId => {Pid, erlang:monitor(process, Pid)}}}};
handle_call(reset, _From, State) ->
    {reply, ok, drop_port(State, <<"Mail helper restarted">>)};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({unwatch, WatchId}, State) ->
    {noreply, stop_watch(WatchId, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info({Port, {data, Data}}, State = #state{port = Port}) ->
    {noreply, incoming(Data, State)};
handle_info({Port, {exit_status, _}}, State = #state{port = Port}) ->
    logger:warning("muse_mail_client: mail sidecar exited"),
    {noreply, drop_port(State, <<"Mail helper exited unexpectedly">>)};
handle_info({timeout, TRef, {request, Id}}, State = #state{pending = P}) ->
    case maps:take(Id, P) of
        {{From, TRef, AccountId, Op}, Rest} ->
            gen_server:reply(From, {error, err(<<"timeout">>, <<"The mail server did not answer in time">>, Op)}),
            %% a wedged connection would hold up the account's next requests
            _ = AccountId =/= undefined andalso
                send_frame(State, #{<<"id">> => 0, <<"op">> => <<"close">>, <<"accountId">> => AccountId}),
            {noreply, State#state{pending = Rest}};
        _ ->
            {noreply, State}
    end;
handle_info({'DOWN', MRef, process, _, _}, State = #state{watches = W}) ->
    case [Id || Id := {_, M} <- W, M =:= MRef] of
        [WatchId] -> {noreply, stop_watch(WatchId, State)};
        [] -> {noreply, State}
    end;
handle_info({'EXIT', _, _}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, State) ->
    _ = drop_port(State, <<"Mail helper stopped">>),
    ok.

%%%===================================================================
%%% Internals
%%%===================================================================

incoming(<<"{\"id\":", Rest/binary>> = Data, State = #state{pending = P}) ->
    case string:to_integer(Rest) of
        {Id, _} when is_integer(Id) ->
            case maps:take(Id, P) of
                {{From, TRef, _, _}, P1} ->
                    _ = erlang:cancel_timer(TRef),
                    gen_server:reply(From, {reply, Data}),
                    State#state{pending = P1};
                error ->
                    State
            end;
        _ ->
            State
    end;
incoming(Data, State = #state{watches = W}) ->
    case muse_json:decode(Data) of
        {ok, #{<<"event">> := <<"watch">>, <<"watchId">> := WatchId, <<"kind">> := Kind}} ->
            _ = case maps:get(WatchId, W, undefined) of
                    {Pid, _} -> Pid ! {muse_mail_watch, WatchId, kind(Kind)};
                    undefined -> ok
                end,
            State;
        _ ->
            State
    end.

kind(<<"exists">>) -> exists;
kind(<<"expunge">>) -> expunge;
kind(<<"flags">>) -> flags;
kind(_) -> closed.

stop_watch(WatchId, State = #state{watches = W}) ->
    case maps:take(WatchId, W) of
        {{_, MRef}, Rest} ->
            erlang:demonitor(MRef, [flush]),
            _ = send_frame(State, #{<<"id">> => 0, <<"op">> => <<"unwatch">>, <<"watchId">> => WatchId}),
            State#state{watches = Rest};
        error ->
            State
    end.

send_frame(#state{port = Port}, Map) when is_port(Port) ->
    catch port_command(Port, muse_json:encode(Map));
send_frame(_, _) ->
    ok.

ensure_port(State = #state{port = Port}) when is_port(Port) ->
    {ok, State};
ensure_port(State) ->
    try muse_pdf:sidecar_port(muse_config:get(mail_sidecar, ?DEFAULT_CMD), ?KEEP_ENV) of
        Port ->
            OsPid = case erlang:port_info(Port, os_pid) of
                        {os_pid, P} -> P;
                        undefined -> undefined
                    end,
            {ok, State#state{port = Port, os_pid = OsPid}}
    catch
        error:Reason ->
            logger:warning("muse_mail_client: cannot start the mail sidecar: ~p", [Reason]),
            {error, State}
    end.

drop_port(State = #state{port = Port, os_pid = OsPid, pending = P, watches = W}, Msg) ->
    _ = case is_port(Port) of
            true ->
                _ = is_integer(OsPid) andalso sigkill(OsPid),
                catch port_close(Port);
            false -> ok
        end,
    maps:foreach(fun(_, {From, TRef, _, Op}) ->
                         _ = erlang:cancel_timer(TRef),
                         gen_server:reply(From, {error, err(<<"unavailable">>, Msg, Op)})
                 end, P),
    maps:foreach(fun(WatchId, {Pid, MRef}) ->
                         erlang:demonitor(MRef, [flush]),
                         Pid ! {muse_mail_watch, WatchId, closed}
                 end, W),
    State#state{port = undefined, os_pid = undefined, pending = #{}, watches = #{}}.

sigkill(OsPid) ->
    case os:find_executable("kill") of
        false -> ok;
        Kill ->
            P = open_port({spawn_executable, Kill}, [{args, ["-9", integer_to_list(OsPid)]}, exit_status]),
            receive {P, {exit_status, _}} -> ok after 2000 -> catch port_close(P), ok end
    end.
