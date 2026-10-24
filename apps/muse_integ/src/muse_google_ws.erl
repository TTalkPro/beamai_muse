%% @doc The Google calls of `muse_workspace` in live mode
%% (designs/ref/openmuse-integrations-spec.md §4, workspace.ts `google()`).
%%
%% Every call is bound to the connection the workspace saw, like
%% `new GoogleClient({getAccessToken: () => auth.accessToken(owner, connectionId)})`,
%% so a reconnect in between fails with 409 instead of mixing accounts.
%% Errors are those of `muse_google_api` (including `outcome_unknown` for
%% writes that may have happened).
-module(muse_google_ws).

-export([tokens/1, calendars/2, events_page/3, upcoming_events/2, thread/3, search_mail/3,
         attachment/4, review_event/4, send_email/4, create_event/3, update_event/4,
         delete_event/5]).

-type error() :: {error, muse_google_api:error()}.

%% @doc `undefined` when disconnected, else the connection, account and
%% granted scopes. Unreadable credentials raise `{google_credentials, Error}`
%% (the original throws: 503 without a key, else a generic 502).
-spec tokens(binary()) -> undefined | #{connection_id := binary(), account := binary(),
                                        scopes := [binary()]}.
tokens(Owner) ->
    case muse_google_auth:connection(Owner) of
        {ok, undefined} ->
            undefined;
        {ok, #{<<"connectionId">> := Id} = C} ->
            #{connection_id => Id, account => maps:get(<<"account">>, C, <<>>),
              scopes => maps:get(<<"scopes">>, C, [])};
        {error, Error} ->
            error({google_credentials, Error})
    end.

-spec calendars(binary(), binary()) -> {ok, [map()]} | error().
calendars(Owner, ConnId) ->
    muse_gcal:list_calendars(client(Owner, ConnId)).

%% @doc `Opts`: `calendarId`, `timeMin`, `timeMax` (binary keys).
-spec events_page(binary(), binary(), map()) ->
          {ok, #{events := [map()], truncated := boolean()}} | error().
events_page(Owner, ConnId, Opts) ->
    case muse_gcal:list_events_page(client(Owner, ConnId), Opts) of
        {ok, #{<<"events">> := Events, <<"truncated">> := Truncated}} ->
            {ok, #{events => Events, truncated => Truncated}};
        Error ->
            Error
    end.

%% @doc The default window: local midnight today plus 31 days.
-spec upcoming_events(binary(), binary()) -> {ok, [map()]} | error().
upcoming_events(Owner, ConnId) ->
    muse_gcal:list_events(client(Owner, ConnId), #{}).

-spec thread(binary(), binary(), binary()) -> {ok, [map()]} | error().
thread(Owner, ConnId, ThreadId) ->
    muse_gmail:get_thread(client(Owner, ConnId), ThreadId).

-spec search_mail(binary(), binary(), binary() | undefined) -> {ok, [map()]} | error().
search_mail(Owner, ConnId, Query) ->
    muse_gmail:list_mail(client(Owner, ConnId), Query).

-spec attachment(binary(), binary(), binary(), binary()) -> {ok, binary()} | error().
attachment(Owner, ConnId, MessageId, AttachmentId) ->
    muse_gmail:get_attachment(client(Owner, ConnId), MessageId, AttachmentId).

-spec review_event(binary(), binary(), binary(), binary()) ->
          {ok, #{event := map(), version := binary()}} | error().
review_event(Owner, ConnId, CalendarId, EventId) ->
    muse_gcal:review_event(client(Owner, ConnId), CalendarId, EventId).

-spec send_email(binary(), binary(), map(), [muse_gmail:attachment()]) ->
          {ok, #{id := binary(), thread_id => binary()}} | error().
send_email(Owner, ConnId, Draft, Attachments) ->
    case muse_gmail:send_email(client(Owner, ConnId), Draft, Attachments) of
        {ok, #{<<"id">> := Id} = Sent} ->
            {ok, maps:merge(#{id => Id}, case Sent of
                                             #{<<"threadId">> := T} -> #{thread_id => T};
                                             _ -> #{}
                                         end)};
        Error ->
            Error
    end.

-spec create_event(binary(), binary(), map()) -> {ok, map()} | error().
create_event(Owner, ConnId, Draft) ->
    muse_gcal:create_event(client(Owner, ConnId), Draft).

%% @doc `Draft` is the calendar.update proposal data (eventDraft + eventId).
-spec update_event(binary(), binary(), map(), binary() | undefined) -> {ok, map()} | error().
update_event(Owner, ConnId, #{<<"eventId">> := EventId} = Draft, Version) ->
    muse_gcal:update_event(client(Owner, ConnId), EventId, Draft, Version).

-spec delete_event(binary(), binary(), binary(), binary(), binary() | undefined) -> ok | error().
delete_event(Owner, ConnId, CalendarId, EventId, Version) ->
    muse_gcal:delete_event(client(Owner, ConnId), CalendarId, EventId, Version).

client(Owner, ConnId) ->
    muse_google_api:client(Owner, ConnId).
