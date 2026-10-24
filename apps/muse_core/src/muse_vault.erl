%% @doc Credential encryption, byte-compatible with OpenMuse vault.ts
%% (designs/ref/openmuse-integrations-spec.md §10).
%%
%% AES-256-GCM, random 12-byte nonce, 16-byte tag, AAD
%% `openmuse:credential:v1`. Envelope: `v1.<nonce>.<tag>.<ciphertext>`, each
%% part unpadded base64url. The key is canonical padded base64 of 32 bytes.
-module(muse_vault).

-export([check_key/1, encrypt/2, decrypt/2]).

-define(AAD, <<"openmuse:credential:v1">>).

-spec check_key(binary() | undefined) -> {ok, binary()} | {error, binary()}.
check_key(KeyB64) when is_binary(KeyB64) ->
    try base64:decode(KeyB64) of
        Key when byte_size(Key) =:= 32 ->
            case base64:encode(Key) =:= KeyB64 of
                true -> {ok, Key};
                false -> key_error()
            end;
        _ ->
            key_error()
    catch
        _:_ -> key_error()
    end;
check_key(_) ->
    key_error().

-spec encrypt(binary(), binary()) -> binary().
encrypt(KeyB64, Plain) ->
    {ok, Key} = check_key(KeyB64),
    Nonce = crypto:strong_rand_bytes(12),
    {Ct, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Plain, ?AAD, 16, true),
    iolist_to_binary(["v1.", b64(Nonce), ".", b64(Tag), ".", b64(Ct)]).

-spec decrypt(binary(), binary()) -> {ok, binary()} | {error, binary()}.
decrypt(KeyB64, Envelope) ->
    case check_key(KeyB64) of
        {ok, Key} ->
            case parts(Envelope) of
                {ok, Nonce, Tag, Ct} ->
                    case crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Ct, ?AAD, Tag, false) of
                        error -> {error, <<"Unable to authenticate or decrypt credential">>};
                        Plain -> {ok, Plain}
                    end;
                error ->
                    {error, <<"Invalid encrypted secret">>}
            end;
        Error ->
            Error
    end.

%% Internal

key_error() ->
    {error, <<"Credential encryption requires a 32-byte base64 key">>}.

parts(Envelope) when is_binary(Envelope) ->
    case binary:split(Envelope, <<".">>, [global]) of
        [<<"v1">>, N, T, C] ->
            case {unb64(N), unb64(T), unb64(C)} of
                {{ok, Nonce}, {ok, Tag}, {ok, Ct}}
                  when byte_size(Nonce) =:= 12, byte_size(Tag) =:= 16 ->
                    {ok, Nonce, Tag, Ct};
                _ ->
                    error
            end;
        _ ->
            error
    end;
parts(_) ->
    error.

b64(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).

%% Decode and require a canonical round trip, like the TypeScript vault.
unb64(Text) ->
    try base64:decode(Text, #{mode => urlsafe, padding => false}) of
        Bin ->
            case b64(Bin) =:= Text of
                true -> {ok, Bin};
                false -> error
            end
    catch
        _:_ -> error
    end.
