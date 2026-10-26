%% @doc `/api/mail/*': the built-in mail (muse_mail, tasks/M9-workspace.md
%% M9-8) over JSON, Bearer auth like every other route. Not in OpenMuse
%% (whose Gmail routes are gone, docs/DIFFERENCES.md).
%%
%%   GET  /api/mail/accounts                          accounts (never a password) and their sync state
%%   GET  /api/mail/folders?account=                  an account's folders
%%   GET  /api/mail/messages?account=&folder=&q=&unread=&limit=&offset=
%%                                                    a page of messages, newest first
%%   GET  /api/mail/messages/<id>                     one message with its text and HTML
%%   POST /api/mail/send                              send now (the user's own action: no review)
%%
%% `send' takes `{accountId?, to, cc?, bcc?, subject, body, inReplyTo?,
%% attachments?: [Files ids], idempotencyKey?}'; the same key never sends
%% twice (it names the send receipt). Answers 201 with the receipt, 409 when
%% that key already failed, 502 when the server refused, and a generic 502
%% when the outcome is unknown.
-module(muse_api_mail).

-export([handle/3]).

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(<<"GET">>, [<<"api">>, <<"mail">>, <<"accounts">>], Req) ->
    O = muse_http:owner(Req),
    {{200, #{<<"accounts">> => [(muse_mail_accounts:public(A))#{<<"sync">> => muse_mail:sync_state(O, Id)}
                                || A = #{<<"id">> := Id} <- muse_mail_accounts:list(O)]}}, Req};
handle(<<"GET">>, [<<"api">>, <<"mail">>, <<"folders">>], Req) ->
    O = muse_http:owner(Req),
    {case account(O, muse_http:query(<<"account">>, Req)) of
         {ok, A} -> {200, #{<<"folders">> => [folder(F) || F <- muse_mail:folders(O, A)]}};
         E -> E
     end, Req};
handle(<<"GET">>, [<<"api">>, <<"mail">>, <<"messages">>], Req) ->
    O = muse_http:owner(Req),
    Q = fun(K, D) -> case muse_http:query(K, Req) of undefined -> D; V -> V end end,
    Int = fun(K, D, Max) -> case string:to_integer(Q(K, <<>>)) of
                                {N, <<>>} when N >= 0 -> min(N, Max);
                                _ -> D
                            end end,
    {case account(O, muse_http:query(<<"account">>, Req)) of
         {ok, A} ->
             Folder = Q(<<"folder">>, <<"inbox">>),
             {Total, Msgs} = muse_mail:list(O, #{account => A, folder => Folder, q => Q(<<"q">>, <<>>),
                                                 unread => lists:member(Q(<<"unread">>, <<>>), [<<"1">>, <<"true">>]),
                                                 limit => max(1, Int(<<"limit">>, 50, 200)),
                                                 offset => Int(<<"offset">>, 0, 100000)}),
             {200, #{<<"account">> => A, <<"folder">> => Folder, <<"total">> => Total,
                     <<"messages">> => [message(M) || M <- Msgs]}};
         E -> E
     end, Req};
handle(<<"GET">>, [<<"api">>, <<"mail">>, <<"messages">>, Id], Req) ->
    O = muse_http:owner(Req),
    {case muse_mail:get_message(O, Id) of
         {ok, M} ->
             #{text := Text, html := Html} = muse_mail:body(O, M),
             {200, (message(M))#{<<"text">> => Text, <<"html">> => Html,
                                 <<"references">> => maps:get(<<"references">>, M, []),
                                 <<"inReplyTo">> => maps:get(<<"inReplyTo">>, M, null),
                                 <<"replyTo">> => maps:get(<<"replyTo">>, M, [])}};
         E -> E
     end, Req};
handle(<<"POST">>, [<<"api">>, <<"mail">>, <<"send">>], Req0) ->
    case muse_http:body(Req0, send_schema()) of
        {ok, In, Req} -> {send(muse_http:owner(Req), In), Req};
        {error, E, Req} -> {{error, E}, Req}
    end;
handle(_, _, _) ->
    next.

account(O, undefined) ->
    case muse_mail_accounts:first(O) of
        {ok, #{<<"id">> := A}} -> {ok, A};
        E -> E
    end;
account(O, A) ->
    case muse_mail_accounts:get(O, A) of
        {ok, _} -> {ok, A};
        E -> E
    end.

folder(F) ->
    maps:with([<<"id">>, <<"path">>, <<"name">>, <<"role">>, <<"total">>, <<"unread">>, <<"noselect">>,
               <<"syncedAt">>], F).

message(M) ->
    maps:with([<<"id">>, <<"accountId">>, <<"folderId">>, <<"messageId">>, <<"subject">>, <<"from">>, <<"to">>,
               <<"cc">>, <<"date">>, <<"snippet">>, <<"seen">>, <<"flagged">>, <<"answered">>, <<"attachments">>,
               <<"hasAttachments">>, <<"size">>, <<"truncated">>], M).

send_schema() ->
    Rcpts = fun(Min) -> {array, {string, #{trim => true, min => 3, max => 320}}, #{min => Min, max => 100}} end,
    {object, [{<<"accountId">>, {optional, {string, #{min => 1, max => 100}}}},
              {<<"to">>, Rcpts(1)},
              {<<"cc">>, {optional, Rcpts(0)}},
              {<<"bcc">>, {optional, Rcpts(0)}},
              {<<"subject">>, {string, #{trim => true, max => 500, single_line => true}}},
              {<<"body">>, {string, #{max => 200000}}},
              {<<"inReplyTo">>, {optional, {string, #{min => 1, max => 200}}}},
              {<<"attachments">>, {optional, {array, {string, #{min => 1, max => 100}}, #{max => 20}}}},
              {<<"idempotencyKey">>, {optional, {string, #{min => 1, max => 200}}}}]}.

send(O, In) ->
    Draft = (maps:with([<<"accountId">>, <<"to">>, <<"cc">>, <<"bcc">>, <<"subject">>, <<"body">>], In))#{
              <<"fileIds">> => maps:get(<<"attachments">>, In, [])},
    Key = <<"api:", (maps:get(<<"idempotencyKey">>, In, muse_ids:uuid()))/binary>>,
    maybe
        {ok, Reply} ?= case maps:get(<<"inReplyTo">>, In, undefined) of
                           undefined -> {ok, #{}};
                           MsgId ->
                               case muse_mail:get_message(O, MsgId) of
                                   {ok, M} ->
                                       Refs = maps:get(<<"references">>, M, []),
                                       H = maps:get(<<"messageId">>, M, null),
                                       {ok, #{<<"inReplyTo">> => MsgId, <<"inReplyToHeader">> => H,
                                              <<"references">> => Refs ++ [H || is_binary(H)]}};
                                   E -> E
                               end
                       end,
        {ok, Msg} ?= muse_mail_send:build_message(O, maps:merge(Draft, Reply)),
        {ok, Receipt} ?= muse_mail_send:send(O, Msg, Key, <<"api">>),
        {201, Receipt}
    end.
