%% @doc Apps page `/apps` (designs/05-web-ui.md §5, tasks/M6-ui.md M6-6):
%% Gmail and Google Calendar connection status, connect with read-only or
%% read-write scopes, disconnect; plus the browser worker's status.
%%
%% Connect and disconnect follow `POST /api/google/connect|disconnect`
%% (muse_api_integ): sample mode toggles the local sample connection; live
%% mode sends the browser to Google's consent page
%% (muse_google_auth:connect/2) and revokes on disconnect.
-module(muse_ui_apps).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, action/4]).

-define(C, muse_ui_b_common).
-define(BODY, <<"apps-body">>).
-define(NOTICE, <<"apps-notice">>).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    {<<>>, ah_div([?C:page_header(<<"应用连接"/utf8>>, <<"把 Gmail 和 Google 日历接入对话；先授权只读，需要时再启用发送与编辑。"/utf8>>),
                   ?C:slot(?NOTICE),
                   ah_div(body(Owner), [<<"flex flex-col gap-6">>], [{id, ?BODY}])],
                  [<<"muse-page">>], [])}.

%% `{Status, Account, Scopes}`: Status is connected | sample | disconnected.
google(Owner) ->
    case muse_config:get(mode) of
        sample ->
            case muse_workspace:connection(Owner) of
                undefined -> {disconnected, undefined, []};
                #{account := Account} -> {sample, Account, [<<"Gmail">>, <<"Calendar">>]}
            end;
        live ->
            case muse_google_auth:connection(Owner) of
                {ok, #{} = C} ->
                    {connected, maps:get(<<"account">>, C, undefined), scopes(maps:get(<<"scopes">>, C, []))};
                _ ->
                    {disconnected, undefined, []}
            end
    end.

scopes(L) when is_list(L) -> [S || S <- L, is_binary(S)];
scopes(_) -> [].

body(Owner) ->
    {Status, Account, Scopes} = google(Owner),
    Connected = Status =/= disconnected,
    Sample = muse_config:get(mode) =:= sample,
    [ah_card([ah_ul([app_row(<<"Gmail">>, <<"读取邮件、起草并（获批后）发送邮件"/utf8>>, Status,
                             [S || S <- Scopes, is_gmail(S)]),
                     app_row(<<"Google 日历"/utf8>>, <<"读取日程，（获批后）创建或修改事件"/utf8>>, Status,
                             [S || S <- Scopes, is_calendar(S)])],
                    [<<"flex flex-col divide-y divide-line">>], [{id, <<"apps-google">>}]),
              case Account of
                  undefined -> [];
                  _ -> ah_p([<<"账户："/utf8>>, Account], [<<"text-sm text-muted">>], [{id, <<"apps-account">>}])
              end,
              case Sample of
                  true -> ah_p(<<"示例模式：连接使用本地示例数据，不会访问真实的 Google 账户。"/utf8>>,
                               [<<"text-sm text-muted">>], []);
                  false -> []
              end,
              ah_div([ah_button(<<"连接（只读）"/utf8>>, read, [primary, sm],
                                [{id, <<"apps-connect-read">>},
                                 on(click, {?MODULE, connect, #{capability => read}}, #{indicator => this})]),
                      ah_button(<<"启用发送与编辑（读写）"/utf8>>, write, [outlined, sm],
                                [{id, <<"apps-connect-write">>},
                                 on(click, {?MODULE, connect, #{capability => write}}, #{indicator => this})]),
                      [ah_button(<<"断开 Google"/utf8>>, disconnect, [error, sm],
                                 [{id, <<"apps-disconnect">>},
                                  on(click, {?MODULE, disconnect, #{}},
                                     #{confirm => <<"断开 Google 后，智能体将无法读取邮件和日历。确定吗？"/utf8>>})])
                       || Connected]],
                     [<<"flex gap-2 flex-wrap">>], [])],
             [], [{title, <<"Google"/utf8>>}]),
     ah_card(ah_ul([other_row(<<"智能体浏览器"/utf8>>, browser_status(),
                              ah_a(<<"打开"/utf8>>, [<<"text-sm text-primary">>], [{href, <<"/browser">>}])),
                    other_row(<<"Linux 电脑"/utf8>>, computer_status(Owner),
                              ah_a(<<"打开"/utf8>>, [<<"text-sm text-primary">>], [{href, <<"/computer">>}]))],
                   [<<"flex flex-col divide-y divide-line">>], []),
             [], [{title, <<"其他连接"/utf8>>}])].

app_row(Name, Desc, Status, Scopes) ->
    ah_li([ah_div([ah_div(Name, [<<"font-medium">>], []),
                   ah_div(Desc, [<<"text-xs text-muted">>], []),
                   case Scopes of
                       [] -> [];
                       _ -> ah_div([ah_chip(scope_label(S), [outlined, small], []) || S <- Scopes],
                                   [<<"flex gap-1 flex-wrap mt-1">>], [])
                   end],
                  [<<"flex flex-col min-w-0">>], []),
           case Status of
               connected -> ?C:chip(<<"已连接"/utf8>>, success);
               sample -> ?C:chip(<<"示例数据"/utf8>>, info);
               disconnected -> ?C:chip(<<"未连接"/utf8>>, default)
           end],
          [<<"py-3 flex items-center justify-between gap-3">>], []).

other_row(Name, Chip, Link) ->
    ah_li([ah_div(Name, [<<"font-medium">>], []), ah_div([Chip, Link], [<<"flex items-center gap-3">>], [])],
          [<<"py-3 flex items-center justify-between gap-3">>], []).

browser_status() ->
    case muse_config:browser_configured() of
        false -> ?C:chip(<<"未配置"/utf8>>, default);
        true ->
            case muse_browser:reachable() of
                true -> ?C:chip(<<"可用"/utf8>>, success);
                false -> ?C:chip(<<"无法连接"/utf8>>, warning)
            end
    end.

computer_status(Owner) ->
    case muse_computer:snapshot(Owner) of
        #{<<"status">> := <<"unconfigured">>} -> ?C:chip(<<"未配置"/utf8>>, default);
        #{<<"status">> := <<"running">>} -> ?C:chip(<<"运行中"/utf8>>, success);
        #{<<"status">> := <<"error">>} -> ?C:chip(<<"出错"/utf8>>, error);
        _ -> ?C:chip(<<"已停止"/utf8>>, default)
    end.

is_gmail(S) -> binary:match(S, <<"gmail">>) =/= nomatch orelse S =:= <<"Gmail">>.
is_calendar(S) -> binary:match(S, <<"calendar">>) =/= nomatch orelse S =:= <<"Calendar">>.

%% OpenMuse capabilityLabel.
scope_label(Scope) ->
    case lists:last(binary:split(Scope, <<"/">>, [global])) of
        <<"gmail.readonly">> -> <<"读取 Gmail"/utf8>>;
        <<"gmail.send">> -> <<"发送 Gmail"/utf8>>;
        <<"calendar.events.readonly">> -> <<"读取日历事件"/utf8>>;
        <<"calendar.calendarlist.readonly">> -> <<"读取日历列表"/utf8>>;
        <<"calendar.events">> -> <<"管理日历事件"/utf8>>;
        <<"calendar.readonly">> -> <<"读取日历"/utf8>>;
        <<"Gmail">> -> <<"示例邮件"/utf8>>;
        <<"Calendar">> -> <<"示例日程"/utf8>>;
        Other -> Other
    end.

%% Actions

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(connect, #{capability := Capability}, _Event, Ctx) when Capability =:= read; Capability =:= write ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_config:get(mode) of
                       sample ->
                           _ = muse_store:put(Owner, <<"settings">>,
                                              #{<<"id">> => <<"google">>, <<"enabled">> => true,
                                                <<"connectionId">> => muse_ids:uuid()}),
                           ?C:notice(Ctx, ?NOTICE, {success, <<"本地示例 Google 数据已就绪。"/utf8>>}),
                           aihtml_action:html(Ctx, {id, ?BODY}, body(Owner));
                       live ->
                           case muse_google_auth:connect(Owner, Capability =:= write) of
                               {ok, #{<<"url">> := Url}} -> aihtml_action:redirect(Ctx, Url);
                               Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                           end
                   end
           end);
action(disconnect, _Args, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = case muse_config:get(mode) of
                                sample ->
                                    _ = muse_store:put(Owner, <<"settings">>,
                                                       #{<<"id">> => <<"google">>, <<"enabled">> => false}),
                                    ok;
                                live ->
                                    muse_google_auth:disconnect(Owner)
                            end,
                   case Result of
                       ok -> ?C:notice(Ctx, ?NOTICE, {success, <<"Google 已断开。"/utf8>>});
                       Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end,
                   aihtml_action:html(Ctx, {id, ?BODY}, body(Owner))
           end).
