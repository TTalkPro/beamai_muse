%% @doc Chat history: exact messages in the `chat` bitcask (KV) and a BM25
%% index in `chat_index` (jieba analyzer).
%%
%% Implements the `beamai_chat_memory` behaviour, so agents use it as their
%% persistent memory: `{store, muse_chat_log:handle(Owner)}`. Conversation ids
%% are thread ids (uuids), unique across owners.
%%
%% Each message becomes:
%%   chat:       `raw/<Thread>/<Seq>`  term_to_binary of the beamai message
%%   chat_index: `doc/<Thread>/<Seq>`  plain text + meta {owner, thread, role}
%% They live in two casks because an index-mode cask tokenises every binary
%% value, raw ones included. The raw entry is written first; a crash between
%% the two writes only loses searchability of that one message. The index
%% entry is skipped for messages without text (pure tool calls).
-module(muse_chat_log).
-behaviour(beamai_chat_memory).

-export([handle/1, messages/2, search/3, delete_thread/1]).
-export([mem_get/2, mem_add/3, mem_clear/2]).

-define(CASK, chat).
-define(INDEX, chat_index).

-spec handle(binary()) -> beamai_chat_memory:handle().
handle(Owner) ->
    {?MODULE, Owner}.

%% @doc Messages of a thread, oldest first.
-spec messages(binary(), binary()) -> [map()].
messages(_Owner, ThreadId) ->
    [binary_to_term(V, [safe]) || {_K, V} <- muse_cask:range_prefix(?CASK, raw_prefix(ThreadId))].

%% @doc BM25 search over the owner's messages: `[{ThreadId, Seq, Score}]`.
-spec search(binary(), binary(), pos_integer()) -> [{binary(), binary(), float()}].
search(Owner, Query, K) ->
    Filter = #{key => <<"owner">>, op => eq, value => Owner},
    %% The analyzer lowercases indexed Latin text but not queries.
    case bitcask:search_text(muse_cask:handle(?INDEX), string:lowercase(Query), K, Filter) of
        {ok, Hits} ->
            [{Thread, Seq, Score} || {<<"doc/", Rest/binary>>, _Ord, Score} <- Hits,
                                     [Thread, Seq] <- [binary:split(Rest, <<"/">>)]];
        {error, Reason} ->
            error({chat_search, Reason})
    end.

-spec delete_thread(binary()) -> ok | {error, term()}.
delete_thread(ThreadId) ->
    Docs = muse_cask:keys_prefix(?INDEX, doc_prefix(ThreadId)),
    ok = muse_cask:commit(?INDEX, [{remove, Key} || Key <- Docs]),
    Raws = muse_cask:keys_prefix(?CASK, raw_prefix(ThreadId)),
    muse_cask:commit(?CASK, [{remove, Key} || Key <- Raws]).

%% beamai_chat_memory

-spec mem_get(binary(), binary()) -> [map()].
mem_get(Owner, ConvId) ->
    messages(Owner, ConvId).

-spec mem_add(binary(), binary(), [map()]) -> ok.
mem_add(Owner, ConvId, Msgs) ->
    lists:foreach(fun(Msg) -> ok = append(Owner, ConvId, Msg) end, Msgs).

-spec mem_clear(binary(), binary()) -> ok.
mem_clear(_Owner, ConvId) ->
    ok = delete_thread(ConvId).

%% Internal

append(Owner, ThreadId, Msg) ->
    Raw = fun(Seq) -> [{put, <<(raw_prefix(ThreadId))/binary, Seq/binary>>, term_to_binary(Msg)}] end,
    case muse_cask:append(?CASK, Raw, no_sync) of
        {ok, Seq} -> index(Owner, ThreadId, Seq, Msg);
        {error, Reason} -> error({chat_append, Reason})
    end.

index(Owner, ThreadId, Seq, Msg) ->
    case text_of(Msg) of
        <<>> ->
            ok;
        Text ->
            Meta = bitcask:encode_meta(#{<<"owner">> => Owner,
                                         <<"thread">> => ThreadId,
                                         <<"role">> => role_of(Msg)}),
            ok = muse_cask:put(?INDEX, <<(doc_prefix(ThreadId))/binary, Seq/binary>>,
                               #{text => Text, meta => Meta})
    end.

raw_prefix(ThreadId) -> <<"raw/", ThreadId/binary, "/">>.
doc_prefix(ThreadId) -> <<"doc/", ThreadId/binary, "/">>.

role_of(#{role := Role}) when is_atom(Role) -> atom_to_binary(Role, utf8);
role_of(#{role := Role}) when is_binary(Role) -> Role;
role_of(_) -> <<"unknown">>.

text_of(#{content := Content}) -> content_text(Content);
text_of(_) -> <<>>.

content_text(Bin) when is_binary(Bin) -> Bin;
content_text(Parts) when is_list(Parts) ->
    iolist_to_binary(lists:join(<<"\n">>, [T || #{type := text, text := T} <- Parts]));
content_text(_) -> <<>>.
