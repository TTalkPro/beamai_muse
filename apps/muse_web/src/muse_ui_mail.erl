%% @doc The mail page `/mail' (邮件, tasks/M9-workspace.md M9-8), after the
%% aihtml example port of sigil's mail app (aihtml_example_mail_app): three
%% columns in the app's shell and house style.
%%
%% - Left, the mailbox: the account switcher (several accounts), its sync
%%   state (syncing, last sync, the last error, live IDLE) and the folders
%%   收件箱, 已加星标, 草稿, 已发送, 归档, 垃圾箱 (垃圾邮件 when the
%%   account has one) and the account's other IMAP folders, with unread
%%   counts.
%% - Middle, the list: search (server side, debounced), rows with star,
%%   sender (recipients in 已发送), time, subject, snippet, attachment mark,
%%   unread in bold; 加载更多 pages by 50. 草稿 lists the local drafts.
%% - Right, the reading pane: subject, 发件人/收件人/抄送/时间, 回复, 全部回复,
%%   转发, 归档, 删除, 星标, 标为未读; the text part as plain text; HTML-only
%%   mail (or 显示网页版式) in a sandboxed iframe from `/mail-content/<id>/body'
%%   (muse_ui_mail_content: its own CSP, no scripts, no same origin, remote
%%   images blocked until 显示图片); attachments with 下载 and 保存到文件.
%% - The compose window (写邮件, replies, forwards, drafts): 发件人, 收件人,
%%   抄送, 密送, 主题, 正文 and attachments, from Files (a picker) or
%%   uploaded (`ah_upload' to `/mail-content/<draft>/upload'); 保存草稿,
%%   发送 (the user's own send: no review), 删除草稿. Every compose is a
%%   local draft from the start, so nothing typed is lost.
%%
%% Addresses: `/mail?account=&folder=' (folder: a role or a folder id),
%% `/mail/<messageId>', `/mail?folder=drafts&draft=<id>' opens a draft (the
%% agent's draft_mail links there), `/mail/accounts' manages the accounts
%% (邮箱账号: presets, 测试连接, edit keeping the password, delete).
%% Folder switches and opening a message are actions that morph the panes
%% and push the address.
%%
%% The tab's state (account, folder, message, page size, search) lives in
%% hidden inputs every action includes. Changes (sync passes, other tabs,
%% the agent's approved sends) arrive as muse_events `{mail, AccountId}';
%% `on_event/2' triggers `mail-changed' on each open page's sync element,
%% which refreshes the rail and the list with that tab's own state.
-module(muse_ui_mail).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4]).

-define(K, muse_ui_a_kit).
-define(C, muse_ui_b_common).
-define(I, muse_ui_icons).
-define(RAIL, <<"mail-rail">>).
-define(LIST, <<"mail-list">>).
-define(READER, <<"mail-reader">>).
-define(STATE, <<"mail-state">>).
-define(SYNC, <<"mail-sync">>).
-define(WIN, <<"mail-compose-win">>).
-define(COMPOSE, <<"mail-compose">>).
-define(ATTS, <<"mail-compose-atts">>).
-define(ACC_LIST, <<"mail-acc-list">>).
-define(ACC_FORM, <<"mail-acc-form">>).
-define(CHANGED, <<"mail-changed">>).
-define(PAGE, 50).
-define(ROLES, [<<"inbox">>, <<"starred">>, <<"drafts">>, <<"sent">>, <<"archive">>, <<"junk">>, <<"trash">>]).

-type state() :: #{account := binary(), folder := binary(), msg := binary(), q := binary(), limit := pos_integer()}.

%%%===================================================================
%%% Page
%%%===================================================================

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    Qs = cowboy_req:parse_qs(Req),
    Q = fun(K) -> case proplists:get_value(K, Qs) of V when is_binary(V) -> V; _ -> <<>> end end,
    case cowboy_req:path_info(Req) of
        [<<"accounts">> | _] ->
            {<<"邮箱账号"/utf8>>, accounts_page(Owner, Q(<<"edit">>))};
        [MsgId | _] when MsgId =/= <<>> ->
            case muse_mail:get_message(Owner, MsgId) of
                {ok, #{<<"accountId">> := A, <<"folderId">> := F, <<"subject">> := S}} ->
                    {subject(S), page(Owner, #{account => A, folder => F, msg => MsgId, q => <<>>, limit => ?PAGE},
                                     undefined)};
                {error, _} ->
                    {<<"邮件"/utf8>>, page(Owner, initial(Owner, Q(<<"account">>), <<"inbox">>), missing)}
            end;
        _ ->
            St = initial(Owner, Q(<<"account">>), case Q(<<"folder">>) of <<>> -> <<"inbox">>; F -> F end),
            Draft = case Q(<<"draft">>) of <<>> -> undefined; D -> D end,
            {<<"邮件"/utf8>>, page(Owner, St#{q => Q(<<"q">>)}, Draft)}
    end.

initial(Owner, Account, Folder) ->
    Accounts = muse_mail_accounts:list(Owner),
    A = case [I || #{<<"id">> := I} <- Accounts, I =:= Account] of
            [I | _] -> I;
            [] -> case Accounts of [#{<<"id">> := I} | _] -> I; [] -> <<>> end
        end,
    #{account => A, folder => Folder, msg => <<>>, q => <<>>, limit => ?PAGE}.

page(Owner, St, Extra) ->
    Accounts = muse_mail_accounts:list(Owner),
    Body = case Accounts of
               [] -> empty_page();
               _ ->
                   [ah_div([rail_el(Owner, St),
                            ah_section([search_bar(St), list_el(Owner, St)], [<<"muse-mail-col">>], []),
                            ah_section(case Extra of
                                           missing -> missing_reader();
                                           _ -> reader(Owner, St)
                                       end, [<<"muse-mail-reader">>], [{id, ?READER}])],
                           [<<"muse-mail-layout">>], [{id, <<"mail-layout">>}]),
                    state_div(St),
                    sync_element(Owner)]
           end,
    Win = compose_window(Owner, case Extra of
                                    D when is_binary(D) -> D;
                                    _ -> undefined
                                end),
    ah_div([?K:page_head(<<"邮件"/utf8>>, head_buttons(Accounts)), Body, Win],
           [<<"muse-page muse-mail-page">>], [{id, <<"mail">>}]).

head_buttons([]) ->
    [ah_a([?I:icon(settings, 16), <<"邮箱账号"/utf8>>], [<<"muse-mail-headlink">>], [{href, <<"/mail/accounts">>}])];
head_buttons(_) ->
    [ah_button([?I:icon(refresh, 16), <<"立即同步"/utf8>>], sync, [outlined, sm, <<"muse-btn-icon">>],
               [{type, button}, {id, <<"mail-sync-now">>},
                on(click, {?MODULE, sync_now, #{}}, #{include => includes()})]),
     ah_a([?I:icon(settings, 16), <<"邮箱账号"/utf8>>], [<<"muse-mail-headlink">>], [{href, <<"/mail/accounts">>}]),
     ah_button([?I:icon(pencil, 16), <<"写邮件"/utf8>>], compose, [primary, sm, <<"muse-btn-icon">>],
               [{type, button}, {id, <<"mail-compose-new">>},
                on(click, {?MODULE, compose, #{}}, #{include => includes()})])].

empty_page() ->
    ah_card(ah_empty(ah_a([?I:icon(plus, 16), <<"添加邮箱账号"/utf8>>], [<<"muse-mail-cta">>],
                          [{href, <<"/mail/accounts">>}, {id, <<"mail-add-account">>}]),
                     [], [{title, <<"还没有邮箱账号"/utf8>>},
                          {description, <<"添加你现有的邮箱（QQ、163、Gmail、Outlook 等），用 IMAP 收信、SMTP 发信。"
                                          "智能体能帮你读信和起草，但每次替你发信都要你先批准。"/utf8>>}]),
            [], [{id, <<"mail-empty">>}]).

%% Hidden inputs with the tab's state (every action includes them).
state_div(#{account := A, folder := F, msg := M, limit := L}) ->
    Hidden = fun(Id, V) -> aihtml:ah_void(input, [], [{type, hidden}, {id, Id}, {value, V}]) end,
    ah_div([Hidden(<<"mail-st-account">>, A), Hidden(<<"mail-st-folder">>, F), Hidden(<<"mail-st-msg">>, M),
            Hidden(<<"mail-st-limit">>, integer_to_binary(L))],
           [<<"hidden">>], [{id, ?STATE}]).

includes() ->
    [{id, <<"mail-st-account">>}, {id, <<"mail-st-folder">>}, {id, <<"mail-st-msg">>}, {id, <<"mail-st-limit">>},
     {id, <<"mail-q">>}].

-spec state(map()) -> state().
state(Event) ->
    V = case Event of
            #{values := Vs} when is_map(Vs) -> Vs;
            _ -> #{}
        end,
    Get = fun(K) -> case maps:get(K, V, <<>>) of B when is_binary(B) -> B; _ -> <<>> end end,
    #{account => Get(<<"mail-st-account">>),
      folder => case Get(<<"mail-st-folder">>) of <<>> -> <<"inbox">>; F -> F end,
      msg => Get(<<"mail-st-msg">>),
      q => string:trim(Get(<<"mail-q">>)),
      limit => case string:to_integer(Get(<<"mail-st-limit">>)) of
                   {N, <<>>} when N >= ?PAGE, N =< 5000 -> N;
                   _ -> ?PAGE
               end}.

sync_element(Owner) ->
    Ref = {?MODULE, refresh, #{}},
    ah_div([], [<<"hidden">>], [{id, ?SYNC}, subscribe(muse_ui:topic(Owner, mail), #{refresh => Ref}),
                                on(?CHANGED, Ref, #{include => includes()})]).

url(#{account := A, folder := F}) ->
    <<"/mail?account=", A/binary, "&folder=", (muse_signing:encode_uri_component(F))/binary>>.

subject(<<>>) -> <<"（无主题）"/utf8>>;
subject(S) -> S.

%%%===================================================================
%%% Rail
%%%===================================================================

%% The rail and the list are morphed as whole elements (one root each).
rail_el(Owner, St) ->
    ah_aside(rail(Owner, St), [<<"muse-mail-rail">>], [{id, ?RAIL}]).

list_el(Owner, St) ->
    ah_div(list(Owner, St), [<<"muse-mail-list">>], [{id, ?LIST}]).

rail(Owner, #{account := A, folder := Current} = St) ->
    Accounts = muse_mail_accounts:list(Owner),
    Folders = [F || F <- muse_mail:folders(Owner, A), maps:get(<<"noselect">>, F, false) =/= true],
    Drafts = length([D || D = #{<<"accountId">> := DA} <- muse_mail_send:drafts(Owner), DA =:= A]),
    Starred = length([M || #{<<"id">> := Fid} = F <- Folders,
                           not lists:member(maps:get(<<"role">>, F, null), [<<"trash">>, <<"junk">>, <<"all">>]),
                           M <- muse_mail:folder_messages(Owner, Fid), maps:get(<<"flagged">>, M, false)]),
    ByRole = maps:from_list([{R, F} || F = #{<<"role">> := R} <- Folders, is_binary(R)]),
    CurrentKey = current_key(Current, Folders),
    RoleItems = [case R of
                     <<"starred">> -> folder_link(St, R, muse_mail:role_label(R), star, Starred, R =:= CurrentKey);
                     <<"drafts">> -> folder_link(St, R, muse_mail:role_label(R), file_text, Drafts, R =:= CurrentKey);
                     _ ->
                         Unread = case maps:get(R, ByRole, undefined) of
                                      undefined -> 0;
                                      F -> maps:get(<<"unread">>, F, 0)
                                  end,
                         folder_link(St, R, muse_mail:role_label(R), role_icon(R),
                                     case R of <<"inbox">> -> Unread; <<"junk">> -> Unread; _ -> 0 end,
                                     R =:= CurrentKey)
                 end
                 || R <- ?ROLES, R =/= <<"junk">> orelse maps:is_key(R, ByRole)],
    Others = [F || F <- Folders, not lists:member(maps:get(<<"role">>, F, null), ?ROLES)],
    [case Accounts of
         [_] -> [];
         _ -> ah_select([{I, maps:get(<<"email">>, X)} || X = #{<<"id">> := I} <- Accounts], A, [<<"w-full">>],
                        [{id, <<"mail-account">>}, {aria_label, <<"邮箱账号"/utf8>>},
                         on(change, {?MODULE, account, #{}}, #{include => includes()})])
     end,
     sync_line(Owner, A),
     ah_nav([RoleItems,
             case Others of
                 [] -> [];
                 _ -> [ah_div(<<"其他文件夹"/utf8>>, [<<"muse-mail-rail-head">>], []),
                       [folder_link(St, Fid, folder_name(F), folder, maps:get(<<"unread">>, F, 0), Fid =:= CurrentKey)
                        || F = #{<<"id">> := Fid} <- Others]]
             end],
            [<<"muse-mail-folders">>], [{aria_label, <<"邮箱文件夹"/utf8>>}, {id, <<"mail-folders">>}])].

%% A folder id of a role folder shows as the role.
current_key(Key, Folders) ->
    case [R || #{<<"id">> := I, <<"role">> := R} <- Folders, I =:= Key, is_binary(R)] of
        [R | _] -> R;
        [] -> Key
    end.

folder_name(#{<<"role">> := R}) when is_binary(R) -> muse_mail:role_label(R);
folder_name(#{<<"path">> := P, <<"delimiter">> := D}) when is_binary(D), D =/= <<>> ->
    %% nested folders show their path, readable
    iolist_to_binary(lists:join(<<" / ">>, binary:split(P, D, [global])));
folder_name(#{<<"path">> := P}) -> P.

role_icon(<<"inbox">>) -> inbox;
role_icon(<<"sent">>) -> send;
role_icon(<<"archive">>) -> archive;
role_icon(<<"trash">>) -> trash;
role_icon(<<"junk">>) -> alert;
role_icon(_) -> folder.

folder_link(St, Key, Label, Icon, Count, Active) ->
    ah_a([?I:icon(Icon, 16), ah_span(Label, [<<"muse-mail-folder-name">>], []),
          case Count of
              0 -> [];
              _ -> ah_span(integer_to_binary(Count), [<<"muse-mail-count">>], [])
          end],
         [<<"muse-mail-folder">>],
         [{href, url(St#{folder => Key})}, {id, <<"mail-folder-", Key/binary>>},
          {aria_current, Active andalso <<"page">>},
          on(click, {?MODULE, folder, #{folder => Key}}, #{include => includes(), prevent_default => true})]).

sync_line(Owner, A) ->
    S = muse_mail:sync_state(Owner, A),
    Status = maps:get(<<"status">>, S, <<"pending">>),
    Live = case maps:get(<<"idle">>, S, false) of
               true -> ah_span(<<"实时"/utf8>>, [<<"muse-mail-live">>], [{title, <<"已用 IMAP IDLE 等待新邮件"/utf8>>}]);
               _ -> []
           end,
    Text = case Status of
               <<"syncing">> -> [ah_span([], [<<"muse-spin">>], []), <<"正在同步…"/utf8>>];
               <<"error">> -> [?I:icon(alert, 14), <<"同步出错"/utf8>>];
               <<"ok">> -> [?I:icon(check, 14), <<"已同步 · "/utf8>>, ?K:time(maps:get(<<"lastSyncAt">>, S, null))];
               _ -> <<"等待第一次同步"/utf8>>
           end,
    ah_div([ah_div([Text, Live], [<<"muse-mail-sync-text">>], []),
            case {Status, maps:get(<<"lastError">>, S, null)} of
                {<<"error">>, E} when is_binary(E) ->
                    ah_p([E, <<" "/utf8>>,
                          case maps:get(<<"nextSyncAt">>, S, null) of
                              N when is_binary(N) -> [<<"（"/utf8>>, ?K:time(N), <<" 重试）"/utf8>>];
                              _ -> []
                          end], [<<"muse-mail-sync-error">>], []);
                _ -> []
            end],
         [<<"muse-mail-sync">>], [{id, <<"mail-sync-state">>}, {data_status, Status}]).

%%%===================================================================
%%% List
%%%===================================================================

search_bar(#{q := Q}) ->
    ah_div(ah_input(Q, [<<"w-full muse-mail-search">>],
                    [{id, <<"mail-q">>}, {name, q}, {type, search}, {placeholder, <<"搜索邮件"/utf8>>},
                     {aria_label, <<"搜索邮件"/utf8>>}, {autocomplete, off},
                     on(input, {?MODULE, search, #{}}, #{debounce => 300, include => includes()})]),
           [<<"muse-mail-searchbar">>], []).

list(Owner, #{folder := <<"drafts">>, account := A} = St) ->
    Drafts = [D || D = #{<<"accountId">> := DA} <- muse_mail_send:drafts(Owner), DA =:= A],
    Q = string:lowercase(maps:get(q, St)),
    Hits = [D || D <- Drafts, Q =:= <<>> orelse
                     binary:match(string:lowercase(iolist_to_binary([maps:get(<<"subject">>, D, <<>>), $\s,
                                                                     maps:get(<<"body">>, D, <<>>), $\s,
                                                                     lists:join(<<" ">>, maps:get(<<"to">>, D, []))])),
                                  Q) =/= nomatch],
    [list_head(muse_mail:role_label(<<"drafts">>), length(Hits)),
     case Hits of
         [] -> ah_empty([], [], [{title, <<"没有草稿"/utf8>>}, {description, <<"写到一半的邮件会保存在这里。"/utf8>>}]);
         _ -> ah_div([draft_row(D) || D <- Hits], [<<"muse-mail-rows">>], [])
     end];
list(Owner, #{account := A, folder := F, q := Q, limit := L} = St) ->
    {Total, Msgs} = muse_mail:list(Owner, #{account => A, folder => F, q => Q, limit => L}),
    Folder = muse_mail:resolve(Owner, A, F),
    Title = case Folder of
                {folder, Fr} -> folder_name(Fr);
                starred -> muse_mail:role_label(<<"starred">>);
                {missing, K} -> case lists:member(K, ?ROLES) of true -> muse_mail:role_label(K); false -> K end;
                _ -> <<>>
            end,
    Sent = case Folder of
               {folder, #{<<"role">> := <<"sent">>}} -> true;
               _ -> false
           end,
    [list_head(Title, Total),
     case Msgs of
         [] ->
             ah_empty([], [], [{title, case Q of <<>> -> <<"这里没有邮件"/utf8>>; _ -> <<"没有找到匹配的邮件"/utf8>> end},
                               {description, case Folder of
                                                 {missing, _} -> <<"这个邮箱还没有这个文件夹，或者还没同步完。"/utf8>>;
                                                 _ -> <<"新邮件同步下来后会出现在这里。"/utf8>>
                                             end}]);
         _ ->
             [ah_div([row(M, maps:get(msg, St), Sent) || M <- Msgs], [<<"muse-mail-rows">>], [{id, <<"mail-rows">>}]),
              case Total > length(Msgs) of
                  true -> ah_button(<<"加载更多"/utf8>>, more, [outlined, sm, <<"muse-mail-more">>],
                                    [{type, button}, {id, <<"mail-more">>},
                                     on(click, {?MODULE, more, #{}}, #{include => includes()})]);
                  false -> []
              end]
     end].

list_head(Title, Total) ->
    ah_div([ah_h2(Title, [<<"muse-mail-list-title">>], []),
            ah_span([integer_to_binary(Total), <<" 封"/utf8>>], [<<"text-xs text-muted">>], [])],
           [<<"muse-mail-list-head">>], []).

row(#{<<"id">> := Id} = M, Selected, Sent) ->
    Unread = not maps:get(<<"seen">>, M, false),
    Who = case Sent of
              true -> [<<"致："/utf8>>, case maps:get(<<"to">>, M, []) of
                                          [T | _] -> display_name(T);
                                          [] -> <<"（无收件人）"/utf8>>
                                      end];
              false -> muse_mail:sender_name(M)
          end,
    ah_div([star_button(M),
            ah_a([ah_div([ah_span(Who, [<<"muse-mail-from">>], []),
                          ah_span(short_time(maps:get(<<"date">>, M, null)), [<<"muse-mail-time">>], [])],
                         [<<"muse-mail-row-top">>], []),
                  ah_div([subject(maps:get(<<"subject">>, M, <<>>)),
                          case maps:get(<<"hasAttachments">>, M, false) of
                              true -> ah_span(?I:icon(paperclip, 13), [<<"muse-mail-clip">>], [{title, <<"有附件"/utf8>>}]);
                              false -> []
                          end], [<<"muse-mail-subject">>], []),
                  ah_div(maps:get(<<"snippet">>, M, <<>>), [<<"muse-mail-snippet">>], [])],
                 [<<"muse-mail-row-main">>],
                 [{href, <<"/mail/", Id/binary>>},
                  on(click, {?MODULE, open, #{id => Id}}, #{include => includes(), prevent_default => true})])],
           [<<"muse-mail-row">>, [<<"muse-mail-unread">> || Unread], [<<"muse-mail-selected">> || Id =:= Selected]],
           [{id, <<"mail-row-", Id/binary>>}, {data_unread, atom_to_binary(Unread)}]).

display_name(#{<<"name">> := N}) when is_binary(N), N =/= <<>> -> N;
display_name(#{<<"address">> := A}) -> A;
display_name(_) -> <<>>.

star_button(#{<<"id">> := Id} = M) ->
    On = maps:get(<<"flagged">>, M, false),
    ah_button(?I:icon(star, 16), star, [<<"muse-iconbtn muse-iconbtn-sm muse-mail-star">>, [<<"muse-on">> || On]],
              [{type, button}, {id, <<"mail-star-", Id/binary>>},
               {aria_label, case On of true -> <<"取消星标"/utf8>>; false -> <<"加星标"/utf8>> end},
               {aria_pressed, atom_to_binary(On)},
               on(click, {?MODULE, star, #{id => Id, on => not On}}, #{include => includes()})]).

draft_row(#{<<"id">> := Id} = D) ->
    To = case maps:get(<<"to">>, D, []) of
             [] -> <<"（未填收件人）"/utf8>>;
             L -> iolist_to_binary(lists:join(<<", ">>, L))
         end,
    ah_div([ah_span(?I:icon(file_text, 16), [<<"muse-mail-draft-icon">>], []),
            aihtml:ah_el(button,
                         [ah_div([ah_span([<<"致："/utf8>>, To], [<<"muse-mail-from">>], []),
                                  ah_span(short_time(maps:get(<<"updatedAt">>, D, null)), [<<"muse-mail-time">>], [])],
                                 [<<"muse-mail-row-top">>], []),
                          ah_div([subject(maps:get(<<"subject">>, D, <<>>)),
                                  case maps:get(<<"createdBy">>, D, <<"user">>) of
                                      <<"agent">> -> ah_chip(<<"智能体起草"/utf8>>, [soft, small, info], []);
                                      _ -> []
                                  end], [<<"muse-mail-subject">>], []),
                          case maps:get(<<"error">>, D, null) of
                              E when is_binary(E) -> ah_div(E, [<<"muse-mail-draft-error">>], []);
                              _ -> ah_div(muse_js:slice(maps:get(<<"body">>, D, <<>>), 120), [<<"muse-mail-snippet">>], [])
                          end],
                         [<<"muse-mail-row-main">>],
                         [{type, button}, on(click, {?MODULE, open_draft, #{id => Id}}, #{include => includes()})])],
           [<<"muse-mail-row">>], [{id, <<"mail-draft-", Id/binary>>}]).

short_time(Iso) when is_binary(Iso) ->
    case muse_time:parse(Iso) of
        nan -> <<>>;
        Ms ->
            {{Y, M, D} = Date, {H, Mi, _}} = calendar:system_time_to_local_time(Ms, millisecond),
            {{TY, _, _} = Today, _} = calendar:local_time(),
            unicode:characters_to_binary(
              if
                  Date =:= Today -> io_lib:format("~2..0B:~2..0B", [H, Mi]);
                  Y =:= TY -> io_lib:format("~B月~B日", [M, D]);
                  true -> io_lib:format("~B/~B/~B", [Y, M, D])
              end)
    end;
short_time(_) ->
    <<>>.

%%%===================================================================
%%% Reader
%%%===================================================================

empty_reader() ->
    ah_div(ah_empty([], [], [{title, <<"选择一封邮件来阅读"/utf8>>}]), [<<"muse-mail-reader-empty">>], []).

missing_reader() ->
    ah_div(ah_empty([], [], [{title, <<"找不到这封邮件"/utf8>>},
                             {description, <<"它可能已被移动或删除，或者已超出同步范围。"/utf8>>}]),
           [<<"muse-mail-reader-empty">>], [{id, <<"mail-missing">>}]).

reader(_Owner, #{msg := <<>>}) ->
    empty_reader();
reader(Owner, #{msg := Id}) ->
    case muse_mail:get_message(Owner, Id) of
        {ok, M} -> message_view(Owner, M, text);
        {error, _} -> missing_reader()
    end.

%% `View': `text', or `{html, Images}' (the sandboxed frame).
message_view(Owner, #{<<"id">> := Id} = M, View0) ->
    #{text := Text} = muse_mail:body(Owner, M),
    HtmlOnly = not maps:get(<<"hasText">>, M, true) andalso maps:get(<<"hasHtml">>, M, false),
    View = case {View0, HtmlOnly} of
               {text, true} -> {html, false};
               _ -> View0
           end,
    Field = fun(_, <<>>) -> [];
               (Label, Value) -> ah_div([ah_span(Label, [<<"muse-mail-hlabel">>], []), ah_span(Value, [], [])],
                                        [<<"muse-mail-hrow">>], [])
            end,
    Tool = fun(Label, Icon, Name, Args, Extra) ->
                   ah_button([?I:icon(Icon, 16), ah_span(Label, [<<"muse-mail-tool-label">>], [])], Name,
                             [borderless, sm, <<"muse-mail-tool">>],
                             [{type, button}, {id, <<"mail-", (atom_to_binary(Name))/binary>>}, {title, Label},
                              on(click, {?MODULE, Name, Args#{id => Id}}, Extra#{include => includes()})])
           end,
    Flagged = maps:get(<<"flagged">>, M, false),
    ah_article(
      [ah_div([Tool(<<"回复"/utf8>>, reply, reply, #{}, #{}),
               Tool(<<"全部回复"/utf8>>, reply_all, reply_all, #{}, #{}),
               Tool(<<"转发"/utf8>>, forward, forward, #{}, #{}),
               ah_span([], [<<"muse-mail-tool-sep">>], []),
               Tool(<<"归档"/utf8>>, archive, archive, #{}, #{}),
               Tool(<<"删除"/utf8>>, trash, delete, #{},
                    #{confirm => #{title => <<"删除邮件"/utf8>>,
                                   body => <<"把这封邮件移到垃圾箱？已在垃圾箱里的会从服务器上彻底删除。"/utf8>>,
                                   ok => <<"删除"/utf8>>, cancel => <<"取消"/utf8>>, variant => danger}}),
               ah_span([], [<<"muse-mail-tool-sep">>], []),
               Tool(case Flagged of true -> <<"取消星标"/utf8>>; false -> <<"加星标"/utf8>> end, star, star_reader,
                    #{on => not Flagged}, #{}),
               Tool(<<"标为未读"/utf8>>, mail, unread, #{}, #{})],
              [<<"muse-mail-tools">>], []),
       ah_h2(subject(maps:get(<<"subject">>, M, <<>>)), [<<"muse-mail-reader-subject">>], []),
       ah_div([ah_div(avatar(M), [], []),
               ah_div([ah_div([ah_strong(muse_mail:sender_name(M), [], []),
                               ah_span(case maps:get(<<"from">>, M, null) of
                                           #{<<"address">> := Ad} -> [<<" <">>, Ad, <<">">>];
                                           _ -> []
                                       end, [<<"text-xs text-muted">>], [])], [], []),
                       Field(<<"收件人"/utf8>>, muse_mail:addresses_text(maps:get(<<"to">>, M, []))),
                       Field(<<"抄送"/utf8>>, muse_mail:addresses_text(maps:get(<<"cc">>, M, []))),
                       Field(<<"时间"/utf8>>, ?K:time(maps:get(<<"date">>, M, null)))],
                      [<<"min-w-0 flex-1">>], [])],
              [<<"muse-mail-headers">>], []),
       ah_div(body_view(M, Text, View), [<<"muse-mail-body">>], [{id, <<"mail-body">>}]),
       attachments(M)],
      [<<"muse-mail-message">>], [{id, <<"mail-message-", Id/binary>>}]).

avatar(M) ->
    Name = muse_mail:sender_name(M),
    Initial = case string:next_grapheme(Name) of
                  [G | _] -> string:uppercase(unicode:characters_to_binary([G]));
                  _ -> <<"?">>
              end,
    ah_span(Initial, [<<"muse-mail-avatar">>], [{aria_hidden, <<"true">>}]).

body_view(#{<<"id">> := Id} = M, Text, text) ->
    [case maps:get(<<"truncated">>, M, false) of
         true -> ah_p(<<"这封邮件很大，这里只显示了前面的部分；附件可以单独下载。"/utf8>>, [<<"muse-mail-note">>], []);
         false -> []
     end,
     ah_div(case Text of <<>> -> <<"（没有正文）"/utf8>>; _ -> Text end, [<<"muse-mail-text">>], [{id, <<"mail-text">>}]),
     case maps:get(<<"hasHtml">>, M, false) of
         true -> ah_button(<<"显示网页版式"/utf8>>, html, [outlined, sm, <<"muse-mail-view">>],
                           [{type, button}, {id, <<"mail-show-html">>},
                            on(click, {?MODULE, view, #{id => Id, view => html, images => false}}, #{})]);
         false -> []
     end];
body_view(#{<<"id">> := Id} = M, _Text, {html, Images}) ->
    Src = <<"/mail-content/", Id/binary, "/body", (case Images of true -> <<"?images=1">>; false -> <<>> end)/binary>>,
    [ah_div([case Images of
                 false -> [ah_span(<<"为保护隐私，远程图片已屏蔽。"/utf8>>, [], []),
                           ah_button(<<"显示图片"/utf8>>, images, [borderless, sm],
                                     [{type, button}, {id, <<"mail-show-images">>},
                                      on(click, {?MODULE, view, #{id => Id, view => html, images => true}}, #{})])];
                 true -> ah_span(<<"已显示远程图片。"/utf8>>, [], [])
             end,
             case maps:get(<<"hasText">>, M, false) of
                 true -> ah_button(<<"显示纯文本"/utf8>>, text, [borderless, sm],
                                   [{type, button}, on(click, {?MODULE, view, #{id => Id, view => text}}, #{})]);
                 false -> []
             end],
            [<<"muse-mail-note muse-mail-images">>], []),
     aihtml:ah_el(iframe, [], [<<"muse-mail-frame">>],
                  [{id, <<"mail-frame">>}, {src, Src}, {sandbox, <<"allow-popups allow-popups-to-escape-sandbox">>},
                   {referrerpolicy, <<"no-referrer">>}, {title, <<"邮件正文"/utf8>>}])].

attachments(#{<<"id">> := Id} = M) ->
    case [A || A <- maps:get(<<"attachments">>, M, []), maps:get(<<"inline">>, A, false) =/= true] of
        [] -> [];
        Atts ->
            ah_div([ah_div([?I:icon(paperclip, 14), integer_to_binary(length(Atts)), <<" 个附件"/utf8>>],
                           [<<"muse-mail-atts-head">>], []),
                    ah_ul([ah_li([?I:icon(file, 16),
                                  ah_div([ah_div(maps:get(<<"filename">>, A, <<>>), [<<"muse-mail-att-name">>], []),
                                          ah_div(?C:size_label(maps:get(<<"size">>, A, 0)), [<<"text-xs text-muted">>], [])],
                                         [<<"min-w-0 flex-1">>], []),
                                  ah_a([?I:icon(download, 14), <<"下载"/utf8>>], [<<"muse-mail-att-btn">>],
                                       [{href, <<"/mail-content/", Id/binary, "/attachment?part=",
                                                 (muse_signing:encode_uri_component(P))/binary, "&download=1">>},
                                        {download, maps:get(<<"filename">>, A, <<>>)}]),
                                  ah_button([?I:icon(folder_plus, 14), <<"保存到文件"/utf8>>], save,
                                            [borderless, sm, <<"muse-mail-att-btn">>],
                                            [{type, button}, {id, <<"mail-save-", (att_key(P))/binary>>},
                                             on(click, {?MODULE, save_attachment, #{id => Id, part => P}},
                                                #{indicator => this})])],
                                 [<<"muse-mail-att">>], [])
                           || A = #{<<"part">> := P} <- Atts],
                          [<<"muse-mail-atts">>], [])],
                   [<<"muse-mail-atts-box">>], [{id, <<"mail-atts">>}])
    end.

att_key(P) -> binary:replace(P, <<".">>, <<"-">>, [global]).

%%%===================================================================
%%% Compose
%%%===================================================================

compose_window(Owner, DraftId) ->
    {Body, Open} = case DraftId of
                       undefined -> {[], false};
                       _ ->
                           case muse_mail_send:get_draft(Owner, DraftId) of
                               {ok, D} -> {compose_form(Owner, D), true};
                               _ -> {[], false}
                           end
                   end,
    #ah_window{id = ?WIN, title = <<"写邮件"/utf8>>, body = ah_div(Body, [], [{id, ?COMPOSE}]),
               modal = true, draggable = false, resizable = false, width = 760, open = Open,
               close_on_overlay = false}.

compose_form(Owner, #{<<"id">> := Id} = D) ->
    Accounts = [{I, address(A)} || A = #{<<"id">> := I} <- muse_mail_accounts:list(Owner)],
    Join = fun(K) -> iolist_to_binary(lists:join(<<", ">>, maps:get(K, D, []))) end,
    Input = fun(Name, Label, Value, Extra) ->
                    ah_field(Label, ah_input(Value, [<<"w-full">>],
                                             [{name, Name}, {id, <<"mail-c-", Name/binary>>}, {autocomplete, off} | Extra]),
                             [], [{for, <<"mail-c-", Name/binary>>}])
            end,
    ah_form([ah_div(case maps:get(<<"error">>, D, null) of
                        E when is_binary(E) -> ah_alert(E, [error], []);
                        _ -> []
                    end, [], [{id, <<"mail-compose-error">>}, {role, status}]),
             ah_field(<<"发件人"/utf8>>, ah_select(Accounts, maps:get(<<"accountId">>, D, <<>>), [<<"w-full">>],
                                                  [{name, account}, {id, <<"mail-c-account">>}]),
                      [], [{for, <<"mail-c-account">>}]),
             Input(<<"to">>, <<"收件人"/utf8>>, Join(<<"to">>),
                   [{placeholder, <<"name@example.com，多个用逗号分隔"/utf8>>}]),
             Input(<<"cc">>, <<"抄送"/utf8>>, Join(<<"cc">>), []),
             Input(<<"bcc">>, <<"密送"/utf8>>, Join(<<"bcc">>), []),
             Input(<<"subject">>, <<"主题"/utf8>>, maps:get(<<"subject">>, D, <<>>), [{maxlength, 500}]),
             ah_textarea(maps:get(<<"body">>, D, <<>>), [<<"w-full muse-mail-compose-body">>],
                         [{name, body}, {id, <<"mail-c-body">>}, {rows, 12}, {aria_label, <<"正文"/utf8>>}]),
             ah_div(compose_attachments(Owner, D), [<<"muse-mail-compose-atts">>], [{id, ?ATTS}]),
             ah_div([ah_button([?I:icon(trash, 16), <<"删除草稿"/utf8>>], discard, [borderless, sm, <<"muse-cal-danger">>],
                               [{type, button}, {id, <<"mail-c-discard">>},
                                on(click, {?MODULE, discard, #{id => Id}},
                                   #{include => includes(),
                                     confirm => #{title => <<"删除草稿"/utf8>>, body => <<"删除这封草稿？无法恢复。"/utf8>>,
                                                  ok => <<"删除"/utf8>>, cancel => <<"取消"/utf8>>, variant => danger}})]),
                     ah_span([], [<<"flex-1">>], []),
                     ah_button(<<"保存草稿"/utf8>>, save, [outlined, sm],
                               [{type, button}, {id, <<"mail-c-save">>},
                                on(click, {?MODULE, save_draft, #{id => Id}}, #{include => includes()})]),
                     ah_button([?I:icon(send, 16), <<"发送"/utf8>>], send, [primary, sm, <<"muse-btn-icon">>],
                               [{type, submit}, {id, <<"mail-c-send">>}])],
                    [<<"muse-cal-form-actions">>], [])],
            [<<"flex flex-col gap-3">>],
            [{id, <<"mail-compose-form">>},
             on(submit, {?MODULE, send, #{id => Id}}, #{prevent_default => true, include => includes(),
                                                          indicator => <<"#mail-c-send">>,
                                                          disable => <<"#mail-c-send">>})]).

address(A) ->
    muse_mail:address_text(#{<<"name">> => maps:get(<<"name">>, A, <<>>), <<"address">> => maps:get(<<"email">>, A)}).

compose_attachments(Owner, #{<<"id">> := Id} = D) ->
    Chip = fun(Name, Size, Kind, Ref) ->
                   ah_li([?I:icon(paperclip, 14), ah_span(Name, [<<"muse-mail-att-name">>], []),
                          ah_span(?C:size_label(Size), [<<"text-xs text-muted">>], []),
                          ah_button(?I:icon(x, 14), remove, [<<"muse-iconbtn muse-iconbtn-sm">>],
                                    [{type, button}, {aria_label, <<"移除附件"/utf8>>},
                                     on(click, {?MODULE, remove_attachment, #{id => Id, kind => Kind, ref => Ref}}, #{})])],
                         [<<"muse-mail-chip">>], [])
           end,
    Files = maps:from_list([{I, F} || F = #{<<"id">> := I} <- muse_files:list(Owner, unsigned)]),
    Chosen = [Chip(maps:get(<<"name">>, F), maps:get(<<"size">>, F, 0), file, FId)
              || FId <- maps:get(<<"fileIds">>, D, []), F <- [maps:get(FId, Files, undefined)], is_map(F)]
        ++ [Chip(N, S, upload, U) || #{<<"id">> := U, <<"name">> := N, <<"size">> := S} <- maps:get(<<"uploads">>, D, [])]
        ++ [Chip(N, S, forward, P) || #{<<"part">> := P, <<"filename">> := N, <<"size">> := S} <- maps:get(<<"forwards">>, D, [])],
    Pick = [{I, N} || #{<<"id">> := I, <<"name">> := N} <- muse_files:list(Owner, unsigned),
                      not lists:member(I, maps:get(<<"fileIds">>, D, []))],
    MaxMb = integer_to_binary(muse_config:get(files_max_mb, 25)),
    [case Chosen of
         [] -> [];
         _ -> ah_ul(Chosen, [<<"muse-mail-chips">>], [{id, <<"mail-c-chips">>}])
     end,
     ah_div([case Pick of
                 [] -> [];
                 _ -> [ah_select([{<<>>, <<"从“文件”添加附件…"/utf8>>} | Pick], <<>>, [<<"muse-mail-pick">>],
                                 [{name, file_pick}, {id, <<"mail-c-file">>}, {aria_label, <<"从文件添加附件"/utf8>>},
                                  on(change, {?MODULE, add_file, #{id => Id}}, #{})])]
             end,
             ah_upload([], [<<"muse-mail-upload">>],
                       [{id, <<"mail-c-upload">>}, {url, <<"/mail-content/", Id/binary, "/upload">>}, {field_name, file},
                        {multiple, true}, {max_size, muse_files:max_bytes()},
                        {drag_text, <<"拖拽文件到这里，或"/utf8>>}, {browse_text, <<"上传附件"/utf8>>},
                        {hint, <<"单个不超过 "/utf8, MaxMb/binary, " MB">>},
                        {labels, #{too_large => <<"超过 "/utf8, MaxMb/binary, " MB">>,
                                   upload_failed => <<"上传失败"/utf8>>, remove => <<"移除"/utf8>>,
                                   network_error => <<"网络错误"/utf8>>}},
                        on(change, {?MODULE, uploaded, #{id => Id}}, #{})])],
            [<<"muse-mail-att-add">>], [])].

open_compose(Ctx, Owner, D) ->
    aihtml_action:html(Ctx, {id, ?COMPOSE}, compose_form(Owner, D), inner),
    aihtml_window:set_title(Ctx, {id, ?WIN},
                       case maps:get(<<"subject">>, D, <<>>) of
                           <<>> -> <<"写邮件"/utf8>>;
                           S -> S
                       end),
    aihtml_lib_overlay:open(Ctx, {id, ?WIN}).

%% The compose form's fields as a draft patch.
form_draft(Event) ->
    T = fun(K) -> ?K:form_text(Event, K) end,
    Body = case ?K:form_value(Event, <<"body">>) of
               undefined -> <<>>;
               B -> binary:replace(B, <<"\r\n">>, <<"\n">>, [global])
           end,
    maps:filter(fun(_, V) -> V =/= undefined end,
                #{<<"accountId">> => case T(<<"account">>) of <<>> -> undefined; A -> A end,
                  <<"to">> => T(<<"to">>), <<"cc">> => T(<<"cc">>), <<"bcc">> => T(<<"bcc">>),
                  <<"subject">> => T(<<"subject">>), <<"body">> => Body}).

%%%===================================================================
%%% Accounts page
%%%===================================================================

accounts_page(Owner, Edit) ->
    Accounts = muse_mail_accounts:list(Owner),
    Form = case {Edit, Accounts} of
               {<<>>, []} -> account_form(new, new_values());
               {<<>>, _} -> [];
               {Id, _} ->
                   case muse_mail_accounts:get(Owner, Id) of
                       {ok, A} -> account_form({edit, Id}, muse_mail_accounts:public(A));
                       _ -> []
                   end
           end,
    ah_div([ah_a(<<"← 邮件"/utf8>>, [<<"text-sm text-muted hover:text-primary">>], [{href, <<"/mail">>}]),
            ?K:page_head(<<"邮箱账号"/utf8>>,
                         [ah_button([?I:icon(plus, 16), <<"添加邮箱账号"/utf8>>], add, [primary, sm, <<"muse-btn-icon">>],
                                    [{type, button}, {id, <<"mail-acc-add">>}, on(click, {?MODULE, new_account, #{}})])]),
            case muse_mail_accounts:ready() of
                true -> [];
                false -> ah_alert(<<"服务器没有设置 TOKEN_ENCRYPTION_KEY，不能保存邮箱密码。请管理员在 .env 里设置后重启。"/utf8>>,
                                  [warning], [{id, <<"mail-no-key">>}])
            end,
            ah_p(<<"用你现有的邮箱收发信：收信走 IMAP，发信走 SMTP。很多邮箱要用“授权码”或“应用专用密码”代替登录密码。"
                   "密码加密保存在服务器上，不会显示，也不会交给智能体。"/utf8>>, [<<"text-sm text-muted">>], []),
            ah_div(Form, [<<"muse-mail-acc-form">>], [{id, ?ACC_FORM}]),
            ah_div(account_list(Owner), [<<"flex flex-col gap-3">>], [{id, ?ACC_LIST}]),
            ah_div([], [<<"hidden">>], [{id, ?SYNC},
                                        subscribe(muse_ui:topic(Owner, mail), #{refresh => {?MODULE, refresh_accounts, #{}}}),
                                        on(?CHANGED, {?MODULE, refresh_accounts, #{}}, #{})])],
           [<<"muse-page muse-mail-accounts">>], [{id, <<"mail-accounts">>}]).

account_list(Owner) ->
    case muse_mail_accounts:list(Owner) of
        [] -> [];
        Accounts -> [account_card(Owner, muse_mail_accounts:public(A)) || A <- Accounts]
    end.

account_card(Owner, #{<<"id">> := Id} = A) ->
    Sec = fun(<<"tls">>) -> <<"TLS">>; (_) -> <<"STARTTLS">> end,
    Server = fun(P) ->
                     [maps:get(<<P/binary, "Host">>, A), <<":">>, integer_to_binary(maps:get(<<P/binary, "Port">>, A)),
                      <<" · "/utf8>>, Sec(maps:get(<<P/binary, "Security">>, A))]
             end,
    ah_div([ah_div([ah_div([ah_div(maps:get(<<"name">>, A), [<<"muse-row-title">>], []),
                            ah_div(maps:get(<<"email">>, A), [<<"muse-row-meta">>], [])],
                           [<<"flex-1 min-w-0">>], []),
                    sync_line(Owner, Id)],
                   [<<"flex items-start gap-3">>], []),
            ah_dl([ah_dt(<<"收信（IMAP）"/utf8>>, [], []), ah_dd(Server(<<"imap">>), [], []),
                   ah_dt(<<"发信（SMTP）"/utf8>>, [], []), ah_dd(Server(<<"smtp">>), [], []),
                   ah_dt(<<"用户名"/utf8>>, [], []), ah_dd(maps:get(<<"username">>, A, <<>>), [], []),
                   ah_dt(<<"已发送"/utf8>>, [], []),
                   ah_dd(case maps:get(<<"saveSent">>, A, true) of
                             true -> <<"发送后存一份到“已发送”"/utf8>>;
                             false -> <<"由服务器自动保存"/utf8>>
                         end, [], [])]
                  ++ case maps:get(<<"allowSelfSigned">>, A, false) of
                         true -> [ah_dt(<<"证书"/utf8>>, [], []), ah_dd(<<"允许自签名证书"/utf8>>, [], [])];
                         false -> []
                     end,
                  [<<"muse-fields">>], []),
            ah_div([ah_a(<<"打开收件箱"/utf8>>, [<<"muse-mail-headlink">>], [{href, <<"/mail?account=", Id/binary>>}]),
                    ah_button(<<"编辑"/utf8>>, edit, [outlined, sm],
                              [{type, button}, {id, <<"mail-acc-edit-", Id/binary>>},
                               on(click, {?MODULE, edit_account, #{id => Id}})]),
                    ah_button(<<"立即同步"/utf8>>, sync, [outlined, sm],
                              [{type, button}, on(click, {?MODULE, sync_account, #{id => Id}})]),
                    ah_button([?I:icon(trash, 16), <<"删除"/utf8>>], delete, [borderless, sm, <<"muse-cal-danger">>],
                              [{type, button}, {id, <<"mail-acc-delete-", Id/binary>>},
                               on(click, {?MODULE, delete_account, #{id => Id}},
                                  #{confirm => #{title => <<"删除邮箱账号"/utf8>>,
                                                 body => <<"删除这个邮箱账号？这里同步的邮件和草稿会一起删除，服务器上的邮件不受影响。"/utf8>>,
                                                 ok => <<"删除"/utf8>>, cancel => <<"取消"/utf8>>, variant => danger}})])],
                   [<<"flex flex-wrap items-center gap-2">>], [])],
           [<<"muse-card muse-mail-acc">>], [{id, <<"mail-acc-", Id/binary>>}]).

new_values() ->
    (muse_mail_accounts:preset(<<"qq">>))#{<<"preset">> => <<"qq">>, <<"allowSelfSigned">> => false}.

account_form(Mode, V0) ->
    V = fun(K) -> case maps:get(K, V0, <<>>) of
                      I when is_integer(I) -> integer_to_binary(I);
                      B when is_binary(B) -> B;
                      _ -> <<>>
                  end
        end,
    Preset = case V(<<"preset">>) of <<>> -> <<"custom">>; P -> P end,
    Ref = case Mode of
              new -> {?MODULE, save_account, #{id => new}};
              {edit, Id} -> {?MODULE, save_account, #{id => Id}}
          end,
    TestId = case Mode of new -> new; {edit, I} -> I end,
    Text = fun(Name, Label, Extra) ->
                   ah_field(Label, ah_input(V(Name), [<<"w-full">>],
                                            [{name, Name}, {id, <<"mail-a-", Name/binary>>}, {autocomplete, off} | Extra]),
                            [top], [{for, <<"mail-a-", Name/binary>>}])
           end,
    Security = fun(Name) ->
                       ah_select([{<<"tls">>, <<"SSL/TLS">>}, {<<"starttls">>, <<"STARTTLS">>}],
                                 case V(Name) of <<>> -> <<"tls">>; S -> S end, [<<"w-full">>],
                                 [{name, Name}, {id, <<"mail-a-", Name/binary>>}])
               end,
    Check = fun(Name, Label, On) ->
                    ah_checkbox(Label, <<"true">>, [], [{name, Name}, {id, <<"mail-a-", Name/binary>>}, {checked, On}])
            end,
    ah_card(
      ah_form([ah_div([], [], [{id, <<"mail-acc-result">>}, {role, status}]),
               ah_field(<<"邮箱类型"/utf8>>,
                        ah_select([{P, L} || {P, L, _} <- muse_mail_accounts:presets()], Preset, [<<"w-full">>],
                                  [{name, preset}, {id, <<"mail-a-preset">>},
                                   on(change, {?MODULE, preset, #{mode => TestId}}, #{})]),
                        [top], [{for, <<"mail-a-preset">>}]),
               ah_p(preset_hint(Preset), [<<"text-xs text-muted">>], [{id, <<"mail-a-hint">>}]),
               ah_div([Text(<<"name">>, <<"显示名称"/utf8>>, [{maxlength, 80}, {placeholder, <<"例如：张三"/utf8>>}]),
                       Text(<<"email">>, <<"邮箱地址"/utf8>>, [{type, email}, {placeholder, <<"name@example.com">>}])],
                      [<<"grid gap-3 sm:grid-cols-2">>], []),
               ah_div([Text(<<"username">>, <<"用户名"/utf8>>, [{placeholder, <<"默认同邮箱地址"/utf8>>}]),
                       ah_field(<<"密码或授权码"/utf8>>,
                                ah_input(<<>>, [<<"w-full">>],
                                         [{name, password}, {id, <<"mail-a-password">>}, {type, password},
                                          {autocomplete, <<"new-password">>},
                                          {placeholder, case Mode of
                                                            new -> <<"授权码 / 应用专用密码"/utf8>>;
                                                            _ -> <<"留空则不修改"/utf8>>
                                                        end}]),
                                [top], [{for, <<"mail-a-password">>}])],
                      [<<"grid gap-3 sm:grid-cols-2">>], []),
               ah_div([Text(<<"imapHost">>, <<"收信服务器（IMAP）"/utf8>>, [{placeholder, <<"imap.example.com">>}]),
                       Text(<<"imapPort">>, <<"端口"/utf8>>, [{inputmode, numeric}]),
                       ah_field(<<"加密"/utf8>>, Security(<<"imapSecurity">>), [top], [])],
                      [<<"muse-mail-server-row">>], []),
               ah_div([Text(<<"smtpHost">>, <<"发信服务器（SMTP）"/utf8>>, [{placeholder, <<"smtp.example.com">>}]),
                       Text(<<"smtpPort">>, <<"端口"/utf8>>, [{inputmode, numeric}]),
                       ah_field(<<"加密"/utf8>>, Security(<<"smtpSecurity">>), [top], [])],
                      [<<"muse-mail-server-row">>], []),
               ah_div([Check(<<"saveSent">>, <<"发送后存一份到“已发送”（Gmail、Outlook 会自动保存，不用勾）"/utf8>>,
                             maps:get(<<"saveSent">>, V0, true) =:= true),
                       Check(<<"allowSelfSigned">>, <<"允许自签名证书（只在自建邮件服务器上使用）"/utf8>>,
                             maps:get(<<"allowSelfSigned">>, V0, false) =:= true)],
                      [<<"flex flex-col gap-2">>], []),
               ah_div([ah_button(<<"测试连接"/utf8>>, test, [outlined, sm],
                                 [{type, button}, {id, <<"mail-acc-test">>},
                                  on(click, {?MODULE, test_account, #{id => TestId}}, #{indicator => this})]),
                       ah_span([], [<<"flex-1">>], []),
                       ah_button(<<"取消"/utf8>>, cancel, [borderless, sm],
                                 [{type, button}, on(click, {?MODULE, cancel_account, #{}})]),
                       ah_button(<<"测试并保存"/utf8>>, save, [primary, sm],
                                 [{type, submit}, {id, <<"mail-acc-save">>}])],
                      [<<"muse-cal-form-actions">>], [])],
              [<<"flex flex-col gap-3">>],
              [{id, <<"mail-acc-form-el">>},
               on(submit, Ref, #{prevent_default => true, indicator => <<"#mail-acc-save">>,
                                 disable => <<"#mail-acc-save">>})]),
      [], [{title, case Mode of new -> <<"添加邮箱账号"/utf8>>; _ -> <<"编辑邮箱账号"/utf8>> end}]).

preset_hint(<<"qq">>) ->
    <<"在 QQ 邮箱网页版“设置 → 账号”里开启 IMAP/SMTP 服务，用生成的授权码代替 QQ 密码。"/utf8>>;
preset_hint(P) when P =:= <<"163">>; P =:= <<"126">> ->
    <<"在网易邮箱网页版“设置 → POP3/SMTP/IMAP”里开启 IMAP/SMTP 服务，用客户端授权码登录。"/utf8>>;
preset_hint(<<"gmail">>) ->
    <<"需要开启两步验证，并在 Google 账号的“应用专用密码”里生成一个密码。"/utf8>>;
preset_hint(<<"outlook">>) ->
    <<"Outlook / Office 365 需要账号允许 IMAP 和 SMTP 密码登录（部分组织账号已关闭）；有两步验证时用应用密码。"/utf8>>;
preset_hint(<<"icloud">>) ->
    <<"在 Apple 账号的“App 专用密码”里生成一个密码；用户名一般是完整的 iCloud 邮箱地址。"/utf8>>;
preset_hint(_) ->
    <<"填写邮箱服务商提供的 IMAP 和 SMTP 服务器。一般 IMAP 用 993（SSL/TLS），SMTP 用 465（SSL/TLS）或 587（STARTTLS）。"/utf8>>.

%% The account form as muse_mail_accounts' input.
form_account(Event) ->
    T = fun(K) -> ?K:form_text(Event, K) end,
    Port = fun(K) ->
                   case string:to_integer(T(K)) of
                       {N, <<>>} -> N;
                       _ -> T(K)
                   end
           end,
    #{<<"name">> => T(<<"name">>), <<"email">> => T(<<"email">>), <<"username">> => T(<<"username">>),
      <<"password">> => case ?K:form_value(Event, <<"password">>) of undefined -> <<>>; P -> P end,
      <<"imapHost">> => T(<<"imapHost">>), <<"imapPort">> => Port(<<"imapPort">>),
      <<"imapSecurity">> => T(<<"imapSecurity">>),
      <<"smtpHost">> => T(<<"smtpHost">>), <<"smtpPort">> => Port(<<"smtpPort">>),
      <<"smtpSecurity">> => T(<<"smtpSecurity">>),
      <<"saveSent">> => T(<<"saveSent">>) =:= <<"true">>,
      <<"allowSelfSigned">> => T(<<"allowSelfSigned">>) =:= <<"true">>,
      <<"preset">> => T(<<"preset">>)}.

%%%===================================================================
%%% Actions
%%%===================================================================

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> term().
action(Name, Args, Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> act(Name, Args, Event, Ctx, Owner) end).

%% navigation
act(folder, #{folder := F}, Event, Ctx, Owner) ->
    St = (state(Event))#{folder => F, msg => <<>>, limit => ?PAGE},
    show(Ctx, Owner, St, [rail, list, reader]),
    aihtml_action:push_url(Ctx, url(St));
act(account, _Args, Event, Ctx, Owner) ->
    St0 = state(Event),
    A = case maps:get(value, Event, <<>>) of V when is_binary(V), V =/= <<>> -> V; _ -> maps:get(account, St0) end,
    St = St0#{account => A, folder => <<"inbox">>, msg => <<>>, limit => ?PAGE, q => <<>>},
    show(Ctx, Owner, St, [rail, list, reader]),
    aihtml_action:set_value(Ctx, {id, <<"mail-q">>}, <<>>),
    aihtml_action:push_url(Ctx, url(St));
act(search, _Args, Event, Ctx, Owner) ->
    show(Ctx, Owner, (state(Event))#{limit => ?PAGE}, [list]);
act(more, _Args, Event, Ctx, Owner) ->
    St = state(Event),
    show(Ctx, Owner, St#{limit => maps:get(limit, St) + ?PAGE}, [list]);
act(refresh, _Args, Event, Ctx, Owner) ->
    St = state(Event),
    Parts = case maps:get(msg, St) of
                <<>> -> [rail, list];
                Id -> case muse_mail:get_message(Owner, Id) of
                          {ok, _} -> [rail, list];
                          _ -> [rail, list, reader]
                      end
            end,
    show(Ctx, Owner, St, Parts);
act(sync_now, _Args, Event, Ctx, Owner) ->
    #{account := A} = state(Event),
    muse_mail_sync:request_sync(Owner, A),
    ?K:toast_ok(Ctx, <<"已开始同步"/utf8>>);
%% reading
act(open, #{id := Id}, Event, Ctx, Owner) ->
    St0 = state(Event),
    case muse_mail:get_message(Owner, Id) of
        {ok, M} ->
            _ = case maps:get(<<"seen">>, M, false) of
                    true -> ok;
                    false -> muse_mail:set_seen(Owner, Id, true)
                end,
            St = St0#{msg => Id},
            show(Ctx, Owner, St, [rail, list, reader]),
            aihtml_action:push_url(Ctx, <<"/mail/", Id/binary>>);
        {error, E} ->
            ?K:toast_error(Ctx, ?K:error_text(E)),
            show(Ctx, Owner, St0, [list])
    end;
act(view, #{id := Id} = Args, _Event, Ctx, Owner) ->
    case muse_mail:get_message(Owner, Id) of
        {ok, M} ->
            #{text := Text} = muse_mail:body(Owner, M),
            View = case maps:get(view, Args, text) of
                       html -> {html, maps:get(images, Args, false) =:= true};
                       _ -> text
                   end,
            aihtml_action:html(Ctx, {id, <<"mail-body">>}, body_view(M, Text, View), inner);
        {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E))
    end;
act(star, #{id := Id, on := On}, Event, Ctx, Owner) ->
    after_change(Ctx, Owner, state(Event), muse_mail:set_flagged(Owner, Id, On), [rail, list], undefined);
act(star_reader, #{id := Id, on := On}, Event, Ctx, Owner) ->
    after_change(Ctx, Owner, state(Event), muse_mail:set_flagged(Owner, Id, On), [rail, list, reader], undefined);
act(unread, #{id := Id}, Event, Ctx, Owner) ->
    after_change(Ctx, Owner, (state(Event))#{msg => <<>>}, muse_mail:set_seen(Owner, Id, false),
                 [rail, list, reader], <<"已标为未读"/utf8>>);
act(archive, #{id := Id}, Event, Ctx, Owner) ->
    after_change(Ctx, Owner, (state(Event))#{msg => <<>>}, muse_mail:move(Owner, Id, <<"archive">>),
                 [rail, list, reader], <<"已归档"/utf8>>);
act(delete, #{id := Id}, Event, Ctx, Owner) ->
    after_change(Ctx, Owner, (state(Event))#{msg => <<>>}, muse_mail:delete(Owner, Id),
                 [rail, list, reader], <<"已删除"/utf8>>);
act(save_attachment, #{id := Id, part := P}, _Event, Ctx, Owner) ->
    case muse_mail:save_attachment(Owner, Id, P) of
        {ok, #{<<"id">> := FileId, <<"name">> := Name}} ->
            ah_toast(Ctx, <<"已保存到“文件”"/utf8>>,
                     #{description => Name, variant => success,
                       action => #{label => <<"打开"/utf8>>, href => <<"/documents/", FileId/binary>>}}),
            aihtml_action:html(Ctx, {id, <<"mail-save-", (att_key(P))/binary>>},
                               ah_a([?I:icon(check, 14), <<"已保存 · 打开"/utf8>>], [<<"muse-mail-att-btn">>],
                                    [{href, <<"/documents/", FileId/binary>>}, {id, <<"mail-save-", (att_key(P))/binary>>}]),
                               outer);
        {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E))
    end;
%% composing
act(compose, _Args, Event, Ctx, Owner) ->
    #{account := A} = state(Event),
    ?K:done(Ctx, muse_mail_send:save_draft(Owner, new, #{<<"accountId">> => A}, <<"user">>),
            fun(D) -> open_compose(Ctx, Owner, D) end);
act(Mode, #{id := Id}, _Event, Ctx, Owner) when Mode =:= reply; Mode =:= reply_all; Mode =:= forward ->
    ?K:done(Ctx, muse_mail_send:reply_draft(Owner, Id, Mode), fun(D) -> open_compose(Ctx, Owner, D) end);
act(open_draft, #{id := Id}, _Event, Ctx, Owner) ->
    ?K:done(Ctx, muse_mail_send:get_draft(Owner, Id), fun(D) -> open_compose(Ctx, Owner, D) end);
act(save_draft, #{id := Id}, Event, Ctx, Owner) ->
    case muse_mail_send:save_draft(Owner, Id, form_draft(Event), <<"user">>) of
        {ok, _} ->
            aihtml_lib_overlay:close(Ctx, {id, ?WIN}),
            ?K:toast_ok(Ctx, <<"草稿已保存"/utf8>>),
            show(Ctx, Owner, state(Event), [rail, list]);
        {error, E} -> compose_error(Ctx, E)
    end;
act(send, #{id := Id}, Event, Ctx, Owner) ->
    Result = maybe
                 {ok, _} ?= muse_mail_send:save_draft(Owner, Id, form_draft(Event), <<"user">>),
                 muse_mail_send:send_draft(Owner, Id)
             end,
    case Result of
        {ok, _} ->
            aihtml_lib_overlay:close(Ctx, {id, ?WIN}),
            ?K:toast_ok(Ctx, <<"邮件已发送"/utf8>>),
            show(Ctx, Owner, state(Event), [rail, list]);
        {error, E} -> compose_error(Ctx, E)
    end;
act(discard, #{id := Id}, Event, Ctx, Owner) ->
    case muse_mail_send:delete_draft(Owner, Id) of
        ok ->
            aihtml_lib_overlay:close(Ctx, {id, ?WIN}),
            ?K:toast_ok(Ctx, <<"草稿已删除"/utf8>>),
            show(Ctx, Owner, state(Event), [rail, list]);
        {error, E} -> compose_error(Ctx, E)
    end;
act(add_file, #{id := Id}, Event, Ctx, Owner) ->
    case maps:get(value, Event, <<>>) of
        FileId when is_binary(FileId), FileId =/= <<>> ->
            Result = maybe
                         {ok, D} ?= muse_mail_send:get_draft(Owner, Id),
                         muse_mail_send:save_draft(Owner, Id,
                                                   #{<<"fileIds">> => lists:usort(maps:get(<<"fileIds">>, D, []) ++ [FileId])},
                                                   <<"user">>)
                     end,
            atts_result(Ctx, Owner, Result);
        _ -> ok
    end;
act(remove_attachment, #{id := Id, kind := Kind, ref := Ref}, _Event, Ctx, Owner) ->
    atts_result(Ctx, Owner, muse_mail_send:remove_attachment(Owner, Id, Kind, Ref));
act(uploaded, #{id := Id}, _Event, Ctx, Owner) ->
    atts_result(Ctx, Owner, muse_mail_send:get_draft(Owner, Id));
%% accounts
act(new_account, _Args, _Event, Ctx, _Owner) ->
    aihtml_action:html(Ctx, {id, ?ACC_FORM}, account_form(new, new_values()), inner),
    aihtml_action:focus(Ctx, {id, <<"mail-a-name">>});
act(edit_account, #{id := Id}, _Event, Ctx, Owner) ->
    ?K:done(Ctx, muse_mail_accounts:get(Owner, Id),
            fun(A) ->
                    aihtml_action:html(Ctx, {id, ?ACC_FORM}, account_form({edit, Id}, muse_mail_accounts:public(A)), inner)
            end);
act(cancel_account, _Args, _Event, Ctx, _Owner) ->
    aihtml_action:html(Ctx, {id, ?ACC_FORM}, [], inner);
act(preset, #{mode := Mode}, Event, Ctx, _Owner) ->
    Preset = ?K:form_text(Event, <<"preset">>),
    Current = form_account(Event),
    Values = maps:merge(maps:with([<<"name">>, <<"email">>, <<"username">>, <<"allowSelfSigned">>], Current),
                        (muse_mail_accounts:preset(Preset))#{<<"preset">> => Preset}),
    Values1 = case Preset of
                  <<"custom">> -> maps:merge(Current, Values);
                  _ -> Values
              end,
    aihtml_action:html(Ctx, {id, ?ACC_FORM},
                       account_form(case Mode of new -> new; Id -> {edit, Id} end, Values1), inner);
act(test_account, #{id := Id}, Event, Ctx, Owner) ->
    Key = case Id of new -> <<"new">>; _ -> Id end,
    Result = case muse_mail_accounts:test(Owner, Key, form_account(Event)) of
                 ok -> {success, <<"连接成功：IMAP 和 SMTP 都能登录。"/utf8>>};
                 {error, E} -> {error, ?K:error_text(E)}
             end,
    ?C:notice(Ctx, <<"mail-acc-result">>, Result);
act(save_account, #{id := Id}, Event, Ctx, Owner) ->
    Input = form_account(Event),
    Result = case Id of
                 new -> muse_mail_accounts:create(Owner, Input, #{});
                 _ -> muse_mail_accounts:update(Owner, Id, Input, #{})
             end,
    case Result of
        {ok, #{<<"id">> := AId}} ->
            aihtml_action:html(Ctx, {id, ?ACC_FORM}, [], inner),
            aihtml_action:html(Ctx, {id, ?ACC_LIST}, account_list(Owner), inner),
            _ = AId,
            ?K:toast_ok(Ctx, <<"邮箱账号已保存，正在同步"/utf8>>);
        {error, E} ->
            ?C:notice(Ctx, <<"mail-acc-result">>, {error, ?K:error_text(E)})
    end;
act(delete_account, #{id := Id}, _Event, Ctx, Owner) ->
    case muse_mail_accounts:delete(Owner, Id) of
        ok ->
            aihtml_action:html(Ctx, {id, ?ACC_LIST}, account_list(Owner), inner),
            aihtml_action:html(Ctx, {id, ?ACC_FORM}, [], inner),
            ?K:toast_ok(Ctx, <<"邮箱账号已删除"/utf8>>);
        {error, E} -> ?K:toast_error(Ctx, ?K:error_text(E))
    end;
act(sync_account, #{id := Id}, _Event, Ctx, Owner) ->
    muse_mail_sync:request_sync(Owner, Id),
    ?K:toast_ok(Ctx, <<"已开始同步"/utf8>>);
act(refresh_accounts, _Args, _Event, Ctx, Owner) ->
    aihtml_action:html(Ctx, {id, ?ACC_LIST}, account_list(Owner), inner).

after_change(Ctx, Owner, St, Result, Parts, Ok) ->
    case Result of
        {ok, _} ->
            _ = Ok =:= undefined orelse ?K:toast_ok(Ctx, Ok),
            show(Ctx, Owner, St, Parts),
            case maps:get(msg, St) of
                <<>> -> aihtml_action:replace_url(Ctx, url(St));
                _ -> ok
            end;
        {error, E} ->
            ?K:toast_error(Ctx, ?K:error_text(E))
    end.

compose_error(Ctx, E) ->
    aihtml_action:html(Ctx, {id, <<"mail-compose-error">>}, ah_alert(?K:error_text(E), [error], []), inner).

atts_result(Ctx, Owner, {ok, D}) ->
    aihtml_action:html(Ctx, {id, ?ATTS}, compose_attachments(Owner, D), inner);
atts_result(Ctx, _Owner, {error, E}) ->
    compose_error(Ctx, E).

%% Re-render the named panes and the state inputs.
show(Ctx, Owner, St, Parts) ->
    _ = [aihtml_action:html(Ctx, {id, ?RAIL}, rail_el(Owner, St), morph) || lists:member(rail, Parts)],
    _ = [aihtml_action:html(Ctx, {id, ?LIST}, list_el(Owner, St), morph) || lists:member(list, Parts)],
    _ = [aihtml_action:html(Ctx, {id, ?READER}, reader(Owner, St), inner) || lists:member(reader, Parts)],
    aihtml_action:html(Ctx, {id, ?STATE}, state_div(St), outer).

%%%===================================================================
%%% Live updates
%%%===================================================================

-spec on_event(binary(), term()) -> ok.
on_event(Owner, {mail, _}) ->
    ?K:publish(Owner, mail, fun(C) -> aihtml_action:trigger(C, {id, ?SYNC}, ?CHANGED, #{}) end);
on_event(_Owner, _Event) ->
    ok.
