%% @doc Notifications: the list, mark one or all read, open the task a
%% notification is about (or its page, `href`: a new mail) (designs/05-web-ui.md §5, tasks/M6-ui.md M6-4).
%% Live on the owner's `notifications` topic; the toast and the unread
%% badge are muse_ui_layout's.
-module(muse_ui_notifications).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4]).

-define(K, muse_ui_a_kit).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    {<<"通知"/utf8>>,
     ah_div([?K:page_head(<<"通知"/utf8>>,
                          [ah_button(<<"全部标为已读"/utf8>>, undefined, [outlined, sm],
                                     [{id, <<"notifications-read-all">>}, on(click, {?MODULE, read_all, #{}})])]),
             ?K:live(Owner, notifications, {?MODULE, refresh, #{}}, body(Owner))],
            [<<"muse-page">>], [{id, <<"notifications">>}])}.

body(Owner) ->
    ah_div(case muse_agent_service:notifications(Owner) of
               [] -> ah_empty([], [], [{title, <<"没有通知"/utf8>>},
                                       {description, <<"任务结果和需要你决定的事会出现在这里。"/utf8>>}]);
               Ns -> [item(N) || N <- Ns]
           end,
           [<<"flex flex-col gap-3">>], [{id, <<"notifications-body">>}]).

item(#{<<"id">> := Id} = N) ->
    Read = maps:get(<<"read">>, N, false) =:= true,
    TaskId = maps:get(<<"taskId">>, N, undefined),
    ah_div([ah_div([ah_span(maps:get(<<"title">>, N, <<>>), [<<"font-medium flex-1">>], []),
                    case Read of
                        true -> [];
                        false -> ah_chip(<<"未读"/utf8>>, [soft, small, primary], [])
                    end,
                    ah_span(?K:time(maps:get(<<"createdAt">>, N, null)), [<<"text-xs text-muted">>], [])],
                   [<<"flex items-center gap-2">>], []),
            ah_p(maps:get(<<"body">>, N, <<>>), [<<"text-sm whitespace-pre-wrap break-words">>], []),
            ah_div([case {is_binary(TaskId), maps:get(<<"href">>, N, undefined)} of
                        {true, _} -> ah_button(<<"查看任务"/utf8>>, undefined, [outlined, sm],
                                               [on(click, {?MODULE, open, #{id => Id, task => TaskId}})]);
                        %% a page of the app (a new mail's /mail/<id>)
                        {false, <<"/", _/binary>> = Href} ->
                            ah_button(<<"查看"/utf8>>, undefined, [outlined, sm],
                                      [on(click, {?MODULE, open, #{id => Id, href => Href}})]);
                        _ -> []
                    end,
                    case Read of
                        true -> [];
                        false -> ah_button(<<"标为已读"/utf8>>, undefined, [borderless, sm],
                                           [on(click, {?MODULE, read, #{id => Id}})])
                    end],
                   [<<"flex gap-2">>], [])],
           [<<"rounded-lg border border-line p-4 flex flex-col gap-2">>,
            case Read of true -> <<"opacity-70">>; false -> <<"border-primary">> end],
           [{id, <<"notification-", Id/binary>>}, {data_read, Read}]).

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(refresh, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> push(Ctx, Owner) end);
action(read, #{id := Id}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   ?K:done(Ctx, muse_agent_service:read_notification(Owner, Id), fun(_) -> push(Ctx, Owner) end)
           end);
action(read_all, _Args, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   _ = [muse_agent_service:read_notification(Owner, Id)
                        || #{<<"id">> := Id, <<"read">> := false} <- muse_agent_service:notifications(Owner)],
                   push(Ctx, Owner)
           end);
action(open, #{id := Id, href := <<"/", _/binary>> = Href}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   _ = muse_agent_service:read_notification(Owner, Id),
                   aihtml_action:redirect(Ctx, Href)
           end);
action(open, #{id := Id, task := TaskId}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   _ = muse_agent_service:read_notification(Owner, Id),
                   aihtml_action:redirect(Ctx, <<"/activity/", TaskId/binary>>)
           end).

push(Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, <<"notifications-body">>}, body(Owner), morph).

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {notification, _}) ->
    ?K:publish(Owner, notifications, fun(C) -> push(C, Owner) end);
on_event(_Owner, _Event) ->
    ok.
