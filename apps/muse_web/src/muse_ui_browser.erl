%% @doc Browser console `/browser/:id` (designs/05-web-ui.md §5,
%% tasks/M6-ui.md M6-6, M9-5, M9-16) over muse_browser and the owner's
%% Chrome container (one window per session).
%%
%% There is no browser page of its own (M9-5): browser sessions belong to
%% conversations and tasks. When a page needs a person (a sign-in, a
%% verification, a final confirmation) the chat agent asks for help in the
%% conversation (`request_takeover`), and its card links here; the
%% browse_web step and the task page link here too. `/browser` without an
%% id is a short empty state that says so and leads to the chat.
%%
%% `/browser/<id>` ("处理浏览器 · <site>") is where the user acts, the
%% aihtml counterpart of OpenMuse's browser-console page, under a one-line
%% hint and, for a conversation's session, a "回到对话" link
%% (muse_browser:thread_of/2):
%% - the screenshot `<img>` polls every 2 s (`poll/2`, only while the page
%%   is open and visible) for a fresh signed preview URL: that session's
%%   window only (captureVisibleTab of its tab, also when other windows
%%   cover it);
%% - pressing and releasing on it (`pointerdown`, `pointerup`, each with the
%%   event `pointer` scaled to the session's 1280x800 viewport) is a click,
%%   or a drag when the pointer moved 6 px or more (slider captchas): the
%%   press is kept by muse_browser_pool until the release. browserd raises
%%   that window and clicks or drags there with xdotool (direct input: a
%%   person, not the agent);
%% - the console frame is focusable and forwards each key
%%   (`sync => fifo`, so none is lost; Tab, Backspace, Enter, Space and the
%%   arrows are kept from the page): printable characters as text, the
%%   whitelisted keys as key presses;
%% - a text field, special-key and scroll buttons, read page text, import
%%   PDF downloads into Documents.
%%
%% Every action re-checks that the session belongs to the signed-in owner
%% (muse_browser:get/2 and the muse_browser operations themselves).
-module(muse_ui_browser).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, action/4, scale/1, key_input/2]).

-define(C, muse_ui_b_common).
-define(NOTICE, <<"browser-notice">>).
-define(SHOT, <<"browser-shot">>).
-define(VIEW_W, 1280).
-define(VIEW_H, 800).
%% the key whitelist (browserd, as the worker's browser.ts input)
-define(KEYS, [<<"Enter">>, <<"Tab">>, <<"Escape">>, <<"Backspace">>, <<"Delete">>, <<"ArrowUp">>,
               <<"ArrowDown">>, <<"ArrowLeft">>, <<"ArrowRight">>, <<"Home">>, <<"End">>,
               <<"PageUp">>, <<"PageDown">>]).
-define(PREVENT, [<<"Tab">>, <<"Backspace">>, <<"Enter">>, <<" ">>, <<"ArrowUp">>, <<"ArrowDown">>,
                  <<"ArrowLeft">>, <<"ArrowRight">>]).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    case ?C:path_id(Req) of
        undefined -> {<<>>, no_session()};
        Id ->
            case muse_browser:get(Owner, Id) of
                {ok, Session} -> {page_title(Session), console(Owner, Session)};
                {error, _} -> {<<>>, missing()}
            end
    end.

page_title(S) ->
    case site(S) of
        <<>> -> <<"处理浏览器"/utf8>>;
        Site -> <<"处理浏览器 · "/utf8, Site/binary>>
    end.

not_configured() ->
    ah_alert(<<"浏览器未启用：在配置里设置 BROWSER_ENABLED=true，并用 make browser-image 构建浏览器镜像后即可使用。"/utf8>>,
             [warning], [{id, <<"browser-unconfigured">>}, {title, <<"浏览器未配置"/utf8>>}]).

%% `/browser` without an id: sessions are opened from conversations.

no_session() ->
    ah_div([case muse_config:browser_configured() of
                true -> [];
                false -> not_configured()
            end,
            ah_card(ah_empty(ah_a(<<"去对话"/utf8>>, [<<"text-primary">>], [{href, <<"/chat">>}]), [],
                            [{title, <<"浏览器在对话里打开"/utf8>>},
                             {description, <<"智能体浏览网页时会使用这个对话自己的浏览器；需要你登录、验证或确认时，"
                                             "它会在对话里请你帮忙，并给出打开浏览器的链接。"/utf8>>}]),
                    [], [{id, <<"browser-none">>}])],
           [<<"muse-page">>], []).

host(Url) ->
    case uri_string:parse(Url) of
        #{host := H} when is_binary(H), H =/= <<>> -> H;
        _ -> Url
    end.

status_chip(<<"active">>) -> ?C:chip(<<"活动"/utf8>>, success);
status_chip(<<"idle">>) -> ?C:chip(<<"空闲"/utf8>>, default);
status_chip(<<"closed">>) -> ?C:chip(<<"已关闭"/utf8>>, default);
status_chip(<<"error">>) -> ?C:chip(<<"出错"/utf8>>, error);
status_chip(S) -> ?C:chip(S, default).

missing() ->
    ah_div(ah_card(ah_empty(ah_a(<<"去对话"/utf8>>, [<<"text-primary">>], [{href, <<"/chat">>}]), [],
                            [{title, <<"找不到该会话"/utf8>>},
                             {description, <<"会话不存在，或不属于当前账户。"/utf8>>}]), [], []),
           [<<"muse-page">>], []).

%% Console

console(Owner, #{<<"id">> := Id} = S) ->
    Configured = muse_config:browser_configured(),
    ah_div([ah_div([ah_div(header(S), [], [{id, <<"browser-header">>}]),
                    ah_div([ah_p(<<"在下面的画面里完成登录或验证，完成后回到对话点「处理好了，继续」。"/utf8>>,
                                 [<<"text-sm text-muted">>], [{id, <<"browser-hint">>}]),
                            back_link(Owner, Id)],
                           [<<"flex items-center justify-between gap-3 flex-wrap">>], [])],
                   [<<"flex flex-col gap-2">>], []),
            case Configured of
                true -> [];
                false -> not_configured()
            end,
            ?C:slot(?NOTICE),
            case Configured of
                false -> [];
                true ->
                    [ah_form([ah_input(maps:get(<<"url">>, S, <<>>), [<<"flex-1">>],
                                       [{name, url}, {type, url}, {required, true}, {aria_label, <<"地址"/utf8>>}]),
                              ah_button(<<"前往"/utf8>>, navigate, [outlined], [{type, submit}]),
                              ah_button(<<"关闭会话"/utf8>>, close, [borderless],
                                        [on(click, {?MODULE, close, #{id => Id}},
                                            #{confirm => #{title => <<"关闭会话"/utf8>>, body => <<"关闭这个浏览器会话？"/utf8>>,
                                                           ok => <<"关闭"/utf8>>, cancel => <<"取消"/utf8>>}})])],
                             [<<"flex gap-2">>],
                             [{id, <<"browser-nav">>}, on(submit, {?MODULE, navigate, #{id => Id}})]),
                     ah_form([ah_input(<<>>, [<<"flex-1">>],
                                       [{name, text}, {id, <<"browser-text-input">>}, {autocomplete, off},
                                        {placeholder, <<"输入要键入到所选字段的文字"/utf8>>}]),
                              ah_button(<<"发送文字"/utf8>>, type, [primary], [{type, submit}])],
                             [<<"flex gap-2">>],
                             [{id, <<"browser-type">>}, on(submit, {?MODULE, type, #{id => Id}})]),
                     ah_div([[key_button(Id, K, L) || {K, L} <- [{<<"Enter">>, <<"Enter ↵"/utf8>>},
                                                                 {<<"Tab">>, <<"Tab ⇥"/utf8>>},
                                                                 {<<"Escape">>, <<"Esc">>},
                                                                 {<<"Backspace">>, <<"删除 ⌫"/utf8>>},
                                                                 {<<"ArrowUp">>, <<"↑"/utf8>>},
                                                                 {<<"ArrowDown">>, <<"↓"/utf8>>},
                                                                 {<<"ArrowLeft">>, <<"←"/utf8>>},
                                                                 {<<"ArrowRight">>, <<"→"/utf8>>}]],
                             ah_button(<<"向上滚动"/utf8>>, up, [outlined, sm],
                                       [on(click, {?MODULE, scroll, #{id => Id, delta => -600}})]),
                             ah_button(<<"向下滚动"/utf8>>, down, [outlined, sm],
                                       [on(click, {?MODULE, scroll, #{id => Id, delta => 600}})]),
                             ah_button(<<"读取正文"/utf8>>, read, [outlined, sm],
                                       [on(click, {?MODULE, read, #{id => Id}}, #{indicator => this})]),
                             ah_button(<<"导入下载"/utf8>>, imports, [outlined, sm],
                                       [on(click, {?MODULE, imports, #{id => Id}}, #{indicator => this})])],
                            [<<"flex gap-2 flex-wrap">>], [{id, <<"browser-keys">>}]),
                     ah_div([ah_img([<<"muse-shot block w-full h-auto">>],
                                    [{id, ?SHOT}, {src, preview(Owner, Id)}, {draggable, false},
                                     {alt, <<"远程浏览器画面，点击进行交互"/utf8>>},
                                     aihtml:poll(2000, {?MODULE, shot, #{id => Id}}),
                                     %% press + release: a click, or a drag (sliders)
                                     on(pointerdown, {?MODULE, pointer_down, #{id => Id}},
                                        #{sync => fifo, prevent_default => true}),
                                     on(pointerup, {?MODULE, pointer_up, #{id => Id}},
                                        #{sync => fifo, prevent_default => true})])],
                            [<<"rounded border border-line overflow-hidden bg-surface focus:outline-none focus:ring-2 focus:ring-primary">>],
                            [{id, <<"browser-stage">>}, {tabindex, 0},
                             {aria_label, <<"浏览器画面：聚焦后键入的按键会转发到远程页面"/utf8>>},
                             on(keydown, {?MODULE, key, #{id => Id}},
                                #{sync => fifo, prevent_default => ?PREVENT})]),
                     ah_p(<<"点击画面选中字段，然后直接键入（按键逐个转发），或在上方输入整段文字。"/utf8>>,
                          [<<"text-xs text-muted">>], []),
                     ah_div([], [<<"flex flex-col gap-3">>], [{id, <<"browser-output">>}])]
            end],
           [<<"muse-page">>], []).

%% "处理浏览器 · <site>", the status, then the page title and address.
header(S) ->
    ah_div([ah_h1(page_title(S), [<<"text-xl font-semibold break-all">>], []),
            status_chip(maps:get(<<"status">>, S, <<>>)),
            ah_span([case maps:get(<<"title">>, S, <<>>) of
                         <<>> -> [];
                         <<"New browser session">> -> [];
                         T -> [T, <<" · "/utf8>>]
                     end, maps:get(<<"url">>, S, <<>>)],
                    [<<"text-sm text-muted break-all">>], [])],
           [<<"flex items-center gap-3 flex-wrap">>], []).

site(S) ->
    case host(maps:get(<<"url">>, S, <<>>)) of
        <<"www.", Rest/binary>> -> Rest;
        H -> H
    end.

%% "回到对话" when the session is a conversation's.
back_link(Owner, Id) ->
    case conversation(Owner, Id) of
        {ok, Tid} ->
            ah_a(<<"← 回到对话"/utf8>>, [<<"text-sm text-primary hover:underline">>],
                 [{href, <<"/chat/", Tid/binary>>}, {id, <<"browser-back">>}]);
        undefined -> []
    end.

conversation(Owner, Id) ->
    case muse_browser:thread_of(Owner, Id) of
        {ok, Tid} ->
            case muse_threads:get(Owner, Tid) of
                {ok, _} -> {ok, Tid};
                _ -> undefined
            end;
        undefined -> undefined
    end.

key_button(Id, Key, Label) ->
    ah_button(Label, Key, [outlined, sm], [on(click, {?MODULE, press, #{id => Id, key => Key}})]).

%% A same-origin signed screenshot URL (15 min).
preview(Owner, Id) ->
    muse_signing:signed_path(Owner, <<"/api/browsers/", Id/binary, "/preview">>).

%% Actions

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(shot, #{id := Id}, _Event, Ctx) ->
    owned(Ctx, Id, fun(Owner, _) -> aihtml_action:attr(Ctx, {id, ?SHOT}, src, preview(Owner, Id)) end);
action(click, #{id := Id}, Event, Ctx) ->
    case scale(maps:get(pointer, Event, null)) of
        {X, Y} -> input(Ctx, Id, #{<<"type">> => <<"click">>, <<"x">> => X, <<"y">> => Y});
        undefined -> ok
    end;
action(pointer_down, #{id := Id}, Event, Ctx) ->
    case scale(maps:get(pointer, Event, null)) of
        {X, Y} -> owned(Ctx, Id, fun(Owner, _) -> muse_browser_pool:press(Owner, Id, {X, Y}) end);
        undefined -> ok
    end;
action(pointer_up, #{id := Id}, Event, Ctx) ->
    case scale(maps:get(pointer, Event, null)) of
        {X, Y} ->
            owned(Ctx, Id,
                  fun(Owner, _) ->
                          input(Ctx, Id, case muse_browser_pool:release(Owner, Id) of
                                             {X0, Y0} when abs(X - X0) + abs(Y - Y0) >= 6 ->
                                                 #{<<"type">> => <<"drag">>, <<"x">> => X0, <<"y">> => Y0,
                                                   <<"toX">> => X, <<"toY">> => Y};
                                             _ ->
                                                 #{<<"type">> => <<"click">>, <<"x">> => X, <<"y">> => Y}
                                         end)
                  end);
        undefined -> ok
    end;
action(key, #{id := Id}, #{key := Key} = Event, Ctx) ->
    case key_input(Key, maps:get(mods, Event, null)) of
        undefined -> ok;
        Input -> input(Ctx, Id, Input)
    end;
action(press, #{id := Id, key := Key}, _Event, Ctx) ->
    input(Ctx, Id, #{<<"type">> => <<"key">>, <<"key">> => Key});
action(scroll, #{id := Id, delta := Delta}, _Event, Ctx) ->
    input(Ctx, Id, #{<<"type">> => <<"scroll">>, <<"deltaY">> => Delta});
action(type, #{id := Id}, #{form := Form}, Ctx) ->
    case maps:get(<<"text">>, Form, <<>>) of
        <<>> -> ok;
        Text ->
            case input(Ctx, Id, #{<<"type">> => <<"text">>, <<"text">> => Text}) of
                ok -> aihtml_action:set_value(Ctx, {id, <<"browser-text-input">>}, <<>>);
                error -> ok
            end
    end;
action(navigate, #{id := Id}, #{form := Form}, Ctx) ->
    owned(Ctx, Id, fun(Owner, _) ->
                           Url = string:trim(maps:get(<<"url">>, Form, <<>>)),
                           Result = case muse_validate:parse({string, #{url => true, max => 4096}}, Url) of
                                        {ok, Valid} -> muse_browser:navigate(Owner, Id, Valid);
                                        {error, _} -> {error, {422, <<"请输入有效的网址（http 或 https）。"/utf8>>}}
                                    end,
                           session_result(Ctx, Owner, Id, Result)
                   end);
action(close, #{id := Id}, _Event, Ctx) ->
    owned(Ctx, Id, fun(Owner, _) ->
                           case muse_browser:close(Owner, Id) of
                               {ok, _} ->
                                   aihtml_action:redirect(Ctx, case conversation(Owner, Id) of
                                                                   {ok, Tid} -> <<"/chat/", Tid/binary>>;
                                                                   undefined -> <<"/chat">>
                                                               end);
                               Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                           end
                   end);
action(read, #{id := Id}, _Event, Ctx) ->
    owned(Ctx, Id, fun(Owner, _) ->
                           case muse_browser:read(Owner, Id) of
                               {ok, #{<<"title">> := T, <<"url">> := U, <<"text">> := Text} = Page} ->
                                   ?C:notice(Ctx, ?NOTICE, clear),
                                   aihtml_action:html(Ctx, {id, <<"browser-output">>},
                                                      ah_card(ah_pre(Text, [<<"whitespace-pre-wrap text-sm max-h-[50vh] overflow-auto">>],
                                                                     [{id, <<"browser-page-text">>}]),
                                                              [], [{title, T},
                                                                   {subtitle, [U, case maps:get(<<"truncated">>, Page, false) of
                                                                                      true -> <<" · 正文已截断"/utf8>>;
                                                                                      _ -> <<>>
                                                                                  end]}]));
                               Error ->
                                   ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                           end
                   end);
action(imports, #{id := Id}, _Event, Ctx) ->
    owned(Ctx, Id, fun(Owner, _) ->
                           case muse_browser:imports(Owner, Id) of
                               {ok, #{<<"files">> := Files} = R} ->
                                   Failures = maps:get(<<"failures">>, R, []),
                                   aihtml_action:html(Ctx, {id, <<"browser-output">>}, imports_html(Files, Failures));
                               Error ->
                                   ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                           end
                   end).

imports_html([], []) ->
    ?C:notice_html(info, <<"这个会话还没有可导入的 PDF 下载。"/utf8>>);
imports_html(Files, Failures) ->
    ah_card([ah_ul([ah_li(ah_a(Name, [<<"text-primary hover:underline">>], [{href, <<"/documents/", FId/binary>>}]), [], [])
                    || #{<<"id">> := FId, <<"name">> := Name} <- Files], [<<"flex flex-col gap-1">>],
                   [{id, <<"browser-imported">>}]),
             [ah_p([maps:get(<<"name">>, F, <<>>), <<"：", (maps:get(<<"message">>, F, <<>>))/binary>>],
                   [<<"text-sm text-muted">>], []) || F <- Failures, is_map(F)]],
            [], [{title, <<"已导入到文档"/utf8>>}]).

%% Forward one input; the screenshot is refreshed right away.
input(Ctx, Id, Input) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_browser:input(Owner, Id, Input) of
                       {ok, Session} ->
                           aihtml_action:html(Ctx, {id, <<"browser-header">>}, header(Session)),
                           aihtml_action:attr(Ctx, {id, ?SHOT}, src, preview(Owner, Id)),
                           ok;
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)}),
                           error
                   end
           end).

session_result(Ctx, Owner, Id, Result) ->
    case Result of
        {ok, Session} ->
            ?C:notice(Ctx, ?NOTICE, clear),
            aihtml_action:html(Ctx, {id, <<"browser-header">>}, header(Session)),
            aihtml_action:attr(Ctx, {id, ?SHOT}, src, preview(Owner, Id));
        Error ->
            ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
    end.

owned(Ctx, Id, Fun) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_browser:get(Owner, Id) of
                       {ok, Session} -> Fun(Owner, Session);
                       Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end).

%% @doc Event `pointer` (offset in the displayed image) -> session viewport
%% coordinates. The displayed point maps to the screenshot's natural pixels
%% (`natural_w/h` when the image reports them, else the displayed size),
%% and those to the 1280x800 viewport; the result is clamped into it.
-spec scale(term()) -> {0..1279, 0..799} | undefined.
scale(#{<<"x">> := X, <<"y">> := Y, <<"w">> := W, <<"h">> := H} = P)
  when is_number(X), is_number(Y), is_number(W), is_number(H), W > 0, H > 0 ->
    NW = natural(maps:get(<<"natural_w">>, P, undefined), W),
    NH = natural(maps:get(<<"natural_h">>, P, undefined), H),
    {clamp(floor(X * NW / W * ?VIEW_W / NW), ?VIEW_W - 1),
     clamp(floor(Y * NH / H * ?VIEW_H / NH), ?VIEW_H - 1)};
scale(_) ->
    undefined.

natural(N, _) when is_number(N), N > 0 -> N;
natural(_, Shown) -> Shown.

clamp(V, Max) -> max(0, min(Max, V)).

%% @doc One keydown -> one browser input: the whitelisted keys (plus
%% Shift+Tab and Ctrl/Cmd+A) as key presses, a single printable character
%% as text, anything else (modifier combos, F-keys, dead keys) ignored.
-spec key_input(term(), term()) -> map() | undefined.
key_input(Key, Mods) when is_binary(Key) ->
    Flag = fun(K) -> is_map(Mods) andalso maps:get(K, Mods, false) =:= true end,
    Ctrl = Flag(<<"ctrl">>),
    Meta = Flag(<<"meta">>),
    Alt = Flag(<<"alt">>),
    if
        Key =:= <<"a">>, Ctrl -> key(<<"Control+a">>);
        Key =:= <<"a">>, Meta -> key(<<"Meta+a">>);
        Key =:= <<"Tab">> -> case Flag(<<"shift">>) of
                                 true -> key(<<"Shift+Tab">>);
                                 false -> key(Key)
                             end;
        Ctrl; Meta; Alt -> undefined;
        true ->
            case lists:member(Key, ?KEYS) of
                true -> key(Key);
                false ->
                    case string:length(Key) of
                        1 -> #{<<"type">> => <<"text">>, <<"text">> => Key};
                        _ -> undefined
                    end
            end
    end;
key_input(_, _) ->
    undefined.

key(K) -> #{<<"type">> => <<"key">>, <<"key">> => K}.
