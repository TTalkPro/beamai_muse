%% Helpers of the live-view tests (muse_vnc_handler): `muse_docker:stream/1`
%% replaced by a shell that greets like an RFB server and then echoes, and a
%% gun WebSocket client.
-module(muse_vnc_test).
-include_lib("stdlib/include/assert.hrl").

-export([fake_stream/0, streams/0, connect/3, expect_bytes/3, send/3, close/2]).

-define(KEY, {?MODULE, streams}).

%% @doc Mock `muse_docker:stream/1` (muse_docker must be mecked already):
%% each call is recorded and runs `printf 'RFB 003.008\n'; exec cat`.
fake_stream() ->
    persistent_term:put(?KEY, []),
    meck:expect(muse_docker, stream,
                fun(Args) ->
                        persistent_term:put(?KEY, persistent_term:get(?KEY, []) ++ [Args]),
                        {ok, _, OsPid} = exec:run_link(["/bin/sh", "-c", "printf 'RFB 003.008\\n'; exec cat"],
                                                       [stdin, {stdout, self()}, {stderr, null}, monitor]),
                        {ok, OsPid}
                end).

%% @doc The argv of every stream started so far.
streams() -> persistent_term:get(?KEY, []).

%% @doc Open a WebSocket: `{ok, Conn, Ref}` once upgraded, `{status, N}`
%% when the handshake is answered with an HTTP status.
connect(Port, Path, Headers) ->
    {ok, Conn} = gun:open("localhost", Port, #{protocols => [http], retry => 0}),
    {ok, http} = gun:await_up(Conn, 5000),
    Ref = gun:ws_upgrade(Conn, Path, Headers),
    receive
        {gun_upgrade, Conn, Ref, [<<"websocket">>], _} -> {ok, Conn, Ref};
        {gun_response, Conn, Ref, _, Status, _} -> gun:close(Conn), {status, Status}
    after 10000 -> error(ws_timeout)
    end.

%% @doc Receive binary frames until exactly `Want` arrived.
expect_bytes(Conn, Ref, Want) ->
    expect_bytes(Conn, Ref, Want, <<>>).

expect_bytes(_Conn, _Ref, Want, Want) -> ok;
expect_bytes(Conn, Ref, Want, Got) when byte_size(Got) < byte_size(Want) ->
    receive
        {gun_ws, Conn, Ref, {binary, Data}} -> expect_bytes(Conn, Ref, Want, <<Got/binary, Data/binary>>);
        {gun_ws, Conn, Ref, ping} -> expect_bytes(Conn, Ref, Want, Got);
        {gun_ws, Conn, Ref, Other} -> error({unexpected_frame, Other, Got})
    after 10000 -> error({ws_timeout, Got})
    end;
expect_bytes(_Conn, _Ref, Want, Got) ->
    ?assertEqual(Want, Got).

send(Conn, Ref, Data) -> gun:ws_send(Conn, Ref, {binary, Data}).

close(Conn, Ref) ->
    gun:ws_send(Conn, Ref, close),
    gun:close(Conn).
