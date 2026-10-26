%% @doc The chat page (designs/05-web-ui.md §4–§5, tasks M6-2), after
%% OpenMuse's ChatScreen: one centred column with the messages (live replies
%% via muse_chat_relay, tool calls as one-line steps from muse_ui_cards),
%% suggestions on an empty conversation, and a pill composer with send/stop
%% and a visible send queue. The conversation list lives in the shell's
%% drawer (`threads/2`, kept live here on the `threads` topic).
%%
%% `/chat` shows the main thread, `/chat/<threadId>` a side chat.
%% Topics: `threads` (the list), `{thread, Tid}` (log, queue, composer).
-module(muse_ui_chat).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4, threads/2, display_title/1]).
%% for muse_chat_relay and muse_ui_cards
-export([streaming_bubble/1, bubble_id/1, bubble_text_id/1, assistant_bubble/2, error_note/1,
         composer_actions/2, send_next/2, choice_panel/2]).

-define(I, muse_ui_icons).

%%%===================================================================
%%% Page
%%%===================================================================

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    {ok, Main} = muse_threads:main_thread(Owner),
    Thread = case cowboy_req:path_info(Req) of
                 [Id | _] ->
                     case muse_threads:get(Owner, Id) of
                         {ok, T} -> T;
                         _ -> Main
                     end;
                 _ -> Main
             end,
    #{<<"id">> := Tid} = Thread,
    {display_title(Thread),
     ah_div([ah_div(ah_div([thread_bar(Thread),
                            ah_div(log(Owner, Tid), [<<"muse-thread-log">>],
                                   [{id, <<"chat-log">>},
                                    subscribe(muse_ui:topic(Owner, {thread, Tid}),
                                              #{refresh => {?MODULE, refresh, #{thread => Tid}}})])],
                           [<<"muse-log-inner">>], []),
                    [<<"muse-log">>], [{data_ah, <<"muse-scroll">>}]),
             ah_div(ah_div([queue(Thread), composer(Tid)], [<<"muse-dock-inner">>], []),
                    [<<"muse-dock">>], [])],
            [<<"muse-chat">>], [{id, <<"chat-page">>}])}.

%% @doc A thread's title as shown: the main conversation and untitled side
%% chats get Chinese names (their stored titles are OpenMuse's).
-spec display_title(map()) -> binary().
display_title(#{<<"kind">> := <<"main">>}) -> <<"主对话"/utf8>>;
display_title(#{<<"title">> := <<"New chat">>}) -> <<"新对话"/utf8>>;
display_title(#{<<"title">> := Title}) -> Title.

%% Threads (in the shell's drawer)

%% @doc The conversation list; `Current` is the open thread id, `main` for
%% the main conversation, or `undefined` off the chat page.
-spec threads(binary(), binary() | main | undefined) -> aihtml:element().
threads(Owner, Current) ->
    All = lists:sort(fun(A, B) -> sort_key(A) >= sort_key(B) end, muse_threads:list(Owner)),
    {Archived, Active} = lists:partition(fun(T) -> maps:get(<<"archived">>, T, false) =:= true end, All),
    ah_nav([[thread_link(T, Current) || T <- Active],
            case Archived of
                [] -> [];
                _ -> aihtml:ah_el(details, [aihtml:ah_el(summary, <<"已归档"/utf8>>,
                                                         [<<"muse-menu-label cursor-pointer">>], []),
                                            [thread_link(T, Current) || T <- Archived]], [], [])
            end],
           [<<"muse-menu">>], [{id, <<"chat-threads">>}, {aria_label, <<"对话"/utf8>>}]).

sort_key(#{<<"kind">> := <<"main">>}) -> <<"~">>;
sort_key(T) -> maps:get(<<"lastMessageAt">>, T, maps:get(<<"updatedAt">>, T, <<>>)).

thread_link(#{<<"id">> := Id} = T, Current) ->
    Main = maps:get(<<"kind">>, T) =:= <<"main">>,
    Href = case Main of
               true -> <<"/chat">>;
               false -> <<"/chat/", Id/binary>>
           end,
    Here = Id =:= Current orelse (Main andalso Current =:= main),
    ah_a([?I:icon(chat, 18), ah_span(display_title(T), [<<"truncate">>], [])], [<<"muse-menu-link">>],
         [{href, Href}, {aria_current, Here andalso <<"page">>}]).

%% Side chats get a slim bar to rename or archive them.
thread_bar(#{<<"kind">> := <<"main">>}) ->
    ah_div([], [], [{id, <<"chat-header">>}]);
thread_bar(#{<<"id">> := Tid} = T) ->
    Archived = maps:get(<<"archived">>, T, false) =:= true,
    ah_div([ah_span(<<"旁支对话 ·"/utf8>>, [], []),
            ah_form(ah_input(display_title(T), [], [{name, title}, {aria_label, <<"对话标题"/utf8>>}, {maxlength, 120}]),
                    [], [on(submit, {?MODULE, rename, #{thread => Tid}})]),
            case Archived of
                false -> ah_button(?I:icon(archive, 16), archive, [<<"muse-iconbtn">>],
                                   [{type, button}, {aria_label, <<"归档"/utf8>>}, {title, <<"归档"/utf8>>},
                                    on(click, {?MODULE, archive, #{thread => Tid}}, #{confirm => <<"归档这个对话？"/utf8>>})]);
                true -> ah_button(<<"恢复"/utf8>>, restore, [sm, borderless],
                                  [{type, button}, on(click, {?MODULE, restore, #{thread => Tid}})])
            end],
           [<<"muse-thread-bar">>], [{id, <<"chat-header">>}]).

%% Log

log(Owner, Tid) ->
    Messages = case muse_threads:messages(Owner, Tid) of
                   {ok, Ms} -> Ms;
                   _ -> []
               end,
    case render_messages(Owner, Tid, Messages) of
        [] -> [empty(Owner, Tid)];
        Html -> Html
    end.

%% OpenMuse's empty conversation: a greeting and three starters.
empty(Owner, Tid) ->
    {ok, #{<<"identity">> := Identity}} = muse_agent_service:snapshot(Owner),
    Name = case maps:get(<<"name">>, Identity, <<>>) of <<>> -> <<"OpenMuse">>; N -> N end,
    Starters = [<<"去 Hacker News 看看有什么有意思的"/utf8>>, <<"总结一下 copilotkit.ai"/utf8>>,
                <<"看看我今天的日程"/utf8>>],
    ah_div([aihtml:ah_el(h2, <<"一点帮助，给生活多留些余裕。"/utf8>>, [], []),
            ah_p([<<"告诉我你在想什么。"/utf8>>, Name,
                  <<" 可以帮你做计划、处理邮件和日程，也能用自己的电脑替你动手。"/utf8>>], [], []),
            ah_div([ah_button(S, suggest, [<<"muse-suggestion">>],
                              [{type, button}, on(click, {?MODULE, suggest, #{thread => Tid, text => S}})])
                    || S <- Starters], [<<"muse-suggestions">>], [])],
           [<<"muse-empty">>], [{id, <<"chat-empty">>}]).

render_messages(Owner, Tid, Messages) ->
    Results = maps:from_list([{Id, C} || #{role := tool, tool_call_id := Id, content := C} <- Messages]),
    lists:flatmap(fun(M) -> message(Owner, Tid, M, Results) end, number(Messages)).

number(Messages) ->
    lists:zip(lists:seq(1, length(Messages)), Messages).

message(_O, _T, {N, #{role := user, content := Text}}, _R) when is_binary(Text) ->
    [user_bubble(<<"h", (integer_to_binary(N))/binary>>, Text)];
message(Owner, Tid, {N, #{role := assistant} = M}, Results) ->
    Cards = [muse_ui_cards:render(Owner, Tid, Id, Name, args(TC), maps:get(Id, Results, <<"{}">>))
             || #{id := Id, name := Name} = TC <- maps:get(tool_calls, M, [])],
    Text = case maps:get(content, M, null) of
               C when is_binary(C), C =/= <<>> -> [assistant_bubble(<<"h", (integer_to_binary(N))/binary>>, C)];
               _ -> []
           end,
    %% the steps a turn took come before what it says about them
    Cards ++ Text;
message(_O, _T, _M, _R) ->
    [].

args(#{arguments := A}) when is_map(A) -> A;
args(_) -> #{}.

user_bubble(Id, Text) ->
    Shown = case muse_jev:parse_action(Text) of
                {ok, _} -> <<"（已选择一个选项）"/utf8>>;
                _ -> Text
            end,
    ah_div(Shown, [<<"muse-msg-user">>], [{id, bubble_id(Id)}]).

-spec bubble_id(binary()) -> binary().
bubble_id(Mid) -> <<"m-", Mid/binary>>.

-spec bubble_text_id(binary()) -> binary().
bubble_text_id(Mid) -> <<"m-", Mid/binary, "-txt">>.

%% @doc An empty assistant message that streamed text is appended to.
-spec streaming_bubble(binary()) -> aihtml:element().
streaming_bubble(Mid) ->
    ah_div(ah_span([], [<<"muse-bubble">>], [{id, bubble_text_id(Mid)}]),
           [<<"muse-msg-assistant">>], [{id, bubble_id(Mid)}]).

-spec assistant_bubble(binary(), binary()) -> aihtml:element().
assistant_bubble(Mid, Text) ->
    ah_div(ah_markdown_view(Text, [<<"max-w-none">>], []),
           [<<"muse-msg-assistant">>], [{id, bubble_id(Mid)}]).

-spec error_note(binary()) -> aihtml:html().
error_note(Message) ->
    ah_alert(Message, [error], []).

%% Queue and composer

queue(#{<<"id">> := _Tid} = Thread) ->
    case maps:get(<<"pending">>, Thread, []) of
        [] -> ah_div([], [], [{id, <<"chat-queue">>}]);
        Pending ->
            ah_div([ah_div(<<"回复结束后依次发送："/utf8>>, [], []),
                    ah_ol([ah_li(muse_js:slice(P, 200), [<<"truncate">>], []) || P <- Pending],
                          [<<"list-decimal ml-5">>], [])],
                   [<<"muse-queue">>], [{id, <<"chat-queue">>}])
    end.

composer(Tid) ->
    ah_form([aihtml:ah_el(textarea, [], [],
                          [{name, text}, {id, <<"chat-text">>}, {rows, 1}, {data_ah, <<"muse-composer">>},
                           {placeholder, <<"发消息…（Enter 发送，Shift+Enter 换行）"/utf8>>}, {aria_label, <<"消息"/utf8>>}]),
             composer_actions(Tid, muse_chat_relay:running(Tid))],
            [<<"muse-composer">>],
            [{id, <<"chat-composer">>}, on(submit, {?MODULE, send, #{thread => Tid}})]).

%% @doc Send; while a reply runs, stop (Enter then queues the text).
-spec composer_actions(binary(), boolean()) -> aihtml:element().
composer_actions(Tid, true) ->
    ah_div(ah_button(?I:icon(stop, 18), stop, [<<"muse-send muse-send-stop">>],
                     [{type, button}, {aria_label, <<"停止回复"/utf8>>}, {title, <<"停止回复"/utf8>>},
                      on(click, {?MODULE, stop, #{thread => Tid}})]),
           [<<"flex">>], [{id, <<"chat-actions">>}]);
composer_actions(_Tid, false) ->
    ah_div(ah_button(?I:icon(arrow_up, 20), send, [<<"muse-send">>],
                     [{type, submit}, {aria_label, <<"发送"/utf8>>}, {title, <<"发送"/utf8>>}]),
           [<<"flex">>], [{id, <<"chat-actions">>}]).

%% Jev

%% @doc A Jev choice panel (OpenMuse JevToolCard): clicking an option sends
%% the "[OpenMuse choice]" message.
-spec choice_panel(binary(), map()) -> aihtml:element().
choice_panel(Tid, #{<<"id">> := PanelId, <<"title">> := Title, <<"options">> := Options} = Panel) ->
    Selected = maps:get(<<"selectedId">>, Panel, undefined),
    ah_div([ah_div(Title, [<<"font-medium mb-2">>], []),
            ah_div([option(Tid, Panel, PanelId, O, Selected) || O <- Options], [<<"grid gap-2 sm:grid-cols-2">>], [])],
           [<<"muse-card">>], [{id, <<"jev-", PanelId/binary>>}]).

option(Tid, Panel, PanelId, #{<<"id">> := OptionId, <<"label">> := Label} = O, Selected) ->
    Action = #{thread => Tid, panel => PanelId, option => OptionId,
               version => maps:get(<<"candidateSetVersion">>, Panel, 1),
               panel_thread => maps:get(<<"threadId">>, Panel, Tid)},
    ah_div([ah_div(Label, [<<"font-medium">>], []),
            ah_ul([ah_li(D, [], []) || D <- maps:get(<<"details">>, O, [])], [<<"text-sm list-disc ml-5">>], []),
            ah_div([ah_a(maps:get(<<"title">>, S, <<>>), [<<"text-xs text-primary mr-2">>],
                         [{href, maps:get(<<"url">>, S, <<>>)}, {target, <<"_blank">>}, {rel, <<"noopener noreferrer">>}])
                    || S <- maps:get(<<"sources">>, O, [])], [], []),
            case Selected of
                undefined -> ah_button(<<"选这个"/utf8>>, choose, [sm, primary, <<"mt-2">>],
                                       [on(click, {?MODULE, choose, Action})]);
                OptionId -> ah_chip(<<"已选择"/utf8>>, [<<"mt-2">>], []);
                _ -> []
            end],
           [<<"rounded-2xl border border-line p-3">>], []).

%%%===================================================================
%%% Live updates
%%%===================================================================

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {thread, Tid}) ->
    muse_ui:publish(Owner, threads,
                    fun(C) -> aihtml_action:html(C, {id, <<"chat-threads">>}, threads(Owner, Tid), morph) end),
    case muse_threads:get(Owner, Tid) of
        {ok, Thread} ->
            muse_ui:publish(Owner, {thread, Tid},
                            fun(C) -> aihtml_action:html(C, {id, <<"chat-queue">>}, queue(Thread), outer) end);
        _ -> ok
    end;
on_event(_Owner, _Event) ->
    ok.

%%%===================================================================
%%% Actions
%%%===================================================================

-spec action(atom(), map(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(Name, Args, Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> act(Name, Args, Event, Ctx, Owner) end).

act(send, #{thread := Tid}, #{form := Form}, Ctx, Owner) ->
    Text = string:trim(maps:get(<<"text">>, Form, <<>>)),
    case {Text, muse_threads:get(Owner, Tid)} of
        {<<>>, _} -> ok;
        {_, {error, {_, Msg}}} -> ah_toast(Ctx, Msg, #{});
        {_, {ok, _}} ->
            aihtml_action:set_value(Ctx, {id, <<"chat-text">>}, <<>>),
            case muse_chat_relay:running(Tid) of
                true -> {ok, _} = muse_threads:enqueue(Owner, Tid, Text), ok;
                false -> start(Owner, Tid, Text, Ctx)
            end
    end;
act(suggest, #{thread := Tid, text := Text}, _Event, Ctx, Owner) ->
    case {muse_threads:get(Owner, Tid), muse_chat_relay:running(Tid)} of
        {{ok, _}, false} -> start(Owner, Tid, Text, Ctx);
        _ -> ok
    end;
act(stop, #{thread := Tid}, _Event, _Ctx, Owner) ->
    case muse_threads:get(Owner, Tid) of
        {ok, _} -> _ = muse_chat:stop(Tid), ok;
        _ -> ok
    end;
act(choose, #{thread := Tid, panel := Panel, option := Option, version := Version, panel_thread := PT}, _E, Ctx, Owner) ->
    Text = <<(muse_jev:action_prefix())/binary,
             (muse_json:encode(#{<<"panelId">> => Panel, <<"threadId">> => PT,
                                 <<"candidateSetVersion">> => Version, <<"optionId">> => Option}))/binary>>,
    case muse_chat_relay:running(Tid) of
        true -> ah_toast(Ctx, <<"请等当前回复结束后再选择"/utf8>>, #{});
        false -> start(Owner, Tid, Text, Ctx)
    end;
act(refresh, #{thread := Tid}, _Event, Ctx, Owner) ->
    case muse_threads:get(Owner, Tid) of
        {ok, Thread} ->
            aihtml_action:html(Ctx, {id, <<"chat-log">>}, log(Owner, Tid), inner),
            aihtml_action:html(Ctx, {id, <<"chat-queue">>}, queue(Thread), outer),
            aihtml_action:html(Ctx, {id, <<"chat-actions">>}, composer_actions(Tid, muse_chat_relay:running(Tid)), outer);
        _ -> ok
    end;
act(new_thread, _Args, _Event, Ctx, Owner) ->
    {ok, #{<<"id">> := Id}} = muse_threads:create_side(Owner, undefined),
    aihtml_action:redirect(Ctx, <<"/chat/", Id/binary>>);
act(rename, #{thread := Tid}, #{form := Form}, Ctx, Owner) ->
    case muse_threads:rename(Owner, Tid, maps:get(<<"title">>, Form, <<>>)) of
        {ok, _} -> aihtml_action:title(Ctx, <<(maps:get(<<"title">>, Form))/binary, " · OpenMuse"/utf8>>);
        {error, {_, Msg}} -> ah_toast(Ctx, Msg, #{variant => error})
    end;
act(archive, #{thread := Tid}, _Event, Ctx, Owner) ->
    case muse_threads:archive(Owner, Tid) of
        {ok, _} -> aihtml_action:redirect(Ctx, <<"/chat">>);
        {error, {_, Msg}} -> ah_toast(Ctx, Msg, #{variant => error})
    end;
act(restore, #{thread := Tid}, _Event, Ctx, Owner) ->
    case muse_threads:restore(Owner, Tid) of
        {ok, _} -> aihtml_action:redirect(Ctx, <<"/chat/", Tid/binary>>);
        {error, {_, Msg}} -> ah_toast(Ctx, Msg, #{variant => error})
    end;
act(search, _Args, #{form := Form}, Ctx, Owner) ->
    Q = string:lowercase(string:trim(maps:get(<<"q">>, Form, <<>>))),
    Html = case Q of
               <<>> -> [];
               _ ->
                   case muse_threads:search(Owner, Q, 10) of
                       [] -> ah_p(<<"没有结果"/utf8>>, [<<"text-sm text-muted py-1">>], []);
                       Hits -> ah_ul([ah_li(ah_a(case T of <<>> -> Id; _ -> T end, [<<"muse-menu-link text-sm">>],
                                                 [{href, <<"/chat/", Id/binary>>}]), [], [])
                                      || #{<<"thread">> := Id, <<"title">> := T} <- Hits], [], [])
                   end
           end,
    aihtml_action:html(Ctx, {id, <<"chat-search">>}, Html, inner).

%% Start a turn: the user's bubble and the stop button go to every page
%% watching the thread, then the relay streams the reply. A busy thread
%% queues the text instead.
start(Owner, Tid, Text, Ctx) ->
    case begin_turn(Owner, Tid, Text) of
        ok -> ok;
        busy -> {ok, _} = muse_threads:enqueue(Owner, Tid, Text), ok;
        {error, Msg} -> aihtml_action:html(Ctx, {id, <<"chat-log">>}, error_note(Msg), append)
    end.

begin_turn(Owner, Tid, Text) ->
    case muse_chat:start_turn(Owner, Tid, Text, #{}) of
        {started, _RunId, Since, Session} ->
            muse_ui:publish(Owner, {thread, Tid},
                            fun(C) ->
                                    aihtml_action:remove(C, {id, <<"chat-empty">>}),
                                    aihtml_action:html(C, {id, <<"chat-log">>}, user_bubble(muse_ids:uuid(), Text), append),
                                    aihtml_action:html(C, {id, <<"chat-actions">>}, composer_actions(Tid, true), outer)
                            end),
            muse_chat_relay:start(Owner, Tid, Session, Since);
        {busy, _} -> busy;
        {error, Msg} -> {error, Msg}
    end.

%% @doc After a run: start the next queued message, if any.
-spec send_next(binary(), binary()) -> ok.
send_next(Owner, Tid) ->
    case muse_threads:dequeue(Owner, Tid) of
        {ok, Text} ->
            case begin_turn(Owner, Tid, Text) of
                ok -> ok;
                busy -> {ok, _} = muse_threads:enqueue(Owner, Tid, Text), ok;
                {error, Msg} ->
                    muse_ui:publish(Owner, {thread, Tid},
                                    fun(C) -> aihtml_action:html(C, {id, <<"chat-log">>}, error_note(Msg), append) end)
            end;
        empty -> ok
    end.
