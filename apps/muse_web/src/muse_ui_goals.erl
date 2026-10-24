%% @doc Goals: create, milestone check boxes, pause / complete / reopen
%% (designs/05-web-ui.md §5, tasks/M6-ui.md M6-4). Live on the owner's
%% `goals` topic.
-module(muse_ui_goals).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4]).

-define(K, muse_ui_a_kit).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    {<<"目标"/utf8>>,
     ah_div([?K:page_head(<<"目标"/utf8>>, []),
             new_form(),
             ?K:live(Owner, goals, {?MODULE, refresh, #{}}, body(Owner))],
            [<<"p-6 flex flex-col gap-6 max-w-4xl">>], [{id, <<"goals">>}])}.

new_form() ->
    ah_card(ah_form([ah_input(undefined, [], [{name, <<"title">>}, {label, <<"目标"/utf8>>},
                                              {placeholder, <<"例如：准备秋季旅行"/utf8>>}]),
                     ah_input(undefined, [], [{name, <<"description">>}, {label, <<"描述（可选）"/utf8>>}]),
                     ah_textarea(undefined, [], [{name, <<"milestones">>}, {rows, 3},
                                                 {label, <<"里程碑（每行一个，可选）"/utf8>>}]),
                     ah_div(ah_button(<<"新建目标"/utf8>>, undefined, [primary], [{type, submit}]), [], [])],
                    [<<"flex flex-col gap-3">>],
                    [{id, <<"goal-form">>}, on(submit, {?MODULE, create, #{}}, #{prevent_default => true})]),
            [], [{title, <<"新目标"/utf8>>}]).

body(Owner) ->
    {ok, #{<<"goals">> := Goals, <<"tasks">> := Tasks}} = muse_agent_service:snapshot(Owner),
    ah_div(case Goals of
               [] -> ah_empty([], [], [{title, <<"还没有目标"/utf8>>}]);
               _ -> [goal_card(G, Tasks) || G <- Goals]
           end,
           [<<"flex flex-col gap-4">>], [{id, <<"goals-body">>}]).

goal_card(#{<<"id">> := Id, <<"status">> := Status} = G, Tasks) ->
    Ms = maps:get(<<"milestones">>, G, []),
    Done = length([M || #{<<"done">> := true} = M <- Ms]),
    Related = [T || T = #{<<"goalId">> := GId} <- Tasks, GId =:= Id],
    StatusBtn = fun(Label, To, Css) ->
                        ah_button(Label, undefined, Css,
                                  [{data_to, To}, on(click, {?MODULE, status, #{goal => Id, status => To}})])
                end,
    ah_card([case maps:get(<<"description">>, G, <<>>) of
                 <<>> -> [];
                 D -> ah_p(D, [<<"text-sm whitespace-pre-wrap">>], [])
             end,
             case Ms of
                 [] -> ah_p(<<"还没有里程碑"/utf8>>, [<<"text-sm text-muted">>], []);
                 _ -> [ah_p([integer_to_binary(Done), <<" / ">>, integer_to_binary(length(Ms)), <<" 个里程碑已完成"/utf8>>],
                            [<<"text-xs text-muted">>], []),
                       ah_progressbar(round(Done * 100 / length(Ms)), [success], []),
                       ah_div([ah_checkbox(MTitle, MId, [],
                                           [{checked, maps:get(<<"done">>, M, false) =:= true},
                                            {id, <<"ms-", Id/binary, "-", MId/binary>>},
                                            on(change, {?MODULE, milestone, #{goal => Id, milestone => MId}})])
                               || M = #{<<"id">> := MId, <<"title">> := MTitle} <- Ms],
                              [<<"flex flex-col gap-1">>], [])]
             end,
             case Related of
                 [] -> [];
                 _ -> ah_div([ah_a(T, [<<"text-xs text-primary hover:underline">>],
                                   [{href, <<"/activity/", TId/binary>>}])
                              || #{<<"id">> := TId, <<"title">> := T} <- Related],
                             [<<"flex flex-wrap gap-3">>], [])
             end,
             ah_div(case Status of
                        <<"active">> -> [StatusBtn(<<"暂停"/utf8>>, <<"paused">>, [outlined, sm]),
                                         StatusBtn(<<"完成"/utf8>>, <<"completed">>, [success, sm])];
                        <<"paused">> -> [StatusBtn(<<"恢复"/utf8>>, <<"active">>, [primary, sm]),
                                         StatusBtn(<<"完成"/utf8>>, <<"completed">>, [success, sm])];
                        _ -> [StatusBtn(<<"重新打开"/utf8>>, <<"active">>, [outlined, sm])]
                    end, [<<"flex flex-wrap gap-2">>], [])],
            [], [{id, <<"goal-", Id/binary>>},
                 {title, maps:get(<<"title">>, G, <<>>)},
                 {subtitle, maps:get(<<"category">>, G, <<>>)},
                 {extra, ?K:status_chip(Status)}]).

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(refresh, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> push(Ctx, Owner) end);
action(create, _Args, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Milestones = [L || L0 <- binary:split(?K:form_text(Event, <<"milestones">>), <<"\n">>, [global]),
                                      (L = string:trim(L0)) =/= <<>>],
                   Raw = #{<<"title">> => ?K:form_text(Event, <<"title">>),
                           <<"description">> => ?K:form_text(Event, <<"description">>),
                           <<"milestones">> => Milestones},
                   ?K:done(Ctx, muse_agent_service:create_goal(Owner, Raw),
                           fun(_) ->
                                   [aihtml_action:set_value(Ctx, <<"#goal-form [name=", N/binary, "]">>, <<>>)
                                    || N <- [<<"title">>, <<"description">>, <<"milestones">>]],
                                   push(Ctx, Owner)
                           end)
           end);
action(milestone, #{goal := GoalId, milestone := MId}, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Done = maps:get(checked, Event, false) =:= true,
                   ?K:done(Ctx, muse_agent_service:set_milestone_done(Owner, GoalId, MId, Done),
                           fun(_) -> push(Ctx, Owner) end)
           end);
action(status, #{goal := GoalId, status := Status}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = case muse_validate:parse(muse_task:goal_update_schema(), #{<<"status">> => Status}) of
                                {ok, Patch} -> muse_agent_service:update_goal(Owner, GoalId, Patch);
                                Error -> Error
                            end,
                   ?K:done(Ctx, Result, fun(_) -> push(Ctx, Owner) end)
           end).

push(Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, <<"goals-body">>}, body(Owner), morph).

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {goal, _}) ->
    ?K:publish(Owner, goals, fun(C) -> push(C, Owner) end);
on_event(Owner, {task, _}) ->
    %% task titles listed under their goals
    ?K:publish(Owner, goals, fun(C) -> push(C, Owner) end);
on_event(_Owner, _Event) ->
    ok.
