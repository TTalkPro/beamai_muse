%% @doc Tool cards in the chat (designs/05-web-ui.md §4, OpenMuse
%% useRenderTool): one card per tool call, rendered from the call's
%% arguments and its JSON result. `pending` renders the loading state
%% while the call runs. Each card's root has id `tc-<CallId>` so the relay
%% can replace it when the result arrives.
-module(muse_ui_cards).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/6, card_id/1]).

-spec card_id(binary()) -> binary().
card_id(CallId) -> <<"tc-", CallId/binary>>.

%% @doc A card for tool `Name` called with `Args` (map) that returned
%% `Result` (the tool message content: JSON text) or is still `pending`.
-spec render(binary(), binary(), binary(), binary(), map(), binary() | pending) -> aihtml:element().
render(_Owner, _Tid, CallId, Name, _Args, pending) ->
    frame(CallId, label(Name), ah_div([ah_loader([], []), ah_span(<<"进行中…"/utf8>>, [<<"text-sm text-muted">>], [])],
                                      [<<"flex items-center gap-2">>], []));
render(Owner, Tid, CallId, Name, Args, Result) ->
    Decoded = case muse_json:decode(Result) of
                  {ok, V} -> V;
                  _ -> Result
              end,
    Body = try body(Owner, Tid, Name, Args, Decoded)
           catch _:_ -> raw(Decoded)
           end,
    frame(CallId, label(Name), Body).

frame(CallId, Title, Body) ->
    ah_div([ah_div(Title, [<<"text-xs font-semibold uppercase tracking-wide text-muted mb-2">>], []), Body],
           [<<"rounded-lg border border-line bg-surface p-3 my-2 max-w-2xl">>],
           [{id, card_id(CallId)}]).

label(<<"search_mail">>) -> <<"邮件搜索"/utf8>>;
label(<<"read_mail_thread">>) -> <<"邮件线程"/utf8>>;
label(<<"read_calendar">>) -> <<"日历"/utf8>>;
label(<<"browse_web">>) -> <<"浏览网页"/utf8>>;
label(<<"search_web">>) -> <<"网页搜索"/utf8>>;
label(<<"delegate_task">>) -> <<"委派任务"/utf8>>;
label(<<"agent_status">>) -> <<"任务状态"/utf8>>;
label(<<"create_goal">>) -> <<"目标"/utf8>>;
label(<<"watch_page">>) -> <<"追踪"/utf8>>;
label(<<"remember_fact">>) -> <<"记忆"/utf8>>;
label(<<"present_choices">>) -> <<"选项"/utf8>>;
label(<<"use_desktop">>) -> <<"桌面"/utf8>>;
label(<<"computer_", _/binary>> = N) -> <<"电脑 · "/utf8, N/binary>>;
label(N) -> N.

%% Bodies

%% The model gets the screenshot as an image part; the stored text carries
%% a signed same-origin `screenshotUrl` for this card (muse_computer_tools).
body(_O, _T, <<"use_desktop">>, _A, #{} = R) ->
    ah_div([case maps:get(<<"screenshotUrl">>, R, maps:get(<<"screenshot">>, R, undefined)) of
                <<"/", _/binary>> = Src ->
                    ah_img([<<"rounded border border-line max-w-full">>],
                           [{src, Src}, {alt, <<"桌面截图"/utf8>>}]);
                _ -> []
            end,
            ah_p(first([<<"error">>, <<"warning">>, <<"action">>], R), [<<"text-sm">>], [])], [], []);
body(_O, _T, <<"search_mail">>, _A, #{<<"matches">> := Matches} = R) ->
    [mail_list(Matches),
     [ah_p(<<"结果已截断"/utf8>>, [<<"text-xs text-muted">>], []) || maps:get(<<"truncated">>, R, false) =:= true]];
body(_O, _T, <<"read_mail_thread">>, _A, #{<<"messages">> := Messages}) ->
    ah_div([ah_div([ah_div([ah_strong(field(<<"sender">>, M), [], []), <<" · ">>,
                            ah_span(field(<<"date">>, M), [<<"text-muted">>], [])], [<<"text-sm">>], []),
                    ah_div(field(<<"subject">>, M), [<<"font-medium">>], []),
                    ah_p(muse_js:slice(text_of(M), 600), [<<"text-sm whitespace-pre-wrap">>], [])],
                   [<<"border-t border-line pt-2 mt-2 first:border-0 first:mt-0 first:pt-0">>], [])
            || M <- Messages], [], []);
body(_O, _T, <<"read_calendar">>, _A, Events) when is_list(Events) ->
    event_list(Events);
body(_O, _T, <<"read_calendar">>, _A, #{<<"events">> := Events}) ->
    event_list(Events);
body(_O, _T, <<"browse_web">>, _A, #{} = R) ->
    Url = field(<<"url">>, R),
    ah_div([ah_div(field(<<"title">>, R), [<<"font-medium">>], []),
            ah_a(Url, [<<"text-xs text-primary break-all">>], [{href, Url}, {target, <<"_blank">>}, {rel, <<"noopener noreferrer">>}]),
            ah_p(muse_js:slice(first([<<"summary">>, <<"text">>, <<"content">>], R), 500),
                 [<<"text-sm mt-1 whitespace-pre-wrap">>], []),
            case maps:get(<<"sessionId">>, R, maps:get(<<"browserId">>, R, undefined)) of
                Sid when is_binary(Sid) ->
                    ah_a(<<"接管浏览器"/utf8>>, [<<"text-sm text-primary">>], [{href, <<"/browser/", Sid/binary>>}]);
                _ -> []
            end], [], []);
body(_O, _T, <<"search_web">>, _A, #{<<"results">> := Results}) ->
    sources(Results);
body(_O, _T, <<"search_web">>, _A, Results) when is_list(Results) ->
    sources(Results);
body(Owner, _T, Name, _A, #{<<"id">> := Id, <<"status">> := _} = Task)
  when Name =:= <<"delegate_task">> ->
    task_card(Owner, Id, Task);
body(Owner, _T, <<"agent_status">>, _A, #{<<"tasks">> := Tasks}) ->
    case Tasks of
        [] -> ah_p(<<"没有任务"/utf8>>, [<<"text-sm text-muted">>], []);
        _ -> ah_div([task_card(Owner, Id, T) || T = #{<<"id">> := Id} <- lists:sublist(Tasks, 5)],
                    [<<"flex flex-col gap-2">>], [])
    end;
body(_O, _T, <<"create_goal">>, _A, #{<<"title">> := Title} = Goal) ->
    ah_div([ah_a(Title, [<<"font-medium text-primary">>], [{href, <<"/goals">>}]),
            ah_ul([ah_li(field(<<"title">>, M), [], []) || M <- maps:get(<<"milestones">>, Goal, [])],
                  [<<"list-disc ml-5 text-sm">>], [])], [], []);
body(_O, _T, <<"watch_page">>, _A, #{<<"url">> := Url} = M) ->
    ah_div([ah_a(field(<<"title">>, M, Url), [<<"font-medium text-primary">>], [{href, <<"/monitors">>}]),
            ah_div([status_chip(field(<<"status">>, M)), <<" ">>, ah_span(Url, [<<"text-xs text-muted break-all">>], [])],
                   [<<"mt-1">>], [])], [], []);
body(_O, _T, <<"remember_fact">>, _A, #{<<"text">> := Text}) ->
    ah_p([<<"已记住："/utf8>>, Text], [<<"text-sm">>], []);
body(_O, Tid, <<"present_choices">>, _A, #{<<"panel">> := #{} = Panel}) ->
    muse_ui_chat:choice_panel(Tid, Panel);
body(_O, _T, <<"present_choices">>, _A, #{<<"error">> := Error}) ->
    ah_alert(Error, [warning], []);
body(_O, _T, <<"computer_", _/binary>>, Args, #{} = R) ->
    command_receipt(Args, R);
body(_O, _T, _Name, _A, #{<<"error">> := Error}) when is_binary(Error) ->
    ah_alert(Error, [error], []);
body(_O, _T, _Name, _A, Other) ->
    raw(Other).

mail_list([]) ->
    ah_p(<<"没有匹配的邮件"/utf8>>, [<<"text-sm text-muted">>], []);
mail_list(Matches) ->
    ah_ul([ah_li([ah_div([ah_strong(field(<<"sender">>, M, field(<<"from">>, M)), [], []), <<" · ">>,
                          ah_span(field(<<"date">>, M), [<<"text-muted">>], [])], [<<"text-sm">>], []),
                  ah_div(field(<<"subject">>, M), [<<"font-medium">>], []),
                  ah_div(muse_js:slice(field(<<"snippet">>, M, field(<<"preview">>, M)), 200),
                         [<<"text-sm text-muted">>], [])],
                 [<<"py-1">>], []) || M <- Matches],
          [<<"divide-y divide-line">>], []).

event_list([]) ->
    ah_p(<<"没有日程"/utf8>>, [<<"text-sm text-muted">>], []);
event_list(Events) ->
    ah_ul([ah_li([ah_strong(first([<<"title">>, <<"summary">>], E), [], []), <<" · ">>,
                  ah_span([field(<<"start">>, E), <<" – "/utf8>>, field(<<"end">>, E)], [<<"text-muted">>], []),
                  case field(<<"location">>, E) of <<>> -> []; L -> [<<" · ">>, L] end],
                 [<<"text-sm py-1">>], []) || E <- Events, is_map(E)],
          [], []).

sources(Results) ->
    ah_ul([ah_li([ah_a(field(<<"title">>, R, field(<<"url">>, R)), [<<"text-primary">>],
                       [{href, field(<<"url">>, R)}, {target, <<"_blank">>}, {rel, <<"noopener noreferrer">>}]),
                  ah_div(muse_js:slice(first([<<"excerpt">>, <<"snippet">>, <<"text">>], R), 300),
                         [<<"text-xs text-muted">>], [])],
                 [<<"text-sm py-1">>], []) || R <- Results, is_map(R)],
          [], []).

command_receipt(Args, R) ->
    Command = first([<<"command">>, <<"cmd">>, <<"path">>], maps:merge(Args, R)),
    Exit = maps:get(<<"exitCode">>, R, maps:get(<<"exit_code">>, R, undefined)),
    ah_div([ah_code(Command, [<<"text-sm">>], []),
            case Exit of
                undefined -> [];
                _ -> ah_span([<<" 退出码 "/utf8>>, integer_to_binary(Exit)],
                             [case Exit of 0 -> <<"text-xs text-success">>; _ -> <<"text-xs text-danger">> end], [])
            end,
            [aihtml:ah_el(details, [aihtml:ah_el(summary, Label, [<<"text-xs text-muted cursor-pointer">>], []),
                             ah_pre(muse_js:slice(Out, 8000), [<<"muse-terminal text-xs max-h-64 overflow-auto">>], [])],
                   [<<"mt-1">>], [])
             || {Label, Key} <- [{<<"stdout">>, <<"stdout">>}, {<<"stderr">>, <<"stderr">>}],
                Out <- [field(Key, R)], Out =/= <<>>]], [], []).

task_card(Owner, _Id, Task) ->
    %% live via the {task_card, Id} topic (muse_ui_activity)
    muse_ui_activity:task_card(Owner, Task).

-spec status_chip(binary()) -> aihtml:html().
status_chip(Status) ->
    ah_chip(Status, [<<"text-xs">>], []).

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
        V when is_binary(V) -> V;
        V when is_integer(V) -> integer_to_binary(V);
        _ -> Default
    end;
field(_, _, Default) -> Default.
