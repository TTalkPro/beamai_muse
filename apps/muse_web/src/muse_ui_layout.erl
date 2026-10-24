%% @doc The app shell: sidenav, top bar with notifications, main area
%% (designs/05-web-ui.md §5). The root subscribes to the owner's `user`
%% topic, which carries toasts and the unread badge.
-module(muse_ui_layout).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([shell/3, nav_items/0, unread_badge/1, on_event/2]).

-spec nav_items() -> [map()].
nav_items() ->
    [#{label => <<"Muse">>,
       items => [{chat, <<"聊天"/utf8>>}, {activity, <<"Activity">>}, {goals, <<"目标"/utf8>>},
                 {monitors, <<"追踪"/utf8>>}, {ideas, <<"Ideas">>}, {documents, <<"文档"/utf8>>}]},
     #{label => <<"电脑"/utf8>>,
       items => [{computer, <<"Linux 电脑"/utf8>>}, {browser, <<"浏览器"/utf8>>}]},
     #{label => <<"账户"/utf8>>,
       items => [{apps, <<"应用"/utf8>>}, {notifications, <<"通知"/utf8>>}, {settings, <<"设置"/utf8>>}]}].

-spec shell(binary(), atom(), aihtml:html()) -> aihtml:element().
shell(Owner, Active, Content) ->
    ah_div([ah_sidenav(nav_items(), Active, [<<"shrink-0">>],
                       [{route_prefix, <<"/">>}, {collapsible, true},
                        {brand, #{name => <<"Muse">>, href => <<"/chat">>}}]),
            ah_div([topbar(Owner),
                    ah_main(Content, [<<"flex-1 min-h-0 overflow-auto">>], [{id, <<"muse-main">>}])],
                   [<<"flex flex-col flex-1 min-w-0">>], [])],
           [<<"flex h-screen bg-surface">>],
           [{id, <<"muse-shell">>}, subscribe(muse_ui:topic(Owner, user))]).

topbar(Owner) ->
    ah_header([ah_div([], [<<"flex-1">>], []),
               ah_a([<<"通知"/utf8>>, unread_badge(Owner)], [<<"text-sm text-muted hover:text-primary">>],
                    [{href, <<"/notifications">>}]),
               ah_form([ah_button(<<"退出"/utf8>>, logout, [borderless, sm], [{type, submit}])],
                       [<<"inline">>], [{action, <<"/logout">>}, {method, post}])],
              [<<"flex items-center gap-4 px-4 h-12 border-b border-line">>], []).

%% @doc The unread count next to the notifications link (replaced by pushes).
-spec unread_badge(binary()) -> aihtml:element().
unread_badge(Owner) ->
    Unread = length([N || #{<<"read">> := false} = N <- muse_agent_service:notifications(Owner)]),
    ah_span(case Unread of 0 -> <<>>; _ -> [<<" (">>, integer_to_binary(Unread), <<")">>] end,
            [<<"font-semibold text-primary">>], [{id, <<"muse-unread">>}]).

%% @doc New notifications: a toast and a fresh unread count on every page.
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
on_event(_Owner, _Event) ->
    ok.
