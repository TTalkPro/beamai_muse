%% @doc Gmail: search, threads, attachments and sending
%% (designs/ref/openmuse-integrations-spec.md §9.6-§9.8, google.ts).
%%
%% Every call takes a `muse_google_api:client()`. Messages come back as Mail
%% documents (binary-keyed maps, spec §2.5). `send_email/3` builds the same
%% MIME bytes as OpenMuse `sendEmail`; `build_mime/1` is the pure part.
%% OpenMuse keeps drafts as local records (workspace), not Gmail drafts.
-module(muse_gmail).

-export([list_mail/2, get_thread/2, get_attachment/3, send_email/3,
         map_message/1, hydrate_and_map/2, build_mime/1, utc_string/1,
         decode_base64url/2, email_draft_schema/0]).

-export_type([attachment/0, mail/0]).

-define(GMAIL, "https://gmail.googleapis.com/gmail/v1/users/me").
-define(MIB, 1048576).
-define(MAX_ATTACHMENT, 10485760).
-define(MAX_TOTAL_ATTACHMENTS, 20971520).
-define(TEXT_LIMIT_MSG, <<"Gmail message text exceeds the 1 MiB limit">>).

-type error() :: muse_google_api:error().
-type client() :: muse_google_api:client().
-type mail() :: #{binary() => term()}.
-type attachment() :: #{name := binary(), mime_type := binary(), bytes := binary()}.

%% @doc The latest 30 messages matching `Query` (`undefined` = `in:inbox`).
-spec list_mail(client(), binary() | undefined) -> {ok, [mail()]} | {error, error()}.
list_mail(Client, undefined) ->
    list_mail(Client, <<"in:inbox">>);
list_mail(Client, Query) ->
    Url = [?GMAIL, "/messages?", muse_google_api:form_encode([{<<"maxResults">>, <<"30">>},
                                                             {<<"q">>, Query}])],
    Schema = {object, [{<<"messages">>,
                        {default, {array, {object, [{<<"id">>, {string, #{}}}]}, #{}}, []}}]},
    maybe
        {ok, Json} ?= muse_google_api:get(Client, Url),
        {ok, #{<<"messages">> := Messages}} ?= muse_validate:parse(Schema, Json),
        Ids = [Id || #{<<"id">> := Id} <- lists:sublist(Messages, 30)],
        muse_google_api:pmap(fun(Id) -> full_message(Client, Id) end, Ids)
    end.

%% @doc Every message of a thread, oldest first as Gmail returns them.
-spec get_thread(client(), binary()) -> {ok, [mail()]} | {error, error()}.
get_thread(Client, ThreadId) ->
    Schema = {object, [{<<"id">>, {string, #{}}},
                       {<<"messages">>, {default, {array, message_schema(), #{}}, []}}]},
    maybe
        {ok, Id} ?= muse_google_api:id_path(ThreadId),
        {ok, Json} ?= muse_google_api:get(Client, [?GMAIL, "/threads/", Id, "?format=full"]),
        {ok, #{<<"id">> := Got, <<"messages">> := Messages}} ?= muse_validate:parse(Schema, Json),
        ok ?= case Got =:= ThreadId andalso
                   lists:all(fun(#{<<"threadId">> := T}) -> T =:= ThreadId end, Messages) of
                  true -> ok;
                  false -> internal(<<"Google returned messages from a different thread">>)
              end,
        muse_google_api:pmap(fun(M) -> hydrate_and_map(Client, M) end, Messages)
    end.

%% @doc Attachment bytes, at most 10 MiB, size cross-checked.
-spec get_attachment(client(), binary(), binary()) -> {ok, binary()} | {error, error()}.
get_attachment(Client, MessageId, AttachmentId) ->
    Schema = {object, [{<<"data">>, {string, #{}}},
                       {<<"size">>, {optional, {integer, #{min => 0}}}}]},
    maybe
        {ok, M} ?= muse_google_api:id_path(MessageId),
        {ok, A} ?= muse_google_api:id_path(AttachmentId),
        {ok, Json} ?= muse_google_api:get(Client, [?GMAIL, "/messages/", M, "/attachments/", A]),
        {ok, #{<<"data">> := Data} = Att} ?= muse_validate:parse(Schema, Json),
        Size = maps:get(<<"size">>, Att, undefined),
        ok ?= case is_integer(Size) andalso Size > ?MAX_ATTACHMENT of
                  true -> internal(<<"Attachment is too large (10 MiB limit)">>);
                  false -> ok
              end,
        {ok, Bytes} ?= decode_base64url(Data, ?MAX_ATTACHMENT),
        case Size =:= undefined orelse Size =:= byte_size(Bytes) of
            true -> {ok, Bytes};
            false -> internal(<<"Google attachment size does not match its actual byte length">>)
        end
    end.

%% @doc Send `Draft` (emailDraft JSON, spec §2.5) with attachments.
%% Returns `#{<<"id">>, <<"threadId">>?}`.
-spec send_email(client(), map(), [attachment()]) -> {ok, map()} | {error, error()}.
send_email(Client, Draft0, Attachments) ->
    maybe
        {ok, Draft} ?= muse_validate:parse(email_draft_schema(), Draft0),
        #{<<"subject">> := Subject, <<"to">> := To, <<"cc">> := Cc, <<"bcc">> := Bcc} = Draft,
        {ok, _} ?= muse_google_api:single_line(Subject, <<"subject">>),
        ok ?= all_ok([muse_google_api:single_line(A, <<"recipient">>) || A <- To ++ Cc ++ Bcc]),
        ok ?= validate_attachments(Attachments),
        ThreadId = truthy(maps:get(<<"threadId">>, Draft, undefined)),
        ReplyTo = truthy(maps:get(<<"replyToMessageId">>, Draft, undefined)),
        ok ?= case ThreadId =/= undefined andalso ReplyTo =:= undefined of
                  true -> internal(<<"Replies require replyToMessageId to resolve the source "
                                     "message headers">>);
                  false -> ok
              end,
        {ok, SendThread, ReplyHeaders} ?= reply_headers(Client, ReplyTo, ThreadId, Subject),
        {ok, Profile} ?= muse_google_api:get(Client, [?GMAIL, "/profile"]),
        {ok, #{<<"emailAddress">> := From0}} ?=
            muse_validate:parse({object, [{<<"emailAddress">>, {string, #{email => true}}}]},
                                Profile),
        {ok, From} ?= muse_google_api:single_line(From0, <<"sender">>),
        Mime = build_mime(#{from => From, to => To, cc => Cc, bcc => Bcc, subject => Subject,
                            body => maps:get(<<"body">>, Draft),
                            date => utc_string(muse_time:now_ms()),
                            message_id => muse_ids:uuid(), reply_headers => ReplyHeaders,
                            attachments => Attachments, boundary => muse_ids:uuid()}),
        Raw = base64:encode(Mime, #{mode => urlsafe, padding => false}),
        {ok, Result} ?= muse_google_api:request(Client, post, [?GMAIL, "/messages/send"],
                                                {obj, [{<<"raw">>, Raw},
                                                       {<<"threadId">>, SendThread}]}, []),
        sent(Result)
    end.

%% @doc The MIME text of OpenMuse `sendEmail`. Keys: `from`, `to`, `cc`,
%% `bcc`, `subject`, `body`, `date` (toUTCString), `message_id` (uuid),
%% `reply_headers`, `attachments`, `boundary` (uuid, used with attachments).
-spec build_mime(map()) -> binary().
build_mime(#{from := From, to := To, subject := Subject, body := Body, date := Date,
             message_id := MessageId} = Opts) ->
    Cc = maps:get(cc, Opts, []),
    Bcc = maps:get(bcc, Opts, []),
    Headers = [<<"From: ", From/binary>>,
               <<"To: ", (join(To, <<",\r\n ">>))/binary>>]
              ++ [<<"Cc: ", (join(Cc, <<",\r\n ">>))/binary>> || Cc =/= []]
              ++ [<<"Bcc: ", (join(Bcc, <<",\r\n ">>))/binary>> || Bcc =/= []]
              ++ [<<"Subject: ", (encoded_subject(Subject))/binary>>,
                  <<"Date: ", Date/binary>>,
                  <<"Message-ID: <", MessageId/binary, "@openmuse.invalid>">>]
              ++ maps:get(reply_headers, Opts, [])
              ++ [<<"MIME-Version: 1.0">>],
    Crlf = re:replace(Body, <<"\r\n|\r|\n">>, <<"\r\n">>, [global, {return, binary}]),
    TextPart = join([<<"Content-Type: text/plain; charset=UTF-8">>,
                     <<"Content-Transfer-Encoding: base64">>, <<>>, wrap_base64(Crlf)],
                    <<"\r\n">>),
    case maps:get(attachments, Opts, []) of
        [] ->
            join(Headers ++ [TextPart], <<"\r\n">>);
        Attachments ->
            Boundary = <<"openmuse_", (maps:get(boundary, Opts))/binary>>,
            Parts = [TextPart | [attachment_part(A) || A <- Attachments]],
            join(Headers ++ [<<"Content-Type: multipart/mixed; boundary=\"", Boundary/binary, "\"">>,
                             <<>>]
                 ++ [<<"--", Boundary/binary, "\r\n", P/binary>> || P <- Parts]
                 ++ [<<"--", Boundary/binary, "--">>, <<>>],
                 <<"\r\n">>)
    end.

%% @doc JavaScript `Date.prototype.toUTCString`.
-spec utc_string(integer()) -> binary().
utc_string(Ms) ->
    {{Y, Mo, D} = Date, {H, Mi, S}} =
        calendar:system_time_to_universal_time(Ms div 1000 - (case Ms rem 1000 < 0 of
                                                                  true -> 1;
                                                                  false -> 0
                                                              end), second),
    Day = element(calendar:day_of_the_week(Date),
                  {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}),
    Mon = element(Mo, {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
                       "Nov", "Dec"}),
    iolist_to_binary(io_lib:format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
                                   [Day, D, Mon, Y, H, Mi, S])).

%% @doc google.ts `decodeBase64url`: strict, canonical, size limited.
-spec decode_base64url(binary(), pos_integer()) -> {ok, binary()} | {error, error()}.
decode_base64url(Encoded, Limit) ->
    Invalid = <<"Invalid base64url attachment or message body">>,
    case byte_size(Encoded) > ceil_div(Limit * 4, 3) + 4 of
        true ->
            internal(<<"Attachment or message body exceeds the size limit">>);
        false ->
            case re:run(Encoded, <<"^[A-Za-z0-9_-]*={0,2}$">>, [{capture, none}]) of
                nomatch ->
                    internal(Invalid);
                match ->
                    Stripped = string:trim(Encoded, trailing, "="),
                    try base64:decode(Stripped, #{mode => urlsafe, padding => false}) of
                        Bytes when byte_size(Bytes) > Limit ->
                            internal(<<"Attachment or message body is too large">>);
                        Bytes ->
                            case base64:encode(Bytes, #{mode => urlsafe, padding => false}) of
                                Stripped -> {ok, Bytes};
                                _ -> internal(Invalid)
                            end
                    catch
                        _:_ -> internal(Invalid)
                    end
            end
    end.

%% @doc Hydrate text bodies stored behind attachment ids, then `map_message/1`.
%% `Message` is the raw Gmail message JSON.
-spec hydrate_and_map(client(), map()) -> {ok, mail()} | {error, error()}.
hydrate_and_map(Client, Message0) ->
    maybe
        {ok, Message} ?= muse_validate:parse(message_schema(), Message0),
        {ok, Hydrated} ?= case Message of
                               #{<<"payload">> := Payload} ->
                                   case hydrate(Client, maps:get(<<"id">>, Message), Payload, 0) of
                                       {ok, P} -> {ok, Message#{<<"payload">> => P}};
                                       Error -> Error
                                   end;
                               _ ->
                                   {ok, Message}
                           end,
        map_message(Hydrated)
    end.

%% @doc google.ts `mapMessage` (spec §9.7) without hydration.
-spec map_message(map()) -> {ok, mail()} | {error, error()}.
map_message(Message0) ->
    maybe
        {ok, Message} ?= muse_validate:parse(message_schema(), Message0),
        #{<<"id">> := Id, <<"threadId">> := ThreadId, <<"snippet">> := Snippet,
          <<"labelIds">> := Labels} = Message,
        Payload = maps:get(<<"payload">>, Message, undefined),
        {ok, {Plain, Html, Refs}} ?= case Payload of
                                         undefined -> {ok, {[], [], []}};
                                         _ -> visit(Id, Payload, 0, {[], [], []})
                                     end,
        Meta = headers(Payload),
        From = muse_mail_text:decode_header(maps:get(<<"from">>, Meta, <<>>)),
        Address = case muse_mail_text:addresses(From) of
                      [First | _] -> First;
                      [] -> From
                  end,
        Display = case binary:match(From, <<"<">>) of
                      {P, _} -> strip_quotes(muse_google_api:js_trim(binary:part(From, 0, P)));
                      nomatch -> <<>>
                  end,
        Body = case {Plain, Html} of
                   {[_ | _], _} -> join(lists:reverse(Plain), <<"\n\n">>);
                   {[], [_ | _]} -> join(lists:reverse(Html), <<"\n\n">>);
                   _ -> muse_mail_text:decode_snippet(Snippet)
               end,
        ok ?= case byte_size(Body) > ?MIB andalso muse_google_api:utf16_length(Body) > ?MIB of
                  true -> internal(?TEXT_LIMIT_MSG);
                  false -> ok
              end,
        Time = case maps:get(<<"internalDate">>, Message, undefined) of
                   undefined -> date_header(maps:get(<<"date">>, Meta, <<>>));
                   Internal -> js_number(Internal)
               end,
        {ok, #{<<"id">> => Id, <<"threadId">> => ThreadId, <<"from">> => Address,
               <<"sender">> => case Display of
                                   <<>> -> Address;
                                   _ -> Display
                               end,
               <<"to">> => muse_mail_text:addresses(maps:get(<<"to">>, Meta, <<>>)),
               <<"subject">> => muse_mail_text:decode_header(
                                  maps:get(<<"subject">>, Meta, <<"(No subject)">>)),
               <<"body">> => Body,
               <<"date">> => case Time of
                                 nan -> <<>>;
                                 _ -> muse_time:to_iso(Time)
                             end,
               <<"unread">> => lists:member(<<"UNREAD">>, Labels),
               <<"label">> => label(Labels),
               <<"attachments">> => lists:reverse(Refs)}}
    end.

%% @doc emailDraft (spec §2.5).
-spec email_draft_schema() -> muse_validate:schema().
email_draft_schema() ->
    Emails = fun(Opts) -> {array, {string, #{email => true}}, Opts} end,
    {object, [{<<"to">>, Emails(#{min => 1, max => 50})},
              {<<"cc">>, {default, Emails(#{max => 50}), []}},
              {<<"bcc">>, {default, Emails(#{max => 50}), []}},
              {<<"subject">>, {refine, {string, #{trim => true, min => 1, max => 998}},
                               fun(S) ->
                                       case binary:match(S, [<<"\r">>, <<"\n">>]) of
                                           nomatch -> ok;
                                           _ -> {error, <<"Subject must be a single line">>}
                                       end
                               end}},
              {<<"body">>, {string, #{min => 1, max => 100000}}},
              {<<"attachmentIds">>, {default, {array, {string, #{}}, #{max => 10}}, []}},
              {<<"threadId">>, {optional, {string, #{}}}},
              {<<"replyToMessageId">>, {optional, {string, #{}}}}]}.

%% Internal

full_message(Client, Id0) ->
    maybe
        {ok, Id} ?= muse_google_api:id_path(Id0),
        {ok, Json} ?= muse_google_api:get(Client, [?GMAIL, "/messages/", Id, "?format=full"]),
        hydrate_and_map(Client, Json)
    end.

message_schema() ->
    {object, [{<<"id">>, {string, #{min => 1}}},
              {<<"threadId">>, {string, #{min => 1}}},
              {<<"snippet">>, {default, {string, #{}}, <<>>}},
              {<<"internalDate">>, {optional, {string, #{}}}},
              {<<"labelIds">>, {default, {array, {string, #{}}, #{}}, []}},
              {<<"payload">>, {optional, {refine, any, fun check_part/1}}}]}.

%% The recursive Part schema of google.ts (zod lazy object).
check_part(Part) ->
    case valid_part(Part) of
        true -> ok;
        false -> {error, <<"Invalid input: malformed Gmail message part">>}
    end.

valid_part(Part) when is_map(Part) ->
    opt(Part, <<"mimeType">>, fun is_binary/1)
        andalso opt(Part, <<"filename">>, fun is_binary/1)
        andalso opt(Part, <<"headers">>,
                    fun(Hs) ->
                            is_list(Hs) andalso
                                lists:all(fun(#{<<"name">> := N, <<"value">> := V}) ->
                                                  is_binary(N) andalso is_binary(V);
                                             (_) -> false
                                          end, Hs)
                    end)
        andalso opt(Part, <<"body">>,
                    fun(B) ->
                            is_map(B) andalso opt(B, <<"data">>, fun is_binary/1)
                                andalso opt(B, <<"size">>, fun(S) -> is_number(S) andalso S >= 0 end)
                                andalso opt(B, <<"attachmentId">>, fun is_binary/1)
                    end)
        andalso opt(Part, <<"parts">>,
                    fun(Ps) -> is_list(Ps) andalso lists:all(fun valid_part/1, Ps) end);
valid_part(_) ->
    false.

opt(Map, Key, Check) ->
    case maps:find(Key, Map) of
        error -> true;
        {ok, V} -> Check(V)
    end.

hydrate(_Client, _Id, _Part, Depth) when Depth > 30 ->
    internal(<<"Gmail message MIME nesting exceeds the limit">>);
hydrate(Client, Id, Part0, Depth) ->
    Body = maps:get(<<"body">>, Part0, #{}),
    Remote = truthy(maps:get(<<"filename">>, Part0, undefined)) =:= undefined
             andalso is_text(Part0)
             andalso not is_map_key(<<"data">>, Body)
             andalso truthy(maps:get(<<"attachmentId">>, Body, undefined)) =/= undefined,
    maybe
        {ok, Part} ?= case Remote of
                          true -> fetch_body(Client, Id, Part0, Body);
                          false -> {ok, Part0}
                      end,
        case maps:find(<<"parts">>, Part) of
            {ok, Children} ->
                case hydrate_all(Client, Id, Children, Depth + 1, []) of
                    {ok, Hydrated} -> {ok, Part#{<<"parts">> => Hydrated}};
                    Error -> Error
                end;
            error ->
                {ok, Part}
        end
    end.

hydrate_all(_Client, _Id, [], _Depth, Acc) ->
    {ok, lists:reverse(Acc)};
hydrate_all(Client, Id, [Child | Rest], Depth, Acc) ->
    case hydrate(Client, Id, Child, Depth) of
        {ok, C} -> hydrate_all(Client, Id, Rest, Depth, [C | Acc]);
        Error -> Error
    end.

fetch_body(Client, Id, Part, #{<<"attachmentId">> := AttId} = Body) ->
    case maps:get(<<"size">>, Body, 0) > ?MIB of
        true ->
            internal(?TEXT_LIMIT_MSG);
        false ->
            case get_attachment(Client, Id, AttId) of
                {ok, Bytes} when byte_size(Bytes) > ?MIB ->
                    internal(?TEXT_LIMIT_MSG);
                {ok, Bytes} ->
                    Data = base64:encode(Bytes, #{mode => urlsafe, padding => false}),
                    {ok, Part#{<<"body">> => Body#{<<"data">> => Data}}};
                Error ->
                    Error
            end
    end.

visit(_Id, _Part, Depth, _Acc) when Depth > 30 ->
    internal(<<"Gmail message MIME nesting exceeds the limit">>);
visit(Id, Part, Depth, {Plain, Html, Refs}) ->
    Filename = truthy(maps:get(<<"filename">>, Part, undefined)),
    Mime = maps:get(<<"mimeType">>, Part, undefined),
    Body = maps:get(<<"body">>, Part, #{}),
    Attached = Filename =/= undefined orelse Mime =:= <<"message/rfc822">>,
    Refs1 = case {Filename, truthy(maps:get(<<"attachmentId">>, Body, undefined))} of
                {undefined, _} -> Refs;
                {_, undefined} -> Refs;
                {_, AttId} ->
                    Name = muse_google_api:encode_uri_component(muse_mail_text:well_formed(Filename)),
                    [<<Id/binary, ":", AttId/binary, ":", Name/binary>> | Refs]
            end,
    Data = truthy(maps:get(<<"data">>, Body, undefined)),
    Text = case not Attached andalso is_text(Part) andalso Data =/= undefined of
               true ->
                   case decode_base64url(Data, ?MIB) of
                       {ok, Bytes} -> {ok, muse_mail_text:decode(charset(Part), Bytes)};
                       Error -> Error
                   end;
               false ->
                   none
           end,
    case Text of
        {error, _} = E ->
            E;
        _ ->
            Acc = case {Text, Mime} of
                      {none, _} -> {Plain, Html, Refs1};
                      {{ok, T}, <<"text/plain">>} -> {[T | Plain], Html, Refs1};
                      {{ok, T}, _} -> {Plain, [muse_mail_text:html_to_text(T) | Html], Refs1}
                  end,
            case Attached of
                true -> {ok, Acc};
                false -> visit_all(Id, maps:get(<<"parts">>, Part, []), Depth + 1, Acc)
            end
    end.

visit_all(_Id, [], _Depth, Acc) ->
    {ok, Acc};
visit_all(Id, [Child | Rest], Depth, Acc) ->
    case visit(Id, Child, Depth, Acc) of
        {ok, Acc1} -> visit_all(Id, Rest, Depth, Acc1);
        Error -> Error
    end.

is_text(Part) ->
    case maps:get(<<"mimeType">>, Part, undefined) of
        <<"text/plain">> -> true;
        <<"text/html">> -> true;
        _ -> false
    end.

charset(Part) ->
    case maps:get(<<"content-type">>, headers(Part), undefined) of
        undefined ->
            <<"utf-8">>;
        Type ->
            case re:run(Type, <<"charset=[\"']?([^;\"'\\s]+)">>,
                        [caseless, {capture, all_but_first, binary}]) of
                {match, [Cs]} -> Cs;
                nomatch -> <<"utf-8">>
            end
    end.

%% Lowercased header name -> value; a later duplicate wins.
headers(Part) when is_map(Part) ->
    maps:from_list([{string:lowercase(N), V}
                    || #{<<"name">> := N, <<"value">> := V} <- maps:get(<<"headers">>, Part, [])]);
headers(_) ->
    #{}.

label(Labels) ->
    case {lists:member(<<"INBOX">>, Labels), lists:member(<<"SENT">>, Labels)} of
        {true, _} -> <<"Inbox">>;
        {false, true} -> <<"Sent">>;
        _ -> <<"Mail">>
    end.

strip_quotes(Name) ->
    re:replace(Name, <<"^\"|\"$">>, <<>>, [global, {return, binary}]).

%% `Number(string)` for internalDate.
js_number(S) ->
    case muse_google_api:js_trim(S) of
        <<>> -> 0;
        T ->
            try binary_to_integer(T)
            catch _:_ ->
                try trunc(binary_to_float(T))
                catch _:_ -> nan
                end
            end
    end.

%% `Date.parse` of a Date header: RFC 2822 or ISO.
date_header(Value) ->
    Re = <<"^\\s*(?:[A-Za-z]{3},\\s*)?(\\d{1,2})\\s+([A-Za-z]{3})\\s+(\\d{2,4})\\s+"
           "(\\d{1,2}):(\\d{2})(?::(\\d{2}))?\\s*([+-]\\d{4}|[A-Za-z]{1,5})?\\s*(?:\\(.*\\))?\\s*$">>,
    case re:run(Value, Re, [{capture, all_but_first, binary}]) of
        {match, [D, Mon, Y, H, Mi | Rest]} ->
            Months = [<<"jan">>, <<"feb">>, <<"mar">>, <<"apr">>, <<"may">>, <<"jun">>,
                      <<"jul">>, <<"aug">>, <<"sep">>, <<"oct">>, <<"nov">>, <<"dec">>],
            {S, Zone} = case Rest of
                            [] -> {<<"0">>, <<>>};
                            [Sec] -> {Sec, <<>>};
                            [Sec, Z | _] -> {Sec, Z}
                        end,
            Year = case binary_to_integer(Y) of
                       Yr when Yr < 50 -> Yr + 2000;
                       Yr when Yr < 100 -> Yr + 1900;
                       Yr -> Yr
                   end,
            Month = length(lists:takewhile(fun(M) -> M =/= string:lowercase(Mon) end, Months)) + 1,
            Sec1 = case S of <<>> -> 0; _ -> binary_to_integer(S) end,
            case {Month =< 12, zone_minutes(Zone)} of
                {true, Offset} when is_integer(Offset) ->
                    Date = {Year, Month, binary_to_integer(D)},
                    Time = {binary_to_integer(H), binary_to_integer(Mi), Sec1},
                    case calendar:valid_date(Date) of
                        true ->
                            (calendar:datetime_to_gregorian_seconds({Date, Time}) - 62167219200
                             - Offset * 60) * 1000;
                        false ->
                            nan
                    end;
                _ ->
                    nan
            end;
        nomatch ->
            muse_time:parse(Value)
    end.

zone_minutes(<<>>) -> 0;
zone_minutes(<<Sign, H:2/binary, M:2/binary>>) when Sign =:= $+; Sign =:= $- ->
    V = binary_to_integer(H) * 60 + binary_to_integer(M),
    case Sign of $+ -> V; $- -> -V end;
zone_minutes(Name) ->
    case string:uppercase(Name) of
        Z when Z =:= <<"GMT">>; Z =:= <<"UT">>; Z =:= <<"UTC">>; Z =:= <<"Z">> -> 0;
        <<"EST">> -> -300; <<"EDT">> -> -240;
        <<"CST">> -> -360; <<"CDT">> -> -300;
        <<"MST">> -> -420; <<"MDT">> -> -360;
        <<"PST">> -> -480; <<"PDT">> -> -420;
        _ -> nan
    end.

reply_headers(_Client, undefined, _ThreadId, _Subject) ->
    {ok, undefined, []};
reply_headers(Client, ReplyTo, ThreadId, Subject) ->
    Query = muse_google_api:form_encode([{<<"format">>, <<"metadata">>},
                                         {<<"metadataHeaders">>, <<"Message-ID">>},
                                         {<<"metadataHeaders">>, <<"References">>},
                                         {<<"metadataHeaders">>, <<"Subject">>}]),
    maybe
        {ok, Id} ?= muse_google_api:id_path(ReplyTo),
        {ok, Json} ?= muse_google_api:get(Client, [?GMAIL, "/messages/", Id, "?", Query]),
        {ok, Source} ?= muse_validate:parse(message_schema(), Json),
        SourceThread = maps:get(<<"threadId">>, Source),
        ok ?= case ThreadId =/= undefined andalso SourceThread =/= ThreadId of
                  true -> internal(<<"Reply thread does not match the source message">>);
                  false -> ok
              end,
        Meta = headers(maps:get(<<"payload">>, Source, undefined)),
        {ok, MessageId} ?= muse_google_api:single_line(maps:get(<<"message-id">>, Meta, <<>>),
                                                       <<"Message-ID">>),
        ok ?= case re:run(MessageId, <<"^<[^<>\\s]+@[^<>\\s]+>$">>, [{capture, none}]) of
                  match -> ok;
                  nomatch -> internal(<<"Source message has no valid Message-ID for reply threading">>)
              end,
        ok ?= case normalized_subject(Subject) =:=
                   normalized_subject(maps:get(<<"subject">>, Meta, <<>>)) of
                  true -> ok;
                  false -> internal(<<"Reply subject must match the source message subject">>)
              end,
        {ok, Refs0} ?= muse_google_api:single_line(maps:get(<<"references">>, Meta, <<>>),
                                                   <<"References">>),
        Refs = muse_google_api:js_trim(Refs0),
        ok ?= case Refs =:= <<>> orelse
                   re:run(Refs, <<"^(?:<[^<>\\s]+@[^<>\\s]+>\\s*)+$">>, [{capture, none}]) =:= match of
                  true -> ok;
                  false -> internal(<<"Source message has invalid References headers">>)
              end,
        Found = case re:run(Refs, <<"<[^<>\\s]+>">>, [global, {capture, first, binary}]) of
                    {match, Ms} -> [M || [M] <- Ms];
                    nomatch -> []
                end,
        Chain = join(unique(Found ++ [MessageId]), <<" ">>),
        ok ?= case muse_google_api:utf16_length(Chain) > 950 of
                  true -> internal(<<"Reply References header exceeds the supported length">>);
                  false -> ok
              end,
        {ok, SourceThread, [<<"In-Reply-To: ", MessageId/binary>>,
                            <<"References: ", Chain/binary>>]}
    end.

normalized_subject(Subject) ->
    Decoded = muse_mail_text:decode_header(Subject),
    muse_google_api:js_trim(re:replace(Decoded, <<"^(?:\\s*re:\\s*)+">>, <<>>,
                                       [caseless, unicode, {return, binary}])).

validate_attachments(Attachments) when length(Attachments) > 10 ->
    internal(<<"Attachment count exceeds the limit of 10">>);
validate_attachments(Attachments) ->
    validate_attachments(Attachments, 0).

validate_attachments([], Total) when Total > ?MAX_TOTAL_ATTACHMENTS ->
    internal(<<"Total attachment size exceeds the 20 MiB limit">>);
validate_attachments([], _) ->
    ok;
validate_attachments([#{name := Name, mime_type := Type, bytes := Bytes} | Rest], Total) ->
    maybe
        {ok, _} ?= muse_google_api:single_line(Name, <<"attachment name">>),
        ok ?= case Name =:= <<>> orelse byte_size(muse_mail_text:well_formed(Name)) > 180 of
                  true -> internal(<<"Invalid attachment name length">>);
                  false -> ok
              end,
        ok ?= case re:run(Type, <<"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$">>,
                          [{capture, none}]) of
                  match -> ok;
                  nomatch -> internal(<<"Invalid attachment MIME type">>)
              end,
        ok ?= case byte_size(Bytes) > ?MAX_ATTACHMENT of
                  true -> internal(<<"Attachment is too large (10 MiB limit)">>);
                  false -> ok
              end,
        validate_attachments(Rest, Total + byte_size(Bytes))
    end.

attachment_part(#{name := Name, mime_type := Type, bytes := Bytes}) ->
    Encoded = muse_google_api:encode_uri_component(muse_mail_text:well_formed(Name)),
    Escaped = << <<(case C of
                        $' -> <<"%27">>;
                        $( -> <<"%28">>;
                        $) -> <<"%29">>;
                        $* -> <<"%2A">>;
                        _ -> <<C>>
                    end)/binary>> || <<C>> <= Encoded >>,
    join([<<"Content-Type: ", Type/binary>>,
          <<"Content-Disposition: attachment; filename*=UTF-8''", Escaped/binary>>,
          <<"Content-Transfer-Encoding: base64">>, <<>>, wrap_base64(Bytes)], <<"\r\n">>).

%% Chunks of at most 42 UTF-8 bytes, never splitting a code point.
encoded_subject(Subject) ->
    Chunks = subject_chunks(Subject, <<>>, []),
    join([<<"=?UTF-8?B?", (base64:encode(C))/binary, "?=">> || C <- Chunks], <<"\r\n ">>).

subject_chunks(<<>>, <<>>, Acc) ->
    lists:reverse(Acc);
subject_chunks(<<>>, Chunk, Acc) ->
    lists:reverse([Chunk | Acc]);
subject_chunks(<<C/utf8, Rest/binary>>, Chunk, Acc) ->
    Char = <<C/utf8>>,
    case byte_size(Chunk) + byte_size(Char) > 42 of
        true -> subject_chunks(Rest, Char, [Chunk | Acc]);
        false -> subject_chunks(Rest, <<Chunk/binary, Char/binary>>, Acc)
    end.

wrap_base64(Bytes) ->
    join(lines(base64:encode(Bytes), []), <<"\r\n">>).

lines(<<>>, Acc) -> lists:reverse(Acc);
lines(<<Line:76/binary, Rest/binary>>, Acc) -> lines(Rest, [Line | Acc]);
lines(Last, Acc) -> lists:reverse([Last | Acc]).

sent(Result) ->
    Schema = {object, [{<<"id">>, {string, #{min => 1}}},
                       {<<"threadId">>, {optional, {string, #{}}}}]},
    case muse_validate:check(Schema, Result) of
        {ok, Sent} -> {ok, Sent};
        {error, _} -> {error, {outcome_unknown, <<"Google may have completed this action. "
                                                  "Check Google before trying again.">>}}
    end.

all_ok(Results) ->
    case [E || {error, _} = E <- Results] of
        [] -> ok;
        [First | _] -> First
    end.

unique(List) ->
    lists:reverse(lists:foldl(fun(X, Acc) ->
                                      case lists:member(X, Acc) of
                                          true -> Acc;
                                          false -> [X | Acc]
                                      end
                              end, [], List)).

truthy(<<>>) -> undefined;
truthy(V) when is_binary(V) -> V;
truthy(_) -> undefined.

join(Parts, Sep) ->
    iolist_to_binary(lists:join(Sep, Parts)).

ceil_div(A, B) -> (A + B - 1) div B.

internal(Msg) ->
    {error, {internal, Msg}}.
