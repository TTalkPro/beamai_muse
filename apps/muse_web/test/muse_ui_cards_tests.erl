%% Tool cards and the Jev choice panel render from tool results.
-module(muse_ui_cards_tests).
-include_lib("eunit/include/eunit.hrl").

html(El) -> iolist_to_binary(aihtml_html:render(El)).

has(Html, Part) -> binary:match(Html, Part) =/= nomatch.

card(Name, Args, Result) ->
    html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, Name, Args, muse_json:encode(Result))).

cards_test_() ->
    [?_assert(has(html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"search_web">>, #{}, pending)), <<"id=\"tc-c1\"">>)),
     ?_assert(has(card(<<"search_web">>, #{}, #{<<"results">> => [#{<<"title">> => <<"Vet">>, <<"url">> => <<"https://v.example">>}]}),
                  <<"href=\"https://v.example\"">>)),
     ?_assert(has(card(<<"browse_web">>, #{}, #{<<"title">> => <<"Example">>, <<"url">> => <<"https://example.com">>,
                                                <<"sessionId">> => <<"b1">>}), <<"/browser/b1">>)),
     ?_assert(has(card(<<"run_computer_command">>, #{<<"command">> => <<"ls /workspace">>},
                       #{<<"exitCode">> => 0, <<"stdout">> => <<"a.txt">>}), <<"ls /workspace">>)),
     %% one line each: what happened, then the details on demand
     ?_assert(has(card(<<"search_web">>, #{}, #{<<"results">> => [#{<<"title">> => <<"Vet">>, <<"url">> => <<"https://v.example">>}]}),
                  <<"搜索了网页 · 1 个来源"/utf8>>)),
     ?_assert(has(card(<<"browse_web">>, #{}, #{<<"title">> => <<"Example">>, <<"url">> => <<"https://www.example.com/a">>,
                                                <<"text">> => <<"Skip to main content">>}), <<"已浏览 · <strong>example.com</strong>"/utf8>>)),
     %% page text is for the model, not the chat
     ?_assertNot(has(card(<<"browse_web">>, #{}, #{<<"title">> => <<"Example">>, <<"url">> => <<"https://example.com">>,
                                                   <<"text">> => <<"Skip to main content">>}), <<"Skip to main content">>)),
     ?_assert(has(card(<<"run_computer_command">>, #{<<"command">> => <<"false">>},
                       #{<<"status">> => <<"failed">>, <<"exitCode">> => 1}), <<"data-state=\"failed\"">>)),
     ?_assert(has(card(<<"search_web">>, #{}, #{<<"error">> => <<"Parallel search timed out after 45 seconds">>}),
                  <<"网页搜索失败"/utf8>>)),
     ?_assert(has(html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"search_web">>, #{}, pending)),
                  <<"正在搜索网页"/utf8>>)),
     ?_assert(has(card(<<"unknown_tool">>, #{}, #{<<"x">> => 1}), <<"&quot;x&quot;">>)),
     %% a broken result never crashes the card
     ?_assert(has(html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"browse_web">>, #{}, <<"not json">>)),
                  <<"not json">>))].

%% The browser help request: a full card with the kind's title, the reason,
%% the site, the console link (new tab) and "处理好了，继续".
takeover_test() ->
    Result = #{<<"sessionId">> => <<"b1">>, <<"kind">> => <<"login">>, <<"reason">> => <<"The shop asks you to sign in">>,
               <<"url">> => <<"https://www.shop.example/login">>, <<"consoleUrl">> => <<"/browser/b1">>},
    Html = card(<<"request_takeover">>, #{}, Result),
    [?assert(has(Html, P), P) || P <- [<<"id=\"tc-c1\"">>, <<"muse-takeover">>, <<"需要你登录"/utf8>>,
                                       <<"The shop asks you to sign in">>, <<"shop.example">>,
                                       <<"href=\"/browser/b1\"">>, <<"target=\"_blank\"">>, <<"打开浏览器处理"/utf8>>,
                                       <<"id=\"tc-c1-go\"">>, <<"处理好了，继续"/utf8>>, <<"data-ah-on">>]],
    ?assertNot(has(Html, <<"<details">>)),
    Title = fun(Kind) -> card(<<"request_takeover">>, #{}, Result#{<<"kind">> => Kind}) end,
    ?assert(has(Title(<<"verification">>), <<"需要你完成验证"/utf8>>)),
    ?assert(has(Title(<<"confirm">>), <<"需要你确认"/utf8>>)),
    ?assert(has(Title(<<"other">>), <<"需要你来处理"/utf8>>)),
    %% once the conversation went on, the button shows as done
    Done = html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"request_takeover">>, #{},
                                     muse_json:encode(Result), #{answered => true})),
    ?assert(has(Done, <<"已通知继续"/utf8>>)),
    ?assert(has(Done, <<"disabled">>)),
    ?assertNot(has(Done, <<"处理好了，继续"/utf8>>)),
    ?assert(has(Done, <<"href=\"/browser/b1\"">>)),
    %% while it runs, and when it failed: a one-line step
    ?assert(has(html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"request_takeover">>, #{}, pending)),
                <<"正在打开浏览器"/utf8>>)),
    Failed = card(<<"request_takeover">>, #{}, #{<<"error">> => <<"Browser worker is unavailable.">>}),
    ?assert(has(Failed, <<"没能打开浏览器"/utf8>>)),
    ?assert(has(Failed, <<"data-state=\"failed\"">>)),
    %% the browse_web step keeps a small link to the console
    ?assert(has(card(<<"browse_web">>, #{}, #{<<"title">> => <<"Example">>, <<"url">> => <<"https://example.com">>,
                                               <<"sessionId">> => <<"b1">>}), <<"打开这个浏览器 ›"/utf8>>)),
    %% reading where the person left the browser: a one-line step like browse_web
    Read = card(<<"read_current_page">>, #{}, #{<<"title">> => <<"Paid">>, <<"url">> => <<"https://shop.example/done">>,
                                                <<"sessionId">> => <<"b1">>, <<"text">> => <<"Order 42">>}),
    ?assert(has(Read, <<"读取了当前页面 · <strong>shop.example</strong>"/utf8>>)),
    ?assert(has(Read, <<"href=\"/browser/b1\"">>)),
    ?assertNot(has(Read, <<"Order 42">>)),
    ?assert(has(html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"read_current_page">>, #{}, pending)),
                <<"正在读取当前页面"/utf8>>)),
    ?assert(has(card(<<"read_current_page">>, #{}, #{<<"error">> => <<"no page">>}), <<"没能读取当前页面"/utf8>>)).

choice_panel_test() ->
    Panel = #{<<"id">> => <<"p1">>, <<"threadId">> => <<"t">>, <<"candidateSetVersion">> => 2,
              <<"title">> => <<"Which vet?">>,
              <<"options">> => [#{<<"id">> => <<"a">>, <<"label">> => <<"Clinic A">>, <<"details">> => [<<"Open late">>],
                                  <<"sources">> => [#{<<"title">> => <<"Site">>, <<"url">> => <<"https://a.example">>}]},
                                #{<<"id">> => <<"b">>, <<"label">> => <<"Clinic B">>, <<"details">> => [], <<"sources">> => []}]},
    Open = html(muse_ui_chat:choice_panel(<<"t">>, Panel)),
    ?assert(has(Open, <<"Clinic A">>)),
    ?assert(has(Open, <<"data-ah-on">>)),
    Chosen = html(muse_ui_chat:choice_panel(<<"t">>, Panel#{<<"selectedId">> => <<"a">>})),
    ?assertNot(has(Chosen, <<"data-ah-on">>)),
    ?assert(has(Chosen, <<"已选择"/utf8>>)).
