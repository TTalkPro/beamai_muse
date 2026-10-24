%% @doc Google Calendar: calendars, bounded event pages, reviewed writes
%% (designs/ref/openmuse-integrations-spec.md §9.6, google.ts).
%%
%% Events come back as CalendarEvent documents (binary-keyed maps, §2.5).
%% Updates and deletes re-read the event first: recurring masters and
%% occurrences are refused (422, RecurringEventError) and the ETag must still
%% equal the reviewed version, which is then sent as If-Match.
-module(muse_gcal).

-export([list_calendars/1, list_events/2, list_events_page/2, review_event/3,
         validate_single_event/3, create_event/2, update_event/4, delete_event/4,
         map_event/3, event_body/2,
         event_draft_schema/0, calendar_range_schema/0, is_offset_datetime/1,
         local_midnight_iso/0]).

-export_type([event/0]).

-define(CALENDAR, "https://www.googleapis.com/calendar/v3").
-define(RECURRING, <<"Recurring events cannot be changed here yet. Open Google Calendar to "
                     "choose one occurrence or the whole series.">>).
-define(OUTCOME_UNKNOWN,
        {error, {outcome_unknown,
                 <<"Google may have completed this action. Check Google before trying again.">>}}).
-define(DATE_RE, "(?:(?:\\d\\d[2468][048]|\\d\\d[13579][26]|\\d\\d0[48]|[02468][048]00|"
                 "[13579][26]00)-02-29|\\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\\d|3[01])|"
                 "(?:0[469]|11)-(?:0[1-9]|[12]\\d|30)|(?:02)-(?:0[1-9]|1\\d|2[0-8])))").

-type error() :: muse_google_api:error().
-type client() :: muse_google_api:client().
-type event() :: #{binary() => term()}.

%% @doc Every calendar of the account (follows at most 10 page tokens).
-spec list_calendars(client()) -> {ok, [map()]} | {error, error()}.
list_calendars(Client) ->
    list_calendars(Client, undefined, [], []).

%% @doc `listEvents`: the events of `list_events_page/2`.
-spec list_events(client(), map()) -> {ok, [event()]} | {error, error()}.
list_events(Client, Opts) ->
    case list_events_page(Client, Opts) of
        {ok, #{<<"events">> := Events}} -> {ok, Events};
        Error -> Error
    end.

%% @doc At most 100 single events in a bounded window. `Opts` keys
%% (binaries or atoms): `calendarId` (default `primary`), `timeMin`
%% (default local midnight today), `timeMax` (default `timeMin` + 31 days).
%% Returns `#{<<"events">>, <<"truncated">>}`.
-spec list_events_page(client(), map()) -> {ok, map()} | {error, error()}.
list_events_page(Client, Opts) ->
    CalId = opt(Opts, calendarId, <<"primary">>),
    maybe
        {ok, Path} ?= muse_google_api:calendar_path(CalId),
        TimeMin = opt(Opts, timeMin, local_midnight_iso()),
        ok ?= offset_check(TimeMin, <<"timeMin">>),
        TimeMax = opt(Opts, timeMax, muse_time:to_iso(muse_time:parse(TimeMin) + 31 * 86400000)),
        ok ?= offset_check(TimeMax, <<"timeMax">>),
        {ok, _} ?= muse_validate:parse(calendar_range_schema(),
                                       #{<<"timeMin">> => TimeMin, <<"timeMax">> => TimeMax}),
        Query = muse_google_api:form_encode([{<<"maxResults">>, <<"100">>},
                                             {<<"singleEvents">>, <<"true">>},
                                             {<<"orderBy">>, <<"startTime">>},
                                             {<<"timeMin">>, TimeMin},
                                             {<<"timeMax">>, TimeMax}]),
        {ok, Json} ?= muse_google_api:get(Client, [Path, "?", Query]),
        Schema = {object, [{<<"items">>, {default, {array, any, #{}}, []}},
                           {<<"timeZone">>, {default, {string, #{}}, <<"UTC">>}},
                           {<<"nextPageToken">>, {optional, {string, #{min => 1}}}}]},
        {ok, #{<<"items">> := Items, <<"timeZone">> := Tz} = Page} ?=
            muse_validate:parse(Schema, Json),
        {ok, Events} ?= map_all(lists:sublist(Items, 100), CalId, Tz, []),
        {ok, #{<<"events">> => Events,
               <<"truncated">> => is_map_key(<<"nextPageToken">>, Page) orelse length(Items) > 100}}
    end.

%% @doc Read an event for an approval card: `#{event => Event, version => ETag}`.
-spec review_event(client(), binary(), binary()) ->
          {ok, #{event := event(), version := binary()}} | {error, error()}.
review_event(Client, CalId, EventId) ->
    maybe
        {ok, Current} ?= read_single_event(Client, CalId, EventId),
        {ok, Version} ?= event_version(Current, undefined),
        {ok, Tz} ?= case Current of
                        #{<<"start">> := #{<<"timeZone">> := Zone}} -> {ok, Zone};
                        _ -> calendar_zone(Client, CalId)
                    end,
        {ok, Event} ?= map_event(Current, CalId, Tz),
        {ok, #{event => Event, version => Version}}
    end.

%% @doc Fails unless the event exists and is a single (non-recurring) event.
-spec validate_single_event(client(), binary(), binary()) -> ok | {error, error()}.
validate_single_event(Client, CalId, EventId) ->
    case read_single_event(Client, CalId, EventId) of
        {ok, _} -> ok;
        Error -> Error
    end.

-spec create_event(client(), map()) -> {ok, event()} | {error, error()}.
create_event(Client, Draft0) ->
    maybe
        {ok, Draft} ?= muse_validate:parse(event_draft_schema(), Draft0),
        CalId = maps:get(<<"calendarId">>, Draft),
        {ok, Path} ?= muse_google_api:calendar_path(CalId),
        {ok, Result} ?= muse_google_api:request(Client, post, [Path, "?sendUpdates=all"],
                                                event_body(Draft, false), []),
        written(Result, CalId, maps:get(<<"timeZone">>, Draft))
    end.

%% @doc PATCH a reviewed event. `Expected` is the reviewed ETag (`undefined`
%% skips the comparison, as in the original).
-spec update_event(client(), binary(), map(), binary() | undefined) ->
          {ok, event()} | {error, error()}.
update_event(Client, EventId, Draft0, Expected) ->
    maybe
        {ok, Draft} ?= muse_validate:parse(event_draft_schema(), Draft0),
        CalId = maps:get(<<"calendarId">>, Draft),
        {ok, Current} ?= read_single_event(Client, CalId, EventId),
        {ok, Path} ?= muse_google_api:calendar_path(CalId),
        {ok, Id} ?= muse_google_api:id_path(EventId),
        {ok, Version} ?= event_version(Current, Expected),
        {ok, Result} ?= muse_google_api:request(Client, patch,
                                                [Path, "/", Id, "?sendUpdates=all"],
                                                event_body(Draft, true),
                                                [{<<"If-Match">>, Version}]),
        written(Result, CalId, maps:get(<<"timeZone">>, Draft))
    end.

-spec delete_event(client(), binary(), binary(), binary() | undefined) -> ok | {error, error()}.
delete_event(Client, CalId, EventId, Expected) ->
    maybe
        {ok, Current} ?= read_single_event(Client, CalId, EventId),
        {ok, Path} ?= muse_google_api:calendar_path(CalId),
        {ok, Id} ?= muse_google_api:id_path(EventId),
        {ok, Version} ?= event_version(Current, Expected),
        {ok, _} ?= muse_google_api:request(Client, delete, [Path, "/", Id, "?sendUpdates=all"],
                                           undefined, [{<<"If-Match">>, Version}]),
        ok
    end.

%% @doc google.ts `mapEvent`.
-spec map_event(term(), binary(), binary()) -> {ok, event()} | {error, error()}.
map_event(Raw, CalId, FallbackTz) ->
    maybe
        {ok, E} ?= muse_validate:parse(google_event_schema(), Raw),
        #{<<"start">> := Start, <<"end">> := End} = E,
        AllDay = is_binary(maps:get(<<"date">>, Start, undefined))
                 andalso maps:get(<<"date">>, Start) =/= <<>>,
        Key = case AllDay of
                  true -> <<"date">>;
                  false -> <<"dateTime">>
              end,
        S = maps:get(Key, Start, undefined),
        En = maps:get(Key, End, undefined),
        ok ?= case is_binary(S) andalso S =/= <<>> andalso is_binary(En) andalso En =/= <<>>
                  andalso muse_time:parse(S) =/= nan andalso muse_time:parse(En) =/= nan of
                  true -> ok;
                  false -> {error, {internal, <<"Invalid Google event time range">>}}
              end,
        {ok, #{<<"id">> => maps:get(<<"id">>, E), <<"calendarId">> => CalId,
               <<"title">> => maps:get(<<"summary">>, E), <<"start">> => S, <<"end">> => En,
               <<"allDay">> => AllDay,
               <<"timeZone">> => maps:get(<<"timeZone">>, Start, FallbackTz),
               <<"location">> => maps:get(<<"location">>, E),
               <<"description">> => maps:get(<<"description">>, E),
               <<"attendees">> => [A || #{<<"email">> := A} <- maps:get(<<"attendees">>, E)]}}
    end.

%% @doc google.ts `eventBody` (ordered JSON). A patch clears the other time form.
-spec event_body(map(), boolean()) -> muse_json:json().
event_body(Draft, Patch) ->
    #{<<"title">> := Title, <<"start">> := Start, <<"end">> := End, <<"allDay">> := AllDay,
      <<"timeZone">> := Tz} = Draft,
    Time = fun(T) when AllDay ->
                   {obj, [{<<"date">>, T}] ++ [{<<"dateTime">>, null} || Patch]};
              (T) ->
                   {obj, [{<<"dateTime">>, T}, {<<"timeZone">>, Tz}] ++ [{<<"date">>, null} || Patch]}
           end,
    {obj, [{<<"summary">>, Title}, {<<"start">>, Time(Start)}, {<<"end">>, Time(End)},
           {<<"location">>, maps:get(<<"location">>, Draft)},
           {<<"description">>, maps:get(<<"description">>, Draft)},
           {<<"attendees">>, [{obj, [{<<"email">>, A}]} || A <- maps:get(<<"attendees">>, Draft)]}]}.

%% @doc eventDraft (spec §2.5).
-spec event_draft_schema() -> muse_validate:schema().
event_draft_schema() ->
    {refine,
     {object, [{<<"calendarId">>, {default, {string, #{}}, <<"primary">>}},
               {<<"title">>, {string, #{trim => true, min => 1, max => 500}}},
               {<<"start">>, {string, #{min => 1}}},
               {<<"end">>, {string, #{min => 1}}},
               {<<"allDay">>, {default, boolean, false}},
               {<<"timeZone">>, {default, {string, #{}}, <<"America/Los_Angeles">>}},
               {<<"location">>, {default, {string, #{max => 2000}}, <<>>}},
               {<<"description">>, {default, {string, #{max => 10000}}, <<>>}},
               {<<"attendees">>, {default, {array, {string, #{email => true}}, #{max => 50}}, []}}]},
     fun refine_event/1}.

%% @doc calendarRange (spec §2.5).
-spec calendar_range_schema() -> muse_validate:schema().
calendar_range_schema() ->
    Stamp = {refine, {string, #{}},
             fun(V) ->
                     case is_offset_datetime(V) of
                         true -> ok;
                         false -> {error, <<"Invalid ISO datetime">>}
                     end
             end},
    {refine, {object, [{<<"timeMin">>, Stamp}, {<<"timeMax">>, Stamp}]},
     fun(#{<<"timeMin">> := Min, <<"timeMax">> := Max}) ->
             Span = muse_time:parse(Max) - muse_time:parse(Min),
             case Span > 0 andalso Span =< 366 * 86400000 of
                 true -> ok;
                 false -> {error, <<"Calendar range must end after it starts and span at most "
                                    "366 days">>}
             end
     end}.

%% @doc zod `z.iso.datetime({offset: true})`.
-spec is_offset_datetime(term()) -> boolean().
is_offset_datetime(V) when is_binary(V) ->
    Re = <<"^", ?DATE_RE, "T(?:[01]\\d|2[0-3]):[0-5]\\d:[0-5]\\d(?:\\.\\d+)?"
           "(?:Z|[+-](?:[01]\\d|2[0-3]):[0-5]\\d)$">>,
    re:run(V, Re, [{capture, none}]) =:= match andalso muse_time:parse(V) =/= nan;
is_offset_datetime(_) ->
    false.

%% @doc Today's local (server zone) midnight as an ISO instant.
-spec local_midnight_iso() -> binary().
local_midnight_iso() ->
    Zone = muse_tz:system_zone(),
    Now = muse_time:now_ms(),
    {Date, _} = muse_tz:local(Zone, Now),
    Wall = (calendar:datetime_to_gregorian_seconds({Date, {0, 0, 0}}) - 62167219200) * 1000,
    Guess = Wall - muse_tz:offset(Zone, Now) * 1000,
    muse_time:to_iso(Wall - muse_tz:offset(Zone, Guess) * 1000).

%% Internal

list_calendars(Client, PageToken, Seen, Acc) ->
    Params = [{<<"maxResults">>, <<"250">>}] ++ [{<<"pageToken">>, PageToken} || PageToken =/= undefined],
    Schema = {object, [{<<"items">>,
                        {default, {array, {object, [{<<"id">>, {string, #{min => 1}}},
                                                    {<<"summary">>, {default, {string, #{}},
                                                                     <<"(Untitled calendar)">>}},
                                                    {<<"summaryOverride">>, {optional, {string, #{}}}},
                                                    {<<"timeZone">>, {default, {string, #{}}, <<"UTC">>}},
                                                    {<<"accessRole">>, {string, #{}}}]}, #{}}, []}},
                       {<<"nextPageToken">>, {optional, {string, #{min => 1}}}}]},
    maybe
        {ok, Json} ?= muse_google_api:get(Client, [?CALENDAR, "/users/me/calendarList?",
                                                   muse_google_api:form_encode(Params)]),
        {ok, #{<<"items">> := Items} = Page} ?= muse_validate:parse(Schema, Json),
        Entries = [#{<<"id">> => Id,
                     <<"name">> => maps:get(<<"summaryOverride">>, C, maps:get(<<"summary">>, C)),
                     <<"timeZone">> => maps:get(<<"timeZone">>, C),
                     <<"accessRole">> => maps:get(<<"accessRole">>, C)}
                   || #{<<"id">> := Id} = C <- Items],
        Acc1 = Acc ++ Entries,
        case maps:get(<<"nextPageToken">>, Page, undefined) of
            undefined ->
                {ok, Acc1};
            Next ->
                case lists:member(Next, Seen) orelse length(Seen) >= 10 of
                    true -> {error, {internal, <<"Google calendar list exceeded the pagination limit">>}};
                    false -> list_calendars(Client, Next, [Next | Seen], Acc1)
                end
        end
    end.

read_single_event(Client, CalId, EventId) ->
    maybe
        {ok, Path} ?= muse_google_api:calendar_path(CalId),
        {ok, Id} ?= muse_google_api:id_path(EventId),
        {ok, Json} ?= muse_google_api:get(Client, [Path, "/", Id]),
        {ok, Event} ?= muse_validate:parse(google_event_schema(), Json),
        ok ?= case maps:get(<<"id">>, Event) =:= EventId of
                  true -> ok;
                  false -> {error, {internal, <<"Google returned a different event">>}}
              end,
        case is_map_key(<<"recurrence">>, Event) orelse is_map_key(<<"recurringEventId">>, Event) of
            true -> {error, {422, ?RECURRING}};
            false -> {ok, Event}
        end
    end.

event_version(Event, Expected) ->
    Etag = maps:get(<<"etag">>, Event, undefined),
    case is_binary(Etag) andalso muse_google_api:js_trim(Etag) =/= <<>> of
        false ->
            {error, {internal, <<"Google event has no ETag; prepare a fresh review">>}};
        true ->
            case muse_google_api:single_line(Etag, <<"event ETag">>) of
                {ok, Version} when Expected =/= undefined, Version =/= Expected ->
                    {error, {502, <<"Google API (409): This event changed since review. "
                                    "Prepare a new action.">>}};
                Other ->
                    Other
            end
    end.

calendar_zone(Client, CalId) ->
    maybe
        {ok, Json} ?= muse_google_api:get(Client, [?CALENDAR, "/users/me/calendarList/",
                                                   muse_google_api:encode_uri_component(CalId)]),
        {ok, #{<<"timeZone">> := Tz}} ?=
            muse_validate:parse({object, [{<<"timeZone">>,
                                           {default, {string, #{min => 1}}, <<"UTC">>}}]}, Json),
        {ok, Tz}
    end.

written(Result, CalId, Tz) ->
    case map_event(Result, CalId, Tz) of
        {ok, _} = Ok -> Ok;
        {error, _} -> ?OUTCOME_UNKNOWN
    end.

map_all([], _CalId, _Tz, Acc) ->
    {ok, lists:reverse(Acc)};
map_all([Item | Rest], CalId, Tz, Acc) ->
    case map_event(Item, CalId, Tz) of
        {ok, E} -> map_all(Rest, CalId, Tz, [E | Acc]);
        Error -> Error
    end.

google_event_schema() ->
    Str = {string, #{}},
    {object, [{<<"id">>, {string, #{min => 1}}},
              {<<"etag">>, {optional, Str}},
              {<<"recurrence">>, {optional, {array, Str, #{}}}},
              {<<"recurringEventId">>, {optional, Str}},
              {<<"summary">>, {default, Str, <<"(Untitled event)">>}},
              {<<"start">>, {object, [{<<"date">>, {optional, Str}},
                                      {<<"dateTime">>, {optional, Str}},
                                      {<<"timeZone">>, {optional, Str}}]}},
              {<<"end">>, {object, [{<<"date">>, {optional, Str}},
                                    {<<"dateTime">>, {optional, Str}}]}},
              {<<"location">>, {default, Str, <<>>}},
              {<<"description">>, {default, Str, <<>>}},
              {<<"attendees">>, {default, {array, {object, [{<<"email">>, Str}]}, #{}}, []}}]}.

refine_event(#{<<"start">> := Start, <<"end">> := End, <<"allDay">> := AllDay,
               <<"timeZone">> := Tz}) ->
    S = muse_time:parse(Start),
    E = muse_time:parse(End),
    Order = [<<"End must be after a valid start">> || S =:= nan orelse E =:= nan orelse E =< S],
    Valid = fun(T) when AllDay -> date_only(T);
               (T) ->
                    re:run(T, <<"^\\d{4}-\\d{2}-\\d{2}T.*(?:Z|[+-]\\d{2}:\\d{2})$">>,
                           [{capture, none}]) =:= match
                        andalso date_only(binary:part(T, 0, 10))
            end,
    Form = case Valid(Start) andalso Valid(End) of
               true -> [];
               false when AllDay -> [<<"All-day events need valid date-only values">>];
               false -> [<<"Timed events need valid date-times with an explicit offset">>]
           end,
    Zone = [<<"Invalid time zone">> || not muse_tz:valid(Tz)],
    case Order ++ Form ++ Zone of
        [] -> ok;
        Msgs -> {error, iolist_to_binary(lists:join(<<"; ">>, Msgs))}
    end.

date_only(T) ->
    re:run(T, <<"^", ?DATE_RE, "$">>, [{capture, none}]) =:= match.

offset_check(V, Field) ->
    case is_offset_datetime(V) of
        true -> ok;
        false -> {error, {internal, <<"Invalid calendar ", Field/binary,
                                      ": use a date-time with an explicit offset">>}}
    end.

opt(Opts, Key, Default) ->
    case maps:get(atom_to_binary(Key), Opts, maps:get(Key, Opts, undefined)) of
        undefined -> Default;
        V -> V
    end.
