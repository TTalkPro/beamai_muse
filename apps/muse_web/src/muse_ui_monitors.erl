%% @doc Monitors ("追踪"): create the three kinds of watch (page change,
%% text appears, price below), pause / resume / stop / check now, the
%% latest change as a diff, and in sample mode the editable test page
%% (designs/05-web-ui.md §5, tasks/M6-ui.md M6-4; OpenMuse agent-ui.tsx
%% MonitorForm / MonitorCard). Live on the owner's `monitors` topic.
-module(muse_ui_monitors).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4]).

-define(K, muse_ui_a_kit).
-define(SAMPLE_URL, <<"sample://availability">>).
-define(CONTROLS, [<<"pause">>, <<"resume">>, <<"stop">>, <<"check">>]).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    Sample = muse_config:get(mode) =:= sample,
    {<<"追踪"/utf8>>,
     ah_div([?K:page_head(<<"追踪"/utf8>>, []),
             new_form(Sample),
             case Sample of
                 true -> sample_page(Owner);
                 false -> []
             end,
             ?K:live(Owner, monitors, {?MODULE, refresh, #{}}, body(Owner))],
            [<<"p-6 flex flex-col gap-6 max-w-4xl">>], [{id, <<"monitors">>}])}.

new_form(Sample) ->
    ah_card(ah_form([ah_input(undefined, [], [{name, <<"title">>}, {label, <<"名称"/utf8>>},
                                              {placeholder, <<"例如：周五晚餐的空位"/utf8>>}]),
                     ah_input(case Sample of true -> ?SAMPLE_URL; false -> undefined end, [],
                              [{name, <<"url">>}, {label, <<"网址"/utf8>>},
                               {placeholder, case Sample of
                                                 true -> <<"https://… 或 sample://availability"/utf8>>;
                                                 false -> <<"https://…"/utf8>>
                                             end}]),
                     ah_div([ah_label([ah_span(<<"条件"/utf8>>, [<<"text-sm">>], []),
                                       ah_select([{<<"change">>, <<"页面有变化"/utf8>>},
                                                  {<<"contains">>, <<"出现指定文字"/utf8>>},
                                                  {<<"price_below">>, <<"价格低于"/utf8>>}],
                                                 <<"change">>, [], [{name, <<"condition">>}])],
                                      [<<"flex flex-col gap-1 flex-1">>], []),
                             ah_input(undefined, [<<"flex-1">>],
                                      [{name, <<"value">>}, {label, <<"文字或价格"/utf8>>},
                                       {placeholder, <<"页面变化时可留空"/utf8>>}]),
                             ah_input(<<"15">>, [<<"w-32">>],
                                      [{name, <<"intervalMinutes">>}, {type, number}, {min, 1}, {max, 10080},
                                       {label, <<"间隔（分钟）"/utf8>>}])],
                            [<<"flex flex-wrap gap-3 items-end">>], []),
                     ah_div(ah_button(<<"开始追踪"/utf8>>, undefined, [primary], [{type, submit}]), [], [])],
                    [<<"flex flex-col gap-3">>],
                    [{id, <<"monitor-form">>}, on(submit, {?MODULE, create, #{}}, #{prevent_default => true})]),
            [], [{title, <<"新的追踪"/utf8>>}]).

%% Sample mode: the built-in availability page the sample watches read.
sample_page(Owner) ->
    Text = case muse_store:get(Owner, <<"sample-pages">>, <<"availability">>) of
               #{<<"text">> := T} -> T;
               _ -> <<"No tables available. Check again later.">>
           end,
    ah_card(ah_form([ah_p(<<"示例模式下，sample://availability 读取这里的文字。修改后点“保存并检查”，示例追踪会立即检查一次。"/utf8>>,
                          [<<"text-sm text-muted">>], []),
                     ah_textarea(Text, [], [{name, <<"text">>}, {rows, 4}, {id, <<"sample-page-text">>}]),
                     ah_div([ah_button(<<"保存"/utf8>>, undefined, [outlined, sm], [{type, submit}]),
                             ah_button(<<"保存并检查"/utf8>>, undefined, [primary, sm],
                                       [on(click, {?MODULE, sample_page, #{check => true}})])],
                            [<<"flex gap-2">>], [])],
                    [<<"flex flex-col gap-3">>],
                    [{id, <<"sample-page-form">>},
                     on(submit, {?MODULE, sample_page, #{check => false}}, #{prevent_default => true})]),
            [], [{title, <<"测试页面"/utf8>>}, {id, <<"sample-page">>}]).

body(Owner) ->
    {ok, #{<<"monitors">> := Monitors}} = muse_agent_service:snapshot(Owner),
    ah_div(case Monitors of
               [] -> ah_empty([], [], [{title, <<"还没有追踪"/utf8>>},
                                       {description, <<"追踪网页变化、某段文字出现或价格低于阈值。"/utf8>>}]);
               _ -> [monitor_card(Owner, M) || M <- Monitors]
           end,
           [<<"flex flex-col gap-4">>], [{id, <<"monitors-body">>}]).

monitor_card(Owner, #{<<"id">> := Id, <<"status">> := Status} = M) ->
    Url = maps:get(<<"url">>, M, <<>>),
    Value = maps:get(<<"value">>, M, <<>>),
    Btn = fun(Label, Op, Css, Opts) ->
                  ah_button(Label, undefined, Css,
                            [{data_op, Op}, on(click, {?MODULE, control, #{monitor => Id, op => Op}}, Opts)])
          end,
    ah_card([ah_p(case Url of ?SAMPLE_URL -> <<"内置可用性页面 (sample://availability)"/utf8>>; _ -> Url end,
                  [<<"text-xs text-muted break-all">>], []),
             ah_p(case maps:get(<<"condition">>, M, <<"change">>) of
                      <<"contains">> -> [<<"出现 “"/utf8>>, Value, <<"” 时提醒"/utf8>>];
                      <<"price_below">> -> [<<"价格低于 "/utf8>>, Value, <<" 时提醒"/utf8>>];
                      _ -> <<"页面变化时提醒"/utf8>>
                  end, [<<"text-sm">>], []),
             ah_p([<<"每 "/utf8>>, ?K:show(maps:get(<<"intervalMinutes">>, M, 15)), <<" 分钟 · 已检查 "/utf8>>,
                   ?K:show(maps:get(<<"checks">>, M, 0)), <<" 次 · 上次 "/utf8>>,
                   case ?K:time(maps:get(<<"lastCheckedAt">>, M, null)) of <<>> -> <<"—"/utf8>>; T -> T end,
                   case Status of
                       <<"active">> -> [<<" · 下次 "/utf8>>, ?K:time(maps:get(<<"nextCheckAt">>, M, null))];
                       _ -> []
                   end],
                  [<<"text-xs text-muted">>], []),
             case maps:get(<<"error">>, M, null) of
                 E when is_binary(E), E =/= <<>> -> ah_alert(E, [error], []);
                 _ -> []
             end,
             latest_change(Owner, M),
             case maps:get(<<"lastValue">>, M, null) of
                 LV when is_binary(LV), LV =/= <<>> ->
                     ah_details_pre(<<"最近一次读取的内容"/utf8>>, LV);
                 _ -> []
             end,
             case Status of
                 <<"stopped">> -> [];
                 _ -> ah_div([case Status of
                                  <<"active">> -> Btn(<<"暂停"/utf8>>, <<"pause">>, [outlined, sm], #{});
                                  _ -> Btn(<<"恢复"/utf8>>, <<"resume">>, [primary, sm], #{})
                              end,
                              Btn(<<"立即检查"/utf8>>, <<"check">>, [outlined, sm], #{}),
                              Btn(<<"停止"/utf8>>, <<"stop">>, [error, sm],
                                  #{confirm => <<"停止这个追踪？停止后需要重新创建。"/utf8>>})],
                             [<<"flex flex-wrap gap-2">>], [])
             end,
             case maps:get(<<"taskId">>, M, undefined) of
                 TaskId when is_binary(TaskId) ->
                     ah_a(<<"查看任务记录"/utf8>>, [<<"text-xs text-primary hover:underline">>],
                          [{href, <<"/activity/", TaskId/binary>>}]);
                 _ -> []
             end],
            [], [{id, <<"monitor-", Id/binary>>},
                 {title, maps:get(<<"title">>, M, <<>>)},
                 {extra, ?K:status_chip(Status)}]).

ah_details_pre(Summary, Text) ->
    aihtml:ah_el(details, [aihtml:ah_el(summary, Summary, [<<"text-xs text-muted cursor-pointer">>], []),
                    ah_pre(Text, [<<"text-xs whitespace-pre-wrap break-words mt-1">>], [])],
          [], []).

%% The latest change the watch reported: its description and a word diff
%% between the two observations around it.
latest_change(Owner, #{<<"taskId">> := TaskId}) when is_binary(TaskId) ->
    Events = muse_events_log:list(Owner, TaskId),
    Observations = [D || #{<<"kind">> := <<"observation">>, <<"detail">> := D} <- Events, is_binary(D)],
    Changes = [D || #{<<"kind">> := <<"result">>, <<"detail">> := D} <- Events, is_binary(D)],
    case changed_pair(lists:reverse(Observations)) of
        {Old, New} ->
            ah_div([ah_p(<<"最近的变化"/utf8>>, [<<"text-xs font-semibold text-muted">>], []),
                    case Changes of
                        [] -> [];
                        _ -> ah_p(lists:last(Changes), [<<"text-sm whitespace-pre-wrap">>], [])
                    end,
                    ah_diff(Old, New, [], [{mode, word}])],
                   [<<"flex flex-col gap-1">>], [{id, <<"monitor-diff-", TaskId/binary>>}]);
        none ->
            []
    end;
latest_change(_Owner, _M) ->
    [].

%% Newest first: the newest observation that differs from the one before it.
changed_pair([New, Old | Rest]) when New =:= Old -> changed_pair([Old | Rest]);
changed_pair([New, Old | _]) -> {Old, New};
changed_pair(_) -> none.

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(refresh, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> push(Ctx, Owner) end);
action(create, _Args, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Interval = ?K:form_text(Event, <<"intervalMinutes">>),
                   Raw = #{<<"title">> => ?K:form_text(Event, <<"title">>),
                           <<"url">> => ?K:form_text(Event, <<"url">>),
                           <<"condition">> => case ?K:form_text(Event, <<"condition">>) of
                                                  <<>> -> <<"change">>;
                                                  C -> C
                                              end,
                           <<"value">> => ?K:form_text(Event, <<"value">>),
                           <<"intervalMinutes">> => case string:to_integer(Interval) of
                                                        {N, <<>>} when is_integer(N) -> N;
                                                        _ when Interval =:= <<>> -> 15;
                                                        _ -> Interval
                                                    end},
                   ?K:done(Ctx, muse_monitors:create(Owner, Raw, undefined),
                           fun(_) ->
                                   [aihtml_action:set_value(Ctx, <<"#monitor-form [name=", N/binary, "]">>, <<>>)
                                    || N <- [<<"title">>, <<"value">>]],
                                   push(Ctx, Owner)
                           end)
           end);
action(control, #{monitor := Id, op := Op}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = case lists:member(Op, ?CONTROLS) of
                                true -> muse_monitors:control(Owner, Id, Op);
                                false -> {error, {422, <<"Invalid control">>}}
                            end,
                   ?K:done(Ctx, Result, fun(_) -> push(Ctx, Owner) end)
           end);
action(sample_page, #{check := Check}, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Text = binary:replace(case ?K:form_value(Event, <<"text">>) of
                                             undefined -> <<>>;
                                             V -> V
                                         end, <<"\r\n">>, <<"\n">>, [global]),
                   Result = case muse_validate:parse({string, #{max => 100000}}, Text) of
                                {ok, Valid} -> muse_agent_service:set_sample_page(Owner, Valid);
                                Error -> Error
                            end,
                   ?K:done(Ctx, Result,
                           fun(_) ->
                                   Checked = case Check of
                                                 true -> [muse_monitors:control(Owner, Id, <<"check">>)
                                                          || #{<<"id">> := Id, <<"url">> := ?SAMPLE_URL,
                                                               <<"status">> := S}
                                                                 <- muse_store:list(Owner, <<"monitors">>),
                                                             S =/= <<"stopped">>];
                                                 false -> []
                                             end,
                                   ?K:toast_ok(Ctx, case Checked of
                                                        [] -> <<"测试页面已保存"/utf8>>;
                                                        _ -> <<"测试页面已保存，正在检查"/utf8>>
                                                    end),
                                   push(Ctx, Owner)
                           end)
           end).

push(Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, <<"monitors-body">>}, body(Owner), morph).

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {monitor, _}) ->
    ?K:publish(Owner, monitors, fun(C) -> push(C, Owner) end);
on_event(Owner, {run_event, _TaskId, #{<<"kind">> := K}}) when K =:= <<"observation">>; K =:= <<"result">> ->
    %% the change and diff come from the run log, written after the monitor update
    ?K:publish(Owner, monitors, fun(C) -> push(C, Owner) end);
on_event(_Owner, _Event) ->
    ok.
