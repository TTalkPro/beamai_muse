%% @doc The `mail.send` action kind (muse_action_kind): every message the
%% agent sends from the built-in mail goes through a separate user review.
%% The user's own sends (the `/mail` page, the JSON API) are direct.
%%
%% `data` is `{accountId?, to, cc?, bcc?, subject, body, inReplyTo?,
%% attachments?}`: recipients as `Name <a@b>` or `a@b`, `inReplyTo` the
%% messageId (from search_mail) of the message answered, `attachments` ids
%% of files in Files. `prepare/2` (muse_mail_send:prepare/2) checks them
%% against the owner (the account and the files must be the owner's, the
%% addresses valid, the size within FILES_MAX_MB) and fills in what the
%% card shows and the send needs: `from`, the normalised recipients,
%% `attachmentNames`, `inReplyToHeader`, `references`, `replySubject`, and
%% `sendId`, a fresh id that keys the send receipt. All of it is in the
%% review hash.
%%
%% `display/1`: "发送邮件：主题" with 发件人, 收件人, 抄送, 密送, 主题, 回复,
%% 正文 (the first 600 characters) and 附件.
%%
%% `execute/3` sends once (muse_mail_send:send_reviewed/2): the receipt
%% `action:<sendId>` is written before the SMTP conversation and after it,
%% so a second execution (a retry, a double approval that got past the
%% claim) never sends again, and a crash in between reads as
%% `outcome_unknown`, as does a connection lost while the message was on
%% its way. muse_actions turns an `executing` action left by a restart into
%% `outcome_unknown` as well.
%%
%% `tool/0`: the task model's `prepare_mail_send`; the chat's
%% `propose_mail_send` is muse_chat_agent's. Registered by muse_engine_app.
-module(muse_mail_action).
-behaviour(muse_action_kind).

-export([register/0, unregister/0, kind/0, schema/0, input_schema/0, description/0, display/1, prepare/2,
         execute/3, tool/0]).

-define(KIND, <<"mail.send">>).
-define(SERVER, <<"Filled in by the server; leave out">>).

-spec kind() -> binary().
kind() -> ?KIND.

-spec register() -> ok.
register() ->
    muse_actions:register_kind(?KIND, ?MODULE).

-spec unregister() -> ok.
unregister() ->
    muse_actions:unregister_kind(?KIND).

%% @doc What a caller proposes (the chat tool's parameters).
-spec input_schema() -> muse_validate:schema().
input_schema() ->
    {object, input_fields()}.

input_fields() ->
    Rcpts = fun(D, Min) -> {desc, D, {array, {string, #{trim => true, min => 3, max => 320}}, #{min => Min, max => 50}}} end,
    [{<<"accountId">>, {optional, {desc, <<"Sending account id (default: the first account)">>,
                                   {string, #{min => 1, max => 100}}}}},
     {<<"to">>, Rcpts(<<"Recipients: a@b.com or Name <a@b.com>">>, 1)},
     {<<"cc">>, {optional, Rcpts(<<"Cc recipients">>, 0)}},
     {<<"bcc">>, {optional, Rcpts(<<"Bcc recipients">>, 0)}},
     {<<"subject">>, {string, #{trim => true, min => 1, max => 500, single_line => true}}},
     {<<"body">>, {desc, <<"Plain-text body">>, {string, #{min => 1, max => 100000}}}},
     {<<"inReplyTo">>, {optional, {desc, <<"messageId (from search_mail) of the message this replies to; sets the "
                                           "threading headers">>, {string, #{min => 1, max => 200}}}}},
     {<<"attachments">>, {optional, {desc, <<"Ids of files in Files to attach">>,
                                     {array, {string, #{min => 1, max => 100}}, #{max => 10}}}}}].

%% @doc The stored data: the input plus what `prepare/2' adds for review.
-spec schema() -> muse_validate:schema().
schema() ->
    Server = fun(S) -> {optional, {desc, ?SERVER, S}} end,
    {object, input_fields()
     ++ [{<<"from">>, Server({string, #{max => 400}})},
         {<<"attachmentNames">>, Server({array, {string, #{}}, #{max => 10}})},
         {<<"inReplyToHeader">>, Server({string, #{max => 1000}})},
         {<<"references">>, Server({array, {string, #{}}, #{max => 31}})},
         {<<"replySubject">>, Server({string, #{max => 1000}})},
         {<<"sendId">>, Server({string, #{max => 100}})}]}.

-spec description() -> binary().
description() ->
    <<"Propose sending an email from the person's own mailbox (邮件). Nothing is sent until the person approves it "
      "in a separate review that shows the exact message. Plain text only. For a reply pass inReplyTo (the "
      "messageId from search_mail) and reply to its sender; attachments are file ids from Files."/utf8>>.

-spec tool() -> muse_action_kind:tool().
tool() ->
    #{name => <<"prepare_mail_send">>,
      description => <<"Prepare an email for a separate user review before it is sent">>}.

-spec prepare(binary(), map()) -> {ok, #{data := map(), target => map()}} | {error, {pos_integer(), binary()}}.
prepare(Owner, Data) ->
    case muse_mail_send:prepare(Owner, Data) of
        {ok, Prepared} ->
            {ok, #{data => Prepared,
                   target => #{<<"accountId">> => maps:get(<<"accountId">>, Prepared),
                               <<"from">> => maps:get(<<"from">>, Prepared)}}};
        {error, {outcome_unknown, Msg}} -> {error, {502, Msg}};
        {error, _} = E -> E
    end.

-spec display(map()) -> muse_action_kind:display().
display(Data) ->
    Subject = maps:get(<<"subject">>, Data, <<>>),
    Join = fun(K) -> iolist_to_binary(lists:join(<<", ">>, maps:get(K, Data, []))) end,
    Body = maps:get(<<"body">>, Data, <<>>),
    Shown = case muse_validate:utf16_length(Body) > 600 of
                true -> <<(muse_js:slice(Body, 600))/binary, "…"/utf8>>;
                false -> Body
            end,
    #{title => <<"发送邮件："/utf8, Subject/binary>>,
      fields => [{<<"发件人"/utf8>>, maps:get(<<"from">>, Data, <<>>)},
                 {<<"收件人"/utf8>>, Join(<<"to">>)},
                 {<<"抄送"/utf8>>, Join(<<"cc">>)},
                 {<<"密送"/utf8>>, Join(<<"bcc">>)},
                 {<<"主题"/utf8>>, Subject},
                 {<<"回复"/utf8>>, maps:get(<<"replySubject">>, Data, <<>>)},
                 {<<"正文"/utf8>>, Shown},
                 {<<"附件"/utf8>>, iolist_to_binary(lists:join(<<"、"/utf8>>, maps:get(<<"attachmentNames">>, Data, [])))}]}.

-spec execute(binary(), map(), muse_action_kind:review()) ->
          {ok, binary()} | {error, {pos_integer() | outcome_unknown | internal, binary()}}.
execute(Owner, Data, _Review) ->
    case muse_mail_send:send_reviewed(Owner, Data) of
        {ok, Receipt} ->
            To = iolist_to_binary(lists:join(<<", ">>, maps:get(<<"to">>, Data, []))),
            Note = case maps:get(<<"appendError">>, Receipt, null) of
                       E when is_binary(E) -> <<"（没能存进“已发送”："/utf8, E/binary, "）"/utf8>>;
                       _ -> <<>>
                   end,
            {ok, <<"已发送邮件「"/utf8, (maps:get(<<"subject">>, Data, <<>>))/binary, "」给 "/utf8, To/binary,
                   Note/binary>>};
        {error, _} = E ->
            E
    end.
