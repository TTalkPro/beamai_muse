%% Ported from OpenMuse tests/google.test.ts (Calendar cases and the request
%% rules of google.ts `request`).
-module(muse_gcal_tests).
-include_lib("eunit/include/eunit.hrl").

-import(muse_google_test_http, [stub/1, calls/0, json/1, json/2, client/0, header/2, body_json/1]).

-define(RECURRING, {error, {422, <<"Recurring events cannot be changed here yet. Open Google Calendar "
                                  "to choose one occurrence or the whole series.">>}}).
-define(UNKNOWN, {error, {outcome_unknown, <<"Google may have completed this action. Check Google "
                                             "before trying again.">>}}).

event() ->
    #{<<"title">> => <<"Community museum">>,
      <<"start">> => <<"2026-10-10T10:00:00-07:00">>,
      <<"end">> => <<"2026-10-10T14:00:00-07:00">>}.

event_response() ->
    #{<<"id">> => <<"event-1">>, <<"etag">> => <<"\"revision-1\"">>, <<"summary">> => <<"Community museum">>,
      <<"start">> => #{<<"dateTime">> => <<"2026-10-10T10:00:00-07:00">>, <<"timeZone">> => <<"America/Los_Angeles">>},
      <<"end">> => #{<<"dateTime">> => <<"2026-10-10T14:00:00-07:00">>}}.

etag() -> <<"\"revision-1\"">>.

http_test_() ->
    {foreach, fun muse_google_test_http:start/0, fun(_) -> muse_google_test_http:stop() end,
     [fun expanded_primary_events/0,
      fun writes_use_calendar_ids/0,
      fun review_requires_version/0,
      fun changed_targets_refused_before_dispatch/0,
      fun review_resolves_calendar_zone/0,
      fun reviewed_version_is_if_match/0,
      fun all_day_writes/0,
      fun nonexistent_dates_rejected/0,
      fun patch_clears_other_time_form/0,
      fun scope_errors_visible/0,
      fun network_and_5xx_writes_unknown/0,
      fun definite_failures/0,
      fun thread_events_bounded_ranges/0,
      fun calendar_pagination/0,
      fun calendar_pagination_limit/0,
      fun calendar_zone_fallback/0,
      fun review_utc_fallback/0,
      fun page_completeness/0,
      fun recurring_rejected/0,
      fun validation_repeated_at_execution/0,
      fun invalid_ids/0]}.

expanded_primary_events() ->
    stub(fun(get, #{host := H, path := P, query := Q}, _, _) ->
                 ?assertEqual(<<"www.googleapis.com">>, H),
                 ?assertEqual(<<"/calendar/v3/calendars/primary/events">>, P),
                 ?assertEqual(<<"true">>, proplists:get_value(<<"singleEvents">>, Q)),
                 ?assertEqual(<<"startTime">>, proplists:get_value(<<"orderBy">>, Q)),
                 ?assertNotEqual(undefined, proplists:get_value(<<"timeMin">>, Q)),
                 json(#{<<"timeZone">> => <<"America/Los_Angeles">>,
                        <<"items">> => [#{<<"id">> => <<"day1">>, <<"summary">> => <<"Museum day">>,
                                          <<"start">> => #{<<"date">> => <<"2026-10-10">>},
                                          <<"end">> => #{<<"date">> => <<"2026-10-11">>},
                                          <<"attendees">> => [#{<<"email">> => <<"guardian@example.com">>}]}]})
         end),
    ?assertEqual({ok, [#{<<"id">> => <<"day1">>, <<"calendarId">> => <<"primary">>, <<"title">> => <<"Museum day">>,
                         <<"start">> => <<"2026-10-10">>, <<"end">> => <<"2026-10-11">>, <<"allDay">> => true,
                         <<"timeZone">> => <<"America/Los_Angeles">>, <<"location">> => <<>>,
                         <<"description">> => <<>>, <<"attendees">> => [<<"guardian@example.com">>]}]},
                 muse_gcal:list_events(client(), #{})).

writes_use_calendar_ids() ->
    stub(fun(delete, _, _, _) -> {status, 204};
            (_, _, _, _) -> json(event_response())
         end),
    Draft = (event())#{<<"calendarId">> => <<"shared@example.com">>,
                       <<"attendees">> => [<<"guardian@example.com">>]},
    ?assertMatch({ok, #{<<"calendarId">> := <<"shared@example.com">>}}, muse_gcal:create_event(client(), Draft)),
    ?assertMatch({ok, _}, muse_gcal:update_event(client(), <<"event-1">>, Draft, undefined)),
    ?assertEqual(ok, muse_gcal:delete_event(client(), <<"shared@example.com">>, <<"event-1">>, undefined)),
    Calls = calls(),
    ?assertEqual([post, get, patch, get, delete], [M || {M, _, _, _} <- Calls]),
    {_, U2, H2, _} = lists:nth(3, Calls),
    ?assertEqual(<<"/calendar/v3/calendars/shared%40example.com/events/event-1">>, maps:get(path, U2)),
    ?assert(lists:all(fun({M, U, _, _}) -> M =:= get orelse
                                               proplists:get_value(<<"sendUpdates">>, maps:get(query, U)) =:= <<"all">>
                      end, Calls)),
    ?assertEqual(etag(), header(<<"if-match">>, H2)),
    {_, _, H4, _} = lists:nth(5, Calls),
    ?assertEqual(etag(), header(<<"if-match">>, H4)),
    {post, _, _, Body} = hd(Calls),
    ?assertEqual(#{<<"summary">> => <<"Community museum">>,
                   <<"start">> => #{<<"dateTime">> => <<"2026-10-10T10:00:00-07:00">>, <<"timeZone">> => <<"America/Los_Angeles">>},
                   <<"end">> => #{<<"dateTime">> => <<"2026-10-10T14:00:00-07:00">>, <<"timeZone">> => <<"America/Los_Angeles">>},
                   <<"location">> => <<>>, <<"description">> => <<>>,
                   <<"attendees">> => [#{<<"email">> => <<"guardian@example.com">>}]}, body_json(Body)),
    %% JSON key order follows eventBody.
    ?assertMatch(<<"{\"summary\":", _/binary>>, iolist_to_binary(Body)).

review_requires_version() ->
    stub(fun(_, _, _, _) -> json(event_response()) end),
    {ok, #{event := Ev, version := V}} = muse_gcal:review_event(client(), <<"primary">>, <<"event-1">>),
    ?assertEqual(<<"Community museum">>, maps:get(<<"title">>, Ev)),
    ?assertEqual(<<"America/Los_Angeles">>, maps:get(<<"timeZone">>, Ev)),
    ?assertEqual(etag(), V),
    lists:foreach(
      fun({Etag, Msg}) ->
              stub(fun(_, _, _, _) -> json(maps:remove(undefined, (event_response())#{<<"etag">> => Etag})) end),
              ?assertEqual({error, {internal, Msg}}, muse_gcal:review_event(client(), <<"primary">>, <<"event-1">>))
      end,
      [{<<>>, <<"Google event has no ETag; prepare a fresh review">>},
       {<<"  ">>, <<"Google event has no ETag; prepare a fresh review">>},
       {<<"bad\r\nversion">>, <<"Invalid event ETag: header control characters are not allowed">>}]),
    stub(fun(_, _, _, _) -> json(maps:remove(<<"etag">>, event_response())) end),
    ?assertEqual({error, {internal, <<"Google event has no ETag; prepare a fresh review">>}},
                 muse_gcal:review_event(client(), <<"primary">>, <<"event-1">>)),
    stub(fun(_, _, _, _) -> json((event_response())#{<<"recurringEventId">> => <<"series">>}) end),
    ?assertEqual(?RECURRING, muse_gcal:review_event(client(), <<"primary">>, <<"event-1">>)).

changed_targets_refused_before_dispatch() ->
    stub(fun(delete, _, _, _) -> {status, 204};
            (_, _, _, _) -> json((event_response())#{<<"etag">> => <<"\"revision-2\"">>})
         end),
    Changed = {error, {502, <<"Google API (409): This event changed since review. Prepare a new action.">>}},
    ?assertEqual(Changed, muse_gcal:update_event(client(), <<"event-1">>, event(), etag())),
    ?assertEqual(Changed, muse_gcal:delete_event(client(), <<"primary">>, <<"event-1">>, etag())),
    ?assertEqual([get, get], [M || {M, _, _, _} <- calls()]).

review_resolves_calendar_zone() ->
    stub(fun(get, #{path := P}, _, _) ->
                 case binary:match(P, <<"/calendarList/">>) of
                     nomatch -> json((event_response())#{<<"start">> => #{<<"dateTime">> => <<"2026-10-11T08:00:00+13:00">>},
                                                         <<"end">> => #{<<"dateTime">> => <<"2026-10-11T09:00:00+13:00">>}});
                     _ -> json(#{<<"id">> => <<"shared@example.com">>, <<"timeZone">> => <<"Pacific/Auckland">>})
                 end
         end),
    {ok, #{event := Ev}} = muse_gcal:review_event(client(), <<"shared@example.com">>, <<"event-1">>),
    ?assertEqual(<<"Pacific/Auckland">>, maps:get(<<"timeZone">>, Ev)),
    ?assert(lists:member(<<"/calendar/v3/users/me/calendarList/shared%40example.com">>,
                         [maps:get(path, U) || {_, U, _, _} <- calls()])).

reviewed_version_is_if_match() ->
    stub(fun(get, _, _, _) -> json(event_response());
            (_, _, H, _) ->
                 ?assertEqual(etag(), header(<<"if-match">>, H)),
                 json(412, #{<<"error">> => #{<<"message">> => <<"Event changed after the check">>}})
         end),
    Err = {error, {502, <<"Google API (412): Event changed after the check">>}},
    ?assertEqual(Err, muse_gcal:update_event(client(), <<"event-1">>, event(), etag())),
    ?assertEqual(Err, muse_gcal:delete_event(client(), <<"primary">>, <<"event-1">>, etag())),
    ?assertEqual(2, length([x || {M, _, _, _} <- calls(), M =/= get])).

all_day_writes() ->
    stub(fun(post, _, _, Body) ->
                 #{<<"start">> := S, <<"end">> := E} = body_json(Body),
                 ?assertEqual(#{<<"date">> => <<"2026-10-10">>}, S),
                 ?assertEqual(#{<<"date">> => <<"2026-10-11">>}, E),
                 json((event_response())#{<<"start">> => S, <<"end">> => E})
         end),
    ?assertMatch({ok, #{<<"allDay">> := true, <<"timeZone">> := <<"America/Los_Angeles">>}},
                 muse_gcal:create_event(client(), (event())#{<<"start">> => <<"2026-10-10">>,
                                                             <<"end">> => <<"2026-10-11">>,
                                                             <<"allDay">> => true})),
    ?assertEqual({error, {422, <<"End must be after a valid start">>}},
                 muse_gcal:create_event(client(), (event())#{<<"end">> => <<"2026-10-09T10:00:00-07:00">>})),
    ?assertEqual(1, length(calls())).

nonexistent_dates_rejected() ->
    stub(fun(_, _, _, _) -> json(event_response()) end),
    lists:foreach(
      fun(AllDay) ->
              Suffix = case AllDay of true -> <<>>; false -> <<"T10:00:00+08:00">> end,
              Draft = (event())#{<<"allDay">> => AllDay, <<"start">> => <<"2026-02-29", Suffix/binary>>,
                                 <<"end">> => <<"2026-03-02", Suffix/binary>>},
              ?assertMatch({error, {422, _}}, muse_gcal:create_event(client(), Draft)),
              ?assertMatch({error, {422, _}}, muse_gcal:update_event(client(), <<"event-1">>, Draft, undefined))
      end, [true, false]),
    ?assertEqual({error, {422, <<"Invalid time zone">>}},
                 muse_gcal:create_event(client(), (event())#{<<"timeZone">> => <<"Mars/Olympus">>})),
    ?assertEqual({error, {422, <<"Timed events need valid date-times with an explicit offset">>}},
                 muse_gcal:create_event(client(), (event())#{<<"start">> => <<"2026-10-10T10:00:00">>})),
    ?assertEqual([], calls()).

patch_clears_other_time_form() ->
    stub(fun(get, _, _, _) -> json(event_response());
            (patch, _, _, Body) ->
                 case body_json(Body) of
                     #{<<"start">> := #{<<"date">> := D} = S, <<"end">> := #{<<"date">> := ED} = E} when is_binary(D) ->
                         ?assertEqual(null, maps:get(<<"dateTime">>, S)),
                         ?assertEqual(null, maps:get(<<"dateTime">>, E)),
                         json((event_response())#{<<"start">> => #{<<"date">> => D}, <<"end">> => #{<<"date">> => ED}});
                     #{<<"start">> := S, <<"end">> := E} ->
                         ?assertEqual(null, maps:get(<<"date">>, S)),
                         ?assertEqual(null, maps:get(<<"date">>, E)),
                         json(event_response())
                 end
         end),
    ?assertMatch({ok, #{<<"allDay">> := true}},
                 muse_gcal:update_event(client(), <<"event-1">>,
                                        (event())#{<<"allDay">> => true, <<"start">> => <<"2026-10-10">>,
                                                   <<"end">> => <<"2026-10-11">>}, undefined)),
    ?assertMatch({ok, #{<<"allDay">> := false}}, muse_gcal:update_event(client(), <<"event-1">>, event(), undefined)).

scope_errors_visible() ->
    stub(fun(_, _, _, _) ->
                 json(403, #{<<"error">> => #{<<"message">> => <<"Request had insufficient authentication scopes.">>}})
         end),
    ?assertEqual({error, {502, <<"Google API (403): Request had insufficient authentication scopes.">>}},
                 muse_gcal:list_events(client(), #{})),
    %% Without a JSON error body the status text stands in.
    stub(fun(_, _, _, _) -> {raw, 404, <<"<html>nope</html>">>} end),
    ?assertEqual({error, {502, <<"Google API (404): Not Found">>}}, muse_gcal:list_calendars(client())).

network_and_5xx_writes_unknown() ->
    lists:foreach(
      fun(Failure) ->
              stub(fun(get, _, _, _) -> json(event_response());
                      (_, _, _, _) -> Failure
                   end),
              ?assertEqual(?UNKNOWN, muse_gcal:create_event(client(), event())),
              ?assertEqual(?UNKNOWN, muse_gcal:update_event(client(), <<"event-1">>, event(), undefined)),
              ?assertEqual(2, length([x || {M, _, _, _} <- calls(), M =/= get])),
              meck:reset(beamai_http)
      end,
      [{error, {gun_error, closed}}, json(503, #{<<"error">> => #{<<"message">> => <<"upstream failed">>}}),
       json(#{<<"unexpected">> => <<"body">>})]),
    stub(fun(get, _, _, _) -> json(event_response());
            (_, _, _, _) -> {error, {gun_error, closed}}
         end),
    ?assertEqual(?UNKNOWN, muse_gcal:delete_event(client(), <<"primary">>, <<"event-1">>, undefined)),
    ?assertEqual(1, length([x || {delete, _, _, _} <- calls()])).

definite_failures() ->
    Client = muse_google_api:token_client(fun() -> {error, {409, <<"Google is disconnected">>}} end),
    stub(fun(_, _, _, _) -> error(must_not_fetch) end),
    ?assertEqual({error, {409, <<"Google is disconnected">>}}, muse_gcal:create_event(Client, event())),
    Bad = muse_google_api:token_client(fun() -> {ok, <<"tok\r\nX: y">>} end),
    ?assertEqual({error, {internal, <<"Google access token is missing or invalid; reconnect Google">>}},
                 muse_gcal:create_event(Bad, event())),
    ?assertEqual([], calls()),
    stub(fun(_, _, _, _) -> json(400, #{<<"error">> => #{<<"message">> => <<"invalid attendee">>}}) end),
    ?assertEqual({error, {502, <<"Google API (400): invalid attendee">>}}, muse_gcal:create_event(client(), event())).

thread_events_bounded_ranges() ->
    stub(fun(_, _, _, _) -> json(#{<<"items">> => [event_response()]}) end),
    {ok, _} = muse_gcal:list_events(client(), #{}),
    [{get, U0, _, _}] = calls(),
    Q0 = maps:get(query, U0),
    ?assertEqual(muse_gcal:local_midnight_iso(), proplists:get_value(<<"timeMin">>, Q0)),
    ?assertEqual(<<"100">>, proplists:get_value(<<"maxResults">>, Q0)),
    ?assertEqual(muse_time:parse(proplists:get_value(<<"timeMin">>, Q0)) + 31 * 86400000,
                 muse_time:parse(proplists:get_value(<<"timeMax">>, Q0))),
    {ok, [Ev]} = muse_gcal:list_events(client(), #{<<"calendarId">> => <<"shared@example.com">>,
                                                   <<"timeMin">> => <<"2026-10-01T00:00:00-07:00">>,
                                                   <<"timeMax">> => <<"2026-11-01T00:00:00-07:00">>}),
    ?assertEqual(<<"shared@example.com">>, maps:get(<<"calendarId">>, Ev)),
    [_, {get, U1, _, _}] = calls(),
    ?assertEqual(<<"/calendar/v3/calendars/shared%40example.com/events">>, maps:get(path, U1)),
    ?assertEqual(<<"2026-10-01T00:00:00-07:00">>, proplists:get_value(<<"timeMin">>, maps:get(query, U1))),
    ?assertEqual(<<"2026-11-01T00:00:00-07:00">>, proplists:get_value(<<"timeMax">>, maps:get(query, U1))),
    Range = {error, {422, <<"Calendar range must end after it starts and span at most 366 days">>}},
    ?assertEqual({error, {internal, <<"Invalid calendar timeMin: use a date-time with an explicit offset">>}},
                 muse_gcal:list_events(client(), #{timeMin => <<"yesterday">>})),
    ?assertEqual({error, {internal, <<"Invalid calendar timeMin: use a date-time with an explicit offset">>}},
                 muse_gcal:list_events(client(), #{timeMin => <<"2026-10-01T00:00:00">>,
                                                   timeMax => <<"2026-11-01T00:00:00Z">>})),
    ?assertEqual({error, {internal, <<"Invalid calendar timeMax: use a date-time with an explicit offset">>}},
                 muse_gcal:list_events(client(), #{timeMin => <<"2026-10-01T00:00:00Z">>,
                                                   timeMax => <<"2026-11-01T00:00Z">>})),
    ?assertEqual(Range, muse_gcal:list_events(client(), #{timeMin => <<"2026-10-01T00:00:00Z">>,
                                                          timeMax => <<"2026-09-01T00:00:00Z">>})),
    ?assertEqual(Range, muse_gcal:list_events(client(), #{timeMin => <<"2026-10-01T00:00:00Z">>,
                                                          timeMax => <<"2028-10-01T00:00:00Z">>})),
    ?assertEqual(2, length(calls())).

calendar_pagination() ->
    stub(fun(get, #{path := P, query := Q}, _, _) ->
                 ?assertEqual(<<"/calendar/v3/users/me/calendarList">>, P),
                 ?assertEqual(<<"250">>, proplists:get_value(<<"maxResults">>, Q)),
                 case proplists:get_value(<<"pageToken">>, Q) of
                     undefined ->
                         json(#{<<"nextPageToken">> => <<"next1">>,
                                <<"items">> => [#{<<"id">> => <<"me@example.com">>, <<"summary">> => <<"Personal">>,
                                                  <<"timeZone">> => <<"America/Los_Angeles">>, <<"accessRole">> => <<"owner">>}]});
                     <<"next1">> ->
                         json(#{<<"items">> => [#{<<"id">> => <<"shared@example.com">>, <<"summary">> => <<"Original name">>,
                                                  <<"summaryOverride">> => <<"Family">>,
                                                  <<"timeZone">> => <<"America/Los_Angeles">>, <<"accessRole">> => <<"writer">>}]})
                 end
         end),
    ?assertEqual({ok, [#{<<"id">> => <<"me@example.com">>, <<"name">> => <<"Personal">>,
                         <<"timeZone">> => <<"America/Los_Angeles">>, <<"accessRole">> => <<"owner">>},
                       #{<<"id">> => <<"shared@example.com">>, <<"name">> => <<"Family">>,
                         <<"timeZone">> => <<"America/Los_Angeles">>, <<"accessRole">> => <<"writer">>}]},
                 muse_gcal:list_calendars(client())).

calendar_pagination_limit() ->
    Limit = {error, {internal, <<"Google calendar list exceeded the pagination limit">>}},
    stub(fun(_, _, _, _) -> json(#{<<"nextPageToken">> => <<"same">>, <<"items">> => []}) end),
    ?assertEqual(Limit, muse_gcal:list_calendars(client())),
    ?assertEqual(2, length(calls())),
    Counter = counters:new(1, []),
    stub(fun(_, _, _, _) ->
                 counters:add(Counter, 1, 1),
                 json(#{<<"nextPageToken">> => integer_to_binary(counters:get(Counter, 1)), <<"items">> => []})
         end),
    ?assertEqual(Limit, muse_gcal:list_calendars(client())),
    ?assertEqual(11, counters:get(Counter, 1)).

calendar_zone_fallback() ->
    stub(fun(_, _, _, _) ->
                 json(#{<<"items">> => [#{<<"id">> => <<"shared@example.com">>, <<"summary">> => <<"Family">>,
                                          <<"accessRole">> => <<"reader">>}]})
         end),
    ?assertEqual({ok, [#{<<"id">> => <<"shared@example.com">>, <<"name">> => <<"Family">>,
                         <<"timeZone">> => <<"UTC">>, <<"accessRole">> => <<"reader">>}]},
                 muse_gcal:list_calendars(client())).

review_utc_fallback() ->
    stub(fun(get, #{path := <<"/calendar/v3/users/me/calendarList/primary">>}, _, _) ->
                 json(#{<<"id">> => <<"primary">>, <<"summary">> => <<"Personal">>, <<"accessRole">> => <<"owner">>});
            (_, _, _, _) ->
                 json((event_response())#{<<"start">> => #{<<"dateTime">> => <<"2026-10-10T10:00:00-07:00">>}})
         end),
    ?assertMatch({ok, #{event := #{<<"timeZone">> := <<"UTC">>}}},
                 muse_gcal:review_event(client(), <<"primary">>, <<"event-1">>)).

page_completeness() ->
    lists:foreach(
      fun({Count, Next, Truncated}) ->
              Items = [(event_response())#{<<"id">> => <<"event-", (integer_to_binary(I))/binary>>}
                       || I <- lists:seq(1, Count)],
              stub(fun(_, _, _, _) ->
                           json(maps:merge(#{<<"items">> => Items},
                                           case Next of undefined -> #{}; _ -> #{<<"nextPageToken">> => Next} end))
                   end),
              {ok, #{<<"events">> := Events, <<"truncated">> := T}} =
                  muse_gcal:list_events_page(client(), #{timeMin => <<"2026-10-01T00:00:00Z">>,
                                                         timeMax => <<"2026-11-01T00:00:00Z">>}),
              ?assertEqual(min(Count, 100), length(Events)),
              ?assertEqual(Truncated, T)
      end, [{0, <<"next-page">>, true}, {0, undefined, false}, {100, undefined, false}, {101, undefined, true}]).

recurring_rejected() ->
    lists:foreach(
      fun(Recurrence) ->
              stub(fun(_, #{path := P}, _, _) ->
                           ?assertEqual(<<"/calendar/v3/calendars/primary/events/event-1">>, P),
                           json(maps:merge(event_response(), Recurrence))
                   end),
              ?assertEqual(?RECURRING, muse_gcal:validate_single_event(client(), <<"primary">>, <<"event-1">>)),
              ?assertEqual(?RECURRING, muse_gcal:update_event(client(), <<"event-1">>, event(), undefined)),
              ?assertEqual(?RECURRING, muse_gcal:delete_event(client(), <<"primary">>, <<"event-1">>, undefined)),
              ?assertEqual([get, get, get], [M || {M, _, _, _} <- calls()]),
              meck:reset(beamai_http)
      end, [#{<<"recurrence">> => [<<"RRULE:FREQ=WEEKLY">>]}, #{<<"recurringEventId">> => <<"series1">>}]).

validation_repeated_at_execution() ->
    Reads = counters:new(1, []),
    stub(fun(get, _, _, _) ->
                 counters:add(Reads, 1, 1),
                 case counters:get(Reads, 1) > 1 of
                     true -> json((event_response())#{<<"recurrence">> => [<<"RRULE:FREQ=DAILY">>]});
                     false -> json(event_response())
                 end;
            (_, _, _, _) -> json(event_response())
         end),
    ?assertEqual(ok, muse_gcal:validate_single_event(client(), <<"primary">>, <<"event-1">>)),
    ?assertEqual(?RECURRING, muse_gcal:update_event(client(), <<"event-1">>, event(), undefined)),
    stub(fun(_, _, _, _) -> json(403, #{<<"error">> => #{<<"message">> => <<"No access to this event">>}}) end),
    ?assertEqual({error, {502, <<"Google API (403): No access to this event">>}},
                 muse_gcal:delete_event(client(), <<"primary">>, <<"event-1">>, undefined)),
    ?assertEqual([], [x || {M, _, _, _} <- calls(), M =/= get]).

invalid_ids() ->
    stub(fun(_, _, _, _) -> error(must_not_fetch) end),
    BadCal = {error, {internal, <<"Invalid Google calendar ID">>}},
    ?assertEqual(BadCal, muse_gcal:list_events(client(), #{calendarId => <<"..">>})),
    ?assertEqual(BadCal, muse_gcal:list_events(client(), #{calendarId => <<"a b">>})),
    ?assertEqual(BadCal, muse_gcal:list_events(client(), #{calendarId => binary:copy(<<"a">>, 1025)})),
    ?assertEqual({error, {internal, <<"Invalid Google resource ID">>}},
                 muse_gcal:validate_single_event(client(), <<"primary">>, <<"ev/../x">>)),
    ?assertEqual([], calls()).

range_schema_test() ->
    P = fun(Min, Max) -> muse_validate:parse(muse_gcal:calendar_range_schema(),
                                             #{<<"timeMin">> => Min, <<"timeMax">> => Max}) end,
    ?assertMatch({ok, _}, P(<<"2026-01-01T00:00:00Z">>, <<"2027-01-02T00:00:00Z">>)),
    ?assertMatch({error, {422, _}}, P(<<"2026-01-01T00:00:00Z">>, <<"2027-01-02T00:00:00.001Z">>)),
    ?assertMatch({ok, _}, P(<<"2026-01-01T00:00:00.5+05:30">>, <<"2026-01-01T00:00:01-00:00">>)),
    ?assertMatch({error, {422, _}}, P(<<"2026-01-01T00:00Z">>, <<"2026-01-02T00:00:00Z">>)),
    ?assertMatch({error, {422, _}}, P(<<"2026-02-30T00:00:00Z">>, <<"2026-03-02T00:00:00Z">>)),
    ?assertMatch({error, {422, _}}, P(<<"2026-01-01T00:00:00+24:00">>, <<"2026-01-02T00:00:00Z">>)).
