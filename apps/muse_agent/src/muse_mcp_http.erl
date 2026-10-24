%% @doc Minimal MCP client for the streamable-HTTP transport, written on gun
%% (designs/03-agent.md §8, designs/ref/beamai-api-digest.md §6).
%%
%% Mirrors what `@modelcontextprotocol/sdk` 1.30 `Client` +
%% `StreamableHTTPClientTransport` put on the wire
%% (designs/ref/openmuse-integrations-spec.md §8): every message is a POST
%% with `Accept: application/json, text/event-stream`; the reply is either a
%% JSON body or an SSE stream whose `data:` lines carry JSON-RPC messages
%% (non-matching events such as notifications are skipped). `initialize` is
%% followed by `notifications/initialized`; later requests carry
%% `mcp-session-id` (when the server issued one) and `mcp-protocol-version`.
%% The SDK's optional standalone GET SSE stream is not opened.
%%
%% The gun connection is owned by the calling process: gun closes it when the
%% owner exits (after a 100 ms grace period instead of gun's 15 s), so a
%% killed caller never leaves it open. Call `close/1` when
%% done. TLS uses verify_peer, the system CA store, SNI and an HTTPS hostname
%% check. Redirects are refused.
-module(muse_mcp_http).

-export([open/2, request/3, notify/3, list_tools/1, call_tool/3, close/1,
         session_id/1, server_result/1, error_message/1]).

-export_type([conn/0, error/0]).

-define(PROTOCOL_VERSION, <<"2025-11-25">>).
-define(SUPPORTED_VERSIONS, [<<"2025-11-25">>, <<"2025-06-18">>, <<"2025-03-26">>,
                             <<"2024-11-05">>, <<"2024-10-07">>]).
-define(DEFAULT_TIMEOUT, 60000).
-define(DEFAULT_MAX_BODY, 4 * 1024 * 1024).
%% gun drains in-flight streams for this long after the owner dies (default 15 s).
-define(CLOSING_TIMEOUT, 100).

-type conn() :: #{pid := pid(),
                  path := binary(),
                  headers := [{binary(), binary()}],
                  session := binary() | undefined,
                  version := binary() | undefined,
                  timeout := non_neg_integer(),
                  deadline := integer() | infinity,
                  max_body := pos_integer() | infinity,
                  init := map()}.

-type error() :: timeout
               | too_large
               | {http, 100..599, binary()}
               | {redirect, 300..399}
               | {jsonrpc, integer(), binary(), term()}
               | {content_type, binary()}
               | {unsupported_protocol, term()}
               | {invalid_response, binary()}
               | {transport, term()}.

-type opts() :: #{headers => [{binary(), binary()}],
                  timeout => non_neg_integer(),
                  deadline => integer() | infinity,
                  max_body => pos_integer() | infinity,
                  client_info => map(),
                  protocol_version => binary()}.

%% @doc Connect and run the initialize handshake. `Opts`:
%% `headers` (extra request headers, e.g. authorization), `timeout` (ms per
%% call, default 60000), `deadline` (absolute `erlang:monotonic_time(millisecond)`
%% bounding every call), `max_body` (bytes per HTTP response, default 4 MiB),
%% `client_info`, `protocol_version` (default the SDK 1.30 latest, 2025-11-25).
-spec open(binary() | string(), opts()) -> {ok, conn()} | {error, error()}.
open(Url, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Deadline = maps:get(deadline, Opts, infinity),
    case parse_url(Url) of
        {ok, Host, Port, Path, Transport} ->
            Wait = remaining(call_deadline(Timeout, Deadline)),
            GunOpts = gun_opts(Host, Transport, Wait),
            case gun:open(binary_to_list(Host), Port, GunOpts) of
                {ok, Pid} ->
                    Conn = #{pid => Pid, path => Path,
                             headers => maps:get(headers, Opts, []),
                             session => undefined, version => undefined,
                             timeout => Timeout, deadline => Deadline,
                             max_body => maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
                             init => #{}},
                    case handshake(Conn, Wait, Opts) of
                        {ok, Conn1} -> {ok, Conn1};
                        Error -> close(Conn), Error
                    end;
                {error, Reason} ->
                    {error, {transport, Reason}}
            end;
        error ->
            {error, {transport, invalid_url}}
    end.

%% @doc JSON-RPC request; returns the `result` member.
-spec request(conn(), binary(), map()) -> {ok, term()} | {error, error()}.
request(Conn, Method, Params) ->
    Id = erlang:unique_integer([positive, monotonic]),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
            <<"method">> => Method, <<"params">> => Params},
    case post(Conn, Msg, Id) of
        {ok, Result, _Headers} -> {ok, Result};
        Error -> Error
    end.

%% @doc JSON-RPC notification (no reply expected beyond 2xx).
-spec notify(conn(), binary(), map()) -> ok | {error, error()}.
notify(Conn, Method, Params) ->
    Msg = case map_size(Params) of
              0 -> #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => Method};
              _ -> #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => Method, <<"params">> => Params}
          end,
    case post(Conn, Msg, undefined) of
        {ok, _, _} -> ok;
        Error -> Error
    end.

%% @doc `tools/list`, following `nextCursor` pages.
-spec list_tools(conn()) -> {ok, [map()]} | {error, error()}.
list_tools(Conn) ->
    list_tools(Conn, #{}, []).

%% @doc `tools/call`; returns the raw CallToolResult (check `isError`).
-spec call_tool(conn(), binary(), map()) -> {ok, map()} | {error, error()}.
call_tool(Conn, Name, Args) ->
    case request(Conn, <<"tools/call">>, #{<<"name">> => Name, <<"arguments">> => Args}) of
        {ok, #{} = Result} -> {ok, Result};
        {ok, _} -> {error, {invalid_response, <<"tools/call result is not an object">>}};
        Error -> Error
    end.

-spec close(conn()) -> ok.
close(#{pid := Pid}) ->
    _ = gun:close(Pid),
    ok.

-spec session_id(conn()) -> binary() | undefined.
session_id(#{session := S}) -> S.

%% @doc The server's initialize result (protocolVersion, capabilities, serverInfo).
-spec server_result(conn()) -> map().
server_result(#{init := Init}) -> Init.

%% @doc Human-readable message, worded like the TypeScript SDK's errors.
-spec error_message(error()) -> binary().
error_message(timeout) ->
    <<"MCP error -32001: Request timed out">>;
error_message(too_large) ->
    <<"Response exceeded the size limit">>;
error_message({http, Status, Body}) ->
    iolist_to_binary(["Streamable HTTP error: Error POSTing to endpoint: ",
                      case Body of <<>> -> integer_to_binary(Status); _ -> Body end]);
error_message({redirect, Status}) ->
    iolist_to_binary(["Redirect refused (HTTP ", integer_to_binary(Status), ")"]);
error_message({jsonrpc, Code, Message, _}) ->
    iolist_to_binary(["MCP error ", integer_to_binary(Code), ": ", Message]);
error_message({content_type, CT}) ->
    <<"Streamable HTTP error: Unexpected content type: ", CT/binary>>;
error_message({unsupported_protocol, V}) ->
    iolist_to_binary(["Server's protocol version is not supported: ",
                      case V of B when is_binary(B) -> B; _ -> <<"undefined">> end]);
error_message({invalid_response, Why}) ->
    <<"Invalid MCP response: ", Why/binary>>;
error_message({transport, _}) ->
    <<"fetch failed">>.

%% Internal

handshake(Conn, Wait, Opts) ->
    case gun:await_up(maps:get(pid, Conn), Wait) of
        {ok, _Protocol} ->
            Params = #{<<"protocolVersion">> => maps:get(protocol_version, Opts, ?PROTOCOL_VERSION),
                       <<"capabilities">> => #{},
                       <<"clientInfo">> => maps:get(client_info, Opts,
                                                    #{<<"name">> => <<"beamai_muse">>,
                                                      <<"version">> => <<"0.1.0">>})},
            Id = erlang:unique_integer([positive, monotonic]),
            Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                    <<"method">> => <<"initialize">>, <<"params">> => Params},
            case post(Conn, Msg, Id) of
                {ok, #{<<"protocolVersion">> := V} = Init, Headers} ->
                    case lists:member(V, ?SUPPORTED_VERSIONS) of
                        true ->
                            Conn1 = Conn#{session => header(<<"mcp-session-id">>, Headers),
                                          version => V, init => Init},
                            case notify(Conn1, <<"notifications/initialized">>, #{}) of
                                ok -> {ok, Conn1};
                                Error -> Error
                            end;
                        false ->
                            {error, {unsupported_protocol, V}}
                    end;
                {ok, Other, _} when is_map(Other) ->
                    {error, {unsupported_protocol, maps:get(<<"protocolVersion">>, Other, undefined)}};
                {ok, _, _} ->
                    {error, {invalid_response, <<"initialize result is not an object">>}};
                Error ->
                    Error
            end;
        {error, timeout} ->
            {error, timeout};
        {error, Reason} ->
            {error, {transport, Reason}}
    end.

list_tools(Conn, Params, Acc) ->
    case request(Conn, <<"tools/list">>, Params) of
        {ok, #{<<"tools">> := Tools} = R} when is_list(Tools) ->
            case maps:get(<<"nextCursor">>, R, null) of
                Cursor when is_binary(Cursor) ->
                    list_tools(Conn, #{<<"cursor">> => Cursor}, [Tools | Acc]);
                _ ->
                    {ok, lists:append(lists:reverse([Tools | Acc]))}
            end;
        {ok, _} ->
            {error, {invalid_response, <<"tools/list result has no tools">>}};
        Error ->
            Error
    end.

%% POST one message. Id =:= undefined for notifications.
post(#{pid := Pid, path := Path} = Conn, Msg, Id) ->
    Deadline = call_deadline(maps:get(timeout, Conn), maps:get(deadline, Conn)),
    Stream = gun:post(Pid, Path, request_headers(Conn), muse_json:encode(Msg)),
    case await(Pid, Stream, Deadline) of
        {response, IsFin, Status, Headers} when Status >= 200, Status < 300 ->
            reply(Conn, Pid, Stream, IsFin, Headers, Id, Deadline);
        {response, IsFin, Status, _} when Status >= 300, Status < 400 ->
            discard(Pid, Stream, IsFin),
            {error, {redirect, Status}};
        {response, fin, Status, _} ->
            {error, {http, Status, <<>>}};
        {response, nofin, Status, _} ->
            case body(Pid, Stream, Deadline, maps:get(max_body, Conn), <<>>) of
                {ok, Body} -> {error, {http, Status, Body}};
                Error -> Error
            end;
        Error ->
            Error
    end.

reply(_Conn, Pid, Stream, IsFin, Headers, undefined, _Deadline) ->
    discard(Pid, Stream, IsFin),
    {ok, undefined, Headers};
reply(_Conn, _Pid, _Stream, fin, _Headers, _Id, _Deadline) ->
    {error, {invalid_response, <<"empty response body">>}};
reply(Conn, Pid, Stream, nofin, Headers, Id, Deadline) ->
    Max = maps:get(max_body, Conn),
    CT = header(<<"content-type">>, Headers),
    case media_type(CT) of
        <<"text/event-stream">> ->
            with_headers(sse(Pid, Stream, Deadline, Max, Id, <<>>, 0), Headers);
        <<"application/json">> ->
            case body(Pid, Stream, Deadline, Max, <<>>) of
                {ok, Body} -> with_headers(json_reply(Body, Id), Headers);
                Error -> Error
            end;
        _ ->
            _ = gun:cancel(Pid, Stream),
            {error, {content_type, case CT of undefined -> <<"null">>; _ -> CT end}}
    end.

with_headers({ok, Result}, Headers) -> {ok, Result, Headers};
with_headers(Error, _) -> Error.

json_reply(Body, Id) ->
    case muse_json:decode(Body) of
        {ok, Msgs} when is_list(Msgs) -> find_reply(Msgs, Id);
        {ok, Msg} -> find_reply([Msg], Id);
        {error, _} -> {error, {invalid_response, <<"response body is not JSON">>}}
    end.

find_reply([], _Id) ->
    {error, {invalid_response, <<"no response for the request id">>}};
find_reply([Msg | Rest], Id) ->
    case match(Msg, Id) of
        nomatch -> find_reply(Rest, Id);
        Result -> Result
    end.

match(#{<<"id">> := Id, <<"error">> := #{<<"code">> := Code} = E}, Id) when is_integer(Code) ->
    Message = case maps:get(<<"message">>, E, <<>>) of
                  M when is_binary(M) -> M;
                  _ -> <<>>
              end,
    {error, {jsonrpc, Code, Message, maps:get(<<"data">>, E, undefined)}};
match(#{<<"id">> := Id, <<"result">> := Result}, Id) ->
    {ok, Result};
match(_, _) ->
    nomatch.

%% Read SSE events until the reply for Id arrives, then drop the stream.
sse(Pid, Stream, Deadline, Max, Id, Buf, Size) ->
    case await(Pid, Stream, Deadline) of
        {data, IsFin, Data} when Max =:= infinity; Size + byte_size(Data) =< Max ->
            {Events, Rest} = split_events(<<Buf/binary, Data/binary>>),
            case sse_match(Events, Id) of
                nomatch when IsFin =:= nofin ->
                    sse(Pid, Stream, Deadline, Max, Id, Rest, Size + byte_size(Data));
                nomatch ->
                    case sse_match(element(1, split_events(<<Rest/binary, "\n\n">>)), Id) of
                        nomatch -> {error, {invalid_response, <<"SSE stream ended without a response">>}};
                        Result -> Result
                    end;
                Result ->
                    discard(Pid, Stream, IsFin),
                    Result
            end;
        {data, IsFin, _} ->
            discard(Pid, Stream, IsFin),
            {error, too_large};
        {trailers, _} ->
            {error, {invalid_response, <<"SSE stream ended without a response">>}};
        Error ->
            Error
    end.

sse_match([], _Id) ->
    nomatch;
sse_match([Event | Rest], Id) ->
    case event_message(Event) of
        {ok, Msg} ->
            case match(Msg, Id) of
                nomatch -> sse_match(Rest, Id);
                Result -> Result
            end;
        skip ->
            sse_match(Rest, Id)
    end.

%% Complete events (blank-line terminated) and the unterminated remainder.
split_events(Bin) ->
    Norm = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    Parts = binary:split(Norm, <<"\n\n">>, [global]),
    {lists:droplast(Parts), lists:last(Parts)}.

event_message(Event) ->
    Lines = binary:split(Event, <<"\n">>, [global]),
    Fields = [field(L) || L <- Lines],
    Type = proplists:get_value(<<"event">>, Fields, <<"message">>),
    case [V || {<<"data">>, V} <- Fields] of
        [_ | _] = Data when Type =:= <<"message">> ->
            case muse_json:decode(iolist_to_binary(lists:join(<<"\n">>, Data))) of
                {ok, Msg} when is_map(Msg) -> {ok, Msg};
                _ -> skip
            end;
        _ ->
            skip
    end.

field(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, <<" ", Value/binary>>] -> {Name, Value};
        [Name, Value] -> {Name, Value};
        [Name] -> {Name, <<>>}
    end.

body(Pid, Stream, Deadline, Max, Acc) ->
    case await(Pid, Stream, Deadline) of
        {data, IsFin, Data} when Max =:= infinity; byte_size(Acc) + byte_size(Data) =< Max ->
            case IsFin of
                fin -> {ok, <<Acc/binary, Data/binary>>};
                nofin -> body(Pid, Stream, Deadline, Max, <<Acc/binary, Data/binary>>)
            end;
        {data, IsFin, _} ->
            discard(Pid, Stream, IsFin),
            {error, too_large};
        {trailers, _} ->
            {ok, Acc};
        Error ->
            Error
    end.

await(Pid, Stream, Deadline) ->
    case gun:await(Pid, Stream, remaining(Deadline)) of
        {error, timeout} ->
            _ = gun:cancel(Pid, Stream),
            {error, timeout};
        {error, Reason} ->
            {error, {transport, Reason}};
        {inform, _, _} ->
            await(Pid, Stream, Deadline);
        Other ->
            Other
    end.

discard(_Pid, _Stream, fin) -> ok;
discard(Pid, Stream, nofin) -> _ = gun:cancel(Pid, Stream), ok.

request_headers(#{headers := Extra, session := Session, version := Version}) ->
    [{<<"content-type">>, <<"application/json">>},
     {<<"accept">>, <<"application/json, text/event-stream">>}]
    ++ [{<<"mcp-session-id">>, Session} || Session =/= undefined]
    ++ [{<<"mcp-protocol-version">>, Version} || Version =/= undefined]
    ++ Extra.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

media_type(undefined) -> undefined;
media_type(CT) ->
    [Essence | _] = binary:split(CT, <<";">>),
    string:lowercase(string:trim(Essence)).

call_deadline(Timeout, Deadline) ->
    min(erlang:monotonic_time(millisecond) + Timeout, Deadline).

remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

parse_url(Url) ->
    case uri_string:parse(iolist_to_binary(Url)) of
        #{scheme := Scheme, host := Host} = U when Host =/= <<>> ->
            Path = case maps:get(path, U, <<>>) of <<>> -> <<"/">>; P -> P end,
            Full = case maps:find(query, U) of
                       {ok, Q} -> <<Path/binary, "?", Q/binary>>;
                       error -> Path
                   end,
            case string:lowercase(Scheme) of
                <<"https">> -> {ok, Host, maps:get(port, U, 443), Full, tls};
                <<"http">> -> {ok, Host, maps:get(port, U, 80), Full, tcp};
                _ -> error
            end;
        _ ->
            error
    end.

gun_opts(Host, tls, Wait) ->
    HostStr = binary_to_list(Host),
    SNI = case inet:parse_address(HostStr) of
              {ok, _} -> [];
              {error, _} -> [{server_name_indication, HostStr}]
          end,
    #{transport => tls, protocols => [http2, http], retry => 0,
      connect_timeout => max(1, Wait),
      http_opts => #{closing_timeout => ?CLOSING_TIMEOUT},
      http2_opts => #{closing_timeout => ?CLOSING_TIMEOUT},
      tls_opts => [{verify, verify_peer},
                   {cacerts, public_key:cacerts_get()},
                   {customize_hostname_check,
                    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
                   | SNI]};
gun_opts(_Host, tcp, Wait) ->
    #{transport => tcp, protocols => [http], retry => 0, connect_timeout => max(1, Wait),
      http_opts => #{closing_timeout => ?CLOSING_TIMEOUT}}.
