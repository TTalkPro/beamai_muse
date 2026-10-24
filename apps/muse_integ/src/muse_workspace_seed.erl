%% @doc Fictional sample workspace, copied verbatim from OpenMuse
%% `workspace.ts::seed` (typographic quotes included).
%%
%% Times are "today at H:M" in server-local time; `At(H, M)` returns the ISO
%% instant. The Studio North mail is dated exactly one day before now.
-module(muse_workspace_seed).

-export([mail/2, events/2, proposal/2]).

-type at() :: fun((0..23, 0..59) -> binary()).

-spec mail(binary(), at()) -> [map()].
mail(PermissionSlipId, At) ->
    [#{<<"id">> => <<"mail-fieldtrip">>,
       <<"threadId">> => <<"trip-thread">>,
       <<"sender">> => <<"Lincoln Middle School">>,
       <<"from">> => <<"office@lincoln.example">>,
       <<"to">> => [<<"alex@example.com">>],
       <<"subject">> => <<"A little reminder: permission slips are due Friday">>,
       <<"body">> => <<"Hi Alex,\n\nOur class is heading to the aquarium this Friday. Please complete "
                       "the attached permission slip and send it back when you have a moment.\n\n"
                       "We’ll leave school at 8:15 AM and return by 4:30 PM. Please pack lunch and "
                       "a water bottle.\n\nThank you!\nMs. Rivera\n\nThis message is included with "
                       "your local workspace."/utf8>>,
       <<"date">> => At(8, 42),
       <<"unread">> => true,
       <<"label">> => <<"School">>,
       <<"attachments">> => [PermissionSlipId]},
     #{<<"id">> => <<"mail-design">>,
       <<"threadId">> => <<"design-thread">>,
       <<"sender">> => <<"Jamie Chen">>,
       <<"from">> => <<"jamie@example.com">>,
       <<"to">> => [<<"alex@example.com">>],
       <<"subject">> => <<"Coffee and a catch-up?">>,
       <<"body">> => <<"Hey Alex,\n\nWould love to catch up this week. I’m free Thursday afternoon. "
                       "How does 3 PM at Bluebird Coffee sound?\n\nJamie\n\nThis invitation is part "
                       "of your local workspace."/utf8>>,
       <<"date">> => At(8, 15),
       <<"unread">> => true,
       <<"label">> => <<"Personal">>,
       <<"attachments">> => []},
     #{<<"id">> => <<"mail-stay">>,
       <<"threadId">> => <<"stay-thread">>,
       <<"sender">> => <<"The Seabird">>,
       <<"from">> => <<"stay@seabird.example">>,
       <<"to">> => [<<"alex@example.com">>],
       <<"subject">> => <<"Your weekend, all sorted">>,
       <<"body">> => <<"Your reservation is confirmed.\n\nCheck-in: Friday, 3 PM\nCheck-out: Sunday, "
                       "11 AM\n\nThis fictional reservation demonstrates how OpenMuse can organize "
                       "travel details.">>,
       <<"date">> => At(7, 30),
       <<"unread">> => false,
       <<"label">> => <<"Travel">>,
       <<"attachments">> => []},
     #{<<"id">> => <<"mail-studio">>,
       <<"threadId">> => <<"studio-thread">>,
       <<"sender">> => <<"Studio North">>,
       <<"from">> => <<"hello@studionorth.example">>,
       <<"to">> => [<<"alex@example.com">>],
       <<"subject">> => <<"Notes from our last conversation">>,
       <<"body">> => <<"Thanks for a thoughtful conversation yesterday. Let’s use our next session to "
                       "review the prototype and pick the three flows for testing.\n\nThis project is "
                       "part of your local workspace."/utf8>>,
       <<"date">> => muse_time:to_iso(muse_time:now_ms() - 86400000),
       <<"unread">> => false,
       <<"label">> => <<"Work">>,
       <<"attachments">> => []}].

-spec events(binary(), at()) -> [map()].
events(Zone, At) ->
    Base = base(Zone),
    [Base#{<<"id">> => <<"event-standup">>, <<"title">> => <<"A slow start · morning walk"/utf8>>,
           <<"start">> => At(9, 0), <<"end">> => At(9, 30), <<"location">> => <<"Neighborhood">>},
     Base#{<<"id">> => <<"event-review">>, <<"title">> => <<"Design catch-up">>,
           <<"start">> => At(11, 0), <<"end">> => At(11, 45), <<"location">> => <<"Studio North">>},
     Base#{<<"id">> => <<"event-lunch">>, <<"title">> => <<"Lunch with Maya">>,
           <<"start">> => At(13, 0), <<"end">> => At(14, 0), <<"location">> => <<"Little Saint">>}].

%% @doc The pending "Coffee with Jamie" calendar proposal.
-spec proposal(binary(), at()) -> map().
proposal(Zone, At) ->
    #{<<"kind">> => <<"calendar.create">>,
      <<"data">> => (base(Zone))#{<<"title">> => <<"Coffee with Jamie">>,
                                  <<"start">> => At(15, 0), <<"end">> => At(16, 0),
                                  <<"location">> => <<"Bluebird Coffee">>,
                                  <<"description">> => <<"Catch up over coffee">>,
                                  <<"attendees">> => [<<"jamie@example.com">>]}}.

base(Zone) ->
    #{<<"calendarId">> => <<"primary">>,
      <<"allDay">> => false,
      <<"timeZone">> => Zone,
      <<"description">> => <<"A little time to catch up">>,
      <<"attendees">> => []}.
