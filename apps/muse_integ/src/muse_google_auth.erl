%% @doc Google OAuth: connect, callback, access tokens, disconnect
%% (designs/ref/openmuse-integrations-spec.md §9.1-§9.4, google-auth.ts;
%% designs/04-integrations.md §5).
%%
%% Records (spec §0): `system/oauth/<state>` holds the PKCE verifier for ten
%% minutes and is consumed with `muse_store:take/3`; `<owner>/credentials/google`
%% holds `{id, generation, connectionId, secret}` where `secret` is the vault
%% envelope of the Tokens JSON. Every connect and disconnect rotates
%% `generation`, so a callback that started earlier can no longer save. Every
%% successful callback mints a new `connectionId`, which invalidates actions
%% prepared against the old connection; a refresh only writes while the
%% stored `connectionId` is still the one it refreshed.
%%
%% Refreshes are single-flight per `owner:connectionId` in this node: callers
%% queue on a `global` lock and the ones that follow see the fresh token.
-module(muse_google_auth).

-export([configured/0, connect/2, callback/2, access_token/2, disconnect/1,
         connection/1, tokens/1]).

-define(AUTH_URL, "https://accounts.google.com/o/oauth2/v2/auth").
-define(TOKEN_URL, <<"https://oauth2.googleapis.com/token">>).
-define(REVOKE_URL, <<"https://oauth2.googleapis.com/revoke">>).
-define(PROFILE_URL, <<"https://gmail.googleapis.com/gmail/v1/users/me/profile">>).
-define(SCOPE(S), <<"https://www.googleapis.com/auth/", S>>).
-define(TIMEOUT, 15000).
-define(STATE_TTL, 600000).

-define(CHANGED, <<"Google sign-in changed or was disconnected. Connect again.">>).
-define(EXPIRED_SESSION, <<"Google session expired. Connect again.">>).

-type error() :: muse_google_api:error().

%% @doc Client id, client secret and encryption key are all set.
-spec configured() -> boolean().
configured() ->
    lists:all(fun(K) -> present(muse_config:get(K, undefined)) end,
              [google_client_id, google_client_secret, encryption_key]).

%% @doc Start a sign-in: returns `#{<<"url">> => AuthorizationUrl}`.
%% `Write` adds the Gmail send and Calendar write scopes.
-spec connect(binary(), boolean()) -> {ok, #{binary() => binary()}} | {error, error()}.
connect(Owner, Write) ->
    case configured() of
        false ->
            {error, {503, <<"Configure GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET and "
                            "TOKEN_ENCRYPTION_KEY to connect Google">>}};
        true ->
            State = b64url(crypto:strong_rand_bytes(32)),
            Verifier = b64url(crypto:strong_rand_bytes(48)),
            {Generation, Previous} = rotate_generation(Owner, false),
            case decode_tokens(Previous) of
                {ok, Existing} ->
                    Scopes = scopes(Existing, Write),
                    _ = muse_store:put(<<"system">>, <<"oauth">>,
                                       #{<<"id">> => State, <<"owner">> => Owner,
                                         <<"expiresAt">> => muse_time:now_ms() + ?STATE_TTL,
                                         <<"verifier">> => Verifier, <<"scopes">> => Scopes,
                                         <<"generation">> => Generation}),
                    Query = muse_google_api:form_encode(
                              [{<<"client_id">>, cfg(google_client_id)},
                               {<<"redirect_uri">>, redirect_uri()},
                               {<<"response_type">>, <<"code">>},
                               {<<"scope">>, lists:join(<<" ">>, Scopes)},
                               {<<"state">>, State},
                               {<<"access_type">>, <<"offline">>},
                               {<<"prompt">>, <<"consent">>},
                               {<<"include_granted_scopes">>, <<"true">>},
                               {<<"code_challenge_method">>, <<"S256">>},
                               {<<"code_challenge">>, b64url(crypto:hash(sha256, Verifier))}]),
                    {ok, #{<<"url">> => <<?AUTH_URL, "?", Query/binary>>}};
                Error ->
                    Error
            end
    end.

%% @doc Finish a sign-in with the `state` and `code` Google redirected with.
-spec callback(binary(), binary()) -> ok | {error, error()}.
callback(StateId, Code) ->
    St = case is_binary(StateId) of
             true -> muse_store:take(<<"system">>, <<"oauth">>, StateId);
             false -> undefined
         end,
    case St of
        #{<<"expiresAt">> := Exp} when is_number(Exp) ->
            case Exp < muse_time:now_ms() of
                true -> expired();
                false -> callback_state(St, Code)
            end;
        #{} ->
            %% `undefined < Date.now()` is false in the original.
            callback_state(St, Code);
        undefined ->
            expired()
    end.

%% @doc A usable access token, refreshed when it expires within a minute.
%% With `ExpectedConnId` set, a different stored connection is a 409.
-spec access_token(binary(), binary() | undefined) -> {ok, binary()} | {error, error()}.
access_token(Owner, ExpectedConnId) ->
    case tokens(Owner) of
        {ok, undefined} ->
            {error, {409, <<"Google is disconnected">>}};
        {ok, #{<<"connectionId">> := ConnId}} when ExpectedConnId =/= undefined,
                                                    ExpectedConnId =/= <<>>,
                                                    ConnId =/= ExpectedConnId ->
            {error, {409, <<"Google account or connection changed. Prepare a new action.">>}};
        {ok, Tokens} ->
            case fresh(Tokens) of
                {ok, _} = Ok -> Ok;
                stale -> single_flight_refresh(Owner, Tokens)
            end;
        Error ->
            Error
    end.

%% @doc Disconnect locally, then revoke the grant at Google.
-spec disconnect(binary()) -> ok | {error, error()}.
disconnect(Owner) ->
    {_, Previous} = rotate_generation(Owner, true),
    case decode_tokens(Previous) of
        {ok, undefined} ->
            ok;
        {ok, Tokens} ->
            Token = case maps:get(<<"refreshToken">>, Tokens, undefined) of
                        R when is_binary(R) -> R;
                        _ -> maps:get(<<"accessToken">>, Tokens)
                    end,
            case form_post(?REVOKE_URL, [{<<"token">>, Token}]) of
                {ok, _} -> ok;
                {status, 400, _} -> ok;
                {status, _, _} ->
                    {error, {502, <<"Disconnected locally. Google revocation failed; remove "
                                    "access in your Google account settings.">>}};
                {error, _} = Error -> Error
            end;
        Error ->
            Error
    end.

%% @doc What the workspace reports about the connection: `undefined` when
%% disconnected, else `connectionId`, `account` and granted `scopes`.
-spec connection(binary()) -> {ok, undefined | #{binary() => term()}} | {error, error()}.
connection(Owner) ->
    case tokens(Owner) of
        {ok, undefined} ->
            {ok, undefined};
        {ok, Tokens} ->
            {ok, maps:with([<<"connectionId">>, <<"account">>, <<"scopes">>], Tokens)};
        Error ->
            Error
    end.

%% @doc The decrypted Tokens document (§9.3), `undefined` when disconnected.
%% Holds the access and refresh tokens: never return it to clients.
-spec tokens(binary()) -> {ok, undefined | #{binary() => term()}} | {error, error()}.
tokens(Owner) ->
    decode_tokens(muse_store:get(Owner, <<"credentials">>, <<"google">>)).

%% Internal

callback_state(St, Code) ->
    Owner = maps:get(<<"owner">>, St, undefined),
    Generation = maps:get(<<"generation">>, St, undefined),
    Credential = case is_binary(Owner) of
                     true -> muse_store:get(Owner, <<"credentials">>, <<"google">>);
                     false -> undefined
                 end,
    case present(Generation) andalso is_map(Credential)
         andalso maps:get(<<"generation">>, Credential, undefined) =:= Generation of
        false ->
            {error, {409, ?CHANGED}};
        true ->
            exchange_code(Owner, St, Code)
    end.

exchange_code(Owner, St, Code) ->
    Form = [{<<"client_id">>, cfg(google_client_id)},
            {<<"client_secret">>, cfg(google_client_secret)},
            {<<"redirect_uri">>, redirect_uri()},
            {<<"grant_type">>, <<"authorization_code">>},
            {<<"code">>, text(Code)},
            {<<"code_verifier">>, text(maps:get(<<"verifier">>, St, <<>>))}],
    case form_post(?TOKEN_URL, Form) of
        {ok, Body} ->
            case muse_validate:parse(token_schema(), Body) of
                {ok, Token} -> fetch_profile(Owner, St, Token);
                Error -> Error
            end;
        {status, _, _} ->
            {error, {502, <<"Google could not complete sign-in. Connect again.">>}};
        {error, _} = Error ->
            Error
    end.

fetch_profile(Owner, St, #{<<"access_token">> := Access} = Token) ->
    Headers = [{<<"Authorization">>, <<"Bearer ", Access/binary>>}],
    case http(get, ?PROFILE_URL, Headers, <<>>) of
        {ok, Body} ->
            Schema = {object, [{<<"emailAddress">>, {string, #{email => true}}}]},
            case muse_validate:parse(Schema, Body) of
                {ok, #{<<"emailAddress">> := Email}} -> save_callback(Owner, St, Token, Email);
                Error -> Error
            end;
        {status, _, _} ->
            {error, {403, <<"Google did not grant Gmail read access. Connect again.">>}};
        {error, _} = Error ->
            Error
    end.

save_callback(Owner, St, Token, Email) ->
    case tokens(Owner) of
        {ok, Previous} ->
            Refresh = case maps:get(<<"refresh_token">>, Token, undefined) of
                          undefined when is_map(Previous) ->
                              case maps:get(<<"account">>, Previous, undefined) of
                                  Email -> maps:get(<<"refreshToken">>, Previous, undefined);
                                  _ -> undefined
                              end;
                          R ->
                              R
                      end,
            Scopes = case maps:get(<<"scope">>, Token, undefined) of
                         undefined -> maps:get(<<"scopes">>, St, []);
                         Scope -> binary:split(Scope, <<" ">>, [global])
                     end,
            Tokens = #{<<"connectionId">> => muse_ids:uuid(),
                       <<"accessToken">> => maps:get(<<"access_token">>, Token),
                       <<"refreshToken">> => Refresh,
                       <<"expiresAt">> => expires_at(Token),
                       <<"scopes">> => Scopes,
                       <<"account">> => Email},
            save(Owner, Tokens, maps:get(<<"generation">>, St));
        Error ->
            Error
    end.

save(Owner, Tokens, Generation) ->
    case muse_config:get(encryption_key, undefined) of
        Key when is_binary(Key), Key =/= <<>> ->
            Patch = #{<<"generation">> => muse_ids:uuid(),
                      <<"connectionId">> => maps:get(<<"connectionId">>, Tokens),
                      <<"secret">> => muse_vault:encrypt(Key, encode_tokens(Tokens))},
            case muse_store:cas(Owner, <<"credentials">>, <<"google">>,
                                #{<<"generation">> => Generation}, Patch) of
                undefined -> {error, {409, ?CHANGED}};
                _ -> ok
            end;
        _ ->
            {error, {503, <<"TOKEN_ENCRYPTION_KEY is not configured">>}}
    end.

single_flight_refresh(Owner, #{<<"connectionId">> := ConnId} = Tokens) ->
    with_lock({{?MODULE, refresh, Owner, ConnId}, self()},
              fun() -> refresh_locked(Owner, Tokens) end).

%% global:trans/4 backs off for up to seconds between attempts; poll instead.
%% The holder finishes within the 15 s token timeout.
with_lock(Lock, Fun) ->
    case global:set_lock(Lock, [node()], 0) of
        true ->
            try Fun()
            after global:del_lock(Lock, [node()])
            end;
        false ->
            timer:sleep(20),
            with_lock(Lock, Fun)
    end.

%% Whoever held the lock before us may already have refreshed this connection.
refresh_locked(Owner, #{<<"connectionId">> := ConnId} = Tokens) ->
    case tokens(Owner) of
        {ok, #{<<"connectionId">> := ConnId} = Current} ->
            case fresh(Current) of
                {ok, _} = Ok -> Ok;
                stale -> refresh(Owner, Current)
            end;
        _ ->
            refresh(Owner, Tokens)
    end.

refresh(Owner, Tokens) ->
    case maps:get(<<"refreshToken">>, Tokens, undefined) of
        Refresh when is_binary(Refresh) ->
            Form = [{<<"client_id">>, cfg(google_client_id)},
                    {<<"client_secret">>, cfg(google_client_secret)},
                    {<<"grant_type">>, <<"refresh_token">>},
                    {<<"refresh_token">>, Refresh}],
            case form_post(?TOKEN_URL, Form) of
                {ok, Body} ->
                    case muse_validate:parse(token_schema(), Body) of
                        {ok, Token} -> store_refresh(Owner, Tokens, Token);
                        Error -> Error
                    end;
                {status, _, _} ->
                    {error, {401, ?EXPIRED_SESSION}};
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, {401, ?EXPIRED_SESSION}}
    end.

store_refresh(Owner, Tokens, #{<<"access_token">> := Access} = Token) ->
    Refreshed = Tokens#{<<"accessToken">> => Access, <<"expiresAt">> => expires_at(Token)},
    case muse_config:get(encryption_key, undefined) of
        Key when is_binary(Key), Key =/= <<>> ->
            ConnId = maps:get(<<"connectionId">>, Tokens),
            Secret = muse_vault:encrypt(Key, encode_tokens(Refreshed)),
            %% db.ts updateCredential: write only while the connection is unchanged.
            Update = fun(#{<<"connectionId">> := C} = Doc) when C =:= ConnId ->
                             {ok, Doc#{<<"secret">> => Secret}};
                        (_) ->
                             abort
                     end,
            case muse_store:update(Owner, <<"credentials">>, <<"google">>, Update) of
                undefined ->
                    {error, {409, <<"Google account changed or was disconnected during refresh">>}};
                _ ->
                    {ok, Access}
            end;
        _ ->
            {error, {503, <<"Token encryption is not configured">>}}
    end.

%% Returns {Generation, PreviousCredential | undefined}.
rotate_generation(Owner, Disconnect) ->
    Generation = muse_ids:uuid(),
    rotate_generation(Owner, Disconnect, Generation).

rotate_generation(Owner, Disconnect, Generation) ->
    case muse_store:get(Owner, <<"credentials">>, <<"google">>) of
        undefined ->
            Fresh = #{<<"id">> => <<"google">>, <<"generation">> => Generation,
                      <<"connectionId">> => null, <<"secret">> => null},
            case muse_store:insert_if_absent(Owner, <<"credentials">>, Fresh) of
                undefined -> rotate_generation(Owner, Disconnect, Generation);
                _ -> {Generation, undefined}
            end;
        Previous ->
            Patch = case Disconnect of
                        true -> #{<<"generation">> => Generation, <<"connectionId">> => null,
                                  <<"secret">> => null};
                        false -> #{<<"generation">> => Generation}
                    end,
            case muse_store:cas(Owner, <<"credentials">>, <<"google">>, Previous, Patch) of
                undefined -> rotate_generation(Owner, Disconnect, Generation);
                _ -> {Generation, Previous}
            end
    end.

decode_tokens(#{<<"secret">> := Secret}) when is_binary(Secret), Secret =/= <<>> ->
    case muse_config:get(encryption_key, undefined) of
        Key when is_binary(Key), Key =/= <<>> ->
            case muse_vault:decrypt(Key, Secret) of
                {ok, Plain} ->
                    case muse_json:decode(Plain) of
                        {ok, Tokens} when is_map(Tokens) -> {ok, Tokens};
                        _ -> {error, {internal, <<"Stored Google credentials are invalid">>}}
                    end;
                {error, Msg} ->
                    {error, {internal, Msg}}
            end;
        _ ->
            {error, {503, <<"TOKEN_ENCRYPTION_KEY is not configured">>}}
    end;
decode_tokens(_) ->
    {ok, undefined}.

%% Key order of the Tokens interface; an absent refreshToken is omitted.
encode_tokens(T) ->
    muse_json:encode({obj, [{K, maps:get(K, T, undefined)}
                            || K <- [<<"connectionId">>, <<"accessToken">>, <<"refreshToken">>,
                                     <<"expiresAt">>, <<"scopes">>, <<"account">>]]}).

fresh(#{<<"expiresAt">> := Exp, <<"accessToken">> := Access}) when is_number(Exp) ->
    case Exp > muse_time:now_ms() + 60000 of
        true -> {ok, Access};
        false -> stale
    end;
fresh(_) ->
    stale.

scopes(Existing, Write) ->
    Base = [?SCOPE("gmail.readonly"), ?SCOPE("calendar.events.readonly"),
            ?SCOPE("calendar.calendarlist.readonly")],
    Old = case Existing of
              #{<<"scopes">> := S} when is_list(S) -> S;
              _ -> []
          end,
    Extra = case Write of
                true -> [?SCOPE("gmail.send"), ?SCOPE("calendar.events")];
                false -> []
            end,
    unique(Base ++ Old ++ Extra).

unique(List) ->
    lists:reverse(lists:foldl(fun(X, Acc) ->
                                      case lists:member(X, Acc) of
                                          true -> Acc;
                                          false -> [X | Acc]
                                      end
                              end, [], List)).

token_schema() ->
    {object, [{<<"access_token">>, {string, #{min => 1}}},
              {<<"refresh_token">>, {optional, {string, #{}}}},
              {<<"expires_in">>, {number, #{}}},
              {<<"scope">>, {optional, {string, #{}}}}]}.

expires_at(#{<<"expires_in">> := Seconds}) ->
    muse_time:now_ms() + Seconds * 1000.

form_post(Url, Pairs) ->
    http(post, Url, [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
         muse_google_api:form_encode(Pairs)).

%% {ok, Json} on 2xx, {status, S, Body} otherwise, {error, _} when Google
%% could not be reached (fetch rejects; the original reports a generic 502).
http(Method, Url, Headers, Body) ->
    Result = try beamai_http:request_meta(Method, Url, Headers, Body, #{timeout => ?TIMEOUT})
             catch _:_ -> {error, exception}
             end,
    case Result of
        {ok, Resp, #{status := S}} when is_integer(S), S >= 200, S < 300 -> {ok, Resp};
        {ok, Resp, #{status := S}} -> {status, S, Resp};
        {error, {http_error, S, Resp, _}} -> {status, S, Resp};
        {error, {http_error, S, Resp}} -> {status, S, Resp};
        {error, _} -> {error, {internal, <<"Could not reach Google; check the connection and try again">>}}
    end.

redirect_uri() ->
    case muse_config:get(google_redirect_uri, undefined) of
        undefined -> <<(cfg(public_url))/binary, "/api/google/callback">>;
        Uri -> Uri
    end.

cfg(Key) ->
    text(muse_config:get(Key, undefined)).

text(V) when is_binary(V) -> V;
text(_) -> <<>>.

present(V) -> is_binary(V) andalso V =/= <<>>.

expired() ->
    {error, {400, <<"Google sign-in expired. Connect again.">>}}.

b64url(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).
