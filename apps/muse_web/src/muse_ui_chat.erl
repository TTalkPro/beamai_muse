%% @doc The chat page (designs/05-web-ui.md §4–§5, tasks M6-2): thread list
%% (main and side chats; new, rename, archive, restore, BM25 search),
%% message log with live replies (muse_chat_relay), composer with stop and a
%% visible send queue, the "delegate a task" form, and Jev choice panels.
%%
%% `/chat` shows the main thread, `/chat/<threadId>` a side chat.
%% Topics: `threads` (the list), `{thread, Tid}` (log, queue, composer).
-module(muse_ui_chat).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4]).
%% for muse_chat_relay and muse_ui_cards
-export([streaming_bubble/1, bubble_id/1, bubble_text_id/1, assistant_bubble/2, error_note/1,
         composer_actions/2, send_next/2, choice_panel/2]).

-define(SAMPLE_CSV, <<"date,description,amount,category\n2026-09-01,Salary,-4200,Income\n"
                      "2026-09-02,Groceries,84.50,Food\n2026-09-03,Subscription,19.99,Subscriptions\n"
                      "2026-09-04,Coffee,6.50,Food">>).

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
    #{<<"id">> := Tid, <<"title">> := Title} = Thread,
    {Title,
     ah_div([thread_list(Owner, Tid),
             ah_section([thread_header(Thread),
                         ah_div(log(Owner, Tid), [<<"flex-1 overflow-auto px-6 py-4 flex flex-col gap-3">>],
                                [{id, <<"chat-log">>}, {data_ah, <<"muse-scroll">>},
                                 subscribe(muse_ui:topic(Owner, {thread, Tid}),
                                           #{refresh => {?MODULE, refresh, #{thread => Tid}}})]),
                         queue(Thread),
                         composer(Tid),
                         delegate_form(Owner)],
                        [<<"flex flex-col flex-1 min-w-0 h-full">>], [])],
            [<<"flex h-full">>], [])}.

%% Threads

thread_list(Owner, Current) ->
    ah_aside([ah_div([ah_button(<<"新建对话"/utf8>>, new, [primary, sm, <<"w-full">>],
                                [on(click, {?MODULE, new_thread, #{}})])], [<<"p-3">>], []),
              ah_form([ah_input(<<>>, [<<"w-full">>], [{name, q}, {placeholder, <<"搜索历史"/utf8>>}, {type, search}])],
                      [<<"px-3 pb-2">>], [on(submit, {?MODULE, search, #{}})]),
              ah_div([], [<<"px-3">>], [{id, <<"chat-search">>}]),
              threads(Owner, Current)],
             [<<"w-64 shrink-0 border-r border-line overflow-auto hidden md:block">>],
             [subscribe(muse_ui:topic(Owner, threads))]).

threads(Owner, Current) ->
    All = lists:sort(fun(A, B) -> sort_key(A) >= sort_key(B) end, muse_threads:list(Owner)),
    {Archived, Active} = lists:partition(fun(T) -> maps:get(<<"archived">>, T, false) =:= true end, All),
    ah_nav([[thread_link(T, Current) || T <- Active],
            case Archived of
                [] -> [];
                _ -> aihtml:ah_el(details, [aihtml:ah_el(summary, <<"已归档"/utf8>>, [<<"px-3 py-1 text-xs text-muted cursor-pointer">>], []),
                                     [thread_link(T, Current) || T <- Archived]], [<<"mt-2">>], [])
            end],
           [<<"flex flex-col">>], [{id, <<"chat-threads">>}, {data_current, Current}]).

sort_key(#{<<"kind">> := <<"main">>}) -> <<"~">>;
sort_key(T) -> maps:get(<<"lastMessageAt">>, T, maps:get(<<"updatedAt">>, T, <<>>)).

thread_link(#{<<"id">> := Id, <<"title">> := Title} = T, Current) ->
    Href = case T of
               #{<<"kind">> := <<"main">>} -> <<"/chat">>;
               _ -> <<"/chat/", Id/binary>>
           end,
    ah_a(Title, [<<"block px-3 py-2 text-sm truncate">>,
                 case Id =:= Current of
                     true -> <<"bg-primary-lighter text-primary-dark font-semibold">>;
                     false -> <<"hover:bg-surface-hover">>
                 end],
         [{href, Href}, {aria_current, Id =:= Current andalso <<"page">>}]).

thread_header(#{<<"id">> := Tid, <<"title">> := Title} = T) ->
    Side = maps:get(<<"kind">>, T) =/= <<"main">>,
    Archived = maps:get(<<"archived">>, T, false) =:= true,
    ah_header([ah_form([ah_input(Title, [<<"font-semibold">>], [{name, title}, {aria_label, <<"对话标题"/utf8>>},
                                                                 {readonly, not Side}])],
                       [<<"flex-1">>], [on(submit, {?MODULE, rename, #{thread => Tid}})]),
               [case Archived of
                    false -> ah_button(<<"归档"/utf8>>, archive, [sm, borderless],
                                       [on(click, {?MODULE, archive, #{thread => Tid}}, #{confirm => <<"归档这个对话？"/utf8>>})]);
                    true -> ah_button(<<"恢复"/utf8>>, restore, [sm, borderless],
                                      [on(click, {?MODULE, restore, #{thread => Tid}})])
                end || Side]],
              [<<"flex items-center gap-2 px-6 h-12 border-b border-line">>], [{id, <<"chat-header">>}]).

%% Log

log(Owner, Tid) ->
    Messages = case muse_threads:messages(Owner, Tid) of
                   {ok, Ms} -> Ms;
                   _ -> []
               end,
    case render_messages(Owner, Tid, Messages) of
        [] -> [ah_p(<<"有什么可以帮你分担的？"/utf8>>, [<<"text-muted text-center my-12">>], [{id, <<"chat-empty">>}])];
        Html -> Html
    end.

render_messages(Owner, Tid, Messages) ->
    Results = maps:from_list([{Id, C} || #{role := tool, tool_call_id := Id, content := C} <- Messages]),
    lists:flatmap(fun(M) -> message(Owner, Tid, M, Results) end, number(Messages)).

number(Messages) ->
    lists:zip(lists:seq(1, length(Messages)), Messages).

message(_O, _T, {N, #{role := user, content := Text}}, _R) when is_binary(Text) ->
    [user_bubble(<<"h", (integer_to_binary(N))/binary>>, Text)];
message(Owner, Tid, {N, #{role := assistant} = M}, Results) ->
    Text = case maps:get(content, M, null) of
               C when is_binary(C), C =/= <<>> -> [assistant_bubble(<<"h", (integer_to_binary(N))/binary>>, C)];
               _ -> []
           end,
    Cards = [muse_ui_cards:render(Owner, Tid, Id, Name, args(TC), maps:get(Id, Results, <<"{}">>))
             || #{id := Id, name := Name} = TC <- maps:get(tool_calls, M, [])],
    Text ++ Cards;
message(_O, _T, _M, _R) ->
    [].

args(#{arguments := A}) when is_map(A) -> A;
args(_) -> #{}.

user_bubble(Id, Text) ->
    Shown = case muse_jev:parse_action(Text) of
                {ok, _} -> <<"（已选择一个选项）"/utf8>>;
                _ -> Text
            end,
    ah_div(ah_div(Shown, [<<"muse-bubble muse-bubble-user rounded-lg px-4 py-2 max-w-2xl">>], []),
           [<<"flex justify-end">>], [{id, bubble_id(Id)}]).

-spec bubble_id(binary()) -> binary().
bubble_id(Mid) -> <<"m-", Mid/binary>>.

-spec bubble_text_id(binary()) -> binary().
bubble_text_id(Mid) -> <<"m-", Mid/binary, "-txt">>.

%% @doc An empty assistant bubble that streamed text is appended to.
-spec streaming_bubble(binary()) -> aihtml:element().
streaming_bubble(Mid) ->
    ah_div(ah_span([], [<<"muse-bubble">>], [{id, bubble_text_id(Mid)}]),
           [<<"rounded-lg px-4 py-2 max-w-2xl bg-surface-raised">>], [{id, bubble_id(Mid)}]).

-spec assistant_bubble(binary(), binary()) -> aihtml:element().
assistant_bubble(Mid, Text) ->
    ah_div(ah_markdown_view(Text, [<<"max-w-none">>], []),
           [<<"rounded-lg px-4 py-2 max-w-2xl bg-surface-raised">>], [{id, bubble_id(Mid)}]).

-spec error_note(binary()) -> aihtml:html().
error_note(Message) ->
    ah_alert(Message, [error, <<"max-w-2xl">>], []).

%% Queue and composer

queue(#{<<"id">> := _Tid} = Thread) ->
    case maps:get(<<"pending">>, Thread, []) of
        [] -> ah_div([], [], [{id, <<"chat-queue">>}]);
        Pending ->
            ah_div([ah_div(<<"待发送"/utf8>>, [<<"text-xs text-muted">>], []),
                    ah_ol([ah_li(muse_js:slice(P, 200), [<<"text-sm truncate">>], []) || P <- Pending],
                          [<<"list-decimal ml-5">>], [])],
                   [<<"px-6 py-2 border-t border-line">>], [{id, <<"chat-queue">>}])
    end.

composer(Tid) ->
    ah_form([aihtml:ah_el(textarea, [], [<<"ah-input flex-1 resize-none min-h-[2.75rem] max-h-48 px-3 py-2 rounded-control border border-line">>],
                   [{name, text}, {id, <<"chat-text">>}, {rows, 2}, {data_ah, <<"muse-composer">>},
                    {placeholder, <<"输入消息，Enter 发送，Shift+Enter 换行"/utf8>>}, {aria_label, <<"消息"/utf8>>}]),
             composer_actions(Tid, muse_chat_relay:running(Tid))],
            [<<"flex items-end gap-2 px-6 py-3 border-t border-line">>],
            [{id, <<"chat-composer">>}, on(submit, {?MODULE, send, #{thread => Tid}})]).

%% @doc Send, or stop while a reply runs (sending then queues the text).
-spec composer_actions(binary(), boolean()) -> aihtml:element().
composer_actions(Tid, Running) ->
    ah_div([case Running of
                true -> ah_button(<<"停止"/utf8>>, stop, [error],
                                  [{type, button}, on(click, {?MODULE, stop, #{thread => Tid}})]);
                false -> []
            end,
            ah_button(case Running of true -> <<"排队"/utf8>>; false -> <<"发送"/utf8>> end, send, [primary],
                      [{type, submit}])],
           [<<"flex gap-2">>], [{id, <<"chat-actions">>}]).

%% Delegate

delegate_form(Owner) ->
    WithPdf = case muse_workspace:snapshot(Owner, undefined) of
                  {ok, #{<<"mail">> := Mail}} -> [M || M = #{<<"attachments">> := [_ | _]} <- Mail];
                  _ -> []
              end,
    Sample = muse_config:get(mode) =:= sample,
    aihtml:ah_el(details,
          [aihtml:ah_el(summary, <<"委派任务"/utf8>>, [<<"cursor-pointer text-sm text-primary">>], []),
           ah_form([ah_div([ah_label([aihtml:ah_void(input, [], [{type, radio}, {name, kind}, {value, K}, {checked, K =:= <<"agent">>}]),
                                      <<" ">>, L], [<<"text-sm">>], [])
                            || {K, L} <- [{<<"plan">>, <<"计划"/utf8>>}, {<<"document">>, <<"文档"/utf8>>},
                                          {<<"finance">>, <<"财务"/utf8>>}, {<<"agent">>, <<"通用任务"/utf8>>}]],
                           [<<"flex gap-4">>], []),
                    aihtml:ah_el(textarea, [], [<<"ah-input w-full px-3 py-2 rounded-control border border-line">>],
                          [{name, prompt}, {rows, 2}, {placeholder, <<"需要完成什么？"/utf8>>}]),
                    ah_label([<<"邮件（文档任务）："/utf8>>,
                              aihtml:ah_el(select, [aihtml:ah_el(option, <<"—"/utf8>>, [], [{value, <<>>}]) |
                                             [aihtml:ah_el(option, [S, <<" · ">>, F], [], [{value, I}])
                                              || #{<<"id">> := I, <<"subject">> := S, <<"sender">> := F} <- WithPdf]],
                                    [<<"ah-input ml-1">>], [{name, messageId}])],
                             [<<"text-sm">>], []),
                    aihtml:ah_el(textarea, [], [<<"ah-input w-full px-3 py-2 rounded-control border border-line font-mono text-xs">>],
                          [{name, csv}, {id, <<"delegate-csv">>}, {rows, 3},
                           {placeholder, <<"date,description,amount,category（财务任务）"/utf8>>}]),
                    ah_div([ah_button(<<"委派"/utf8>>, delegate, [primary, sm], [{type, submit}]),
                            [ah_button(<<"试用示例交易"/utf8>>, sample, [sm, borderless],
                                       [{type, button}, on(click, {?MODULE, sample_csv, #{}})]) || Sample]],
                           [<<"flex gap-2">>], []),
                    ah_div([], [], [{id, <<"delegate-result">>}])],
                   [<<"flex flex-col gap-2 mt-2">>], [on(submit, {?MODULE, delegate, #{}})])],
          [<<"px-6 pb-3">>], []).

%% Jev

%% @doc A Jev choice panel (OpenMuse JevToolCard): clicking an option sends
%% the "[OpenMuse choice]" message.
-spec choice_panel(binary(), map()) -> aihtml:element().
choice_panel(Tid, #{<<"id">> := PanelId, <<"title">> := Title, <<"options">> := Options} = Panel) ->
    Selected = maps:get(<<"selectedId">>, Panel, undefined),
    ah_div([ah_div(Title, [<<"font-medium mb-2">>], []),
            ah_div([option(Tid, Panel, PanelId, O, Selected) || O <- Options], [<<"grid gap-2 sm:grid-cols-2">>], [])],
           [], [{id, <<"jev-", PanelId/binary>>}]).

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
           [<<"rounded border border-line p-2">>], []).

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
        {ok, _} -> aihtml_action:title(Ctx, <<(maps:get(<<"title">>, Form))/binary, " · Muse"/utf8>>);
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
                       Hits -> ah_ul([ah_li(ah_a(case T of <<>> -> Id; _ -> T end, [<<"text-sm text-primary">>],
                                                 [{href, <<"/chat/", Id/binary>>}]), [<<"py-1">>], [])
                                      || #{<<"thread">> := Id, <<"title">> := T} <- Hits], [], [])
                   end
           end,
    aihtml_action:html(Ctx, {id, <<"chat-search">>}, Html, inner);
act(sample_csv, _Args, _Event, Ctx, _Owner) ->
    aihtml_action:set_value(Ctx, {id, <<"delegate-csv">>}, ?SAMPLE_CSV);
act(delegate, _Args, #{form := Form}, Ctx, Owner) ->
    Kind = maps:get(<<"kind">>, Form, <<"agent">>),
    Input = case Kind of
                <<"finance">> -> #{<<"csv">> => maps:get(<<"csv">>, Form, <<>>)};
                <<"document">> -> #{<<"messageId">> => maps:get(<<"messageId">>, Form, <<>>)};
                _ -> #{}
            end,
    Raw = #{<<"prompt">> => maps:get(<<"prompt">>, Form, <<>>), <<"kind">> => Kind, <<"input">> => Input},
    case muse_agent_service:create_task(Owner, Raw) of
        {ok, #{<<"id">> := Id}} -> aihtml_action:redirect(Ctx, <<"/activity/", Id/binary>>);
        {error, {_, Msg}} -> aihtml_action:html(Ctx, {id, <<"delegate-result">>}, ah_alert(Msg, [error], []), inner)
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
