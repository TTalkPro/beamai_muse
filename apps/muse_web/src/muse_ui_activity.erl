%% @doc Activity: the task list, task details and action reviews
%% (designs/05-web-ui.md §5, tasks/M6-ui.md M6-3; OpenMuse agent-ui.tsx
%% TaskSheet and details.tsx ReviewDetail).
%%
%% `/activity` lists pending reviews and every task; `/activity/<id>` shows
%% one task: prompt, controls, the input form while it waits for input, its
%% reviews, plan, files, artifacts, browsers and run timeline. Pages follow
%% the owner's `activity` and `{task, Id}` topics; `task_card/2` is the
%% compact card the chat embeds, pushed on `{task_card, Id}`.
-module(muse_ui_activity).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4, task_card/2, approval_card/3]).

-define(K, muse_ui_a_kit).
-define(CONTROLS, [<<"pause">>, <<"resume">>, <<"cancel">>, <<"retry">>]).

%% Page

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    case cowboy_req:path_info(Req) of
        [Id | _] -> detail_page(Owner, Id);
        _ -> {<<"任务与审批"/utf8>>, list_page(Owner)}
    end.

list_page(Owner) ->
    ah_div([?K:page_head(<<"任务与审批"/utf8>>, []),
            ?K:live(Owner, activity, {?MODULE, refresh_list, #{}}, list_body(Owner))],
           [<<"muse-page">>], [{id, <<"activity">>}]).

list_body(Owner) ->
    {ok, #{<<"tasks">> := Tasks}} = muse_agent_service:snapshot(Owner),
    Pending = [A || A = #{<<"status">> := <<"awaiting_review">>} <- actions(Owner)],
    ah_div([case Pending of
                [] -> [];
                _ -> ?K:section(<<"等待你的审批"/utf8>>,
                                ah_div([approval_card(Owner, A, list) || A <- Pending],
                                       [<<"flex flex-col gap-4">>], []))
            end,
            ?K:section(<<"任务"/utf8>>, task_table(Tasks))],
           [<<"flex flex-col gap-6">>], [{id, <<"activity-body">>}]).

task_table([]) ->
    ah_empty([], [], [{title, <<"还没有任务"/utf8>>},
                      {description, <<"在对话里把事情交给我，我会在这里显示进度和需要你确认的地方。"/utf8>>}]);
task_table(Tasks) ->
    ah_ul([ah_li(ah_a([ah_div([ah_div(Title, [<<"muse-row-title">>], []),
                               ah_div(lists:join(<<" · "/utf8>>,
                                                 [M || M <- [?K:kind_label(Kind), progress_text(T),
                                                             ?K:time(maps:get(<<"updatedAt">>, T, null))],
                                                       M =/= <<>>]),
                                      [<<"muse-row-meta">>], [])],
                              [<<"flex-1 min-w-0">>], []),
                       ?K:status_chip(Status),
                       muse_ui_icons:icon(chevron_right, 16)],
                      [<<"muse-row">>], [{href, <<"/activity/", Id/binary>>}]),
                 [], [{id, <<"task-row-", Id/binary>>}])
           || T = #{<<"id">> := Id, <<"title">> := Title, <<"kind">> := Kind,
                    <<"status">> := Status} <- Tasks],
          [<<"muse-list">>], [{id, <<"activity-tasks">>}]).

progress({Done, Total}) when Total > 0 -> round(Done * 100 / Total);
progress(_) -> 0.

steps_done(#{<<"plan">> := Plan}) when is_list(Plan) ->
    {length([S || #{<<"status">> := <<"succeeded">>} = S <- Plan]), length(Plan)};
steps_done(_) ->
    {0, 0}.

progress_text(Task) ->
    case steps_done(Task) of
        {_, 0} -> <<>>;
        {D, T} -> <<"第 "/utf8, (integer_to_binary(D))/binary, "/", (integer_to_binary(T))/binary, " 步"/utf8>>
    end.

%% Task detail

detail_page(Owner, Id) ->
    case muse_agent_service:get_task(Owner, Id) of
        {ok, #{<<"title">> := Title}} ->
            {Title,
             ah_div([ah_a(<<"← 任务与审批"/utf8>>, [<<"text-sm text-muted hover:text-primary">>],
                          [{href, <<"/activity">>}]),
                     ?K:live(Owner, {task, Id}, {?MODULE, refresh_task, #{task => Id}},
                             detail_body(Owner, Id))],
                    [<<"muse-page">>], [{id, <<"task-", Id/binary>>}])};
        {error, _} ->
            {<<"任务与审批"/utf8>>,
             ah_div(ah_empty(ah_a(<<"返回任务列表"/utf8>>, [<<"text-primary">>], [{href, <<"/activity">>}]),
                             [], [{title, <<"找不到这个任务"/utf8>>}]),
                    [<<"p-8">>], [])}
    end.

body_id(Id) -> <<"task-body-", Id/binary>>.
timeline_id(Id) -> <<"task-timeline-", Id/binary>>.

detail_body(Owner, Id) ->
    case muse_agent_service:detail(Owner, Id) of
        {ok, #{<<"task">> := Task} = D} ->
            ah_div([header(Task),
                    ah_p(maps:get(<<"prompt">>, Task, <<>>), [<<"whitespace-pre-wrap">>], []),
                    controls(Task),
                    error_alert(Task),
                    input_form(Task),
                    task_reviews(Owner, Task),
                    result(Task),
                    plan(Task),
                    files(maps:get(<<"files">>, D, [])),
                    artifacts(maps:get(<<"artifacts">>, D, [])),
                    browsers(maps:get(<<"browsers">>, D, [])),
                    ?K:section(<<"时间线"/utf8>>, timeline(Id, maps:get(<<"events">>, D, [])))],
                   [<<"flex flex-col gap-5">>], [{id, body_id(Id)}]);
        {error, E} ->
            ah_div(ah_empty([], [], [{title, ?K:error_text(E)}]), [], [{id, body_id(Id)}])
    end.

header(#{<<"title">> := Title, <<"status">> := Status} = Task) ->
    ah_div([ah_h1(Title, [<<"muse-page-title">>], []),
            ?K:status_chip(Status),
            ah_span([?K:kind_label(maps:get(<<"kind">>, Task, <<>>)), <<" · 更新于 "/utf8>>,
                     ?K:time(maps:get(<<"updatedAt">>, Task, null))],
                    [<<"text-xs text-muted">>], [])],
           [<<"flex flex-wrap items-center gap-3">>], []).

controls(#{<<"id">> := Id, <<"status">> := Status}) ->
    Btn = fun(Label, Op, Css, Opts) ->
                  ah_button(Label, undefined, Css,
                            [{data_op, Op}, on(click, {?MODULE, control, #{task => Id, op => Op}}, Opts)])
          end,
    Pausable = lists:member(Status, [<<"queued">>, <<"running">>, <<"scheduled">>, <<"waiting_input">>,
                                     <<"waiting_approval">>]),
    Buttons = [Btn(<<"暂停"/utf8>>, <<"pause">>, [outlined, sm], #{}) || Pausable]
        ++ [Btn(<<"恢复"/utf8>>, <<"resume">>, [primary, sm], #{}) || Status =:= <<"paused">>]
        ++ [Btn(<<"重试"/utf8>>, <<"retry">>, [primary, sm], #{}) || Status =:= <<"failed">>]
        ++ [Btn(<<"取消"/utf8>>, <<"cancel">>, [error, sm],
                #{confirm => <<"确定取消这个任务吗？等待中的审批会被拒绝。"/utf8>>})
            || not muse_task:is_terminal(Status)],
    case Buttons of
        [] -> [];
        _ -> ah_div(Buttons, [<<"flex flex-wrap gap-2">>], [{id, <<"task-controls-", Id/binary>>}])
    end.

error_alert(#{<<"error">> := E}) when is_binary(E), E =/= <<>> ->
    ah_alert(E, [error], []);
error_alert(_) ->
    [].

result(#{<<"result">> := R}) when R =/= null, R =/= <<>> ->
    ah_alert(ah_span(?K:show(R), [<<"whitespace-pre-wrap">>], []), [success], [{title, <<"结果"/utf8>>}]);
result(_) ->
    [].

%% The form shown while a task waits for input: one control per field the
%% task asks for, an answer, and (documents without a field list) raw JSON.
input_form(#{<<"id">> := Id, <<"status">> := <<"waiting_input">>} = Task) ->
    Missing = missing_fields(Task),
    Question = case maps:get(<<"question">>, Task, null) of
                   Q when is_binary(Q), Q =/= <<>> -> Q;
                   _ -> <<"需要你补充一些信息"/utf8>>
               end,
    Json = case Missing =:= [] andalso maps:get(<<"kind">>, Task, <<>>) =:= <<"document">> of
               true -> [ah_textarea(undefined, [],
                                    [{name, <<"fields_json">>}, {rows, 3},
                                     {label, <<"表单字段（JSON：字段名到值）"/utf8>>},
                                     {placeholder, <<"{\"full_name\":\"Your name\",\"consent\":true}">>}])];
               false -> []
           end,
    ah_card(ah_form([ah_p(Question, [<<"whitespace-pre-wrap">>], []),
                     [field_control(Id, F) || F <- Missing],
                     ah_textarea(undefined, [],
                                 [{name, <<"answer">>}, {rows, 3},
                                  {label, case Missing of
                                              [] -> <<"你的回答"/utf8>>;
                                              _ -> <<"补充说明（可选）"/utf8>>
                                          end}]),
                     Json,
                     ah_div(ah_button(<<"继续任务"/utf8>>, undefined, [primary], [{type, submit}]), [], [])],
                    [<<"flex flex-col gap-3">>],
                    [{id, <<"task-input-", Id/binary>>},
                     on(submit, {?MODULE, answer, #{task => Id}}, #{prevent_default => true})]),
            [], [{title, <<"需要你的信息"/utf8>>}]);
input_form(_) ->
    [].

missing_fields(#{<<"state">> := #{<<"missingFields">> := Fields}}) when is_list(Fields) ->
    lists:filtermap(fun(#{<<"name">> := N} = F) when is_binary(N) ->
                            {true, {N, maps:get(<<"type">>, F, <<"text">>), maps:get(<<"value">>, F, null)}};
                       (N) when is_binary(N) ->
                            {true, {N, <<"text">>, null}};
                       (_) ->
                            false
                    end, Fields);
missing_fields(_) ->
    [].

field_control(TaskId, {Name, <<"checkbox">>, Value}) ->
    ah_checkbox(?K:label(Name), <<"true">>, [],
                [{name, <<"f.", Name/binary>>}, {checked, Value =:= true},
                 {id, <<"task-", TaskId/binary, "-f-", Name/binary>>}]);
field_control(TaskId, {Name, _, Value}) ->
    ah_input(case Value of V when is_binary(V) -> V; _ -> undefined end, [],
             [{name, <<"f.", Name/binary>>}, {label, ?K:label(Name)},
              {id, <<"task-", TaskId/binary, "-f-", Name/binary>>}]).

plan(#{<<"plan">> := [_ | _] = Plan}) ->
    Current = case [I || {I, #{<<"status">> := S}} <- lists:zip(lists:seq(0, length(Plan) - 1), Plan),
                         S =/= <<"succeeded">>] of
                  [I | _] -> I;
                  [] -> length(Plan) - 1
              end,
    Items = [#{title => maps:get(<<"title">>, S, <<>>),
               description => ?K:status_label(maps:get(<<"status">>, S, <<>>)),
               status => step_status(maps:get(<<"status">>, S, <<>>))} || S <- Plan],
    ?K:section(<<"计划"/utf8>>, ah_steps(Items, Current, [], [{orientation, vertical}, {clickable, false}]));
plan(_) ->
    [].

step_status(<<"succeeded">>) -> completed;
step_status(<<"failed">>) -> error;
step_status(S) when S =:= <<"running">>; S =:= <<"waiting">> -> active;
step_status(_) -> pending.

files([]) -> [];
files(Files) ->
    ?K:section(<<"文件"/utf8>>,
               ah_ul([ah_li([ah_span(maps:get(<<"name">>, F, <<"file">>), [<<"flex-1">>], []),
                             ah_a(<<"查看 PDF"/utf8>>, [<<"text-primary hover:underline">>],
                                  [{href, maps:get(<<"url">>, F, <<"#">>)}, {target, <<"_blank">>},
                                   {rel, <<"noopener">>}])],
                            [<<"flex items-center gap-3 text-sm">>], [])
                      || F <- Files],
                     [<<"flex flex-col gap-1">>], [])).

artifacts([]) -> [];
artifacts(Artifacts) ->
    ?K:section(<<"产物"/utf8>>,
               ah_div([ah_card(ah_p(?K:show(maps:get(<<"summary">>, A, <<>>)), [<<"whitespace-pre-wrap text-sm">>], []),
                               [], [{title, maps:get(<<"title">>, A, <<>>)},
                                    {extra, ah_chip(?K:kind_label(maps:get(<<"kind">>, A, <<>>)), [soft, small], [])}])
                       || A <- Artifacts],
                      [<<"flex flex-col gap-3">>], [])).

browsers([]) -> [];
browsers(Browsers) ->
    ?K:section(<<"浏览器"/utf8>>,
               ah_div([ah_card([ah_p(maps:get(<<"url">>, B, <<>>), [<<"text-xs text-muted break-all">>], []),
                                case B of
                                    #{<<"status">> := <<"active">>, <<"previewUrl">> := P} ->
                                        ah_img([<<"w-full rounded-md border border-line">>],
                                               [{src, P}, {alt, <<"浏览器预览"/utf8>>}]);
                                    _ -> []
                                end,
                                ah_a(<<"打开浏览器控制台"/utf8>>, [<<"text-primary text-sm hover:underline">>],
                                     [{href, <<"/browser/", (maps:get(<<"id">>, B))/binary>>}])],
                               [], [{title, maps:get(<<"title">>, B, <<"Agent browser">>)},
                                    {extra, ?K:status_chip(maps:get(<<"status">>, B, <<>>))}])
                       || B <- Browsers],
                      [<<"flex flex-col gap-3">>], [])).

%% Run events, newest first.
timeline(Id, []) ->
    ah_div(ah_p(<<"还没有运行记录"/utf8>>, [<<"text-sm text-muted">>], []), [], [{id, timeline_id(Id)}]);
timeline(Id, Events) ->
    Items = [maps:merge(#{date => ?K:time(maps:get(<<"date">>, E, null)),
                          title => maps:get(<<"title">>, E, <<>>),
                          subtitle => event_kind(maps:get(<<"kind">>, E, <<>>)),
                          dot => dot(maps:get(<<"kind">>, E, <<>>))},
                        case ?K:show(maps:get(<<"detail">>, E, <<>>)) of
                            <<>> -> #{};
                            D -> #{description => D}
                        end)
             || E <- lists:reverse(Events)],
    ah_div(ah_timeline(Items, [], [{position, near}]), [], [{id, timeline_id(Id)}]).

timeline_of(Owner, Id) ->
    timeline(Id, muse_events_log:list(Owner, Id)).

event_kind(<<"result">>) -> <<"结果"/utf8>>;
event_kind(<<"error">>) -> <<"错误"/utf8>>;
event_kind(<<"approval">>) -> <<"审批"/utf8>>;
event_kind(<<"input">>) -> <<"补充信息"/utf8>>;
event_kind(<<"step">>) -> <<"步骤"/utf8>>;
event_kind(<<"tool">>) -> <<"工具"/utf8>>;
event_kind(<<"control">>) -> <<"操作"/utf8>>;
event_kind(<<"status">>) -> <<"状态"/utf8>>;
event_kind(K) -> K.

dot(<<"result">>) -> success;
dot(<<"error">>) -> danger;
dot(<<"approval">>) -> warning;
dot(_) -> primary.

%% Reviews

actions(Owner) ->
    muse_store:list(Owner, <<"actions">>).

task_reviews(Owner, #{<<"id">> := Id} = Task) ->
    Linked = maps:get(<<"actionId">>, Task, null),
    case [A || A = #{<<"id">> := AId} <- actions(Owner),
               maps:get(<<"taskId">>, A, undefined) =:= Id orelse AId =:= Linked] of
        [] -> [];
        Reviews -> ?K:section(<<"审批"/utf8>>,
                              ah_div([approval_card(Owner, A, {task, Id}) || A <- Reviews],
                                     [<<"flex flex-col gap-4">>], []))
    end.

%% @doc A review card: the exact proposal (email draft or event), its hash
%% and status; approve (with the hash) or deny while it awaits review, the
%% receipt or the error afterwards. `Scope` is where it is shown (`list` or
%% `{task, Id}`), so a decision re-renders the right region.
-spec approval_card(binary(), map(), list | {task, binary()}) -> aihtml:html().
approval_card(Owner, #{<<"id">> := Id, <<"status">> := Status} = A, Scope) ->
    Kind = maps:get(<<"kind">>, A, <<>>),
    Data = maps:get(<<"data">>, A, #{}),
    Hash = maps:get(<<"hash">>, A, <<>>),
    Account = case maps:get(<<"account">>, A, undefined) of
                  Acc when is_binary(Acc) -> Acc;
                  _ -> <<"connected account">>
              end,
    Lines = case Kind of
                <<"email.send">> -> email_lines(Owner, Data);
                _ -> event_lines(Kind, Data)
            end,
    Pending = Status =:= <<"awaiting_review">>,
    TaskLink = case {Scope, maps:get(<<"taskId">>, A, undefined)} of
                   {list, T} when is_binary(T) ->
                       ah_a(<<"查看任务 ›"/utf8>>, [<<"text-sm text-primary">>],
                            [{href, <<"/activity/", T/binary>>}]);
                   _ -> []
               end,
    ah_div([ah_div([ah_div([ah_div(maps:get(<<"title">>, A, ?K:kind_label(Kind)), [<<"muse-row-title">>], []),
                            ah_div([?K:kind_label(Kind), <<" · "/utf8>>, Account], [<<"muse-row-meta">>], [])],
                           [<<"flex-1 min-w-0">>], []),
                    ?K:status_chip(Status)],
                   [<<"flex items-start gap-3">>], []),
            ah_dl([[ah_dt(L, [], []), ah_dd(V, [], [])] || {L, V} <- Lines, V =/= <<>>],
                  [<<"muse-fields">>], []),
            outcome(A),
            case Pending of
                true ->
                    Decide = fun(D) -> #{action => Id, hash => Hash, decision => D, scope => Scope} end,
                    [ah_div([ah_button(approve_label(Kind), undefined, [primary],
                                       [{data_decision, approve}, on(click, {?MODULE, decide, Decide(approve)})]),
                             ah_button(<<"拒绝"/utf8>>, undefined, [outlined],
                                       [{data_decision, deny},
                                        on(click, {?MODULE, decide, Decide(deny)},
                                           #{confirm => <<"拒绝这个操作？不会做任何更改。"/utf8>>})])],
                            [<<"flex flex-wrap gap-2">>], []),
                     ah_p([<<"请在 "/utf8>>, ?K:time(maps:get(<<"expiresAt">>, A, null)),
                           <<" 前决定。批准只对上面显示的内容生效。"/utf8>>],
                          [<<"muse-row-meta">>], [])];
                false -> []
            end,
            ah_div([TaskLink,
                    aihtml:ah_el(details, [aihtml:ah_el(summary, <<"校验信息"/utf8>>, [<<"cursor-pointer">>], []),
                                           ah_code(Hash, [<<"break-all">>], [])],
                                 [<<"muse-row-meta ml-auto">>], [])],
                   [<<"flex items-start gap-3">>], [])],
           [<<"muse-card muse-approval">>], [{id, <<"approval-", Id/binary>>}]).

approve_label(Kind) ->
    case {muse_config:get(mode), Kind} of
        {sample, _} -> <<"本地批准"/utf8>>;
        {_, <<"email.send">>} -> <<"批准并发送"/utf8>>;
        _ -> <<"批准更改"/utf8>>
    end.

outcome(#{<<"status">> := <<"outcome_unknown">>} = A) ->
    ah_alert([?K:show(maps:get(<<"error">>, A, <<>>)),
              <<" 结果未知：这次写入可能已经生效，也可能没有。请先在已连接的账户里核实，系统不会自动重试。"/utf8>>],
             [warning], [{title, <<"结果未知"/utf8>>}, {data_outcome, unknown}]);
outcome(#{<<"status">> := <<"failed">>} = A) ->
    ah_alert(?K:show(maps:get(<<"error">>, A, <<>>)), [error], [{title, <<"执行失败"/utf8>>}]);
outcome(#{<<"status">> := <<"succeeded">>} = A) ->
    ah_alert(?K:show(maps:get(<<"result">>, A, <<>>)), [success],
             [{title, <<"回执"/utf8>>}, {data_receipt, true}]);
outcome(#{<<"status">> := <<"denied">>}) ->
    ah_p(<<"已拒绝，没有做任何更改。"/utf8>>, [<<"text-sm text-muted">>], []);
outcome(#{<<"status">> := <<"expired">>}) ->
    ah_p(<<"审批已过期，需要重新准备。"/utf8>>, [<<"text-sm text-muted">>], []);
outcome(_) ->
    [].

list_text(V) when is_list(V) -> iolist_to_binary(lists:join(<<", ">>, [?K:show(X) || X <- V]));
list_text(_) -> <<>>.

email_lines(Owner, Data) ->
    Attachments = [case muse_files:get(Owner, FId) of
                       {ok, F} ->
                           #{<<"url">> := Url} = muse_files:signed(Owner, F),
                           ah_a([maps:get(<<"name">>, F, FId), <<" · 查看 PDF"/utf8>>],
                                [<<"text-primary hover:underline block">>],
                                [{href, Url}, {target, <<"_blank">>}, {rel, <<"noopener">>}]);
                       {error, _} -> ah_span(?K:show(FId), [<<"block">>], [])
                   end || FId <- maps:get(<<"attachmentIds">>, Data, [])],
    [{<<"收件人"/utf8>>, list_text(maps:get(<<"to">>, Data, []))},
     {<<"抄送"/utf8>>, list_text(maps:get(<<"cc">>, Data, []))},
     {<<"密送"/utf8>>, list_text(maps:get(<<"bcc">>, Data, []))},
     {<<"主题"/utf8>>, ?K:show(maps:get(<<"subject">>, Data, <<>>))},
     {<<"正文"/utf8>>, ?K:show(maps:get(<<"body">>, Data, <<>>))},
     {<<"附件"/utf8>>, case Attachments of [] -> <<>>; _ -> Attachments end}].

event_lines(<<"calendar.delete">>, Data) ->
    [{<<"事件"/utf8>>, ?K:show(maps:get(<<"title">>, Data, <<>>))},
     {<<"日历"/utf8>>, ?K:show(maps:get(<<"calendarId">>, Data, <<"primary">>))},
     {<<"说明"/utf8>>, <<"这会删除该事件，可能会通知参与者。"/utf8>>}];
event_lines(_Kind, Data) ->
    G = fun(K) -> ?K:show(maps:get(K, Data, <<>>)) end,
    AllDay = maps:get(<<"allDay">>, Data, false) =:= true,
    When = case AllDay of
               true -> [G(<<"start">>), <<"（全天）"/utf8>>];
               false -> [?K:time(G(<<"start">>)), <<" – "/utf8>>, ?K:time(G(<<"end">>))]
           end,
    [{<<"日程"/utf8>>, G(<<"title">>)},
     {<<"时间"/utf8>>, iolist_to_binary(When)},
     {<<"时区"/utf8>>, G(<<"timeZone">>)},
     {<<"地点"/utf8>>, G(<<"location">>)},
     {<<"参与者"/utf8>>, list_text(maps:get(<<"attendees">>, Data, []))},
     {<<"备注"/utf8>>, G(<<"description">>)},
     {<<"日历"/utf8>>, case G(<<"calendarId">>) of <<>> -> <<"primary">>; C -> C end}].

%% @doc The compact task card the chat embeds: title, status, progress and
%% a link. Its root id is `task-card-<Id>`; `on_event/2` replaces it on the
%% `{task_card, Id}` topic.
-spec task_card(binary(), map() | binary()) -> aihtml:element().
task_card(Owner, Id) when is_binary(Id) ->
    case muse_agent_service:get_task(Owner, Id) of
        {ok, Task} -> task_card(Owner, Task);
        {error, _} -> ah_div(<<"任务不存在"/utf8>>, [<<"text-sm text-muted">>], [{id, <<"task-card-", Id/binary>>}])
    end;
task_card(_Owner, #{<<"id">> := Id, <<"status">> := Status} = Task) ->
    {Done, Total} = steps_done(Task),
    Note = case Status of
               <<"waiting_input">> -> ?K:show(maps:get(<<"question">>, Task, <<"需要你的信息"/utf8>>));
               <<"waiting_approval">> -> <<"等待你的审批"/utf8>>;
               _ -> <<>>
           end,
    ah_div([ah_div([ah_a(maps:get(<<"title">>, Task, <<>>), [<<"muse-row-title flex-1 hover:text-primary">>],
                         [{href, <<"/activity/", Id/binary>>}]),
                    ?K:status_chip(Status)],
                   [<<"flex items-center gap-2">>], []),
            case Total of
                0 -> [];
                _ -> ah_progressbar(progress({Done, Total}), [], [])
            end,
            case Note of
                <<>> -> [];
                _ -> ah_p(muse_js:slice(Note, 240), [<<"text-xs text-muted">>], [])
            end,
            ah_a(<<"查看详情 ›"/utf8>>, [<<"text-sm text-primary">>],
                 [{href, <<"/activity/", Id/binary>>}])],
           [<<"muse-card flex flex-col gap-2">>],
           [{id, <<"task-card-", Id/binary>>}, {data_status, Status}]).

%% Actions

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(refresh_list, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> push_list(Ctx, Owner) end);
action(refresh_task, #{task := Id}, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> push_task(Ctx, Owner, Id) end);
action(control, #{task := Id, op := Op}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = case lists:member(Op, ?CONTROLS) of
                                true -> muse_agent_service:control(Owner, Id, Op);
                                false -> {error, {422, <<"Invalid control">>}}
                            end,
                   ?K:done(Ctx, Result, fun(_) -> push_task(Ctx, Owner, Id) end)
           end);
action(answer, #{task := Id}, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = maybe
                                {ok, Task} ?= muse_agent_service:get_task(Owner, Id),
                                {ok, Fields} ?= answer_fields(Task, Event),
                                Answer = case ?K:form_text(Event, <<"answer">>) of
                                             <<>> when map_size(Fields) > 0 -> <<"Provided the requested fields.">>;
                                             A -> A
                                         end,
                                Body = case map_size(Fields) of
                                           0 -> #{<<"answer">> => Answer};
                                           _ -> #{<<"answer">> => Answer, <<"fields">> => Fields}
                                       end,
                                {ok, #{<<"answer">> := Valid} = Input} ?= muse_validate:parse(muse_task:answer_schema(), Body),
                                muse_agent_service:answer(Owner, Id, Valid, maps:get(<<"fields">>, Input, undefined))
                            end,
                   ?K:done(Ctx, Result, fun(_) -> push_task(Ctx, Owner, Id) end)
           end);
action(decide, #{action := AId, hash := Hash, decision := D} = Args, _Event, Ctx)
  when D =:= approve; D =:= deny ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Rerender = fun() -> case maps:get(scope, Args, list) of
                                           {task, TaskId} -> push_task(Ctx, Owner, TaskId);
                                           _ -> push_list(Ctx, Owner)
                                       end
                              end,
                   case muse_actions:decide(Owner, AId, Hash, D) of
                       {ok, #{<<"status">> := <<"outcome_unknown">>}} ->
                           ?K:toast_error(Ctx, <<"结果未知，请先核实再操作"/utf8>>),
                           Rerender();
                       {ok, _} -> Rerender();
                       {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E)), Rerender()
                   end
           end).

%% Field values from the form: `f.<name>` per requested field (checkboxes
%% are true when ticked), or a JSON object in `fields_json`.
answer_fields(Task, Event) ->
    case ?K:form_text(Event, <<"fields_json">>) of
        <<>> ->
            {ok, maps:from_list(
                   lists:append(
                     [case Type of
                          <<"checkbox">> ->
                              [{Name, ?K:form_value(Event, <<"f.", Name/binary>>) =/= undefined
                                andalso ?K:form_value(Event, <<"f.", Name/binary>>) =/= <<>>}];
                          _ ->
                              case ?K:form_text(Event, <<"f.", Name/binary>>) of
                                  <<>> -> [];
                                  V -> [{Name, V}]
                              end
                      end || {Name, Type, _} <- missing_fields(Task)]))};
        Json ->
            case muse_json:decode(Json) of
                {ok, M} when is_map(M) -> {ok, M};
                _ -> {error, {422, <<"Form fields must be a JSON object with text or true/false values.">>}}
            end
    end.

push_list(Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, <<"activity-body">>}, list_body(Owner), morph).

push_task(Ctx, Owner, Id) ->
    aihtml_action:html(Ctx, {id, body_id(Id)}, detail_body(Owner, Id), morph).

%% Live updates

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {task, Id}) ->
    ?K:publish(Owner, activity, fun(C) -> push_list(C, Owner) end),
    ?K:publish(Owner, {task, Id}, fun(C) -> push_task(C, Owner, Id) end),
    ?K:publish(Owner, {task_card, Id},
               fun(C) ->
                       case muse_agent_service:get_task(Owner, Id) of
                           {ok, Task} -> aihtml_action:html(C, {id, <<"task-card-", Id/binary>>},
                                                            task_card(Owner, Task), outer);
                           {error, _} -> ok
                       end
               end);
on_event(Owner, {run_event, TaskId, _Event}) ->
    ?K:publish(Owner, {task, TaskId},
               fun(C) -> aihtml_action:html(C, {id, timeline_id(TaskId)}, timeline_of(Owner, TaskId), morph) end);
on_event(Owner, {action, AId}) ->
    ?K:publish(Owner, activity, fun(C) -> push_list(C, Owner) end),
    case muse_actions:get(Owner, AId) of
        #{<<"taskId">> := TaskId} when is_binary(TaskId) ->
            ?K:publish(Owner, {task, TaskId}, fun(C) -> push_task(C, Owner, TaskId) end);
        _ ->
            ok
    end;
on_event(_Owner, _Event) ->
    ok.
