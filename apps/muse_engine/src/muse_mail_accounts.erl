%% @doc Mailbox accounts of the built-in mail (邮件, tasks/M9-workspace.md
%% M9-8): the user's existing mailboxes, reached over IMAP and SMTP.
%%
%% Records (per owner, muse_store kind `mail-accounts'): `{id, name, email,
%% username, imapHost, imapPort, imapSecurity, smtpHost, smtpPort,
%% smtpSecurity, allowSelfSigned, saveSent, preset, secret, order, createdAt,
%% updatedAt}'. `security' is `tls' (implicit TLS, 993/465) or `starttls'
%% (required upgrade, 143/587); there is no cleartext option. Certificates
%% are verified unless `allowSelfSigned' (允许自签名证书) is set.
%%
%% The password (授权码 / app password) is encrypted with muse_vault under
%% TOKEN_ENCRYPTION_KEY (AES-256-GCM) and stored as `secret'; without that
%% key no account can be saved. `public/1' is the only shape that leaves
%% this module (pages, API, agent): it has no `secret', only
%% `hasPassword'. The clear password exists only in `sidecar_account/2',
%% the request frame to the mail sidecar. Editing without a password keeps
%% the stored one.
%%
%% Presets fill in the servers of QQ, 163, 126, Gmail, Outlook/Office 365
%% and iCloud. `saveSent' says whether a sent message is appended to the
%% Sent folder over IMAP: Gmail and Outlook file SMTP mail there
%% themselves, so their presets turn it off.
%%
%% Saving checks both servers first (`test/3', 测试连接) unless the caller
%% skips it. A saved account starts its sync process (muse_mail_sync);
%% deleting one stops it and removes its folders, messages, drafts and
%% sync state. Changes emit `{mail, AccountId}'.
-module(muse_mail_accounts).

-export([presets/0, preset/1, list/1, get/2, first/1, public/1, input_schema/1,
         create/3, update/4, delete/2, test/3, sidecar_account/2, ready/0, describe_error/2]).

-define(KIND, <<"mail-accounts">>).
-define(NOT_FOUND, {error, {404, <<"找不到这个邮箱账号"/utf8>>}}).
-define(NO_KEY, {error, {503, <<"服务器没有设置 TOKEN_ENCRYPTION_KEY，不能保存邮箱密码。请管理员设置后重启。"/utf8>>}}).

-type owner() :: binary().
-type account() :: #{binary() => term()}.
-type error() :: {error, {pos_integer(), binary()}}.
-export_type([account/0]).

%%%===================================================================
%%% Presets
%%%===================================================================

%% @doc The presets in display order: `{Id, Label, Fields}'.
-spec presets() -> [{binary(), binary(), map()}].
presets() ->
    [{<<"qq">>, <<"QQ 邮箱"/utf8>>, servers(<<"imap.qq.com">>, 993, tls, <<"smtp.qq.com">>, 465, tls, true)},
     {<<"163">>, <<"网易 163 邮箱"/utf8>>, servers(<<"imap.163.com">>, 993, tls, <<"smtp.163.com">>, 465, tls, true)},
     {<<"126">>, <<"网易 126 邮箱"/utf8>>, servers(<<"imap.126.com">>, 993, tls, <<"smtp.126.com">>, 465, tls, true)},
     {<<"gmail">>, <<"Gmail">>, servers(<<"imap.gmail.com">>, 993, tls, <<"smtp.gmail.com">>, 465, tls, false)},
     {<<"outlook">>, <<"Outlook / Office 365">>,
      servers(<<"outlook.office365.com">>, 993, tls, <<"smtp.office365.com">>, 587, starttls, false)},
     {<<"icloud">>, <<"iCloud 邮件"/utf8>>,
      servers(<<"imap.mail.me.com">>, 993, tls, <<"smtp.mail.me.com">>, 587, starttls, true)},
     {<<"custom">>, <<"其他邮箱"/utf8>>, #{}}].

servers(IH, IP, IS, SH, SP, SS, SaveSent) ->
    #{<<"imapHost">> => IH, <<"imapPort">> => IP, <<"imapSecurity">> => atom_to_binary(IS),
      <<"smtpHost">> => SH, <<"smtpPort">> => SP, <<"smtpSecurity">> => atom_to_binary(SS),
      <<"saveSent">> => SaveSent}.

-spec preset(binary()) -> map().
preset(Id) ->
    case lists:keyfind(Id, 1, presets()) of
        {_, _, Fields} -> Fields;
        false -> #{}
    end.

%%%===================================================================
%%% Reading
%%%===================================================================

%% @doc The owner's accounts in order (stored records, with `secret').
-spec list(owner()) -> [account()].
list(Owner) ->
    lists:sort(fun(A, B) -> sort_key(A) =< sort_key(B) end, muse_store:list(Owner, ?KIND)).

sort_key(A) ->
    {maps:get(<<"order">>, A, 0), maps:get(<<"createdAt">>, A, <<>>), maps:get(<<"id">>, A)}.

-spec get(owner(), term()) -> {ok, account()} | error().
get(Owner, Id) when is_binary(Id) ->
    case muse_store:get(Owner, ?KIND, Id) of
        undefined -> ?NOT_FOUND;
        A -> {ok, A}
    end;
get(_Owner, _) ->
    ?NOT_FOUND.

%% @doc The first account (the default sender), if any.
-spec first(owner()) -> {ok, account()} | error().
first(Owner) ->
    case list(Owner) of
        [A | _] -> {ok, A};
        [] -> {error, {404, <<"还没有邮箱账号。请先在“邮件 → 邮箱账号”里添加一个。"/utf8>>}}
    end.

%% @doc An account without its secret: what pages, the API and the agent see.
-spec public(account()) -> account().
public(A) ->
    (maps:without([<<"secret">>], A))#{<<"hasPassword">> => is_binary(maps:get(<<"secret">>, A, undefined))}.

%% @doc Whether passwords can be stored (TOKEN_ENCRYPTION_KEY is set).
-spec ready() -> boolean().
ready() ->
    case muse_vault:check_key(muse_config:get(encryption_key, undefined)) of
        {ok, _} -> true;
        _ -> false
    end.

%%%===================================================================
%%% Writing
%%%===================================================================

%% @doc The form schema: `new' needs the password, `edit' keeps the stored
%% one when it is blank.
-spec input_schema(new | edit) -> muse_validate:schema().
input_schema(Mode) ->
    Host = fun(Label) ->
                   {string, #{trim => true, min => 1, max => 253,
                              regex => <<"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$">>,
                              message => <<Label/binary, "服务器要写成主机名，比如 imap.example.com"/utf8>>}}
           end,
    Port = fun(Label) -> {integer, #{min => 1, max => 65535, message => <<Label/binary, "端口要在 1–65535 之间"/utf8>>}} end,
    Security = {enum, [<<"tls">>, <<"starttls">>]},
    Password = {string, #{min => 1, max => 512, message => <<"请填写密码或授权码"/utf8>>}},
    {object, [{<<"name">>, {string, #{trim => true, min => 1, max => 80, single_line => true,
                                       message => <<"显示名称需要 1–80 个字"/utf8>>}}},
              {<<"email">>, {string, #{trim => true, email => true, max => 254,
                                        message => <<"请填写有效的邮箱地址"/utf8>>}}},
              {<<"username">>, {optional, {string, #{trim => true, max => 254}}}},
              {<<"password">>, case Mode of
                                   new -> Password;
                                   edit -> {optional, {string, #{max => 512}}}
                               end},
              {<<"imapHost">>, Host(<<"IMAP ">>)},
              {<<"imapPort">>, Port(<<"IMAP ">>)},
              {<<"imapSecurity">>, Security},
              {<<"smtpHost">>, Host(<<"SMTP ">>)},
              {<<"smtpPort">>, Port(<<"SMTP ">>)},
              {<<"smtpSecurity">>, Security},
              {<<"allowSelfSigned">>, {default, boolean, false}},
              {<<"saveSent">>, {default, boolean, true}},
              {<<"preset">>, {optional, {enum, [P || {P, _, _} <- presets()]}}}]}.

%% @doc Add an account. `Opts': `verify' (default true) checks IMAP and
%% SMTP first.
-spec create(owner(), term(), #{verify => boolean()}) -> {ok, account()} | error().
create(Owner, Raw, Opts) ->
    maybe
        true ?= ready() orelse ?NO_KEY,
        {ok, In} ?= muse_validate:parse(input_schema(new), Raw),
        Fields = fields(In),
        Password = maps:get(<<"password">>, In),
        ok ?= verify_if(Opts, Fields#{<<"id">> => <<"new">>}, Password),
        ok ?= unique(Owner, maps:get(<<"email">>, Fields), undefined),
        Now = muse_time:now_iso(),
        Order = lists:max([0 | [maps:get(<<"order">>, A, 0) || A <- list(Owner)]]) + 1,
        Account = Fields#{<<"id">> => muse_ids:uuid(), <<"secret">> => encrypt(Password),
                          <<"order">> => Order, <<"createdAt">> => Now, <<"updatedAt">> => Now},
        _ = muse_store:put(Owner, ?KIND, Account),
        changed(Owner, maps:get(<<"id">>, Account)),
        {ok, Account}
    end.

%% @doc Change an account; a blank password keeps the stored one.
-spec update(owner(), binary(), term(), #{verify => boolean()}) -> {ok, account()} | error().
update(Owner, Id, Raw, Opts) ->
    maybe
        true ?= ready() orelse ?NO_KEY,
        {ok, Old} ?= get(Owner, Id),
        {ok, In} ?= muse_validate:parse(input_schema(edit), Raw),
        Fields = fields(In),
        {ok, Password} ?= case maps:get(<<"password">>, In, <<>>) of
                              <<>> -> decrypt(Old);
                              P -> {ok, P}
                          end,
        ok ?= verify_if(Opts, Fields#{<<"id">> => Id}, Password),
        ok ?= unique(Owner, maps:get(<<"email">>, Fields), Id),
        New = maps:merge(Old, Fields#{<<"secret">> => encrypt(Password), <<"updatedAt">> => muse_time:now_iso()}),
        _ = muse_store:put(Owner, ?KIND, New),
        _ = muse_mail_client:request(<<"close">>, #{<<"accountId">> => Id}, 5000),
        changed(Owner, Id),
        {ok, New}
    end.

%% @doc Remove an account and everything synced from it.
-spec delete(owner(), binary()) -> ok | error().
delete(Owner, Id) ->
    maybe
        {ok, _} ?= get(Owner, Id),
        ok = muse_mail_sync:stop(Owner, Id),
        _ = muse_mail_client:request(<<"close">>, #{<<"accountId">> => Id}, 5000),
        ok = muse_mail:forget_account(Owner, Id),
        ok = muse_store:remove(Owner, ?KIND, Id),
        muse_events:emit(Owner, {mail, Id}),
        ok
    end.

%% @doc 测试连接: log in to both servers with the form's values (`Id' is
%% `new' or the account being edited, whose password a blank one reuses).
-spec test(owner(), binary(), term()) -> ok | error().
test(Owner, Id, Raw) ->
    Mode = case Id of <<"new">> -> new; _ -> edit end,
    maybe
        {ok, In} ?= muse_validate:parse(input_schema(Mode), Raw),
        {ok, Password} ?= case {maps:get(<<"password">>, In, <<>>), Mode} of
                              {<<>>, edit} ->
                                  maybe
                                      {ok, Old} ?= get(Owner, Id),
                                      decrypt(Old)
                                  end;
                              {P, _} -> {ok, P}
                          end,
        verify((fields(In))#{<<"id">> => Id}, Password)
    end.

verify_if(#{verify := false}, _Fields, _Password) -> ok;
verify_if(_Opts, Fields, Password) -> verify(Fields, Password).

verify(Fields, Password) ->
    case muse_mail_client:request(<<"verify">>, #{<<"account">> => wire(Fields, Password)}, 60000) of
        {ok, #{<<"imap">> := I, <<"smtp">> := S}} ->
            case [describe_error(P, E) || {P, #{<<"error">> := E}} <- [{<<"IMAP">>, I}, {<<"SMTP">>, S}]] of
                [] -> ok;
                Errors -> {error, {422, iolist_to_binary(lists:join(<<"；"/utf8>>, Errors))}}
            end;
        {error, E} ->
            {error, {502, describe_error(<<"IMAP/SMTP">>, E)}}
    end.

%% @doc A sidecar error in Chinese, with the server's own words after it.
-spec describe_error(binary(), map()) -> binary().
describe_error(Proto, E) ->
    Code = field(code, <<"code">>, E),
    Detail = field(message, <<"message">>, E),
    What = case Code of
               <<"auth">> -> <<"登录失败，用户名或密码（授权码）不对"/utf8>>;
               <<"tls">> -> <<"安全连接失败（证书无效或服务器不支持所选的加密方式）"/utf8>>;
               <<"timeout">> -> <<"服务器没有及时响应"/utf8>>;
               <<"connect">> -> <<"连不上服务器，请检查主机名和端口"/utf8>>;
               <<"unavailable">> -> <<"邮件组件没有运行"/utf8>>;
               <<"toolarge">> -> <<"内容太大"/utf8>>;
               <<"notfound">> -> <<"找不到这封邮件或附件"/utf8>>;
               <<"uidvalidity">> -> <<"文件夹在服务器上被重建，需要重新同步"/utf8>>;
               _ -> <<"出错了"/utf8>>
           end,
    Tail = case Detail of
               <<>> -> <<>>;
               _ -> <<"（"/utf8, (muse_js:slice(Detail, 200))/binary, "）"/utf8>>
           end,
    <<Proto/binary, "："/utf8, What/binary, Tail/binary>>.

field(A, B, E) ->
    case maps:get(A, E, maps:get(B, E, <<>>)) of
        V when is_binary(V) -> V;
        _ -> <<>>
    end.

%% @doc The account as the mail sidecar takes it, with the clear password.
-spec sidecar_account(owner(), account() | binary()) -> {ok, map()} | error().
sidecar_account(Owner, Id) when is_binary(Id) ->
    maybe
        {ok, A} ?= get(Owner, Id),
        sidecar_account(Owner, A)
    end;
sidecar_account(_Owner, Account) ->
    maybe
        {ok, Password} ?= decrypt(Account),
        {ok, wire(Account, Password)}
    end.

wire(A, Password) ->
    User = case maps:get(<<"username">>, A, <<>>) of
               <<>> -> maps:get(<<"email">>, A);
               U -> U
           end,
    Self = maps:get(<<"allowSelfSigned">>, A, false) =:= true,
    Side = fun(P) ->
                   #{<<"host">> => maps:get(<<P/binary, "Host">>, A), <<"port">> => maps:get(<<P/binary, "Port">>, A),
                     <<"security">> => maps:get(<<P/binary, "Security">>, A), <<"user">> => User,
                     <<"pass">> => Password, <<"allowSelfSigned">> => Self}
           end,
    #{<<"id">> => maps:get(<<"id">>, A), <<"imap">> => Side(<<"imap">>), <<"smtp">> => Side(<<"smtp">>)}.

fields(In) ->
    Email = string:lowercase(maps:get(<<"email">>, In)),
    Username = case maps:get(<<"username">>, In, <<>>) of
                   <<>> -> Email;
                   U -> U
               end,
    (maps:with([<<"name">>, <<"imapHost">>, <<"imapPort">>, <<"imapSecurity">>, <<"smtpHost">>, <<"smtpPort">>,
                <<"smtpSecurity">>, <<"allowSelfSigned">>, <<"saveSent">>, <<"preset">>], In))
        #{<<"email">> => Email, <<"username">> => Username,
          <<"imapHost">> => string:lowercase(maps:get(<<"imapHost">>, In)),
          <<"smtpHost">> => string:lowercase(maps:get(<<"smtpHost">>, In))}.

unique(Owner, Email, Self) ->
    case [Id || #{<<"id">> := Id, <<"email">> := E} <- list(Owner), E =:= Email, Id =/= Self] of
        [] -> ok;
        _ -> {error, {409, <<"这个邮箱已经添加过了"/utf8>>}}
    end.

encrypt(Password) ->
    muse_vault:encrypt(muse_config:get(encryption_key), Password).

decrypt(#{<<"secret">> := Secret}) when is_binary(Secret) ->
    case muse_vault:decrypt(muse_config:get(encryption_key, undefined), Secret) of
        {ok, P} -> {ok, P};
        {error, _} -> {error, {409, <<"保存的邮箱密码无法解密（TOKEN_ENCRYPTION_KEY 变了？），请重新填写密码。"/utf8>>}}
    end;
decrypt(_) ->
    {error, {409, <<"这个账号没有保存密码，请重新填写。"/utf8>>}}.

changed(Owner, Id) ->
    muse_events:emit(Owner, {mail, Id}),
    muse_mail_sync:ensure(Owner, Id).
