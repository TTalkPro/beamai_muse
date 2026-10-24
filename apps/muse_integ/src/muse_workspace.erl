%% @doc The user's mail, calendar and documents in sample or live mode
%% (OpenMuse workspace.ts, integrations spec §4).
%%
%% Sample mode serves the fictional mailbox seeded by `ensure_sample/2`
%% from Mnesia; live mode goes through the Google modules and caches mail
%% and events locally. Proposals for external writes are prepared and
%% executed here once the action review (muse_engine) approves them.
-module(muse_workspace).

-export([connection/1, connected/1, calendars/1, events/2, events_page/2,
         thread/2, search_mail/2, ensure_sample/2, snapshot/2, section_snapshot/2,
         prepare/3, execute/4, import_attachment/2,
         drafts/1, save_draft/2, at_local/2]).

-type owner() :: binary().
-type error() :: {error, {pos_integer(), binary()}}.

-define(SAMPLE_ACCOUNT, <<"alex@example.com">>).

%% @doc `undefined` when Google is disconnected, else `#{id, account}`.
-spec connection(owner()) -> #{id := binary(), account := binary() | undefined} | undefined.
connection(Owner) ->
    case mode() of
        sample ->
            case muse_store:get(Owner, <<"settings">>, <<"google">>) of
                #{<<"enabled">> := false} -> undefined;
                Settings -> #{id => conn_id(Settings), account => ?SAMPLE_ACCOUNT}
            end;
        live ->
            case muse_google_ws:tokens(Owner) of
                undefined -> undefined;
                #{connection_id := Id, account := Account} -> #{id => Id, account => Account}
            end
    end.

conn_id(#{<<"connectionId">> := Id}) when is_binary(Id) -> Id;
conn_id(_) -> <<"sample-google">>.

-spec connected(owner()) -> boolean().
connected(Owner) ->
    connection(Owner) =/= undefined.

-spec calendars(owner()) -> {ok, [map()]} | error().
calendars(Owner) ->
    case {connection(Owner), mode()} of
        {undefined, _} -> {ok, []};
        {_, sample} ->
            {ok, [#{<<"id">> => <<"primary">>, <<"name">> => <<"Personal">>,
                    <<"timeZone">> => muse_tz:system_zone(), <<"accessRole">> => <<"owner">>}]};
        {#{id := ConnId}, live} ->
            muse_google_ws:calendars(Owner, ConnId)
    end.

-spec events(owner(), map()) -> {ok, [map()]} | error().
events(Owner, Opts) ->
    case events_page(Owner, Opts) of
        {ok, undefined} -> {ok, []};
        {ok, #{events := Events}} -> {ok, Events};
        Error -> Error
    end.

%% @doc Events in a range. `{ok, undefined}` means disconnected, which is
%% different from a connected calendar without events.
%% Opts: `calendarId`, `timeMin`, `timeMax` (binaries, optional).
-spec events_page(owner(), map()) -> {ok, #{events := [map()], truncated := boolean()} | undefined} | error().
events_page(Owner, Opts) ->
    case {connection(Owner), mode()} of
        {undefined, _} -> {ok, undefined};
        {#{id := ConnId}, live} -> muse_google_ws:events_page(Owner, ConnId, Opts);
        {_, sample} -> {ok, #{events => sample_events(Owner, Opts), truncated => false}}
    end.

sample_events(Owner, Opts) ->
    CalendarId = maps:get(<<"calendarId">>, Opts, <<"primary">>),
    TimeMin = maps:get(<<"timeMin">>, Opts, undefined),
    TimeMax = maps:get(<<"timeMax">>, Opts, undefined),
    LastIncluded = case TimeMax of
                       undefined -> undefined;
                       _ -> muse_time:to_iso(muse_time:parse(TimeMax) - 1)
                   end,
    P = fun muse_time:parse/1,
    Keep = fun(#{<<"allDay">> := true, <<"start">> := S, <<"end">> := E, <<"timeZone">> := Tz}) ->
                   %% All-day events cover local dates: compare against the
                   %% local date of the last included instant.
                   (LastIncluded =:= undefined orelse
                        P(S) =< P(element(1, muse_tz:local_date_time(LastIncluded, Tz))))
                   andalso (TimeMin =:= undefined orelse
                        P(E) > P(element(1, muse_tz:local_date_time(TimeMin, Tz))));
              (#{<<"start">> := S, <<"end">> := E}) ->
                   (TimeMax =:= undefined orelse P(S) < P(TimeMax))
                   andalso (TimeMin =:= undefined orelse P(E) > P(TimeMin))
           end,
    Events = [E || E = #{<<"calendarId">> := C} <- muse_store:list(Owner, <<"events">>),
                   C =:= CalendarId, Keep(E)],
    sort_by(<<"start">>, asc, Events).

%% @doc Every message of a thread, oldest first.
-spec thread(owner(), binary()) -> {ok, [map()]} | error().
thread(Owner, ThreadId) ->
    case connection(Owner) of
        undefined ->
            disconnected();
        #{id := ConnId} ->
            Mail = case mode() of
                       sample -> {ok, [M || M = #{<<"threadId">> := T} <- muse_store:list(Owner, <<"mail">>),
                                            T =:= ThreadId]};
                       live ->
                           maybe
                               {ok, Fetched} ?= muse_google_ws:thread(Owner, ConnId, ThreadId),
                               {ok, cache_mail(Owner, Fetched, ConnId)}
                           end
                   end,
            case Mail of
                {ok, []} -> {error, {404, <<"Mail thread not found">>}};
                {ok, Messages} -> {ok, sort_by(<<"date">>, asc, Messages)};
                Error -> Error
            end
    end.

%% @doc Mail search: Gmail query in live mode, every word must occur in
%% sender/from/subject/body in sample mode (sent mail excluded), newest first.
-spec search_mail(owner(), binary()) -> {ok, [map()]} | error().
search_mail(Owner, Query) ->
    case {connection(Owner), mode()} of
        {undefined, _} ->
            disconnected();
        {#{id := ConnId}, live} ->
            Q = case Query of <<>> -> <<"in:inbox">>; _ -> Query end,
            maybe
                {ok, Mail} ?= muse_google_ws:search_mail(Owner, ConnId, Q),
                {ok, cache_mail(Owner, Mail, ConnId)}
            end;
        {_, sample} ->
            Words = string:lexemes(string:lowercase(string:trim(Query)), " \t\n\r"),
            Match = fun(#{<<"label">> := Label} = M) ->
                            not is_sent(Label) andalso
                                begin
                                    Hay = string:lowercase(iolist_to_binary(
                                            lists:join(<<" ">>, [field(M, K) || K <- [<<"sender">>, <<"from">>,
                                                                                     <<"subject">>, <<"body">>]]))),
                                    lists:all(fun(W) -> binary:match(Hay, W) =/= nomatch end, Words)
                                end
                    end,
            {ok, sort_by(<<"date">>, desc, [M || M <- muse_store:list(Owner, <<"mail">>), Match(M)])}
    end.

%% @doc Seed the fictional mailbox, calendar, permission slip and one pending
%% calendar proposal (sample mode only, once per owner). `Propose` is
%% `fun(Owner, ProposalInput) -> any()` from the action review service.
-spec ensure_sample(owner(), fun((owner(), map()) -> term())) -> ok | error().
ensure_sample(Owner, Propose) ->
    case mode() of
        live -> ok;
        sample ->
            global:trans({{?MODULE, seed, Owner}, self()},
                         fun() ->
                             case muse_store:get(Owner, <<"settings">>, <<"seeded">>) of
                                 undefined -> seed(Owner, Propose);
                                 _ -> ok
                             end
                         end, [node()], infinity)
    end.

seed(Owner, Propose) ->
    maybe
        {ok, Pdf} ?= file:read_file(filename:join(code:priv_dir(muse_integ), "sample-permission-slip.pdf")),
        {ok, #{<<"id">> := FileId}} ?= muse_files:import(Owner, <<"Field trip permission slip.pdf">>, Pdf,
                                                          <<"Gmail · Lincoln Middle School"/utf8>>),
        lists:foreach(fun(M) -> muse_store:put(Owner, <<"mail">>, M) end,
                      muse_workspace_seed:mail(FileId, fun at_today/2)),
        Zone = muse_tz:system_zone(),
        lists:foreach(fun(E) -> muse_store:put(Owner, <<"events">>, E) end,
                      muse_workspace_seed:events(Zone, fun at_today/2)),
        _ = Propose(Owner, muse_workspace_seed:proposal(Zone, fun at_today/2)),
        _ = muse_store:put(Owner, <<"settings">>, #{<<"id">> => <<"google">>, <<"enabled">> => true}),
        _ = muse_store:put(Owner, <<"settings">>, #{<<"id">> => <<"seeded">>, <<"value">> => true}),
        ok
    else
        {error, {_, _}} = Error -> Error;
        {error, Reason} -> error({sample_seed_failed, Reason})
    end.

at_today(H, M) ->
    at_local(H, M).

%% @doc Today at `H:M` server-local time as an ISO instant (JS
%% `new Date(); d.setHours(h, m, 0, 0); d.toISOString()`).
-spec at_local(0..23, 0..59) -> binary().
at_local(H, M) ->
    {Date, _} = calendar:local_time(),
    %% A time skipped by a spring-forward gap moves an hour later, like JS.
    Utc = case calendar:local_time_to_universal_time_dst({Date, {H, M, 0}}) of
              [U | _] -> U;
              [] -> hd(calendar:local_time_to_universal_time_dst({Date, {min(H + 1, 23), M, 0}}))
          end,
    Secs = calendar:datetime_to_gregorian_seconds(Utc) - 62167219200,
    muse_time:to_iso(Secs * 1000).

%% @doc OpenMuse Workspace snapshot (spec §2.5 / §4.4) minus browser
%% decoration, which the HTTP layer adds.
-spec snapshot(owner(), binary() | undefined) -> {ok, map()} | error().
snapshot(Owner, Query) ->
    maybe
        {ok, #{mail := Mail, events := Events, connected := Connected}} ?=
            sections(Owner, true, true, Query),
        Mode = mode(),
        Tokens = case Mode of
                     live -> muse_google_ws:tokens(Owner);
                     sample -> undefined
                 end,
        Account = case {Tokens, Mode} of
                      {#{account := A}, _} -> A;
                      {_, sample} -> ?SAMPLE_ACCOUNT;
                      _ -> undefined
                  end,
        Config = muse_config:all(),
        GoogleConn = #{<<"id">> => <<"google">>, <<"name">> => <<"Google">>,
                       <<"status">> => case {Connected, Mode} of
                                           {false, _} -> <<"disconnected">>;
                                           {true, sample} -> <<"sample">>;
                                           {true, live} -> <<"connected">>
                                       end,
                       <<"capabilities">> => case {Mode, Tokens} of
                                                 {sample, _} -> [<<"Gmail">>, <<"Calendar">>];
                                                 {live, #{scopes := Scopes}} -> Scopes;
                                                 _ -> []
                                             end},
        {ok, #{<<"mode">> => atom_to_binary(Mode),
               <<"profile">> => #{<<"name">> => case Mode of sample -> <<"Alex">>; live -> <<"You">> end,
                                  <<"email">> => case Account of undefined -> <<>>; _ -> Account end},
               <<"mail">> => sort_by(<<"date">>, desc, Mail),
               <<"events">> => sort_by(<<"start">>, asc, Events),
               <<"files">> => muse_files:list(Owner),
               <<"browsers">> => muse_store:list(Owner, <<"browsers">>),
               <<"actions">> => muse_store:list(Owner, <<"actions">>),
               <<"activity">> => muse_store:list(Owner, <<"activity">>),
               <<"connections">> =>
                   [with_account(GoogleConn, Account),
                    #{<<"id">> => <<"browser">>, <<"name">> => <<"Browser">>,
                      <<"status">> => case muse_config:browser_configured() of
                                          true -> <<"connected">>;
                                          false -> <<"unconfigured">>
                                      end,
                      <<"capabilities">> => [<<"Persistent sessions">>, <<"PDF downloads">>]},
                    #{<<"id">> => <<"openbot">>, <<"name">> => <<"OpenBot">>,
                      <<"status">> => <<"unconfigured">>,
                      <<"capabilities">> => [<<"Integration adapter available">>]}],
               <<"runtime">> => #{<<"provider">> => case maps:get(agent_backend, Config) of
                                                        sample -> <<"sample">>;
                                                        _ -> <<"model">>
                                                    end,
                                  <<"configured">> => muse_config:agent_configured(),
                                  <<"openbotConfigured">> => false,
                                  <<"richThreads">> => true}}}
    end.

with_account(Conn, undefined) -> Conn;
with_account(Conn, Account) -> Conn#{<<"account">> => Account}.

%% @doc `read_workspace` tool payload: requested sections, files without URLs.
-spec section_snapshot(owner(), binary()) -> {ok, map()} | error().
section_snapshot(Owner, Section) ->
    WantMail = Section =:= <<"mail">> orelse Section =:= <<"all">>,
    WantEvents = Section =:= <<"calendar">> orelse Section =:= <<"all">>,
    WantFiles = Section =:= <<"files">> orelse Section =:= <<"all">>,
    maybe
        {ok, #{mail := Mail, events := Events}} ?=
            case WantMail orelse WantEvents of
                true -> sections(Owner, WantMail, WantEvents, undefined);
                false -> {ok, #{mail => [], events => []}}
            end,
        {ok, maps:from_list(
               [{<<"mail">>, sort_by(<<"date">>, desc, Mail)} || WantMail] ++
               [{<<"events">>, sort_by(<<"start">>, asc, Events)} || WantEvents] ++
               [{<<"files">>, muse_files:list(Owner, unsigned)} || WantFiles])}
    end.

sections(Owner, WantMail, WantEvents, Query) ->
    case {connection(Owner), mode()} of
        {undefined, _} ->
            {ok, #{mail => [], events => [], connected => false}};
        {#{id := ConnId}, live} ->
            maybe
                {ok, Mail} ?= case WantMail of
                                  true -> muse_google_ws:search_mail(Owner, ConnId, Query);
                                  false -> {ok, []}
                              end,
                {ok, Events} ?= case WantEvents of
                                    true -> muse_google_ws:upcoming_events(Owner, ConnId);
                                    false -> {ok, []}
                                end,
                Cached = case WantMail of
                             true -> cache_mail(Owner, Mail, ConnId);
                             false -> []
                         end,
                lists:foreach(fun(E) -> muse_store:put(Owner, <<"events">>, E) end, Events),
                {ok, #{mail => Cached, events => Events, connected => true}}
            end;
        {_, sample} ->
            Mail = case WantMail of
                       false -> [];
                       true ->
                           All = muse_store:list(Owner, <<"mail">>),
                           case Query of
                               Q when Q =:= undefined; Q =:= <<>> -> All;
                               Q ->
                                   Needle = string:lowercase(Q),
                                   [M || M <- All,
                                         binary:match(string:lowercase(iolist_to_binary(
                                             [field(M, <<"sender">>), " ", field(M, <<"subject">>), " ",
                                              field(M, <<"body">>)])), Needle) =/= nomatch]
                           end
                   end,
            Events = case WantEvents of
                         true -> muse_store:list(Owner, <<"events">>);
                         false -> []
                     end,
            {ok, #{mail => Mail, events => Events, connected => true}}
    end.

%% Live mail is cached locally with attachment references swapped for the
%% artifacts already imported on this connection.
cache_mail(Owner, Mail, ConnId) ->
    Imports = [I || I = #{<<"connectionId">> := C} <- muse_store:list(Owner, <<"imports">>), C =:= ConnId],
    Swap = fun(Ref) ->
                   case [A || #{<<"id">> := Id, <<"artifactId">> := A} <- Imports, Id =:= Ref] of
                       [A | _] -> A;
                       [] -> Ref
                   end
           end,
    Result = [M#{<<"attachments">> => [Swap(R) || R <- maps:get(<<"attachments">>, M, [])]} || M <- Mail],
    lists:foreach(fun(M) -> muse_store:put(Owner, <<"mail">>, M#{<<"connectionId">> => ConnId}) end, Result),
    Result.

%% @doc Prepare a validated proposal input `#{<<"kind">>, <<"data">>}` for
%% review: attachments must be owned; live calendar updates/deletes capture
%% the reviewed target event and its version.
-spec prepare(owner(), map(), binary() | undefined) -> {ok, map()} | error().
prepare(Owner, #{<<"kind">> := <<"email.send">>, <<"data">> := Data} = Input, _ConnId) ->
    case first_error([muse_files:get(Owner, Id) || Id <- maps:get(<<"attachmentIds">>, Data, [])]) of
        ok -> {ok, #{input => Input}};
        Error -> Error
    end;
prepare(_Owner, #{<<"kind">> := <<"calendar.create">>} = Input, _ConnId) ->
    {ok, #{input => Input}};
prepare(Owner, #{<<"kind">> := Kind, <<"data">> := Data} = Input, ConnId) ->
    case mode() of
        sample -> {ok, #{input => Input}};
        live ->
            maybe
                {ok, #{event := Event, version := Version}} ?=
                    muse_google_ws:review_event(Owner, ConnId, maps:get(<<"calendarId">>, Data),
                                                maps:get(<<"eventId">>, Data)),
                Reviewed = case Kind of
                               <<"calendar.delete">> ->
                                   Input#{<<"data">> => Data#{<<"title">> => maps:get(<<"title">>, Event)}};
                               _ -> Input
                           end,
                {ok, #{input => Reviewed, target => Event, target_version => Version}}
            end
    end.

%% @doc Perform an approved external write; returns the receipt text.
-spec execute(owner(), map(), binary() | undefined, binary() | undefined) -> {ok, binary()} | error().
execute(Owner, #{<<"kind">> := Kind, <<"data">> := Data}, ConnId, TargetVersion) ->
    case mode() of
        sample -> execute_sample(Owner, Kind, Data);
        live -> execute_live(Owner, Kind, Data, ConnId, TargetVersion)
    end.

execute_sample(Owner, <<"email.send">>, Data) ->
    Id = muse_ids:uuid(),
    _ = muse_store:put(Owner, <<"mail">>,
                       #{<<"id">> => Id,
                         <<"threadId">> => maps:get(<<"threadId">>, Data, Id),
                         <<"sender">> => <<"You">>,
                         <<"from">> => ?SAMPLE_ACCOUNT,
                         <<"to">> => maps:get(<<"to">>, Data),
                         <<"subject">> => maps:get(<<"subject">>, Data),
                         <<"body">> => maps:get(<<"body">>, Data),
                         <<"date">> => muse_time:now_iso(),
                         <<"unread">> => false,
                         <<"label">> => <<"Sent · local"/utf8>>,
                         <<"attachments">> => maps:get(<<"attachmentIds">>, Data, [])}),
    {ok, <<"Saved to local sent mail · "/utf8, Id/binary>>};
execute_sample(Owner, <<"calendar.delete">>, #{<<"eventId">> := EventId}) ->
    ok = muse_store:remove(Owner, <<"events">>, EventId),
    {ok, <<"Removed from local calendar">>};
execute_sample(Owner, Kind, Data) ->
    Id = case Kind of
             <<"calendar.update">> -> maps:get(<<"eventId">>, Data);
             _ -> muse_ids:uuid()
         end,
    _ = muse_store:put(Owner, <<"events">>, Data#{<<"id">> => Id}),
    {ok, <<"Saved to local calendar · "/utf8, Id/binary>>}.

execute_live(Owner, Kind, Data, ConnId, TargetVersion) ->
    Capability = case Kind of
                     <<"email.send">> -> <<"gmail.send">>;
                     _ -> <<"calendar.events">>
                 end,
    case muse_google_ws:tokens(Owner) of
        undefined ->
            disconnected();
        #{scopes := Scopes, connection_id := Current} ->
            HasScope = lists:member(<<"https://www.googleapis.com/auth/", Capability/binary>>, Scopes),
            NeedsVersion = Kind =:= <<"calendar.update">> orelse Kind =:= <<"calendar.delete">>,
            if
                not HasScope ->
                    {error, {403, <<"Enable Google write access in Connections before approving">>}};
                Current =/= ConnId ->
                    {error, {409, <<"Google account or connection changed. Prepare a new action.">>}};
                NeedsVersion, TargetVersion =:= undefined ->
                    {error, {409, <<"This calendar review predates target-version checks. "
                                    "Prepare a new review.">>}};
                true ->
                    live_write(Owner, Kind, Data, ConnId, TargetVersion)
            end
    end.

live_write(Owner, <<"email.send">>, Data, ConnId, _) ->
    maybe
        {ok, Attachments} ?= attachments(Owner, maps:get(<<"attachmentIds">>, Data, []), []),
        {ok, #{id := MsgId}} ?= muse_google_ws:send_email(Owner, ConnId, Data, Attachments),
        {ok, <<"Gmail sent message · "/utf8, MsgId/binary>>}
    end;
live_write(Owner, <<"calendar.delete">>, #{<<"calendarId">> := Cal, <<"eventId">> := EventId}, ConnId, Version) ->
    maybe
        ok ?= muse_google_ws:delete_event(Owner, ConnId, Cal, EventId, Version),
        ok = muse_store:remove(Owner, <<"events">>, EventId),
        {ok, <<"Deleted Google Calendar event · "/utf8, EventId/binary>>}
    end;
live_write(Owner, Kind, Data, ConnId, Version) ->
    maybe
        {ok, #{<<"id">> := Id} = Event} ?=
            case Kind of
                <<"calendar.create">> -> muse_google_ws:create_event(Owner, ConnId, Data);
                <<"calendar.update">> -> muse_google_ws:update_event(Owner, ConnId, Data, Version)
            end,
        _ = muse_store:put(Owner, <<"events">>, Event),
        {ok, <<"Google Calendar event · "/utf8, Id/binary>>}
    end.

attachments(_Owner, [], Acc) ->
    {ok, lists:reverse(Acc)};
attachments(Owner, [Id | Rest], Acc) ->
    maybe
        {ok, #{<<"name">> := Name, <<"mimeType">> := Mime}} ?= muse_files:get(Owner, Id),
        {ok, Bytes} ?= muse_files:bytes(Owner, Id),
        attachments(Owner, Rest, [#{name => Name, mime_type => Mime, bytes => Bytes} | Acc])
    end.

%% @doc Import a Gmail attachment (`messageId:attachmentId:filename`) into
%% Documents, once per connection.
-spec import_attachment(owner(), binary()) -> {ok, map()} | error().
import_attachment(Owner, Reference) ->
    case connection(Owner) of
        undefined ->
            disconnected();
        #{id := ConnId} ->
            case muse_store:get(Owner, <<"imports">>, Reference) of
                #{<<"artifactId">> := ArtifactId, <<"connectionId">> := ConnId} ->
                    maybe
                        {ok, File} ?= muse_files:get(Owner, ArtifactId),
                        {ok, muse_files:signed(Owner, File)}
                    end;
                _ ->
                    fetch_attachment(Owner, Reference, ConnId)
            end
    end.

fetch_attachment(Owner, Reference, ConnId) ->
    case binary:split(Reference, <<":">>, [global]) of
        [MessageId, AttachmentId, FileName | _] when MessageId =/= <<>>, AttachmentId =/= <<>>,
                                                     FileName =/= <<>> ->
            Message = muse_store:get(Owner, <<"mail">>, MessageId),
            Owned = is_map(Message)
                andalso lists:member(Reference, maps:get(<<"attachments">>, Message, []))
                andalso maps:get(<<"connectionId">>, Message, undefined) =:= ConnId,
            case Owned of
                false ->
                    {error, {404, <<"Attachment not found. Refresh the current account's inbox.">>}};
                true ->
                    maybe
                        {ok, Bytes} ?= muse_google_ws:attachment(Owner, ConnId, MessageId, AttachmentId),
                        Key = muse_json:encode([<<"attachment">>, ConnId, Reference]),
                        {ok, #{<<"id">> := FileId} = File} ?=
                            muse_files:import(Owner, uri_string:percent_decode(FileName), Bytes,
                                              <<"Gmail · "/utf8, (maps:get(<<"subject">>, Message))/binary>>,
                                              undefined, Key),
                        _ = muse_store:put(Owner, <<"imports">>, #{<<"id">> => Reference,
                                                                  <<"artifactId">> => FileId,
                                                                  <<"connectionId">> => ConnId}),
                        {ok, File}
                    end
            end;
        _ ->
            {error, {400, <<"Attachment reference is invalid">>}}
    end.

%% @doc Saved email drafts (`GET /api/drafts`).
-spec drafts(owner()) -> [map()].
drafts(Owner) ->
    muse_store:list(Owner, <<"drafts">>).

%% @doc Create or update a draft (`POST /api/drafts`). `Draft` is already
%% validated against emailDraft and may carry `id`.
-spec save_draft(owner(), map()) -> {ok, map()} | error().
save_draft(Owner, Draft) ->
    case maps:find(<<"id">>, Draft) of
        {ok, Id} ->
            case muse_store:get(Owner, <<"drafts">>, Id) of
                undefined -> {error, {404, <<"Draft not found">>}};
                #{<<"createdAt">> := Created} ->
                    {ok, muse_store:put(Owner, <<"drafts">>, Draft#{<<"createdAt">> => Created})}
            end;
        error ->
            {ok, muse_store:put(Owner, <<"drafts">>, Draft#{<<"id">> => muse_ids:uuid(),
                                                             <<"createdAt">> => muse_time:now_iso()})}
    end.

%% Helpers

mode() ->
    muse_config:get(mode).

disconnected() ->
    {error, {409, <<"Google is disconnected">>}}.

is_sent(Label) ->
    re:run(Label, <<"^Sent\\b">>, [caseless, unicode, {capture, none}]) =:= match.

field(M, K) ->
    case maps:get(K, M, <<>>) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end.

sort_by(Key, Dir, Docs) ->
    Sorted = lists:sort(fun(A, B) -> field(A, Key) =< field(B, Key) end, Docs),
    case Dir of
        asc -> Sorted;
        desc -> lists:reverse(Sorted)
    end.

first_error([]) -> ok;
first_error([{error, _} = E | _]) -> E;
first_error([_ | Rest]) -> first_error(Rest).
