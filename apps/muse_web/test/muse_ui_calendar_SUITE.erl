%% The built-in calendar in the UI and the JSON API (tasks/M9-workspace.md
%% M9-7): the `/calendar` page and its actions, called the way the aihtml
%% runtime calls them (POST /aihtml/action with a signed token and an
%% event), the chat's approval card for a proposed change, and
%% `/api/calendars`, `/api/calendar/events`. Sample mode.
-module(muse_ui_calendar_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).
-define(EVENTS, <<"calendar-events">>).

all() ->
    [page_render, create_through_form, lazy_load_on_change, drag_and_resize, edit_and_delete, select_range,
     calendar_toggles, calendar_manage, chat_proposal_card, api_routes].

init_per_testcase(_Case, Config) ->
    Env = muse_web_test_env:start(),
    C = [{env, Env} | Config],
    [{cookie, sign_in(C)} | C].

end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)).

%% HTTP helpers (as muse_ui_pages_b_SUITE)

host(Config) ->
    #{port := Port} = ?config(env, Config),
    "localhost:" ++ integer_to_list(Port).

origin() -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

same_origin(Config) -> [{"origin", origin()}, {"host", host(Config)}].

req(Config, Method, Path, Headers, Body) ->
    Url = muse_web_test_env:base(?config(env, Config)) ++ Path,
    Request = case Body of
                  undefined -> {Url, Headers};
                  {form, Form} -> {Url, Headers, "application/x-www-form-urlencoded", uri_string:compose_query(Form)};
                  {Type, Bin} -> {Url, Headers, Type, Bin}
              end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{autoredirect, false}, {timeout, 30000}], [{body_format, binary}]),
    {Status, RespHeaders, RespBody}.

sign_in(Config) ->
    {302, H, _} = req(Config, post, "/login", same_origin(Config), {form, []}),
    [SetCookie] = [V || {"set-cookie", V} <- H],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

cookie(Config) -> [{"cookie", "muse_session=" ++ ?config(cookie, Config)}].

page(Config, Path) ->
    {200, _, Html} = req(Config, get, Path, cookie(Config), undefined),
    Html.

%% The ops of an action call.
act(Config, Ref, Event) ->
    Body = muse_json:encode(#{<<"action">> => aihtml_action:token(Ref), <<"event">> => Event}),
    {200, _, Resp} = req(Config, post, "/aihtml/action", cookie(Config) ++ same_origin(Config),
                         {"application/json", Body}),
    lists:append([Ops || L <- binary:split(Resp, <<"\n">>, [global, trim_all]),
                         {ok, #{<<"ops">> := Ops}} <- [muse_json:decode(L)]]).

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

contains(B, Needle) when is_binary(B) -> has(B, Needle);
contains(L, Needle) when is_list(L) -> lists:any(fun(X) -> contains(X, Needle) end, L);
contains(M, Needle) when is_map(M) -> contains(maps:values(M), Needle);
contains(_, _) -> false.

op(Ops, Name) -> [O || O = #{<<"op">> := N} <- Ops, N =:= Name].

%% The calendar reloads its range after a change (a triggered `change`).
reloads(Ops) ->
    [#{<<"event">> := <<"change">>, <<"id">> := <<"cal">>}] = op(Ops, <<"trigger">>),
    true.

form(Fields) -> #{<<"type">> => <<"submit">>, <<"form">> => Fields}.

events() -> muse_store:list(?O, ?EVENTS).

new_event(Fields) ->
    {ok, E} = muse_calendar:create_event(?O, maps:merge(#{<<"title">> => <<"评审"/utf8>>}, Fields), <<"user">>),
    E.

%% Page

page_render(Config) ->
    #{<<"id">> := _} = new_event(#{<<"title">> => <<"Dentist visit">>, <<"start">> => <<"2030-01-08T10:00">>,
                                   <<"rrule">> => <<"weekly">>}),
    Html = page(Config, "/calendar?date=2030-01-07&view=week"),
    [?assert(has(Html, P), P)
     || P <- [<<"data-ah=\"calendar\"">>, <<"id=\"cal\"">>, <<"data-ah-value=\"2030-01-07\"">>, <<"data-view=\"week\"">>,
              <<"data-ah-first-day=\"1\"">>, <<"/calendar?date={date}&amp;view={view}">>,
              %% Chinese labels and the 24-hour clock
              <<"今天"/utf8>>, <<"列表"/utf8>>, <<"data-ah-hour-format=\"24\"">>,
              %% the events of the shown range, with their calendar colour and repeat
              <<"Dentist visit">>, <<"FREQ=WEEKLY">>, <<"#6366f1">>,
              %% rail: calendars and upcoming, live
              <<"我的日历"/utf8>>, <<"个人"/utf8>>, <<"工作"/utf8>>, <<"家庭"/utf8>>, <<"出行"/utf8>>,
              <<"接下来 30 天"/utf8>>, <<"id=\"cal-rail\"">>, <<"data-ah-subscribe">>,
              %% header button and the forms
              <<"新建日程"/utf8>>, <<"id=\"cal-event-window\"">>, <<"id=\"cal-cal-window\"">>,
              %% the sidebar entry
              <<"href=\"/calendar\"">>]],
    %% the toolbar links lead to the neighbouring weeks
    ?assert(has(Html, <<"/calendar?date=2030-01-14&amp;view=week">>)),
    %% bad query values fall back to today's month
    Today = page(Config, "/calendar?date=soon&view=year"),
    ?assert(has(Today, <<"data-ah-value=\"", (muse_calendar:today())/binary, "\"">>)),
    ?assert(has(Today, <<"data-view=\"month\"">>)),
    %% the upcoming list shows what comes in the next 30 days
    Tomorrow = muse_calendar:add_days(muse_calendar:today(), 1),
    new_event(#{<<"title">> => <<"Soon thing">>, <<"start">> => <<Tomorrow/binary, "T08:30">>}),
    Rail = page(Config, "/calendar"),
    ?assert(has(Rail, <<"明天"/utf8>>)),
    ?assert(has(Rail, <<"08:30 · Soon thing"/utf8>>)),
    %% other pages show the sidebar entry too
    ?assert(has(page(Config, "/activity"), <<"href=\"/calendar\"">>)).

create_through_form(Config) ->
    Open = act(Config, {muse_ui_calendar, new_event, #{}}, #{<<"type">> => <<"click">>}),
    ?assert(contains(Open, <<"cal-event-form">>)),
    ?assert(contains(Open, <<"创建"/utf8>>)),
    ?assert(contains(Open, <<"cal-event-window">>)),
    Save = act(Config, {muse_ui_calendar, save_event, #{id => new}},
               form(#{<<"title">> => <<"产品评审"/utf8>>, <<"calendar">> => <<"work">>,
                      <<"start">> => <<"2030-01-07 10:00">>, <<"end">> => <<"2030-01-07 11:30">>,
                      <<"location">> => <<"3 楼"/utf8>>, <<"notes">> => <<"带上数据\r\n第二行"/utf8>>,
                      <<"repeat">> => <<"weekly">>})),
    true = reloads(Save),
    ?assert(contains(Save, <<"日程已创建"/utf8>>)),
    [#{<<"title">> := <<"产品评审"/utf8>>, <<"calendarId">> := <<"work">>, <<"start">> := <<"2030-01-07T10:00">>,
       <<"end">> := <<"2030-01-07T11:30">>, <<"allDay">> := false, <<"location">> := <<"3 楼"/utf8>>,
       <<"notes">> := <<"带上数据\n第二行"/utf8>>, <<"rrule">> := <<"weekly">>, <<"createdBy">> := <<"user">>}] = events(),
    %% an all-day event: the form's end date is inclusive
    _ = act(Config, {muse_ui_calendar, save_event, #{id => new}},
            form(#{<<"title">> => <<"Trip">>, <<"calendar">> => <<"travel">>, <<"all_day">> => <<"true">>,
                   <<"start">> => <<"2030-02-01 09:00">>, <<"end">> => <<"2030-02-03 10:00">>, <<"repeat">> => <<"none">>})),
    [#{<<"allDay">> := true, <<"start">> := <<"2030-02-01">>, <<"end">> := <<"2030-02-04">>}] =
        [E || E = #{<<"title">> := <<"Trip">>} <- events()],
    %% invalid input: the error in the form, nothing saved
    Bad = act(Config, {muse_ui_calendar, save_event, #{id => new}},
              form(#{<<"title">> => <<>>, <<"calendar">> => <<"work">>, <<"start">> => <<"2030-01-07 10:00">>})),
    ?assert(contains(Bad, <<"cal-event-error">>)),
    ?assertEqual([], op(Bad, <<"trigger">>)),
    Backwards = act(Config, {muse_ui_calendar, save_event, #{id => new}},
                    form(#{<<"title">> => <<"x">>, <<"start">> => <<"2030-01-07 10:00">>,
                           <<"end">> => <<"2030-01-07 09:00">>})),
    ?assert(contains(Backwards, <<"结束时间必须晚于开始时间"/utf8>>)),
    ?assertEqual(2, length(events())).

lazy_load_on_change(Config) ->
    new_event(#{<<"title">> => <<"In January">>, <<"start">> => <<"2030-01-15T10:00">>}),
    new_event(#{<<"title">> => <<"In March">>, <<"start">> => <<"2030-03-15T10:00">>}),
    Change = fun(Start, End) ->
                     act(Config, {muse_ui_calendar, range, #{}},
                         #{<<"type">> => <<"change">>, <<"id">> => <<"cal">>, <<"value">> => Start,
                           <<"data">> => #{<<"view">> => <<"month">>, <<"start">> => Start, <<"end">> => End}})
             end,
    Jan = Change(<<"2029-12-30">>, <<"2030-02-03">>),
    [#{<<"id">> := <<"cal">>, <<"method">> := <<"setEvents">>, <<"args">> := [Events]}] = op(Jan, <<"call">>),
    ?assertEqual([<<"In January">>], [T || #{<<"title">> := T} <- Events]),
    [#{<<"start">> := <<"2030-01-15T10:00">>, <<"color">> := <<"#6366f1">>, <<"allDay">> := false}] = Events,
    [#{<<"args">> := [[#{<<"title">> := <<"In March">>}]]}] = op(Change(<<"2030-02-24">>, <<"2030-04-07">>), <<"call">>),
    %% a broken range loads nothing
    ?assertEqual([], op(Change(<<"later">>, <<"2030-04-07">>), <<"call">>)).

drag_and_resize(Config) ->
    #{<<"id">> := Id} = new_event(#{<<"start">> => <<"2030-01-07T10:00">>, <<"end">> => <<"2030-01-07T11:00">>}),
    Drop = act(Config, {muse_ui_calendar, move_event, #{}},
               #{<<"type">> => <<"ah:event-drop">>, <<"id">> => <<"cal">>,
                 <<"data">> => #{<<"event">> => Id, <<"from">> => <<"2030-01-09T14:00">>, <<"to">> => <<"2030-01-09T15:00">>,
                                 <<"allDay">> => <<"false">>, <<"days">> => <<"2">>}}),
    ?assertNot(contains(Drop, <<"操作失败"/utf8>>)),
    {ok, #{<<"start">> := <<"2030-01-09T14:00">>, <<"end">> := <<"2030-01-09T15:00">>}} = muse_calendar:get_event(?O, Id),
    _ = act(Config, {muse_ui_calendar, move_event, #{}},
            #{<<"type">> => <<"ah:event-resize">>,
              <<"data">> => #{<<"event">> => Id, <<"from">> => <<"2030-01-09T14:00">>, <<"to">> => <<"2030-01-09T16:30">>,
                              <<"allDay">> => <<"false">>}}),
    {ok, #{<<"end">> := <<"2030-01-09T16:30">>}} = muse_calendar:get_event(?O, Id),
    %% into the all-day row
    _ = act(Config, {muse_ui_calendar, move_event, #{}},
            #{<<"type">> => <<"ah:event-drop">>,
              <<"data">> => #{<<"event">> => Id, <<"from">> => <<"2030-01-10">>, <<"to">> => <<"2030-01-11">>,
                              <<"allDay">> => <<"true">>}}),
    {ok, #{<<"allDay">> := true, <<"start">> := <<"2030-01-10">>}} = muse_calendar:get_event(?O, Id),
    %% a refused move shows why and reloads the range (the event snaps back)
    Bad = act(Config, {muse_ui_calendar, move_event, #{}},
              #{<<"type">> => <<"ah:event-drop">>,
                <<"data">> => #{<<"event">> => <<"gone">>, <<"from">> => <<"2030-01-10">>, <<"to">> => <<"2030-01-11">>,
                                <<"allDay">> => <<"true">>}}),
    ?assert(contains(Bad, <<"找不到这个日程"/utf8>>)),
    true = reloads(Bad).

edit_and_delete(Config) ->
    #{<<"id">> := Id} = new_event(#{<<"title">> => <<"Standup">>, <<"start">> => <<"2030-01-07T09:00">>,
                                    <<"calendarId">> => <<"work">>, <<"location">> => <<"Room 4">>}),
    Open = act(Config, {muse_ui_calendar, edit_event, #{}},
               #{<<"type">> => <<"ah:event-click">>, <<"data">> => #{<<"event">> => Id}}),
    [?assert(contains(Open, P), P) || P <- [<<"Standup">>, <<"Room 4">>, <<"cal-event-delete">>, <<"编辑日程"/utf8>>,
                                            <<"2030-01-07T09:00">>, <<"保存"/utf8>>]],
    %% the delete button asks first, as a danger
    ?assert(contains(Open, <<"danger">>)),
    Saved = act(Config, {muse_ui_calendar, save_event, #{id => Id}},
                form(#{<<"title">> => <<"Daily standup">>, <<"calendar">> => <<"work">>,
                       <<"start">> => <<"2030-01-07 09:15">>, <<"end">> => <<"2030-01-07 09:30">>, <<"repeat">> => <<"daily">>,
                       <<"location">> => <<>>})),
    true = reloads(Saved),
    {ok, #{<<"title">> := <<"Daily standup">>, <<"start">> := <<"2030-01-07T09:15">>, <<"rrule">> := <<"daily">>,
           <<"location">> := <<>>}} = muse_calendar:get_event(?O, Id),
    Deleted = act(Config, {muse_ui_calendar, delete_event, #{id => Id}}, #{<<"type">> => <<"click">>}),
    true = reloads(Deleted),
    ?assert(contains(Deleted, <<"日程已删除"/utf8>>)),
    [] = events(),
    %% opening a deleted event says so
    Gone = act(Config, {muse_ui_calendar, edit_event, #{id => Id}}, #{<<"type">> => <<"click">>}),
    ?assert(contains(Gone, <<"找不到这个日程"/utf8>>)).

select_range(Config) ->
    Days = act(Config, {muse_ui_calendar, select, #{}},
               #{<<"type">> => <<"ah:select">>,
                 <<"data">> => #{<<"from">> => <<"2030-01-07">>, <<"to">> => <<"2030-01-10">>, <<"allDay">> => <<"true">>}}),
    %% all day, the end shown inclusive
    ?assert(contains(Days, <<"2030-01-07T09:00">>)),
    ?assert(contains(Days, <<"2030-01-09T10:00">>)),
    ?assert(contains(Days, <<"新建日程"/utf8>>)),
    Times = act(Config, {muse_ui_calendar, select, #{}},
                #{<<"type">> => <<"ah:select">>,
                  <<"data">> => #{<<"from">> => <<"2030-01-07T13:00">>, <<"to">> => <<"2030-01-07T14:30">>,
                                  <<"allDay">> => <<"false">>}}),
    ?assert(contains(Times, <<"2030-01-07T13:00">>)),
    ?assert(contains(Times, <<"2030-01-07T14:30">>)).

calendar_toggles(Config) ->
    new_event(#{<<"title">> => <<"Work thing">>, <<"start">> => <<"2030-01-07T09:00">>, <<"calendarId">> => <<"work">>}),
    Off = act(Config, {muse_ui_calendar, toggle_calendar, #{id => <<"work">>}},
              #{<<"type">> => <<"change">>, <<"checked">> => false}),
    true = reloads(Off),
    {ok, #{<<"visible">> := false}} = muse_calendar:get_calendar(?O, <<"work">>),
    ?assert(has(page(Config, "/calendar?date=2030-01-07"), <<"data-visible=\"false\"">>)),
    ?assertNot(has(page(Config, "/calendar?date=2030-01-07"), <<"Work thing">>)),
    [#{<<"args">> := [[]]}] = op(act(Config, {muse_ui_calendar, range, #{}},
                                     #{<<"type">> => <<"change">>,
                                       <<"data">> => #{<<"start">> => <<"2030-01-01">>, <<"end">> => <<"2030-02-01">>}}),
                                 <<"call">>),
    _ = act(Config, {muse_ui_calendar, toggle_calendar, #{id => <<"work">>}},
            #{<<"type">> => <<"change">>, <<"checked">> => true}),
    ?assert(has(page(Config, "/calendar?date=2030-01-07"), <<"Work thing">>)).

calendar_manage(Config) ->
    Open = act(Config, {muse_ui_calendar, new_calendar, #{}}, #{<<"type">> => <<"click">>}),
    ?assert(contains(Open, <<"添加日历"/utf8>>)),
    _ = act(Config, {muse_ui_calendar, save_calendar, #{id => new}},
            form(#{<<"name">> => <<"读书"/utf8>>, <<"color">> => <<"#ec4899">>})),
    [#{<<"id">> := Id, <<"color">> := <<"#ec4899">>}] =
        [C || C = #{<<"name">> := <<"读书"/utf8>>} <- muse_calendar:calendars(?O)],
    Bad = act(Config, {muse_ui_calendar, save_calendar, #{id => Id}}, form(#{<<"name">> => <<" ">>})),
    ?assert(contains(Bad, <<"cal-cal-error">>)),
    _ = act(Config, {muse_ui_calendar, save_calendar, #{id => Id}},
            form(#{<<"name">> => <<"阅读"/utf8>>, <<"color">> => <<"#14b8a6">>})),
    {ok, #{<<"name">> := <<"阅读"/utf8>>, <<"color">> := <<"#14b8a6">>}} = muse_calendar:get_calendar(?O, Id),
    %% deleting a calendar with events asks what to do with them
    new_event(#{<<"title">> => <<"Book club">>, <<"start">> => <<"2030-01-07">>, <<"calendarId">> => Id}),
    Edit = act(Config, {muse_ui_calendar, edit_calendar, #{id => Id}}, #{<<"type">> => <<"click">>}),
    [?assert(contains(Edit, P), P) || P <- [<<"cal-cal-delete">>, <<"这个日历里有 1 个日程"/utf8>>, <<"一并删除这些日程"/utf8>>,
                                            <<"danger">>]],
    _ = act(Config, {muse_ui_calendar, delete_calendar, #{id => Id}},
            #{<<"type">> => <<"click">>, <<"form">> => #{<<"events">> => <<"move">>, <<"move_to">> => <<"family">>}}),
    {error, {404, _}} = muse_calendar:get_calendar(?O, Id),
    [#{<<"calendarId">> := <<"family">>}] = events(),
    _ = act(Config, {muse_ui_calendar, delete_calendar, #{id => <<"family">>}},
            #{<<"type">> => <<"click">>, <<"form">> => #{<<"events">> => <<"delete">>}}),
    [] = events(),
    %% the rail follows
    ?assertNot(has(page(Config, "/calendar"), <<"cal-row-family">>)).

%% A change the chat agent proposed: the approval card in the chat (with the
%% tool call's `tc-` id), approving from the chat, and the same review on
%% 审批 (`/approvals`).
chat_proposal_card(Config) ->
    #{<<"id">> := Id} = new_event(#{<<"title">> => <<"Dentist">>, <<"start">> => <<"2030-01-07T10:00">>}),
    Tools = muse_chat_agent:tools(?O, <<"t1">>, <<"r">>, <<"t1:m1">>, undefined),
    [#{handler := H}] = [T || T = #{name := <<"propose_calendar_change">>} <- Tools],
    Args = #{<<"operation">> => <<"update">>, <<"eventId">> => Id, <<"start">> => <<"2030-01-08T15:00">>},
    {ok, #{<<"actionId">> := AId, <<"status">> := <<"awaiting_review">>} = Result} = H(Args, undefined),
    Card = iolist_to_binary(aihtml_html:render(
                              muse_ui_cards:render(?O, <<"t1">>, <<"call-9">>, <<"propose_calendar_change">>, Args,
                                                   muse_json:encode(Result)))),
    [?assert(has(Card, P), P) || P <- [<<"id=\"tc-call-9\"">>, <<"approval-", AId/binary>>, <<"修改日程：Dentist"/utf8>>,
                                       <<"原时间"/utf8>>, <<"批准"/utf8>>, <<"拒绝"/utf8>>, <<"data-ah-subscribe">>]],
    %% 审批 lists it and the sidebar counts it; 任务 only links there
    Approvals = page(Config, "/approvals"),
    ?assert(has(Approvals, <<"approval-", AId/binary>>)),
    ?assertEqual(match, re:run(Approvals, <<"<span[^>]*muse-approval-count[^>]*>1</span>">>, [{capture, none}])),
    Activity = page(Config, "/activity"),
    ?assertNot(has(Activity, <<"approval-", AId/binary>>)),
    ?assert(has(Activity, <<"1 项等待你审批"/utf8>>)),
    ?assert(has(Activity, <<"href=\"/approvals\"">>)),
    %% approve from the chat card: the card re-renders in place with the receipt
    #{<<"hash">> := Hash} = muse_actions:get(?O, AId),
    Approved = act(Config, {muse_ui_activity, decide, #{action => AId, hash => Hash, decision => approve, scope => chat}},
                   #{<<"type">> => <<"click">>}),
    ?assert(contains(Approved, <<"approval-", AId/binary>>)),
    ?assert(contains(Approved, <<"已修改日程「Dentist」"/utf8>>)),
    ?assert(contains(Approved, <<"/calendar?date=2030-01-08&amp;view=week">>)),
    {ok, #{<<"start">> := <<"2030-01-08T15:00">>}} = muse_calendar:get_event(?O, Id),
    %% a second proposal, declined on 审批: the page re-renders, and the
    %% decided reviews are listed under 已处理
    {ok, #{<<"actionId">> := A2}} = H(Args#{<<"title">> => <<"Other">>}, undefined),
    #{<<"hash">> := H2} = muse_actions:get(?O, A2),
    Denied = act(Config, {muse_ui_activity, decide, #{action => A2, hash => H2, decision => deny, scope => approvals}},
                 #{<<"type">> => <<"click">>}),
    ?assert(contains(Denied, <<"approvals-body">>)),
    ?assert(contains(Denied, <<"没有等待审批的事项"/utf8>>)),
    History = page(Config, "/approvals"),
    ?assert(has(History, <<"approval-row-", AId/binary>>)),
    ?assert(has(History, <<"approval-row-", A2/binary>>)),
    ?assert(has(History, <<"已处理"/utf8>>)),
    #{<<"status">> := <<"denied">>} = muse_actions:get(?O, A2),
    {ok, #{<<"title">> := <<"Dentist">>}} = muse_calendar:get_event(?O, Id),
    %% a failed proposal is a failed step
    Failed = iolist_to_binary(aihtml_html:render(
                                muse_ui_cards:render(?O, <<"t1">>, <<"call-10">>, <<"propose_calendar_change">>, Args,
                                                     muse_json:encode(#{<<"error">> => <<"找不到这个日程"/utf8>>})))),
    ?assert(has(Failed, <<"没能准备日程更改"/utf8>>)),
    %% the read step: one line with the range and the count
    {ok, Read} = muse_calendar:read(?O, #{<<"from">> => <<"2030-01-08">>, <<"to">> => <<"2030-01-08">>}),
    ReadCard = iolist_to_binary(aihtml_html:render(
                                  muse_ui_cards:render(?O, <<"t1">>, <<"call-11">>, <<"read_calendar">>, #{},
                                                       muse_json:encode(Read)))),
    ?assert(has(ReadCard, <<"查看了日程 · 2030-01-08 · 1 项"/utf8>>)).

%% JSON API

api_routes(Config) ->
    Env = ?config(env, Config),
    T = muse_web_test_env:login(Env),
    H = fun(M, P, B) -> muse_web_test_env:http(Env, M, P, T, B) end,
    401 = element(1, muse_web_test_env:http(Env, get, "/api/calendars", undefined)),
    {200, #{<<"calendars">> := [#{<<"id">> := <<"personal">>, <<"name">> := <<"个人"/utf8>>} | _],
            <<"timeZone">> := Zone}} = H(get, "/api/calendars", undefined),
    ?assert(is_binary(Zone)),
    {201, #{<<"id">> := Id, <<"createdBy">> := <<"user">>, <<"end">> := <<"2030-01-07T11:00">>}} =
        H(post, "/api/calendar/events", #{<<"title">> => <<"API event">>, <<"start">> => <<"2030-01-07T10:00">>,
                                          <<"rrule">> => <<"daily">>}),
    422 = element(1, H(post, "/api/calendar/events", #{<<"title">> => <<"x">>, <<"start">> => <<"later">>})),
    {200, #{<<"events">> := Occ, <<"from">> := <<"2030-01-07">>}} =
        H(get, "/api/calendar/events?from=2030-01-07&to=2030-01-10", undefined),
    ?assertEqual([<<"2030-01-07T10:00">>, <<"2030-01-08T10:00">>, <<"2030-01-09T10:00">>],
                 [S || #{<<"eventId">> := I, <<"start">> := S} <- Occ, I =:= Id]),
    ?assertMatch([#{<<"calendar">> := <<"个人"/utf8>>, <<"recurring">> := true, <<"repeat">> := <<"daily">>} | _], Occ),
    [422 = element(1, H(get, P, undefined)) || P <- ["/api/calendar/events", "/api/calendar/events?from=2030-01-07",
                                             "/api/calendar/events?from=2030-01-07&to=2030-01-07",
                                             "/api/calendar/events?from=2030-01-01&to=2032-01-01"]],
    {200, #{<<"title">> := <<"Renamed">>, <<"end">> := <<"2030-01-07T11:00">>}} =
        H(post, "/api/calendar/events/" ++ binary_to_list(Id), #{<<"title">> => <<"Renamed">>}),
    404 = element(1, H(post, "/api/calendar/events/nope", #{<<"title">> => <<"x">>})),
    {200, #{<<"ok">> := true}} = H(delete, "/api/calendar/events/" ++ binary_to_list(Id), undefined),
    404 = element(1, H(delete, "/api/calendar/events/" ++ binary_to_list(Id), undefined)),
    {200, #{<<"events">> := []}} = H(get, "/api/calendar/events?from=2030-01-07&to=2030-01-10", undefined).
