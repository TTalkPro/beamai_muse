%% Ported from OpenMuse tests/google.test.ts (Gmail cases) plus byte-exact
%% vectors produced by the original TypeScript (muse_google_vectors).
-module(muse_gmail_tests).
-include_lib("eunit/include/eunit.hrl").

-import(muse_google_test_http, [stub/1, calls/0, json/1, json/2, client/0, header/2, body_json/1]).

-define(MIB, 1048576).

b64url(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

email() ->
    #{<<"to">> => [<<"reader@example.com">>],
      <<"subject">> => <<"Your visit résumé"/utf8>>,
      <<"body">> => <<"Hello <reader>,\nHere is your form.\nThank you.">>}.

http_test_() ->
    {foreach, fun muse_google_test_http:start/0, fun(_) -> muse_google_test_http:stop() end,
     [fun nested_plain_text_and_refs/0,
      fun folded_encoded_words/0,
      fun q_words_keep_spaces/0,
      fun unknown_body_charset/0,
      fun html_only_message/0,
      fun attachment_bytes_and_limits/0,
      fun send_crlf_mime/0,
      fun injection_fails_before_token/0,
      fun replies_preserve_references/0,
      fun reply_metadata_cannot_inject/0,
      fun thread_reads_sent_and_archived/0,
      fun thread_hydrates_remote_bodies/0,
      fun thread_from_other_thread/0,
      fun rfc2231_and_display_names/0,
      fun attached_message_not_merged/0,
      fun lone_surrogate_filename/0,
      fun outgoing_name_with_replacement_char/0,
      fun send_outcome_unknown/0,
      fun scope_errors_visible/0,
      fun mime_vectors_end_to_end/0]}.

nested_plain_text_and_refs() ->
    stub(fun(get, #{path := P}, Headers, _) ->
                 ?assertEqual(<<"Bearer synthetic-access-token">>, header(<<"authorization">>, Headers)),
                 case binary:longest_common_suffix([P, <<"/messages">>]) of
                     9 -> json(#{<<"messages">> => [#{<<"id">> => <<"msg1">>}]});
                     _ -> json(nested_message())
                 end
         end),
    {ok, [Mail]} = muse_gmail:list_mail(client(), <<"from:museum@example.com">>),
    [{get, U1, _, _}, {get, U2, _, _}] = calls(),
    ?assertEqual(<<"gmail.googleapis.com">>, maps:get(host, U1)),
    ?assertEqual(<<"from:museum@example.com">>, proplists:get_value(<<"q">>, maps:get(query, U1))),
    ?assertEqual(<<"30">>, proplists:get_value(<<"maxResults">>, maps:get(query, U1))),
    ?assertEqual(<<"full">>, proplists:get_value(<<"format">>, maps:get(query, U2))),
    ?assertMatch(#{<<"body">> := <<"Please complete the attached form.">>,
                   <<"from">> := <<"museum@example.com">>,
                   <<"sender">> := <<"Museum, Community">>,
                   <<"to">> := [<<"guardian@example.com">>],
                   <<"unread">> := true,
                   <<"label">> := <<"Inbox">>,
                   <<"date">> := <<"2026-10-10T19:00:00.000Z">>,
                   <<"attachments">> := [<<"msg1:attach1:Permission%3A%20form.pdf">>]}, Mail).

nested_message() ->
    #{<<"id">> => <<"msg1">>, <<"threadId">> => <<"thread1">>,
      <<"internalDate">> => <<"1791658800000">>, <<"labelIds">> => [<<"INBOX">>, <<"UNREAD">>],
      <<"payload">> =>
          #{<<"headers">> => [#{<<"name">> => <<"From">>, <<"value">> => <<"\"Museum, Community\" <museum@example.com>">>},
                              #{<<"name">> => <<"To">>, <<"value">> => <<"Guardian <guardian@example.com>">>},
                              #{<<"name">> => <<"Subject">>, <<"value">> => <<"Visit form">>}],
            <<"mimeType">> => <<"multipart/mixed">>,
            <<"parts">> =>
                [#{<<"mimeType">> => <<"multipart/alternative">>,
                   <<"parts">> => [#{<<"mimeType">> => <<"text/html">>,
                                     <<"body">> => #{<<"data">> => b64url(<<"<script>unsafe</script>">>)}},
                                   #{<<"mimeType">> => <<"text/plain">>,
                                     <<"body">> => #{<<"data">> => b64url(<<"Please complete the attached form.">>)}}]},
                 #{<<"mimeType">> => <<"application/pdf">>, <<"filename">> => <<"Permission: form.pdf">>,
                   <<"body">> => #{<<"attachmentId">> => <<"attach1">>, <<"size">> => 1024}}]}}.

thread_of(Messages) ->
    stub(fun(get, _, _, _) -> json(#{<<"id">> => <<"thread1">>, <<"messages">> => Messages}) end).

folded_encoded_words() ->
    Word = fun(V) -> <<"=?UTF-8?B?", (base64:encode(V))/binary, "?=">> end,
    lists:foreach(
      fun(Sep) ->
              thread_of([#{<<"id">> => <<"msg1">>, <<"threadId">> => <<"thread1">>,
                           <<"payload">> => #{<<"headers">> =>
                               [#{<<"name">> => <<"Subject">>,
                                  <<"value">> => <<(Word(<<"Visit résumé"/utf8>>))/binary, Sep/binary,
                                                   (Word(<<" details">>))/binary>>},
                                #{<<"name">> => <<"From">>,
                                  <<"value">> => <<(Word(<<"Community">>))/binary, Sep/binary,
                                                   (Word(<<" Museum">>))/binary, " <museum@example.com>">>}]}}]),
              {ok, [Mail]} = muse_gmail:get_thread(client(), <<"thread1">>),
              ?assertEqual(<<"Visit résumé details"/utf8>>, maps:get(<<"subject">>, Mail)),
              ?assertEqual(<<"Community Museum">>, maps:get(<<"sender">>, Mail)),
              ?assertEqual(<<"museum@example.com">>, maps:get(<<"from">>, Mail))
      end, [<<" ">>, <<"\t">>, <<"\r\n ">>, <<"\r\n\t">>, <<" \r\n \t">>]).

q_words_keep_spaces() ->
    thread_of([#{<<"id">> => <<"msg1">>, <<"threadId">> => <<"thread1">>,
                 <<"payload">> => #{<<"headers">> => [#{<<"name">> => <<"Subject">>,
                                                        <<"value">> => <<"Re: =?UTF-8?Q?Visit_r=C3=A9sum=C3=A9?= notes">>}]}}]),
    {ok, [Mail]} = muse_gmail:get_thread(client(), <<"thread1">>),
    ?assertEqual(<<"Re: Visit résumé notes"/utf8>>, maps:get(<<"subject">>, Mail)).

unknown_body_charset() ->
    Charsets = #{<<"known">> => <<"utf-8">>, <<"unknown">> => <<"unknown-8bit">>},
    Bodies = #{<<"known">> => <<"Opening hours">>, <<"unknown">> => <<"Café tickets"/utf8>>},
    stub(fun(get, #{path := P}, _, _) ->
                 case lists:last(binary:split(P, <<"/">>, [global])) of
                     <<"messages">> ->
                         json(#{<<"messages">> => [#{<<"id">> => <<"known">>}, #{<<"id">> => <<"unknown">>}]});
                     Id ->
                         json(#{<<"id">> => Id, <<"threadId">> => <<"thread-", Id/binary>>,
                                <<"labelIds">> => [<<"INBOX">>],
                                <<"payload">> => #{<<"headers">> => [#{<<"name">> => <<"From">>, <<"value">> => <<"Museum <museum@example.com>">>},
                                                                     #{<<"name">> => <<"Content-Type">>, <<"value">> => <<"text/plain; charset=", (maps:get(Id, Charsets))/binary>>}],
                                                   <<"mimeType">> => <<"text/plain">>,
                                                   <<"body">> => #{<<"data">> => b64url(maps:get(Id, Bodies))}}})
                 end
         end),
    {ok, Mails} = muse_gmail:list_mail(client(), undefined),
    ?assertEqual([<<"Opening hours">>, <<"Café tickets"/utf8>>], [maps:get(<<"body">>, M) || M <- Mails]),
    [{get, U1, _, _} | _] = calls(),
    ?assertEqual(<<"in:inbox">>, proplists:get_value(<<"q">>, maps:get(query, U1))).

html_only_message() ->
    Full = binary:copy(<<"Complete museum itinerary. ">>, 4500),
    Html = <<"<html><head><style>.secret{display:none}</style></head><body><h1>Welcome &amp; thank you</h1><p>",
             Full/binary, "</p><p>Last details &copy; &#x1f30e;.</p><img src=\"https://tracker.invalid\"><script>alert(1)</script>"
             "<iframe src=\"https://tracker.invalid\">hidden frame</iframe></body></html>">>,
    stub(fun(get, #{path := P}, _, _) ->
                 case binary:longest_common_suffix([P, <<"/messages">>]) of
                     9 -> json(#{<<"messages">> => [#{<<"id">> => <<"msg1">>}]});
                     _ -> json(#{<<"id">> => <<"msg1">>, <<"threadId">> => <<"thread1">>,
                                 <<"snippet">> => <<"Welcome &amp; thank you">>,
                                 <<"payload">> => #{<<"mimeType">> => <<"text/html">>,
                                                    <<"body">> => #{<<"data">> => b64url(Html)}}})
                 end
         end),
    {ok, [#{<<"body">> := Body}]} = muse_gmail:list_mail(client(), undefined),
    ?assertMatch(<<"Welcome & thank you\n", _/binary>>, Body),
    ?assertNotEqual(nomatch, binary:match(Body, string:trim(Full))),
    ?assertEqual(<<"Last details © 🌎."/utf8>>, binary:part(Body, byte_size(Body), -byte_size(<<"Last details © 🌎."/utf8>>))),
    ?assertEqual(nomatch, re:run(Body, <<"alert\\(1\\)|secret|hidden frame|tracker\\.invalid|<h1>">>)),
    ?assertEqual(2, length(calls())).

attachment_bytes_and_limits() ->
    Original = <<0, 255, 127, 1, 2>>,
    stub(fun(get, #{path := P}, _, _) ->
                 ?assertEqual(<<"/gmail/v1/users/me/messages/msg1/attachments/attach1">>, P),
                 json(#{<<"size">> => 5, <<"data">> => b64url(Original)})
         end),
    ?assertEqual({ok, Original}, muse_gmail:get_attachment(client(), <<"msg1">>, <<"attach1">>)),
    stub(fun(_, _, _, _) -> json(#{<<"size">> => 10 * ?MIB + 1, <<"data">> => <<"AA">>}) end),
    ?assertEqual({error, {internal, <<"Attachment is too large (10 MiB limit)">>}},
                 muse_gmail:get_attachment(client(), <<"msg1">>, <<"attach1">>)),
    stub(fun(_, _, _, _) -> json(#{<<"data">> => <<"not valid base64!">>}) end),
    ?assertEqual({error, {internal, <<"Invalid base64url attachment or message body">>}},
                 muse_gmail:get_attachment(client(), <<"msg1">>, <<"attach1">>)),
    stub(fun(_, _, _, _) -> json(#{<<"size">> => 2, <<"data">> => b64url(Original)}) end),
    ?assertEqual({error, {internal, <<"Google attachment size does not match its actual byte length">>}},
                 muse_gmail:get_attachment(client(), <<"msg1">>, <<"attach1">>)),
    ?assertEqual({error, {internal, <<"Invalid Google resource ID">>}},
                 muse_gmail:get_attachment(client(), <<"../x">>, <<"attach1">>)).

send_stub(Reply) ->
    stub(fun(get, #{path := <<"/gmail/v1/users/me/profile">>}, _, _) ->
                 json(#{<<"emailAddress">> => <<"me@example.com">>});
            (Method, Url, Headers, Body) ->
                 Reply(Method, Url, Headers, Body)
         end).

raw_mime(Body) ->
    #{<<"raw">> := Raw} = body_json(Body),
    base64:decode(Raw, #{mode => urlsafe, padding => false}).

send_crlf_mime() ->
    Attachment = <<0, 127, 255, 10>>,
    Self = self(),
    send_stub(fun(post, #{path := <<"/gmail/v1/users/me/messages/send">>}, Headers, Body) ->
                      ?assertEqual(<<"application/json">>, header(<<"content-type">>, Headers)),
                      #{<<"raw">> := Raw} = body_json(Body),
                      ?assertEqual(match, re:run(Raw, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}])),
                      Self ! {mime, raw_mime(Body)},
                      json(#{<<"id">> => <<"sent1">>, <<"threadId">> => <<"thread1">>})
              end),
    ?assertEqual({ok, #{<<"id">> => <<"sent1">>, <<"threadId">> => <<"thread1">>}},
                 muse_gmail:send_email(client(), email(),
                                       [#{name => <<"visit résumé.pdf"/utf8>>,
                                          mime_type => <<"application/pdf">>, bytes => Attachment}])),
    Mime = receive {mime, M} -> M end,
    ?assertEqual(nomatch, re:run(Mime, <<"(?<!\\r)\\n">>)),
    ?assertMatch({match, _}, re:run(Mime, <<"From: me@example\\.com\\r\\n">>)),
    {match, Words} = re:run(Mime, <<"=\\?UTF-8\\?B\\?([^?]+)\\?=">>, [global, {capture, all_but_first, binary}]),
    ?assertEqual(<<"Your visit résumé"/utf8>>, iolist_to_binary([base64:decode(W) || [W] <- Words])),
    ?assertMatch({_, _}, binary:match(Mime, <<"Content-Type: text/plain; charset=UTF-8">>)),
    ?assertMatch({_, _}, binary:match(Mime, base64:encode(<<"Hello <reader>,\r\nHere is your form.\r\nThank you.">>))),
    ?assertMatch({_, _}, binary:match(Mime, base64:encode(Attachment))),
    ?assertMatch({_, _}, binary:match(Mime, <<"filename*=UTF-8''visit%20r%C3%A9sum%C3%A9.pdf">>)),
    ?assertEqual(nomatch, binary:match(Mime, <<"Content-Type: text/html">>)),
    ?assertEqual(2, length(calls())).

injection_fails_before_token() ->
    Self = self(),
    Client = muse_google_api:token_client(fun() -> Self ! token_read, {ok, <<"synthetic">>} end),
    stub(fun(_, _, _, _) -> error(unexpected_fetch) end),
    Pdf = fun(Name, Type, Bytes) -> #{name => Name, mime_type => Type, bytes => Bytes} end,
    ?assertMatch({error, {422, _}},
                 muse_gmail:send_email(Client, (email())#{<<"subject">> => <<"Hello\r\nBcc: intruder@example.com">>}, [])),
    ?assertMatch({error, {422, _}},
                 muse_gmail:send_email(Client, (email())#{<<"to">> => [<<"reader@example.com\r\nBcc: intruder@example.com">>]}, [])),
    ?assertEqual({error, {internal, <<"Invalid attachment name: header control characters are not allowed">>}},
                 muse_gmail:send_email(Client, email(), [Pdf(<<"a\r\nX-Injection: yes.pdf">>, <<"application/pdf">>, <<>>)])),
    ?assertEqual({error, {internal, <<"Invalid attachment MIME type">>}},
                 muse_gmail:send_email(Client, email(), [Pdf(<<"a.pdf">>, <<"application/pdf\r\nX-Injection: yes">>, <<>>)])),
    ?assertEqual({error, {internal, <<"Attachment is too large (10 MiB limit)">>}},
                 muse_gmail:send_email(Client, email(), [Pdf(<<"big.pdf">>, <<"application/pdf">>, <<0:(8 * (10 * ?MIB + 1))>>)])),
    Big = <<0:(8 * 10 * ?MIB)>>,
    ?assertEqual({error, {internal, <<"Total attachment size exceeds the 20 MiB limit">>}},
                 muse_gmail:send_email(Client, email(), [Pdf(integer_to_binary(I), <<"application/pdf">>, Big) || I <- [0, 1, 2]])),
    ?assertEqual({error, {internal, <<"Attachment count exceeds the limit of 10">>}},
                 muse_gmail:send_email(Client, email(), [Pdf(<<"a.pdf">>, <<"application/pdf">>, <<>>) || _ <- lists:seq(1, 11)])),
    ?assertEqual({error, {internal, <<"Invalid attachment name length">>}},
                 muse_gmail:send_email(Client, email(), [Pdf(binary:copy(<<"é"/utf8>>, 91), <<"application/pdf">>, <<>>)])),
    receive token_read -> ?assert(false) after 0 -> ok end,
    ?assertEqual([], calls()).

source_message() ->
    #{<<"id">> => <<"source1">>, <<"threadId">> => <<"source-thread">>,
      <<"payload">> => #{<<"headers">> => [#{<<"name">> => <<"Message-ID">>, <<"value">> => <<"<source@example.com>">>},
                                           #{<<"name">> => <<"References">>, <<"value">> => <<"<earlier@example.com>">>},
                                           #{<<"name">> => <<"Subject">>, <<"value">> => <<"Visit form">>}]}}.

replies_preserve_references() ->
    Self = self(),
    send_stub(fun(get, #{path := <<"/gmail/v1/users/me/messages/source1">>, query := Q}, _, _) ->
                      ?assertEqual(<<"metadata">>, proplists:get_value(<<"format">>, Q)),
                      ?assertEqual([<<"Message-ID">>, <<"References">>, <<"Subject">>],
                                   proplists:get_all_values(<<"metadataHeaders">>, Q)),
                      json(source_message());
                 (post, _, _, Body) ->
                      Self ! write,
                      #{<<"threadId">> := ThreadId} = body_json(Body),
                      ?assertEqual(<<"source-thread">>, ThreadId),
                      Mime = raw_mime(Body),
                      ?assertMatch({_, _}, binary:match(Mime, <<"In-Reply-To: <source@example.com>\r\n">>)),
                      ?assertMatch({_, _}, binary:match(Mime, <<"References: <earlier@example.com> <source@example.com>\r\n">>)),
                      json(#{<<"id">> => <<"reply1">>, <<"threadId">> => ThreadId})
              end),
    Reply = (email())#{<<"subject">> => <<"Re: Visit form">>, <<"replyToMessageId">> => <<"source1">>},
    ?assertMatch({ok, #{<<"id">> := <<"reply1">>}}, muse_gmail:send_email(client(), Reply, [])),
    ?assertEqual({error, {internal, <<"Reply thread does not match the source message">>}},
                 muse_gmail:send_email(client(), Reply#{<<"threadId">> => <<"wrong-thread">>}, [])),
    ?assertEqual({error, {internal, <<"Reply subject must match the source message subject">>}},
                 muse_gmail:send_email(client(), Reply#{<<"subject">> => <<"Unrelated subject">>}, [])),
    ?assertEqual({error, {internal, <<"Replies require replyToMessageId to resolve the source message headers">>}},
                 muse_gmail:send_email(client(), (email())#{<<"threadId">> => <<"source-thread">>}, [])),
    ?assertEqual(1, length([x || {post, _, _, _} <- calls()])).

reply_metadata_cannot_inject() ->
    send_stub(fun(get, _, _, _) ->
                      json(#{<<"id">> => <<"source1">>, <<"threadId">> => <<"thread1">>,
                             <<"payload">> => #{<<"headers">> =>
                                 [#{<<"name">> => <<"Message-ID">>, <<"value">> => <<"<ok@example.com>\r\nBcc: intruder@example.com">>},
                                  #{<<"name">> => <<"Subject">>, <<"value">> => <<"Your visit résumé"/utf8>>}]}});
                 (_, _, _, _) ->
                      error(unexpected_write)
              end),
    ?assertEqual({error, {internal, <<"Invalid Message-ID: header control characters are not allowed">>}},
                 muse_gmail:send_email(client(), (email())#{<<"replyToMessageId">> => <<"source1">>}, [])),
    ?assertEqual([], [x || {M, _, _, _} <- calls(), M =/= get]).

thread_reads_sent_and_archived() ->
    stub(fun(get, #{path := P, query := Q}, _, _) ->
                 ?assertEqual(<<"/gmail/v1/users/me/threads/thread1">>, P),
                 ?assertEqual(<<"full">>, proplists:get_value(<<"format">>, Q)),
                 json(#{<<"id">> => <<"thread1">>, <<"messages">> =>
                            [#{<<"id">> => <<"archived1">>, <<"threadId">> => <<"thread1">>, <<"labelIds">> => [],
                               <<"payload">> => #{<<"mimeType">> => <<"text/plain">>, <<"body">> => #{<<"data">> => b64url(<<"Archived original">>)}}},
                             #{<<"id">> => <<"sent1">>, <<"threadId">> => <<"thread1">>, <<"labelIds">> => [<<"SENT">>],
                               <<"payload">> => #{<<"mimeType">> => <<"text/html">>, <<"body">> => #{<<"data">> => b64url(<<"<p>Sent reply &amp; thanks</p>">>)}}}]})
         end),
    {ok, Mails} = muse_gmail:get_thread(client(), <<"thread1">>),
    ?assertEqual([{<<"archived1">>, <<"Archived original">>, <<"Mail">>},
                  {<<"sent1">>, <<"Sent reply & thanks">>, <<"Sent">>}],
                 [{maps:get(<<"id">>, M), maps:get(<<"body">>, M), maps:get(<<"label">>, M)} || M <- Mails]).

thread_hydrates_remote_bodies() ->
    Html = <<"<p>Entire message beyond the snippet.</p>">>,
    stub(fun(get, #{path := P}, _, _) ->
                 case binary:match(P, <<"/attachments/">>) of
                     nomatch ->
                         json(#{<<"id">> => <<"thread1">>, <<"messages">> =>
                                    [#{<<"id">> => <<"msg1">>, <<"threadId">> => <<"thread1">>,
                                       <<"snippet">> => <<"Entire message...">>,
                                       <<"payload">> => #{<<"mimeType">> => <<"text/html">>,
                                                          <<"body">> => #{<<"attachmentId">> => <<"body1">>, <<"size">> => 38}}}]});
                     _ ->
                         json(#{<<"data">> => b64url(Html), <<"size">> => byte_size(Html)})
                 end
         end),
    ?assertMatch({ok, [#{<<"body">> := <<"Entire message beyond the snippet.">>}]},
                 muse_gmail:get_thread(client(), <<"thread1">>)),
    ?assertEqual([<<"/gmail/v1/users/me/threads/thread1">>,
                  <<"/gmail/v1/users/me/messages/msg1/attachments/body1">>],
                 [maps:get(path, U) || {_, U, _, _} <- calls()]),
    %% A declared size over 1 MiB is refused before fetching.
    stub(fun(get, _, _, _) ->
                 json(#{<<"id">> => <<"thread1">>, <<"messages">> =>
                            [#{<<"id">> => <<"msg1">>, <<"threadId">> => <<"thread1">>,
                               <<"payload">> => #{<<"mimeType">> => <<"text/plain">>,
                                                  <<"body">> => #{<<"attachmentId">> => <<"b">>, <<"size">> => ?MIB + 1}}}]})
         end),
    ?assertEqual({error, {internal, <<"Gmail message text exceeds the 1 MiB limit">>}},
                 muse_gmail:get_thread(client(), <<"thread1">>)).

thread_from_other_thread() ->
    thread_of([#{<<"id">> => <<"m">>, <<"threadId">> => <<"other">>}]),
    ?assertEqual({error, {internal, <<"Google returned messages from a different thread">>}},
                 muse_gmail:get_thread(client(), <<"thread1">>)).

rfc2231_and_display_names() ->
    stub(fun(get, #{path := P}, _, _) ->
                 case binary:longest_common_suffix([P, <<"/messages">>]) of
                     9 -> json(#{<<"messages">> => [#{<<"id">> => <<"msg-charset">>}]});
                     _ -> json(#{<<"id">> => <<"msg-charset">>, <<"threadId">> => <<"thread-charset">>,
                                 <<"payload">> => #{<<"mimeType">> => <<"text/plain">>,
                                                    <<"headers">> => [#{<<"name">> => <<"From">>, <<"value">> => <<"<bare@example.com>">>},
                                                                      #{<<"name">> => <<"To">>, <<"value">> => <<"\"billing@other.example\" <real@example.com>">>},
                                                                      #{<<"name">> => <<"Subject">>, <<"value">> => <<"=?UTF-8*en?B?SGVsbG8=?=">>},
                                                                      #{<<"name">> => <<"Content-Type">>, <<"value">> => <<"text/plain; charset=unknown-8bit">>}],
                                                    <<"body">> => #{<<"data">> => b64url(<<"Body with unknown charset ✓"/utf8>>)}}})
                 end
         end),
    {ok, [Mail]} = muse_gmail:list_mail(client(), undefined),
    ?assertMatch(#{<<"body">> := <<"Body with unknown charset ✓"/utf8>>, <<"subject">> := <<"Hello">>,
                   <<"from">> := <<"bare@example.com">>, <<"sender">> := <<"bare@example.com">>,
                   <<"to">> := [<<"real@example.com">>]}, Mail).

attached_message_not_merged() ->
    {ok, Mail} = muse_gmail:map_message(
                   #{<<"id">> => <<"msg-forward">>, <<"threadId">> => <<"thread-forward">>,
                     <<"payload">> => #{<<"mimeType">> => <<"multipart/mixed">>, <<"parts">> =>
                         [#{<<"mimeType">> => <<"text/plain">>, <<"body">> => #{<<"data">> => b64url(<<"Outer body text.">>)}},
                          #{<<"mimeType">> => <<"message/rfc822">>, <<"filename">> => <<"forwarded.eml">>,
                            <<"body">> => #{<<"attachmentId">> => <<"attach2">>, <<"size">> => 42},
                            <<"parts">> => [#{<<"mimeType">> => <<"text/plain">>,
                                              <<"body">> => #{<<"data">> => b64url(<<"INNER ATTACHED MESSAGE BODY">>)}}]}]}}),
    ?assertEqual(<<"Outer body text.">>, maps:get(<<"body">>, Mail)),
    ?assertEqual([<<"msg-forward:attach2:forwarded.eml">>], maps:get(<<"attachments">>, Mail)).

lone_surrogate_filename() ->
    %% OTP's JSON decoder rejects lone surrogates that V8 accepts.
    Raw = <<"{\"id\":\"msg1\",\"threadId\":\"thread1\",\"internalDate\":\"1791658800000\",\"labelIds\":[\"INBOX\"],"
            "\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"sender@example.com\"}],\"mimeType\":\"multipart/mixed\","
            "\"parts\":[{\"mimeType\":\"text/plain\",\"body\":{\"data\":\"", (b64url(<<"See attached.">>))/binary, "\"}},"
            "{\"mimeType\":\"application/pdf\",\"filename\":\"form\\uD800.pdf\",\"body\":{\"attachmentId\":\"attach1\",\"size\":10}}]}}">>,
    stub(fun(get, #{path := P}, _, _) ->
                 case binary:longest_common_suffix([P, <<"/messages">>]) of
                     9 -> json(#{<<"messages">> => [#{<<"id">> => <<"msg1">>}]});
                     _ -> {raw, 200, Raw}
                 end
         end),
    ?assertMatch({ok, [#{<<"attachments">> := [<<"msg1:attach1:form%EF%BF%BD.pdf">>]}]},
                 muse_gmail:list_mail(client(), undefined)).

outgoing_name_with_replacement_char() ->
    Self = self(),
    send_stub(fun(post, _, _, Body) ->
                      Self ! {mime, raw_mime(Body)},
                      json(#{<<"id">> => <<"sent1">>, <<"threadId">> => <<"thread1">>})
              end),
    %% Invalid UTF-8 in a name is replaced like a lone surrogate in JS.
    {ok, _} = muse_gmail:send_email(client(), email(),
                                    [#{name => <<"form", 16#ED, 16#A0, 16#80, ".pdf">>,
                                       mime_type => <<"application/pdf">>, bytes => <<1>>}]),
    Mime = receive {mime, M} -> M end,
    ?assertMatch({_, _}, binary:match(Mime, <<"filename*=UTF-8''form%EF%BF%BD%EF%BF%BD%EF%BF%BD.pdf">>)).

send_outcome_unknown() ->
    Unknown = {error, {outcome_unknown, <<"Google may have completed this action. Check Google before trying again.">>}},
    lists:foreach(
      fun(Failure) ->
              send_stub(fun(post, _, _, _) -> Failure end),
              ?assertEqual(Unknown, muse_gmail:send_email(client(), email(), []))
      end,
      [{error, {gun_error, closed}}, {error, timeout}, json(503, #{<<"error">> => #{<<"message">> => <<"upstream failed">>}}),
       {status, 408}, json(#{<<"unexpected">> => <<"body">>}), {raw, 200, <<"not json">>}, {status, 302}]),
    ?assertEqual(7, length([x || {post, _, _, _} <- calls()])),
    send_stub(fun(post, _, _, _) -> json(400, #{<<"error">> => #{<<"message">> => <<"Invalid To header">>}}) end),
    ?assertEqual({error, {502, <<"Google API (400): Invalid To header">>}},
                 muse_gmail:send_email(client(), email(), [])).

scope_errors_visible() ->
    stub(fun(_, _, _, _) ->
                 json(403, #{<<"error">> => #{<<"message">> => <<"Request had insufficient authentication scopes.">>}})
         end),
    ?assertEqual({error, {502, <<"Google API (403): Request had insufficient authentication scopes.">>}},
                 muse_gmail:list_mail(client(), undefined)),
    stub(fun(_, _, _, _) -> {error, econnrefused} end),
    ?assertEqual({error, {internal, <<"Could not reach Google; check the connection and try again">>}},
                 muse_gmail:list_mail(client(), undefined)).

%% sendEmail end to end against the original's output: only the Date,
%% Message-ID and boundary (time and random) are substituted.
mime_vectors_end_to_end() ->
    lists:foreach(fun mime_vector/1, muse_google_vectors:mime()).

mime_vector(#{<<"name">> := Name, <<"draft">> := Draft, <<"attachments">> := Atts, <<"raw">> := Raw,
              <<"date">> := Date, <<"mid">> := Mid, <<"boundary">> := Boundary,
              <<"threadId">> := ThreadId, <<"result">> := Result}) ->
    Expected = base64:decode(Raw, #{mode => urlsafe, padding => false}),
    Self = self(),
    send_stub(fun(get, #{path := <<"/gmail/v1/users/me/messages/source1">>}, _, _) ->
                      json(#{<<"id">> => <<"source1">>, <<"threadId">> => <<"source-thread">>,
                             <<"payload">> => #{<<"headers">> =>
                                 [#{<<"name">> => <<"Message-ID">>, <<"value">> => <<"<source@example.com>">>},
                                  #{<<"name">> => <<"References">>, <<"value">> => <<"<a@example.com>  <b@example.com>">>},
                                  #{<<"name">> => <<"Subject">>, <<"value">> => <<"Visit form">>}]}});
                 (post, _, _, Body) ->
                      Sent = body_json(Body),
                      Self ! {sent, Sent},
                      json(#{<<"id">> => <<"sent-", Name/binary>>,
                             <<"threadId">> => maps:get(<<"threadId">>, Sent, <<"t">>)})
              end),
    Attachments = [#{name => N, mime_type => T, bytes => base64:decode(B)}
                   || #{<<"name">> := N, <<"mimeType">> := T, <<"bytes">> := B} <- Atts],
    {ok, Got} = muse_gmail:send_email(client(), Draft, Attachments),
    ?assertEqual(Result, Got),
    Sent = receive {sent, S} -> S end,
    ?assertEqual(ThreadId, maps:get(<<"threadId">>, Sent, null)),
    Mime = base64:decode(maps:get(<<"raw">>, Sent), #{mode => urlsafe, padding => false}),
    {match, [OurDate]} = re:run(Mime, <<"\\r\\nDate: ([^\\r]*)\\r\\n">>, [{capture, all_but_first, binary}]),
    {match, [OurMid]} = re:run(Mime, <<"Message-ID: <([0-9a-f-]+)@openmuse\\.invalid>">>, [{capture, all_but_first, binary}]),
    Normalized0 = binary:replace(binary:replace(Mime, OurDate, Date), OurMid, Mid),
    Normalized = case re:run(Mime, <<"boundary=\"openmuse_([0-9a-f-]+)\"">>, [{capture, all_but_first, binary}]) of
                     {match, [OurBoundary]} -> binary:replace(Normalized0, OurBoundary, Boundary, [global]);
                     nomatch -> Normalized0
                 end,
    ?assertEqual({Name, Expected}, {Name, Normalized}).

%% Pure checks

mime_vectors_pure_test() ->
    lists:foreach(
      fun(#{<<"name">> := Name, <<"draft">> := Draft0, <<"attachments">> := Atts, <<"raw">> := Raw,
            <<"date">> := Date, <<"mid">> := Mid, <<"boundary">> := Boundary}) ->
              {ok, Draft} = muse_validate:check(muse_gmail:email_draft_schema(), Draft0),
              Reply = case Draft of
                          #{<<"replyToMessageId">> := _} ->
                              [<<"In-Reply-To: <source@example.com>">>,
                               <<"References: <a@example.com> <b@example.com> <source@example.com>">>];
                          _ -> []
                      end,
              Mime = muse_gmail:build_mime(
                       #{from => <<"me@example.com">>, to => maps:get(<<"to">>, Draft),
                         cc => maps:get(<<"cc">>, Draft), bcc => maps:get(<<"bcc">>, Draft),
                         subject => maps:get(<<"subject">>, Draft), body => maps:get(<<"body">>, Draft),
                         date => Date, message_id => Mid, reply_headers => Reply, boundary => Boundary,
                         attachments => [#{name => N, mime_type => T, bytes => base64:decode(B)}
                                         || #{<<"name">> := N, <<"mimeType">> := T, <<"bytes">> := B} <- Atts]}),
              ?assertEqual({Name, base64:decode(Raw, #{mode => urlsafe, padding => false})}, {Name, Mime})
      end, muse_google_vectors:mime()).

utc_string_test() ->
    [?assertEqual(Expected, muse_gmail:utc_string(Ms)) || [Ms, Expected] <- muse_google_vectors:utc()].

%% mapMessage over the original's outputs (HTML layout, charsets, RFC 2047,
%% snippets, Date headers, attachment references).
map_message_vectors_test_() ->
    [{maps:get(<<"id">>, In),
      ?_assertEqual(Out, element(2, muse_gmail:map_message(In)))}
     || #{<<"input">> := In, <<"output">> := Out} <- muse_google_vectors:mail()].

decode_base64url_test() ->
    D = fun muse_gmail:decode_base64url/2,
    ?assertEqual({ok, <<"ab">>}, D(<<"YWI">>, 10)),
    ?assertEqual({ok, <<"ab">>}, D(<<"YWI=">>, 10)),
    ?assertEqual({ok, <<>>}, D(<<>>, 10)),
    Invalid = {error, {internal, <<"Invalid base64url attachment or message body">>}},
    ?assertEqual(Invalid, D(<<"YWJ">>, 10)),       %% non-canonical trailing bits
    ?assertEqual(Invalid, D(<<"Y">>, 10)),
    ?assertEqual(Invalid, D(<<"YW+/">>, 10)),
    ?assertEqual(Invalid, D(<<"YWI===">>, 10)),
    ?assertEqual({error, {internal, <<"Attachment or message body is too large">>}}, D(<<"YWJj">>, 2)),
    ?assertEqual({error, {internal, <<"Attachment or message body exceeds the size limit">>}},
                 D(binary:copy(<<"A">>, 9), 3)).

text_helpers_test() ->
    ?assertEqual([<<"a@b.example">>, <<"c@d.example">>],
                 muse_mail_text:addresses(<<"\"x@y.example\" <a@b.example>, c@d.example">>)),
    ?assertEqual(<<"=?bogus?B?SGk=?=">>, muse_mail_text:decode_header(<<"=?bogus?B?SGk=?=">>)),
    ?assertEqual(<<"Ünïcode"/utf8>>, muse_mail_text:decode_header(<<"=?ISO-8859-1?Q?=DCn=EFcode?=">>)),
    ?assertEqual(<<"&#1114112; \x{FFFD} &unknown;"/utf8>>,
                 muse_mail_text:decode_snippet(<<"&#1114112; &#xD800; &unknown;">>)),
    ?assertEqual(<<"H\x{FFFD}("/utf8>>, muse_mail_text:utf8_lossy(<<"H", 16#C3, "(">>)).
