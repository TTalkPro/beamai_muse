%% @doc Fixed-window rate limits (OpenMuse rate-limit.ts, spec §2.4).
%%
%% `api`: 120 requests per client per minute on `/api/*`, at most 10000
%% tracked clients (new clients are rejected while the table is full of live
%% windows). `login`: 30 sign-in attempts per client per minute. OpenMuse
%% keeps one global login counter; it is per client here on purpose
%% (designs/04-integrations.md §1), so one caller cannot lock everyone out.
%%
%% Rejected requests still count. The owning process only holds the tables.
-module(muse_rate_limit).
-behaviour(gen_server).

-export([start_link/0, take/2, take/3, client_key/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(WINDOW_MS, 60000).
-define(MAX_ENTRIES, 10000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec take(api | login, binary()) -> boolean().
take(Bucket, Key) ->
    take(Bucket, Key, muse_time:now_ms()).

-spec take(api | login, binary(), integer()) -> boolean().
take(Bucket, Key, Now) ->
    Table = table(Bucket),
    Count = case ets:lookup(Table, Key) of
                [{_, _, Expires}] when Expires > Now ->
                    ets:update_counter(Table, Key, {2, 1});
                _ ->
                    case room(Table, Now) of
                        true ->
                            ets:insert(Table, {Key, 1, Now + ?WINDOW_MS}),
                            1;
                        false ->
                            infinity
                    end
            end,
    Count =/= infinity andalso Count =< limit(Bucket).

%% @doc Client identity for limiting: the socket address, or the proxy's
%% forwarded address when TRUST_PROXY is set. Never the caller's credentials.
-spec client_key(boolean(), #{binary() => binary()}, inet:ip_address() | undefined) -> binary().
client_key(true, Headers, Peer) ->
    case maps:get(<<"x-forwarded-for">>, Headers, undefined) of
        Fwd when is_binary(Fwd) ->
            case string:trim(hd(binary:split(Fwd, <<",">>))) of
                <<>> -> real_ip(Headers, Peer);
                Ip -> <<"proxy:", Ip/binary>>
            end;
        undefined ->
            real_ip(Headers, Peer)
    end;
client_key(false, _Headers, Peer) ->
    conn(Peer).

%% gen_server

init([]) ->
    _ = ets:new(table(api), [named_table, public, set, {write_concurrency, true}]),
    _ = ets:new(table(login), [named_table, public, set, {write_concurrency, true}]),
    erlang:send_after(?WINDOW_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    Now = muse_time:now_ms(),
    _ = [sweep(table(B), Now) || B <- [api, login]],
    erlang:send_after(?WINDOW_MS, self(), sweep),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Internal

table(api) -> muse_rate_limit_api;
table(login) -> muse_rate_limit_login.

limit(api) -> 120;
limit(login) -> 30.

room(Table, Now) ->
    ets:info(Table, size) < ?MAX_ENTRIES orelse
        (sweep(Table, Now) > 0 andalso ets:info(Table, size) < ?MAX_ENTRIES).

sweep(Table, Now) ->
    ets:select_delete(Table, [{{'_', '_', '$1'}, [{'=<', '$1', Now}], [true]}]).

real_ip(Headers, Peer) ->
    case maps:get(<<"x-real-ip">>, Headers, undefined) of
        Ip when is_binary(Ip), Ip =/= <<>> -> <<"proxy:", Ip/binary>>;
        _ -> conn(Peer)
    end.

conn(undefined) -> <<"conn:unknown">>;
conn(Ip) -> <<"conn:", (list_to_binary(inet:ntoa(Ip)))/binary>>.
