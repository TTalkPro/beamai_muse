-module(muse_workspace_tests).
-include_lib("eunit/include/eunit.hrl").

-define(O, <<"local-user">>).

workspace_test_() ->
    {setup,
     fun() ->
         Env = muse_integ_test_env:start(#{}),
         %% setup runs in another process than the tests: record via persistent_term
         Record = fun(Owner, Input) ->
                      persistent_term:put({?MODULE, proposed},
                                          [{Owner, Input} | persistent_term:get({?MODULE, proposed}, [])])
                  end,
         ok = muse_workspace:ensure_sample(?O, Record),
         Env
     end,
     fun muse_integ_test_env:stop/1,
     [fun seeded/0, fun seed_once/0, fun search/0, fun thread/0, fun events_range/0,
      fun snapshot_shape/0, fun sections/0, fun execute_sample/0, fun prepare/0,
      fun attachments_and_drafts/0, fun disconnected/0]}.

seeded() ->
    [{?O, #{<<"kind">> := <<"calendar.create">>, <<"data">> := Data}}] = persistent_term:get({?MODULE, proposed}),
    ?assertMatch(#{<<"title">> := <<"Coffee with Jamie">>, <<"attendees">> := [<<"jamie@example.com">>]}, Data),
    ?assertEqual(4, length(muse_store:list(?O, <<"mail">>))),
    ?assertEqual(3, length(muse_store:list(?O, <<"events">>))),
    [#{<<"attachments">> := [FileId]}] =
        [M || M = #{<<"id">> := <<"mail-fieldtrip">>} <- muse_store:list(?O, <<"mail">>)],
    ?assertMatch({ok, #{<<"name">> := <<"Field trip permission slip.pdf">>}}, muse_files:get(?O, FileId)).

seed_once() ->
    ok = muse_workspace:ensure_sample(?O, fun(_, _) -> error(proposed_twice) end),
    ?assertEqual(4, length(muse_store:list(?O, <<"mail">>))).

search() ->
    {ok, All} = muse_workspace:search_mail(?O, <<>>),
    ?assertEqual([<<"mail-fieldtrip">>, <<"mail-design">>, <<"mail-stay">>, <<"mail-studio">>],
                 [Id || #{<<"id">> := Id} <- All]),
    {ok, Hits} = muse_workspace:search_mail(?O, <<"  PERMISSION  aquarium ">>),
    ?assertEqual([<<"mail-fieldtrip">>], [Id || #{<<"id">> := Id} <- Hits]),
    {ok, []} = muse_workspace:search_mail(?O, <<"permission nosuchword">>).

thread() ->
    {ok, [#{<<"id">> := <<"mail-design">>}]} = muse_workspace:thread(?O, <<"design-thread">>),
    ?assertEqual({error, {404, <<"Mail thread not found">>}}, muse_workspace:thread(?O, <<"nope">>)).

events_range() ->
    {ok, Events} = muse_workspace:events(?O, #{}),
    ?assertEqual([<<"event-standup">>, <<"event-review">>, <<"event-lunch">>], [Id || #{<<"id">> := Id} <- Events]),
    Lunch = muse_workspace:at_local(13, 0),
    {ok, Morning} = muse_workspace:events(?O, #{<<"timeMax">> => Lunch}),
    ?assertEqual([<<"event-standup">>, <<"event-review">>], [Id || #{<<"id">> := Id} <- Morning]),
    {ok, Afternoon} = muse_workspace:events(?O, #{<<"timeMin">> => muse_workspace:at_local(11, 45)}),
    ?assertEqual([<<"event-lunch">>], [Id || #{<<"id">> := Id} <- Afternoon]),
    {ok, []} = muse_workspace:events(?O, #{<<"calendarId">> => <<"other">>}),
    %% all-day event covers its local date
    _ = muse_store:put(?O, <<"events">>, #{<<"id">> => <<"allday">>, <<"calendarId">> => <<"primary">>,
                                          <<"allDay">> => true, <<"start">> => <<"2030-01-02">>,
                                          <<"end">> => <<"2030-01-03">>, <<"timeZone">> => <<"Asia/Shanghai">>}),
    {ok, [#{<<"id">> := <<"allday">>}]} =
        muse_workspace:events(?O, #{<<"timeMin">> => <<"2030-01-01T16:00:00Z">>,
                                     <<"timeMax">> => <<"2030-01-02T16:00:00Z">>}),
    {ok, []} = muse_workspace:events(?O, #{<<"timeMin">> => <<"2030-01-02T16:00:00Z">>,
                                            <<"timeMax">> => <<"2030-01-03T16:00:00Z">>}),
    ok = muse_store:remove(?O, <<"events">>, <<"allday">>),
    {ok, [#{<<"id">> := <<"primary">>, <<"accessRole">> := <<"owner">>}]} = muse_workspace:calendars(?O).

snapshot_shape() ->
    {ok, S} = muse_workspace:snapshot(?O, undefined),
    ?assertMatch(#{<<"mode">> := <<"sample">>,
                   <<"profile">> := #{<<"name">> := <<"Alex">>, <<"email">> := <<"alex@example.com">>},
                   <<"runtime">> := #{<<"provider">> := <<"sample">>, <<"configured">> := true,
                                      <<"openbotConfigured">> := false, <<"richThreads">> := true}}, S),
    [Google, Browser, Openbot] = maps:get(<<"connections">>, S),
    ?assertMatch(#{<<"status">> := <<"sample">>, <<"account">> := <<"alex@example.com">>,
                   <<"capabilities">> := [<<"Gmail">>, <<"Calendar">>]}, Google),
    ?assertMatch(#{<<"status">> := <<"unconfigured">>}, Browser),
    ?assertMatch(#{<<"id">> := <<"openbot">>}, Openbot),
    ?assertEqual(4, length(maps:get(<<"mail">>, S))),
    {ok, Q} = muse_workspace:snapshot(?O, <<"BLUEBIRD">>),
    ?assertEqual([<<"mail-design">>], [Id || #{<<"id">> := Id} <- maps:get(<<"mail">>, Q)]).

sections() ->
    {ok, M} = muse_workspace:section_snapshot(?O, <<"mail">>),
    ?assertEqual([<<"mail">>], maps:keys(M)),
    {ok, A} = muse_workspace:section_snapshot(?O, <<"all">>),
    ?assertEqual([<<"events">>, <<"files">>, <<"mail">>], lists:sort(maps:keys(A))),
    [F | _] = maps:get(<<"files">>, A),
    ?assertNot(maps:is_key(<<"url">>, F)).

execute_sample() ->
    {ok, <<"Saved to local sent mail · "/utf8, Id/binary>>} =
        muse_workspace:execute(?O, #{<<"kind">> => <<"email.send">>,
                                     <<"data">> => #{<<"to">> => [<<"office@lincoln.example">>],
                                                     <<"subject">> => <<"Re: slip">>, <<"body">> => <<"Done">>,
                                                     <<"attachmentIds">> => [], <<"threadId">> => <<"trip-thread">>}},
                               undefined, undefined),
    ?assertMatch(#{<<"label">> := <<"Sent · local"/utf8>>, <<"threadId">> := <<"trip-thread">>},
                 muse_store:get(?O, <<"mail">>, Id)),
    %% sent mail is excluded from search but appears in the thread
    {ok, Hits} = muse_workspace:search_mail(?O, <<"done">>),
    ?assertEqual([], [X || #{<<"id">> := X} <- Hits, X =:= Id]),
    {ok, Thread} = muse_workspace:thread(?O, <<"trip-thread">>),
    ?assertEqual(2, length(Thread)),
    Event = #{<<"calendarId">> => <<"primary">>, <<"title">> => <<"T">>, <<"start">> => <<"2030-01-01T10:00:00Z">>,
              <<"end">> => <<"2030-01-01T11:00:00Z">>, <<"allDay">> => false},
    {ok, <<"Saved to local calendar · "/utf8, EvId/binary>>} =
        muse_workspace:execute(?O, #{<<"kind">> => <<"calendar.create">>, <<"data">> => Event}, undefined, undefined),
    {ok, _} = muse_workspace:execute(?O, #{<<"kind">> => <<"calendar.update">>,
                                           <<"data">> => Event#{<<"eventId">> => EvId, <<"title">> => <<"T2">>}},
                                     undefined, undefined),
    ?assertMatch(#{<<"title">> := <<"T2">>}, muse_store:get(?O, <<"events">>, EvId)),
    {ok, <<"Removed from local calendar">>} =
        muse_workspace:execute(?O, #{<<"kind">> => <<"calendar.delete">>,
                                     <<"data">> => #{<<"calendarId">> => <<"primary">>, <<"eventId">> => EvId,
                                                     <<"title">> => <<"T2">>}}, undefined, undefined),
    ?assertEqual(undefined, muse_store:get(?O, <<"events">>, EvId)).

prepare() ->
    Missing = muse_ids:uuid(),
    ?assertEqual({error, {404, <<"File not found">>}},
                 muse_workspace:prepare(?O, #{<<"kind">> => <<"email.send">>,
                                              <<"data">> => #{<<"attachmentIds">> => [Missing]}}, undefined)),
    Input = #{<<"kind">> => <<"calendar.delete">>, <<"data">> => #{<<"eventId">> => <<"e">>}},
    ?assertEqual({ok, #{input => Input}}, muse_workspace:prepare(?O, Input, undefined)).

attachments_and_drafts() ->
    [#{<<"attachments">> := [FileId]}] =
        [M || M = #{<<"id">> := <<"mail-fieldtrip">>} <- muse_store:list(?O, <<"mail">>)],
    %% sample attachments are artifact ids, not Gmail references
    ?assertEqual({error, {400, <<"Attachment reference is invalid">>}}, muse_workspace:import_attachment(?O, FileId)),
    {ok, #{<<"id">> := D, <<"createdAt">> := C}} = muse_workspace:save_draft(?O, #{<<"subject">> => <<"s">>}),
    {ok, #{<<"subject">> := <<"t">>, <<"createdAt">> := C}} =
        muse_workspace:save_draft(?O, #{<<"id">> => D, <<"subject">> => <<"t">>}),
    ?assertEqual({error, {404, <<"Draft not found">>}}, muse_workspace:save_draft(?O, #{<<"id">> => <<"zz">>})),
    ?assertEqual(1, length(muse_workspace:drafts(?O))).

disconnected() ->
    _ = muse_store:put(?O, <<"settings">>, #{<<"id">> => <<"google">>, <<"enabled">> => false}),
    try
        ?assertEqual(undefined, muse_workspace:connection(?O)),
        ?assertEqual({error, {409, <<"Google is disconnected">>}}, muse_workspace:search_mail(?O, <<>>)),
        ?assertEqual({ok, []}, muse_workspace:events(?O, #{})),
        ?assertEqual({ok, undefined}, muse_workspace:events_page(?O, #{})),
        {ok, S} = muse_workspace:snapshot(?O, undefined),
        ?assertEqual([], maps:get(<<"mail">>, S)),
        [#{<<"status">> := <<"disconnected">>} | _] = maps:get(<<"connections">>, S)
    after
        muse_store:put(?O, <<"settings">>, #{<<"id">> => <<"google">>, <<"enabled">> => true})
    end.
