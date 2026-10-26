%% @doc Tool calls in the chat (designs/05-web-ui.md §4, OpenMuse
%% useRenderTool). Most calls render as one quiet line, "搜索了网页 · 10 个来源",
%% that opens to its details (sources, command output, a screenshot); the
%% ones that need the user stay full cards: delegated tasks and task status
%% (live task cards with approvals) and Jev choice panels.
%%
%% Rendered from the call's arguments and its JSON result, or `pending`
%% while it runs. Each root has id `tc-<CallId>` so the relay can replace it
%% when the result arrives.
-module(muse_ui_cards).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/6, card_id/1]).

-define(I, muse_ui_icons).

-spec card_id(binary()) -> binary().
card_id(CallId) -> <<"tc-", CallId/binary>>.

%% @doc The chat element for tool `Name` called with `Args` (map) that
%% returned `Result` (the tool message content: JSON text) or is still
%% `pending`.
-spec render(binary(), binary(), binary(), binary(), map(), binary() | pending) -> aihtml:element().
render(_Owner, _Tid, CallId, Name, _Args, pending) ->
    step(CallId, running, icon(Name), working(Name), []);
render(Owner, Tid, CallId, Name, Args, Result) ->
    Decoded = case muse_json:decode(Result) of
                  {ok, V} -> V;
                  _ -> Result
              end,
    try card(Owner, Tid, CallId, Name, Args, Decoded)
    catch _:_ -> step(CallId, done, icon(Name), [<<"调用了 "/utf8>>, ah_strong(Name, [], [])], raw(Decoded))
    end.

%% Full cards

card(Owner, _Tid, CallId, <<"delegate_task">>, _A, #{<<"id">> := _, <<"status">> := _} = Task) ->
    ah_div(muse_ui_activity:task_card(Owner, Task), [], [{id, card_id(CallId)}]);
card(Owner, _Tid, CallId, <<"agent_status">>, _A, #{<<"tasks">> := [_ | _] = Tasks}) ->
    ah_div([muse_ui_activity:task_card(Owner, T) || T = #{<<"id">> := _} <- lists:sublist(Tasks, 5)],
           [<<"flex flex-col gap-2">>], [{id, card_id(CallId)}]);
card(_Owner, Tid, CallId, <<"present_choices">>, _A, #{<<"panel">> := #{} = Panel}) ->
    ah_div(muse_ui_chat:choice_panel(Tid, Panel), [], [{id, card_id(CallId)}]);
card(_Owner, _Tid, CallId, Name, Args, Result) ->
    case Result of
        #{<<"error">> := Error} when is_binary(Error) ->
            step(CallId, failed, icon(Name), failed(Name), ah_p(Error, [], []));
        _ ->
            {Summary, State, Body} = describe(Name, Args, Result),
            step(CallId, State, icon(Name), Summary, Body)
    end.

%% One-line steps

step(CallId, State, Icon, Summary, Body) ->
    Mark = case State of
               running -> ah_span([], [<<"muse-spin">>], [{aria_label, <<"进行中"/utf8>>}]);
               done -> ah_span(?I:icon(check, 16), [<<"muse-step-ok">>], [{aria_label, <<"完成"/utf8>>}]);
               failed -> ah_span(?I:icon(alert, 16), [<<"muse-step-fail">>], [{aria_label, <<"失败"/utf8>>}])
           end,
    Line = [?I:icon(Icon, 16), ah_span(Summary, [<<"muse-step-text">>], []), Mark,
            case Body of
                [] -> [];
                _ -> ah_span(?I:icon(chevron_right, 14), [<<"muse-chevron">>], [])
            end],
    aihtml:ah_el(details, [aihtml:ah_el(summary, Line, [], []),
                           case Body of
                               [] -> [];
                               _ -> ah_div(Body, [<<"muse-step-body">>], [])
                           end],
                 [<<"muse-step">>], [{id, card_id(CallId)}, {data_state, atom_to_binary(State)}]).

icon(<<"search_web">>) -> search;
icon(<<"browse_web">>) -> globe;
icon(<<"search_mail">>) -> mail;
icon(<<"read_mail_thread">>) -> mail;
icon(<<"read_calendar">>) -> calendar;
icon(<<"use_desktop">>) -> monitor;
icon(<<"remember_fact">>) -> brain;
icon(<<"delegate_task">>) -> tasks;
icon(<<"agent_status">>) -> tasks;
icon(<<"present_choices">>) -> sparkles;
icon(<<"run_computer_command">>) -> terminal;
icon(<<"import_computer_pdf">>) -> file;
icon(<<"export_computer_pdf">>) -> file;
icon(<<"read_computer_file">>) -> file;
icon(<<"write_computer_file">>) -> file;
icon(<<"list_computer_files">>) -> file;
icon(<<"mkdir_computer">>) -> file;
icon(<<"computer_status">>) -> monitor;
icon(<<"start_computer">>) -> monitor;
icon(<<"stop_computer">>) -> monitor;
icon(_) -> tool.

working(<<"search_web">>) -> <<"正在搜索网页…"/utf8>>;
working(<<"browse_web">>) -> <<"正在阅读网页…"/utf8>>;
working(<<"search_mail">>) -> <<"正在查找邮件…"/utf8>>;
working(<<"read_mail_thread">>) -> <<"正在读邮件…"/utf8>>;
working(<<"read_calendar">>) -> <<"正在查看日历…"/utf8>>;
working(<<"use_desktop">>) -> <<"正在操作桌面…"/utf8>>;
working(<<"run_computer_command">>) -> <<"正在执行命令…"/utf8>>;
working(<<"start_computer">>) -> <<"正在启动电脑…"/utf8>>;
working(<<"stop_computer">>) -> <<"正在关闭电脑…"/utf8>>;
working(<<"delegate_task">>) -> <<"正在安排任务…"/utf8>>;
working(<<"present_choices">>) -> <<"正在准备选项…"/utf8>>;
working(<<"remember_fact">>) -> <<"正在记下…"/utf8>>;
working(_) -> <<"处理中…"/utf8>>.

failed(<<"search_web">>) -> <<"网页搜索失败"/utf8>>;
failed(<<"browse_web">>) -> <<"没能读取网页"/utf8>>;
failed(<<"run_computer_command">>) -> <<"命令没能执行"/utf8>>;
failed(<<"use_desktop">>) -> <<"桌面操作失败"/utf8>>;
failed(<<"present_choices">>) -> <<"没能准备选项"/utf8>>;
failed(Name) -> [ah_strong(Name, [], []), <<" 失败"/utf8>>].

%% {Summary, State, Body} of a finished call.
describe(<<"search_web">>, _A, R) ->
    Results = case R of
                  #{<<"results">> := L} when is_list(L) -> L;
                  L when is_list(L) -> L
              end,
    Sources = [S || S = #{<<"url">> := _} <- Results],
    Note = [ah_p(<<"部分结果或摘录已省略。"/utf8>>, [<<"text-xs text-muted">>], [])
            || is_map(R), maps:get(<<"truncated">>, R, false) =:= true],
    {[<<"搜索了网页 · "/utf8>>, count(length(Sources), <<"个来源"/utf8>>)], done,
     case Sources of
         [] -> [];
         _ -> [ah_ul([ah_li(ext_link(field(<<"title">>, S, field(<<"url">>, S)), field(<<"url">>, S)), [], [])
                      || S <- Sources], [<<"flex flex-col gap-1">>], []), Note]
     end};
describe(<<"browse_web">>, A, #{} = R) ->
    Url = field(<<"url">>, R, field(<<"url">>, A)),
    Takeover = case maps:get(<<"sessionId">>, R, maps:get(<<"browserId">>, R, undefined)) of
                   Sid when is_binary(Sid) ->
                       ah_a(<<"接管这个浏览器 ›"/utf8>>, [<<"text-sm">>], [{href, <<"/browser/", Sid/binary>>}]);
                   _ -> []
               end,
    {[<<"已浏览 · "/utf8>>, ah_strong(host(Url), [], [])], done,
     [ext_link(field(<<"title">>, R, Url), Url), Takeover]};
describe(<<"search_mail">>, _A, #{<<"matches">> := Matches}) ->
    {[<<"查找了邮件 · "/utf8>>, count(length(Matches), <<"封"/utf8>>)], done,
     case Matches of [] -> []; _ -> mail_list(Matches) end};
describe(<<"read_mail_thread">>, _A, #{<<"messages">> := [First | _] = Messages}) ->
    {[<<"读了邮件 · "/utf8>>, ah_strong(field(<<"subject">>, First), [], [])], done,
     [ah_div([ah_div([ah_strong(field(<<"sender">>, M), [], []), <<" · ">>,
                      ah_span(field(<<"date">>, M), [<<"text-muted">>], [])], [], []),
              ah_p(muse_js:slice(text_of(M), 600), [<<"whitespace-pre-wrap text-muted">>], [])], [], [])
      || M <- Messages]};
describe(<<"read_calendar">>, A, Events) when is_list(Events) ->
    describe(<<"read_calendar">>, A, #{<<"events">> => Events});
describe(<<"read_calendar">>, _A, #{<<"events">> := Events}) ->
    {[<<"查看了日历 · "/utf8>>, count(length(Events), <<"个日程"/utf8>>)], done,
     case Events of [] -> []; _ -> event_list(Events) end};
describe(<<"run_computer_command">>, A, #{} = R) ->
    Command = field(<<"command">>, R, field(<<"command">>, A)),
    Exit = maps:get(<<"exitCode">>, R, undefined),
    Ok = maps:get(<<"status">>, R, <<"succeeded">>) =:= <<"succeeded">> andalso (Exit =:= undefined orelse Exit =:= 0),
    {[<<"执行了命令 "/utf8>>, ah_code(muse_js:slice(Command, 80), [], [])],
     case Ok of true -> done; false -> failed end,
     [[ah_p([<<"退出码 "/utf8>>, integer_to_binary(Exit)], [<<"text-xs text-muted">>], []) || is_integer(Exit)],
      [ah_pre(muse_js:slice(Out, 6000), [<<"muse-terminal text-xs max-h-64 overflow-auto">>], [])
       || Key <- [<<"stdout">>, <<"stderr">>], Out <- [field(Key, R)], Out =/= <<>>]]};
describe(<<"use_desktop">>, A, #{} = R) ->
    Shot = case maps:get(<<"screenshotUrl">>, R, maps:get(<<"screenshot">>, R, undefined)) of
               <<"/", _/binary>> = Src -> ah_img([], [{src, Src}, {alt, <<"操作后的桌面截图"/utf8>>}, {loading, lazy}]);
               _ -> []
           end,
    {[<<"操作了桌面 · "/utf8>>, desktop_action(A)], done, Shot};
describe(<<"computer_status">>, _A, #{} = R) ->
    {[<<"查看了电脑 · "/utf8>>, computer_state(field(<<"status">>, R))], done, []};
describe(<<"start_computer">>, _A, _R) -> {<<"启动了电脑"/utf8>>, done, []};
describe(<<"stop_computer">>, _A, _R) -> {<<"关闭了电脑"/utf8>>, done, []};
describe(<<"list_computer_files">>, A, #{} = R) ->
    Entries = maps:get(<<"entries">>, R, []),
    {[<<"列出了文件 · "/utf8>>, ah_code(field(<<"path">>, A), [], [])], done,
     case Entries of
         [] -> [];
         _ -> ah_ul([ah_li(field(<<"name">>, E), [<<"font-mono text-xs">>], []) || E <- lists:sublist(Entries, 50), is_map(E)],
                    [], [])
     end};
describe(<<"read_computer_file">>, A, #{} = R) ->
    {[<<"读取了文件 · "/utf8>>, ah_code(field(<<"path">>, A), [], [])], done,
     case field(<<"text">>, R) of
         <<>> -> [];
         T -> ah_pre(muse_js:slice(T, 3000), [<<"muse-terminal text-xs max-h-64 overflow-auto">>], [])
     end};
describe(<<"write_computer_file">>, A, _R) ->
    {[<<"写入了文件 · "/utf8>>, ah_code(field(<<"path">>, A), [], [])], done, []};
describe(<<"mkdir_computer">>, A, _R) ->
    {[<<"新建了文件夹 · "/utf8>>, ah_code(field(<<"path">>, A), [], [])], done, []};
describe(<<"import_computer_pdf">>, A, _R) ->
    {[<<"把 PDF 放进了电脑 · "/utf8>>, ah_code(field(<<"path">>, A), [], [])], done, []};
describe(<<"export_computer_pdf">>, A, _R) ->
    {[<<"从电脑导出了 PDF · "/utf8>>, ah_code(field(<<"path">>, A), [], [])], done, []};
describe(<<"remember_fact">>, _A, #{<<"text">> := Text}) ->
    {[<<"记住了 · "/utf8>>, muse_js:slice(Text, 80)], done, []};
describe(<<"agent_status">>, _A, #{<<"tasks">> := []}) ->
    {<<"查看了任务 · 目前没有任务"/utf8>>, done, []};
describe(Name, _A, Other) ->
    {[<<"调用了 "/utf8>>, ah_strong(Name, [], [])], done, raw(Other)}.

desktop_action(A) ->
    Action = field(<<"action">>, A),
    Verb = case Action of
               <<"left_click">> -> <<"单击"/utf8>>;
               <<"double_click">> -> <<"双击"/utf8>>;
               <<"right_click">> -> <<"右键"/utf8>>;
               <<"middle_click">> -> <<"中键"/utf8>>;
               <<"type">> -> <<"输入文字"/utf8>>;
               <<"key">> -> <<"按键"/utf8>>;
               <<"scroll">> -> <<"滚动"/utf8>>;
               <<"screenshot">> -> <<"截图"/utf8>>;
               <<"wait">> -> <<"等待"/utf8>>;
               <<"mouse_move">> -> <<"移动鼠标"/utf8>>;
               <<"left_click_drag">> -> <<"拖动"/utf8>>;
               _ -> Action
           end,
    Detail = case Action of
                 <<"key">> -> [<<" ">>, ah_code(field(<<"text">>, A), [], [])];
                 <<"type">> -> [<<" “"/utf8>>, muse_js:slice(field(<<"text">>, A), 40), <<"”"/utf8>>];
                 _ -> []
             end,
    [Verb, Detail].

computer_state(<<"running">>) -> <<"运行中"/utf8>>;
computer_state(<<"stopped">>) -> <<"已停止"/utf8>>;
computer_state(S) -> S.

count(N, Unit) -> [integer_to_binary(N), <<" ">>, Unit].

host(Url) ->
    case uri_string:parse(Url) of
        #{host := H} when is_binary(H), H =/= <<>> ->
            case H of <<"www.", Rest/binary>> -> Rest; _ -> H end;
        _ -> Url
    end.

ext_link(Text, Url) ->
    ah_a(Text, [], [{href, Url}, {target, <<"_blank">>}, {rel, <<"noopener noreferrer">>}]).

mail_list(Matches) ->
    ah_ul([ah_li([ah_div([ah_strong(field(<<"sender">>, M, field(<<"from">>, M)), [], []), <<" · ">>,
                          ah_span(field(<<"date">>, M), [<<"text-muted">>], [])], [], []),
                  ah_div(field(<<"subject">>, M), [], []),
                  ah_div(muse_js:slice(field(<<"snippet">>, M, field(<<"preview">>, M)), 200),
                         [<<"text-muted">>], [])],
                 [<<"py-1">>], []) || M <- Matches, is_map(M)],
          [<<"divide-y divide-line">>], []).

event_list(Events) ->
    ah_ul([ah_li([ah_strong(first([<<"title">>, <<"summary">>], E), [], []), <<" · ">>,
                  ah_span([field(<<"start">>, E), <<" – "/utf8>>, field(<<"end">>, E)], [<<"text-muted">>], []),
                  case field(<<"location">>, E) of <<>> -> []; L -> [<<" · ">>, L] end],
                 [<<"py-1">>], []) || E <- Events, is_map(E)],
          [], []).

raw(V) when is_binary(V) ->
    ah_pre(muse_js:slice(V, 4000), [<<"text-xs whitespace-pre-wrap max-h-64 overflow-auto">>], []);
raw(V) ->
    raw(muse_json:encode(V)).

text_of(M) -> first([<<"text">>, <<"body">>, <<"snippet">>], M).

first([K | Rest], M) ->
    case maps:get(K, M, undefined) of
        V when is_binary(V), V =/= <<>> -> V;
        _ -> first(Rest, M)
    end;
first([], _) -> <<>>.

field(K, M) -> field(K, M, <<>>).

field(K, M, Default) when is_map(M) ->
    case maps:get(K, M, undefined) of
        V when is_binary(V), V =/= <<>> -> V;
        V when is_integer(V) -> integer_to_binary(V);
        _ -> Default
    end;
field(_, _, Default) -> Default.
