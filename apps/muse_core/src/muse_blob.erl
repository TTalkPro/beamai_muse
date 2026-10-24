%% @doc Large binary objects in the `blobs` bitcask: PDF bytes, screenshots,
%% monitor page snapshots (designs/01-store.md §2.1).
%%
%% Write blobs before the Mnesia metadata that points at them; orphans left
%% by a crash in between are collected by `orphans/2` during maintenance.
-module(muse_blob).

-export([put/2, get/1, delete/1, keys/1, orphans/2]).

-define(CASK, blobs).

-spec put(binary(), binary()) -> ok | {error, term()}.
put(Key, Bin) when is_binary(Bin) ->
    muse_cask:put(?CASK, Key, Bin).

-spec get(binary()) -> {ok, binary()} | not_found.
get(Key) ->
    case bitcask:get(muse_cask:handle(?CASK), Key) of
        {ok, Bin} -> {ok, Bin};
        not_found -> not_found;
        {error, Reason} -> error({blob_read, Key, Reason})
    end.

-spec delete(binary()) -> ok | {error, term()}.
delete(Key) ->
    muse_cask:delete(?CASK, Key).

-spec keys(binary()) -> [binary()].
keys(Prefix) ->
    muse_cask:keys_prefix(?CASK, Prefix).

%% @doc Keys under `Prefix` for which `Live(Key)` is false.
-spec orphans(binary(), fun((binary()) -> boolean())) -> [binary()].
orphans(Prefix, Live) ->
    [K || K <- keys(Prefix), not Live(K)].
