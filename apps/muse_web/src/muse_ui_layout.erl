%% @doc The app shell, after OpenMuse's single-column workspace (apps/mobile
%% App.tsx): a header with the menu button, the agent (avatar, name and a
%% status line that opens the task list) and the notifications bell; the
%% page in a centred 760 px column; and a left drawer with new chat, the
%% conversations and the few secondary pages (designs/05-web-ui.md §5).
%%
%% The root subscribes to the owner's `user` topic: toasts, the unread dot
%% and the status line. The drawer's conversation list is `chat-threads`,
%% kept live by muse_ui_chat on the `threads` topic.
-module(muse_ui_layout).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([shell/4, title/1, unread_badge/1, status_line/1, on_event/2]).

-define(I, muse_ui_icons).
-define(MENU, <<"muse-menu">>).

%% @doc The page title of a page key.
-spec title(atom()) -> binary().
title(chat) -> <<"对话"/utf8>>;
title(activity) -> <<"任务与审批"/utf8>>;
title(documents) -> <<"文件"/utf8>>;
title(computer) -> <<"Linux 电脑"/utf8>>;
title(browser) -> <<"浏览器"/utf8>>;
title(apps) -> <<"应用连接"/utf8>>;
title(notifications) -> <<"通知"/utf8>>;
title(settings) -> <<"设置"/utf8>>;
title(Key) -> atom_to_binary(Key).

-spec shell(binary(), atom(), aihtml:html(), cowboy_req:req()) -> aihtml:element().
shell(Owner, Active, Content, Req) ->
    Current = case {Active, cowboy_req:path_info(Req)} of
                  {chat, [Tid | _]} -> Tid;
                  {chat, _} -> main;
                  _ -> undefined
              end,
    ah_div([header(Owner),
            ah_main(Content, [<<"muse-main">>], [{id, <<"muse-main">>}]),
            menu(Owner, Active, Current)],
           [<<"muse-app">>],
           [{id, <<"muse-shell">>}, subscribe(muse_ui:topic(Owner, user))]).

header(Owner) ->
    {ok, #{<<"identity">> := Identity}} = muse_agent_service:snapshot(Owner),
    Name = case maps:get(<<"name">>, Identity, <<>>) of
               <<>> -> <<"OpenMuse">>;
               N -> N
           end,
    ah_header([ah_button(?I:icon(menu, 22), menu, [<<"muse-iconbtn">>],
                         [{type, button}, {aria_label, <<"打开菜单"/utf8>>} | opens({id, ?MENU})]),
               ah_div([ah_a(ah_span(initial(Name), [<<"muse-mascot">>],
                                    [{data_avatar, maps:get(<<"avatar">>, Identity, <<>>)}]),
                            [], [{href, <<"/chat">>}, {aria_label, <<"回到对话"/utf8>>}]),
                       ah_div(Name, [<<"muse-agent-name">>], []),
                       status_line(Owner)],
                      [<<"muse-header-center">>], []),
               ah_a([?I:icon(bell, 22), unread_badge(Owner)], [<<"muse-iconbtn">>],
                    [{href, <<"/notifications">>}, {aria_label, <<"通知"/utf8>>}])],
              [<<"muse-header">>], []).

initial(Name) ->
    case string:next_grapheme(Name) of
        [G | _] -> unicode:characters_to_binary([G]);
        _ -> <<"M">>
    end.

%% @doc The line under the agent's name: what it is doing now (OpenMuse
%% WorkspaceShell `status`); it opens the task list.
-spec status_line(binary()) -> aihtml:element().
status_line(Owner) ->
    {ok, #{<<"tasks">> := Tasks}} = muse_agent_service:snapshot(Owner),
    Waiting = [T || T = #{<<"status">> := S} <- Tasks,
                    S =:= <<"waiting_approval">> orelse S =:= <<"waiting_input">>],
    Running = [T || T = #{<<"status">> := <<"running">>} <- Tasks],
    Text = case {Waiting, Running} of
               {[#{<<"status">> := <<"waiting_approval">>} = T | _], _} -> [<<"等你审阅 · "/utf8>>, title_of(T)];
               {[T | _], _} -> [<<"需要你补充信息 · "/utf8>>, title_of(T)];
               {[], [T | _]} -> [<<"正在处理 · "/utf8>>, running_step(T)];
               {[], []} ->
                   case [T || T = #{<<"status">> := <<"queued">>} <- Tasks] of
                       [_ | _] -> <<"马上处理下一个任务…"/utf8>>;
                       [] -> <<"随时待命"/utf8>>
                   end
           end,
    ah_a(Text, [<<"muse-status">>], [{href, <<"/activity">>}, {id, <<"muse-status">>}]).

title_of(T) -> maps:get(<<"title">>, T, <<>>).

running_step(#{<<"plan">> := Plan} = T) when is_list(Plan) ->
    case [S || S = #{<<"status">> := <<"running">>} <- Plan] of
        [#{<<"title">> := Step} | _] -> Step;
        _ -> title_of(T)
    end;
running_step(T) ->
    title_of(T).

%% @doc The dot on the bell while notifications are unread (replaced by pushes).
-spec unread_badge(binary()) -> aihtml:element().
unread_badge(Owner) ->
    Unread = length([N || #{<<"read">> := false} = N <- muse_agent_service:notifications(Owner)]),
    ah_span([], case Unread of 0 -> []; _ -> [<<"muse-dot">>] end,
            [{id, <<"muse-unread">>}, {data_count, integer_to_binary(Unread)}]).

%% The drawer: new chat, conversations, the secondary pages, settings.
menu(Owner, Active, Current) ->
    Links = [{activity, tasks, <<"/activity">>, pending(Owner)},
             {documents, file, <<"/documents">>, <<>>}]
        ++ [{computer, monitor, <<"/computer">>, <<>>} || muse_config:get(computer_enabled, false) =:= true]
        ++ [{browser, globe, <<"/browser">>, <<>>} || muse_config:browser_configured()]
        ++ [{settings, settings, <<"/settings">>, <<>>}],
    ah_drawer(ah_div([ah_button([?I:icon(plus, 18), <<"新对话"/utf8>>], new, [<<"muse-new-chat">>],
                                [{type, button}, {id, <<"muse-new-chat">>},
                                 on(click, {muse_ui_chat, new_thread, #{}})]),
                      ah_div(<<"对话"/utf8>>, [<<"muse-menu-label">>], []),
                      ah_form(ah_input(<<>>, [<<"w-full">>], [{name, q}, {type, search},
                                                             {placeholder, <<"搜索对话"/utf8>>},
                                                             {aria_label, <<"搜索对话"/utf8>>}]),
                              [<<"px-1 pb-1">>], [on(submit, {muse_ui_chat, search, #{}})]),
                      ah_div([], [<<"px-1">>], [{id, <<"chat-search">>}]),
                      ah_div(muse_ui_chat:threads(Owner, Current), [],
                             [subscribe(muse_ui:topic(Owner, threads))]),
                      ah_div(<<"工作区"/utf8>>, [<<"muse-menu-label">>], []),
                      ah_nav([link(Key, Icon, Href, Meta, Active) || {Key, Icon, Href, Meta} <- Links],
                             [<<"muse-menu">>], [{aria_label, <<"工作区"/utf8>>}])],
                     [<<"flex flex-col gap-2">>], []),
              [left], [{id, ?MENU}, {size, 300}, {handle, false}, {title, <<"OpenMuse">>}]).

link(Key, Icon, Href, Meta, Active) ->
    ah_a([?I:icon(Icon, 20), title(Key), case Meta of <<>> -> []; _ -> ah_span(Meta, [<<"muse-menu-meta">>], []) end],
         [<<"muse-menu-link">>], [{href, Href}, {aria_current, Key =:= Active andalso <<"page">>}]).

pending(Owner) ->
    {ok, #{<<"tasks">> := Tasks}} = muse_agent_service:snapshot(Owner),
    case length([T || T = #{<<"status">> := S} <- Tasks,
                      lists:member(S, [<<"waiting_approval">>, <<"waiting_input">>, <<"running">>, <<"queued">>])]) of
        0 -> <<>>;
        N -> integer_to_binary(N)
    end.

%% @doc New notifications: a toast and the unread dot on every page; task
%% and approval changes refresh the status line.
-spec on_event(binary(), term()) -> ok.
on_event(Owner, {notification, Id}) ->
    Toast = case [N || N = #{<<"id">> := I} <- muse_agent_service:notifications(Owner), I =:= Id] of
                [#{<<"title">> := T, <<"body">> := B, <<"read">> := false}] -> {T, B};
                _ -> undefined
            end,
    muse_ui:publish(Owner, user,
                    fun(C) ->
                            aihtml_action:html(C, {id, <<"muse-unread">>}, unread_badge(Owner), outer),
                            case Toast of
                                {Title, Body} ->
                                    aihtml_toast:ah_toast(C, Title, #{description => muse_js:slice(Body, 240)});
                                undefined -> ok
                            end
                    end);
on_event(Owner, {Kind, _}) when Kind =:= task; Kind =:= action ->
    muse_ui:publish(Owner, user,
                    fun(C) -> aihtml_action:html(C, {id, <<"muse-status">>}, status_line(Owner), outer) end);
on_event(_Owner, _Event) ->
    ok.
