%% @doc Fake streamable-HTTP MCP server (cowboy) for muse_search
%% tests. The first path segment picks the behaviour: `json`, `sse`, `status/<code>`, `rpcerror`, `slow`, `slowinit`, `big`.
%% `tools/call` of `web_search` answers with `set_search_result/1`; other
%% tools echo their arguments as a text block.
%% Every POST is recorded; `requests/0` returns them oldest first.
-module(muse_mcp_fake).

-export([start/0, stop/0, url/1, requests/0, reset/0, set_search_result/1, init/2]).

-define(TAB, muse_mcp_fake_requests).

-spec start() -> ok.
start() ->
    {ok, _} = application:ensure_all_started([gun, cowboy]),
    Self = self(),
    Owner = spawn(fun() ->
                      _ = ets:new(?TAB, [named_table, public, ordered_set]),
                      Self ! ready,
                      receive stop -> ok end
                  end),
    receive ready -> ok end,
    persistent_term:put({?MODULE, owner}, Owner),
    Dispatch = cowboy_router:compile([{'_', [{"/[...]", ?MODULE, #{}}]}]),
    {ok, _} = cowboy:start_clear(?MODULE, [{port, 0}], #{env => #{dispatch => Dispatch}}),
    ok.

-spec stop() -> ok.
stop() ->
    ok = cowboy:stop_listener(?MODULE),
    persistent_term:get({?MODULE, owner}) ! stop,
    ok.

-spec url(binary()) -> binary().
url(Path) ->
    Port = ranch:get_port(?MODULE),
    <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/", Path/binary>>.

-spec requests() -> [map()].
requests() ->
    [R || {_, R} <- ets:tab2list(?TAB)].

-spec reset() -> ok.
reset() ->
    true = ets:delete_all_objects(?TAB),
    ok.

%% @doc The `web_search` tool result (a CallToolResult map).
-spec set_search_result(map()) -> ok.
set_search_result(Result) ->
    persistent_term:put({?MODULE, search}, Result).

-spec init(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Msg = json:decode(Body),
    Mode = cowboy_req:path_info(Req1),
    Record = #{mode => Mode,
               method => maps:get(<<"method">>, Msg, undefined),
               params => maps:get(<<"params">>, Msg, undefined),
               session => cowboy_req:header(<<"mcp-session-id">>, Req1),
               version => cowboy_req:header(<<"mcp-protocol-version">>, Req1),
               accept => cowboy_req:header(<<"accept">>, Req1),
               auth => cowboy_req:header(<<"authorization">>, Req1),
               user_agent => cowboy_req:header(<<"user-agent">>, Req1)},
    true = ets:insert(?TAB, {erlang:unique_integer([monotonic]), Record}),
    {ok, handle(Mode, Msg, Req1), State}.

handle([<<"status">>, Code], _Msg, Req) ->
    cowboy_req:reply(binary_to_integer(Code), #{}, <<"boom">>, Req);
handle(_Mode, Msg, Req) when not is_map_key(<<"id">>, Msg) ->
    cowboy_req:reply(202, #{}, <<>>, Req);
handle([<<"slowinit">>], #{<<"method">> := <<"initialize">>} = Msg, Req) ->
    timer:sleep(3000),
    handle([<<"json">>], Msg, Req);
handle(Mode, #{<<"method">> := <<"initialize">>} = Msg, Req) ->
    Result = #{<<"protocolVersion">> => maps:get(<<"protocolVersion">>, maps:get(<<"params">>, Msg)),
               <<"capabilities">> => #{<<"tools">> => #{}},
               <<"serverInfo">> => #{<<"name">> => <<"fake">>, <<"version">> => <<"1">>}},
    Req1 = cowboy_req:set_resp_header(<<"mcp-session-id">>, <<"sess-1">>, Req),
    respond(Mode, Msg, #{<<"result">> => Result}, Req1);
handle([<<"rpcerror">>] = Mode, #{<<"method">> := <<"tools/call">>} = Msg, Req) ->
    respond(Mode, Msg, #{<<"error">> => #{<<"code">> => -32602, <<"message">> => <<"bad args">>}}, Req);
handle([<<"slow">>] = Mode, #{<<"method">> := <<"tools/call">>} = Msg, Req) ->
    timer:sleep(3000),
    respond(Mode, Msg, #{<<"result">> => #{<<"content">> => []}}, Req);
handle([<<"big">>] = Mode, #{<<"method">> := <<"tools/call">>} = Msg, Req) ->
    Text = binary:copy(<<"x">>, 2 * 1024 * 1024),
    respond(Mode, Msg, #{<<"result">> => #{<<"content">> => [#{<<"type">> => <<"text">>,
                                                              <<"text">> => Text}]}}, Req);
handle(Mode, #{<<"method">> := <<"tools/list">>} = Msg, Req) ->
    Params = maps:get(<<"params">>, Msg, #{}),
    Result = case maps:get(<<"cursor">>, Params, undefined) of
                 undefined -> #{<<"tools">> => [tool(<<"a">>)], <<"nextCursor">> => <<"p2">>};
                 <<"p2">> -> #{<<"tools">> => [tool(<<"b">>)]}
             end,
    respond(Mode, Msg, #{<<"result">> => Result}, Req);
handle(Mode, #{<<"method">> := <<"tools/call">>,
               <<"params">> := #{<<"name">> := <<"web_search">>}} = Msg, Req) ->
    respond(Mode, Msg, #{<<"result">> => persistent_term:get({?MODULE, search})}, Req);
handle(Mode, #{<<"method">> := <<"tools/call">>, <<"params">> := P} = Msg, Req) ->
    Text = iolist_to_binary(json:encode(maps:get(<<"arguments">>, P))),
    respond(Mode, Msg, #{<<"result">> => #{<<"content">> => [#{<<"type">> => <<"text">>,
                                                              <<"text">> => Text}]}}, Req).

tool(Name) ->
    #{<<"name">> => Name, <<"inputSchema">> => #{<<"type">> => <<"object">>}}.

respond([<<"sse">>], #{<<"id">> := Id}, Reply, Req0) ->
    Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req0),
    Note = json:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"notifications/message">>,
                         <<"params">> => #{<<"level">> => <<"info">>, <<"data">> => <<"hi">>}}),
    Other = json:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id + 1000,
                          <<"result">> => #{}}),
    Final = iolist_to_binary(json:encode(Reply#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id})),
    {A, B} = split_binary(Final, byte_size(Final) div 2),
    ok = cowboy_req:stream_body([<<": comment\r\n\r\nevent: message\r\ndata: ">>, Note, <<"\r\n\r\n">>], nofin, Req),
    ok = cowboy_req:stream_body([<<"event: other\ndata: ">>, Other, <<"\n\n">>], nofin, Req),
    ok = cowboy_req:stream_body([<<"id: 7\ndata: ">>, A], nofin, Req),
    ok = cowboy_req:stream_body([B, <<"\n\n">>], fin, Req),
    Req;
respond(_Mode, #{<<"id">> := Id}, Reply, Req) ->
    Body = json:encode(Reply#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id}),
    cowboy_req:reply(200, #{<<"content-type">> => <<"application/json; charset=utf-8">>}, Body, Req).
