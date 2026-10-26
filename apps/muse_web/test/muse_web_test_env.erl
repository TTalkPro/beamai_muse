%% @doc Boot the whole application (muse_web and below) for HTTP tests:
%% config from an env map, Mnesia in RAM, a free port, the scripted model.
%% `http/4` is a small JSON client on httpc.
-module(muse_web_test_env).

-export([start/0, start/1, stop/1, http/4, http/5, login/1, base/1]).

start() ->
    start(#{}).

start(Env0) ->
    Dir = "/tmp/muse_web_" ++ os:getpid() ++ "_" ++ integer_to_list(erlang:unique_integer([positive])),
    Port = free_port(),
    Env = maps:merge(#{<<"WEB_SEARCH_ENABLED">> => <<"false">>,
                       <<"PORT">> => integer_to_binary(Port),
                       <<"DATA_DIR">> => list_to_binary(Dir)}, Env0),
    ok = application:set_env(muse_core, env, Env),
    ok = application:set_env(muse_core, storage, ram),
    ok = application:set_env(muse_engine, poll_ms, 3600000),
    %% the computer pool's sweeper stays idle (tests call it directly)
    ok = application:set_env(muse_integ, computer_pool_timer, false),
    ok = application:set_env(muse_agent, llm, muse_script_llm:model()),
    {ok, Started} = application:ensure_all_started([inets, muse_web]),
    #{dir => Dir, port => Port, started => Started}.

stop(#{dir := Dir, started := Started}) ->
    [application:stop(A) || A <- lists:reverse(Started), A =/= inets],
    _ = application:stop(mnesia),
    application:unset_env(muse_core, env),
    application:unset_env(muse_core, storage),
    application:unset_env(muse_integ, computer_pool_timer),
    application:unset_env(muse_agent, llm),
    os:cmd("rm -rf " ++ Dir),
    ok.

base(#{port := Port}) ->
    "http://127.0.0.1:" ++ integer_to_list(Port).

%% @doc Sign in (sample mode) and return the Bearer token.
login(Env) ->
    {200, #{<<"token">> := Token}} = http(Env, post, "/api/session", undefined, #{}),
    Token.

http(Env, Method, Path, Token) ->
    http(Env, Method, Path, Token, undefined).

%% @doc `{Status, DecodedJsonOrBinary}`; Body may be a map (JSON), `{raw, ContentType, Bin}` or undefined.
http(Env, Method, Path, Token, Body) ->
    Url = base(Env) ++ Path,
    Headers = case Token of
                  undefined -> [];
                  {headers, H} -> H;
                  _ -> [{"authorization", "Bearer " ++ binary_to_list(Token)}]
              end,
    Request = case Body of
                  undefined when Method =:= get; Method =:= delete -> {Url, Headers};
                  undefined -> {Url, Headers, "application/json", <<>>};
                  {raw, ContentType, Bin} -> {Url, Headers, ContentType, Bin};
                  _ -> {Url, Headers, "application/json", muse_json:encode(Body)}
              end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{timeout, 30000}], [{body_format, binary}]),
    Type = proplists:get_value("content-type", RespHeaders, ""),
    case string:prefix(Type, "application/json") of
        nomatch -> {Status, RespBody, RespHeaders};
        _ -> {ok, Json} = muse_json:decode(RespBody), {Status, Json}
    end.

free_port() ->
    {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(S),
    gen_tcp:close(S),
    Port.
