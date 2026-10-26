%% Tool cards and the Jev choice panel render from tool results.
-module(muse_ui_cards_tests).
-include_lib("eunit/include/eunit.hrl").

html(El) -> iolist_to_binary(aihtml_html:render(El)).

has(Html, Part) -> binary:match(Html, Part) =/= nomatch.

card(Name, Args, Result) ->
    html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, Name, Args, muse_json:encode(Result))).

cards_test_() ->
    [?_assert(has(html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"search_mail">>, #{}, pending)), <<"id=\"tc-c1\"">>)),
     ?_assert(has(card(<<"search_mail">>, #{}, #{<<"matches">> => [#{<<"sender">> => <<"Ms. Rivera">>, <<"subject">> => <<"Field trip">>}],
                                                 <<"truncated">> => true}), <<"Ms. Rivera">>)),
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
     ?_assert(has(html(muse_ui_cards:render(<<"o">>, <<"t">>, <<"c1">>, <<"read_calendar">>, #{}, <<"not json">>)),
                  <<"not json">>))].

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
