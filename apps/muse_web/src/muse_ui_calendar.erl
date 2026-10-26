%% @doc The calendar page `/calendar` (日程, tasks/M9-workspace.md M9-7),
%% after the aihtml example port of sigil's calendar app
%% (aihtml_example_calendar_app): a header with "新建日程", a rail with the
%% calendars and what comes up in the next 30 days, and the `ah_calendar`
%% (month, week, day, list; Monday first; Chinese labels; 24-hour clock).
%%
%% Data is muse_calendar's. Every interaction is the user's own change, so
%% it is written directly (the agent's changes go through review instead,
%% muse_calendar_action):
%%
%% - navigating fires `change` with the visible range (`data-start`,
%%   `data-end`); `range` answers with the events of that range
%%   (`set_events`, lazy loading). The first render carries the events
%%   around the shown date. `/calendar?date=YYYY-MM-DD&view=week` URLs come
%%   from the component's `href` template, so every view has an address.
%% - "新建日程" and selecting a range (`ah:select`) open the event form,
%%   prefilled with the range; clicking an event (`ah:event-click`, or an
%%   upcoming item) opens it for editing, with delete (a danger confirm).
%%   For an all-day event the form's end date is inclusive.
%% - dragging and resizing (`ah:event-drop`, `ah:event-resize`) reschedule
%%   the event at once (a whole series for a repeating one, as the
%%   component moves it); a refused move reloads the range.
%% - the rail's checkboxes show and hide a calendar (persisted, `visible`);
%%   the pencil opens the calendar form: name, colour, and delete, which
%%   asks what happens to the calendar's events (move to another calendar
%%   or delete them) behind a danger confirm.
%%
%% After a change the rail is re-rendered and a `change` is triggered on
%% the calendar, so it reloads its own range. Changes from elsewhere (the
%% agent's approved actions, the API, another tab) arrive as muse_events
%% `{calendar, Id}`; `on_event/2` does the same for every page following
%% the owner's `calendar` topic.
-module(muse_ui_calendar).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4, labels/0]).

-define(K, muse_ui_a_kit).
-define(I, muse_ui_icons).
-define(CAL, <<"cal">>).
-define(RAIL, <<"cal-rail">>).
-define(EVENT_WIN, <<"cal-event-window">>).
-define(EVENT_FORM, <<"cal-event-form">>).
-define(CAL_WIN, <<"cal-cal-window">>).
-define(CAL_FORM, <<"cal-cal-form">>).
-define(VIEWS, [<<"month">>, <<"week">>, <<"day">>, <<"list">>]).
-define(HREF, <<"/calendar?date={date}&view={view}">>).

%%%===================================================================
%%% Page
%%%===================================================================

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    Qs = cowboy_req:parse_qs(Req),
    Date = case proplists:get_value(<<"date">>, Qs) of
               D when is_binary(D) ->
                   case muse_calendar:parse_time(D) of
                       {date, _} -> D;
                       _ -> muse_calendar:today()
                   end;
               _ -> muse_calendar:today()
           end,
    View = case proplists:get_value(<<"view">>, Qs) of
               V when is_binary(V) ->
                   case lists:member(V, ?VIEWS) of
                       true -> binary_to_atom(V);
                       false -> month
                   end;
               _ -> month
           end,
    {<<"日程"/utf8>>, page(Owner, Date, View)}.

page(Owner, Date, View) ->
    ah_div([?K:page_head(<<"日程"/utf8>>,
                         [ah_button([?I:icon(plus, 16), <<"新建日程"/utf8>>], new, [primary, sm],
                                    [{type, button}, {id, <<"cal-new">>},
                                     on(click, {?MODULE, new_event, #{}})])]),
            ah_div([ah_div(rail(Owner), [<<"muse-cal-rail">>],
                           [{id, ?RAIL}, subscribe(muse_ui:topic(Owner, calendar),
                                                   #{refresh => {?MODULE, refresh, #{}}})]),
                    ah_div(calendar_view(Owner, Date, View), [<<"muse-cal-main">>], [])],
                   [<<"muse-cal-layout">>], []),
            event_window(Owner),
            calendar_window()],
           [<<"muse-page muse-cal-page">>], [{id, <<"calendar">>}]).

calendar_view(Owner, Date, View) ->
    %% the events around the date cover every view (a month grid is at most
    %% six weeks, the list 30 days); later ranges load on `change`
    From = muse_calendar:add_days(Date, -42),
    To = muse_calendar:add_days(Date, 43),
    ah_calendar(Date, [editable, selectable],
                [{id, ?CAL}, {view, View}, {first_day, 1}, {day_max_events, 3}, {agenda_days, 30},
                 {height, 680}, {hour_format, 24}, {href, ?HREF}, {labels, labels()},
                 {events, component_events(Owner, From, To)},
                 on(change, {?MODULE, range, #{}}),
                 on('ah:range', {?MODULE, range, #{}}),
                 on('ah:event-click', {?MODULE, edit_event, #{}}),
                 on('ah:event-drop', {?MODULE, move_event, #{}}),
                 on('ah:event-resize', {?MODULE, move_event, #{}}),
                 on('ah:select', {?MODULE, select, #{}})]).

%% @doc The calendar's Chinese texts (weekdays from Sunday, as the
%% component wants them; the week starts on Monday through `first_day`).
-spec labels() -> map().
labels() ->
    Months = [<<(integer_to_binary(M))/binary, "月"/utf8>> || M <- lists:seq(1, 12)],
    #{today => <<"今天"/utf8>>, prev => <<"上一页"/utf8>>, next => <<"下一页"/utf8>>,
      month => <<"月"/utf8>>, week => <<"周"/utf8>>, day => <<"日"/utf8>>, list => <<"列表"/utf8>>,
      all_day => <<"全天"/utf8>>, all_day_short => <<"全天"/utf8>>, more => <<"还有 {n} 项"/utf8>>,
      no_events => <<"这段时间没有日程"/utf8>>, no_events_hint => <<"点“新建日程”添加一个"/utf8>>,
      am => <<"上午"/utf8>>, pm => <<"下午"/utf8>>,
      months => Months, months_short => Months,
      weekdays => [<<"星期日"/utf8>>, <<"星期一"/utf8>>, <<"星期二"/utf8>>, <<"星期三"/utf8>>,
                   <<"星期四"/utf8>>, <<"星期五"/utf8>>, <<"星期六"/utf8>>],
      weekdays_short => [<<"日"/utf8>>, <<"一"/utf8>>, <<"二"/utf8>>, <<"三"/utf8>>, <<"四"/utf8>>,
                         <<"五"/utf8>>, <<"六"/utf8>>],
      title_month => <<"yyyy年M月"/utf8>>, title_day => <<"yyyy年M月d日 EEEE"/utf8>>,
      range_start => <<"yyyy年M月d日"/utf8>>, range_end => <<"M月d日"/utf8>>,
      list_date => <<"M月d日"/utf8>>}.

%% Events of visible calendars for the component.
component_events(Owner, From, To) ->
    [maps:merge(#{id => Id, title => maps:get(<<"title">>, E), start => maps:get(<<"start">>, E),
                  'end' => maps:get(<<"end">>, E), all_day => maps:get(<<"allDay">>, E, false),
                  color => maps:get(<<"color">>, E), status => maps:get(<<"status">>, E, <<"confirmed">>)},
                case muse_calendar:rrule_freq(maps:get(<<"rrule">>, E, <<"none">>)) of
                    undefined -> #{};
                    R -> #{rrule => R}
                end)
     || #{<<"id">> := Id} = E <- muse_calendar:events_between(Owner, From, To, #{visible_only => true})].

%%%===================================================================
%%% Rail
%%%===================================================================

rail(Owner) ->
    Cals = muse_calendar:calendars(Owner),
    [ah_section([ah_div([ah_h2(<<"我的日历"/utf8>>, [<<"muse-section-title">>], []),
                         ah_button(?I:icon(plus, 16), add, [<<"muse-iconbtn muse-iconbtn-sm">>],
                                   [{type, button}, {id, <<"cal-add-calendar">>}, {aria_label, <<"添加日历"/utf8>>},
                                    {title, <<"添加日历"/utf8>>}, on(click, {?MODULE, new_calendar, #{}})])],
                        [<<"muse-cal-rail-head">>], []),
                 ah_ul([calendar_row(C) || C <- Cals], [<<"muse-cal-list">>], [{id, <<"cal-calendars">>}])],
                [<<"muse-cal-box">>], []),
     ah_section([ah_div(ah_h2(<<"接下来 30 天"/utf8>>, [<<"muse-section-title">>], []), [<<"muse-cal-rail-head">>], []),
                 upcoming(Owner)],
                [<<"muse-cal-box">>], [])].

calendar_row(#{<<"id">> := Id, <<"name">> := Name, <<"color">> := Color} = C) ->
    ah_li([ah_checkbox([dot(Color), ah_span(Name, [<<"muse-cal-name">>], [])], <<"true">>, [<<"muse-cal-toggle">>],
                       [{id, <<"cal-show-", Id/binary>>}, {checked, maps:get(<<"visible">>, C, true) =:= true},
                        on(change, {?MODULE, toggle_calendar, #{id => Id}})]),
           ah_button(?I:icon(pencil, 14), edit, [<<"muse-iconbtn muse-iconbtn-sm muse-cal-edit">>],
                     [{type, button}, {aria_label, <<"编辑日历"/utf8>>}, {title, <<"编辑日历"/utf8>>},
                      on(click, {?MODULE, edit_calendar, #{id => Id}})])],
          [<<"muse-cal-row">>], [{id, <<"cal-row-", Id/binary>>}, {data_visible, atom_to_binary(maps:get(<<"visible">>, C, true) =:= true)}]).

dot(Color) ->
    ah_span([], [<<"muse-cal-dot">>], [{style, [<<"background-color:">>, Color]}]).

%% The next occurrence of each event (a daily series shows once).
upcoming(Owner) ->
    Next = lists:foldl(fun(#{<<"eventId">> := Id} = E, Acc) ->
                               case lists:any(fun(#{<<"eventId">> := I}) -> I =:= Id end, Acc) of
                                   true -> Acc;
                                   false -> Acc ++ [E]
                               end
                       end, [], muse_calendar:upcoming(Owner, 30, 200)),
    case lists:sublist(Next, 12) of
        [] ->
            ah_p(<<"接下来 30 天没有安排。"/utf8>>, [<<"text-sm text-muted">>], [{id, <<"cal-upcoming">>}]);
        Items ->
            ah_ul([ah_li(aihtml:ah_el(button,
                                      [ah_div([ah_div(day_label(maps:get(<<"start">>, E)), [<<"muse-cal-up-day">>], []),
                                               ah_div([time_label(E), <<" · "/utf8>>, maps:get(<<"title">>, E)],
                                                      [<<"muse-cal-up-title">>], [])],
                                              [<<"min-w-0 flex-1">>], []),
                                       dot(maps:get(<<"color">>, E))],
                                      [<<"muse-cal-up">>],
                                      [{type, button},
                                       on(click, {?MODULE, edit_event, #{id => maps:get(<<"eventId">>, E)}})]),
                         [], [])
                   || E <- Items],
                  [<<"muse-cal-upcoming">>], [{id, <<"cal-upcoming">>}])
    end.

day_label(<<Day:10/binary, _/binary>>) ->
    Today = muse_calendar:today(),
    Tomorrow = muse_calendar:add_days(Today, 1),
    case Day of
        Today -> <<"今天"/utf8>>;
        Tomorrow -> <<"明天"/utf8>>;
        _ ->
            <<_:4/binary, "-", M:2/binary, "-", D:2/binary>> = Day,
            {date, Min} = muse_calendar:parse_time(Day),
            W = element(calendar:day_of_the_week(calendar:gregorian_days_to_date(Min div 1440)),
                        {<<"周一"/utf8>>, <<"周二"/utf8>>, <<"周三"/utf8>>, <<"周四"/utf8>>, <<"周五"/utf8>>,
                         <<"周六"/utf8>>, <<"周日"/utf8>>}),
            <<(integer_to_binary(binary_to_integer(M)))/binary, "月"/utf8,
              (integer_to_binary(binary_to_integer(D)))/binary, "日 "/utf8, W/binary>>
    end.

time_label(#{<<"allDay">> := true}) -> <<"全天"/utf8>>;
time_label(#{<<"start">> := <<_:11/binary, Clock:5/binary, _/binary>>}) -> Clock;
time_label(_) -> <<>>.

%%%===================================================================
%%% Event form
%%%===================================================================

event_window(Owner) ->
    ah_window(event_form(Owner, new, new_values(Owner)), [],
              [{id, ?EVENT_WIN}, {title, <<"新建日程"/utf8>>}, {modal, true}, {width, 560},
               {draggable, false}, {resizable, false}, {close_on_overlay, true}]).

%% Values of a new event: the next full hour today.
new_values(Owner) ->
    Now = muse_calendar:now_local(),
    Start = Now - Now rem 60 + 60,
    #{<<"title">> => <<>>, <<"calendarId">> => first_visible(Owner),
      <<"start">> => muse_calendar:format_time(Start, false),
      <<"end">> => muse_calendar:format_time(Start + 60, false),
      <<"allDay">> => false, <<"location">> => <<>>, <<"notes">> => <<>>, <<"rrule">> => <<"none">>}.

first_visible(Owner) ->
    Cals = muse_calendar:calendars(Owner),
    case [Id || #{<<"id">> := Id, <<"visible">> := true} <- Cals] ++ [Id || #{<<"id">> := Id} <- Cals] of
        [Id | _] -> Id;
        [] -> <<>>
    end.

%% The form's values of a stored event: datetime fields, an all-day end
%% shown inclusive.
event_values(#{<<"allDay">> := true, <<"start">> := S, <<"end">> := E} = Ev) ->
    Last = case muse_calendar:add_days(E, -1) of
               L when L >= S -> L;
               _ -> S
           end,
    Ev#{<<"start">> => <<S/binary, "T09:00">>, <<"end">> => <<Last/binary, "T10:00">>};
event_values(Ev) ->
    Ev.

event_form(Owner, Mode, Values) ->
    V = fun(K) -> maps:get(K, Values, <<>>) end,
    {Ref, Submit, Delete} =
        case Mode of
            new -> {{?MODULE, save_event, #{id => new}}, <<"创建"/utf8>>, []};
            {edit, Id} ->
                {{?MODULE, save_event, #{id => Id}}, <<"保存"/utf8>>,
                 ah_button([?I:icon(trash, 16), <<"删除"/utf8>>], delete, [borderless, sm, <<"muse-cal-danger">>],
                           [{type, button}, {id, <<"cal-event-delete">>},
                            on(click, {?MODULE, delete_event, #{id => Id}},
                               #{confirm => #{title => <<"删除日程"/utf8>>,
                                              body => <<"删除这个日程？重复的日程会整个删除，无法恢复。"/utf8>>,
                                              ok => <<"删除"/utf8>>, cancel => <<"取消"/utf8>>,
                                              variant => danger}})])}
        end,
    Calendars = [{Id, Name} || #{<<"id">> := Id, <<"name">> := Name} <- muse_calendar:calendars(Owner)],
    Repeats = [{R, muse_calendar:repeat_label(R)} || R <- [<<"none">>, <<"daily">>, <<"weekly">>, <<"monthly">>,
                                                          <<"yearly">>]],
    DateTime = fun(Name, Value) ->
                       ah_datetime_input(Value, [show_time],
                                         [{name, Name}, {id, <<"cal-f-", Name/binary>>},
                                          {format, <<"yyyy-MM-dd HH:mm">>}, {first_day, 1}])
               end,
    ah_form([ah_div([], [], [{id, <<"cal-event-error">>}]),
             ah_field(<<"标题"/utf8>>,
                      ah_input(V(<<"title">>), [<<"w-full">>],
                               [{name, title}, {id, <<"cal-f-title">>}, {maxlength, 200}, {autocomplete, off},
                                {placeholder, <<"例如：产品评审"/utf8>>}]),
                      [top], [{for, <<"cal-f-title">>}]),
             ah_field(<<"日历"/utf8>>,
                      ah_select(Calendars, V(<<"calendarId">>), [], [{name, calendar}, {id, <<"cal-f-calendar">>}]),
                      [top], [{for, <<"cal-f-calendar">>}]),
             ah_div([ah_field(<<"开始"/utf8>>, DateTime(<<"start">>, V(<<"start">>)), [top], []),
                     ah_field(<<"结束"/utf8>>, DateTime(<<"end">>, V(<<"end">>)), [top], [])],
                    [<<"grid gap-4 sm:grid-cols-2">>], []),
             ah_div([ah_checkbox(<<"全天"/utf8>>, <<"true">>, [],
                                 [{name, all_day}, {id, <<"cal-f-allday">>}, {checked, V(<<"allDay">>) =:= true}]),
                     ah_span(<<"全天日程只看日期，结束日期包含在内。"/utf8>>, [<<"text-xs text-muted">>], [])],
                    [<<"flex flex-wrap items-center gap-3">>], []),
             ah_field(<<"地点"/utf8>>,
                      ah_input(V(<<"location">>), [<<"w-full">>],
                               [{name, location}, {id, <<"cal-f-location">>}, {maxlength, 200}, {autocomplete, off}]),
                      [top], [{for, <<"cal-f-location">>}]),
             ah_field(<<"重复"/utf8>>,
                      ah_select(Repeats, case V(<<"rrule">>) of <<>> -> <<"none">>; R -> R end, [],
                                [{name, repeat}, {id, <<"cal-f-repeat">>}]),
                      [top], [{for, <<"cal-f-repeat">>}]),
             ah_field(<<"备注"/utf8>>,
                      ah_textarea(V(<<"notes">>), [<<"w-full">>], [{name, notes}, {id, <<"cal-f-notes">>}, {rows, 3}]),
                      [top], [{for, <<"cal-f-notes">>}]),
             ah_div([Delete, ah_span([], [<<"flex-1">>], []),
                     ah_button(<<"取消"/utf8>>, cancel, [outlined, sm], [{type, button} | closes({id, ?EVENT_WIN})]),
                     ah_button(Submit, save, [primary, sm], [{type, submit}, {id, <<"cal-event-save">>}])],
                    [<<"muse-cal-form-actions">>], [])],
            [<<"flex flex-col gap-4">>],
            [{id, ?EVENT_FORM}, on(submit, Ref, #{prevent_default => true})]).

%% The form, filled in, in the window, which then opens.
open_event_form(Ctx, Owner, Mode, Values) ->
    aihtml_action:html(Ctx, {id, ?EVENT_FORM}, event_form(Owner, Mode, Values), outer),
    aihtml_window:set_title(Ctx, {id, ?EVENT_WIN},
                            case Mode of new -> <<"新建日程"/utf8>>; _ -> <<"编辑日程"/utf8>> end),
    aihtml_lib_overlay:open(Ctx, {id, ?EVENT_WIN}).

%% The event a submitted form describes (muse_calendar's input).
form_event(Event) ->
    Text = fun(K) -> ?K:form_text(Event, K) end,
    AllDay = Text(<<"all_day">>) =:= <<"true">>,
    Time = fun(K) -> binary:replace(Text(K), <<" ">>, <<"T">>) end,
    {Start, End} = case AllDay of
                       true ->
                           S = date_part(Time(<<"start">>)),
                           E = case date_part(Time(<<"end">>)) of
                                   <<>> -> S;
                                   D -> D
                               end,
                           {S, case muse_calendar:parse_time(E) of
                                   {date, _} -> muse_calendar:add_days(E, 1);
                                   _ -> E
                               end};
                       false -> {Time(<<"start">>), Time(<<"end">>)}
                   end,
    (maps:filter(fun(_, V) -> V =/= <<>> end,
                 #{<<"title">> => Text(<<"title">>), <<"calendarId">> => Text(<<"calendar">>),
                   <<"start">> => Start, <<"end">> => End, <<"rrule">> => Text(<<"repeat">>)}))
        #{<<"allDay">> => AllDay, <<"location">> => Text(<<"location">>),
          <<"notes">> => ?K:form_text(Event, <<"notes">>)}.

date_part(<<D:10/binary, _/binary>>) -> D;
date_part(_) -> <<>>.

%%%===================================================================
%%% Calendar form
%%%===================================================================

calendar_window() ->
    ah_window(ah_div([], [], [{id, ?CAL_FORM}]), [],
              [{id, ?CAL_WIN}, {title, <<"日历"/utf8>>}, {modal, true}, {width, 460},
               {draggable, false}, {resizable, false}, {close_on_overlay, true}]).

calendar_form(Owner, Mode) ->
    {Ref, Name, Color, Extra} =
        case Mode of
            new ->
                Taken = [C || #{<<"color">> := C} <- muse_calendar:calendars(Owner)],
                Free = [C || C <- muse_calendar:palette(), not lists:member(C, Taken)] ++ muse_calendar:palette(),
                {{?MODULE, save_calendar, #{id => new}}, <<>>, hd(Free), []};
            {edit, #{<<"id">> := Id, <<"name">> := N, <<"color">> := C}} ->
                {{?MODULE, save_calendar, #{id => Id}}, N, C, delete_part(Owner, Id)}
        end,
    Palette = [Color || not lists:member(Color, muse_calendar:palette())] ++ muse_calendar:palette(),
    ah_form([ah_div([], [], [{id, <<"cal-cal-error">>}]),
             ah_field(<<"名称"/utf8>>,
                      ah_input(Name, [<<"w-full">>], [{name, name}, {id, <<"cal-c-name">>}, {maxlength, 40},
                                                      {autocomplete, off}, {placeholder, <<"例如：读书"/utf8>>}]),
                      [top], [{for, <<"cal-c-name">>}]),
             ah_field(<<"颜色"/utf8>>,
                      ah_div([ah_radiobutton(ah_span([], [<<"muse-cal-swatch">>], [{style, [<<"background-color:">>, C]}]),
                                             C, [], [{name, color}, {title, C}, {checked, C =:= Color}])
                              || C <- Palette],
                             [<<"flex flex-wrap gap-3">>], []),
                      [top], []),
             Extra,
             ah_div([ah_span([], [<<"flex-1">>], []),
                     ah_button(<<"取消"/utf8>>, cancel, [outlined, sm], [{type, button} | closes({id, ?CAL_WIN})]),
                     ah_button(<<"保存"/utf8>>, save, [primary, sm], [{type, submit}, {id, <<"cal-cal-save">>}])],
                    [<<"muse-cal-form-actions">>], [])],
            [<<"flex flex-col gap-4">>],
            [{id, ?CAL_FORM}, on(submit, Ref, #{prevent_default => true})]).

%% Deleting a calendar: what happens to its events, then the danger confirm.
delete_part(Owner, Id) ->
    Others = [{I, N} || #{<<"id">> := I, <<"name">> := N} <- muse_calendar:calendars(Owner), I =/= Id],
    Count = muse_calendar:count_events(Owner, Id),
    case Others of
        [] -> [];
        [{First, _} | _] ->
            Choice = case Count of
                         0 -> [];
                         _ ->
                             ah_div([ah_p([<<"这个日历里有 "/utf8>>, integer_to_binary(Count), <<" 个日程。删除日历时："/utf8>>],
                                          [<<"text-sm">>], []),
                                     ah_radiobutton(<<"移到"/utf8>>, <<"move">>, [],
                                                    [{name, events}, {checked, true}, {id, <<"cal-c-move">>}]),
                                     ah_select(Others, First, [], [{name, move_to}, {id, <<"cal-c-move-to">>}]),
                                     ah_radiobutton(<<"一并删除这些日程"/utf8>>, <<"delete">>, [],
                                                    [{name, events}, {id, <<"cal-c-delete-events">>}])],
                                    [<<"muse-cal-delete-choice">>], [])
                     end,
            ah_div([Choice,
                    ah_button([?I:icon(trash, 16), <<"删除日历"/utf8>>], delete, [borderless, sm, <<"muse-cal-danger">>],
                              [{type, button}, {id, <<"cal-cal-delete">>},
                               on(click, {?MODULE, delete_calendar, #{id => Id}},
                                  #{confirm => #{title => <<"删除日历"/utf8>>,
                                                 body => <<"删除这个日历？按上面的选择处理其中的日程，无法恢复。"/utf8>>,
                                                 ok => <<"删除"/utf8>>, cancel => <<"取消"/utf8>>,
                                                 variant => danger}})])],
                   [<<"muse-cal-delete">>], [])
    end.

open_calendar_form(Ctx, Owner, Mode) ->
    aihtml_action:html(Ctx, {id, ?CAL_FORM}, calendar_form(Owner, Mode), outer),
    aihtml_window:set_title(Ctx, {id, ?CAL_WIN},
                            case Mode of new -> <<"添加日历"/utf8>>; _ -> <<"编辑日历"/utf8>> end),
    aihtml_lib_overlay:open(Ctx, {id, ?CAL_WIN}).

%%%===================================================================
%%% Actions
%%%===================================================================

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(Name, Args, Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> act(Name, Args, Event, Ctx, Owner) end).

%% The visible range changed: its events.
act(range, _Args, Event, Ctx, Owner) ->
    Data = maps:get(data, Event, #{}),
    case {data(Data, <<"start">>), data(Data, <<"end">>)} of
        {From, To} when is_binary(From), is_binary(To) ->
            case {muse_calendar:parse_time(From), muse_calendar:parse_time(To)} of
                {{_, F}, {_, T}} when T > F, T - F =< 400 * 1440 ->
                    aihtml_calendar:set_events(Ctx, {id, ?CAL}, component_events(Owner, From, To));
                _ -> ok
            end;
        _ -> ok
    end;
act(refresh, _Args, _Event, Ctx, Owner) ->
    refresh(Ctx, Owner);
act(new_event, _Args, _Event, Ctx, Owner) ->
    open_event_form(Ctx, Owner, new, new_values(Owner));
act(select, _Args, Event, Ctx, Owner) ->
    Data = maps:get(data, Event, #{}),
    Values0 = new_values(Owner),
    Values = case {data(Data, <<"from">>), data(Data, <<"to">>), data(Data, <<"allDay">>)} of
                 {From, To, AllDay} when is_binary(From), is_binary(To) ->
                     case AllDay =:= <<"true">> orelse muse_calendar:parse_time(From) of
                         true ->
                             event_values(Values0#{<<"start">> => date_part(From), <<"end">> => date_part(To),
                                                   <<"allDay">> => true});
                         {datetime, _} ->
                             Values0#{<<"start">> => From, <<"end">> => To};
                         _ ->
                             Values0
                     end;
                 _ -> Values0
             end,
    open_event_form(Ctx, Owner, new, Values);
act(edit_event, Args, Event, Ctx, Owner) ->
    Id = case Args of
             #{id := I} -> I;
             _ -> data(maps:get(data, Event, #{}), <<"event">>)
         end,
    case muse_calendar:get_event(Owner, Id) of
        {ok, Ev} -> open_event_form(Ctx, Owner, {edit, Id}, event_values(Ev));
        {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E)), refresh(Ctx, Owner)
    end;
act(save_event, #{id := Id}, Event, Ctx, Owner) ->
    Input = form_event(Event),
    Result = case Id of
                 new -> muse_calendar:create_event(Owner, Input, <<"user">>);
                 _ -> muse_calendar:update_event(Owner, Id, Input, #{})
             end,
    case Result of
        {ok, _} ->
            aihtml_lib_overlay:close(Ctx, {id, ?EVENT_WIN}),
            ?K:toast_ok(Ctx, case Id of new -> <<"日程已创建"/utf8>>; _ -> <<"日程已保存"/utf8>> end),
            refresh(Ctx, Owner);
        {error, E} ->
            aihtml_action:html(Ctx, {id, <<"cal-event-error">>}, ah_alert(?K:error_text(E), [error], []), inner)
    end;
act(delete_event, #{id := Id}, _Event, Ctx, Owner) ->
    case muse_calendar:delete_event(Owner, Id, #{}) of
        ok ->
            aihtml_lib_overlay:close(Ctx, {id, ?EVENT_WIN}),
            ?K:toast_ok(Ctx, <<"日程已删除"/utf8>>);
        {error, E} ->
            ?K:toast_error(Ctx, ?K:error_text(E))
    end,
    refresh(Ctx, Owner);
act(move_event, _Args, Event, Ctx, Owner) ->
    Data = maps:get(data, Event, #{}),
    Patch = maps:filter(fun(_, V) -> V =/= undefined end,
                        #{<<"start">> => data(Data, <<"from">>), <<"end">> => data(Data, <<"to">>),
                          <<"allDay">> => data(Data, <<"allDay">>) =:= <<"true">>}),
    case muse_calendar:update_event(Owner, data(Data, <<"event">>), Patch, #{}) of
        {ok, _} -> aihtml_action:html(Ctx, {id, ?RAIL}, rail(Owner), inner);
        {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E)), refresh(Ctx, Owner)
    end;
act(toggle_calendar, #{id := Id}, Event, Ctx, Owner) ->
    Visible = maps:get(checked, Event, null) =:= true,
    case muse_calendar:set_visible(Owner, Id, Visible) of
        {ok, _} -> ok;
        {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E))
    end,
    refresh(Ctx, Owner);
act(new_calendar, _Args, _Event, Ctx, Owner) ->
    open_calendar_form(Ctx, Owner, new);
act(edit_calendar, #{id := Id}, _Event, Ctx, Owner) ->
    case muse_calendar:get_calendar(Owner, Id) of
        {ok, Cal} -> open_calendar_form(Ctx, Owner, {edit, Cal});
        {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E)), refresh(Ctx, Owner)
    end;
act(save_calendar, #{id := Id}, Event, Ctx, Owner) ->
    Input = maps:filter(fun(_, V) -> V =/= <<>> end,
                        #{<<"name">> => ?K:form_text(Event, <<"name">>), <<"color">> => ?K:form_text(Event, <<"color">>)}),
    Result = case Id of
                 new -> muse_calendar:create_calendar(Owner, Input#{<<"name">> => maps:get(<<"name">>, Input, <<>>)});
                 _ -> muse_calendar:update_calendar(Owner, Id, Input#{<<"name">> => maps:get(<<"name">>, Input, <<>>)})
             end,
    case Result of
        {ok, _} ->
            aihtml_lib_overlay:close(Ctx, {id, ?CAL_WIN}),
            ?K:toast_ok(Ctx, <<"日历已保存"/utf8>>),
            refresh(Ctx, Owner);
        {error, E} ->
            aihtml_action:html(Ctx, {id, <<"cal-cal-error">>}, ah_alert(?K:error_text(E), [error], []), inner)
    end;
act(delete_calendar, #{id := Id}, Event, Ctx, Owner) ->
    Mode = case ?K:form_text(Event, <<"events">>) of
               <<"delete">> -> delete;
               <<"move">> -> {move, ?K:form_text(Event, <<"move_to">>)};
               _ -> undefined
           end,
    case muse_calendar:delete_calendar(Owner, Id, Mode) of
        ok ->
            aihtml_lib_overlay:close(Ctx, {id, ?CAL_WIN}),
            ?K:toast_ok(Ctx, <<"日历已删除"/utf8>>),
            refresh(Ctx, Owner);
        {error, E} ->
            aihtml_action:html(Ctx, {id, <<"cal-cal-error">>}, ah_alert(?K:error_text(E), [error], []), inner)
    end.

%% A data-* value of the event (`undefined` when absent).
data(Data, Key) ->
    case maps:get(Key, Data, undefined) of
        V when is_binary(V), V =/= <<>> -> V;
        _ -> undefined
    end.

%% The rail again, and the calendar reloads its range: aihtml's `reload/2`
%% (since aihtml 22c36ef) makes it fire `ah:range`, answered like a
%% navigation's `change` by `range`, without navigating.
refresh(Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, ?RAIL}, rail(Owner), inner),
    aihtml_calendar:reload(Ctx, {id, ?CAL}).

%%%===================================================================
%%% Live updates
%%%===================================================================

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {calendar, _Id}) ->
    ?K:publish(Owner, calendar, fun(C) -> refresh(C, Owner) end);
on_event(_Owner, _Event) ->
    ok.
