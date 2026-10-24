%% @doc Identifiers and digests shared by every OpenMuse record.
%%
%% Most derived ids are `sha256hex` of a plain string concatenation and are
%% built inline by their owners (see designs/ref/openmuse-engine-spec.md);
%% the helpers here cover the ones with extra structure.
-module(muse_ids).

-export([uuid/0, is_uuid/1, sha256hex/1, hex/1,
         deterministic_file_id/2,
         chat_key/3, random_token/1]).

%% @doc Random v4 UUID, lowercase.
-spec uuid() -> binary().
uuid() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    format_uuid(<<A:48, 4:4, B:12, 2:2, C:62>>).

%% @doc v1-v8 UUID check used for file, browser and worker ids
%% (`^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`, case-insensitive).
-spec is_uuid(term()) -> boolean().
is_uuid(Bin) when is_binary(Bin), byte_size(Bin) =:= 36 ->
    re:run(Bin, <<"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$">>,
           [caseless, {capture, none}]) =:= match;
is_uuid(_) ->
    false.

-spec sha256hex(iodata()) -> binary().
sha256hex(Data) ->
    hex(crypto:hash(sha256, Data)).

-spec hex(binary()) -> binary().
hex(Bin) ->
    binary:encode_hex(Bin, lowercase).

%% @doc `deterministicFileId(owner, operationKey)` from files.ts: the first
%% 16 bytes of sha256(JSON.stringify([owner, key])) stamped as a v5 UUID.
-spec deterministic_file_id(binary(), binary()) -> binary().
deterministic_file_id(Owner, Key) ->
    <<B0:6/binary, B6, B7, B8, Rest:7/binary, _/binary>> =
        crypto:hash(sha256, muse_json:encode([Owner, Key])),
    format_uuid(<<B0/binary, ((B6 band 16#0f) bor 16#50), B7,
                  ((B8 band 16#3f) bor 16#80), Rest/binary>>).

%% @doc Chat idempotency key: `<requestKey>:<name>:<sha256hex(JSON(value))>`.
-spec chat_key(binary(), binary(), muse_json:json()) -> binary().
chat_key(RequestKey, Name, Value) ->
    <<RequestKey/binary, ":", Name/binary, ":",
      (sha256hex(muse_json:encode(Value)))/binary>>.

%% @doc Random bytes as lowercase hex (session tokens, PKCE verifiers).
-spec random_token(pos_integer()) -> binary().
random_token(Bytes) ->
    hex(crypto:strong_rand_bytes(Bytes)).

format_uuid(<<A:4/binary, B:2/binary, C:2/binary, D:2/binary, E:6/binary>>) ->
    <<(hex(A))/binary, "-", (hex(B))/binary, "-", (hex(C))/binary, "-",
      (hex(D))/binary, "-", (hex(E))/binary>>.
