%% @doc `/api/calendars` and `/api/calendar/events`: the built-in calendar
%% (muse_calendar, tasks/M9-workspace.md M9-7) over JSON, Bearer auth like
%% every other route. Not in OpenMuse (whose Google calendar routes with
%% these paths are gone, docs/DIFFERENCES.md).
%%
%%   GET    /api/calendars                       the calendars
%%   GET    /api/calendar/events?from=&to=       occurrences in [from, to)
%%   POST   /api/calendar/events                 create (the user's own: no review)
%%   POST   /api/calendar/events/<id>            update with a patch
%%   DELETE /api/calendar/events/<id>            delete
%%
%% `from` and `to` are local dates `YYYY-MM-DD` (to exclusive, at most 400
%% days apart); events carry local times without a zone (`timeZone` names
%% the deployment's zone). The agent never writes through here: its
%% changes are `calendar.event` actions that the user reviews.
-module(muse_api_calendar).

-export([handle/3]).

-define(MAX_DAYS, 400).

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(<<"GET">>, [<<"api">>, <<"calendars">>], Req) ->
    {{200, #{<<"calendars">> => muse_calendar:calendars(muse_http:owner(Req)),
             <<"timeZone">> => muse_calendar:zone()}}, Req};
handle(<<"GET">>, [<<"api">>, <<"calendar">>, <<"events">>], Req) ->
    {events(muse_http:owner(Req), muse_http:query(<<"from">>, Req), muse_http:query(<<"to">>, Req)), Req};
handle(<<"POST">>, [<<"api">>, <<"calendar">>, <<"events">>], Req0) ->
    raw_body(Req0, fun(Raw) -> created(muse_calendar:create_event(muse_http:owner(Req0), Raw, <<"user">>)) end);
handle(<<"POST">>, [<<"api">>, <<"calendar">>, <<"events">>, Id], Req0) ->
    raw_body(Req0, fun(Raw) -> ok_200(muse_calendar:update_event(muse_http:owner(Req0), Id, Raw, #{})) end);
handle(<<"DELETE">>, [<<"api">>, <<"calendar">>, <<"events">>, Id], Req) ->
    {case muse_calendar:delete_event(muse_http:owner(Req), Id, #{}) of
         ok -> {200, #{<<"ok">> => true}};
         E -> E
     end, Req};
handle(_, _, _) ->
    next.

events(Owner, From, To) ->
    case {muse_calendar:parse_time(From), muse_calendar:parse_time(To)} of
        {{date, F}, {date, T}} when T > F, T - F =< ?MAX_DAYS * 1440 ->
            Occurrences = muse_calendar:occurrences(Owner, From, To, #{}),
            {200, #{<<"from">> => From, <<"to">> => To, <<"timeZone">> => muse_calendar:zone(),
                    <<"events">> => [(muse_calendar:summary(O))#{<<"color">> => maps:get(<<"color">>, O),
                                                                 <<"recurring">> => maps:get(<<"recurring">>, O)}
                                     || O <- Occurrences]}};
        _ ->
            {error, {422, <<"from and to are local dates YYYY-MM-DD, to after from, at most 400 days apart">>}}
    end.

raw_body(Req0, Fun) ->
    case muse_http:json_body(Req0) of
        {ok, V, Req} -> {Fun(V), Req};
        {error, E, Req} -> {{error, E}, Req}
    end.

ok_200({ok, V}) -> {200, V};
ok_200({error, E}) -> {error, E}.

created({ok, V}) -> {201, V};
created({error, E}) -> {error, E}.
