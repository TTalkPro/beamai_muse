%% @doc Approvals `/approvals` (designs/05-web-ui.md §5, tasks/M9-workspace.md
%% M9-10; in OpenMuse the reviews sit with the tasks).
%%
%% Reviews no longer come only from tasks: the chat proposes calendar
%% changes and mail sends that have no task. So every action waiting for the
%% person is gathered here, apart from the task list (`/activity`, 任务):
%% the pending reviews first (the same approval card as in the chat and on
%% a task, muse_ui_activity:approval_card/3 with scope `approvals`), then
%% the decided ones (the last 50 proposed), newest first, each one line that opens to its card.
%% The page follows the owner's `approvals_page` topic; every `{action, _}`
%% event re-renders it. The sidebar count is `muse_ui_layout:approval_count/1`.
-module(muse_ui_approvals).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4, pending/1, push/2]).

-define(K, muse_ui_a_kit).
-define(HISTORY, 50).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    {<<"审批"/utf8>>,
     ah_div([?K:page_head(<<"审批"/utf8>>, []),
             ah_p(<<"智能体要替你对外做的事（发邮件、改日程，以及任务里的写入）会先停在这里，批准后才执行。"/utf8>>,
                  [<<"text-sm text-muted">>], []),
             ?K:live(Owner, approvals_page, {?MODULE, refresh, #{}}, body(Owner))],
            [<<"muse-page">>], [{id, <<"approvals">>}])}.

%% @doc The reviews waiting for the person (not yet expired), newest first.
-spec pending(binary()) -> [map()].
pending(Owner) ->
    Now = muse_time:now_ms(),
    newest([A || A = #{<<"status">> := <<"awaiting_review">>} <- muse_store:list(Owner, <<"actions">>),
                 not muse_time:is_due(maps:get(<<"expiresAt">>, A, undefined), Now)]).

body(Owner) ->
    Pending = pending(Owner),
    Decided = lists:sublist(newest([A || A = #{<<"status">> := S} <- muse_store:list(Owner, <<"actions">>),
                                         S =/= <<"awaiting_review">>]),
                            ?HISTORY),
    ah_div([?K:section(<<"等待你决定"/utf8>>,
                       case Pending of
                           [] -> ah_empty([], [compact], [{title, <<"没有等待审批的事项"/utf8>>},
                                                          {description, <<"智能体提议发邮件、改日程时，会出现在这里和对话里。"/utf8>>}]);
                           _ -> ah_div([muse_ui_activity:approval_card(Owner, A, approvals) || A <- Pending],
                                       [<<"flex flex-col gap-4">>], [{id, <<"approvals-pending">>}])
                       end),
            case Decided of
                [] -> [];
                _ -> ?K:section(<<"已处理"/utf8>>,
                                ah_div([history_row(Owner, A) || A <- Decided],
                                       [<<"muse-list">>], [{id, <<"approvals-history">>}]))
            end],
           [<<"flex flex-col gap-6">>], [{id, <<"approvals-body">>}]).

%% One decided review: title, kind, status and time; it opens to its card.
history_row(Owner, #{<<"id">> := Id, <<"status">> := Status} = A) ->
    #{title := Title} = muse_actions:display(A),
    aihtml:ah_el(details,
                 [aihtml:ah_el(summary,
                               [ah_div([ah_div(maps:get(<<"title">>, A, Title), [<<"muse-row-title">>], []),
                                        ah_div(lists:join(<<" · "/utf8>>,
                                                          [M || M <- [?K:kind_label(maps:get(<<"kind">>, A, <<>>)),
                                                                      [<<"提议于 "/utf8>>, ?K:time(proposed_at(A))]],
                                                                M =/= <<>>]),
                                               [<<"muse-row-meta">>], [])],
                                       [<<"flex-1 min-w-0">>], []),
                                ?K:status_chip(Status)],
                               [<<"muse-row cursor-pointer">>], []),
                  ah_div(muse_ui_activity:approval_card(Owner, A, approvals), [<<"mt-2">>], [])],
                 [], [{id, <<"approval-row-", Id/binary>>}]).

proposed_at(A) ->
    maps:get(<<"createdAt">>, A, null).

newest(Actions) ->
    lists:sort(fun(X, Y) -> proposed_at(X) >= proposed_at(Y) end, Actions).

%% @doc Re-render the page body (after a decision made here).
-spec push(aihtml_action:ctx(), binary()) -> ok.
push(Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, <<"approvals-body">>}, body(Owner), morph),
    ok.

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(refresh, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> push(Ctx, Owner) end).

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {action, _}) ->
    ?K:publish(Owner, approvals_page, fun(C) -> push(C, Owner) end);
on_event(_Owner, _Event) ->
    ok.
