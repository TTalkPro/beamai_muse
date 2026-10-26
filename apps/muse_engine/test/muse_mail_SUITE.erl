%% The built-in mail's engine side (tasks/M9-workspace.md M9-8): accounts
%% and their encryption, sync (new mail, flags, expunges, UIDVALIDITY, the
%% window), writes back to the server, attachments, drafts and sending, the
%% `mail.send' kind (prepare, display, send once, outcome_unknown), the
%% agent's read tools, the sync process (IDLE, back-off) and the client's
%% timeouts. The servers are muse_mail_fake (a scripted sidecar), no network.
-module(muse_mail_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [accounts_and_encryption, account_errors, sync_new_mail_and_flags, sync_window_and_validity,
     writes_go_to_the_server, attachments_and_files, drafts_reply_and_send, send_failures, send_draft_once,
     mail_send_kind, mail_send_outcome_unknown, agent_read_tools, sync_process_idle_and_backoff,
     client_timeout_and_restart].

init_per_testcase(_Case, Config) ->
    Key = base64:encode(crypto:strong_rand_bytes(32)),
    Env = muse_engine_test_env:start(#{<<"TOKEN_ENCRYPTION_KEY">> => Key}),
    {ok, C} = muse_mail_client:start_link(), unlink(C),
    ok = muse_mail_action:register(),
    File = muse_mail_fake:setup(maps:get(dir, Env)),
    [{env, Env}, {fake, File}, {client, C} | Config].

end_per_testcase(_Case, Config) ->
    case whereis(muse_mail_sup) of
        undefined -> ok;
        Sup -> unlink(Sup), exit(Sup, shutdown), timer:sleep(50)
    end,
    gen_server:stop(muse_mail_client),
    ok = muse_mail_action:unregister(),
    muse_time:set_offset(0),
    muse_engine_test_env:stop(?config(env, Config)).

fake(Config) -> ?config(fake, Config).

account(Over) ->
    {ok, A} = muse_mail_accounts:create(?O, muse_mail_fake:account_input(Over), #{}),
    A.

synced() ->
    #{<<"id">> := A} = account(#{}),
    {ok, _} = muse_mail_sync:sync_now(?O, A),
    A.

inbox(A) ->
    {ok, #{<<"id">> := F}} = muse_mail:folder_by_role(?O, A, <<"inbox">>),
    lists:sort([S || #{<<"subject">> := S} <- muse_mail:folder_messages(?O, F)]).

by_subject(A, Subject) ->
    {_, Msgs} = muse_mail:list(?O, #{account => A, folder => <<"inbox">>, limit => 100}),
    hd([M || M = #{<<"subject">> := S} <- Msgs, S =:= Subject]).

server_flags(Config, Path, Uid) ->
    #{<<"messages">> := Ms} = muse_mail_fake:folder(fake(Config), Path),
    hd([F || #{<<"uid">> := U, <<"flags">> := F} <- Ms, U =:= Uid]).

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

%%%===================================================================
%%% Accounts
%%%===================================================================

accounts_and_encryption(_Config) ->
    ?assert(muse_mail_accounts:ready()),
    #{<<"id">> := Id, <<"secret">> := Secret} = A = account(#{<<"username">> => <<>>}),
    %% the password is stored only encrypted, nowhere in clear text
    ?assertMatch(<<"v1.", _/binary>>, Secret),
    Stored = muse_store:get(?O, <<"mail-accounts">>, Id),
    ?assertNot(has(term_to_binary(Stored), muse_mail_fake:password())),
    ?assertNot(has(muse_json:encode(muse_mail_accounts:public(A)), muse_mail_fake:password())),
    ?assertNot(maps:is_key(<<"secret">>, muse_mail_accounts:public(A))),
    ?assertMatch(#{<<"hasPassword">> := true, <<"username">> := <<"me@example.com">>}, muse_mail_accounts:public(A)),
    {ok, #{<<"imap">> := #{<<"pass">> := P}}} = muse_mail_accounts:sidecar_account(?O, Id),
    ?assertEqual(muse_mail_fake:password(), P),
    %% one account per address
    ?assertMatch({error, {409, _}}, muse_mail_accounts:create(?O, muse_mail_fake:account_input(), #{})),
    %% editing without a password keeps it (and the check passes with it)
    {ok, _} = muse_mail_accounts:update(?O, Id, maps:remove(<<"password">>,
                                                            muse_mail_fake:account_input(#{<<"name">> => <<"Work">>})), #{}),
    {ok, #{<<"name">> := <<"Work">>} = A2} = muse_mail_accounts:get(?O, Id),
    {ok, #{<<"imap">> := #{<<"pass">> := P}}} = muse_mail_accounts:sidecar_account(?O, A2),
    ok = muse_mail_accounts:test(?O, Id, maps:put(<<"password">>, <<>>, muse_mail_fake:account_input())),
    %% a wrong new password is refused by the check, the old one stays
    {error, {422, Msg}} = muse_mail_accounts:update(?O, Id, muse_mail_fake:account_input(#{<<"password">> => <<"nope">>}), #{}),
    ?assert(has(Msg, <<"IMAP：登录失败"/utf8>>)),
    ?assert(has(Msg, <<"SMTP：登录失败"/utf8>>)),
    {ok, #{<<"imap">> := #{<<"pass">> := P}}} = muse_mail_accounts:sidecar_account(?O, Id),
    %% presets
    ?assertMatch(#{<<"imapHost">> := <<"imap.qq.com">>, <<"smtpPort">> := 465}, muse_mail_accounts:preset(<<"qq">>)),
    ?assertMatch(#{<<"saveSent">> := false, <<"smtpSecurity">> := <<"starttls">>}, muse_mail_accounts:preset(<<"outlook">>)),
    ?assertMatch(#{<<"saveSent">> := false}, muse_mail_accounts:preset(<<"gmail">>)),
    %% delete takes the local copy with it
    {ok, _} = muse_mail_sync:sync_now(?O, Id),
    {ok, _} = muse_mail_send:save_draft(?O, new, #{<<"subject">> => <<"x">>}, <<"user">>),
    ?assertNotEqual([], muse_mail:folders(?O, Id)),
    ok = muse_mail_accounts:delete(?O, Id),
    ?assertEqual([], muse_mail:folders(?O, Id)),
    ?assertEqual([], muse_mail_send:drafts(?O)),
    ?assertEqual([], muse_store:list(?O, <<"mail-bodies">>)),
    ?assertMatch({error, {404, _}}, muse_mail_accounts:get(?O, Id)).

account_errors(_Config) ->
    In = muse_mail_fake:account_input(),
    ?assertMatch({error, {422, <<"请填写有效的邮箱地址"/utf8>>}},
                 muse_mail_accounts:create(?O, In#{<<"email">> => <<"not mail">>}, #{})),
    ?assertMatch({error, {422, _}}, muse_mail_accounts:create(?O, In#{<<"imapSecurity">> => <<"none">>}, #{})),
    ?assertMatch({error, {422, _}}, muse_mail_accounts:create(?O, maps:remove(<<"password">>, In), #{})),
    %% TLS: a self-signed server only with the explicit option
    {error, {422, Tls}} = muse_mail_accounts:create(?O, In#{<<"imapHost">> => <<"selfsigned.invalid">>}, #{}),
    ?assert(has(Tls, <<"IMAP：安全连接失败"/utf8>>)),
    {ok, _} = muse_mail_accounts:create(?O, In#{<<"imapHost">> => <<"selfsigned.invalid">>,
                                                 <<"allowSelfSigned">> => true}, #{}),
    {error, {422, Conn}} = muse_mail_accounts:test(?O, <<"new">>, In#{<<"smtpHost">> => <<"unreachable.invalid">>}),
    ?assert(has(Conn, <<"SMTP：连不上服务器"/utf8>>)),
    ?assertNot(has(Conn, <<"IMAP">>)),
    %% without TOKEN_ENCRYPTION_KEY nothing is saved
    muse_config:set((muse_config:all())#{encryption_key => undefined}),
    ?assertNot(muse_mail_accounts:ready()),
    ?assertMatch({error, {503, _}}, muse_mail_accounts:create(?O, In#{<<"email">> => <<"b@example.com">>}, #{})).

%%%===================================================================
%%% Sync
%%%===================================================================

sync_new_mail_and_flags(Config) ->
    A = synced(),
    Folders = muse_mail:folders(?O, A),
    ?assertEqual([<<"inbox">>, <<"drafts">>, <<"sent">>, <<"archive">>, <<"trash">>, null],
                 [maps:get(<<"role">>, F) || F <- Folders]),
    ?assertMatch([#{<<"path">> := <<"Projects/2026">>, <<"delimiter">> := <<"/">>}],
                 [F || F = #{<<"role">> := null} <- Folders]),
    %% the 60-day-old message is outside the 30-day window
    ?assertEqual([<<"Lunch?">>, <<"季度报告"/utf8>>, <<"本周精选"/utf8>>], inbox(A)),
    Report = by_subject(A, <<"季度报告"/utf8>>),
    ?assertMatch(#{<<"seen">> := false, <<"flagged">> := false, <<"hasAttachments">> := true,
                   <<"from">> := #{<<"name">> := <<"张三"/utf8>>, <<"address">> := <<"zhang@example.com">>},
                   <<"messageId">> := <<"<q1@example.com>">>, <<"threadKey">> := <<"<root@example.com>">>,
                   <<"snippet">> := <<"请看附件里的季度报告。 谢谢"/utf8>>,
                   <<"attachments">> := [#{<<"part">> := <<"2">>, <<"filename">> := <<"report.pdf">>}, _]}, Report),
    ?assertMatch(#{text := <<"请看附件里的季度报告。\n谢谢"/utf8>>}, muse_mail:body(?O, Report)),
    News = by_subject(A, <<"本周精选"/utf8>>),
    ?assertMatch(#{<<"seen">> := true, <<"hasText">> := false, <<"hasHtml">> := true, <<"hasAttachments">> := false},
                 News),
    ?assertMatch(#{<<"flagged">> := true}, by_subject(A, <<"Lunch?">>)),
    {ok, Inbox} = muse_mail:folder_by_role(?O, A, <<"inbox">>),
    ?assertMatch(#{<<"unread">> := 3, <<"total">> := 4, <<"lastUid">> := 4, <<"uidValidity">> := <<"1">>}, Inbox),
    %% the first sync raises no notifications
    ?assertEqual([], muse_store:list(?O, <<"notifications">>)),
    ?assertMatch(#{<<"status">> := <<"ok">>, <<"lastError">> := null}, muse_mail:sync_state(?O, A)),
    %% new mail arrives: stored, and notified with a link to it
    muse_mail_fake:deliver(fake(Config), <<"INBOX">>, #{<<"subject">> => <<"新消息"/utf8>>, <<"text">> => <<"你好"/utf8>>,
                                                       <<"from">> => [#{<<"name">> => <<"王五"/utf8>>,
                                                                        <<"address">> => <<"wang@example.com">>}]}),
    {ok, #{<<"new">> := 1}} = muse_mail_sync:sync_now(?O, A),
    #{<<"id">> := NewId} = by_subject(A, <<"新消息"/utf8>>),
    [#{<<"title">> := <<"新邮件 · 王五"/utf8>>, <<"href">> := Href, <<"body">> := Body}] =
        muse_store:list(?O, <<"notifications">>),
    ?assertEqual(<<"/mail/", NewId/binary>>, Href),
    ?assert(has(Body, <<"新消息"/utf8>>)),
    %% a second pass changes nothing and notifies nothing again
    {ok, #{<<"new">> := 0}} = muse_mail_sync:sync_now(?O, A),
    ?assertEqual(1, length(muse_store:list(?O, <<"notifications">>))),
    %% flags changed in another client, and a message expunged there
    muse_mail_fake:set_flags(fake(Config), <<"INBOX">>, 2, [<<"\\Seen">>, <<"\\Flagged">>]),
    muse_mail_fake:expunge(fake(Config), <<"INBOX">>, 4),
    {ok, _} = muse_mail_sync:sync_now(?O, A),
    ?assertMatch(#{<<"seen">> := true, <<"flagged">> := true}, by_subject(A, <<"季度报告"/utf8>>)),
    ?assertEqual([<<"季度报告"/utf8>>, <<"新消息"/utf8>>, <<"本周精选"/utf8>>], inbox(A)),
    %% more than three new messages: one summary notification
    [muse_mail_fake:deliver(fake(Config), <<"INBOX">>, #{<<"subject">> => integer_to_binary(N)}) || N <- lists:seq(1, 4)],
    {ok, #{<<"new">> := 4}} = muse_mail_sync:sync_now(?O, A),
    ?assertEqual(1, length([N || N = #{<<"title">> := <<"收到 4 封新邮件"/utf8>>} <- muse_store:list(?O, <<"notifications">>)])).

sync_window_and_validity(Config) ->
    muse_config:set((muse_config:all())#{mail_sync_max => 2}),
    A = synced(),
    %% at most two per folder, the newest
    ?assertEqual([<<"Lunch?">>, <<"本周精选"/utf8>>], inbox(A)),
    muse_config:set((muse_config:all())#{mail_sync_max => 500}),
    %% the server rebuilt the folder: everything is fetched again
    muse_mail_fake:update(fake(Config),
                          fun(S = #{<<"accounts">> := #{<<"me@example.com">> := Acc = #{<<"folders">> := [In | Rest]}} = As}) ->
                                  S#{<<"accounts">> := As#{<<"me@example.com">> := Acc#{<<"folders">> := [In#{<<"uidValidity">> := 9} | Rest]}}}
                          end),
    {ok, _} = muse_mail_sync:sync_now(?O, A),
    ?assertEqual([<<"Lunch?">>, <<"季度报告"/utf8>>, <<"本周精选"/utf8>>], inbox(A)),
    {ok, #{<<"uidValidity">> := <<"9">>}} = muse_mail:folder_by_role(?O, A, <<"inbox">>),
    ?assertMatch([_ | _], [M || M = #{<<"id">> := <<_:16/binary, "-9-", _/binary>>} <- element(2, muse_mail:list(?O, #{account => A, folder => <<"inbox">>}))]),
    %% a folder gone from the server goes here too
    muse_mail_fake:update(fake(Config),
                          fun(S = #{<<"accounts">> := #{<<"me@example.com">> := Acc = #{<<"folders">> := Fs}} = As}) ->
                                  S#{<<"accounts">> := As#{<<"me@example.com">> := Acc#{<<"folders">> := lists:droplast(Fs)}}}
                          end),
    {ok, _} = muse_mail_sync:sync_now(?O, A),
    ?assertEqual([], [F || F = #{<<"path">> := <<"Projects/2026">>} <- muse_mail:folders(?O, A)]).

%%%===================================================================
%%% Writes
%%%===================================================================

writes_go_to_the_server(Config) ->
    A = synced(),
    #{<<"id">> := Id} = by_subject(A, <<"季度报告"/utf8>>),
    {ok, #{<<"seen">> := true}} = muse_mail:set_seen(?O, Id, true),
    ?assertEqual([<<"\\Seen">>], server_flags(Config, <<"INBOX">>, 2)),
    {ok, #{<<"flagged">> := true}} = muse_mail:set_flagged(?O, Id, true),
    ?assertEqual(lists:sort([<<"\\Seen">>, <<"\\Flagged">>]), lists:sort(server_flags(Config, <<"INBOX">>, 2))),
    {ok, #{<<"seen">> := false}} = muse_mail:set_seen(?O, Id, false),
    ?assertEqual([<<"\\Flagged">>], server_flags(Config, <<"INBOX">>, 2)),
    {ok, #{<<"unread">> := 3}} = muse_mail:folder_by_role(?O, A, <<"inbox">>),
    %% a refused write changes nothing here
    muse_mail_fake:fail(fake(Config), <<"flags">>, #{<<"code">> => <<"error">>, <<"message">> => <<"NO [CANNOT]">>}),
    ?assertMatch({error, {502, _}}, muse_mail:set_seen(?O, Id, true)),
    {ok, #{<<"seen">> := false}} = muse_mail:get_message(?O, Id),
    %% archive: the message moves on the server and here (new UID)
    {ok, #{<<"id">> := Archived, <<"subject">> := <<"季度报告"/utf8>>}} = muse_mail:move(?O, Id, <<"archive">>),
    ?assertMatch({error, {404, _}}, muse_mail:get_message(?O, Id)),
    #{<<"messages">> := [#{<<"subject">> := <<"季度报告"/utf8>>}]} = muse_mail_fake:folder(fake(Config), <<"Archive">>),
    {ok, ArchivedMsg} = muse_mail:get_message(?O, Archived),
    ?assertMatch(#{text := <<"请看附件里的季度报告。\n谢谢"/utf8>>}, muse_mail:body(?O, ArchivedMsg)),
    ?assertMatch({error, {409, _}}, muse_mail:move(?O, Archived, <<"archive">>)),
    %% delete: to the trash, then for good
    {ok, #{<<"id">> := Trashed}} = muse_mail:delete(?O, Archived),
    #{<<"messages">> := [_]} = muse_mail_fake:folder(fake(Config), <<"Trash">>),
    {ok, deleted} = muse_mail:delete(?O, Trashed),
    #{<<"messages">> := []} = muse_mail_fake:folder(fake(Config), <<"Trash">>),
    ?assertMatch({error, {404, _}}, muse_mail:get_message(?O, Trashed)).

attachments_and_files(_Config) ->
    A = synced(),
    #{<<"id">> := Id} = by_subject(A, <<"季度报告"/utf8>>),
    {ok, #{name := <<"report.pdf">>, type := <<"application/pdf">>, bytes := <<"%PDF", _/binary>>}} =
        muse_mail:attachment(?O, Id, <<"2">>),
    ?assertMatch({error, {404, _}}, muse_mail:attachment(?O, Id, <<"9">>)),
    {ok, #{<<"id">> := FileId, <<"name">> := <<"report.pdf">>, <<"source">> := Source}} =
        muse_mail:save_attachment(?O, Id, <<"2">>),
    ?assertEqual(<<"邮件附件：「季度报告」"/utf8>>, Source),
    {ok, <<"%PDF", _/binary>>} = muse_files:bytes(?O, FileId).

%%%===================================================================
%%% Drafts and sending
%%%===================================================================

drafts_reply_and_send(Config) ->
    A = synced(),
    #{<<"id">> := Id} = by_subject(A, <<"季度报告"/utf8>>),
    %% reply all: the sender and the other recipients, not me
    {ok, #{<<"id">> := D, <<"to">> := [<<"张三 <zhang@example.com>"/utf8>>], <<"cc">> := [<<"boss@example.com">>],
           <<"subject">> := <<"Re: 季度报告"/utf8>>, <<"inReplyToHeader">> := <<"<q1@example.com>">>,
           <<"references">> := [<<"<root@example.com>">>, <<"<q1@example.com>">>], <<"body">> := Quote}} =
        muse_mail_send:reply_draft(?O, Id, reply_all),
    ?assert(has(Quote, <<"> 请看附件里的季度报告。"/utf8>>)),
    {ok, #{<<"id">> := Up}} = muse_mail_send:add_upload(?O, D, <<"notes.txt">>, <<"hello">>, <<"text/plain">>),
    {ok, Pdf} = muse_pdf:sample(),
    {ok, #{<<"id">> := FileId}} = muse_files:upload(?O, <<"表单.pdf"/utf8>>, Pdf, #{}),
    {ok, _} = muse_mail_send:save_draft(?O, D, #{<<"body">> => <<"收到，谢谢。"/utf8>>, <<"fileIds">> => [FileId],
                                                  <<"bcc">> => <<"Hidden <hidden@example.com>">>}, <<"user">>),
    {ok, #{<<"status">> := <<"sent">>, <<"messageId">> := <<"<fake-1@muse.test>">>, <<"appended">> := true}} =
        muse_mail_send:send_draft(?O, D),
    [Sent] = muse_mail_fake:sent(fake(Config)),
    ?assertMatch(#{<<"from">> := #{<<"name">> := <<"Me">>, <<"address">> := <<"me@example.com">>},
                   <<"to">> := [#{<<"address">> := <<"zhang@example.com">>}],
                   <<"cc">> := [#{<<"address">> := <<"boss@example.com">>}],
                   <<"bcc">> := [#{<<"name">> := <<"Hidden">>, <<"address">> := <<"hidden@example.com">>}],
                   <<"subject">> := <<"Re: 季度报告"/utf8>>, <<"inReplyTo">> := <<"<q1@example.com>">>,
                   <<"references">> := [<<"<root@example.com>">>, <<"<q1@example.com>">>],
                   <<"sentFolder">> := <<"Sent">>}, Sent),
    ?assertEqual([<<"表单.pdf"/utf8>>, <<"notes.txt">>], [N || #{<<"filename">> := N} <- maps:get(<<"attachments">>, Sent)]),
    %% the draft and its upload are gone; the copy is in Sent; the original answered
    ?assertMatch({error, {404, _}}, muse_mail_send:get_draft(?O, D)),
    ?assertEqual(not_found, muse_mail_send:upload_bytes(Up)),
    #{<<"messages">> := [#{<<"subject">> := <<"Re: 季度报告"/utf8>>}]} = muse_mail_fake:folder(fake(Config), <<"Sent">>),
    ?assert(lists:member(<<"\\Answered">>, server_flags(Config, <<"INBOX">>, 2))),
    %% forward: the original attachments go along
    {ok, #{<<"id">> := F, <<"subject">> := <<"Fwd: 季度报告"/utf8>>, <<"to">> := [],
           <<"forwards">> := [#{<<"filename">> := <<"report.pdf">>}, _]}} = muse_mail_send:reply_draft(?O, Id, forward),
    {ok, _} = muse_mail_send:remove_attachment(?O, F, forward, <<"3">>),
    ?assertMatch({error, {422, <<"请至少填写一个收件人"/utf8>>}}, muse_mail_send:send_draft(?O, F)),
    {ok, _} = muse_mail_send:save_draft(?O, F, #{<<"to">> => [<<"x@example.com">>]}, <<"user">>),
    {ok, _} = muse_mail_send:send_draft(?O, F),
    [_, Fwd] = muse_mail_fake:sent(fake(Config)),
    ?assertMatch(#{<<"attachments">> := [#{<<"filename">> := <<"report.pdf">>}], <<"inReplyTo">> := null}, Fwd),
    %% recipients are checked when sending
    {ok, #{<<"id">> := Bad}} = muse_mail_send:save_draft(?O, new, #{<<"to">> => <<"a@example.com, not an address">>},
                                                         <<"user">>),
    ?assertEqual({error, {422, <<"收件人地址无效：not an address"/utf8>>}}, muse_mail_send:send_draft(?O, Bad)),
    ?assertEqual({ok, [#{<<"name">> => <<"Doe, John">>, <<"address">> => <<"j@x.org">>},
                       #{<<"name">> => <<>>, <<"address">> => <<"k@y.org">>}]},
                 muse_mail_send:parse_addresses(<<"\"Doe, John\" <J@x.org>；k@y.org"/utf8>>)).

send_failures(Config) ->
    _ = synced(),
    {ok, #{<<"id">> := D}} = muse_mail_send:save_draft(?O, new, #{<<"to">> => <<"x@example.com">>,
                                                                  <<"subject">> => <<"Hi">>}, <<"user">>),
    %% refused by the server: back to a draft with the reason, nothing sent
    muse_mail_fake:fail(fake(Config), <<"send">>, #{<<"code">> => <<"send_failed">>, <<"message">> => <<"550 rejected">>,
                                                    <<"definite">> => true}),
    {error, {502, Why}} = muse_mail_send:send_draft(?O, D),
    ?assert(has(Why, <<"550 rejected">>)),
    {ok, #{<<"status">> := <<"draft">>, <<"error">> := Why}} = muse_mail_send:get_draft(?O, D),
    %% the connection broke during DATA: the outcome is unknown, said so
    muse_mail_fake:fail(fake(Config), <<"send">>, #{<<"code">> => <<"send_failed">>, <<"message">> => <<"socket closed">>,
                                                    <<"definite">> => false}),
    {error, {outcome_unknown, _}} = muse_mail_send:send_draft(?O, D),
    {ok, #{<<"status">> := <<"draft">>, <<"error">> := <<"发送结果未知："/utf8, _/binary>>}} = muse_mail_send:get_draft(?O, D),
    ?assertEqual([], muse_mail_fake:sent(fake(Config))),
    ?assertMatch([#{<<"status">> := <<"unknown">>}, #{<<"status">> := <<"failed">>}],
                 lists:sort(fun(X, Y) -> maps:get(<<"status">>, X) >= maps:get(<<"status">>, Y) end,
                            muse_store:list(?O, <<"mail-sends">>))).

send_draft_once(Config) ->
    _ = synced(),
    {ok, #{<<"id">> := D}} = muse_mail_send:save_draft(?O, new, #{<<"to">> => <<"x@example.com">>,
                                                                  <<"subject">> => <<"Once">>}, <<"user">>),
    muse_mail_fake:delay(fake(Config), <<"send">>, 400),
    Self = self(),
    [spawn(fun() -> Self ! {done, muse_mail_send:send_draft(?O, D)} end) || _ <- [1, 2, 3]],
    Results = [receive {done, R} -> R after 10000 -> timeout end || _ <- [1, 2, 3]],
    ?assertEqual(1, length([ok || {ok, _} <- Results])),
    ?assertEqual(1, length(muse_mail_fake:sent(fake(Config)))),
    %% the same receipt key never sends again
    {ok, Msg} = muse_mail_send:build_message(?O, #{<<"to">> => [<<"y@example.com">>], <<"subject">> => <<"K">>}),
    {ok, #{<<"status">> := <<"sent">>} = R1} = muse_mail_send:send(?O, Msg, <<"api:k1">>, <<"api">>),
    {ok, R1} = muse_mail_send:send(?O, Msg, <<"api:k1">>, <<"api">>),
    ?assertEqual(2, length(muse_mail_fake:sent(fake(Config)))).

%%%===================================================================
%%% The mail.send kind
%%%===================================================================

propose(Data) ->
    muse_actions:propose(?O, #{<<"kind">> => <<"mail.send">>, <<"data">> => Data}, undefined, undefined).

mail_send_kind(Config) ->
    A = synced(),
    #{<<"id">> := Reply} = by_subject(A, <<"Lunch?">>),
    {ok, Pdf} = muse_pdf:sample(),
    {ok, #{<<"id">> := FileId}} = muse_files:upload(?O, <<"menu.pdf">>, Pdf, #{}),
    {ok, #{<<"id">> := AId, <<"status">> := <<"awaiting_review">>, <<"title">> := <<"发送邮件：Re: Lunch?"/utf8>>,
           <<"data">> := Data, <<"hash">> := Hash}} =
        propose(#{<<"to">> => [<<"Li <li@example.com>">>], <<"subject">> => <<"Re: Lunch?">>,
                  <<"body">> => <<"Yes, 12:30.">>, <<"inReplyTo">> => Reply, <<"attachments">> => [FileId],
                  <<"bcc">> => [<<"me@example.com">>], <<"sendId">> => <<"chosen-by-the-model">>}),
    %% prepare filled in what the card shows; the caller's sendId is replaced
    ?assertMatch(#{<<"accountId">> := A, <<"from">> := <<"Me <me@example.com>">>,
                   <<"to">> := [<<"Li <li@example.com>">>], <<"inReplyToHeader">> := <<"<l4@example.com>">>,
                   <<"references">> := [<<"<l4@example.com>">>], <<"replySubject">> := <<"Lunch?">>,
                   <<"attachmentNames">> := [<<"menu.pdf (", _/binary>>]}, Data),
    ?assertNotEqual(<<"chosen-by-the-model">>, maps:get(<<"sendId">>, Data)),
    #{title := <<"发送邮件：Re: Lunch?"/utf8>>, fields := Fields} = muse_actions:display(muse_actions:get(?O, AId)),
    ?assertEqual([<<"发件人"/utf8>>, <<"收件人"/utf8>>, <<"抄送"/utf8>>, <<"密送"/utf8>>, <<"主题"/utf8>>,
                  <<"回复"/utf8>>, <<"正文"/utf8>>, <<"附件"/utf8>>], [L || {L, _} <- Fields]),
    ?assertMatch({_, <<"me@example.com">>}, lists:keyfind(<<"密送"/utf8>>, 1, Fields)),
    %% the long body is cut on the card
    {ok, #{<<"id">> := Long}} = propose(#{<<"to">> => [<<"a@example.com">>], <<"subject">> => <<"Long">>,
                                          <<"body">> => binary:copy(<<"字"/utf8>>, 900)}),
    #{fields := LF} = muse_actions:display(muse_actions:get(?O, Long)),
    {_, Shown} = lists:keyfind(<<"正文"/utf8>>, 1, LF),
    ?assertEqual(601, string:length(Shown)),
    %% ownership and validity are checked before review
    ?assertMatch({error, {404, _}}, propose(#{<<"to">> => [<<"a@example.com">>], <<"subject">> => <<"S">>,
                                              <<"body">> => <<"B">>, <<"attachments">> => [muse_ids:uuid()]})),
    {ok, #{<<"id">> := Theirs}} = muse_files:upload(<<"someone-else">>, <<"x.pdf">>, Pdf, #{}),
    ?assertMatch({error, {404, _}}, propose(#{<<"to">> => [<<"a@example.com">>], <<"subject">> => <<"S">>,
                                              <<"body">> => <<"B">>, <<"attachments">> => [Theirs]})),
    ?assertMatch({error, {404, _}}, propose(#{<<"to">> => [<<"a@example.com">>], <<"subject">> => <<"S">>,
                                              <<"body">> => <<"B">>, <<"accountId">> => <<"nope">>})),
    ?assertMatch({error, {422, _}}, propose(#{<<"to">> => [<<"not an address">>], <<"subject">> => <<"S">>,
                                              <<"body">> => <<"B">>})),
    ?assertMatch({error, {404, _}}, propose(#{<<"to">> => [<<"a@example.com">>], <<"subject">> => <<"S">>,
                                              <<"body">> => <<"B">>, <<"inReplyTo">> => <<"0000000000000000-1-1">>})),
    %% nothing is sent before approval
    ?assertEqual([], muse_mail_fake:sent(fake(Config))),
    {ok, #{<<"status">> := <<"succeeded">>, <<"result">> := Receipt}} = muse_actions:decide(?O, AId, Hash, approve),
    ?assertEqual(<<"已发送邮件「Re: Lunch?」给 Li <li@example.com>"/utf8>>, Receipt),
    [Sent] = muse_mail_fake:sent(fake(Config)),
    ?assertMatch(#{<<"inReplyTo">> := <<"<l4@example.com>">>, <<"bcc">> := [#{<<"address">> := <<"me@example.com">>}],
                   <<"attachments">> := [#{<<"filename">> := <<"menu.pdf">>}]}, Sent),
    %% a second approval (or a retry) sends nothing
    {ok, #{<<"status">> := <<"succeeded">>}} = muse_actions:decide(?O, AId, Hash, approve),
    #{<<"data">> := Stored} = muse_actions:get(?O, AId),
    {ok, _} = muse_mail_action:execute(?O, Stored, #{}),
    ?assertEqual(1, length(muse_mail_fake:sent(fake(Config)))),
    %% the task model gets a prepare tool for it
    ?assert(lists:member(<<"prepare_mail_send">>, [N || #{name := N} <- muse_actions:tools()])).

mail_send_outcome_unknown(Config) ->
    _ = synced(),
    Base = #{<<"to">> => [<<"a@example.com">>], <<"subject">> => <<"S">>, <<"body">> => <<"B">>},
    %% a crash between the two receipt writes: the receipt says sending
    {ok, #{<<"id">> := A1, <<"hash">> := H1, <<"data">> := #{<<"sendId">> := S1}}} = propose(Base),
    _ = muse_store:put(?O, <<"mail-sends">>, #{<<"id">> => muse_ids:sha256hex(<<"mail-send:action:", S1/binary>>),
                                              <<"status">> => <<"sending">>}),
    {ok, #{<<"status">> := <<"outcome_unknown">>, <<"error">> := E1}} = muse_actions:decide(?O, A1, H1, approve),
    ?assert(has(E1, <<"结果未知"/utf8>>)),
    %% the connection broke while the message went out
    {ok, #{<<"id">> := A2, <<"hash">> := H2}} = propose(Base#{<<"subject">> => <<"S2">>}),
    muse_mail_fake:fail(fake(Config), <<"send">>, #{<<"code">> => <<"send_failed">>, <<"message">> => <<"lost">>,
                                                    <<"definite">> => false}),
    {ok, #{<<"status">> := <<"outcome_unknown">>}} = muse_actions:decide(?O, A2, H2, approve),
    %% refused by the server: failed
    {ok, #{<<"id">> := A3, <<"hash">> := H3}} = propose(Base#{<<"subject">> => <<"S3">>}),
    muse_mail_fake:fail(fake(Config), <<"send">>, #{<<"code">> => <<"send_failed">>, <<"message">> => <<"550 no">>,
                                                    <<"definite">> => true}),
    {ok, #{<<"status">> := <<"failed">>, <<"error">> := E3}} = muse_actions:decide(?O, A3, H3, approve),
    ?assert(has(E3, <<"550 no">>)),
    ?assertEqual([], muse_mail_fake:sent(fake(Config))),
    %% a restart during execution
    {ok, #{<<"id">> := A4}} = propose(Base#{<<"subject">> => <<"S4">>}),
    _ = muse_store:cas(?O, <<"actions">>, A4, #{}, #{<<"status">> => <<"executing">>}),
    1 = muse_store:recover_interrupted_actions(),
    #{<<"status">> := <<"outcome_unknown">>} = muse_actions:get(?O, A4).

%%%===================================================================
%%% The agent's reads
%%%===================================================================

agent_read_tools(_Config) ->
    ?assertMatch({error, {404, <<"No mailbox is set up yet", _/binary>>}}, muse_mail:search(?O, #{})),
    A = synced(),
    {ok, #{<<"messages">> := All, <<"total">> := 3, <<"note">> := Note}} = muse_mail:search(?O, #{}),
    ?assert(has(Note, <<"untrusted">>)),
    ?assertEqual([<<"Lunch?">>, <<"本周精选"/utf8>>, <<"季度报告"/utf8>>], [S || #{<<"subject">> := S} <- All]),
    {ok, #{<<"messages">> := [#{<<"subject">> := <<"Lunch?">>, <<"messageId">> := LunchId}]}} =
        muse_mail:search(?O, #{<<"query">> => <<"tomorrow">>}),
    {ok, #{<<"messages">> := [_]}} = muse_mail:search(?O, #{<<"query">> => <<"张三"/utf8>>}),
    {ok, #{<<"total">> := 2}} = muse_mail:search(?O, #{<<"unreadOnly">> => true}),
    {ok, #{<<"total">> := 1}} = muse_mail:search(?O, #{<<"folder">> => <<"starred">>}),
    {ok, #{<<"messages">> := [#{<<"subject">> := <<"项目计划"/utf8>>}]}} =
        muse_mail:search(?O, #{<<"folder">> => <<"Projects/2026">>}),
    {ok, #{<<"total">> := 0}} = muse_mail:search(?O, #{<<"folder">> => <<"sent">>}),
    Today = muse_calendar:today(),
    {ok, #{<<"total">> := 0}} = muse_mail:search(?O, #{<<"from">> => Today}),
    {ok, #{<<"total">> := 3}} = muse_mail:search(?O, #{<<"to">> => Today, <<"account">> => <<"me@example.com">>}),
    {ok, #{<<"messages">> := [_, _], <<"truncated">> := true}} = muse_mail:search(?O, #{<<"limit">> => 2}),
    ?assertMatch({error, {404, _}}, muse_mail:search(?O, #{<<"account">> => <<"x@y.z">>})),
    {ok, R} = muse_mail:read(?O, #{<<"messageId">> => LunchId}),
    ?assertMatch(#{<<"subject">> := <<"Lunch?">>, <<"from">> := <<"Li <li@example.com>">>,
                   <<"text">> := <<"Are you free tomorrow?", _/binary>>, <<"link">> := <<"/mail/", _/binary>>,
                   <<"thread">> := [], <<"note">> := _}, R),
    #{<<"id">> := ReportId} = by_subject(A, <<"季度报告"/utf8>>),
    {ok, #{<<"attachments">> := [#{<<"name">> := <<"report.pdf">>}, #{<<"name">> := <<"page.html">>}]}} =
        muse_mail:read(?O, #{<<"messageId">> => ReportId}),
    ?assertMatch({error, {404, _}}, muse_mail:read(?O, #{<<"messageId">> => <<"nope">>})),
    %% the HTML-only newsletter reads as text
    #{<<"id">> := NewsId} = by_subject(A, <<"本周精选"/utf8>>),
    {ok, #{<<"text">> := NewsText}} = muse_mail:read(?O, #{<<"messageId">> => NewsId}),
    ?assertNotEqual(<<>>, NewsText),
    %% drafts are searchable too
    {ok, #{<<"id">> := D}} = muse_mail_send:save_draft(?O, new, #{<<"subject">> => <<"草稿一"/utf8>>}, <<"agent">>),
    {ok, #{<<"messages">> := [#{<<"draftId">> := D, <<"link">> := <<"/mail?folder=drafts&draft=", D/binary>>}]}} =
        muse_mail:search(?O, #{<<"folder">> => <<"drafts">>}).

%%%===================================================================
%%% The sync process
%%%===================================================================

wait_for(Fun) ->
    muse_engine_test_env:wait_for(Fun, 15000).

sync_process_idle_and_backoff(Config) ->
    {ok, Sup} = muse_mail_sup:start_link(), unlink(Sup),
    #{<<"id">> := A} = account(#{}),
    %% the account's process syncs at once and then IDLEs on the inbox
    wait_for(fun() -> maps:get(<<"status">>, muse_mail:sync_state(?O, A)) =:= <<"ok">> end),
    wait_for(fun() -> maps:get(<<"idle">>, muse_mail:sync_state(?O, A), false) =:= true end),
    ?assertMatch([_], supervisor:which_children(muse_mail_sup)),
    %% new mail wakes it through the watch
    muse_mail_fake:deliver(fake(Config), <<"INBOX">>, #{<<"subject">> => <<"Pushed">>}),
    wait_for(fun() -> lists:member(<<"Pushed">>, inbox(A)) end),
    %% a failing pass: the state says why and when it retries
    muse_mail_fake:fail(fake(Config), <<"folders">>, #{<<"code">> => <<"auth">>, <<"message">> => <<"AUTHENTICATIONFAILED">>}),
    {error, {502, _}} = muse_mail_sync:sync_now(?O, A),
    #{<<"status">> := <<"error">>, <<"lastError">> := Err, <<"failures">> := 1, <<"nextSyncAt">> := Next} =
        muse_mail:sync_state(?O, A),
    ?assert(has(Err, <<"登录失败"/utf8>>)),
    ?assertNot(has(Err, muse_mail_fake:password())),
    ?assert(muse_time:parse(Next) > muse_time:now_ms() + 50000),
    {ok, _} = muse_mail_sync:sync_now(?O, A),
    #{<<"status">> := <<"ok">>, <<"failures">> := 0} = muse_mail:sync_state(?O, A),
    %% deleting the account stops its process
    ok = muse_mail_accounts:delete(?O, A),
    wait_for(fun() -> supervisor:which_children(muse_mail_sup) =:= [] end).

client_timeout_and_restart(Config) ->
    #{<<"id">> := A} = account(#{}),
    {ok, Acc} = muse_mail_accounts:sidecar_account(?O, A),
    muse_mail_fake:delay(fake(Config), <<"folders">>, 2000),
    ?assertMatch({error, #{code := <<"timeout">>}},
                 muse_mail_client:request(<<"folders">>, #{<<"account">> => Acc}, 300)),
    %% a send that times out may have gone out: never definite
    timer:sleep(200),
    muse_mail_fake:delay(fake(Config), <<"send">>, 2000),
    ?assertMatch({error, #{code := <<"timeout">>, definite := false}},
                 muse_mail_client:request(<<"send">>, #{<<"account">> => Acc}, 300)),
    muse_mail_fake:delay(fake(Config), <<"folders">>, 0),
    {ok, #{<<"folders">> := [_ | _]}} = muse_mail_client:request(<<"folders">>, #{<<"account">> => Acc}, 10000),
    %% a missing helper is an error, not a crash
    muse_config:set((muse_config:all())#{mail_sidecar => <<"/nonexistent/mail-helper">>}),
    ok = muse_mail_client:reset(),
    ?assertMatch({error, #{code := <<"unavailable">>}},
                 muse_mail_client:request(<<"folders">>, #{<<"account">> => Acc}, 1000)),
    ?assertMatch({error, {502, _}}, muse_mail_sync:run(?O, A)).
