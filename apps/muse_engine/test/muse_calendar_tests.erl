%% The built-in calendar (muse_calendar) and its reviewed agent writes
%% (muse_calendar_action, `calendar.event`), on Mnesia in RAM.
-module(muse_calendar_tests).
-include_lib("eunit/include/eunit.hrl").

-define(EVENTS, <<"calendar-events">>).

calendar_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     {foreach, fun each/0, fun after_each/1,
      [{"seeded calendars, once", fun seeding/0},
       {"calendar add, rename, recolour, hide", fun calendar_crud/0},
       {"calendar delete: refuse, move, delete, last one", fun calendar_delete/0},
       {"event create and time rules", fun event_rules/0},
       {"local times only", fun time_parsing/0},
       {"update keeps duration, versions move forward", fun event_update/0},
       {"stale versions are refused", fun event_stale/0},
       {"ranges, visibility and query", fun ranges/0},
       {"recurrence", fun recurrence/0},
       {"read tool", fun read_tool/0},
       {"words", fun words/0},
       {"action: create through review", fun action_create/0},
       {"action: update and delete display the target", fun action_update_delete/0},
       {"action: stale target is refused", fun action_stale/0},
       {"action: ownership", fun action_ownership/0},
       {"action: task-model tool", fun action_tool/0}]}}.

setup() ->
    ok = muse_store:init(#{storage => ram}),
    ok.

cleanup(_) ->
    muse_store:stop().

each() ->
    ok = muse_calendar_action:register().

after_each(_) ->
    muse_time:set_offset(0),
    ok = muse_calendar_action:unregister().

owner() ->
    <<"user-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

ok({ok, V}) -> V.

event(O, Fields) ->
    ok(muse_calendar:create_event(O, maps:merge(#{<<"title">> => <<"评审"/utf8>>}, Fields), <<"user">>)).

%% Calendars

seeding() ->
    O = owner(),
    Cals = muse_calendar:calendars(O),
    ?assertEqual([<<"personal">>, <<"work">>, <<"family">>, <<"travel">>], [I || #{<<"id">> := I} <- Cals]),
    ?assertEqual([<<"个人"/utf8>>, <<"工作"/utf8>>, <<"家庭"/utf8>>, <<"出行"/utf8>>], [N || #{<<"name">> := N} <- Cals]),
    ?assertEqual([<<"#6366f1">>, <<"#0ea5e9">>, <<"#f59e0b">>, <<"#22c55e">>], [C || #{<<"color">> := C} <- Cals]),
    ?assert(lists:all(fun(#{<<"visible">> := V}) -> V end, Cals)),
    %% deleted defaults do not come back
    ok = muse_calendar:delete_calendar(O, <<"travel">>, undefined),
    ?assertEqual(3, length(muse_calendar:calendars(O))),
    ?assertEqual(3, length(muse_calendar:calendars(O))).

calendar_crud() ->
    O = owner(),
    #{<<"id">> := Id, <<"color">> := Color, <<"visible">> := true} =
        ok(muse_calendar:create_calendar(O, #{<<"name">> => <<"  读书  "/utf8>>})),
    ?assertEqual(lists:nth(5, muse_calendar:palette()), Color),
    ?assertEqual(<<"读书"/utf8>>, lists:last([N || #{<<"name">> := N} <- muse_calendar:calendars(O)])),
    ?assertMatch({ok, #{<<"name">> := <<"阅读"/utf8>>, <<"color">> := <<"#abcdef">>}},
                 muse_calendar:update_calendar(O, Id, #{<<"name">> => <<"阅读"/utf8>>, <<"color">> => <<"#ABCDEF">>})),
    ?assertMatch({error, {422, _}}, muse_calendar:update_calendar(O, Id, #{<<"color">> => <<"red;x">>})),
    ?assertMatch({error, {422, _}}, muse_calendar:create_calendar(O, #{<<"name">> => <<"  ">>})),
    ?assertMatch({ok, #{<<"visible">> := false}}, muse_calendar:set_visible(O, Id, false)),
    ?assertMatch({error, {404, _}}, muse_calendar:update_calendar(O, <<"nope">>, #{<<"name">> => <<"x">>})),
    %% another owner's calendar is not found
    ?assertMatch({error, {404, _}}, muse_calendar:get_calendar(owner(), Id)).

calendar_delete() ->
    O = owner(),
    #{<<"id">> := E1} = event(O, #{<<"calendarId">> => <<"work">>, <<"start">> => <<"2026-11-02T10:00">>}),
    #{<<"id">> := E2} = event(O, #{<<"calendarId">> => <<"work">>, <<"start">> => <<"2026-11-03">>}),
    ?assertEqual(2, muse_calendar:count_events(O, <<"work">>)),
    ?assertMatch({error, {409, <<"这个日历里还有 2 个日程"/utf8, _/binary>>}},
                 muse_calendar:delete_calendar(O, <<"work">>, undefined)),
    ?assertMatch({error, {422, _}}, muse_calendar:delete_calendar(O, <<"work">>, {move, <<"work">>})),
    ok = muse_calendar:delete_calendar(O, <<"work">>, {move, <<"family">>}),
    ?assertMatch({ok, #{<<"calendarId">> := <<"family">>}}, muse_calendar:get_event(O, E1)),
    ?assertMatch({ok, #{<<"calendarId">> := <<"family">>}}, muse_calendar:get_event(O, E2)),
    ok = muse_calendar:delete_calendar(O, <<"family">>, delete),
    ?assertMatch({error, {404, _}}, muse_calendar:get_event(O, E1)),
    ok = muse_calendar:delete_calendar(O, <<"travel">>, undefined),
    ?assertEqual({error, {409, <<"至少要保留一个日历"/utf8>>}}, muse_calendar:delete_calendar(O, <<"personal">>, delete)).

%% Events

event_rules() ->
    O = owner(),
    %% defaults: first visible calendar, one hour, confirmed, no repeat
    E = event(O, #{<<"start">> => <<"2026-11-02T10:00">>}),
    ?assertMatch(#{<<"calendarId">> := <<"personal">>, <<"end">> := <<"2026-11-02T11:00">>, <<"allDay">> := false,
                   <<"status">> := <<"confirmed">>, <<"location">> := <<>>, <<"notes">> := <<>>,
                   <<"createdBy">> := <<"user">>}, E),
    ?assertNot(maps:is_key(<<"rrule">>, E)),
    ?assertEqual(maps:get(<<"createdAt">>, E), maps:get(<<"updatedAt">>, E)),
    %% a date-only start is all day; the end is exclusive
    ?assertMatch(#{<<"allDay">> := true, <<"start">> := <<"2026-11-07">>, <<"end">> := <<"2026-11-08">>},
                 event(O, #{<<"start">> => <<"2026-11-07">>})),
    ?assertMatch(#{<<"allDay">> := true, <<"start">> := <<"2026-11-07">>, <<"end">> := <<"2026-11-09">>},
                 event(O, #{<<"start">> => <<"2026-11-07T09:00">>, <<"end">> => <<"2026-11-08T00:00">>,
                            <<"allDay">> => true})),
    %% an all-day end on the start day means that day
    ?assertMatch(#{<<"end">> := <<"2026-11-08">>}, event(O, #{<<"start">> => <<"2026-11-07">>, <<"end">> => <<"2026-11-07">>})),
    ?assertMatch(#{<<"rrule">> := <<"weekly">>}, event(O, #{<<"start">> => <<"2026-11-02T10:00">>, <<"rrule">> => <<"weekly">>})),
    ?assertEqual({error, {422, <<"结束时间必须晚于开始时间"/utf8>>}},
                 muse_calendar:create_event(O, #{<<"title">> => <<"x">>, <<"start">> => <<"2026-11-02T10:00">>,
                                                 <<"end">> => <<"2026-11-02T09:00">>}, <<"user">>)),
    ?assertMatch({error, {422, _}}, muse_calendar:create_event(O, #{<<"title">> => <<"x">>, <<"start">> => <<"2026-11-02T10:00">>,
                                                                    <<"end">> => <<"2026-11-03">>}, <<"user">>)),
    ?assertMatch({error, {422, _}}, muse_calendar:create_event(O, #{<<"title">> => <<" ">>, <<"start">> => <<"2026-11-02">>},
                                                               <<"user">>)),
    ?assertMatch({error, {422, _}}, muse_calendar:create_event(O, #{<<"title">> => <<"x">>, <<"start">> => <<"2026-11-02">>,
                                                                    <<"rrule">> => <<"hourly">>}, <<"user">>)),
    ?assertMatch({error, {422, <<"一个日程最长 366 天"/utf8>>}},
                 muse_calendar:create_event(O, #{<<"title">> => <<"x">>, <<"start">> => <<"2026-01-01">>,
                                                 <<"end">> => <<"2028-01-01">>}, <<"user">>)),
    ?assertMatch({error, {404, _}}, muse_calendar:create_event(O, #{<<"title">> => <<"x">>, <<"start">> => <<"2026-11-02">>,
                                                                    <<"calendarId">> => <<"nope">>}, <<"user">>)).

time_parsing() ->
    ?assertMatch({date, _}, muse_calendar:parse_time(<<"2026-10-26">>)),
    ?assertMatch({datetime, _}, muse_calendar:parse_time(<<"2026-10-26T10:00">>)),
    ?assertEqual(muse_calendar:parse_time(<<"2026-10-26T10:00">>), muse_calendar:parse_time(<<"2026-10-26 10:00:59">>)),
    ?assertEqual(<<"Use local time without a zone, e.g. 2026-10-26T10:00">>,
                 element(2, muse_calendar:parse_time(<<"2026-10-26T10:00:00Z">>))),
    ?assertMatch({error, <<"Use local", _/binary>>}, muse_calendar:parse_time(<<"2026-10-26T10:00+08:00">>)),
    ?assertMatch({error, _}, muse_calendar:parse_time(<<"2026-02-30">>)),
    ?assertMatch({error, _}, muse_calendar:parse_time(<<"2026-10-26T24:00">>)),
    ?assertMatch({error, _}, muse_calendar:parse_time(undefined)),
    {_, M} = muse_calendar:parse_time(<<"2026-10-26T10:05">>),
    ?assertEqual(<<"2026-10-26T10:05">>, muse_calendar:format_time(M, false)),
    ?assertEqual(<<"2026-10-26">>, muse_calendar:format_time(M, true)),
    ?assertEqual(<<"2026-11-01">>, muse_calendar:add_days(<<"2026-10-26">>, 6)),
    ?assertMatch({date, _}, muse_calendar:parse_time(muse_calendar:today())).

event_update() ->
    O = owner(),
    #{<<"id">> := Id, <<"updatedAt">> := V0} = event(O, #{<<"start">> => <<"2026-11-02T10:00">>, <<"end">> => <<"2026-11-02T11:30">>,
                                                          <<"rrule">> => <<"daily">>}),
    %% a new start keeps the duration
    #{<<"updatedAt">> := V1} = U1 = ok(muse_calendar:update_event(O, Id, #{<<"start">> => <<"2026-11-03T14:00">>}, #{})),
    ?assertMatch(#{<<"start">> := <<"2026-11-03T14:00">>, <<"end">> := <<"2026-11-03T15:30">>, <<"rrule">> := <<"daily">>}, U1),
    ?assert(V1 > V0),
    %% at the same instant the version still moves forward
    #{<<"updatedAt">> := V2} = U2 = ok(muse_calendar:update_event(O, Id, #{<<"rrule">> => <<"none">>,
                                                                           <<"title">> => <<"新标题"/utf8>>}, #{})),
    ?assert(V2 > V1),
    ?assertNot(maps:is_key(<<"rrule">>, U2)),
    ?assertMatch(#{<<"title">> := <<"新标题"/utf8>>, <<"createdBy">> := <<"user">>}, U2),
    %% to all day and back
    ?assertMatch({ok, #{<<"allDay">> := true, <<"start">> := <<"2026-11-05">>, <<"end">> := <<"2026-11-06">>}},
                 muse_calendar:update_event(O, Id, #{<<"start">> => <<"2026-11-05">>, <<"end">> => <<"2026-11-06">>,
                                                     <<"allDay">> => true}, #{})),
    ?assertMatch({ok, #{<<"allDay">> := false, <<"start">> := <<"2026-11-05T08:00">>}},
                 muse_calendar:update_event(O, Id, #{<<"start">> => <<"2026-11-05T08:00">>, <<"end">> => <<"2026-11-05T09:00">>,
                                                     <<"allDay">> => false}, #{})),
    ?assertMatch({error, {422, _}}, muse_calendar:update_event(O, Id, #{<<"end">> => <<"2026-11-05T07:00">>}, #{})),
    ?assertMatch({error, {404, _}}, muse_calendar:update_event(owner(), Id, #{<<"title">> => <<"x">>}, #{})),
    ok = muse_calendar:delete_event(O, Id, #{}),
    ?assertMatch({error, {404, _}}, muse_calendar:delete_event(O, Id, #{})).

event_stale() ->
    O = owner(),
    #{<<"id">> := Id, <<"updatedAt">> := V0} = event(O, #{<<"start">> => <<"2026-11-02T10:00">>}),
    {ok, _} = muse_calendar:update_event(O, Id, #{<<"title">> => <<"changed">>}, #{expect => V0}),
    ?assertMatch({error, {409, _}}, muse_calendar:update_event(O, Id, #{<<"title">> => <<"again">>}, #{expect => V0})),
    ?assertMatch({error, {409, _}}, muse_calendar:delete_event(O, Id, #{expect => V0})),
    ?assertMatch({ok, #{<<"title">> := <<"changed">>}}, muse_calendar:get_event(O, Id)).

ranges() ->
    O = owner(),
    #{<<"id">> := A} = event(O, #{<<"title">> => <<"Standup">>, <<"start">> => <<"2026-11-02T09:00">>,
                                  <<"calendarId">> => <<"work">>, <<"location">> => <<"Room 4">>}),
    #{<<"id">> := B} = event(O, #{<<"title">> => <<"Trip">>, <<"start">> => <<"2026-10-31">>, <<"end">> => <<"2026-11-03">>,
                                  <<"calendarId">> => <<"travel">>}),
    #{<<"id">> := _C} = event(O, #{<<"title">> => <<"Later">>, <<"start">> => <<"2026-12-01T09:00">>}),
    In = fun(F, T, Opts) -> [maps:get(<<"eventId">>, I) || I <- muse_calendar:occurrences(O, F, T, Opts)] end,
    ?assertEqual([B, A], In(<<"2026-11-02">>, <<"2026-11-03">>, #{})),
    ?assertEqual([B], In(<<"2026-11-01">>, <<"2026-11-02">>, #{})),
    ?assertEqual([], In(<<"2026-11-03">>, <<"2026-11-04">>, #{})),
    [#{<<"calendarName">> := <<"工作"/utf8>>, <<"color">> := <<"#0ea5e9">>}] =
        muse_calendar:occurrences(O, <<"2026-11-02T08:00">>, <<"2026-11-02T10:00">>, #{query => <<"room">>}),
    {ok, _} = muse_calendar:set_visible(O, <<"travel">>, false),
    ?assertEqual([A], In(<<"2026-11-02">>, <<"2026-11-03">>, #{visible_only => true})),
    ?assertEqual([A], [I || #{<<"id">> := I} <- muse_calendar:events_between(O, <<"2026-11-02">>, <<"2026-11-03">>,
                                                                             #{visible_only => true})]).

recurrence() ->
    O = owner(),
    Starts = fun(Fields, F, T) ->
                     #{<<"id">> := Id} = event(O, Fields),
                     R = [S || #{<<"eventId">> := I, <<"start">> := S} <- muse_calendar:occurrences(O, F, T, #{}), I =:= Id],
                     ok = muse_calendar:delete_event(O, Id, #{}),
                     R
             end,
    ?assertEqual([<<"2026-11-04T09:00">>, <<"2026-11-05T09:00">>],
                 Starts(#{<<"start">> => <<"2026-11-02T09:00">>, <<"rrule">> => <<"daily">>},
                        <<"2026-11-04">>, <<"2026-11-06">>)),
    ?assertEqual([<<"2026-11-09T09:00">>, <<"2026-11-16T09:00">>],
                 Starts(#{<<"start">> => <<"2026-11-02T09:00">>, <<"rrule">> => <<"weekly">>},
                        <<"2026-11-03">>, <<"2026-11-17">>)),
    %% the 31st skips shorter months
    ?assertEqual([<<"2027-01-31">>, <<"2027-03-31">>, <<"2027-05-31">>],
                 Starts(#{<<"start">> => <<"2026-10-31">>, <<"rrule">> => <<"monthly">>},
                        <<"2027-01-01">>, <<"2027-06-30">>)),
    ?assertEqual([<<"2028-02-29">>],
                 Starts(#{<<"start">> => <<"2024-02-29">>, <<"rrule">> => <<"yearly">>},
                        <<"2025-01-01">>, <<"2029-01-01">>)),
    %% an occurrence that started before the range but still runs counts
    ?assertEqual([<<"2026-11-03T23:00">>],
                 Starts(#{<<"start">> => <<"2026-11-02T23:00">>, <<"end">> => <<"2026-11-03T01:00">>,
                          <<"rrule">> => <<"daily">>}, <<"2026-11-04T00:30">>, <<"2026-11-04T01:00">>)),
    %% nothing before the first occurrence
    ?assertEqual([], Starts(#{<<"start">> => <<"2026-11-02T09:00">>, <<"rrule">> => <<"daily">>},
                            <<"2026-10-01">>, <<"2026-11-01">>)).

read_tool() ->
    O = owner(),
    Today = muse_calendar:today(),
    Tomorrow = muse_calendar:add_days(Today, 1),
    #{<<"id">> := Id} = event(O, #{<<"title">> => <<"牙医"/utf8>>, <<"start">> => <<Tomorrow/binary, "T10:00">>,
                                   <<"location">> => <<"诊所"/utf8>>, <<"calendarId">> => <<"family">>}),
    _ = event(O, #{<<"title">> => <<"Far">>, <<"start">> => muse_calendar:add_days(Today, 30)}),
    {ok, R} = muse_calendar:read(O, #{}),
    ?assertMatch(#{<<"today">> := Today, <<"from">> := Today, <<"truncated">> := false,
                   <<"recentChanges">> := [], <<"calendars">> := [_, _, _, _]}, R),
    ?assertEqual(muse_calendar:add_days(Today, 6), maps:get(<<"to">>, R)),
    ?assert(is_binary(maps:get(<<"timeZone">>, R))),
    [#{<<"eventId">> := Id, <<"title">> := <<"牙医"/utf8>>, <<"calendar">> := <<"家庭"/utf8>>, <<"repeat">> := <<"none">>,
       <<"start">> := <<_:10/binary, "T10:00">>, <<"location">> := <<"诊所"/utf8>>}] = maps:get(<<"events">>, R),
    {ok, #{<<"events">> := []}} = muse_calendar:read(O, #{<<"from">> => Tomorrow, <<"to">> => Tomorrow,
                                                          <<"query">> => <<"nothing">>}),
    {ok, #{<<"events">> := [_]}} = muse_calendar:read(O, #{<<"from">> => Tomorrow, <<"to">> => Tomorrow,
                                                           <<"query">> => <<"牙"/utf8>>}),
    ?assertMatch({error, {422, _}}, muse_calendar:read(O, #{<<"from">> => Tomorrow, <<"to">> => Today})),
    ?assertMatch({error, {422, _}}, muse_calendar:read(O, #{<<"from">> => <<"2026-01-01">>, <<"to">> => <<"2028-01-01">>})),
    ?assertMatch({error, {422, _}}, muse_calendar:read(O, #{<<"from">> => <<"tomorrow">>})),
    %% proposals of the last day are reported with their status
    {ok, #{<<"id">> := AId}} = propose(O, #{<<"operation">> => <<"create">>, <<"title">> => <<"Gym">>,
                                            <<"start">> => <<Tomorrow/binary, "T18:00">>}),
    {ok, #{<<"recentChanges">> := [#{<<"actionId">> := AId, <<"status">> := <<"awaiting_review">>,
                                     <<"title">> := <<"新建日程：Gym"/utf8>>}]}} = muse_calendar:read(O, #{}).

words() ->
    ?assertEqual(<<"2030年1月7日（周一） 10:00–11:30"/utf8>>,
                 muse_calendar:describe_time(#{<<"start">> => <<"2030-01-07T10:00">>, <<"end">> => <<"2030-01-07T11:30">>})),
    ?assertEqual(<<"2030年1月7日（周一） 全天，每周重复"/utf8>>,
                 muse_calendar:describe_time(#{<<"start">> => <<"2030-01-07">>, <<"end">> => <<"2030-01-08">>,
                                               <<"allDay">> => true, <<"rrule">> => <<"weekly">>})),
    ?assertEqual(<<"2030年1月7日（周一）–2030年1月9日（周三） 全天"/utf8>>,
                 muse_calendar:describe_time(#{<<"start">> => <<"2030-01-07">>, <<"end">> => <<"2030-01-10">>,
                                               <<"allDay">> => true})),
    ?assertEqual(<<"FREQ=MONTHLY">>, muse_calendar:rrule_freq(<<"monthly">>)),
    ?assertEqual(undefined, muse_calendar:rrule_freq(<<"none">>)).

%% calendar.event

propose(O, Data) ->
    muse_actions:propose(O, #{<<"kind">> => <<"calendar.event">>, <<"data">> => Data}, undefined, undefined).

action_create() ->
    O = owner(),
    {ok, #{<<"id">> := AId, <<"hash">> := H, <<"status">> := <<"awaiting_review">>, <<"data">> := Data} = P} =
        propose(O, #{<<"operation">> => <<"create">>, <<"title">> => <<"产品评审"/utf8>>,
                     <<"start">> => <<"2030-01-07T10:00">>, <<"calendarId">> => <<"work">>,
                     <<"location">> => <<"3 楼"/utf8>>, <<"rrule">> => <<"weekly">>,
                     %% display-only fields from the caller are replaced
                     <<"calendarName">> => <<"Fake">>}),
    %% prepared in full: defaults and the calendar's name
    ?assertMatch(#{<<"end">> := <<"2030-01-07T11:00">>, <<"allDay">> := false, <<"calendarName">> := <<"工作"/utf8>>,
                   <<"status">> := <<"confirmed">>, <<"notes">> := <<>>}, Data),
    ?assertNot(maps:is_key(<<"target">>, P)),
    #{title := Title, fields := Fields} = muse_actions:display(P),
    ?assertEqual(<<"新建日程：产品评审"/utf8>>, Title),
    ?assertEqual(Title, maps:get(<<"title">>, P)),
    ?assertEqual([{<<"时间"/utf8>>, <<"2030年1月7日（周一） 10:00–11:00，每周重复"/utf8>>},
                  {<<"日历"/utf8>>, <<"工作"/utf8>>}, {<<"地点"/utf8>>, <<"3 楼"/utf8>>},
                  {<<"重复"/utf8>>, <<"每周重复"/utf8>>}, {<<"状态"/utf8>>, <<>>}, {<<"备注"/utf8>>, <<>>}], Fields),
    %% nothing is written before approval
    [] = muse_store:list(O, ?EVENTS),
    {ok, #{<<"status">> := <<"succeeded">>, <<"result">> := Receipt}} = muse_actions:decide(O, AId, H, approve),
    ?assertMatch(<<"已新建日程「产品评审」 · "/utf8, _/binary>>, Receipt),
    [#{<<"createdBy">> := <<"agent">>, <<"calendarId">> := <<"work">>, <<"rrule">> := <<"weekly">>,
       <<"location">> := <<"3 楼"/utf8>>}] = muse_store:list(O, ?EVENTS),
    %% denied: nothing written
    {ok, #{<<"id">> := A2, <<"hash">> := H2}} = propose(O, #{<<"operation">> => <<"create">>, <<"title">> => <<"x">>,
                                                             <<"start">> => <<"2030-01-08">>}),
    {ok, #{<<"status">> := <<"denied">>}} = muse_actions:decide(O, A2, H2, deny),
    ?assertEqual(1, length(muse_store:list(O, ?EVENTS))),
    %% invalid input never becomes a proposal
    ?assertMatch({error, {422, _}}, propose(O, #{<<"operation">> => <<"create">>, <<"title">> => <<"x">>,
                                                 <<"start">> => <<"2030-01-08T10:00Z">>})),
    ?assertMatch({error, {422, _}}, propose(O, #{<<"operation">> => <<"create">>, <<"start">> => <<"2030-01-08">>})).

action_update_delete() ->
    O = owner(),
    #{<<"id">> := Id, <<"updatedAt">> := V} =
        event(O, #{<<"title">> => <<"牙医"/utf8>>, <<"start">> => <<"2030-01-07T10:00">>, <<"calendarId">> => <<"family">>}),
    {ok, #{<<"id">> := AId, <<"hash">> := H, <<"target">> := #{<<"id">> := Id}, <<"targetVersion">> := V,
           <<"data">> := Data} = P} =
        propose(O, #{<<"operation">> => <<"update">>, <<"eventId">> => Id, <<"start">> => <<"2030-01-08T15:00">>}),
    %% the whole event after the change, and what it was
    ?assertMatch(#{<<"title">> := <<"牙医"/utf8>>, <<"start">> := <<"2030-01-08T15:00">>, <<"end">> := <<"2030-01-08T16:00">>,
                   <<"previous">> := #{<<"start">> := <<"2030-01-07T10:00">>, <<"calendarName">> := <<"家庭"/utf8>>}},
                 Data),
    #{title := <<"修改日程：牙医"/utf8>>, fields := Fields} = muse_actions:display(P),
    ?assertEqual({<<"时间"/utf8>>, <<"2030年1月8日（周二） 15:00–16:00"/utf8>>}, hd(Fields)),
    ?assert(lists:member({<<"原时间"/utf8>>, <<"2030年1月7日（周一） 10:00–11:00"/utf8>>}, Fields)),
    ?assertNot(lists:keymember(<<"原标题"/utf8>>, 1, Fields)),
    {ok, #{<<"status">> := <<"succeeded">>, <<"result">> := <<"已修改日程「牙医」 · "/utf8, _/binary>>}} =
        muse_actions:decide(O, AId, H, approve),
    {ok, #{<<"start">> := <<"2030-01-08T15:00">>, <<"createdBy">> := <<"user">>, <<"updatedAt">> := V2}} =
        muse_calendar:get_event(O, Id),
    %% delete
    {ok, #{<<"id">> := D, <<"hash">> := DH, <<"targetVersion">> := V2} = DP} =
        propose(O, #{<<"operation">> => <<"delete">>, <<"eventId">> => Id}),
    ?assertMatch(#{title := <<"删除日程：牙医"/utf8>>,
                   fields := [{<<"时间"/utf8>>, <<"2030年1月8日（周二） 15:00–16:00"/utf8>>}, {<<"日历"/utf8>>, <<"家庭"/utf8>>} | _]},
                 muse_actions:display(DP)),
    {ok, #{<<"status">> := <<"succeeded">>, <<"result">> := <<"已删除日程「牙医」 · "/utf8, _/binary>>}} =
        muse_actions:decide(O, D, DH, approve),
    ?assertMatch({error, {404, _}}, muse_calendar:get_event(O, Id)).

action_stale() ->
    O = owner(),
    #{<<"id">> := Id} = event(O, #{<<"start">> => <<"2030-01-07T10:00">>}),
    {ok, #{<<"id">> := AId, <<"hash">> := H}} =
        propose(O, #{<<"operation">> => <<"update">>, <<"eventId">> => Id, <<"title">> => <<"Agent title">>}),
    {ok, #{<<"id">> := DId, <<"hash">> := DH}} = propose(O, #{<<"operation">> => <<"delete">>, <<"eventId">> => Id}),
    %% the user moves the event while the reviews wait
    {ok, _} = muse_calendar:update_event(O, Id, #{<<"start">> => <<"2030-01-09T10:00">>}, #{}),
    {ok, #{<<"status">> := <<"failed">>, <<"error">> := Stale}} = muse_actions:decide(O, AId, H, approve),
    ?assertMatch(<<"这个日程已经被改动过"/utf8, _/binary>>, Stale),
    {ok, #{<<"status">> := <<"failed">>}} = muse_actions:decide(O, DId, DH, approve),
    ?assertMatch({ok, #{<<"title">> := <<"评审"/utf8>>, <<"start">> := <<"2030-01-09T10:00">>}},
                 muse_calendar:get_event(O, Id)),
    %% an event deleted before approval
    {ok, #{<<"id">> := A3, <<"hash">> := H3}} =
        propose(O, #{<<"operation">> => <<"update">>, <<"eventId">> => Id, <<"title">> => <<"x">>}),
    ok = muse_calendar:delete_event(O, Id, #{}),
    {ok, #{<<"status">> := <<"failed">>, <<"error">> := <<"找不到这个日程"/utf8>>}} = muse_actions:decide(O, A3, H3, approve).

action_ownership() ->
    O = owner(),
    #{<<"id">> := Id} = event(O, #{<<"start">> => <<"2030-01-07T10:00">>}),
    Other = owner(),
    ?assertEqual({error, {404, <<"找不到这个日程"/utf8>>}},
                 propose(Other, #{<<"operation">> => <<"delete">>, <<"eventId">> => Id})),
    ?assertMatch({error, {422, <<"eventId is required", _/binary>>}}, propose(O, #{<<"operation">> => <<"update">>})),
    ?assertMatch({error, {404, _}}, propose(O, #{<<"operation">> => <<"create">>, <<"title">> => <<"x">>,
                                                 <<"start">> => <<"2030-01-07">>, <<"calendarId">> => <<"theirs">>})),
    %% another owner cannot decide this owner's proposal
    {ok, #{<<"id">> := AId, <<"hash">> := H}} = propose(O, #{<<"operation">> => <<"delete">>, <<"eventId">> => Id}),
    ?assertEqual({error, {404, <<"Action not found">>}}, muse_actions:decide(Other, AId, H, approve)),
    ?assertMatch({ok, _}, muse_calendar:get_event(O, Id)).

action_tool() ->
    ?assertMatch([#{kind := <<"calendar.event">>, name := <<"prepare_calendar_change">>, schema := {object, _}}],
                 muse_actions:tools()).
