%% @doc Ideas: suggestions with their evidence; the prompt can be edited
%% before accepting (which starts a task), or the idea dismissed
%% (designs/05-web-ui.md §5, tasks/M6-ui.md M6-4). Live on the owner's
%% `ideas` topic.
-module(muse_ui_ideas).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4]).

-define(K, muse_ui_a_kit).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    {<<"Ideas">>,
     ah_div([?K:page_head(<<"Ideas">>,
                          [ah_button(<<"重新查找"/utf8>>, undefined, [outlined, sm],
                                     [{id, <<"ideas-refresh">>}, on(click, {?MODULE, find, #{}})])]),
             ?K:live(Owner, ideas, {?MODULE, refresh, #{}}, body(Owner))],
            [<<"p-6 flex flex-col gap-6 max-w-4xl">>], [{id, <<"ideas">>}])}.

body(Owner) ->
    {ok, #{<<"ideas">> := Ideas}} = muse_agent_service:snapshot(Owner),
    {New, Done} = lists:partition(fun(#{<<"status">> := S}) -> S =:= <<"new">> end, Ideas),
    ah_div([case New of
                [] -> ah_empty([], [], [{title, <<"暂时没有新的建议"/utf8>>},
                                        {description, <<"Muse 会根据邮件和目标提出可以代劳的事。"/utf8>>}]);
                _ -> ah_div([idea_card(I) || I <- New], [<<"flex flex-col gap-4">>], [])
            end,
            case Done of
                [] -> [];
                _ -> ?K:section(<<"已处理"/utf8>>,
                                ah_ul([ah_li([ah_span(maps:get(<<"title">>, I, <<>>), [<<"flex-1">>], []),
                                              ?K:status_chip(S),
                                              case maps:get(<<"taskId">>, I, undefined) of
                                                  T when is_binary(T), S =:= <<"accepted">> ->
                                                      ah_a(<<"查看任务"/utf8>>, [<<"text-primary hover:underline">>],
                                                           [{href, <<"/activity/", T/binary>>}]);
                                                  _ -> []
                                              end],
                                             [<<"flex items-center gap-3 text-sm">>],
                                             [{id, <<"idea-", Id/binary>>}])
                                       || I = #{<<"id">> := Id, <<"status">> := S} <- Done],
                                      [<<"flex flex-col gap-2">>], []))
            end],
           [<<"flex flex-col gap-6">>], [{id, <<"ideas-body">>}]).

idea_card(#{<<"id">> := Id} = I) ->
    ah_card([ah_p(maps:get(<<"reason">>, I, <<>>), [<<"text-sm">>], []),
             case maps:get(<<"evidence">>, I, []) of
                 [] -> [];
                 Evidence ->
                     ah_div([ah_blockquote([ah_p([ah_strong(maps:get(<<"title">>, E, <<>>), [], []),
                                                  ah_span([<<" · "/utf8>>, maps:get(<<"kind">>, E, <<>>)],
                                                          [<<"text-xs text-muted">>], [])], [], []),
                                            ah_p(maps:get(<<"excerpt">>, E, <<>>),
                                                 [<<"text-xs text-muted whitespace-pre-wrap">>], [])],
                                           [<<"border-l-2 border-line pl-3">>], [])
                             || E <- Evidence, is_map(E)],
                            [<<"flex flex-col gap-2">>], [])
             end,
             ah_form([ah_textarea(maps:get(<<"prompt">>, I, <<>>), [],
                                  [{name, <<"prompt">>}, {rows, 3}, {label, <<"任务说明（可修改）"/utf8>>},
                                   {id, <<"idea-prompt-", Id/binary>>}]),
                      ah_div([ah_button(<<"采纳"/utf8>>, undefined, [primary, sm], [{type, submit}]),
                              ah_button(<<"忽略"/utf8>>, undefined, [outlined, sm],
                                        [on(click, {?MODULE, dismiss, #{idea => Id}})])],
                             [<<"flex gap-2">>], [])],
                     [<<"flex flex-col gap-3">>],
                     [on(submit, {?MODULE, accept, #{idea => Id}}, #{prevent_default => true})])],
            [], [{id, <<"idea-", Id/binary>>},
                 {title, maps:get(<<"title">>, I, <<>>)},
                 {extra, ah_chip(maps:get(<<"kind">>, I, <<>>), [soft, small], [])}]).

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(refresh, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> push(Ctx, Owner) end);
action(find, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) ->
                                    ?K:done(Ctx, muse_ideas:refresh(Owner), fun(_) -> push(Ctx, Owner) end)
                            end);
action(accept, #{idea := Id}, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = maybe
                                {ok, Prompt} ?= muse_validate:parse({string, #{trim => true, min => 1, max => 12000}},
                                                                    ?K:form_text(Event, <<"prompt">>)),
                                muse_ideas:decide(Owner, Id, <<"accept">>, Prompt)
                            end,
                   ?K:done(Ctx, Result,
                           fun(Idea) ->
                                   case Idea of
                                       #{<<"taskId">> := T} when is_binary(T) ->
                                           ?K:toast_ok(Ctx, <<"已开始任务"/utf8>>);
                                       _ -> ok
                                   end,
                                   push(Ctx, Owner)
                           end)
           end);
action(dismiss, #{idea := Id}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   ?K:done(Ctx, muse_ideas:decide(Owner, Id, <<"dismiss">>, undefined), fun(_) -> push(Ctx, Owner) end)
           end).

push(Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, <<"ideas-body">>}, body(Owner), morph).

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {idea, _}) ->
    ?K:publish(Owner, ideas, fun(C) -> push(C, Owner) end);
on_event(_Owner, _Event) ->
    ok.
