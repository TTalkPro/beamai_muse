%% @doc Live remote screens over WebSocket (designs/05-web-ui.md §5.1; not
%% in OpenMuse): the page's noVNC speaks RFB to an x11vnc that runs, for
%% this connection only, in the owner's container, started with
%% `docker exec -i` (muse_docker:vnc_args/2, stream/1). The bytes are
%% relayed unchanged both ways: binary frames <-> the exec's stdin/stdout.
%%
%% - `/vnc/browser/<session>`: a browser session's window, with input
%%   (muse_browser:vnc/2; the console page, where the person acts);
%% - `/vnc/computer/<id>[?control=1]`: a desktop computer's screen, watching
%%   only unless `control=1` (muse_computer_desktop:vnc/2).
%%
%% The owner comes from the session cookie, like the UI's other endpoints,
%% and the session or computer must be the owner's; a cross-site handshake
%% is refused (muse_mw already rejects foreign origins). Failures before the
%% upgrade are plain HTTP errors. The cookie is checked again every minute
%% (a signed-out owner's view closes, 4401), a ping every 30 s keeps idle
%% proxies from dropping a still screen, and when x11vnc ends (the container
%% stopped) the socket closes (1000). Closing the socket ends the exec, and
%% with it x11vnc. An open browser view counts as use of the session's host
%% (its browser container or desktop computer; idle stop, as the old
%% screenshot poll did), a desktop view only while controlled.
-module(muse_vnc_handler).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3,
         browser_path/1, computer_path/2]).

-define(PING_MS, 30000).
-define(AUTH_MS, 60000).
-define(MAX_FRAME, 1048576).

-spec browser_path(binary()) -> binary().
browser_path(Id) -> <<"/vnc/browser/", Id/binary>>.

-spec computer_path(binary(), boolean()) -> binary().
computer_path(Id, false) -> <<"/vnc/computer/", Id/binary>>;
computer_path(Id, true) -> <<"/vnc/computer/", Id/binary, "?control=1">>.

-spec init(cowboy_req:req(), term()) ->
    {cowboy_websocket, cowboy_req:req(), map(), map()} | {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case {same_origin(Req0), muse_ui:owner(Req0)} of
        {false, _} ->
            {ok, muse_http:error_reply(403, <<"Origin is not allowed">>, Req0), State};
        {true, error} ->
            {ok, muse_http:error_reply(401, <<"Sign in again">>, Req0), State};
        {true, {ok, Owner}} ->
            case target(Owner, cowboy_req:binding(kind, Req0), cowboy_req:binding(id, Req0), Req0) of
                {ok, Args, Keepalive} ->
                    Req = subprotocol(Req0),
                    {_, Token} = lists:keyfind(muse_ui:cookie(), 1, cowboy_req:parse_cookies(Req0)),
                    {cowboy_websocket, Req, #{owner => Owner, token => Token, args => Args, keepalive => Keepalive,
                                           os_pid => undefined},
                     #{idle_timeout => 3 * ?PING_MS, max_frame_size => ?MAX_FRAME, compress => false}};
                {error, {Status, Msg}} ->
                    {ok, muse_http:error_reply(Status, Msg, Req0), State}
            end
    end.

%% The argv, and what an open view counts as use of (idle stop): the
%% owner's browser container; a computer only while the person controls it.
target(Owner, <<"browser">>, Id, _Req) ->
    case muse_browser:vnc(Owner, Id) of
        {ok, Args} -> {ok, Args, fun() -> muse_browser_docker:touch_session(Owner, Id) end};
        Error -> Error
    end;
target(Owner, <<"computer">>, Id, Req) ->
    Control = muse_http:query(<<"control">>, Req) =:= <<"1">>,
    case muse_computers:get(Owner, Id) of
        undefined ->
            {error, {404, <<"Computer not found">>}};
        _ ->
            case muse_computer_desktop:vnc(muse_computer:ref_of(Owner, Id), #{control => Control}) of
                {ok, Args} when Control -> {ok, Args, fun() -> muse_computers:touch(Owner, Id) end};
                {ok, Args} -> {ok, Args, fun() -> ok end};
                Error -> Error
            end
    end;
target(_, _, _, _) ->
    {error, {404, <<"Not found">>}}.

%% noVNC asks for no subprotocol by default; older clients ask for `binary`.
subprotocol(Req) ->
    case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
        Protocols when is_list(Protocols) ->
            case lists:member(<<"binary">>, Protocols) of
                true -> cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, <<"binary">>, Req);
                false -> Req
            end;
        _ -> Req
    end.

same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> cowboy_req:header(<<"sec-fetch-site">>, Req) =/= <<"cross-site">>;
        _ -> true
    end.

-spec websocket_init(map()) -> {cowboy_websocket:commands(), map()}.
websocket_init(#{args := Args} = S) ->
    %% the exec is linked (it dies with this process); its own exit is the
    %% monitor's 'DOWN', not a crash here
    process_flag(trap_exit, true),
    case muse_docker:stream(Args) of
        {ok, OsPid} ->
            erlang:send_after(?PING_MS, self(), ping),
            erlang:send_after(?AUTH_MS, self(), auth),
            {[], S#{os_pid := OsPid}};
        {error, Msg} ->
            {[{close, 1011, Msg}], S}
    end.

-spec websocket_handle(cow_ws:frame(), map()) -> {cowboy_websocket:commands(), map()}.
websocket_handle({binary, Data}, #{os_pid := OsPid} = S) when OsPid =/= undefined ->
    _ = (catch exec:send(OsPid, Data)),
    {[], S};
websocket_handle(_Frame, S) ->
    {[], S}.

-spec websocket_info(term(), map()) -> {cowboy_websocket:commands(), map()}.
websocket_info({stdout, OsPid, Data}, #{os_pid := OsPid} = S) ->
    {[{binary, Data}], S};
websocket_info({'DOWN', OsPid, process, _, _}, #{os_pid := OsPid} = S) ->
    {[{close, 1000, <<"The screen closed">>}], S#{os_pid := undefined}};
websocket_info(ping, #{keepalive := Keepalive} = S) ->
    erlang:send_after(?PING_MS, self(), ping),
    _ = (catch Keepalive()),
    {[ping], S};
websocket_info(auth, #{owner := Owner, token := Token} = S) ->
    case muse_auth:owner_from_token(Token) =:= {ok, Owner} of
        true ->
            erlang:send_after(?AUTH_MS, self(), auth),
            {[], S};
        false ->
            {[{close, 4401, <<"Sign in again">>}], S}
    end;
websocket_info(_Info, S) ->
    {[], S}.

-spec terminate(term(), cowboy_req:req() | map(), map()) -> ok.
terminate(_Reason, _Req, #{os_pid := OsPid}) when is_integer(OsPid) ->
    _ = (catch exec:stop(OsPid)),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.
