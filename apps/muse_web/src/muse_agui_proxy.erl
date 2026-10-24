%% @doc `AGENT_BACKEND=agui`: relay a run to an external AG-UI agent
%% (designs/03-agent.md §5; OpenMuse agent.ts `HttpAgent({url: AGENT_URL,
%% headers: {Authorization: Bearer AGENT_TOKEN}})`).
%%
%% The RunAgentInput is POSTed to `AGENT_URL` over gun with
%% `accept: text/event-stream`; the upstream SSE stream is parsed frame by
%% frame and each event is handed to the caller unchanged: the frame keeps
%% the upstream `id:` (when present) and the exact `data:` lines. Comments
%% and frames without a JSON object with a `type` are dropped. The relay ends
%% after the first RUN_FINISHED / RUN_ERROR (the upstream request is then
%% cancelled). A non-2xx response, a network failure or a stream that ends
%% before a terminal event becomes one RUN_ERROR with a safe message; the
%% details are only logged.
%%
%% The gun connection is owned by the calling process, so it is closed when
%% that process exits (an HTTP client going away kills its cowboy request
%% process, which cancels the upstream request).
%%
%% Two entry points: `run/2` streams in the calling process (the HTTP
%% handler); `start/2` runs in a new process that sends
%% `{muse_agui_proxy, Ref, Item}` and finally `{muse_agui_proxy_done, Ref}` to
%% a subscriber and stops when the subscriber exits (the UI relay,
%% designs/05-web-ui.md §4).
-module(muse_agui_proxy).

-export([run/2, run/3, start/2, parse/2, new_parser/0]).

-define(HEARTBEAT, 25000).
-define(CONNECT_TIMEOUT, 15000).
%% gun drains in-flight streams for this long after the owner dies (default 15 s).
-define(CLOSING_TIMEOUT, 100).
-define(UNREACHABLE, <<"Could not reach the AG-UI agent">>).
-define(MAX_FRAME, 8388608).

-type item() :: ping | {event, map(), binary()}.
-type parser() :: #{line := binary(), data := [binary()], id := binary() | undefined}.
-export_type([item/0, parser/0]).

%% @doc Relay one run; `Emit` receives every event (and a `ping` every 25 s
%% of upstream silence). Returns after the terminal event.
-spec run(map(), fun((item()) -> term())) -> ok.
run(Payload, Emit) ->
    run(Payload, Emit, #{}).

%% @doc `Opts`: `url`, `token` (default AGENT_URL / AGENT_TOKEN), `watch`
%% (a pid; the relay stops silently when it exits).
-spec run(map(), fun((item()) -> term()), map()) -> ok.
run(Payload, Emit, Opts) ->
    Url = maps:get(url, Opts, muse_config:get(agent_url)),
    Token = maps:get(token, Opts, muse_config:get(agent_token)),
    Watch = case maps:get(watch, Opts, undefined) of
                undefined -> undefined;
                Pid -> erlang:monitor(process, Pid)
            end,
    case connect(Url) of
        {ok, Conn, Path} ->
            Headers = [{<<"content-type">>, <<"application/json">>},
                       {<<"accept">>, <<"text/event-stream">>}
                       | case Token of
                             undefined -> [];
                             _ -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
                         end],
            Stream = gun:post(Conn, Path, Headers, muse_json:encode(Payload)),
            Result = loop(Conn, Stream, Watch, new_parser(), Emit),
            _ = gun:close(Conn),
            Result;
        {error, Reason} ->
            fail(Reason, Emit)
    end.

%% @doc Relay in a new process, reporting to `Subscriber`.
-spec start(map(), pid()) -> {ok, reference()}.
start(Payload, Subscriber) ->
    Ref = make_ref(),
    _ = proc_lib:spawn(fun() ->
                               ok = run(Payload, fun(Item) -> Subscriber ! {?MODULE, Ref, Item} end,
                                        #{watch => Subscriber}),
                               Subscriber ! {muse_agui_proxy_done, Ref}
                       end),
    {ok, Ref}.

connect(undefined) ->
    {error, no_agent_url};
connect(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = U when Host =/= <<>> ->
            Path0 = case maps:get(path, U, <<>>) of <<>> -> <<"/">>; P -> P end,
            Path = case maps:find(query, U) of
                       {ok, Q} -> <<Path0/binary, "?", Q/binary>>;
                       error -> Path0
                   end,
            case string:lowercase(Scheme) of
                <<"https">> -> open(Host, maps:get(port, U, 443), tls, Path);
                <<"http">> -> open(Host, maps:get(port, U, 80), tcp, Path);
                _ -> {error, bad_agent_url}
            end;
        _ ->
            {error, bad_agent_url}
    end.

open(Host, Port, Transport, Path) ->
    case gun:open(binary_to_list(Host), Port, gun_opts(Host, Transport)) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECT_TIMEOUT) of
                {ok, _} -> {ok, Conn, Path};
                {error, Reason} -> _ = gun:close(Conn), {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

gun_opts(Host, tls) ->
    HostStr = binary_to_list(Host),
    SNI = case inet:parse_address(HostStr) of
              {ok, _} -> [];
              {error, _} -> [{server_name_indication, HostStr}]
          end,
    #{transport => tls, protocols => [http], retry => 0, connect_timeout => ?CONNECT_TIMEOUT,
      http_opts => #{closing_timeout => ?CLOSING_TIMEOUT},
      tls_opts => [{verify, verify_peer},
                   {cacerts, public_key:cacerts_get()},
                   {customize_hostname_check,
                    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
                   | SNI]};
gun_opts(_Host, tcp) ->
    #{transport => tcp, protocols => [http], retry => 0, connect_timeout => ?CONNECT_TIMEOUT,
      http_opts => #{closing_timeout => ?CLOSING_TIMEOUT}}.

loop(Conn, Stream, Watch, Parser, Emit) ->
    receive
        {gun_response, Conn, Stream, IsFin, Status, _Headers} when Status >= 200, Status < 300 ->
            case IsFin of
                fin -> fail(empty_response, Emit);
                nofin -> loop(Conn, Stream, Watch, Parser, Emit)
            end;
        {gun_response, Conn, Stream, _IsFin, Status, _Headers} ->
            _ = gun:cancel(Conn, Stream),
            fail({http, Status}, Emit);
        {gun_inform, Conn, Stream, _, _} ->
            loop(Conn, Stream, Watch, Parser, Emit);
        {gun_data, Conn, Stream, IsFin, Data} ->
            case parse(Data, Parser) of
                {_, #{line := Line}} when byte_size(Line) > ?MAX_FRAME ->
                    _ = gun:cancel(Conn, Stream),
                    fail(frame_too_large, Emit);
                {Events, Parser1} ->
                    case emit(Events, Emit) of
                        terminal ->
                            _ = gun:cancel(Conn, Stream),
                            ok;
                        more when IsFin =:= fin ->
                            fail(stream_ended, Emit);
                        more ->
                            loop(Conn, Stream, Watch, Parser1, Emit)
                    end
            end;
        {gun_trailers, Conn, Stream, _} ->
            fail(stream_ended, Emit);
        {gun_error, Conn, Stream, Reason} ->
            fail(Reason, Emit);
        {gun_error, Conn, Reason} ->
            fail(Reason, Emit);
        {gun_down, Conn, _, Reason, _} ->
            fail(Reason, Emit);
        {'DOWN', Watch, process, _, _} ->
            _ = gun:cancel(Conn, Stream),
            ok
    after ?HEARTBEAT ->
        _ = Emit(ping),
        loop(Conn, Stream, Watch, Parser, Emit)
    end.

emit([], _Emit) ->
    more;
emit([{Event, Frame} | Rest], Emit) ->
    _ = Emit({event, Event, Frame}),
    case beamai_agui_event:is_terminal(Event) of
        true -> terminal;
        false -> emit(Rest, Emit)
    end.

fail(Reason, Emit) ->
    logger:warning("[OpenMuse] AG-UI agent request failed: ~0p", [Reason]),
    Message = case Reason of
                  {http, Status} ->
                      <<"The AG-UI agent rejected the request (HTTP ", (integer_to_binary(Status))/binary, ")">>;
                  stream_ended -> <<"The AG-UI agent ended the stream before the run finished">>;
                  empty_response -> <<"The AG-UI agent ended the stream before the run finished">>;
                  frame_too_large -> <<"The AG-UI agent sent an event that is too large">>;
                  _ -> ?UNREACHABLE
              end,
    Event = beamai_agui_event:new(<<"RUN_ERROR">>, #{<<"message">> => Message}),
    _ = Emit({event, Event, beamai_agui_event:to_sse(Event)}),
    ok.

%% SSE parsing (WHATWG event-stream: lines end in CRLF, LF or CR; a blank
%% line dispatches; `data:` lines join with LF; one leading space is removed).

-spec new_parser() -> parser().
new_parser() ->
    #{line => <<>>, data => [], id => undefined}.

%% @doc Feed bytes; returns the complete `{Event, Frame}` pairs and the new state.
-spec parse(binary(), parser()) -> {[{map(), binary()}], parser()}.
parse(Data, #{line := Partial} = P) ->
    Buf = <<Partial/binary, Data/binary>>,
    %% A trailing CR may be the first half of a CRLF.
    {Complete, Keep} = case binary:last(<<0, Buf/binary>>) of
                           $\r -> {binary:part(Buf, 0, byte_size(Buf) - 1), <<"\r">>};
                           _ -> {Buf, <<>>}
                       end,
    Lines = binary:split(binary:replace(binary:replace(Complete, <<"\r\n">>, <<"\n">>, [global]),
                                        <<"\r">>, <<"\n">>, [global]),
                         <<"\n">>, [global]),
    {Done, Last} = lists:split(length(Lines) - 1, Lines),
    {Events, P1} = lines(Done, P, []),
    {Events, P1#{line := <<(hd(Last))/binary, Keep/binary>>}}.

lines([], P, Acc) ->
    {lists:reverse(Acc), P};
lines([<<>> | Rest], #{data := []} = P, Acc) ->
    lines(Rest, P#{id := undefined}, Acc);
lines([<<>> | Rest], #{data := Data, id := Id} = P, Acc) ->
    Lines = lists:reverse(Data),
    Acc1 = case muse_json:decode(lists:join(<<"\n">>, Lines)) of
               {ok, #{<<"type">> := Type} = Event} when is_binary(Type) ->
                   IdLine = case Id of
                                undefined -> [];
                                _ -> [<<"id: ">>, Id, <<"\n">>]
                            end,
                   [{Event, iolist_to_binary([IdLine, [[<<"data: ">>, L, <<"\n">>] || L <- Lines], <<"\n">>])}
                    | Acc];
               _ ->
                   Acc
           end,
    lines(Rest, P#{data := [], id := undefined}, Acc1);
lines([<<":", _/binary>> | Rest], P, Acc) ->
    lines(Rest, P, Acc);
lines([Line | Rest], #{data := Data} = P, Acc) ->
    {Field, Value} = case binary:split(Line, <<":">>) of
                         [F, <<" ", V/binary>>] -> {F, V};
                         [F, V] -> {F, V};
                         [F] -> {F, <<>>}
                     end,
    P1 = case Field of
             <<"data">> -> P#{data := [Value | Data]};
             <<"id">> -> P#{id := Value};
             _ -> P
         end,
    lines(Rest, P1, Acc).
