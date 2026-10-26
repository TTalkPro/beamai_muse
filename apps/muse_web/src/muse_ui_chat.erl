%% @doc The chat page (designs/05-web-ui.md §4–§5, tasks M6-2, M9-2).
%%
%% Every conversation is alike and any number of them can reply at the
%% same time; a reply runs on the server (beamai_agui session) until it is
%% done or the user stops it, whether or not a page watches it.
%%
%% `/chat` is a new conversation: a greeting, the composer and starters.
%% Its thread id is chosen when the page renders, so the page already
%% follows `{thread, Tid}`; the first message creates the conversation
%% (titled after the message), starts the reply and puts `/chat/<id>` in
%% the address bar. `/chat/<id>` shows a conversation: its messages (live
%% via muse_chat_relay; the steps between two texts folded into a group of
%% one-line steps from muse_ui_cards), the send queue and the composer.
%% A browser help request (`request_takeover`), a proposed calendar
%% change (`propose_calendar_change`, its approval card) and a proposed send
%% (`propose_mail_send`, likewise) are not folded
%% with the steps: their cards stand in the log. The help request's
%% "处理好了，继续" (`continue`) sends "我已经处理好了，请继续。" through the
%% same path as the composer.
%%
%% The conversation list in the shell's sidebar is `threads/1`: pinned and
%% other conversations, each with its status dot (replying, new reply,
%% needs attention) and a menu (pin, rename, delete), re-rendered on the
%% `threads` topic. Topics: `threads`, `{thread, Tid}` (log, queue,
%% composer).
%%
%% A reply that made files (M9-11, muse_chat_products) ends with the
%% "全部文件" card (muse_ui_products) inside its last text bubble, after
%% the text and before the message tools; a reply without text there gets
%% the card on its own after its steps. The page carries the card's
%% preview window.
-module(muse_ui_chat).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4, threads/1, thread_menu/1, display_title/1, log/2]).
%% for muse_chat_relay and muse_ui_cards
-export([streaming_bubble/1, bubble_id/1, bubble_text_id/1, assistant_bubble/2, error_note/1,
         composer_actions/2, send_next/2, choice_panel/2,
         step_group/3, group_list_id/1, group_summary_id/1, group_summary/2]).

-define(I, muse_ui_icons).
-define(STARTERS, [<<"去 Hacker News 看看有什么有意思的"/utf8>>, <<"总结一下 copilotkit.ai"/utf8>>,
                   <<"在电脑上写一个 Python 脚本统计词频"/utf8>>, <<"帮我把一份 PDF 表单填好"/utf8>>]).

%%%===================================================================
%%% Page
%%%===================================================================

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    case cowboy_req:path_info(Req) of
        [Id | _] ->
            case muse_threads:get(Owner, Id) of
                {ok, Thread} ->
                    ok = muse_threads:mark(Owner, Id, #{<<"unread">> => false}),
                    {display_title(Thread), page(Owner, Id, existing)};
                _ ->
                    {<<"新会话"/utf8>>, page(Owner, muse_ids:uuid(), new)}
            end;
        _ ->
            {<<"新会话"/utf8>>, page(Owner, muse_ids:uuid(), new)}
    end.

page(Owner, Tid, Kind) ->
    Thread = case muse_threads:get(Owner, Tid) of
                 {ok, T} -> T;
                 _ -> #{<<"id">> => Tid}
             end,
    Log = case Kind of
              new -> [];
              existing -> log(Owner, Tid)
          end,
    Empty = Log =:= [],
    ah_div([ah_div(ah_div([greeting(Owner),
                           ah_div(Log, [<<"muse-thread-log">>],
                                  [{id, <<"chat-log">>},
                                   subscribe(muse_ui:topic(Owner, {thread, Tid}),
                                             #{refresh => {?MODULE, refresh, #{thread => Tid}}})])],
                          [<<"muse-log-inner">>], []),
                   [<<"muse-log">>], [{data_ah, <<"muse-scroll">>}]),
            ah_div(ah_div([queue(Thread), composer(Tid, Kind),
                           ah_div([ah_button(S, suggest, [<<"muse-chip">>],
                                             [{type, button}, on(click, {?MODULE, suggest, #{thread => Tid, text => S}})])
                                   || S <- ?STARTERS],
                                  [<<"muse-chips">>], [])],
                          [<<"muse-dock-inner">>], []),
                   [<<"muse-dock">>], []),
            muse_ui_products:window()],
           [<<"muse-chat">>, case Empty of true -> <<"muse-chat-empty">>; false -> <<>> end],
           [{id, <<"chat-page">>}, {data_thread, Tid}]).

%% Shown while the conversation has no messages (CSS: .muse-chat-empty).
greeting(Owner) ->
    {ok, #{<<"identity">> := Identity}} = muse_agent_service:snapshot(Owner),
    Name = case maps:get(<<"name">>, Identity, <<>>) of <<>> -> <<"BeamAI Muse">>; N -> N end,
    ah_div([aihtml:ah_el(h2, <<"今天想让我做点什么？"/utf8>>, [], []),
            ah_p([Name, <<" 可以帮你做计划、查资料、填写 PDF 表单，也能用自己的电脑动手；几件事可以同时交给我。"/utf8>>],
                 [], [])],
           [<<"muse-greeting">>], [{id, <<"chat-empty">>}]).

%% @doc A thread's title as shown (stored default titles are OpenMuse's).
-spec display_title(map()) -> binary().
display_title(#{<<"kind">> := <<"main">>, <<"title">> := <<"Main conversation">>}) -> <<"主会话"/utf8>>;
display_title(#{<<"title">> := <<"New chat">>}) -> <<"新会话"/utf8>>;
display_title(#{<<"title">> := Title}) -> Title;
display_title(_) -> <<"新会话"/utf8>>.

%%%===================================================================
%%% Conversation list (in the shell's sidebar)
%%%===================================================================

%% @doc Pinned and other conversations, most recent first. The open
%% conversation is marked in the browser (muse.js), so one rendering
%% serves every page.
-spec threads(binary()) -> aihtml:element().
threads(Owner) ->
    All = lists:sort(fun(A, B) -> sort_key(A) >= sort_key(B) end,
                     [T || T <- muse_threads:list(Owner), maps:get(<<"archived">>, T, false) =/= true]),
    {Pinned, Rest} = lists:partition(fun(T) -> maps:get(<<"pinned">>, T, false) =:= true end, All),
    Group = fun(_Label, []) -> [];
               (Label, Ts) ->
                    aihtml:ah_el(details,
                                 [aihtml:ah_el(summary, [Label, ?I:icon(chevron_down, 14)], [<<"muse-group-label">>], []),
                                  ah_ul([thread_row(T) || T <- Ts], [<<"muse-thread-list">>], [])],
                                 [<<"muse-group">>], [{open, true}])
            end,
    ah_div([Group(<<"置顶"/utf8>>, Pinned),
            case {Pinned, Rest} of
                {[], []} -> ah_p(<<"还没有会话"/utf8>>, [<<"muse-group-empty">>], []);
                _ -> Group(<<"会话"/utf8>>, Rest)
            end],
           [], [{id, <<"chat-threads">>}]).

sort_key(T) -> maps:get(<<"lastMessageAt">>, T, maps:get(<<"updatedAt">>, T, <<>>)).

thread_row(#{<<"id">> := Id} = T) ->
    Menu = <<"tm-", Id/binary>>,
    ah_li([ah_a([status_dot(T), ah_span(display_title(T), [<<"muse-thread-title">>], [])],
                [<<"muse-thread-link">>], [{href, <<"/chat/", Id/binary>>}]),
           ah_button(?I:icon(more, 16), more, [<<"muse-thread-more">>],
                     [{type, button}, {aria_label, <<"会话操作"/utf8>>} | toggles({id, Menu})]),
           ah_popover(thread_menu(T), [right], [{id, Menu}, {width, 170}])],
          [<<"muse-thread">>], [{id, <<"thread-", Id/binary>>}, {data_thread, Id}]).

%% The status of a conversation: replying (blue, pulsing), needs attention
%% (orange warning: its last reply failed), a new reply (blue), or idle.
status_dot(#{<<"id">> := Id} = T) ->
    case {muse_chat_relay:running(Id), maps:get(<<"attention">>, T, false), maps:get(<<"unread">>, T, false)} of
        {true, _, _} -> ah_span([], [<<"muse-sdot muse-sdot-running">>], [{title, <<"正在回复"/utf8>>}]);
        {_, true, _} -> ah_span(?I:icon(warning, 14), [<<"muse-sdot-attention">>], [{title, <<"需要你看一下"/utf8>>}]);
        {_, _, true} -> ah_span([], [<<"muse-sdot muse-sdot-unread">>], [{title, <<"有新回复"/utf8>>}]);
        _ -> ah_span([], [<<"muse-sdot">>], [])
    end.

%% @doc A conversation's menu: pin or unpin, rename (the shell's dialog),
%% delete.
-spec thread_menu(map()) -> aihtml:element().
thread_menu(#{<<"id">> := Id} = T) ->
    Pinned = maps:get(<<"pinned">>, T, false) =:= true,
    ah_div([ah_button([?I:icon(pin, 16), case Pinned of true -> <<"取消置顶"/utf8>>; false -> <<"置顶"/utf8>> end],
                      pin, [<<"muse-pop-item">>],
                      [{type, button}, on(click, {?MODULE, pin, #{thread => Id, pinned => not Pinned}})]),
            ah_button([?I:icon(pencil, 16), <<"重命名"/utf8>>], rename, [<<"muse-pop-item">>],
                      [{type, button}, {data_muse_rename, Id}, {data_title, display_title(T)}]),
            ah_button([?I:icon(trash, 16), <<"删除"/utf8>>], delete, [<<"muse-pop-item muse-pop-danger">>],
                      [{type, button},
                       on(click, {?MODULE, delete, #{thread => Id}},
                          #{confirm => #{title => <<"删除会话"/utf8>>,
                                         body => <<"对话记录会一起删除，无法恢复。"/utf8>>,
                                         ok => <<"删除"/utf8>>, cancel => <<"取消"/utf8>>, variant => danger}})])],
           [<<"muse-pop-menu">>], []).

%%%===================================================================
%%% Log
%%%===================================================================

%% @doc The rendered messages of a thread.
-spec log(binary(), binary()) -> aihtml:html().
log(Owner, Tid) ->
    Messages = case muse_threads:messages(Owner, Tid) of
                   {ok, Ms} -> Ms;
                   _ -> []
               end,
    Results = maps:from_list([{Id, C} || #{role := tool, tool_call_id := Id, content := C} <- Messages]),
    Numbered = number(Messages),
    LastUser = lists:max([0 | [N || {N, #{role := user}} <- Numbered]]),
    Cards = product_cards(Owner, Tid, Numbered),
    group(lists:flatmap(fun({N, _} = M) ->
                                Items = message(Owner, Tid, M, Results, LastUser, maps:get({in, N}, Cards, [])),
                                Items ++ [{el, C} || C <- maps:get({after_, N}, Cards, [])]
                        end, Numbered), []).

%% Where each reply's products card goes: `{in, N}` (inside the bubble of
%% message N, the reply's last text) or `{after_, N}` (after message N,
%% the reply's last message, when the reply has no text).
product_cards(Owner, Tid, Numbered) ->
    Last = length(Numbered),
    lists:foldl(
      fun(#{<<"runId">> := Run} = Turn, Acc) ->
              case muse_ui_products:card(Owner, Tid, Run) of
                  [] -> Acc;
                  Card ->
                      Anchor = min(Last, maps:get(<<"anchor">>, Turn, Last)),
                      User = lists:max([0 | [N || {N, #{role := user}} <- Numbered, N =< Anchor]]),
                      Texts = [N || {N, #{role := assistant, content := C}} <- Numbered,
                                    N > User, N =< Anchor, is_binary(C), C =/= <<>>],
                      Key = case Texts of
                                [] -> {after_, Anchor};
                                _ -> {in, lists:max(Texts)}
                            end,
                      maps:update_with(Key, fun(Cs) -> Cs ++ [Card] end, [Card], Acc)
              end
      end, #{}, muse_chat_products:turns(Owner, Tid)).

number(Messages) ->
    lists:zip(lists:seq(1, length(Messages)), Messages).

%% Consecutive steps (between two texts) fold into one group.
group([], Acc) ->
    lists:reverse(Acc);
group([{step, Id, _} | _] = Items, Acc) ->
    {Steps, Rest} = lists:splitwith(fun(I) -> element(1, I) =:= step end, Items),
    group(Rest, [step_group(<<"g-", Id/binary>>, [El || {step, _, El} <- Steps], done) | Acc]);
group([{el, El} | Rest], Acc) ->
    group(Rest, [El | Acc]).

message(_O, _T, {N, #{role := user, content := Text}}, _R, _L, _Cards) when is_binary(Text) ->
    [{el, user_bubble(<<"h", (integer_to_binary(N))/binary>>, Text)}];
message(Owner, Tid, {N, #{role := assistant} = M}, Results, LastUser, Cards) ->
    %% a help request stands on its own; it is handled once the user wrote
    %% after it; so does a calendar change waiting for approval
    Steps = [case Name of
                 <<"request_takeover">> ->
                     {el, muse_ui_cards:render(Owner, Tid, Id, Name, args(TC), maps:get(Id, Results, <<"{}">>),
                                               #{answered => LastUser > N})};
                 <<"propose_calendar_change">> ->
                     {el, muse_ui_cards:render(Owner, Tid, Id, Name, args(TC), maps:get(Id, Results, <<"{}">>))};
                 <<"propose_mail_send">> ->
                     {el, muse_ui_cards:render(Owner, Tid, Id, Name, args(TC), maps:get(Id, Results, <<"{}">>))};
                 _ ->
                     {step, Id, muse_ui_cards:render(Owner, Tid, Id, Name, args(TC), maps:get(Id, Results, <<"{}">>))}
             end
             || #{id := Id, name := Name} = TC <- maps:get(tool_calls, M, [])],
    Text = case maps:get(content, M, null) of
               C when is_binary(C), C =/= <<>> -> [{el, assistant_bubble(<<"h", (integer_to_binary(N))/binary>>, C, Cards)}];
               _ -> []
           end,
    %% the steps a turn took come before what it says about them
    Steps ++ Text;
message(_O, _T, _M, _R, _L, _Cards) ->
    [].

args(#{arguments := A}) when is_map(A) -> A;
args(_) -> #{}.

%% @doc A group of steps: open while they run, folded to "执行了 N 个步骤"
%% when done.
-spec step_group(binary(), [aihtml:element()], running | done) -> aihtml:element().
step_group(Gid, Steps, State) ->
    aihtml:ah_el(details,
                 [aihtml:ah_el(summary, [ah_span(group_summary(length(Steps), State), [],
                                                 [{id, group_summary_id(Gid)}]),
                                         ?I:icon(chevron_down, 14)],
                               [<<"muse-group-sum">>], []),
                  ah_div(Steps, [<<"muse-group-steps">>], [{id, group_list_id(Gid)}])],
                 [<<"muse-steps-group">>], [{id, Gid}, {open, State =:= running}]).

-spec group_list_id(binary()) -> binary().
group_list_id(Gid) -> <<Gid/binary, "-list">>.

-spec group_summary_id(binary()) -> binary().
group_summary_id(Gid) -> <<Gid/binary, "-sum">>.

-spec group_summary(non_neg_integer(), running | done) -> binary().
group_summary(N, running) -> <<"正在执行 · 第 "/utf8, (integer_to_binary(N))/binary, " 步…"/utf8>>;
group_summary(N, done) -> <<"执行了 "/utf8, (integer_to_binary(N))/binary, " 个步骤"/utf8>>.

user_bubble(Id, Text) ->
    Shown = case muse_jev:parse_action(Text) of
                {ok, _} -> <<"（已选择一个选项）"/utf8>>;
                _ -> Text
            end,
    ah_div([ah_div(Shown, [<<"muse-msg-user">>], []), msg_tools(Shown)],
           [<<"muse-msg-user-row">>], [{id, bubble_id(Id)}]).

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
    assistant_bubble(Mid, Text, []).

%% The reply products' cards go between the text and the message tools.
assistant_bubble(Mid, Text, Cards) ->
    ah_div([ah_markdown_view(Text, [<<"max-w-none">>], []), Cards, msg_tools(Text)],
           [<<"muse-msg-assistant">>], [{id, bubble_id(Mid)}]).

%% Shown on hover: copy the message (muse.js `data-muse-copy`).
msg_tools(Text) ->
    ah_div(ah_button(?I:icon(copy, 15), copy, [<<"muse-iconbtn muse-iconbtn-sm">>],
                     [{type, button}, {aria_label, <<"复制"/utf8>>}, {title, <<"复制"/utf8>>},
                      {data_muse_copy, Text}]),
           [<<"muse-msg-tools">>], []).

-spec error_note(binary()) -> aihtml:html().
error_note(Message) ->
    ah_alert(Message, [error], []).

%%%===================================================================
%%% Queue and composer
%%%===================================================================

queue(#{<<"id">> := _Tid} = Thread) ->
    case maps:get(<<"pending">>, Thread, []) of
        [] -> ah_div([], [], [{id, <<"chat-queue">>}]);
        Pending ->
            ah_div([ah_div(<<"回复结束后依次发送："/utf8>>, [], []),
                    ah_ol([ah_li(muse_js:slice(P, 200), [<<"truncate">>], []) || P <- Pending],
                          [<<"list-decimal ml-5">>], [])],
                   [<<"muse-queue">>], [{id, <<"chat-queue">>}])
    end.

composer(Tid, Kind) ->
    ah_form([aihtml:ah_el(textarea, [], [],
                          [{name, text}, {id, <<"chat-text">>}, {rows, 2}, {data_ah, <<"muse-composer">>},
                           {placeholder, <<"给 BeamAI Muse 发消息…"/utf8>>}, {aria_label, <<"消息"/utf8>>}]),
             ah_div([ah_span(<<"Enter 发送 · Shift+Enter 换行"/utf8>>, [<<"muse-composer-hint">>], []),
                     composer_actions(Tid, muse_chat_relay:running(Tid))],
                    [<<"muse-composer-bar">>], [])],
            [<<"muse-composer">>],
            [{id, <<"chat-composer">>}, on(submit, {?MODULE, send, #{thread => Tid, new => Kind =:= new}})]).

%% @doc Send; while a reply runs, stop (Enter then queues the text).
-spec composer_actions(binary(), boolean()) -> aihtml:element().
composer_actions(Tid, true) ->
    ah_div(ah_button(?I:icon(stop, 16), stop, [<<"muse-send muse-send-stop">>],
                     [{type, button}, {aria_label, <<"停止回复"/utf8>>}, {title, <<"停止回复"/utf8>>},
                      on(click, {?MODULE, stop, #{thread => Tid}})]),
           [<<"flex">>], [{id, <<"chat-actions">>}]);
composer_actions(_Tid, false) ->
    ah_div(ah_button(?I:icon(arrow_up, 18), send, [<<"muse-send">>],
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

%% A thread changed (created, renamed, pinned, deleted, its reply started
%% or ended): every sidebar re-renders the list; pages showing the thread
%% get its queue and title, or leave it when it was deleted.
-spec on_event(binary(), term()) -> ok.
on_event(Owner, {thread, Tid}) ->
    muse_ui:publish(Owner, threads,
                    fun(C) -> aihtml_action:html(C, {id, <<"chat-threads">>}, threads(Owner), outer) end),
    case muse_threads:get(Owner, Tid) of
        {ok, Thread} ->
            muse_ui:publish(Owner, {thread, Tid},
                            fun(C) ->
                                    aihtml_action:html(C, {id, <<"chat-queue">>}, queue(Thread), outer),
                                    aihtml_action:text(C, {id, <<"muse-title">>}, display_title(Thread), replace)
                            end);
        _ ->
            muse_ui:publish(Owner, {thread, Tid}, fun(C) -> aihtml_action:redirect(C, <<"/chat">>) end)
    end;
on_event(_Owner, _Event) ->
    ok.

%%%===================================================================
%%% Actions
%%%===================================================================

-spec action(atom(), map(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(Name, Args, Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> act(Name, Args, Event, Ctx, Owner) end).

act(send, #{thread := Tid} = Args, #{form := Form}, Ctx, Owner) ->
    Text = string:trim(maps:get(<<"text">>, Form, <<>>)),
    case Text of
        <<>> -> ok;
        _ -> say(Owner, Tid, maps:get(new, Args, false), Text, Ctx)
    end;
act(suggest, #{thread := Tid, text := Text}, _Event, Ctx, Owner) ->
    New = case muse_threads:get(Owner, Tid) of
              {ok, _} -> false;
              _ -> true
          end,
    say(Owner, Tid, New, Text, Ctx);
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
%% "处理好了，继续" on a browser help request: the agreed message goes to
%% the thread like a typed one (queued while a reply runs); the button
%% shows as done.
act(continue, #{thread := Tid, call := CallId}, _Event, Ctx, Owner) ->
    case muse_threads:get(Owner, Tid) of
        {ok, Thread} ->
            %% the composer keeps whatever the user is typing
            deliver(Owner, Thread, muse_ui_cards:continue_text(), Ctx),
            aihtml_action:html(Ctx, {id, muse_ui_cards:continue_id(CallId)}, muse_ui_cards:continue_done(), inner);
        {error, {_, Msg}} ->
            ah_toast(Ctx, Msg, #{variant => error})
    end;
act(refresh, #{thread := Tid}, _Event, Ctx, Owner) ->
    case muse_threads:get(Owner, Tid) of
        {ok, Thread} ->
            aihtml_action:html(Ctx, {id, <<"chat-log">>}, log(Owner, Tid), inner),
            aihtml_action:html(Ctx, {id, <<"chat-queue">>}, queue(Thread), outer),
            aihtml_action:html(Ctx, {id, <<"chat-actions">>}, composer_actions(Tid, muse_chat_relay:running(Tid)), outer);
        _ -> ok
    end;
act(new_thread, _Args, _Event, Ctx, _Owner) ->
    aihtml_action:redirect(Ctx, <<"/chat">>);
act(rename, _Args, #{form := Form}, Ctx, Owner) ->
    Tid = maps:get(<<"thread">>, Form, <<>>),
    case muse_threads:rename(Owner, Tid, maps:get(<<"title">>, Form, <<>>)) of
        {ok, _} -> aihtml_lib_overlay:close(Ctx, {id, <<"muse-rename">>});
        {error, {_, Msg}} -> ah_toast(Ctx, Msg, #{variant => error})
    end;
act(pin, #{thread := Tid, pinned := Pinned}, _Event, Ctx, Owner) ->
    case muse_threads:pin(Owner, Tid, Pinned) of
        {ok, _} -> ok;
        {error, {_, Msg}} -> ah_toast(Ctx, Msg, #{variant => error})
    end;
act(delete, #{thread := Tid}, _Event, Ctx, Owner) ->
    case muse_threads:delete(Owner, Tid) of
        ok -> ok;
        {error, {_, Msg}} -> ah_toast(Ctx, Msg, #{variant => error})
    end;
act(search, _Args, #{form := Form}, Ctx, Owner) ->
    Q = string:lowercase(string:trim(maps:get(<<"q">>, Form, <<>>))),
    Html = case Q of
               <<>> -> [];
               _ ->
                   case muse_threads:search(Owner, Q, 10) of
                       [] -> ah_p(<<"没有结果"/utf8>>, [<<"muse-group-empty">>], []);
                       Hits -> ah_ul([ah_li(ah_a(case T of <<>> -> Id; _ -> T end, [<<"muse-thread-link">>],
                                                 [{href, <<"/chat/", Id/binary>>}]), [], [])
                                      || #{<<"thread">> := Id, <<"title">> := T} <- Hits],
                                     [<<"muse-thread-list">>], [])
                   end
           end,
    aihtml_action:html(Ctx, {id, <<"chat-search">>}, Html, inner).

%% A message to a conversation; the first one of a new conversation
%% creates it, titled after the message.
say(Owner, Tid, true, Text, Ctx) ->
    case muse_threads:create(Owner, Tid, muse_threads:title_from(Text)) of
        {ok, Thread} ->
            aihtml_action:replace_url(Ctx, <<"/chat/", Tid/binary>>),
            aihtml_action:title(Ctx, <<(display_title(Thread))/binary, " · BeamAI Muse"/utf8>>),
            aihtml_action:text(Ctx, {id, <<"muse-title">>}, display_title(Thread), replace),
            aihtml_action:remove_class(Ctx, {id, <<"chat-page">>}, [<<"muse-chat-empty">>]),
            aihtml_action:html(Ctx, {id, <<"chat-composer">>}, composer(Tid, existing), outer),
            say(Owner, Tid, false, Text, Ctx);
        {error, {_, Msg}} ->
            ah_toast(Ctx, Msg, #{variant => error})
    end;
say(Owner, Tid, false, Text, Ctx) ->
    case muse_threads:get(Owner, Tid) of
        {error, {_, Msg}} -> ah_toast(Ctx, Msg, #{});
        {ok, Thread} ->
            aihtml_action:set_value(Ctx, {id, <<"chat-text">>}, <<>>),
            deliver(Owner, Thread, Text, Ctx)
    end.

%% A message to an existing conversation: a default title becomes the
%% message's; a busy thread queues it.
deliver(Owner, #{<<"id">> := Tid} = Thread, Text, Ctx) ->
    _ = case muse_threads:default_title(Thread) of
            true -> muse_threads:rename(Owner, Tid, muse_threads:title_from(Text));
            false -> ok
        end,
    case muse_chat_relay:running(Tid) of
        true -> {ok, _} = muse_threads:enqueue(Owner, Tid, Text), ok;
        false -> start(Owner, Tid, Text, Ctx)
    end.

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
                                    aihtml_action:remove_class(C, {id, <<"chat-page">>}, [<<"muse-chat-empty">>]),
                                    aihtml_action:html(C, {id, <<"chat-log">>}, user_bubble(muse_ids:uuid(), Text), append),
                                    aihtml_action:html(C, {id, <<"chat-actions">>}, composer_actions(Tid, true), outer)
                            end),
            ok = muse_chat_relay:start(Owner, Tid, Session, Since),
            %% the sidebar shows the reply running; a new turn clears the marks
            ok = muse_threads:mark(Owner, Tid, #{<<"attention">> => false, <<"unread">> => false}),
            muse_events:emit(Owner, {thread, Tid}),
            ok;
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
