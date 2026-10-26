%% @doc Drafts and sending of the built-in mail (邮件, designs/02-engine.md
%% §9).
%%
%% Drafts are local (`mail-drafts', not synced to the IMAP Drafts folder):
%% `{id, accountId, to, cc, bcc, subject, body, inReplyTo, references,
%% inReplyToHeader, fileIds, uploads, forwards, createdBy, status, error,
%% createdAt, updatedAt}'. Recipients are texts (`Name <a@b>' or `a@b');
%% `fileIds' are files of the Files library; `uploads' are files uploaded
%% in the compose window, kept in the blobs cask (`mailup/<id>') until the
%% draft is sent or deleted; `forwards' are attachments of a forwarded
%% message, fetched from the server when sending. The agent writes drafts
%% too (`createdBy: agent', draft_mail): a draft never sends itself.
%%
%% Sending (`send/4') is SMTP through the sidecar, one message built once:
%% plain text, cc, bcc (envelope only), attachments, In-Reply-To and
%% References for replies. Accounts with `saveSent' get the same bytes
%% appended to their Sent folder (Gmail and Outlook file SMTP mail
%% themselves). Every send has a receipt (`mail-sends', its id the caller's
%% idempotency key) written `sending' before the SMTP conversation and
%% `sent', `failed' or `unknown' after it; a receipt that already exists is
%% never sent again: `sent' answers with it, anything else refuses. So a
%% retry, a double click or a double approval cannot send twice, and a
%% crash between the two writes leaves `sending', which reads as
%% `outcome_unknown'. A send that may have reached the server (the
%% connection broke during DATA, or no answer in time) is `unknown' too.
%%
%% The user's own sends (the page's 发送, `send_draft/2'; the JSON API) need
%% no review. The agent's go through the `mail.send' action
%% (muse_mail_action), which calls `prepare/2' before review and
%% `send_reviewed/2' after approval.
-module(muse_mail_send).

-export([drafts/1, get_draft/2, save_draft/4, delete_draft/2, reply_draft/3,
         add_upload/5, remove_attachment/4, send_draft/2, send/4, build_message/2, receipt/2,
         parse_addresses/1, prepare/2, send_reviewed/2, forget_account/2, upload_bytes/1]).

-define(DRAFTS, <<"mail-drafts">>).
-define(SENDS, <<"mail-sends">>).
-define(NO_DRAFT, {error, {404, <<"找不到这封草稿"/utf8>>}}).
-define(MAX_RCPT, 100).

-type owner() :: binary().
-type draft() :: #{binary() => term()}.
-type error() :: {error, {pos_integer() | outcome_unknown, binary()}}.

%%%===================================================================
%%% Drafts
%%%===================================================================

-spec drafts(owner()) -> [draft()].
drafts(Owner) ->
    lists:sort(fun(A, B) -> maps:get(<<"updatedAt">>, A, <<>>) >= maps:get(<<"updatedAt">>, B, <<>>) end,
               muse_store:list(Owner, ?DRAFTS)).

-spec get_draft(owner(), term()) -> {ok, draft()} | {error, {404, binary()}}.
get_draft(Owner, Id) when is_binary(Id) ->
    case muse_store:get(Owner, ?DRAFTS, Id) of
        undefined -> ?NO_DRAFT;
        D -> {ok, D}
    end;
get_draft(_Owner, _) ->
    ?NO_DRAFT.

draft_schema() ->
    Rcpt = {union, [{array, {string, #{trim => true, max => 320}}, #{max => ?MAX_RCPT}},
                    {string, #{max => 20000}}]},
    {object, [{<<"accountId">>, {optional, {string, #{min => 1, max => 100}}}},
              {<<"to">>, {optional, Rcpt}},
              {<<"cc">>, {optional, Rcpt}},
              {<<"bcc">>, {optional, Rcpt}},
              {<<"subject">>, {optional, {string, #{trim => true, max => 500, single_line => true}}}},
              {<<"body">>, {optional, {string, #{max => 200000}}}},
              {<<"inReplyTo">>, {optional, {string, #{max => 200}}}},
              {<<"fileIds">>, {optional, {array, {string, #{min => 1, max => 100}}, #{max => 20}}}}]}.

%% @doc Create (`new', or `{new, Id}' with a given id) or update a draft with
%% the given fields (others are kept). `By' is `user' or `agent'. Recipients may be partial while the
%% user types; they are checked when sending.
-spec save_draft(owner(), binary() | new | {new, binary()}, map(), binary()) -> {ok, draft()} | error().
save_draft(Owner, Id, Raw, By) ->
    maybe
        {ok, In} ?= muse_validate:parse(draft_schema(), Raw),
        {ok, Old} ?= case Id of
                         new -> {ok, #{}};
                         {new, _} -> {ok, #{}};
                         _ -> get_draft(Owner, Id)
                     end,
        ok ?= case Old of
                  #{<<"status">> := <<"sending">>} -> {error, {409, <<"这封邮件正在发送"/utf8>>}};
                  _ -> ok
              end,
        {ok, AccountId} ?= account_id(Owner, maps:get(<<"accountId">>, In, maps:get(<<"accountId">>, Old, undefined))),
        {ok, Reply} ?= reply_fields(Owner, In, Old),
        ok ?= own_files(Owner, maps:get(<<"fileIds">>, In, [])),
        Now = muse_time:now_iso(),
        Fields = maps:map(fun(K, V) when K =:= <<"to">>; K =:= <<"cc">>; K =:= <<"bcc">> -> rcpt_list(V);
                             (_, V) -> V
                          end, maps:without([<<"inReplyTo">>, <<"accountId">>], In)),
        Draft = maps:merge(maps:merge(#{<<"to">> => [], <<"cc">> => [], <<"bcc">> => [], <<"subject">> => <<>>,
                                        <<"body">> => <<>>, <<"fileIds">> => [], <<"uploads">> => [],
                                        <<"forwards">> => [], <<"createdBy">> => By, <<"createdAt">> => Now,
                                        <<"id">> => case Id of
                                                        new -> muse_ids:uuid();
                                                        {new, Fixed} -> Fixed;
                                                        _ -> Id
                                                    end},
                                      Old),
                           maps:merge(Fields, Reply#{<<"accountId">> => AccountId, <<"status">> => <<"draft">>,
                                                     <<"error">> => null, <<"updatedAt">> => Now})),
        Saved = muse_store:put(Owner, ?DRAFTS, Draft),
        muse_events:emit(Owner, {mail, AccountId}),
        {ok, Saved}
    end.

account_id(Owner, undefined) ->
    case muse_mail_accounts:first(Owner) of
        {ok, #{<<"id">> := A}} -> {ok, A};
        E -> E
    end;
account_id(Owner, A) ->
    case muse_mail_accounts:get(Owner, A) of
        {ok, _} -> {ok, A};
        E -> E
    end.

reply_fields(Owner, #{<<"inReplyTo">> := <<>>}, _Old) ->
    _ = Owner,
    {ok, #{<<"inReplyTo">> => null, <<"inReplyToHeader">> => null, <<"references">> => []}};
reply_fields(Owner, #{<<"inReplyTo">> := MsgId}, _Old) ->
    case muse_mail:get_message(Owner, MsgId) of
        {ok, M} -> {ok, (threading(M))#{<<"inReplyTo">> => MsgId}};
        E -> E
    end;
reply_fields(_Owner, _In, _Old) ->
    {ok, #{}}.

threading(M) ->
    Refs = maps:get(<<"references">>, M, []),
    case maps:get(<<"messageId">>, M, null) of
        H when is_binary(H) -> #{<<"inReplyToHeader">> => H, <<"references">> => lists:sublist(Refs, 30) ++ [H]};
        _ -> #{<<"inReplyToHeader">> => null, <<"references">> => Refs}
    end.

rcpt_list(L) when is_list(L) -> [T || T0 <- L, T <- [string:trim(T0)], T =/= <<>>];
rcpt_list(T) when is_binary(T) -> [string:trim(P) || P <- split_rcpt(T), string:trim(P) =/= <<>>].

own_files(Owner, Ids) ->
    case [Id || Id <- Ids, element(1, muse_files:get(Owner, Id)) =/= ok] of
        [] -> ok;
        _ -> {error, {404, <<"找不到要附加的文件"/utf8>>}}
    end.

-spec delete_draft(owner(), binary()) -> ok | error().
delete_draft(Owner, Id) ->
    maybe
        {ok, D} ?= get_draft(Owner, Id),
        ok ?= case D of
                  #{<<"status">> := <<"sending">>} -> {error, {409, <<"这封邮件正在发送"/utf8>>}};
                  _ -> ok
              end,
        drop_draft(Owner, D)
    end.

drop_draft(Owner, #{<<"id">> := Id} = D) ->
    _ = [muse_blob:delete(<<"mailup/", U/binary>>) || #{<<"id">> := U} <- maps:get(<<"uploads">>, D, [])],
    ok = muse_store:remove(Owner, ?DRAFTS, Id),
    muse_events:emit(Owner, {mail, maps:get(<<"accountId">>, D, <<>>)}),
    ok.

%% @doc A new draft that replies to (`reply', `reply_all') or forwards
%% (`forward') a message: recipients, subject, the quoted text, threading
%% headers, and for a forward the original attachments.
-spec reply_draft(owner(), binary(), reply | reply_all | forward) -> {ok, draft()} | error().
reply_draft(Owner, MsgId, Mode) ->
    maybe
        {ok, #{<<"accountId">> := A} = M} ?= muse_mail:get_message(Owner, MsgId),
        {ok, Account} ?= muse_mail_accounts:get(Owner, A),
        Me = maps:get(<<"email">>, Account),
        #{text := Text} = muse_mail:body(Owner, M),
        Sender = case maps:get(<<"replyTo">>, M, []) of
                     [R | _] -> R;
                     [] -> maps:get(<<"from">>, M, null)
                 end,
        NotMe = fun(L) -> [muse_mail:address_text(X) || X = #{<<"address">> := Ad} <- L,
                                                        string:lowercase(Ad) =/= Me] end,
        Subject = maps:get(<<"subject">>, M, <<>>),
        {To, Cc} = case Mode of
                       reply -> {NotMe([Sender || is_map(Sender)]), []};
                       reply_all ->
                           To0 = lists:usort(NotMe([Sender || is_map(Sender)]) ++ NotMe(maps:get(<<"to">>, M, []))),
                           {To0, NotMe(maps:get(<<"cc">>, M, [])) -- To0};
                       forward -> {[], []}
                   end,
        Date = muse_ui_time(maps:get(<<"date">>, M, null)),
        From = muse_mail:address_text(maps:get(<<"from">>, M, null)),
        Body = case Mode of
                   forward ->
                       iolist_to_binary([<<"\n\n---------- 转发的邮件 ----------\n"/utf8>>,
                                         <<"发件人："/utf8>>, From, <<"\n日期："/utf8>>, Date, <<"\n主题："/utf8>>, Subject,
                                         <<"\n收件人："/utf8>>, muse_mail:addresses_text(maps:get(<<"to">>, M, [])), "\n\n",
                                         Text]);
                   _ ->
                       Quoted = [["> ", L, "\n"] || L <- binary:split(string:trim(Text, trailing), [<<"\r\n">>, <<"\n">>],
                                                                     [global])],
                       iolist_to_binary(["\n\n", Date, <<"，"/utf8>>, From, <<" 写道：\n"/utf8>>, Quoted])
               end,
        Base = #{<<"accountId">> => A, <<"to">> => To, <<"cc">> => Cc, <<"subject">> => prefixed(Mode, Subject),
                 <<"body">> => Body},
        {ok, D} ?= save_draft(Owner, new, case Mode of
                                              forward -> Base;
                                              _ -> Base#{<<"inReplyTo">> => MsgId}
                                          end, <<"user">>),
        case Mode of
            forward ->
                Fwd = [#{<<"messageId">> => MsgId, <<"part">> => maps:get(<<"part">>, X),
                         <<"filename">> => maps:get(<<"filename">>, X, <<"attachment">>),
                         <<"size">> => maps:get(<<"size">>, X, 0),
                         <<"contentType">> => maps:get(<<"contentType">>, X, <<"application/octet-stream">>)}
                       || X <- maps:get(<<"attachments">>, M, []), maps:get(<<"inline">>, X, false) =/= true],
                {ok, muse_store:put(Owner, ?DRAFTS, D#{<<"forwards">> => Fwd})};
            _ ->
                {ok, D}
        end
    end.

muse_ui_time(Iso) when is_binary(Iso) ->
    case muse_time:parse(Iso) of
        nan -> Iso;
        Ms ->
            {{Y, Mo, D}, {H, Mi, _}} = calendar:system_time_to_local_time(Ms, millisecond),
            unicode:characters_to_binary(io_lib:format("~B年~B月~B日 ~2..0B:~2..0B", [Y, Mo, D, H, Mi]))
    end;
muse_ui_time(_) ->
    <<>>.

prefixed(Mode, Subject) ->
    {Prefix, Known} = case Mode of
                          forward -> {<<"Fwd: ">>, [<<"fwd:">>, <<"fw:">>, <<"转发："/utf8>>]};
                          _ -> {<<"Re: ">>, [<<"re:">>, <<"回复："/utf8>>, <<"答复："/utf8>>]}
                      end,
    Lower = string:lowercase(Subject),
    case lists:any(fun(K) -> string:prefix(Lower, K) =/= nomatch end, Known) of
        true -> Subject;
        false -> <<Prefix/binary, Subject/binary>>
    end.

%% @doc Attach an uploaded file to a draft (at most FILES_MAX_MB).
-spec add_upload(owner(), binary(), binary(), binary(), binary() | undefined) -> {ok, map()} | error().
add_upload(Owner, DraftId, Name0, Bytes, Declared) ->
    maybe
        {ok, D} ?= get_draft(Owner, DraftId),
        ok ?= case byte_size(Bytes) =< muse_files:max_bytes() of
                  true -> ok;
                  false -> {error, {413, <<"附件太大，单个不能超过 "/utf8,
                                       (integer_to_binary(muse_config:get(files_max_mb, 25)))/binary, " MB">>}}
              end,
        Name = muse_files:sanitize_file_name(Name0),
        {ok, Mime} ?= muse_files:detect_mime(Name, Bytes, Declared),
        Id = muse_ids:uuid(),
        ok = muse_blob:put(<<"mailup/", Id/binary>>, Bytes),
        Upload = #{<<"id">> => Id, <<"name">> => Name, <<"size">> => byte_size(Bytes), <<"mimeType">> => Mime},
        _ = muse_store:put(Owner, ?DRAFTS, D#{<<"uploads">> => maps:get(<<"uploads">>, D, []) ++ [Upload],
                                              <<"updatedAt">> => muse_time:now_iso()}),
        {ok, Upload}
    end.

%% @doc Remove an attachment from a draft: `file' (a Files id), `upload' or
%% `forward' (an attachment part of the forwarded message).
-spec remove_attachment(owner(), binary(), file | upload | forward, binary()) -> {ok, draft()} | error().
remove_attachment(Owner, DraftId, Kind, Ref) ->
    maybe
        {ok, D} ?= get_draft(Owner, DraftId),
        New = case Kind of
                  file -> D#{<<"fileIds">> => lists:delete(Ref, maps:get(<<"fileIds">>, D, []))};
                  upload ->
                      _ = muse_blob:delete(<<"mailup/", Ref/binary>>),
                      D#{<<"uploads">> => [U || U = #{<<"id">> := I} <- maps:get(<<"uploads">>, D, []), I =/= Ref]};
                  forward ->
                      D#{<<"forwards">> => [F || F = #{<<"part">> := P} <- maps:get(<<"forwards">>, D, []), P =/= Ref]}
              end,
        {ok, muse_store:put(Owner, ?DRAFTS, New#{<<"updatedAt">> => muse_time:now_iso()})}
    end.

-spec upload_bytes(binary()) -> {ok, binary()} | not_found.
upload_bytes(Id) ->
    muse_blob:get(<<"mailup/", Id/binary>>).

-spec forget_account(owner(), binary()) -> ok.
forget_account(Owner, AccountId) ->
    lists:foreach(fun(D) -> drop_draft(Owner, D) end,
                  [D || D = #{<<"accountId">> := A} <- muse_store:list(Owner, ?DRAFTS), A =:= AccountId]).

%%%===================================================================
%%% Sending
%%%===================================================================

%% @doc 发送 a draft (the user's own send: no review). The draft is claimed
%% (`sending') so a second click does nothing; it is removed once sent,
%% and back to a draft with the error otherwise.
-spec send_draft(owner(), binary()) -> {ok, map()} | error().
send_draft(Owner, Id) ->
    maybe
        {ok, D} ?= get_draft(Owner, Id),
        {ok, Msg} ?= build(Owner, D),
        #{} = Claimed ?= case muse_store:cas(Owner, ?DRAFTS, Id, #{<<"status">> => <<"draft">>},
                                               #{<<"status">> => <<"sending">>}) of
                             undefined -> {error, {409, <<"这封邮件已经在发送了"/utf8>>}};
                             C -> C
                         end,
        Key = <<"draft:", Id/binary, ":", (maps:get(<<"updatedAt">>, Claimed))/binary>>,
        case send(Owner, Msg, Key, <<"user">>) of
            {ok, Receipt} ->
                ok = drop_draft(Owner, Claimed),
                {ok, Receipt};
            {error, {Status, Text}} = E ->
                Note = case Status of
                           outcome_unknown ->
                               <<"发送结果未知："/utf8, Text/binary,
                                 "。请先到“已发送”里确认，再决定是否重发。"/utf8>>;
                           _ -> Text
                       end,
                _ = muse_store:put(Owner, ?DRAFTS, Claimed#{<<"status">> => <<"draft">>, <<"error">> => Note,
                                                            <<"updatedAt">> => muse_time:now_iso()}),
                muse_events:emit(Owner, {mail, maps:get(<<"accountId">>, D)}),
                E
        end
    end.

%% @doc A draft-shaped map (a draft, a reviewed action's data, an API
%% request) as the message `send/4' takes: the account, parsed recipients,
%% attachment bytes, threading headers.
-spec build_message(owner(), map()) -> {ok, map()} | error().
build_message(Owner, D) ->
    build(Owner, D).

build(Owner, D) ->
    maybe
        {ok, Account} ?= case maps:get(<<"accountId">>, D, undefined) of
                             undefined -> muse_mail_accounts:first(Owner);
                             A -> muse_mail_accounts:get(Owner, A)
                         end,
        {ok, To} ?= parse_addresses(maps:get(<<"to">>, D, [])),
        {ok, Cc} ?= parse_addresses(maps:get(<<"cc">>, D, [])),
        {ok, Bcc} ?= parse_addresses(maps:get(<<"bcc">>, D, [])),
        ok ?= case To ++ Cc ++ Bcc of
                  [] -> {error, {422, <<"请至少填写一个收件人"/utf8>>}};
                  All when length(All) > ?MAX_RCPT -> {error, {422, <<"收件人太多（最多 100 个）"/utf8>>}};
                  _ -> ok
              end,
        {ok, Atts} ?= attachments(Owner, D),
        ok ?= case lists:sum([byte_size(B) || #{bytes := B} <- Atts]) =< muse_files:max_bytes() of
                  true -> ok;
                  false -> {error, {413, <<"附件合计不能超过 "/utf8,
                                       (integer_to_binary(muse_config:get(files_max_mb, 25)))/binary, " MB">>}}
              end,
        {ok, #{account => Account, to => To, cc => Cc, bcc => Bcc,
               subject => maps:get(<<"subject">>, D, <<>>), text => maps:get(<<"body">>, D, <<>>),
               in_reply_to => maps:get(<<"inReplyToHeader">>, D, null),
               references => maps:get(<<"references">>, D, []),
               replied => maps:get(<<"inReplyTo">>, D, null),
               attachments => Atts}}
    end.

attachments(Owner, D) ->
    Files = [case muse_files:get(Owner, Id) of
                 {ok, #{<<"name">> := N} = F} ->
                     case muse_files:bytes(Owner, Id) of
                         {ok, B} -> {ok, #{name => N, type => maps:get(<<"mimeType">>, F, <<"application/octet-stream">>),
                                           bytes => B}};
                         E -> E
                     end;
                 _ -> {error, {404, <<"找不到要附加的文件"/utf8>>}}
             end || Id <- maps:get(<<"fileIds">>, D, [])],
    Uploads = [case upload_bytes(Id) of
                   {ok, B} -> {ok, #{name => N, type => maps:get(<<"mimeType">>, U, <<"application/octet-stream">>),
                                     bytes => B}};
                   not_found -> {error, {404, <<"上传的附件不见了，请重新添加"/utf8>>}}
               end || U = #{<<"id">> := Id, <<"name">> := N} <- maps:get(<<"uploads">>, D, [])],
    Forwards = [case muse_mail:attachment(Owner, M, P) of
                    {ok, A} -> {ok, A};
                    E -> E
                end || #{<<"messageId">> := M, <<"part">> := P} <- maps:get(<<"forwards">>, D, [])],
    All = Files ++ Uploads ++ Forwards,
    case [E || {error, _} = E <- All] of
        [] -> {ok, [A || {ok, A} <- All]};
        [E | _] -> E
    end.

%% @doc Send `Msg' once under the receipt `Key' (see the module doc).
-spec send(owner(), map(), binary(), binary()) -> {ok, map()} | error().
send(Owner, #{account := #{<<"id">> := A} = Account} = Msg, Key, By) ->
    Id = muse_ids:sha256hex(<<"mail-send:", Key/binary>>),
    Receipt = #{<<"id">> => Id, <<"key">> => Key, <<"status">> => <<"sending">>, <<"accountId">> => A,
                <<"from">> => maps:get(<<"email">>, Account),
                <<"to">> => [muse_mail:address_text(X) || X <- maps:get(to, Msg)],
                <<"cc">> => [muse_mail:address_text(X) || X <- maps:get(cc, Msg)],
                <<"bcc">> => [muse_mail:address_text(X) || X <- maps:get(bcc, Msg)],
                <<"subject">> => maps:get(subject, Msg), <<"by">> => By,
                <<"startedAt">> => muse_time:now_iso()},
    case muse_store:insert_if_absent(Owner, ?SENDS, Receipt) of
        undefined -> existing(muse_store:get(Owner, ?SENDS, Id));
        _ -> deliver(Owner, Account, Msg, Id)
    end.

existing(#{<<"status">> := <<"sent">>} = R) ->
    {ok, R};
existing(#{<<"status">> := <<"failed">>} = R) ->
    {error, {409, <<"这次发送已经失败过："/utf8, (maps:get(<<"error">>, R, <<>>))/binary>>}};
existing(_) ->
    {error, {outcome_unknown, <<"这封邮件之前已经开始发送，结果未知，不会再发一次。请先到“已发送”里确认。"/utf8>>}}.

deliver(Owner, #{<<"id">> := A} = Account, Msg, Id) ->
    Sent = case maps:get(<<"saveSent">>, Account, true) =:= true
               andalso muse_mail:folder_by_role(Owner, A, <<"sent">>) of
               {ok, #{<<"path">> := P}} -> P;
               _ -> null
           end,
    Wire = #{<<"from">> => #{<<"name">> => maps:get(<<"name">>, Account, <<>>),
                             <<"address">> => maps:get(<<"email">>, Account)},
             <<"to">> => maps:get(to, Msg), <<"cc">> => maps:get(cc, Msg), <<"bcc">> => maps:get(bcc, Msg),
             <<"subject">> => maps:get(subject, Msg), <<"text">> => maps:get(text, Msg),
             <<"inReplyTo">> => maps:get(in_reply_to, Msg, null),
             <<"references">> => maps:get(references, Msg, []),
             <<"attachments">> => [#{<<"filename">> => N, <<"contentType">> => T, <<"data">> => base64:encode(B)}
                                   || #{name := N, type := T, bytes := B} <- maps:get(attachments, Msg, [])]},
    Result = muse_mail:request(Owner, A, <<"send">>, #{<<"message">> => Wire, <<"sentFolder">> => Sent}, 180000),
    Done = muse_time:now_iso(),
    case Result of
        {ok, R} ->
            Saved = muse_store:put(Owner, ?SENDS,
                                   (muse_store:get(Owner, ?SENDS, Id))#{
                                     <<"status">> => <<"sent">>, <<"finishedAt">> => Done,
                                     <<"messageId">> => maps:get(<<"messageId">>, R, null),
                                     <<"accepted">> => maps:get(<<"accepted">>, R, []),
                                     <<"rejected">> => maps:get(<<"rejected">>, R, []),
                                     <<"appended">> => maps:get(<<"appended">>, R, false),
                                     <<"appendError">> => maps:get(<<"appendError">>, R, null)}),
            _ = case maps:get(replied, Msg, null) of
                    Replied when is_binary(Replied) -> catch answered(Owner, Replied);
                    _ -> ok
                end,
            muse_mail_sync:request_sync(Owner, A),
            muse_events:emit(Owner, {mail, A}),
            {ok, Saved};
        {error, {Status, Text}} ->
            Final = case Status of outcome_unknown -> <<"unknown">>; _ -> <<"failed">> end,
            _ = muse_store:cas(Owner, ?SENDS, Id, #{<<"status">> => <<"sending">>},
                               #{<<"status">> => Final, <<"error">> => Text, <<"finishedAt">> => Done}),
            {error, {Status, Text}}
    end.

%% A reply marks the original answered (best effort, also on the server).
answered(Owner, MsgId) ->
    maybe
        {ok, #{<<"accountId">> := A, <<"flags">> := Flags} = M} ?= muse_mail:get_message(Owner, MsgId),
        false ?= lists:member(<<"\\Answered">>, Flags),
        {ok, F} ?= muse_mail:folder(Owner, maps:get(<<"folderId">>, M)),
        {ok, _} ?= muse_mail:request(Owner, A, <<"flags">>,
                                     #{<<"path">> => maps:get(<<"path">>, F),
                                       <<"uidValidity">> => maps:get(<<"uidValidity">>, F),
                                       <<"uids">> => [maps:get(<<"uid">>, M)], <<"add">> => [<<"\\Answered">>],
                                       <<"remove">> => []}, 30000),
        muse_mail:update_message(Owner, M, [<<"\\Answered">> | Flags])
    end.

-spec receipt(owner(), binary()) -> map() | undefined.
receipt(Owner, Key) ->
    muse_store:get(Owner, ?SENDS, muse_ids:sha256hex(<<"mail-send:", Key/binary>>)).

%%%===================================================================
%%% The reviewed send (mail.send)
%%%===================================================================

%% @doc Check a proposed send against the owner's data and fill in what
%% the review shows: the sender, threading headers, attachment names and a
%% fresh `sendId' (the receipt key).
-spec prepare(owner(), map()) -> {ok, map()} | error().
prepare(Owner, Data) ->
    maybe
        {ok, #{<<"id">> := A} = Account} ?= case maps:get(<<"accountId">>, Data, undefined) of
                                                 undefined -> muse_mail_accounts:first(Owner);
                                                 Id -> muse_mail_accounts:get(Owner, Id)
                                             end,
        {ok, To} ?= parse_addresses(maps:get(<<"to">>, Data, [])),
        {ok, Cc} ?= parse_addresses(maps:get(<<"cc">>, Data, [])),
        {ok, Bcc} ?= parse_addresses(maps:get(<<"bcc">>, Data, [])),
        Count = length(To ++ Cc ++ Bcc),
        ok ?= case To of
                  [] -> {error, {422, <<"At least one recipient is required in to">>}};
                  _ when Count > ?MAX_RCPT -> {error, {422, <<"At most 100 recipients">>}};
                  _ -> ok
              end,
        {ok, Files} ?= files(Owner, maps:get(<<"attachments">>, Data, [])),
        ok ?= case lists:sum([S || #{<<"size">> := S} <- Files]) =< muse_files:max_bytes() of
                  true -> ok;
                  false -> {error, {413, <<"The attachments are larger than FILES_MAX_MB">>}}
              end,
        {ok, Reply} ?= case maps:get(<<"inReplyTo">>, Data, undefined) of
                           undefined -> {ok, #{}};
                           MsgId ->
                               maybe
                                   {ok, M} ?= muse_mail:get_message(Owner, MsgId),
                                   ok ?= case maps:get(<<"accountId">>, M) of
                                             A -> ok;
                                             _ -> {error, {422, <<"Reply from the account the message arrived in">>}}
                                         end,
                                   T = threading(M),
                                   {ok, #{<<"inReplyToHeader">> => maps:get(<<"inReplyToHeader">>, T),
                                          <<"references">> => maps:get(<<"references">>, T),
                                          <<"replySubject">> => maps:get(<<"subject">>, M, <<>>)}}
                               end
                       end,
        Clean = maps:filter(fun(_, V) -> V =/= null end, Reply),
        Base = (maps:without([<<"inReplyToHeader">>, <<"references">>, <<"replySubject">>], Data))#{
                 <<"accountId">> => A,
                 <<"from">> => muse_mail:address_text(#{<<"name">> => maps:get(<<"name">>, Account, <<>>),
                                                        <<"address">> => maps:get(<<"email">>, Account)}),
                 <<"to">> => [muse_mail:address_text(X) || X <- To],
                 <<"cc">> => [muse_mail:address_text(X) || X <- Cc],
                 <<"bcc">> => [muse_mail:address_text(X) || X <- Bcc],
                 <<"attachmentNames">> => [<<N/binary, " (", (muse_ui_size(S))/binary, ")">>
                                           || #{<<"name">> := N, <<"size">> := S} <- Files],
                 <<"sendId">> => muse_ids:uuid()},
        {ok, maps:merge(Base, Clean)}
    end.

files(Owner, Ids) ->
    Got = [muse_files:get(Owner, Id) || Id <- Ids],
    case [E || {error, _} = E <- Got] of
        [] -> {ok, [F || {ok, F} <- Got]};
        _ -> {error, {404, <<"An attachment is not one of the person's files (use file ids from Files)">>}}
    end.

muse_ui_size(N) when is_integer(N), N >= 1048576 -> iolist_to_binary(io_lib:format("~.1f MB", [N / 1048576]));
muse_ui_size(N) when is_integer(N), N >= 1024 -> iolist_to_binary(io_lib:format("~.1f KB", [N / 1024]));
muse_ui_size(N) when is_integer(N) -> <<(integer_to_binary(N))/binary, " B">>;
muse_ui_size(_) -> <<>>.

%% @doc Send an approved `mail.send' once (receipt `action:<sendId>').
-spec send_reviewed(owner(), map()) -> {ok, map()} | error().
send_reviewed(Owner, #{<<"sendId">> := SendId} = Data) ->
    maybe
        {ok, Msg} ?= build(Owner, #{<<"accountId">> => maps:get(<<"accountId">>, Data),
                                    <<"to">> => maps:get(<<"to">>, Data, []),
                                    <<"cc">> => maps:get(<<"cc">>, Data, []),
                                    <<"bcc">> => maps:get(<<"bcc">>, Data, []),
                                    <<"subject">> => maps:get(<<"subject">>, Data, <<>>),
                                    <<"body">> => maps:get(<<"body">>, Data, <<>>),
                                    <<"inReplyToHeader">> => maps:get(<<"inReplyToHeader">>, Data, null),
                                    <<"references">> => maps:get(<<"references">>, Data, []),
                                    <<"inReplyTo">> => maps:get(<<"inReplyTo">>, Data, null),
                                    <<"fileIds">> => maps:get(<<"attachments">>, Data, [])}),
        send(Owner, Msg, <<"action:", SendId/binary>>, <<"agent">>)
    end;
send_reviewed(_Owner, _Data) ->
    {error, {422, <<"This send was not prepared for review">>}}.

%%%===================================================================
%%% Addresses
%%%===================================================================

%% @doc Recipients from texts or one text separated by `,' `;' (also the
%% full-width ones) or new lines: `Name <a@b>' or `a@b'.
-spec parse_addresses(binary() | [binary()]) -> {ok, [map()]} | {error, {422, binary()}}.
parse_addresses(L) when is_list(L) ->
    Parts = lists:append([split_rcpt(T) || T <- L, is_binary(T)]),
    Parsed = [parse_one(string:trim(P)) || P <- Parts, string:trim(P) =/= <<>>],
    case [P || {error, P} <- Parsed] of
        [] -> {ok, [A || {ok, A} <- Parsed]};
        Bad -> {error, {422, <<"收件人地址无效："/utf8, (iolist_to_binary(lists:join(<<", ">>, Bad)))/binary>>}}
    end;
parse_addresses(T) when is_binary(T) ->
    parse_addresses([T]);
parse_addresses(_) ->
    {ok, []}.

parse_one(P) ->
    case re:run(P, <<"^(.*)<\\s*([^<>\\s]+)\\s*>$">>, [{capture, all_but_first, binary}, unicode]) of
        {match, [Name0, Addr]} ->
            Name = string:trim(string:trim(Name0), both, "\"'"),
            address(Name, Addr, P);
        nomatch ->
            address(<<>>, P, P)
    end.

address(Name, Addr, Orig) ->
    case muse_validate:is_email(Addr) of
        true -> {ok, #{<<"name">> => Name, <<"address">> => string:lowercase(Addr)}};
        false -> {error, Orig}
    end.

%% Split on separators outside quotes and angle brackets.
split_rcpt(T) ->
    split_rcpt(unicode:characters_to_list(T), false, 0, [], []).

split_rcpt([], _Q, _A, Cur, Acc) ->
    lists:reverse([unicode:characters_to_binary(lists:reverse(Cur)) | Acc]);
split_rcpt([$" | R], Q, A, Cur, Acc) ->
    split_rcpt(R, not Q, A, [$" | Cur], Acc);
split_rcpt([$< | R], Q, A, Cur, Acc) when not Q ->
    split_rcpt(R, Q, A + 1, [$< | Cur], Acc);
split_rcpt([$> | R], Q, A, Cur, Acc) when not Q, A > 0 ->
    split_rcpt(R, Q, A - 1, [$> | Cur], Acc);
split_rcpt([C | R], false, 0, Cur, Acc) when C =:= $,; C =:= $;; C =:= $\n; C =:= 16#FF0C; C =:= 16#FF1B ->
    split_rcpt(R, false, 0, [], [unicode:characters_to_binary(lists:reverse(Cur)) | Acc]);
split_rcpt([C | R], Q, A, Cur, Acc) ->
    split_rcpt(R, Q, A, [C | Cur], Acc).
