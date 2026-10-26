%% @doc The app shell (designs/05-web-ui.md §5), after the Agentic Noosh
%% sidebar design: a left sidebar with the brand, "新会话", the workspace
%% pages, the pinned and the other conversations (each with its status:
%% running, new reply, needs attention) and the account menu; beside it a
%% header row (sidebar toggle, the page or conversation title with its menu,
%% the notifications bell) and the page. On narrow screens the sidebar
%% slides in; on wide ones the toggle folds it away (muse.js).
%%
%% The shell also holds the conversation rename dialog, an aihtml modal
%% window that muse.js fills in. (Confirmations are aihtml's own in-page
%% dialog since aihtml 4f49549.)
%%
%% The root subscribes to the owner's `user` topic: toasts, the unread dot
%% and the task count. The conversation list (`chat-threads`) is kept live
%% by muse_ui_chat on the `threads` topic.
-module(muse_ui_layout).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([shell/4, title/1, unread_badge/1, task_count/1, approval_count/1, mail_count/1, on_event/2]).

-define(I, muse_ui_icons).
-define(PRODUCT, <<"BeamAI Muse">>).

%% @doc The page title of a page key.
-spec title(atom()) -> binary().
title(chat) -> <<"新会话"/utf8>>;
title(activity) -> <<"任务"/utf8>>;
title(approvals) -> <<"审批"/utf8>>;
title(calendar) -> <<"日程"/utf8>>;
title(mail) -> <<"邮件"/utf8>>;
title(documents) -> <<"文件"/utf8>>;
title(computer) -> <<"电脑"/utf8>>;
title(browser) -> <<"浏览器"/utf8>>;
title(notifications) -> <<"通知"/utf8>>;
title(settings) -> <<"设置"/utf8>>;
title(Key) -> atom_to_binary(Key).

-spec shell(binary(), atom(), aihtml:html(), cowboy_req:req()) -> aihtml:element().
shell(Owner, Active, Content, Req) ->
    Thread = case {Active, cowboy_req:path_info(Req)} of
                 {chat, [Tid | _]} ->
                     case muse_threads:get(Owner, Tid) of
                         {ok, T} -> T;
                         _ -> undefined
                     end;
                 _ -> undefined
             end,
    ah_div([side(Owner, Active),
            ah_div([], [<<"muse-scrim">>], [{data_ah, <<"muse-menu-close">>}]),
            ah_div([header(Owner, Active, Thread),
                    ah_main(Content, [<<"muse-main">>], [{id, <<"muse-main">>}])],
                   [<<"muse-body">>], []),
            rename_window()],
           [<<"muse-app">>],
           [{id, <<"muse-shell">>}, subscribe(muse_ui:topic(Owner, user))]).

%% Header: toggle, title (a conversation's with its menu), bell.
header(Owner, Active, Thread) ->
    Title = case Thread of
                undefined -> ah_h1(title(Active), [<<"muse-title">>], [{id, <<"muse-title">>}]);
                #{<<"id">> := Tid} ->
                    [ah_h1(muse_ui_chat:display_title(Thread), [<<"muse-title">>], [{id, <<"muse-title">>}]),
                     ah_button(?I:icon(chevron_down, 16), more, [<<"muse-iconbtn muse-iconbtn-sm">>],
                               [{type, button}, {aria_label, <<"会话操作"/utf8>>} | toggles({id, <<"muse-title-menu">>})]),
                     ah_popover(muse_ui_chat:thread_menu(Thread), [bottom],
                                [{id, <<"muse-title-menu">>}, {width, 180}, {data_thread, Tid}])]
            end,
    ah_header([ah_button(?I:icon(sidebar, 20), menu, [<<"muse-iconbtn">>],
                         [{type, button}, {aria_label, <<"显示或隐藏侧栏"/utf8>>}, {data_ah, <<"muse-menu">>}]),
               ah_div(Title, [<<"muse-titlebar">>], []),
               ah_a([?I:icon(bell, 20), unread_badge(Owner)], [<<"muse-iconbtn">>],
                    [{href, <<"/notifications">>}, {aria_label, <<"通知"/utf8>>}])],
              [<<"muse-header">>], []).

%% @doc The dot on the bell while notifications are unread (replaced by pushes).
-spec unread_badge(binary()) -> aihtml:element().
unread_badge(Owner) ->
    Unread = length([N || #{<<"read">> := false} = N <- muse_agent_service:notifications(Owner)]),
    ah_span([], case Unread of 0 -> []; _ -> [<<"muse-dot">>] end,
            [{id, <<"muse-unread">>}, {data_count, integer_to_binary(Unread)}]).

%% The sidebar.
side(Owner, Active) ->
    {ok, #{<<"identity">> := Identity}} = muse_agent_service:snapshot(Owner),
    Links = [{activity, tasks, <<"/activity">>, task_count(Owner)},
             {approvals, approval, <<"/approvals">>, approval_count(Owner)},
             {calendar, calendar, <<"/calendar">>, []},
             {mail, mail, <<"/mail">>, mail_count(Owner)},
             {documents, file, <<"/documents">>, []}]
        %% no browser link: a conversation's browser opens from its help
        %% request or browse_web step (tasks/M9-workspace.md M9-5)
        ++ [{computer, monitor, <<"/computer">>, []} || muse_config:get(computer_enabled, false) =:= true],
    ah_aside([ah_a([ah_span(<<"M">>, [<<"muse-logo">>], []),
                    ah_span([ah_span(?PRODUCT, [<<"muse-brand-name">>], []),
                             ah_span(<<"智能体工作台"/utf8>>, [<<"muse-brand-sub">>], [])],
                            [<<"flex flex-col">>], [])],
                   [<<"muse-brand">>], [{href, <<"/chat">>}]),
              ah_a([?I:icon(plus, 18), <<"新会话"/utf8>>], [<<"muse-new-chat">>],
                   [{href, <<"/chat">>}, {id, <<"muse-new-chat">>}]),
              ah_nav([link(Key, Icon, Href, Meta, Active) || {Key, Icon, Href, Meta} <- Links],
                     [<<"muse-menu">>], [{aria_label, <<"工作区"/utf8>>}]),
              ah_form(ah_input(<<>>, [<<"muse-side-search">>],
                               [{name, q}, {type, search}, {placeholder, <<"搜索会话"/utf8>>},
                                {aria_label, <<"搜索会话"/utf8>>}]),
                      [<<"mt-3">>], [on(submit, {muse_ui_chat, search, #{}})]),
              ah_div([], [], [{id, <<"chat-search">>}]),
              ah_div(muse_ui_chat:threads(Owner), [<<"muse-side-threads">>],
                     [subscribe(muse_ui:topic(Owner, threads))]),
              account(Identity)],
             [<<"muse-side">>], [{id, <<"muse-side">>}, {aria_label, <<"菜单"/utf8>>}]).

link(Key, Icon, Href, Meta, Active) ->
    ah_a([?I:icon(Icon, 18), title(Key), Meta],
         [<<"muse-menu-link">>], [{href, Href}, {aria_current, Key =:= Active andalso <<"page">>}]).

%% @doc The count beside 任务: tasks that wait for the person's reply, else
%% the running and queued ones (replaced by pushes, id `muse-task-count`).
%% Reviews are counted beside 审批 (`approval_count/1`).
-spec task_count(binary()) -> aihtml:element().
task_count(Owner) ->
    {ok, #{<<"tasks">> := Tasks}} = muse_agent_service:snapshot(Owner),
    Waiting = length([T || #{<<"status">> := <<"waiting_input">>} = T <- Tasks]),
    Active = length([T || #{<<"status">> := S} = T <- Tasks, S =:= <<"running">> orelse S =:= <<"queued">>]),
    ah_span(case {Waiting, Active} of
                {0, 0} -> [];
                {0, A} -> integer_to_binary(A);
                {W, _} -> [integer_to_binary(W), <<" 待回复"/utf8>>]
            end,
            [<<"muse-menu-meta">>, case Waiting of 0 -> <<>>; _ -> <<"muse-menu-meta-alert">> end],
            [{id, <<"muse-task-count">>}]).

%% @doc The count beside 审批: reviews waiting for the person, from the chat
%% and from tasks (replaced by pushes, id `muse-approval-count`).
-spec approval_count(binary()) -> aihtml:element().
approval_count(Owner) ->
    N = length(muse_ui_approvals:pending(Owner)),
    ah_span(case N of 0 -> []; _ -> integer_to_binary(N) end,
            [<<"muse-menu-meta">>, case N of 0 -> <<>>; _ -> <<"muse-menu-meta-alert">> end],
            [{id, <<"muse-approval-count">>}]).

%% @doc The unread count beside 邮件: the inboxes' unread mail (replaced by
%% pushes, id `muse-mail-count`).
-spec mail_count(binary()) -> aihtml:element().
mail_count(Owner) ->
    Unread = lists:sum([maps:get(<<"unread">>, F, 0)
                        || #{<<"id">> := A} <- muse_mail_accounts:list(Owner),
                           {ok, F} <- [muse_mail:folder_by_role(Owner, A, <<"inbox">>)]]),
    ah_span(case Unread of 0 -> []; _ -> integer_to_binary(Unread) end, [<<"muse-menu-meta">>],
            [{id, <<"muse-mail-count">>}]).

%% The account block at the bottom: settings, notifications, sign out.
account(Identity) ->
    Agent = case maps:get(<<"name">>, Identity, <<>>) of <<>> -> ?PRODUCT; N -> N end,
    [ah_button([ah_span(<<"我"/utf8>>, [<<"muse-avatar">>], []),
                ah_span([ah_span(<<"我的账户"/utf8>>, [<<"muse-account-name">>], []),
                         ah_span([<<"智能体："/utf8>>, Agent], [<<"muse-account-sub">>], [])],
                        [<<"flex flex-col min-w-0 flex-1 text-left">>], []),
                ?I:icon(chevron_down, 16)],
               account, [<<"muse-account">>],
               [{type, button}, {aria_label, <<"账户菜单"/utf8>>} | toggles({id, <<"muse-account-menu">>})]),
     ah_popover(ah_div([ah_a([?I:icon(settings, 16), <<"设置"/utf8>>], [<<"muse-pop-item">>], [{href, <<"/settings">>}]),
                        ah_a([?I:icon(bell, 16), <<"通知"/utf8>>], [<<"muse-pop-item">>], [{href, <<"/notifications">>}]),
                        ah_form(ah_button([?I:icon(logout, 16), <<"退出登录"/utf8>>], logout,
                                          [<<"muse-pop-item">>], [{type, submit}]),
                                [], [{action, <<"/logout">>}, {method, post}])],
                       [<<"muse-pop-menu">>], []),
                [top], [{id, <<"muse-account-menu">>}, {width, 220}])].

%% The rename dialog: muse.js fills in the thread and its title from the
%% `data-muse-rename` button that opened it.
rename_window() ->
    ah_window(ah_form([aihtml:ah_void(input, [], [{type, hidden}, {name, thread}, {id, <<"muse-rename-thread">>}]),
                       ah_input(<<>>, [<<"w-full">>], [{name, title}, {id, <<"muse-rename-input">>}, {maxlength, 120},
                                                       {aria_label, <<"会话名称"/utf8>>}, {required, true}]),
                       ah_div([ah_button(<<"取消"/utf8>>, cancel, [outlined], [{type, button} | closes()]),
                               ah_button(<<"保存"/utf8>>, save, [primary], [{type, submit}])],
                              [<<"flex justify-end gap-2">>], [])],
                      [<<"flex flex-col gap-4">>],
                      [{id, <<"muse-rename-form">>}, on(submit, {muse_ui_chat, rename, #{}})]),
              [],
              [{id, <<"muse-rename">>}, {title, <<"重命名会话"/utf8>>}, {modal, true}, {width, 440},
               {draggable, false}, {resizable, false}, {close_on_overlay, true}]).

%% @doc New notifications: a toast and the unread dot on every page; task
%% and approval changes refresh the task count.
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
on_event(Owner, {mail, _}) ->
    muse_ui:publish(Owner, user,
                    fun(C) -> aihtml_action:html(C, {id, <<"muse-mail-count">>}, mail_count(Owner), outer) end);
on_event(Owner, {Kind, _}) when Kind =:= task; Kind =:= action ->
    muse_ui:publish(Owner, user,
                    fun(C) ->
                            aihtml_action:html(C, {id, <<"muse-task-count">>}, task_count(Owner), outer),
                            aihtml_action:html(C, {id, <<"muse-approval-count">>}, approval_count(Owner), outer)
                    end);
on_event(_Owner, _Event) ->
    ok.
