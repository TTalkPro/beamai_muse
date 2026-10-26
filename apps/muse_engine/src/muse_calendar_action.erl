%% @doc The `calendar.event` action kind (muse_action_kind): the agent's
%% writes to the built-in calendar (muse_calendar) go through a separate
%% user review, like every external write. The user's own changes on the
%% `/calendar` page and through the JSON API are direct.
%%
%% `data` is `{operation: create | update | delete, eventId?, calendarId?,
%% title?, start?, end?, allDay?, location?, notes?, rrule?, status?}`;
%% `calendarName` and `previous` are filled in by `prepare/2` for the review
%% card and are ignored from the caller.
%%
%% - `prepare/2` resolves the proposal against the owner's calendar: a
%%   create is normalised in full (defaults, the calendar must be the
%%   owner's); an update or delete must name one of the owner's events,
%%   whose current record becomes the reviewed `target` and its `updatedAt`
%%   the `target_version`. An update's data is the whole event after the
%%   change (so the card and the hash show exactly what will be written),
%%   with `previous`, the event before it.
%% - `display/1` gives the card in Chinese: "新建日程：…", "修改日程：…",
%%   "删除日程：…" with 时间, 原时间, 日历, 地点, 重复, 状态, 备注.
%% - `execute/3` applies it with the reviewed version as a precondition:
%%   if the event changed (or went away) since the review it refuses with
%%   409 and changes nothing. The receipt names the event and its time.
%% - `tool/0`: the task model's `prepare_calendar_change`.
%%
%% Registered by muse_engine_app at start (`register/0`).
-module(muse_calendar_action).
-behaviour(muse_action_kind).

-export([register/0, unregister/0, kind/0, schema/0, input_schema/0, display/1, prepare/2, execute/3, tool/0,
         description/0]).

-define(KIND, <<"calendar.event">>).

-spec kind() -> binary().
kind() -> ?KIND.

-spec register() -> ok.
register() ->
    muse_actions:register_kind(?KIND, ?MODULE).

-spec unregister() -> ok.
unregister() ->
    muse_actions:unregister_kind(?KIND).

%% @doc What a caller proposes (the chat tool's parameters).
-spec input_schema() -> muse_validate:schema().
input_schema() ->
    {object, input_fields()}.

input_fields() ->
    [{<<"operation">>, {desc, <<"create, update or delete">>, {enum, [<<"create">>, <<"update">>, <<"delete">>]}}},
     {<<"eventId">>, {optional, {desc, <<"The event to update or delete (eventId from read_calendar)">>,
                                 {string, #{min => 1, max => 100}}}}},
     {<<"calendarId">>, {optional, {desc, <<"Calendar id from read_calendar (default: the first calendar)">>,
                                    {string, #{min => 1, max => 100}}}}},
     {<<"title">>, {optional, {string, #{trim => true, min => 1, max => 200, single_line => true}}}},
     {<<"start">>, {optional, {desc, <<"Local start without a zone: YYYY-MM-DDTHH:MM, or YYYY-MM-DD for an all-day "
                                       "event">>, {string, #{trim => true, max => 30}}}}},
     {<<"end">>, {optional, {desc, <<"Local end, exclusive, same form as start (default: one hour, or one day for "
                                     "all-day; an update that only moves start keeps the duration)">>,
                             {string, #{trim => true, max => 30}}}}},
     {<<"allDay">>, {optional, boolean}},
     {<<"location">>, {optional, {string, #{trim => true, max => 200}}}},
     {<<"notes">>, {optional, {string, #{max => 4000}}}},
     {<<"rrule">>, {optional, {desc, <<"Repeat: none, daily, weekly, monthly or yearly">>,
                               {enum, [<<"none">>, <<"daily">>, <<"weekly">>, <<"monthly">>, <<"yearly">>]}}}},
     {<<"status">>, {optional, {enum, [<<"confirmed">>, <<"tentative">>, <<"cancelled">>]}}}].

%% @doc The stored data: the input plus what `prepare/2` adds for review.
-spec schema() -> muse_validate:schema().
schema() ->
    {object, input_fields()
     ++ [{<<"calendarName">>, {optional, {desc, <<"Filled in by the server; leave out">>,
                                          {string, #{max => 100}}}}},
         {<<"previous">>, {optional, {desc, <<"Filled in by the server; leave out">>,
                                      {object, [{<<"title">>, {string, #{}}},
                                                {<<"start">>, {string, #{}}},
                                                {<<"end">>, {string, #{}}},
                                                {<<"allDay">>, boolean},
                                                {<<"calendarName">>, {optional, {string, #{}}}},
                                                {<<"location">>, {optional, {string, #{}}}},
                                                {<<"rrule">>, {optional, {string, #{}}}}]}}}}]}.

-spec description() -> binary().
description() ->
    <<"Propose creating, updating or deleting an event in the person's built-in calendar (日程). Nothing "
      "changes until the person approves it in a separate review. Times are local without a zone "
      "(YYYY-MM-DDTHH:MM, or YYYY-MM-DD with allDay); end is exclusive. For update and delete pass the eventId "
      "from read_calendar; an update only needs the fields that change."/utf8>>.

-spec tool() -> muse_action_kind:tool().
tool() ->
    %% the task model titles its timeline steps with the description: short;
    %% the parameters describe the time format
    #{name => <<"prepare_calendar_change">>,
      description => <<"Prepare a change to the built-in calendar (日程) for a separate user review"/utf8>>}.

event_fields() ->
    [<<"calendarId">>, <<"title">>, <<"start">>, <<"end">>, <<"allDay">>, <<"location">>, <<"notes">>,
     <<"rrule">>, <<"status">>].

-spec prepare(binary(), map()) ->
          {ok, #{data := map(), target => map(), target_version => binary()}} | {error, {pos_integer(), binary()}}.
prepare(Owner, #{<<"operation">> := <<"create">>} = Data) ->
    maybe
        {ok, Fields} ?= muse_calendar:prepare_event(Owner, new, maps:with(event_fields(), Data)),
        {ok, #{data => reviewed(Owner, <<"create">>, Fields)}}
    end;
prepare(Owner, #{<<"operation">> := Op} = Data) ->
    maybe
        {ok, Id} ?= case maps:get(<<"eventId">>, Data, undefined) of
                        undefined -> {error, {422, <<"eventId is required to update or delete an event">>}};
                        I -> {ok, I}
                    end,
        {ok, Current} ?= muse_calendar:get_event(Owner, Id),
        {ok, Fields} ?= case Op of
                            <<"update">> -> muse_calendar:prepare_event(Owner, Current,
                                                                        maps:with(event_fields(), Data));
                            <<"delete">> -> {ok, #{}}
                        end,
        Reviewed = case Op of
                       <<"update">> -> reviewed(Owner, Op, Fields);
                       <<"delete">> -> #{<<"operation">> => Op}
                   end,
        {ok, #{data => Reviewed#{<<"eventId">> => Id, <<"previous">> => previous(Owner, Current)},
               target => Current,
               target_version => maps:get(<<"updatedAt">>, Current)}}
    end.

reviewed(Owner, Op, Fields) ->
    (maps:merge(#{<<"rrule">> => <<"none">>}, Fields))#{<<"operation">> => Op,
                                                         <<"calendarName">> => calendar_name(Owner, Fields)}.

previous(Owner, Event) ->
    maps:merge(maps:with([<<"title">>, <<"start">>, <<"end">>, <<"allDay">>, <<"location">>, <<"rrule">>], Event),
               #{<<"calendarName">> => calendar_name(Owner, Event)}).

calendar_name(Owner, #{<<"calendarId">> := Id}) ->
    case muse_calendar:get_calendar(Owner, Id) of
        {ok, #{<<"name">> := N}} -> N;
        _ -> <<>>
    end;
calendar_name(_Owner, _) ->
    <<>>.

-spec display(map()) -> muse_action_kind:display().
display(#{<<"operation">> := <<"delete">>} = Data) ->
    P = maps:get(<<"previous">>, Data, #{}),
    #{title => <<"删除日程："/utf8, (maps:get(<<"title">>, P, maps:get(<<"eventId">>, Data, <<>>)))/binary>>,
      fields => [{<<"时间"/utf8>>, muse_calendar:describe_time(P)},
                 {<<"日历"/utf8>>, maps:get(<<"calendarName">>, P, <<>>)},
                 {<<"地点"/utf8>>, maps:get(<<"location">>, P, <<>>)}]};
display(#{<<"operation">> := Op} = Data) ->
    Title = maps:get(<<"title">>, Data, <<>>),
    Prefix = case Op of
                 <<"create">> -> <<"新建日程："/utf8>>;
                 _ -> <<"修改日程："/utf8>>
             end,
    Time = muse_calendar:describe_time(Data),
    P = maps:get(<<"previous">>, Data, #{}),
    Was = fun(Key, Label, Now, Then) ->
                  case maps:is_key(Key, P) andalso Then =/= Now of
                      true -> [{Label, Then}];
                      false -> []
                  end
          end,
    #{title => <<Prefix/binary, Title/binary>>,
      fields => [{<<"时间"/utf8>>, Time}]
          ++ Was(<<"start">>, <<"原时间"/utf8>>, Time, muse_calendar:describe_time(P))
          ++ Was(<<"title">>, <<"原标题"/utf8>>, Title, maps:get(<<"title">>, P, <<>>))
          ++ [{<<"日历"/utf8>>, maps:get(<<"calendarName">>, Data, <<>>)}]
          ++ Was(<<"calendarName">>, <<"原日历"/utf8>>, maps:get(<<"calendarName">>, Data, <<>>),
                 maps:get(<<"calendarName">>, P, <<>>))
          ++ [{<<"地点"/utf8>>, maps:get(<<"location">>, Data, <<>>)},
              {<<"重复"/utf8>>, case maps:get(<<"rrule">>, Data, <<"none">>) of
                                    <<"none">> -> <<>>;
                                    R -> muse_calendar:repeat_label(R)
                                end},
              {<<"状态"/utf8>>, case maps:get(<<"status">>, Data, <<"confirmed">>) of
                                    <<"confirmed">> -> <<>>;
                                    S -> muse_calendar:status_label(S)
                                end},
              {<<"备注"/utf8>>, maps:get(<<"notes">>, Data, <<>>)}]}.

-spec execute(binary(), map(), muse_action_kind:review()) ->
          {ok, binary()} | {error, {pos_integer() | outcome_unknown | internal, binary()}}.
execute(Owner, #{<<"operation">> := <<"create">>} = Data, _Review) ->
    case muse_calendar:create_event(Owner, maps:with(event_fields(), Data), <<"agent">>) of
        {ok, Event} -> {ok, receipt(<<"已新建日程"/utf8>>, Event)};
        {error, _} = E -> E
    end;
execute(Owner, #{<<"operation">> := <<"update">>, <<"eventId">> := Id} = Data, Review) ->
    case muse_calendar:update_event(Owner, Id, maps:with(event_fields(), Data), expect(Review)) of
        {ok, Event} -> {ok, receipt(<<"已修改日程"/utf8>>, Event)};
        {error, _} = E -> E
    end;
execute(Owner, #{<<"operation">> := <<"delete">>, <<"eventId">> := Id} = Data, Review) ->
    case muse_calendar:delete_event(Owner, Id, expect(Review)) of
        ok -> {ok, receipt(<<"已删除日程"/utf8>>, maps:get(<<"previous">>, Data, #{}))};
        {error, _} = E -> E
    end;
execute(_Owner, _Data, _Review) ->
    {error, {422, <<"eventId is required to update or delete an event">>}}.

%% No reviewed version means the proposal was not prepared: refuse.
expect(#{target_version := V}) -> #{expect => V};
expect(_) -> #{expect => <<"unreviewed">>}.

receipt(What, Event) ->
    <<What/binary, "「"/utf8, (maps:get(<<"title">>, Event, <<>>))/binary, "」 · "/utf8,
      (muse_calendar:describe_time(Event))/binary>>.
