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
     ?_assert(has(card(<<"computer_exec">>, #{<<"command">> => <<"ls /workspace">>},
                       #{<<"exitCode">> => 0, <<"stdout">> => <<"a.txt">>}), <<"ls /workspace">>)),
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
