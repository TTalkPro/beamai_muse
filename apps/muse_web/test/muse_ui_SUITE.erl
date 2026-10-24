%% aihtml UI shell (designs/05-web-ui.md §3, tasks/M6-ui.md M6-1): sign-in
%% and sign-out by form post, session cookie gating of pages and of the
%% aihtml action/events endpoints, the push epoch, static assets.
-module(muse_ui_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [login_page_and_redirects, sign_in_and_pages, gate_on_aihtml_endpoints, sign_out_rotates_epoch,
     live_access_key, assets_and_bridge].

init_per_testcase(live_access_key, Config) ->
    [{env, muse_web_test_env:start(#{<<"WORKSPACE_MODE">> => <<"live">>,
                                     <<"OPENMUSE_ACCESS_KEY">> => binary:copy(<<"k">>, 24),
                                     <<"TOKEN_ENCRYPTION_KEY">> => base64:encode(crypto:strong_rand_bytes(32)),
                                     <<"MUSE_UI_SECRET">> => binary:copy(<<"s">>, 32)})} | Config];
init_per_testcase(_Case, Config) ->
    [{env, muse_web_test_env:start()} | Config].

end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)).

%% Plain request, no redirect following: {Status, Headers, Body}.
req(Config, Method, Path, Headers) ->
    req(Config, Method, Path, Headers, undefined).

req(Config, Method, Path, Headers, Form) ->
    Url = muse_web_test_env:base(?config(env, Config)) ++ Path,
    Request = case Form of
                  undefined -> {Url, Headers};
                  _ -> {Url, Headers, "application/x-www-form-urlencoded", uri_string:compose_query(Form)}
              end,
    {ok, {{_, Status, _}, RespHeaders, Body}} =
        httpc:request(Method, Request, [{autoredirect, false}, {timeout, 30000}], [{body_format, binary}]),
    {Status, RespHeaders, Body}.

%% Sign in by form post; the session cookie value.
sign_in(Config, Form) ->
    {302, H, _} = req(Config, post, "/login", [{"origin", origin(Config)}], Form),
    ?assertEqual("/chat", proplists:get_value("location", H)),
    cookie(H).

cookie(Headers) ->
    [SetCookie] = [V || {"set-cookie", V} <- Headers],
    [Pair | Attrs] = string:split(SetCookie, ";", all),
    ?assert(lists:member("httponly", [string:lowercase(string:trim(A)) || A <- Attrs])),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

with_cookie(Value) -> [{"cookie", "muse_session=" ++ Value}].

%% The UI is served at PUBLIC_API_URL, whose origin the middleware allows.
origin(_Config) -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

login_page_and_redirects(Config) ->
    {302, H1, _} = req(Config, get, "/", []),
    ?assertEqual("/login", proplists:get_value("location", H1)),
    {302, H2, _} = req(Config, get, "/chat", []),
    ?assertEqual("/login", proplists:get_value("location", H2)),
    {200, H3, Page} = req(Config, get, "/login", []),
    ?assertMatch("text/html" ++ _, proplists:get_value("content-type", H3)),
    %% sample mode: no access key field
    ?assertEqual(nomatch, binary:match(Page, <<"accessKey">>)),
    ?assertNotEqual(nomatch, binary:match(Page, <<"action=\"/login\"">>)),
    %% a cross-site form post is refused
    {403, _, _} = req(Config, post, "/login", [{"sec-fetch-site", "cross-site"}], []),
    {403, _, _} = req(Config, post, "/login", [{"origin", "https://evil.example"}], []).

sign_in_and_pages(Config) ->
    Cookie = sign_in(Config, []),
    {302, H, _} = req(Config, get, "/", with_cookie(Cookie)),
    ?assertEqual("/chat", proplists:get_value("location", H)),
    lists:foreach(
      fun({Key, _}) ->
              Path = "/" ++ atom_to_list(Key),
              {200, _, Html} = req(Config, get, Path, with_cookie(Cookie)),
              %% the shell: subscribed root, nav, our stylesheet and script
              ?assertNotEqual(nomatch, binary:match(Html, <<"id=\"muse-shell\"">>), Path),
              ?assertNotEqual(nomatch, binary:match(Html, <<"data-ah-subscribe">>), Path),
              ?assertNotEqual(nomatch, binary:match(Html, <<"/static/css/muse.css?v=">>), Path),
              ?assertNotEqual(nomatch, binary:match(Html, <<"href=\"/settings\"">>), Path)
      end, muse_ui_page:modules()),
    %% a bad cookie is no session
    {302, _, _} = req(Config, get, "/chat", with_cookie("nope")),
    %% the API token and the cookie are the same session
    {200, #{<<"mode">> := <<"sample">>}} =
        muse_web_test_env:http(?config(env, Config), get, "/api/workspace", list_to_binary(Cookie)).

gate_on_aihtml_endpoints(Config) ->
    Cookie = sign_in(Config, []),
    Token = binary_to_list(aihtml_push:token(muse_ui:topic(<<"local-user">>, user))),
    {401, _, _} = req(Config, get, "/aihtml/events?t=" ++ Token, []),
    {401, _, _} = req(Config, get, "/aihtml/events?t=" ++ Token, with_cookie("nope")),
    {401, _, _} = req(Config, post, "/aihtml/action", [], []),
    %% with the session the request reaches aihtml (405 / 400 are aihtml's)
    {405, _, _} = req(Config, put, "/aihtml/events", with_cookie(Cookie), []),
    {400, _, _} = req(Config, get, "/aihtml/events", with_cookie(Cookie)),
    %% the aihtml runtime the page loads is public
    {200, _, Page} = req(Config, get, "/login", []),
    {match, [Src]} = re:run(Page, <<"<script[^>]*src=\"(/aihtml/[^\"]+)\"">>, [{capture, all_but_first, list}]),
    {200, _, _} = req(Config, get, Src, []).

sign_out_rotates_epoch(Config) ->
    Cookie = sign_in(Config, []),
    Epoch = muse_ui:epoch(<<"local-user">>),
    ?assertEqual(Epoch, muse_ui:epoch(<<"local-user">>)),
    {403, _, _} = req(Config, post, "/logout", with_cookie(Cookie) ++ [{"sec-fetch-site", "cross-site"}], []),
    {302, H, _} = req(Config, post, "/logout", with_cookie(Cookie) ++ [{"origin", origin(Config)}], []),
    ?assertEqual("/login", proplists:get_value("location", H)),
    ?assertEqual("", cookie_value(H)),
    ?assertNotEqual(Epoch, muse_ui:epoch(<<"local-user">>)),
    %% the old session is gone
    {302, _, _} = req(Config, get, "/chat", with_cookie(Cookie)).

cookie_value(Headers) ->
    [SetCookie] = [V || {"set-cookie", V} <- Headers],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

live_access_key(Config) ->
    {200, _, Page} = req(Config, get, "/login", []),
    ?assertNotEqual(nomatch, binary:match(Page, <<"name=\"accessKey\"">>)),
    {200, _, Wrong} = req(Config, post, "/login", [{"origin", origin(Config)}], [{"accessKey", "wrong"}]),
    ?assertNotEqual(nomatch, binary:match(Wrong, <<"login-error">>)),
    ?assertEqual({ok, binary:copy(<<"s">>, 32)}, application:get_env(aihtml, secret)),
    _ = sign_in(Config, [{"accessKey", binary_to_list(binary:copy(<<"k">>, 24))}]).

assets_and_bridge(Config) ->
    {200, H, Js} = req(Config, get, "/static/js/muse.js", []),
    ?assertMatch("application/javascript" ++ _, proplists:get_value("content-type", H)),
    ?assertNotEqual(nomatch, binary:match(Js, <<"muse-composer">>)),
    %% the sample-mode UI secret is kept in the data dir
    #{dir := Dir} = ?config(env, Config),
    {ok, Secret} = file:read_file(filename:join(Dir, "ui-secret")),
    ?assertEqual({ok, Secret}, application:get_env(aihtml, secret)),
    %% a page view starts the owner's bridge; a notification reaches it
    Cookie = sign_in(Config, []),
    {200, _, _} = req(Config, get, "/chat", with_cookie(Cookie)),
    Bridge = global:whereis_name({muse_ui_bridge, <<"local-user">>}),
    ?assert(is_pid(Bridge)),
    ok = muse_ui_bridge:ensure(<<"local-user">>),
    ?assertEqual(Bridge, global:whereis_name({muse_ui_bridge, <<"local-user">>})).
