%% @doc Short-lived HMAC-signed URLs for resources that cannot carry a Bearer
%% header (PDF iframes, browser console and preview), OpenMuse auth.ts §3.2-3.3.
%%
%% The key file `DATA_DIR/session-signing-key` holds 32 random bytes as
%% padded base64 text; the HMAC key is that 44-character *text*, not the
%% decoded bytes (byte-compatible with OpenMuse).
-module(muse_signing).

-export([init/1, sign/2, signed_path/2, verify/4, is_signable_path/1,
         encode_uri_component/1]).

-define(KEY, {?MODULE, key}).
-define(TTL_MS, 900000).

%% @doc Load or create the key file. Concurrent first starts are safe: the
%% key is written to a temp file and published with `link`, which never
%% overwrites; the loser reads the winner's key.
-spec init(file:filename_all()) -> ok.
init(DataDir) ->
    ok = ensure_private_dir(DataDir),
    Path = filename:join(DataDir, "session-signing-key"),
    Key = case file:read_file(Path) of
              {ok, Existing} -> Existing;
              {error, enoent} -> create_key(Path)
          end,
    persistent_term:put(?KEY, Key).

%% @doc Absolute signed URL: `PUBLIC_API_URL ++ Path ++ ?owner=&expires=&signature=`.
-spec sign(binary(), binary()) -> binary().
sign(Owner, Path) ->
    <<(muse_config:get(public_url))/binary, (signed_path(Owner, Path))/binary>>.

%% @doc Path plus signature query, without the origin.
-spec signed_path(binary(), binary()) -> binary().
signed_path(Owner, Path) ->
    Expires = integer_to_binary(muse_time:now_ms() + ?TTL_MS),
    <<Path/binary, "?owner=", (encode_uri_component(Owner))/binary,
      "&expires=", Expires/binary, "&signature=", (mac(Owner, Path, Expires))/binary>>.

%% @doc Check a signed request. `Path` is the request pathname (no query).
-spec verify(binary(), binary() | undefined, binary() | undefined, binary() | undefined) ->
    {ok, binary()} | {error, {401 | 403, binary()}}.
verify(Path, Owner, Expires, Signature) ->
    Expired = {error, {401, <<"Document link expired; refresh the workspace">>}},
    Valid = is_binary(Owner) andalso Owner =/= <<>>
        andalso is_binary(Expires) andalso re:run(Expires, <<"^\\d+$">>, [{capture, none}]) =:= match
        andalso is_binary(Signature) andalso re:run(Signature, <<"^\\w{64}$">>, [{capture, none}]) =:= match,
    case Valid andalso binary_to_integer(Expires) >= muse_time:now_ms() of
        false ->
            Expired;
        true ->
            case crypto:hash_equals(mac(Owner, Path, Expires), Signature) of
                true -> {ok, Owner};
                false -> {error, {403, <<"Invalid access link">>}}
            end
    end.

%% @doc Paths on which a signature replaces Bearer auth (the reply
%% products' zip, M9-11, too).
-spec is_signable_path(binary()) -> boolean().
is_signable_path(Path) ->
    re:run(Path, <<"^/api/(?:files/[^/]+/content|browsers/[^/]+/(?:preview|console)"
                   "|computer/desktop/screenshot|threads/[^/]+/products/[^/]+/zip)$">>,
           [{capture, none}]) =:= match.

%% @doc JavaScript encodeURIComponent.
-spec encode_uri_component(binary()) -> binary().
encode_uri_component(Bin) ->
    << <<(enc(C))/binary>> || <<C>> <= Bin >>.

%% Internal

mac(Owner, Path, Expires) ->
    Key = persistent_term:get(?KEY),
    muse_ids:hex(crypto:mac(hmac, sha256, Key, <<Owner/binary, "\n", Path/binary, "\n", Expires/binary>>)).

enc(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 -> <<C>>;
enc(C) when C =:= $-; C =:= $_; C =:= $.; C =:= $!; C =:= $~; C =:= $*;
            C =:= $'; C =:= $(; C =:= $) -> <<C>>;
enc(C) -> list_to_binary(io_lib:format("%~2.16.0B", [C])).

create_key(Path) ->
    Key = base64:encode(crypto:strong_rand_bytes(32)),
    Tmp = iolist_to_binary([Path, ".", muse_ids:random_token(16), ".tmp"]),
    ok = file:write_file(Tmp, Key, [write, exclusive]),
    ok = file:change_mode(Tmp, 8#600),
    try file:make_link(Tmp, Path) of
        ok -> Key;
        {error, eexist} ->
            {ok, Existing} = file:read_file(Path),
            Existing
    after
        _ = file:delete(Tmp)
    end.

ensure_private_dir(Dir) ->
    ok = filelib:ensure_path(Dir),
    file:change_mode(Dir, 8#700).
