%% @doc Settings page `/settings` (designs/05-web-ui.md §5, tasks/M6-ui.md
%% M6-6): the agent identity (name, tone, avatar, showChatUpdates), the
%% memories (add, edit, forget), the app connections link and sign-out.
%%
%% Identity and memories go through muse_agent_service, which validates
%% them (`muse_task:identity_schema/0`, `memory_schema/0`) and emits
%% `{identity, _}` / `{memory, _}`; `on_event/2` republishes the memory list
%% to the owner's open settings pages, so memories the chat agent saves
%% show up live.
-module(muse_ui_settings).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, action/4, on_event/2]).

-define(C, muse_ui_b_common).
-define(MEMORIES, <<"settings-memories">>).
-define(ID_NOTICE, <<"settings-identity-notice">>).
-define(MEM_NOTICE, <<"settings-memory-notice">>).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    {ok, #{<<"identity">> := Identity}} = muse_agent_service:snapshot(Owner),
    {<<>>, ah_div([?C:page_header(<<"设置"/utf8>>, <<>>),
                   ah_card([?C:slot(?ID_NOTICE), identity_form(Identity)], [], [{title, <<"智能体身份"/utf8>>}]),
                   ah_card([?C:slot(?MEM_NOTICE),
                            add_memory_form(),
                            ah_div(memories(Owner), [<<"flex flex-col">>],
                                   [{id, ?MEMORIES},
                                    subscribe(muse_ui:topic(Owner, memories), #{refresh => {?MODULE, refresh, #{}}})])],
                           [], [{title, <<"记忆"/utf8>>},
                                {subtitle, <<"智能体记住的关于你的事情，可随时修改或忘记。"/utf8>>}]),
                   ah_card(ah_a([<<"Gmail 和 Google 日历"/utf8>>, ah_span(<<"管理 ›"/utf8>>, [<<"text-muted">>], [])],
                                [<<"flex justify-between items-center">>], [{href, <<"/apps">>}, {id, <<"settings-apps">>}]),
                           [], [{title, <<"应用连接"/utf8>>}]),
                   ah_card(ah_form([ah_p(<<"退出后，本设备上的会话将失效。"/utf8>>, [<<"text-sm text-muted">>], []),
                                    ah_div(ah_button(<<"退出登录"/utf8>>, logout, [error, sm], [{type, submit}]), [], [])],
                                   [<<"flex flex-col gap-3">>],
                                   [{id, <<"settings-logout">>}, {action, <<"/logout">>}, {method, post}]),
                           [], [{title, <<"账户"/utf8>>}])],
                  [<<"muse-page">>], [])}.

identity_form(Identity) ->
    Tone = maps:get(<<"tone">>, Identity, <<"warm">>),
    Avatar = maps:get(<<"avatar">>, Identity, <<>>),
    Show = maps:get(<<"showChatUpdates">>, Identity, false) =:= true,
    ah_form([ah_field(<<"名字"/utf8>>, ah_input(maps:get(<<"name">>, Identity, <<>>), [],
                                               [{name, name}, {required, true}, {maxlength, 80}]), [], []),
             ah_field(<<"语气"/utf8>>, ah_select([{<<"warm">>, <<"温暖"/utf8>>}, {<<"concise">>, <<"简洁"/utf8>>},
                                                {<<"thoughtful">>, <<"深思"/utf8>>}],
                                               Tone, [], [{name, tone}]), [], []),
             ah_field(<<"头像颜色"/utf8>>, ah_select([{<<>>, <<"默认"/utf8>>}, {<<"sky">>, <<"天蓝"/utf8>>},
                                                  {<<"sand">>, <<"沙色"/utf8>>}, {<<"lilac">>, <<"淡紫"/utf8>>}],
                                                 Avatar, [], [{name, avatar}]), [], []),
             ah_checkbox(<<"在聊天中显示任务进展"/utf8>>, <<"true">>, [], [{name, showChatUpdates}, {checked, Show}]),
             ah_div(ah_button(<<"保存"/utf8>>, save, [primary, sm], [{type, submit}]), [], [])],
            [<<"flex flex-col gap-4">>], [{id, <<"settings-identity">>}, on(submit, {?MODULE, identity, #{}})]).

add_memory_form() ->
    ah_form([ah_textarea(<<>>, [<<"w-full">>], [{name, text}, {rows, 2}, {id, <<"settings-memory-new">>},
                                                {placeholder, <<"例如：我更喜欢上午开会"/utf8>>}]),
             ah_div(ah_button(<<"记住"/utf8>>, add, [primary, sm], [{type, submit}]), [], [])],
            [<<"flex flex-col gap-2 mb-4">>], [{id, <<"settings-memory-add">>}, on(submit, {?MODULE, add_memory, #{}})]).

memories(Owner) ->
    case lists:sort(fun(A, B) -> created(A) >= created(B) end, muse_agent_service:memories(Owner)) of
        [] -> ah_empty([], [compact], [{title, <<"还没有记忆"/utf8>>}]);
        Ms -> ah_ul([memory_row(M) || M <- Ms], [<<"flex flex-col divide-y divide-line">>], [])
    end.

created(M) -> maps:get(<<"createdAt">>, M, <<>>).

memory_row(#{<<"id">> := Id, <<"text">> := Text} = M) ->
    ah_li(ah_form([ah_input(Text, [<<"flex-1">>], [{name, text}, {required, true}, {maxlength, 4000},
                                                   {aria_label, <<"记忆内容"/utf8>>}]),
                   ah_span([maps:get(<<"source">>, M, <<>>), <<" · "/utf8>>, ?C:time_label(created(M))],
                           [<<"text-xs text-muted shrink-0">>], []),
                   ah_button(<<"保存"/utf8>>, save, [outlined, sm], [{type, submit}]),
                   ah_button(<<"忘记"/utf8>>, forget, [borderless, sm],
                             [on(click, {?MODULE, forget_memory, #{id => Id}},
                                 #{confirm => <<"忘记这条记忆？"/utf8>>})])],
                  [<<"flex items-center gap-2">>], [on(submit, {?MODULE, update_memory, #{id => Id}})]),
          [<<"py-2">>], [{id, <<"memory-", Id/binary>>}]).

%% Actions

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(refresh, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> aihtml_action:html(Ctx, {id, ?MEMORIES}, memories(Owner)) end);
action(identity, _Args, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Input0 = #{<<"name">> => maps:get(<<"name">>, Form, <<>>),
                              <<"tone">> => maps:get(<<"tone">>, Form, <<>>),
                              <<"showChatUpdates">> => maps:is_key(<<"showChatUpdates">>, Form)},
                   Input = case maps:get(<<"avatar">>, Form, <<>>) of
                               <<>> -> Input0;
                               A -> Input0#{<<"avatar">> => A}
                           end,
                   Notice = case muse_agent_service:set_identity(Owner, Input) of
                                {ok, _} -> {success, <<"身份已保存。"/utf8>>};
                                Error -> {error, ?C:error_text(Error)}
                            end,
                   ?C:notice(Ctx, ?ID_NOTICE, Notice)
           end);
action(add_memory, _Args, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_agent_service:add_memory(Owner, #{<<"text">> => maps:get(<<"text">>, Form, <<>>)}) of
                       {ok, _} ->
                           ?C:notice(Ctx, ?MEM_NOTICE, clear),
                           aihtml_action:set_value(Ctx, {id, <<"settings-memory-new">>}, <<>>),
                           aihtml_action:html(Ctx, {id, ?MEMORIES}, memories(Owner));
                       Error ->
                           ?C:notice(Ctx, ?MEM_NOTICE, {error, ?C:error_text(Error)})
                   end
           end);
action(update_memory, #{id := Id}, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_agent_service:update_memory(Owner, Id, #{<<"text">> => maps:get(<<"text">>, Form, <<>>)}) of
                       {ok, _} ->
                           ?C:notice(Ctx, ?MEM_NOTICE, {success, <<"记忆已更新。"/utf8>>}),
                           aihtml_action:html(Ctx, {id, ?MEMORIES}, memories(Owner));
                       Error ->
                           ?C:notice(Ctx, ?MEM_NOTICE, {error, ?C:error_text(Error)})
                   end
           end);
action(forget_memory, #{id := Id}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_agent_service:forget_memory(Owner, Id) of
                       ok -> ?C:notice(Ctx, ?MEM_NOTICE, clear);
                       Error -> ?C:notice(Ctx, ?MEM_NOTICE, {error, ?C:error_text(Error)})
                   end,
                   aihtml_action:html(Ctx, {id, ?MEMORIES}, memories(Owner))
           end).

%% @doc A memory changed anywhere (this page, the chat agent): the owner's
%% open settings pages re-render the list.
-spec on_event(binary(), term()) -> ok.
on_event(Owner, {memory, _}) ->
    muse_ui:publish(Owner, memories,
                    fun(C) -> aihtml_action:html(C, {id, ?MEMORIES}, memories(Owner), morph_inner) end);
on_event(_Owner, _Event) ->
    ok.
