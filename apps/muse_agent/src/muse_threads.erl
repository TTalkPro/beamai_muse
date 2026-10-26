%% @doc Conversation threads (replaces CopilotKit Intelligence "Rich
%% Threads", designs/03-agent.md §7). The UI treats every thread alike:
%% any number of conversations, each with its own reply running
%% independently, pinned, renamed or deleted. Messages live in
%% `muse_chat_log`.
%%
%% Record `threads/<id>`: `{id, title, kind: main | side | chat, archived,
%% pinned, attention, unread, createdAt, updatedAt, lastMessageAt?, pending:
%% [Text]}`. `pending` is the visible send queue: one run per thread at a
%% time; text typed while a reply is running waits there (OpenMuse
%% conversation-queue). `attention` marks a reply that ended in an error,
%% `unread` a reply that finished since the conversation was last opened.
%% The main thread (`conversation-settings/main`, OpenMuse
%% `/api/main-thread`) and archiving remain for the JSON API only.
-module(muse_threads).

-export([main_thread/1, list/1, get/2, create/3, create_side/2, rename/3, archive/2, restore/2,
         pin/3, delete/2, mark/3, title_from/1, default_title/1,
         touch/2, messages/2, search/3, enqueue/3, dequeue/2]).

-define(KIND, <<"threads">>).

-type owner() :: binary().
-type error() :: {error, {pos_integer(), binary()}}.

%% @doc The owner's main thread, created on first use.
-spec main_thread(owner()) -> {ok, map()}.
main_thread(Owner) ->
    _ = muse_store:insert_if_absent(Owner, <<"conversation-settings">>,
                                    #{<<"id">> => <<"main">>, <<"threadId">> => muse_ids:uuid(),
                                      <<"existing">> => false}),
    #{<<"threadId">> := Id} = muse_store:get(Owner, <<"conversation-settings">>, <<"main">>),
    _ = muse_store:insert_if_absent(Owner, ?KIND, new(Id, <<"Main conversation">>, <<"main">>)),
    {ok, muse_store:get(Owner, ?KIND, Id)}.

-spec list(owner()) -> [map()].
list(Owner) ->
    muse_store:list(Owner, ?KIND).

%% @doc A new conversation with a given id (the chat page picks the id
%% before the first message, so its page already follows the thread) and a
%% title, usually `title_from/1` of the first message.
-spec create(owner(), binary(), binary()) -> {ok, map()} | error().
create(Owner, Id, Title0) ->
    maybe
        {ok, Title} ?= title(Title0, undefined),
        true ?= muse_ids:is_uuid(Id) orelse {error, {422, <<"Invalid thread id">>}},
        Thread = new(Id, Title, <<"chat">>),
        _ = muse_store:insert_if_absent(Owner, ?KIND, Thread),
        muse_events:emit(Owner, {thread, Id}),
        get(Owner, Id)
    end.

%% @doc A short title from a first message: its first line, at most 40
%% characters.
-spec title_from(binary()) -> binary().
title_from(Text) ->
    [Line | _] = string:split(string:trim(Text), <<"\n">>),
    case string:trim(Line) of
        <<>> -> <<"新会话"/utf8>>;
        L -> muse_js:slice(L, 40)
    end.

%% @doc Whether a thread still has a default title (renamed on its first
%% message).
-spec default_title(map()) -> boolean().
default_title(#{<<"title">> := T}) -> lists:member(T, [<<"New chat">>, <<"新会话"/utf8>>]);
default_title(_) -> false.

%% @doc Pin or unpin a conversation.
-spec pin(owner(), binary(), boolean()) -> {ok, map()} | error().
pin(Owner, Id, Pinned) when is_boolean(Pinned) ->
    patch(Owner, Id, #{<<"pinned">> => Pinned}).

%% @doc Delete a conversation: its reply is stopped, its messages and the
%% record removed.
-spec delete(owner(), binary()) -> ok | error().
delete(Owner, Id) ->
    case get(Owner, Id) of
        {ok, _} ->
            _ = catch muse_chat:stop(Id),
            _ = muse_chat_log:delete_thread(Id),
            ok = muse_store:remove(Owner, ?KIND, Id),
            muse_events:emit(Owner, {thread, Id}),
            ok;
        Error ->
            Error
    end.

%% @doc Set the display marks of a conversation: `#{attention, unread}`.
-spec mark(owner(), binary(), map()) -> ok.
mark(Owner, Id, Marks) ->
    Patch = maps:with([<<"attention">>, <<"unread">>], Marks),
    case muse_store:get(Owner, ?KIND, Id) of
        undefined -> ok;
        Thread ->
            case maps:with(maps:keys(Patch), Thread) =:= Patch of
                true -> ok;
                false -> _ = patch(Owner, Id, Patch), ok
            end
    end.

-spec get(owner(), binary()) -> {ok, map()} | error().
get(Owner, Id) ->
    case muse_store:get(Owner, ?KIND, Id) of
        undefined -> {error, {404, <<"Thread not found">>}};
        Thread -> {ok, Thread}
    end.

-spec create_side(owner(), binary() | undefined) -> {ok, map()} | error().
create_side(Owner, Title0) ->
    case title(Title0, <<"New chat">>) of
        {ok, Title} ->
            Thread = new(muse_ids:uuid(), Title, <<"side">>),
            _ = muse_store:put(Owner, ?KIND, Thread),
            muse_events:emit(Owner, {thread, maps:get(<<"id">>, Thread)}),
            {ok, Thread};
        Error ->
            Error
    end.

-spec rename(owner(), binary(), binary()) -> {ok, map()} | error().
rename(Owner, Id, Title0) ->
    maybe
        {ok, Title} ?= title(Title0, undefined),
        patch(Owner, Id, #{<<"title">> => Title})
    end.

%% @doc Archive a side chat (the main thread cannot be archived).
-spec archive(owner(), binary()) -> {ok, map()} | error().
archive(Owner, Id) ->
    case get(Owner, Id) of
        {ok, #{<<"kind">> := <<"main">>}} -> {error, {409, <<"The main conversation cannot be archived">>}};
        {ok, _} -> patch(Owner, Id, #{<<"archived">> => true});
        Error -> Error
    end.

-spec restore(owner(), binary()) -> {ok, map()} | error().
restore(Owner, Id) ->
    patch(Owner, Id, #{<<"archived">> => false}).

%% @doc Record activity (a new message) on a thread.
-spec touch(owner(), binary()) -> ok.
touch(Owner, Id) ->
    _ = muse_store:cas(Owner, ?KIND, Id, #{}, #{<<"lastMessageAt">> => muse_time:now_iso(),
                                               <<"updatedAt">> => muse_time:now_iso()}),
    ok.

%% @doc The thread's messages (beamai message maps), oldest first.
-spec messages(owner(), binary()) -> {ok, [map()]} | error().
messages(Owner, Id) ->
    maybe
        {ok, _} ?= get(Owner, Id),
        {ok, muse_chat_log:messages(Owner, Id)}
    end.

%% @doc BM25 search over the owner's messages: `[#{thread, title, score}]`,
%% best first, one entry per thread.
-spec search(owner(), binary(), pos_integer()) -> [map()].
search(Owner, Query, Limit) ->
    Hits = muse_chat_log:search(Owner, Query, Limit * 3),
    Best = lists:foldl(fun({T, _Seq, Score}, Acc) ->
                               case maps:find(T, Acc) of
                                   {ok, S} when S >= Score -> Acc;
                                   _ -> Acc#{T => Score}
                               end
                       end, #{}, Hits),
    Ranked = lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(Best))), Limit),
    [#{<<"thread">> => T, <<"score">> => S,
       <<"title">> => case muse_store:get(Owner, ?KIND, T) of
                          #{<<"title">> := Title} -> Title;
                          _ -> <<>>
                      end} || {T, S} <- Ranked].

%% @doc Queue text while a reply is running.
-spec enqueue(owner(), binary(), binary()) -> {ok, map()} | error().
enqueue(Owner, Id, Text) ->
    case muse_store:update(Owner, ?KIND, Id,
                           fun(T) -> {ok, T#{<<"pending">> => maps:get(<<"pending">>, T, []) ++ [Text]}} end) of
        undefined -> {error, {404, <<"Thread not found">>}};
        Saved -> muse_events:emit(Owner, {thread, Id}), {ok, Saved}
    end.

%% @doc Take the next queued text, if any.
-spec dequeue(owner(), binary()) -> {ok, binary()} | empty.
dequeue(Owner, Id) ->
    Self = self(),
    Ref = make_ref(),
    Saved = muse_store:update(Owner, ?KIND, Id,
                              fun(#{<<"pending">> := [Next | Rest]} = T) ->
                                      Self ! {Ref, Next},
                                      {ok, T#{<<"pending">> => Rest}};
                                 (_) -> abort
                              end),
    case Saved of
        undefined -> empty;
        _ ->
            %% the transaction may retry; the last message wins
            Next = last_message(Ref, undefined),
            muse_events:emit(Owner, {thread, Id}),
            {ok, Next}
    end.

last_message(Ref, Acc) ->
    receive {Ref, V} -> last_message(Ref, V) after 0 -> Acc end.

%% Internal

new(Id, Title, Kind) ->
    Now = muse_time:now_iso(),
    #{<<"id">> => Id, <<"title">> => Title, <<"kind">> => Kind, <<"archived">> => false,
      <<"pinned">> => false, <<"createdAt">> => Now, <<"updatedAt">> => Now, <<"pending">> => []}.

patch(Owner, Id, Patch) ->
    case muse_store:cas(Owner, ?KIND, Id, #{}, Patch#{<<"updatedAt">> => muse_time:now_iso()}) of
        undefined -> {error, {404, <<"Thread not found">>}};
        Saved -> muse_events:emit(Owner, {thread, Id}), {ok, Saved}
    end.

title(undefined, Default) when is_binary(Default) -> {ok, Default};
title(Raw, _) ->
    muse_validate:parse({string, #{trim => true, min => 1, max => 120}}, Raw).
