%% @doc Access-key sign-in and session tokens (OpenMuse auth.ts,
%% designs/ref/openmuse-integrations-spec.md §3.1).
%%
%% Single-user: every session belongs to `<<"local-user">>`. Tokens are 32
%% random bytes (base64url, no padding); only their SHA-256 is stored, under
%% `system/sessions`. The same token works as a Bearer header (JSON API) and
%% as the UI cookie.
-module(muse_auth).

-export([session/1, owner_from_header/1, owner_from_token/1, revoke/1,
         purge_expired/0, owner/0]).

-define(OWNER, <<"local-user">>).
-define(TTL_MS, 86400000).

-spec owner() -> binary().
owner() -> ?OWNER.

%% @doc Exchange the access key for a session. Sample mode accepts any key.
-spec session(binary() | undefined) ->
    {ok, #{token := binary(), mode := binary()}} | {error, {401, binary()}}.
session(AccessKey) ->
    Mode = muse_config:get(mode),
    case Mode =:= sample orelse key_matches(AccessKey, muse_config:get(access_key)) of
        true ->
            Token = base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}),
            _ = muse_store:put(<<"system">>, <<"sessions">>,
                           #{<<"id">> => muse_ids:sha256hex(Token),
                             <<"owner">> => ?OWNER,
                             <<"expiresAt">> => muse_time:now_ms() + ?TTL_MS}),
            {ok, #{token => Token, mode => atom_to_binary(Mode)}};
        false ->
            {error, {401, <<"Access key is incorrect">>}}
    end.

%% @doc Resolve `Authorization: Bearer <token>`.
-spec owner_from_header(binary() | undefined) -> {ok, binary()} | {error, {401, binary()}}.
owner_from_header(<<"Bearer ", Token/binary>>) ->
    owner_from_token(Token);
owner_from_header(_) ->
    {error, {401, <<"Sign in to OpenMuse">>}}.

-spec owner_from_token(binary()) -> {ok, binary()} | {error, {401, binary()}}.
owner_from_token(Token) when is_binary(Token), Token =/= <<>> ->
    case muse_store:get(<<"system">>, <<"sessions">>, muse_ids:sha256hex(Token)) of
        #{<<"owner">> := Owner, <<"expiresAt">> := Exp} when is_integer(Exp) ->
            case Exp < muse_time:now_ms() of
                true -> expired();
                false -> {ok, Owner}
            end;
        _ ->
            expired()
    end;
owner_from_token(_) ->
    {error, {401, <<"Sign in to OpenMuse">>}}.

%% @doc Sign out (UI logout; OpenMuse itself never revokes sessions).
-spec revoke(binary()) -> ok.
revoke(Token) ->
    muse_store:remove(<<"system">>, <<"sessions">>, muse_ids:sha256hex(Token)).

-spec purge_expired() -> non_neg_integer().
purge_expired() ->
    Now = muse_time:now_ms(),
    Expired = [Id || #{<<"id">> := Id, <<"expiresAt">> := Exp} <- muse_store:list(<<"system">>, <<"sessions">>),
                     Exp < Now],
    lists:foreach(fun(Id) -> muse_store:remove(<<"system">>, <<"sessions">>, Id) end, Expired),
    length(Expired).

%% Internal

expired() ->
    {error, {401, <<"Session expired. Sign in again.">>}}.

%% Hash both sides first so the constant-time compare sees equal lengths.
key_matches(Given, Expected) when is_binary(Given), is_binary(Expected) ->
    crypto:hash_equals(crypto:hash(sha256, Given), crypto:hash(sha256, Expected));
key_matches(_, _) ->
    false.
