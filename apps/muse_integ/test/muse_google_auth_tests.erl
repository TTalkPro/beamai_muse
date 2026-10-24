%% Ported from OpenMuse tests/oauth.test.ts, plus PKCE, scopes, generation
%% and refresh cases of google-auth.ts.
-module(muse_google_auth_tests).
-include_lib("eunit/include/eunit.hrl").

-import(muse_google_test_http, [stub/1, calls/0, json/1, json/2, header/2]).

-define(SCOPE(S), <<"https://www.googleapis.com/auth/", S>>).
-define(CHANGED, {error, {409, <<"Google sign-in changed or was disconnected. Connect again.">>}}).

key() -> base64:encode(<<7:256>>).

config(Extra) ->
    Env = maps:merge(#{<<"WORKSPACE_MODE">> => <<"sample">>,
                       <<"PUBLIC_API_URL">> => <<"http://localhost:8787">>,
                       <<"GOOGLE_CLIENT_ID">> => <<"synthetic-client">>,
                       <<"GOOGLE_CLIENT_SECRET">> => <<"synthetic-secret">>,
                       <<"TOKEN_ENCRYPTION_KEY">> => key()}, Extra),
    {ok, Config} = muse_config:from_env(Env),
    ok = muse_config:set(Config).

setup() ->
    ok = muse_store:init(#{storage => ram}),
    config(#{}),
    muse_google_test_http:start().

cleanup(_) ->
    muse_google_test_http:stop(),
    muse_store:stop().

oauth_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun connect_url_and_pkce/0,
      fun connect_requires_configuration/0,
      fun incremental_scopes/0,
      fun callback_saves_encrypted_tokens/0,
      fun callback_failures/0,
      fun state_single_use/0,
      fun old_refresh_cannot_overwrite_new_account/0,
      fun disconnect_during_token_exchange/0,
      fun disconnect_during_profile/0,
      fun disconnect_before_callback/0,
      fun newer_connect_wins/0,
      fun refresh_cannot_restore_after_disconnect/0,
      fun refresh_and_single_flight/0,
      fun access_token_errors/0,
      fun disconnect_revokes/0]}.

state_of(#{<<"url">> := Url}) ->
    #{query := Q} = uri_string:parse(Url),
    proplists:get_value(<<"state">>, uri_string:dissect_query(Q)).

query_of(#{<<"url">> := Url}) ->
    #{query := Q} = uri_string:parse(Url),
    uri_string:dissect_query(Q).

put_tokens(Owner, Tokens) ->
    Secret = muse_vault:encrypt(key(), iolist_to_binary(json:encode(Tokens))),
    muse_store:put(Owner, <<"credentials">>, #{<<"id">> => <<"google">>,
                                               <<"connectionId">> => maps:get(<<"connectionId">>, Tokens),
                                               <<"secret">> => Secret}).

tokens(Conn, Access, Account, ExpiresAt) ->
    #{<<"connectionId">> => Conn, <<"accessToken">> => Access, <<"refreshToken">> => <<"refresh-", Conn/binary>>,
      <<"expiresAt">> => ExpiresAt, <<"scopes">> => [], <<"account">> => Account}.

form(Body) ->
    uri_string:dissect_query(iolist_to_binary(Body)).

is_token_url(#{path := P}) -> P =:= <<"/token">>.

%% Run Fun in a process; it blocks at the stub until released.
async(Fun) ->
    Self = self(),
    spawn(fun() -> Self ! {done, Fun()} end).

await_done() ->
    receive {done, R} -> R after 5000 -> error(timeout) end.

%% A stub that parks the first matching request until `release` arrives.
parking_stub(Park, Answer) ->
    Test = self(),
    stub(fun(M, U, H, B) ->
                 case Park(M, U, H, B) of
                     true ->
                         Test ! {parked, self()},
                         receive release -> ok end;
                     false ->
                         ok
                 end,
                 Answer(M, U, H, B)
         end).

await_parked() ->
    receive {parked, Pid} -> Pid after 5000 -> error(not_parked) end.

connect_url_and_pkce() ->
    {ok, Res} = muse_google_auth:connect(<<"owner">>, false),
    #{<<"url">> := Url} = Res,
    ?assertMatch(<<"https://accounts.google.com/o/oauth2/v2/auth?client_id=synthetic-client&redirect_uri=", _/binary>>, Url),
    Q = query_of(Res),
    ?assertEqual([<<"client_id">>, <<"redirect_uri">>, <<"response_type">>, <<"scope">>, <<"state">>,
                  <<"access_type">>, <<"prompt">>, <<"include_granted_scopes">>,
                  <<"code_challenge_method">>, <<"code_challenge">>], [K || {K, _} <- Q]),
    ?assertEqual(<<"http://localhost:8787/api/google/callback">>, proplists:get_value(<<"redirect_uri">>, Q)),
    ?assertMatch({_, _}, binary:match(Url, <<"scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.readonly+https">>)),
    State = proplists:get_value(<<"state">>, Q),
    ?assertEqual(43, byte_size(State)),
    #{<<"verifier">> := Verifier, <<"owner">> := <<"owner">>, <<"expiresAt">> := Exp,
      <<"generation">> := Gen, <<"scopes">> := Scopes} = muse_store:get(<<"system">>, <<"oauth">>, State),
    ?assertEqual(64, byte_size(Verifier)),
    ?assert(Exp > muse_time:now_ms() + 590000),
    ?assertEqual([?SCOPE("gmail.readonly"), ?SCOPE("calendar.events.readonly"),
                  ?SCOPE("calendar.calendarlist.readonly")], Scopes),
    ?assertEqual(base64:encode(crypto:hash(sha256, Verifier), #{mode => urlsafe, padding => false}),
                 proplists:get_value(<<"code_challenge">>, Q)),
    ?assertEqual(<<"S256">>, proplists:get_value(<<"code_challenge_method">>, Q)),
    ?assertMatch(#{<<"generation">> := Gen, <<"connectionId">> := null, <<"secret">> := null},
                 muse_store:get(<<"owner">>, <<"credentials">>, <<"google">>)).

connect_requires_configuration() ->
    config(#{<<"GOOGLE_CLIENT_SECRET">> => <<>>}),
    ?assertEqual({error, {503, <<"Configure GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET and "
                                 "TOKEN_ENCRYPTION_KEY to connect Google">>}},
                 muse_google_auth:connect(<<"owner">>, false)),
    ?assertNot(muse_google_auth:configured()).

incremental_scopes() ->
    put_tokens(<<"owner">>, (tokens(<<"c1">>, <<"a">>, <<"me@example.com">>, 0))#{
                              <<"scopes">> => [?SCOPE("gmail.readonly"), ?SCOPE("drive.file")]}),
    {ok, Res} = muse_google_auth:connect(<<"owner">>, true),
    #{<<"scopes">> := Scopes} = muse_store:get(<<"system">>, <<"oauth">>, state_of(Res)),
    ?assertEqual([?SCOPE("gmail.readonly"), ?SCOPE("calendar.events.readonly"),
                  ?SCOPE("calendar.calendarlist.readonly"), ?SCOPE("drive.file"),
                  ?SCOPE("gmail.send"), ?SCOPE("calendar.events")], Scopes),
    %% Connecting does not disconnect: the old tokens stay usable until the callback.
    ?assertMatch({ok, #{<<"connectionId">> := <<"c1">>}}, muse_google_auth:connection(<<"owner">>)).

google_ok(Account) ->
    fun(post, U, _, _) ->
            true = is_token_url(U),
            json(#{<<"access_token">> => <<"access-1">>, <<"refresh_token">> => <<"refresh-1">>,
                   <<"expires_in">> => 3600, <<"scope">> => <<"a b">>});
       (get, _, _, _) ->
            json(#{<<"emailAddress">> => Account})
    end.

callback_saves_encrypted_tokens() ->
    {ok, Res} = muse_google_auth:connect(<<"owner">>, false),
    State = state_of(Res),
    #{<<"verifier">> := Verifier} = muse_store:get(<<"system">>, <<"oauth">>, State),
    stub(google_ok(<<"me@example.com">>)),
    ?assertEqual(ok, muse_google_auth:callback(State, <<"code-1">>)),
    [{post, TokenUrl, TH, TB}, {get, ProfileUrl, PH, _}] = calls(),
    ?assertEqual(<<"oauth2.googleapis.com">>, maps:get(host, TokenUrl)),
    ?assertEqual(<<"application/x-www-form-urlencoded">>, header(<<"content-type">>, TH)),
    ?assertEqual([{<<"client_id">>, <<"synthetic-client">>}, {<<"client_secret">>, <<"synthetic-secret">>},
                  {<<"redirect_uri">>, <<"http://localhost:8787/api/google/callback">>},
                  {<<"grant_type">>, <<"authorization_code">>}, {<<"code">>, <<"code-1">>},
                  {<<"code_verifier">>, Verifier}], form(TB)),
    ?assertEqual(<<"/gmail/v1/users/me/profile">>, maps:get(path, ProfileUrl)),
    ?assertEqual(<<"Bearer access-1">>, header(<<"authorization">>, PH)),
    #{<<"secret">> := Secret, <<"connectionId">> := Conn} =
        muse_store:get(<<"owner">>, <<"credentials">>, <<"google">>),
    ?assertMatch(<<"v1.", _/binary>>, Secret),
    {ok, Plain} = muse_vault:decrypt(key(), Secret),
    ?assertMatch(<<"{\"connectionId\":\"", _/binary>>, Plain),
    {ok, T} = muse_google_auth:tokens(<<"owner">>),
    ?assertMatch(#{<<"connectionId">> := Conn, <<"accessToken">> := <<"access-1">>,
                   <<"refreshToken">> := <<"refresh-1">>, <<"scopes">> := [<<"a">>, <<"b">>],
                   <<"account">> := <<"me@example.com">>}, T),
    ?assertEqual({ok, #{<<"connectionId">> => Conn, <<"account">> => <<"me@example.com">>,
                        <<"scopes">> => [<<"a">>, <<"b">>]}}, muse_google_auth:connection(<<"owner">>)),
    ?assertEqual({ok, <<"access-1">>}, muse_google_auth:access_token(<<"owner">>, Conn)),
    %% Reconnecting the same account without a new refresh token keeps the old one,
    %% and yields a new connection id.
    {ok, Res2} = muse_google_auth:connect(<<"owner">>, true),
    stub(fun(post, _, _, _) -> json(#{<<"access_token">> => <<"access-2">>, <<"expires_in">> => 3600});
            (get, _, _, _) -> json(#{<<"emailAddress">> => <<"me@example.com">>})
         end),
    ok = muse_google_auth:callback(state_of(Res2), <<"code-2">>),
    {ok, T2} = muse_google_auth:tokens(<<"owner">>),
    ?assertMatch(#{<<"refreshToken">> := <<"refresh-1">>, <<"accessToken">> := <<"access-2">>}, T2),
    ?assertNotEqual(Conn, maps:get(<<"connectionId">>, T2)),
    %% No `scope` in the token response: the requested (incremental) scopes.
    ?assertEqual([?SCOPE("gmail.readonly"), ?SCOPE("calendar.events.readonly"),
                  ?SCOPE("calendar.calendarlist.readonly"), <<"a">>, <<"b">>,
                  ?SCOPE("gmail.send"), ?SCOPE("calendar.events")], maps:get(<<"scopes">>, T2)),
    ?assertEqual({error, {409, <<"Google account or connection changed. Prepare a new action.">>}},
                 muse_google_auth:access_token(<<"owner">>, Conn)),
    %% A different account does not inherit the refresh token.
    {ok, Res3} = muse_google_auth:connect(<<"owner">>, false),
    stub(fun(post, _, _, _) -> json(#{<<"access_token">> => <<"access-3">>, <<"expires_in">> => 3600});
            (get, _, _, _) -> json(#{<<"emailAddress">> => <<"other@example.com">>})
         end),
    ok = muse_google_auth:callback(state_of(Res3), <<"code-3">>),
    {ok, T3} = muse_google_auth:tokens(<<"owner">>),
    ?assertNot(maps:is_key(<<"refreshToken">>, T3)).

callback_failures() ->
    Connect = fun() -> {ok, R} = muse_google_auth:connect(<<"owner">>, false), state_of(R) end,
    stub(fun(_, _, _, _) -> json(400, #{<<"error">> => <<"invalid_grant">>}) end),
    ?assertEqual({error, {502, <<"Google could not complete sign-in. Connect again.">>}},
                 muse_google_auth:callback(Connect(), <<"c">>)),
    stub(fun(post, _, _, _) -> json(#{<<"access_token">> => <<"a">>, <<"expires_in">> => 1});
            (get, _, _, _) -> json(403, #{})
         end),
    ?assertEqual({error, {403, <<"Google did not grant Gmail read access. Connect again.">>}},
                 muse_google_auth:callback(Connect(), <<"c">>)),
    stub(fun(_, _, _, _) -> json(#{<<"access_token">> => <<>>, <<"expires_in">> => 1}) end),
    ?assertMatch({error, {422, _}}, muse_google_auth:callback(Connect(), <<"c">>)),
    stub(fun(post, _, _, _) -> json(#{<<"access_token">> => <<"a">>, <<"expires_in">> => 1});
            (get, _, _, _) -> json(#{<<"emailAddress">> => <<"not an email">>})
         end),
    ?assertMatch({error, {422, _}}, muse_google_auth:callback(Connect(), <<"c">>)),
    ?assertEqual({ok, undefined}, muse_google_auth:connection(<<"owner">>)).

state_single_use() ->
    config(#{<<"GOOGLE_CLIENT_ID">> => <<>>, <<"GOOGLE_CLIENT_SECRET">> => <<>>,
             <<"TOKEN_ENCRYPTION_KEY">> => <<>>}),
    Expired = {error, {400, <<"Google sign-in expired. Connect again.">>}},
    ?assertEqual(Expired, muse_google_auth:callback(<<"unknown-state">>, <<"untrusted-code">>)),
    muse_store:put(<<"system">>, <<"oauth">>, #{<<"id">> => <<"expired">>, <<"owner">> => <<"owner">>,
                                                <<"verifier">> => <<"example">>, <<"scopes">> => [],
                                                <<"expiresAt">> => muse_time:now_ms() - 1}),
    ?assertEqual(Expired, muse_google_auth:callback(<<"expired">>, <<"untrusted-code">>)),
    ?assertEqual(undefined, muse_store:get(<<"system">>, <<"oauth">>, <<"expired">>)),
    %% A valid state is consumed by its first use.
    config(#{}),
    {ok, Res} = muse_google_auth:connect(<<"owner">>, false),
    stub(google_ok(<<"me@example.com">>)),
    ok = muse_google_auth:callback(state_of(Res), <<"c">>),
    ?assertEqual(Expired, muse_google_auth:callback(state_of(Res), <<"c">>)).

old_refresh_cannot_overwrite_new_account() ->
    A = tokens(<<"connection-a">>, <<"old-a">>, <<"a@example.com">>, 0),
    B = (tokens(<<"connection-b">>, <<"new-b">>, <<"b@example.com">>, muse_time:now_ms() + 3600000)),
    put_tokens(<<"owner">>, A),
    parking_stub(fun(_, _, _, _) -> true end,
                 fun(_, _, _, _) -> json(#{<<"access_token">> => <<"refreshed-a">>, <<"expires_in">> => 3600}) end),
    async(fun() -> muse_google_auth:access_token(<<"owner">>, <<"connection-a">>) end),
    Parked = await_parked(),
    put_tokens(<<"owner">>, B),
    Parked ! release,
    ?assertEqual({error, {409, <<"Google account changed or was disconnected during refresh">>}}, await_done()),
    ?assertMatch({ok, #{<<"account">> := <<"b@example.com">>}}, muse_google_auth:tokens(<<"owner">>)),
    ?assertEqual({error, {409, <<"Google account or connection changed. Prepare a new action.">>}},
                 muse_google_auth:access_token(<<"owner">>, <<"connection-a">>)).

disconnect_during(Stage) ->
    {ok, Res} = muse_google_auth:connect(<<"callback-race">>, true),
    State = state_of(Res),
    parking_stub(fun(post, #{path := <<"/revoke">>}, _, _) -> false;
                    (_, U, _, _) -> is_token_url(U) =:= (Stage =:= token)
                 end,
                 fun(post, #{path := <<"/revoke">>}, _, _) -> {status, 200};
                    (post, _, _, _) -> json(#{<<"access_token">> => <<"callback-access">>,
                                               <<"refresh_token">> => <<"callback-refresh">>,
                                               <<"expires_in">> => 3600});
                    (get, _, _, _) -> json(#{<<"emailAddress">> => <<"callback@example.com">>})
                 end),
    async(fun() -> muse_google_auth:callback(State, <<"synthetic-code">>) end),
    Parked = await_parked(),
    ?assertEqual(ok, muse_google_auth:disconnect(<<"callback-race">>)),
    Parked ! release,
    ?assertEqual(?CHANGED, await_done()),
    ?assertEqual({ok, undefined}, muse_google_auth:tokens(<<"callback-race">>)).

disconnect_during_token_exchange() -> disconnect_during(token).
disconnect_during_profile() -> disconnect_during(profile).

disconnect_before_callback() ->
    {ok, Res} = muse_google_auth:connect(<<"pending-owner">>, false),
    ?assertEqual(ok, muse_google_auth:disconnect(<<"pending-owner">>)),
    stub(google_ok(<<"unused@example.com">>)),
    ?assertEqual(?CHANGED, muse_google_auth:callback(state_of(Res), <<"synthetic-code">>)),
    ?assertEqual([], calls()).

newer_connect_wins() ->
    {ok, First} = muse_google_auth:connect(<<"reconnect-owner">>, false),
    parking_stub(fun(post, _, _, Body) -> proplists:get_value(<<"code">>, form(Body)) =:= <<"old-code">>;
                    (_, _, _, _) -> false
                 end,
                 fun(post, _, _, Body) ->
                         Access = case proplists:get_value(<<"code">>, form(Body)) of
                                      <<"old-code">> -> <<"old-access">>;
                                      _ -> <<"new-access">>
                                  end,
                         json(#{<<"access_token">> => Access, <<"expires_in">> => 3600});
                    (get, _, _, _) ->
                         json(#{<<"emailAddress">> => <<"new@example.com">>})
                 end),
    async(fun() -> muse_google_auth:callback(state_of(First), <<"old-code">>) end),
    Parked = await_parked(),
    {ok, Second} = muse_google_auth:connect(<<"reconnect-owner">>, true),
    ?assertEqual(ok, muse_google_auth:callback(state_of(Second), <<"new-code">>)),
    Parked ! release,
    ?assertEqual(?CHANGED, await_done()),
    ?assertMatch({ok, #{<<"accessToken">> := <<"new-access">>}}, muse_google_auth:tokens(<<"reconnect-owner">>)).

refresh_cannot_restore_after_disconnect() ->
    put_tokens(<<"refresh-disconnect">>, tokens(<<"old-connection">>, <<"old-access">>, <<"me@example.com">>, 0)),
    parking_stub(fun(_, #{path := P}, _, _) -> P =:= <<"/token">> end,
                 fun(_, #{path := <<"/revoke">>}, _, _) -> {status, 200};
                    (_, _, _, _) -> json(#{<<"access_token">> => <<"refreshed">>, <<"expires_in">> => 3600})
                 end),
    async(fun() -> muse_google_auth:access_token(<<"refresh-disconnect">>, undefined) end),
    Parked = await_parked(),
    ?assertEqual(ok, muse_google_auth:disconnect(<<"refresh-disconnect">>)),
    Parked ! release,
    ?assertEqual({error, {409, <<"Google account changed or was disconnected during refresh">>}}, await_done()),
    ?assertEqual({ok, undefined}, muse_google_auth:tokens(<<"refresh-disconnect">>)).

refresh_and_single_flight() ->
    put_tokens(<<"owner">>, tokens(<<"c1">>, <<"stale">>, <<"me@example.com">>, muse_time:now_ms() + 59000)),
    parking_stub(fun(_, _, _, _) -> true end,
                 fun(post, _, _, Body) ->
                         ?assertEqual([{<<"client_id">>, <<"synthetic-client">>},
                                       {<<"client_secret">>, <<"synthetic-secret">>},
                                       {<<"grant_type">>, <<"refresh_token">>},
                                       {<<"refresh_token">>, <<"refresh-c1">>}], form(Body)),
                         json(#{<<"access_token">> => <<"fresh">>, <<"expires_in">> => 3600})
                 end),
    async(fun() -> muse_google_auth:access_token(<<"owner">>, <<"c1">>) end),
    Parked = await_parked(),
    %% A second caller queues behind the first refresh instead of starting another.
    async(fun() -> muse_google_auth:access_token(<<"owner">>, undefined) end),
    receive {parked, _} -> ?assert(false) after 100 -> ok end,
    Parked ! release,
    ?assertEqual([{ok, <<"fresh">>}, {ok, <<"fresh">>}], [await_done(), await_done()]),
    ?assertEqual(1, length(calls())),
    {ok, T} = muse_google_auth:tokens(<<"owner">>),
    ?assertMatch(#{<<"accessToken">> := <<"fresh">>, <<"refreshToken">> := <<"refresh-c1">>,
                   <<"connectionId">> := <<"c1">>, <<"account">> := <<"me@example.com">>}, T),
    ?assert(maps:get(<<"expiresAt">>, T) > muse_time:now_ms() + 3500000),
    %% Fresh tokens are used without contacting Google.
    ?assertEqual({ok, <<"fresh">>}, muse_google_auth:access_token(<<"owner">>, undefined)),
    ?assertEqual(1, length(calls())).

access_token_errors() ->
    ?assertEqual({error, {409, <<"Google is disconnected">>}}, muse_google_auth:access_token(<<"nobody">>, undefined)),
    Expired = {error, {401, <<"Google session expired. Connect again.">>}},
    put_tokens(<<"owner">>, maps:remove(<<"refreshToken">>, tokens(<<"c1">>, <<"a">>, <<"me@example.com">>, 0))),
    ?assertEqual(Expired, muse_google_auth:access_token(<<"owner">>, undefined)),
    put_tokens(<<"owner">>, tokens(<<"c1">>, <<"a">>, <<"me@example.com">>, 0)),
    stub(fun(_, _, _, _) -> json(400, #{<<"error">> => <<"invalid_grant">>}) end),
    ?assertEqual(Expired, muse_google_auth:access_token(<<"owner">>, undefined)),
    config(#{<<"TOKEN_ENCRYPTION_KEY">> => <<>>}),
    ?assertEqual({error, {503, <<"TOKEN_ENCRYPTION_KEY is not configured">>}},
                 muse_google_auth:access_token(<<"owner">>, undefined)),
    config(#{<<"TOKEN_ENCRYPTION_KEY">> => base64:encode(<<9:256>>)}),
    ?assertEqual({error, {internal, <<"Unable to authenticate or decrypt credential">>}},
                 muse_google_auth:access_token(<<"owner">>, undefined)),
    ?assertEqual({502, <<"Request failed. Check the server setup and try again.">>},
                 muse_google_api:http_error({internal, <<"Unable to authenticate or decrypt credential">>})).

disconnect_revokes() ->
    ?assertEqual(ok, muse_google_auth:disconnect(<<"nobody">>)),
    ?assertEqual([], calls()),
    put_tokens(<<"owner">>, tokens(<<"c1">>, <<"a">>, <<"me@example.com">>, 0)),
    stub(fun(post, #{path := <<"/revoke">>}, _, Body) ->
                 ?assertEqual([{<<"token">>, <<"refresh-c1">>}], form(Body)),
                 {status, 400}
         end),
    ?assertEqual(ok, muse_google_auth:disconnect(<<"owner">>)),
    ?assertMatch(#{<<"connectionId">> := null, <<"secret">> := null},
                 muse_store:get(<<"owner">>, <<"credentials">>, <<"google">>)),
    put_tokens(<<"owner">>, maps:remove(<<"refreshToken">>, tokens(<<"c1">>, <<"acc">>, <<"me@example.com">>, 0))),
    stub(fun(post, _, _, Body) ->
                 ?assertEqual([{<<"token">>, <<"acc">>}], form(Body)),
                 {status, 500}
         end),
    ?assertEqual({error, {502, <<"Disconnected locally. Google revocation failed; remove access in your "
                                 "Google account settings.">>}}, muse_google_auth:disconnect(<<"owner">>)),
    ?assertEqual({ok, undefined}, muse_google_auth:tokens(<<"owner">>)).
