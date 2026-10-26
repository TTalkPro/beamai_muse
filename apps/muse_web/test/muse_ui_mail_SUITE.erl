%% The built-in mail in the UI, the chat and the JSON API (tasks/M9-workspace.md
%% M9-8): the `/mail' page and its actions (called the way the aihtml runtime
%% calls them), `/mail/accounts', the sandboxed body frame and attachment
%% downloads (`/mail-content/...'), the compose window's uploads, the agent's
%% mail tools with the approval card in the chat and on 审批, and
%% `/api/mail/*'. Sample mode; the mail servers are muse_mail_fake.
-module(muse_ui_mail_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).
-define(BOUNDARY, "muse-mail-boundary-3c1f").

all() ->
    [empty_page_and_sidebar, accounts_page, page_render_and_navigation, html_safety_and_attachments,
     compose_send_and_reply, chat_tools_and_card, api_routes].

init_per_testcase(_Case, Config) ->
    Env = muse_web_test_env:start(#{<<"TOKEN_ENCRYPTION_KEY">> => base64:encode(crypto:strong_rand_bytes(32))}),
    File = muse_mail_fake:setup(maps:get(dir, Env)),
    C = [{env, Env}, {fake, File} | Config],
    [{cookie, sign_in(C)} | C].

end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)).

fake(Config) -> ?config(fake, Config).

%% HTTP helpers (as muse_ui_calendar_SUITE)

host(Config) ->
    #{port := Port} = ?config(env, Config),
    "localhost:" ++ integer_to_list(Port).

origin() -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

same_origin(Config) -> [{"origin", origin()}, {"host", host(Config)}].

req(Config, Method, Path, Headers, Body) ->
    Url = muse_web_test_env:base(?config(env, Config)) ++ Path,
    Request = case Body of
                  undefined -> {Url, Headers};
                  {form, Form} -> {Url, Headers, "application/x-www-form-urlencoded", uri_string:compose_query(Form)};
                  {Type, Bin} -> {Url, Headers, Type, Bin}
              end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{autoredirect, false}, {timeout, 30000}], [{body_format, binary}]),
    {Status, RespHeaders, RespBody}.

sign_in(Config) ->
    {302, H, _} = req(Config, post, "/login", same_origin(Config), {form, []}),
    [SetCookie] = [V || {"set-cookie", V} <- H],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

cookie(Config) -> [{"cookie", "muse_session=" ++ ?config(cookie, Config)}].

page(Config, Path) ->
    {200, _, Html} = req(Config, get, Path, cookie(Config), undefined),
    Html.

act(Config, Ref, Event) ->
    Body = muse_json:encode(#{<<"action">> => aihtml_action:token(Ref), <<"event">> => Event}),
    {200, _, Resp} = req(Config, post, "/aihtml/action", cookie(Config) ++ same_origin(Config),
                         {"application/json", Body}),
    lists:append([Ops || L <- binary:split(Resp, <<"\n">>, [global, trim_all]),
                         {ok, #{<<"ops">> := Ops}} <- [muse_json:decode(L)]]).

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

contains(B, Needle) when is_binary(B) -> has(B, Needle);
contains(L, Needle) when is_list(L) -> lists:any(fun(X) -> contains(X, Needle) end, L);
contains(M, Needle) when is_map(M) -> contains(maps:values(M), Needle);
contains(_, _) -> false.

op(Ops, Name) -> [O || O = #{<<"op">> := N} <- Ops, N =:= Name].

%% The tab's state values an action includes.
values(A, Folder, Msg) ->
    #{<<"mail-st-account">> => A, <<"mail-st-folder">> => Folder, <<"mail-st-msg">> => Msg,
      <<"mail-st-limit">> => <<"50">>, <<"mail-q">> => <<>>}.

click(Values) -> #{<<"type">> => <<"click">>, <<"values">> => Values}.

submit(Form, Values) -> #{<<"type">> => <<"submit">>, <<"form">> => Form, <<"values">> => Values}.

synced() ->
    {ok, #{<<"id">> := A}} = muse_mail_accounts:create(?O, muse_mail_fake:account_input(), #{}),
    {ok, _} = muse_mail_sync:sync_now(?O, A),
    A.

by_subject(A, Subject) ->
    {_, Msgs} = muse_mail:list(?O, #{account => A, folder => <<"inbox">>, limit => 100}),
    hd([M || M = #{<<"subject">> := S} <- Msgs, S =:= Subject]).

multipart(Name, Type, Bytes) ->
    B = <<?BOUNDARY>>,
    {"multipart/form-data; boundary=" ?BOUNDARY,
     iolist_to_binary([<<"--", B/binary, "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"",
                         Name/binary, "\"\r\nContent-Type: ", Type/binary, "\r\n\r\n">>, Bytes,
                       <<"\r\n--", B/binary, "--\r\n">>])}.

%%%===================================================================
%%% Cases
%%%===================================================================

empty_page_and_sidebar(Config) ->
    Html = page(Config, "/mail"),
    [?assert(has(Html, P), P) || P <- [<<"还没有邮箱账号"/utf8>>, <<"href=\"/mail/accounts\"">>, <<"id=\"mail-empty\"">>,
                                       %% the sidebar entry, after 日程
                                       <<"href=\"/mail\"">>, <<"id=\"muse-mail-count\"">>]],
    {CalPos, _} = binary:match(Html, <<"href=\"/calendar\"">>),
    {MailPos, _} = binary:match(Html, <<"href=\"/mail\"">>),
    ?assert(MailPos > CalPos),
    ?assert(has(page(Config, "/activity"), <<"href=\"/mail\"">>)),
    %% signed out: the login page
    {302, _, _} = req(Config, get, "/mail", [], undefined).

accounts_page(Config) ->
    Html = page(Config, "/mail/accounts"),
    [?assert(has(Html, P), P) || P <- [<<"邮箱账号"/utf8>>, <<"id=\"mail-acc-form\"">>, <<"imap.qq.com">>,
                                       <<"QQ 邮箱"/utf8>>, <<"网易 163 邮箱"/utf8>>, <<"Gmail">>, <<"Outlook / Office 365">>,
                                       <<"iCloud 邮件"/utf8>>, <<"测试连接"/utf8>>, <<"允许自签名证书"/utf8>>,
                                       <<"type=\"password\"">>]],
    %% a preset fills in the servers, keeping what was typed
    Preset = act(Config, {muse_ui_mail, preset, #{mode => new}},
                 #{<<"type">> => <<"change">>, <<"form">> => #{<<"preset">> => <<"gmail">>, <<"name">> => <<"Me">>,
                                                              <<"email">> => <<"me@gmail.com">>}}),
    ?assert(contains(Preset, <<"imap.gmail.com">>)),
    ?assert(contains(Preset, <<"me@gmail.com">>)),
    ?assert(contains(Preset, <<"应用专用密码"/utf8>>)),
    Form = fun(Over) ->
                   maps:merge(#{<<"preset">> => <<"custom">>, <<"name">> => <<"Me">>, <<"email">> => <<"me@example.com">>,
                                <<"username">> => <<>>, <<"password">> => muse_mail_fake:password(),
                                <<"imapHost">> => <<"imap.example.com">>, <<"imapPort">> => <<"993">>,
                                <<"imapSecurity">> => <<"tls">>, <<"smtpHost">> => <<"smtp.example.com">>,
                                <<"smtpPort">> => <<"465">>, <<"smtpSecurity">> => <<"tls">>, <<"saveSent">> => <<"true">>},
                              Over)
           end,
    %% 测试连接
    Bad = act(Config, {muse_ui_mail, test_account, #{id => new}},
              #{<<"type">> => <<"click">>, <<"form">> => Form(#{<<"password">> => <<"wrong">>})}),
    ?assert(contains(Bad, <<"登录失败"/utf8>>)),
    Good = act(Config, {muse_ui_mail, test_account, #{id => new}}, #{<<"type">> => <<"click">>, <<"form">> => Form(#{})}),
    ?assert(contains(Good, <<"连接成功"/utf8>>)),
    %% save checks first, then stores
    Saved = act(Config, {muse_ui_mail, save_account, #{id => new}}, #{<<"type">> => <<"submit">>, <<"form">> => Form(#{})}),
    ?assert(contains(Saved, <<"邮箱账号已保存"/utf8>>)),
    [#{<<"id">> := Id, <<"imapPort">> := 993}] = muse_mail_accounts:list(?O),
    %% the password never reaches a page
    Page = page(Config, "/mail/accounts?edit=" ++ binary_to_list(Id)),
    ?assertNot(has(Page, muse_mail_fake:password())),
    ?assert(has(Page, <<"留空则不修改"/utf8>>)),
    ?assert(has(Page, <<"imap.example.com:993 · TLS"/utf8>>)),
    %% edit without retyping the password
    Edited = act(Config, {muse_ui_mail, save_account, #{id => Id}},
                 #{<<"type">> => <<"submit">>, <<"form">> => Form(#{<<"password">> => <<>>, <<"name">> => <<"Work">>})}),
    ?assertNot(contains(Edited, muse_mail_fake:password())),
    {ok, #{<<"name">> := <<"Work">>}} = muse_mail_accounts:get(?O, Id),
    {ok, #{<<"imap">> := #{<<"pass">> := P}}} = muse_mail_accounts:sidecar_account(?O, Id),
    ?assertEqual(muse_mail_fake:password(), P),
    %% delete
    Deleted = act(Config, {muse_ui_mail, delete_account, #{id => Id}}, #{<<"type">> => <<"click">>}),
    ?assert(contains(Deleted, <<"邮箱账号已删除"/utf8>>)),
    ?assertEqual([], muse_mail_accounts:list(?O)).

page_render_and_navigation(Config) ->
    A = synced(),
    Html = page(Config, "/mail"),
    [?assert(has(Html, P), P)
     || P <- [<<"id=\"mail-rail\"">>, <<"id=\"mail-list\"">>, <<"id=\"mail-reader\"">>,
              <<"收件箱"/utf8>>, <<"已加星标"/utf8>>, <<"草稿"/utf8>>, <<"已发送"/utf8>>, <<"归档"/utf8>>, <<"垃圾箱"/utf8>>,
              <<"其他文件夹"/utf8>>, <<"Projects / 2026">>,
              <<"季度报告"/utf8>>, <<"张三"/utf8>>, <<"请看附件里的季度报告。"/utf8>>, <<"Lunch?">>,
              <<"已同步"/utf8>>, <<"写邮件"/utf8>>, <<"选择一封邮件来阅读"/utf8>>, <<"id=\"mail-sync\"">>,
              <<"data-ah-subscribe">>, <<"搜索邮件"/utf8>>, <<"muse-mail-unread">>,
              <<"href=\"/mail?account=", A/binary, "&amp;folder=sent\"">>]],
    %% the inbox unread count in the rail and the sidebar
    ?assert(has(Html, <<"<span class=\"muse-mail-count\">3</span>">>)),
    ?assert(has(Html, <<"id=\"muse-mail-count\">3</span>">>)),
    %% the 60-day-old message is not there
    ?assertNot(has(Html, <<"旧邮件"/utf8>>)),
    %% open a message: the reader, marked read here and on the server
    #{<<"id">> := Id} = by_subject(A, <<"季度报告"/utf8>>),
    Open = act(Config, {muse_ui_mail, open, #{id => Id}}, click(values(A, <<"inbox">>, <<>>))),
    [?assert(contains(Open, P), P) || P <- [<<"mail-message-", Id/binary>>, <<"回复"/utf8>>, <<"全部回复"/utf8>>,
                                            <<"转发"/utf8>>, <<"归档"/utf8>>, <<"标为未读"/utf8>>, <<"report.pdf">>,
                                            <<"保存到文件"/utf8>>, <<"boss@example.com">>]],
    ?assertMatch([#{<<"value">> := <<"/mail/", Id/binary>>}], op(Open, <<"url">>)),
    {ok, #{<<"seen">> := true}} = muse_mail:get_message(?O, Id),
    #{<<"messages">> := Ms} = muse_mail_fake:folder(fake(Config), <<"INBOX">>),
    ?assertEqual([<<"\\Seen">>], hd([F || #{<<"uid">> := 2, <<"flags">> := F} <- Ms])),
    %% the message's own address renders the same reader
    Direct = page(Config, "/mail/" ++ binary_to_list(Id)),
    ?assert(has(Direct, <<"mail-message-", Id/binary>>)),
    ?assert(has(Direct, <<"<title>季度报告"/utf8>>) orelse has(Direct, <<"季度报告"/utf8>>)),
    ?assert(has(page(Config, "/mail/0000000000000000-1-9"), <<"找不到这封邮件"/utf8>>)),
    %% star from the list
    Star = act(Config, {muse_ui_mail, star, #{id => Id, on => true}}, click(values(A, <<"inbox">>, Id))),
    ?assert(contains(Star, <<"muse-on">>)),
    {ok, #{<<"flagged">> := true}} = muse_mail:get_message(?O, Id),
    %% switch folders
    Starred = act(Config, {muse_ui_mail, folder, #{folder => <<"starred">>}}, click(values(A, <<"inbox">>, <<>>))),
    ?assert(contains(Starred, <<"季度报告"/utf8>>)),
    ?assert(contains(Starred, <<"Lunch?">>)),
    ?assertNot(contains(Starred, <<"本周精选"/utf8>>)),
    ?assertMatch([#{<<"value">> := <<"/mail?account=", _/binary>>}], op(Starred, <<"url">>)),
    Sent = act(Config, {muse_ui_mail, folder, #{folder => <<"sent">>}}, click(values(A, <<"inbox">>, <<>>))),
    ?assert(contains(Sent, <<"这里没有邮件"/utf8>>)),
    %% search
    Search = act(Config, {muse_ui_mail, search, #{}},
                 #{<<"type">> => <<"input">>, <<"values">> => (values(A, <<"inbox">>, <<>>))#{<<"mail-q">> => <<"lunch">>}}),
    ?assert(contains(Search, <<"Lunch?">>)),
    ?assertNot(contains(Search, <<"季度报告"/utf8>>)),
    %% mark unread, archive and delete write to the server
    _ = act(Config, {muse_ui_mail, unread, #{id => Id}}, click(values(A, <<"inbox">>, Id))),
    {ok, #{<<"seen">> := false}} = muse_mail:get_message(?O, Id),
    Arch = act(Config, {muse_ui_mail, archive, #{id => Id}}, click(values(A, <<"inbox">>, Id))),
    ?assert(contains(Arch, <<"已归档"/utf8>>)),
    #{<<"messages">> := [_]} = muse_mail_fake:folder(fake(Config), <<"Archive">>),
    #{<<"id">> := Lunch} = by_subject(A, <<"Lunch?">>),
    _ = act(Config, {muse_ui_mail, delete, #{id => Lunch}}, click(values(A, <<"inbox">>, Lunch))),
    #{<<"messages">> := [_]} = muse_mail_fake:folder(fake(Config), <<"Trash">>),
    %% live: a change elsewhere triggers the tab's refresh
    Refresh = act(Config, {muse_ui_mail, refresh, #{}}, click(values(A, <<"inbox">>, <<>>))),
    ?assert(contains(Refresh, <<"mail-rail">>)),
    ?assertNot(contains(Refresh, <<"Lunch?">>)).

html_safety_and_attachments(Config) ->
    A = synced(),
    #{<<"id">> := News} = by_subject(A, <<"本周精选"/utf8>>),
    %% HTML-only mail opens in the sandboxed frame
    Open = act(Config, {muse_ui_mail, open, #{id => News}}, click(values(A, <<"inbox">>, <<>>))),
    [?assert(contains(Open, P), P) || P <- [<<"<iframe">>, <<"sandbox=\"allow-popups allow-popups-to-escape-sandbox\"">>,
                                            <<"/mail-content/", News/binary, "/body">>, <<"显示图片"/utf8>>,
                                            <<"referrerpolicy=\"no-referrer\"">>]],
    ?assertNot(contains(Open, <<"allow-scripts">>)),
    ?assertNot(contains(Open, <<"allow-same-origin">>)),
    Path = "/mail-content/" ++ binary_to_list(News) ++ "/body",
    {401, _, _} = req(Config, get, Path, [], undefined),
    {200, H, Body} = req(Config, get, Path, cookie(Config), undefined),
    Csp = list_to_binary(proplists:get_value("content-security-policy", H)),
    [?assert(has(Csp, P), P) || P <- [<<"sandbox allow-popups allow-popups-to-escape-sandbox">>, <<"default-src 'none'">>,
                                      <<"img-src data:;">>, <<"form-action 'none'">>, <<"base-uri 'none'">>,
                                      <<"frame-ancestors 'self'">>]],
    ?assertNot(has(Csp, <<"script-src">>)),
    ?assertNot(has(Csp, <<"https:">>)),
    ?assertEqual("nosniff", proplists:get_value("x-content-type-options", H)),
    ?assertEqual("no-referrer", proplists:get_value("referrer-policy", H)),
    ?assertMatch("text/html" ++ _, proplists:get_value("content-type", H)),
    %% the cid: image is inlined, links open in new tabs
    ?assert(has(Body, <<"src=\"data:image/png;base64,">>)),
    ?assertNot(has(Body, <<"cid:logo@x">>)),
    ?assert(has(Body, <<"<base target=\"_blank\">">>)),
    %% 显示图片 allows remote images (still no scripts)
    {200, H2, _} = req(Config, get, Path ++ "?images=1", cookie(Config), undefined),
    Csp2 = list_to_binary(proplists:get_value("content-security-policy", H2)),
    ?assert(has(Csp2, <<"img-src data: https: http:">>)),
    ?assertNot(has(Csp2, <<"script-src">>)),
    Shown = act(Config, {muse_ui_mail, view, #{id => News, view => html, images => true}}, #{<<"type">> => <<"click">>}),
    ?assert(contains(Shown, <<"/body?images=1">>)),
    %% a text message shows its text, escaped, not as HTML
    #{<<"id">> := Report} = by_subject(A, <<"季度报告"/utf8>>),
    Text = act(Config, {muse_ui_mail, open, #{id => Report}}, click(values(A, <<"inbox">>, <<>>))),
    ?assert(contains(Text, <<"muse-mail-text">>)),
    ?assertNot(contains(Text, <<"<iframe">>)),
    %% attachments: the Files content route's rules
    Att = fun(Part, Q) -> "/mail-content/" ++ binary_to_list(Report) ++ "/attachment?part=" ++ Part ++ Q end,
    {200, PH, <<"%PDF", _/binary>>} = req(Config, get, Att("2", ""), cookie(Config), undefined),
    ?assertEqual("application/pdf", proplists:get_value("content-type", PH)),
    ?assertMatch("inline; filename*=UTF-8''report.pdf", proplists:get_value("content-disposition", PH)),
    ?assertEqual("nosniff", proplists:get_value("x-content-type-options", PH)),
    {200, PD, _} = req(Config, get, Att("2", "&download=1"), cookie(Config), undefined),
    ?assertMatch("attachment;" ++ _, proplists:get_value("content-disposition", PD)),
    {200, HH, <<"<script>x()</script>">>} = req(Config, get, Att("3", ""), cookie(Config), undefined),
    ?assertEqual("application/octet-stream", proplists:get_value("content-type", HH)),
    ?assertMatch("attachment;" ++ _, proplists:get_value("content-disposition", HH)),
    {404, _, _} = req(Config, get, Att("9", ""), cookie(Config), undefined),
    {401, _, _} = req(Config, get, Att("2", ""), [], undefined),
    %% 保存到文件
    Saved = act(Config, {muse_ui_mail, save_attachment, #{id => Report, part => <<"2">>}}, #{<<"type">> => <<"click">>}),
    ?assert(contains(Saved, <<"已保存到“文件”"/utf8>>)),
    ?assertMatch([_], [F || F = #{<<"name">> := <<"report.pdf">>} <- muse_files:list(?O, unsigned)]).

compose_send_and_reply(Config) ->
    A = synced(),
    V = values(A, <<"inbox">>, <<>>),
    %% 写邮件 opens a fresh draft in the window
    Open = act(Config, {muse_ui_mail, compose, #{}}, click(V)),
    ?assert(contains(Open, <<"mail-compose-form">>)),
    ?assert(contains(Open, <<"/mail-content/">>)),
    [#{<<"id">> := D}] = muse_mail_send:drafts(?O),
    %% an upload into the draft (session and origin required)
    {Type, Multipart} = multipart(<<"notes.txt">>, <<"text/plain">>, <<"hello">>),
    UpPath = "/mail-content/" ++ binary_to_list(D) ++ "/upload",
    {401, _, _} = req(Config, post, UpPath, same_origin(Config), {Type, Multipart}),
    {403, _, _} = req(Config, post, UpPath, cookie(Config) ++ [{"sec-fetch-site", "cross-site"}], {Type, Multipart}),
    {201, _, UpBody} = req(Config, post, UpPath, cookie(Config) ++ same_origin(Config), {Type, Multipart}),
    {ok, #{<<"name">> := <<"notes.txt">>}} = muse_json:decode(UpBody),
    Atts = act(Config, {muse_ui_mail, uploaded, #{id => D}}, #{<<"type">> => <<"change">>}),
    ?assert(contains(Atts, <<"notes.txt">>)),
    %% a file from Files
    {ok, Pdf} = muse_pdf:sample(),
    {ok, #{<<"id">> := FileId}} = muse_files:upload(?O, <<"表单.pdf"/utf8>>, Pdf, #{}),
    Added = act(Config, {muse_ui_mail, add_file, #{id => D}}, #{<<"type">> => <<"change">>, <<"value">> => FileId}),
    ?assert(contains(Added, <<"表单.pdf"/utf8>>)),
    %% send: the user's own, no review
    Form = #{<<"account">> => A, <<"to">> => <<"张三 <zhang@example.com>, li@example.com"/utf8>>, <<"cc">> => <<>>,
             <<"bcc">> => <<"hidden@example.com">>, <<"subject">> => <<"周报"/utf8>>, <<"body">> => <<"本周进展。\r\n第二行"/utf8>>},
    Sent = act(Config, {muse_ui_mail, send, #{id => D}}, submit(Form, V)),
    ?assert(contains(Sent, <<"邮件已发送"/utf8>>)),
    [S1] = muse_mail_fake:sent(fake(Config)),
    ?assertMatch(#{<<"subject">> := <<"周报"/utf8>>, <<"text">> := <<"本周进展。\n第二行"/utf8>>,
                   <<"to">> := [#{<<"name">> := <<"张三"/utf8>>}, #{<<"address">> := <<"li@example.com">>}],
                   <<"bcc">> := [#{<<"address">> := <<"hidden@example.com">>}]}, S1),
    ?assertEqual([<<"表单.pdf"/utf8>>, <<"notes.txt">>], [N || #{<<"filename">> := N} <- maps:get(<<"attachments">>, S1)]),
    ?assertEqual([], [X || X = #{<<"status">> := <<"awaiting_review">>} <- muse_store:list(?O, <<"actions">>)]),
    ?assertEqual([], muse_mail_send:drafts(?O)),
    %% reply: threading headers
    #{<<"id">> := Id} = by_subject(A, <<"季度报告"/utf8>>),
    Reply = act(Config, {muse_ui_mail, reply, #{id => Id}}, click(V)),
    ?assert(contains(Reply, <<"Re: 季度报告"/utf8>>)),
    [#{<<"id">> := R}] = muse_mail_send:drafts(?O),
    _ = act(Config, {muse_ui_mail, send, #{id => R}},
            submit(#{<<"account">> => A, <<"to">> => <<"zhang@example.com">>, <<"cc">> => <<>>, <<"bcc">> => <<>>,
                     <<"subject">> => <<"Re: 季度报告"/utf8>>, <<"body">> => <<"收到"/utf8>>}, V)),
    [_, S2] = muse_mail_fake:sent(fake(Config)),
    ?assertMatch(#{<<"inReplyTo">> := <<"<q1@example.com>">>,
                   <<"references">> := [<<"<root@example.com>">>, <<"<q1@example.com>">>]}, S2),
    %% a bad address keeps the window open with the reason
    _ = act(Config, {muse_ui_mail, compose, #{}}, click(V)),
    [#{<<"id">> := B}] = muse_mail_send:drafts(?O),
    Bad = act(Config, {muse_ui_mail, send, #{id => B}},
              submit(#{<<"account">> => A, <<"to">> => <<"nobody">>, <<"subject">> => <<"x">>, <<"body">> => <<>>}, V)),
    ?assert(contains(Bad, <<"收件人地址无效"/utf8>>)),
    %% the draft is listed in 草稿 and opens again
    Drafts = act(Config, {muse_ui_mail, folder, #{folder => <<"drafts">>}}, click(V)),
    ?assert(contains(Drafts, <<"mail-draft-", B/binary>>)),
    Page = page(Config, "/mail?folder=drafts&draft=" ++ binary_to_list(B)),
    ?assert(has(Page, <<"mail-compose-form">>)),
    ?assert(has(Page, <<"nobody">>)),
    Discard = act(Config, {muse_ui_mail, discard, #{id => B}}, click(V)),
    ?assert(contains(Discard, <<"草稿已删除"/utf8>>)),
    ?assertEqual([], muse_mail_send:drafts(?O)).

chat_tools_and_card(Config) ->
    A = synced(),
    Tools = muse_chat_agent:tools(?O, <<"t1">>, <<"r">>, <<"t1:m1">>, undefined),
    Handler = fun(Name) -> hd([H || #{name := N, handler := H} <- Tools, N =:= Name]) end,
    ?assertEqual([<<"search_mail">>, <<"read_mail">>, <<"draft_mail">>, <<"propose_mail_send">>],
                 [N || #{name := N} <- Tools, binary:match(N, <<"mail">>) =/= nomatch]),
    {ok, #{<<"messages">> := [#{<<"messageId">> := Lunch} | _], <<"note">> := _, <<"recentSends">> := []} = Found} =
        (Handler(<<"search_mail">>))(#{}, undefined),
    {ok, Read} = (Handler(<<"read_mail">>))(#{<<"messageId">> => Lunch, <<"thread">> => true}, undefined),
    ?assertMatch(#{<<"subject">> := <<"Lunch?">>, <<"text">> := <<"Are you free", _/binary>>}, Read),
    %% read steps are one line each
    Step = iolist_to_binary(aihtml_html:render(muse_ui_cards:render(?O, <<"t1">>, <<"c1">>, <<"search_mail">>, #{},
                                                                    muse_json:encode(Found)))),
    ?assert(has(Step, <<"搜索了邮件 · 3 封"/utf8>>)),
    ReadStep = iolist_to_binary(aihtml_html:render(muse_ui_cards:render(?O, <<"t1">>, <<"c2">>, <<"read_mail">>, #{},
                                                                        muse_json:encode(Read)))),
    ?assert(has(ReadStep, <<"读了邮件 · "/utf8>>)),
    ?assert(has(ReadStep, <<"/mail/", Lunch/binary>>)),
    %% a draft: no approval, a link; replaying the turn does not duplicate it
    DraftArgs = #{<<"to">> => [<<"li@example.com">>], <<"subject">> => <<"Re: Lunch?">>, <<"body">> => <<"Sure">>,
                  <<"inReplyTo">> => Lunch},
    {ok, #{<<"draftId">> := D, <<"link">> := Link}} = (Handler(<<"draft_mail">>))(DraftArgs, undefined),
    {ok, #{<<"draftId">> := D}} = (Handler(<<"draft_mail">>))(DraftArgs, undefined),
    ?assertEqual(<<"/mail?folder=drafts&draft=", D/binary>>, Link),
    [#{<<"createdBy">> := <<"agent">>, <<"inReplyToHeader">> := <<"<l4@example.com>">>}] = muse_mail_send:drafts(?O),
    ?assertMatch({ok, #{<<"error">> := <<"收件人地址无效：bogus"/utf8>>}},
                 (Handler(<<"draft_mail">>))(#{<<"to">> => [<<"bogus">>]}, undefined)),
    ?assert(has(page(Config, "/mail?folder=drafts&draft=" ++ binary_to_list(D)), <<"智能体起草"/utf8>>)
            orelse has(page(Config, "/mail?folder=drafts"), <<"智能体起草"/utf8>>)),
    %% a send: awaiting review, nothing sent
    SendArgs = #{<<"to">> => [<<"Li <li@example.com>">>], <<"subject">> => <<"Re: Lunch?">>,
                 <<"body">> => <<"Sure, 12:30.">>, <<"inReplyTo">> => Lunch},
    {ok, #{<<"actionId">> := AId, <<"status">> := <<"awaiting_review">>, <<"note">> := Note} = Result} =
        (Handler(<<"propose_mail_send">>))(SendArgs, undefined),
    ?assert(has(Note, <<"Not sent yet">>)),
    {ok, #{<<"actionId">> := AId}} = (Handler(<<"propose_mail_send">>))(SendArgs, undefined),
    ?assertEqual([], muse_mail_fake:sent(fake(Config))),
    Card = iolist_to_binary(aihtml_html:render(muse_ui_cards:render(?O, <<"t1">>, <<"call-9">>, <<"propose_mail_send">>,
                                                                    SendArgs, muse_json:encode(Result)))),
    [?assert(has(Card, P), P) || P <- [<<"id=\"tc-call-9\"">>, <<"approval-", AId/binary>>, <<"发送邮件：Re: Lunch?"/utf8>>,
                                       <<"发件人"/utf8>>, <<"Me &lt;me@example.com&gt;">>, <<"收件人"/utf8>>,
                                       <<"Sure, 12:30.">>, <<"批准"/utf8>>, <<"拒绝"/utf8>>, <<"data-ah-subscribe">>]],
    %% 审批 lists it and counts it
    Approvals = page(Config, "/approvals"),
    ?assert(has(Approvals, <<"approval-", AId/binary>>)),
    ?assertEqual(match, re:run(Approvals, <<"<span[^>]*muse-approval-count[^>]*>1</span>">>, [{capture, none}])),
    %% approve in the chat card: sent once, the card shows the receipt
    #{<<"hash">> := Hash} = muse_actions:get(?O, AId),
    Approved = act(Config, {muse_ui_activity, decide, #{action => AId, hash => Hash, decision => approve, scope => chat}},
                   #{<<"type">> => <<"click">>}),
    ?assert(contains(Approved, <<"已发送邮件「Re: Lunch?」"/utf8>>)),
    ?assert(contains(Approved, <<"folder=sent">>)),
    _ = act(Config, {muse_ui_activity, decide, #{action => AId, hash => Hash, decision => approve, scope => chat}},
            #{<<"type">> => <<"click">>}),
    [#{<<"inReplyTo">> := <<"<l4@example.com>">>}] = muse_mail_fake:sent(fake(Config)),
    {ok, #{<<"recentSends">> := [#{<<"status">> := <<"succeeded">>, <<"actionId">> := AId}]}} =
        (Handler(<<"search_mail">>))(#{}, undefined),
    %% the prompt's mail part
    System = muse_chat_agent:system_prompt(),
    ?assert(has(System, muse_chat_agent:mail_prompt())),
    ?assert(has(muse_chat_agent:mail_prompt(), <<"untrusted">>)),
    _ = A.

api_routes(Config) ->
    Env = ?config(env, Config),
    T = muse_web_test_env:login(Env),
    Hr = fun(M, P, B) -> muse_web_test_env:http(Env, M, P, T, B) end,
    401 = element(1, muse_web_test_env:http(Env, get, "/api/mail/accounts", undefined)),
    {200, #{<<"accounts">> := []}} = Hr(get, "/api/mail/accounts", undefined),
    {404, _} = Hr(get, "/api/mail/messages", undefined),
    A = synced(),
    {200, Accounts} = Hr(get, "/api/mail/accounts", undefined),
    ?assertNot(has(muse_json:encode(Accounts), muse_mail_fake:password())),
    ?assertNot(has(muse_json:encode(Accounts), <<"secret">>)),
    ?assertMatch(#{<<"accounts">> := [#{<<"id">> := A, <<"hasPassword">> := true,
                                        <<"sync">> := #{<<"status">> := <<"ok">>}}]}, Accounts),
    {200, #{<<"folders">> := Folders}} = Hr(get, "/api/mail/folders", undefined),
    ?assertEqual(6, length(Folders)),
    {200, #{<<"total">> := 3, <<"messages">> := [#{<<"subject">> := <<"Lunch?">>, <<"id">> := Id} | _]}} =
        Hr(get, "/api/mail/messages?account=" ++ binary_to_list(A) ++ "&folder=inbox", undefined),
    {200, #{<<"total">> := 1}} = Hr(get, "/api/mail/messages?q=%E5%BC%A0%E4%B8%89", undefined),
    {200, #{<<"total">> := 2}} = Hr(get, "/api/mail/messages?unread=1", undefined),
    {200, #{<<"text">> := <<"Are you free tomorrow?", _/binary>>}} =
        Hr(get, "/api/mail/messages/" ++ binary_to_list(Id), undefined),
    {404, _} = Hr(get, "/api/mail/messages/nope", undefined),
    {404, _} = Hr(get, "/api/mail/messages?account=nope", undefined),
    %% sending is the user's own action: direct, once per key
    Send = #{<<"to">> => [<<"li@example.com">>], <<"subject">> => <<"API">>, <<"body">> => <<"Hi">>,
             <<"inReplyTo">> => Id, <<"idempotencyKey">> => <<"k-1">>},
    {201, #{<<"status">> := <<"sent">>, <<"messageId">> := MsgId}} = Hr(post, "/api/mail/send", Send),
    {201, #{<<"messageId">> := MsgId}} = Hr(post, "/api/mail/send", Send),
    [#{<<"subject">> := <<"API">>, <<"inReplyTo">> := <<"<l4@example.com>">>}] = muse_mail_fake:sent(fake(Config)),
    {422, _} = Hr(post, "/api/mail/send", #{<<"to">> => [], <<"subject">> => <<"x">>, <<"body">> => <<>>}),
    {422, _} = Hr(post, "/api/mail/send", #{<<"to">> => [<<"bad address">>], <<"subject">> => <<"x">>, <<"body">> => <<>>}).
