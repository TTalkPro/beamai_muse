-module(muse_jev_tests).
-include_lib("eunit/include/eunit.hrl").

%% Ports of OpenMuse tests/jev.test.ts, tests/jev-persistence.test.ts and the
%% service-level parts of tests/conversation-jev.test.ts (sample mode, plus
%% the live grounding checks, which only read stored evidence). Reference
%% vectors come from Node 24 running the original code.

-define(O, <<"owner">>).
-define(T, <<"thread">>).

%% Fixtures

src(Title, Url) -> #{<<"title">> => Title, <<"url">> => Url}.

opt(Id, Label, Details, Url, Title) ->
    #{<<"id">> => Id, <<"label">> => Label, <<"details">> => Details,
      <<"sources">> => [src(Title, Url)]}.

options() ->
    [opt(<<"a">>, <<"Kelp Forest">>, [<<"Forest">>], <<"https://example.org/kelp">>, <<"Kelp">>),
     opt(<<"b">>, <<"Rocky Shore">>, [<<"Touch pool">>], <<"https://example.org/rocky">>, <<"Rocky">>)].

four() ->
    options() ++
        [opt(<<"c">>, <<"Open Sea">>, [<<"Far views">>], <<"https://example.org/sea">>, <<"Sea">>),
         opt(<<"d">>, <<"Birds">>, [<<"Birds">>], <<"https://example.org/birds">>, <<"Birds">>)].

args() ->
    #{<<"message">> => <<"Compare">>, <<"context">> => <<"Observed pages">>,
      <<"title">> => <<"Exhibits">>, <<"control">> => <<"comparison">>,
      <<"options">> => options()}.

%% Scores by index, as the persistence tests' adapter.
by_index() ->
    fun(#{<<"options">> := Os}) ->
            {ok, #{<<"control">> => <<"comparison">>,
                   <<"scores">> => maps:from_list(lists:zip([I || #{<<"id">> := I} <- Os],
                                                            lists:seq(0, length(Os) - 1)))}}
    end.

constant(Control, Scores) -> fun(_) -> {ok, #{<<"control">> => Control, <<"scores">> => Scores}} end.

create(Turn, Args) -> create(Turn, Args, by_index()).

create(Turn, Args, Adapter) ->
    muse_jev:create_panel(?O, ?T, Turn, Args, #{adapter => Adapter, mode => sample}).

panel_of({ok, #{<<"panel">> := P}}) when is_map(P) -> P.

action(#{<<"id">> := Id, <<"candidateSetVersion">> := V}, Option) ->
    #{<<"panelId">> => Id, <<"threadId">> => ?T, <<"candidateSetVersion">> => V,
      <<"optionId">> => Option}.

continuation({ok, #{<<"continuation">> := C}}) -> C.

head() -> muse_store:get(?O, <<"jev_threads">>, ?T).

store_test_() ->
    {foreach,
     fun() ->
             ok = muse_store:init(#{storage => ram}),
             {ok, C} = muse_config:from_env(#{<<"JEV_MODE">> => <<"sample">>}),
             muse_config:set(C)
     end,
     fun(_) ->
             catch meck:unload(muse_store),
             muse_store:stop()
     end,
     [fun conflicts/0, fun supersede/0, fun refinement/0, fun aborted/0, fun preserve/0,
      fun stale_refinement/0, fun refine_after_select/0, fun sources/0, fun evidence/0,
      fun select_race/0, fun pre_reserve_race/0, fun evidence_text/0, fun agent_expire/0,
      fun turn_expiry/0, fun retired_refine/0, fun tool_sample/0, fun choice_dispatch/0,
      fun live_grounding/0, fun live_mail/0, fun live_refinement/0, fun panel_view/0,
      fun user_message/0]}.

%% "panels survive restart and reject owner, thread, option, version and replay conflicts"
conflicts() ->
    P = panel_of(create(<<"turn">>, args())),
    A = action(P, <<"b">>),
    ?assertMatch({error, _}, muse_jev:select(<<"other">>, ?T, A)),
    ?assertEqual({error, <<"This choice belongs to another conversation">>},
                 muse_jev:select(?O, <<"other-thread">>, A)),
    ?assertEqual({error, <<"This option is unavailable">>},
                 muse_jev:select(?O, ?T, A#{<<"optionId">> => <<"missing">>})),
    ?assertEqual({error, <<"This choice is unavailable or out of date">>},
                 muse_jev:select(?O, ?T, A#{<<"candidateSetVersion">> => 99})),
    ?assertEqual(<<"I choose “Rocky Shore” from comparison choices. Continue with that preference."/utf8>>,
                 continuation(muse_jev:select(?O, ?T, A))),
    {ok, #{<<"panel">> := Selected}} = muse_jev:select(?O, ?T, A),
    ?assertEqual(<<"b">>, maps:get(<<"selectedId">>, Selected)),
    ?assertEqual({error, <<"A different choice was already selected">>},
                 muse_jev:select(?O, ?T, A#{<<"optionId">> => <<"a">>})).

%% "new generation supersedes an old panel and prevents late inference publication"
supersede() ->
    Self = self(),
    Racing = fun(#{<<"message">> := M} = In) ->
                     M =:= <<"old">> andalso begin Self ! {gated, self()},
                                                   receive release -> ok end end,
                     (by_index())(In)
             end,
    Pid = spawn(fun() -> Self ! {old, create(<<"old-turn">>, (args())#{<<"message">> => <<"old">>}, Racing)} end),
    Gated = receive {gated, G} -> G end,
    Newer = panel_of(create(<<"new-turn">>, (args())#{<<"message">> => <<"new">>}, Racing)),
    Gated ! release,
    Old = receive {old, R} -> R end,
    ?assert(is_pid(Pid)),
    ?assertEqual({ok, #{<<"panel">> => null,
                        <<"error">> => <<"These choices were superseded by a newer response.">>}}, Old),
    ?assertEqual(maps:get(<<"id">>, Newer), maps:get(<<"id">>, muse_jev:current_panel(?O, ?T))),
    ?assertMatch({error, _}, muse_jev:select(?O, ?T, #{<<"panelId">> => <<"missing">>,
                                                       <<"threadId">> => ?T,
                                                       <<"candidateSetVersion">> => 1,
                                                       <<"optionId">> => <<"a">>})).

%% "refinement reuses all candidates and permits a new selection"
refinement() ->
    First = panel_of(create(<<"turn">>, (args())#{<<"options">> => four()})),
    {ok, _} = muse_jev:select(?O, ?T, action(First, <<"b">>)),
    Refined = panel_of(create(<<"next">>, (args())#{<<"options">> => [],
                                                     <<"refinementPanelId">> => maps:get(<<"id">>, First)})),
    ?assertNot(maps:is_key(<<"selectedId">>, Refined)),
    Opts = maps:get(<<"options">>, Refined),
    ?assertEqual(3, length(Opts)),
    %% by_index ranks d, c, b, a; the prior selection b is visible and preferred.
    ?assertEqual([<<"d">>, <<"c">>, <<"b">>], [I || #{<<"id">> := I} <- Opts]),
    ?assertEqual(<<"b">>, maps:get(<<"preferredId">>, Refined)),
    ?assertEqual({error, <<"These choices have been superseded">>},
                 muse_jev:select(?O, ?T, action(First, <<"b">>))).

%% "aborted decision never publishes a panel"
aborted() ->
    Flag = atomics:new(1, []),
    Adapter = fun(#{<<"options">> := Os}) ->
                      atomics:put(Flag, 1, 1),
                      {ok, #{<<"control">> => <<"comparison">>,
                             <<"scores">> => maps:from_list([{I, 1} || #{<<"id">> := I} <- Os])}}
              end,
    ?assertEqual({error, aborted},
                 muse_jev:create_panel(?O, ?T, <<"turn">>, args(),
                                       #{adapter => Adapter, mode => sample,
                                         aborted => fun() -> atomics:get(Flag, 1) =:= 1 end})),
    ?assertEqual([], muse_store:list(?O, <<"jev_panels">>)).

%% "failed and aborted decisions keep the prior panel, while an agent decision clears it"
preserve() ->
    First = panel_of(create(<<"turn">>, args())),
    ?assertEqual({error, <<"unavailable">>},
                 create(<<"failed">>, args(), fun(_) -> {error, <<"unavailable">>} end)),
    ?assertEqual(maps:get(<<"id">>, First), maps:get(<<"id">>, muse_jev:current_panel(?O, ?T))),
    ?assertEqual({error, aborted},
                 muse_jev:create_panel(?O, ?T, <<"aborted">>, args(),
                                       #{adapter => constant(<<"comparison">>, #{<<"a">> => 1, <<"b">> => 2}),
                                         aborted => aborted_after(1), mode => sample})),
    ?assertEqual(maps:get(<<"id">>, First), maps:get(<<"id">>, muse_jev:current_panel(?O, ?T))),
    ?assertEqual({ok, #{<<"panel">> => null}},
                 create(<<"ordinary">>, args(), constant(<<"agent">>, #{<<"a">> => 1, <<"b">> => 2}))),
    ?assertEqual(undefined, muse_jev:current_panel(?O, ?T)),
    ?assertEqual({error, <<"These choices have been superseded">>},
                 muse_jev:select(?O, ?T, action(First, <<"a">>))).

%% Not aborted at the first check, aborted from then on (abort during decide).
aborted_after(N) ->
    C = counters:new(1, []),
    fun() -> counters:add(C, 1, 1), counters:get(C, 1) > N end.

%% Pause the next jev_threads insert_if_absent (the start of reserve) until resumed.
hold_reservation() ->
    Self = self(),
    Hold = atomics:new(1, []),
    ok = meck:new(muse_store, [passthrough]),
    meck:expect(muse_store, insert_if_absent,
                fun(O, <<"jev_threads">> = K, V) ->
                        case atomics:compare_exchange(Hold, 1, 0, 1) of
                            ok -> Self ! {paused, self()}, receive resume -> ok end;
                            _ -> ok
                        end,
                        meck:passthrough([O, K, V]);
                   (O, K, V) -> meck:passthrough([O, K, V])
                end).

%% "stale refinement cannot reserve over a newer published panel"
stale_refinement() ->
    First = panel_of(create(<<"initial">>, args())),
    hold_reservation(),
    Self = self(),
    _ = spawn(fun() -> Self ! {stale, create(<<"stale">>, (args())#{<<"refinementPanelId">> => maps:get(<<"id">>, First)})} end),
    Paused = receive {paused, P} -> P end,
    Newer = panel_of(create(<<"new">>, args())),
    Paused ! resume,
    ?assertEqual({error, <<"The earlier choices have been superseded">>}, receive {stale, R} -> R end),
    ?assertEqual(maps:get(<<"id">>, Newer), maps:get(<<"id">>, muse_jev:current_panel(?O, ?T))).

%% "refinement after a selection remains selectable as a new panel"
refine_after_select() ->
    First = panel_of(create(<<"initial">>, args())),
    {ok, _} = muse_jev:select(?O, ?T, action(First, <<"a">>)),
    Refined = panel_of(create(<<"refined">>, (args())#{<<"refinementPanelId">> => maps:get(<<"id">>, First)})),
    ?assertNot(maps:is_key(<<"selectedId">>, Refined)),
    ?assertMatch(<<"I choose “Rocky Shore”"/utf8, _/binary>>,
                 continuation(muse_jev:select(?O, ?T, action(Refined, <<"b">>)))).

%% "candidate source lookup uses the full current set and rejects sample proof in live mode"
sources() ->
    P = panel_of(create(<<"turn">>, (args())#{<<"options">> => four()})),
    Id = maps:get(<<"id">>, P),
    ?assertEqual(3, length(maps:get(<<"options">>, P))),
    ?assertEqual({ok, [<<"https://example.org/kelp">>, <<"https://example.org/rocky">>,
                       <<"https://example.org/sea">>, <<"https://example.org/birds">>]},
                 muse_jev:candidate_sources(?O, ?T, <<"turn">>, Id)),
    Unavailable = {error, <<"The earlier choices are unavailable or superseded">>},
    ?assertEqual(Unavailable, muse_jev:candidate_sources(<<"other">>, ?T, <<"turn">>, Id)),
    ?assertEqual(Unavailable, muse_jev:candidate_sources(?O, ?T, <<"turn">>, Id, #{mode => live})),
    _ = panel_of(create(<<"next">>, args())),
    ?assertEqual(Unavailable, muse_jev:candidate_sources(?O, ?T, <<"turn">>, Id)).

%% "evidence records are scoped to owner, thread, and run"
evidence() ->
    ok = muse_jev:note_evidence(?O, ?T, <<"run-1">>, mail, <<"trip-thread">>),
    ok = muse_jev:note_evidence(?O, ?T, <<"run-1">>, web, <<"https://example.org/kelp">>,
                                <<"Observed kelp page">>),
    ?assert(muse_jev:has_any_mail_evidence(?O, ?T, <<"run-1">>)),
    ?assertNot(muse_jev:has_any_mail_evidence(?O, ?T, <<"run-2">>)),
    ?assert(muse_jev:has_evidence(?O, ?T, <<"run-1">>, web, <<"https://example.org/kelp">>)),
    ?assertNot(muse_jev:has_evidence(?O, ?T, <<"run-2">>, web, <<"https://example.org/kelp">>)),
    ?assertNot(muse_jev:has_evidence(<<"other">>, ?T, <<"run-1">>, web, <<"https://example.org/kelp">>)),
    %% Ids: `${threadId}:${runId}:${kind}:${sha256hex(reference)}` (Node vectors).
    ok = muse_jev:note_evidence(?O, ?T, <<"run">>, mail, <<"trip-thread">>),
    ok = muse_jev:note_evidence(?O, ?T, <<"run">>, web, <<"https://example.org/kelp">>, <<"x">>),
    ?assertMatch(#{<<"kind">> := <<"mail">>, <<"reference">> := <<"trip-thread">>},
                 muse_store:get(?O, <<"jev_evidence">>,
                                <<"thread:run:mail:01130b6d681b9885b4f609e9c18845fff13586415bd5b45dba61828df57b9fbe">>)),
    ?assertMatch(#{<<"kind">> := <<"web">>, <<"text">> := <<"x">>},
                 muse_store:get(?O, <<"jev_evidence">>,
                                <<"thread:run:web:a5a400a77aa1095bb0e54edbf1a03f5347c58de8a9e8c5b96a05daf2b30e4967">>)),
    ?assertEqual(#{<<"id">> => <<"thread:run">>}, muse_store:get(?O, <<"jev_mail_evidence">>, <<"thread:run">>)).

%% "a selection made during inference prevents the new panel from replacing it"
select_race() ->
    First = panel_of(create(<<"first">>, args())),
    Self = self(),
    Slow = fun(#{<<"options">> := Os}) ->
                   Self ! {started, self()},
                   receive release -> ok end,
                   {ok, #{<<"control">> => <<"comparison">>,
                          <<"scores">> => maps:from_list([{I, 1} || #{<<"id">> := I} <- Os])}}
           end,
    _ = spawn(fun() -> Self ! {second, create(<<"second">>, args(), Slow)} end),
    Started = receive {started, S} -> S end,
    {ok, _} = muse_jev:select(?O, ?T, action(First, <<"a">>)),
    Started ! release,
    ?assertMatch({ok, #{<<"panel">> := null, <<"error">> := <<"These choices were superseded", _/binary>>}},
                 receive {second, R} -> R end),
    ?assertEqual(maps:get(<<"id">>, First), maps:get(<<"id">>, muse_jev:current_panel(?O, ?T))),
    ?assertEqual(<<"a">>, maps:get(<<"selectedId">>, head())).

%% "refinement uses a selection that races before generation reservation"
pre_reserve_race() ->
    FirstAdapter = fun(#{<<"options">> := Os}) ->
                           Ids = [I || #{<<"id">> := I} <- Os],
                           {ok, #{<<"control">> => <<"comparison">>,
                                  <<"scores">> => maps:from_list(
                                                    [{I, case I of <<"a">> -> 10; _ -> N end}
                                                     || {I, N} <- lists:zip(Ids, lists:seq(0, length(Ids) - 1))])}}
                   end,
    First = panel_of(create(<<"first">>, (args())#{<<"options">> => four()}, FirstAdapter)),
    hold_reservation(),
    Self = self(),
    Inspecting = fun(In) -> Self ! {selected, maps:get(<<"selectedId">>, In, undefined)}, (by_index())(In) end,
    _ = spawn(fun() ->
                      Self ! {refined, create(<<"refine">>, (args())#{<<"options">> => [],
                                                                       <<"refinementPanelId">> => maps:get(<<"id">>, First)},
                                              Inspecting)}
              end),
    Paused = receive {paused, P} -> P end,
    {ok, _} = muse_jev:select(?O, ?T, action(First, <<"a">>)),
    Paused ! resume,
    ?assertEqual(<<"a">>, receive {selected, S} -> S end),
    Refined = panel_of(receive {refined, R} -> R end),
    ?assertEqual(<<"a">>, maps:get(<<"preferredId">>, Refined)),
    ?assertNot(maps:is_key(<<"selectedId">>, Refined)),
    %% by_index ranks d, c, b, a: a replaces the last visible slot.
    ?assertEqual([<<"d">>, <<"c">>, <<"a">>], [I || #{<<"id">> := I} <- maps:get(<<"options">>, Refined)]).

%% "mail evidence lookup uses direct run marker and web evidence stores bounded text"
evidence_text() ->
    ok = muse_jev:note_evidence(?O, ?T, <<"run">>, mail, <<"trip-thread">>),
    ?assert(muse_jev:has_any_mail_evidence(?O, ?T, <<"run">>)),
    ?assertNot(muse_jev:has_any_mail_evidence(?O, ?T, <<"other">>)),
    ok = muse_jev:note_evidence(?O, ?T, <<"run">>, web, <<"https://example.org/empty">>, <<"   ">>),
    ?assertEqual(undefined, muse_jev:evidence_text(?O, ?T, <<"run">>, web, <<"https://example.org/empty">>)),
    ok = muse_jev:note_evidence(?O, ?T, <<"run">>, web, <<"https://example.org/full">>,
                                binary:copy(<<"x">>, 40000)),
    ?assertEqual(30000, byte_size(muse_jev:evidence_text(?O, ?T, <<"run">>, web, <<"https://example.org/full">>))),
    ?assertEqual(undefined, muse_jev:evidence_text(?O, ?T, <<"other">>, web, <<"https://example.org/full">>)).

%% "an agent decision invalidates the older panel but a failed decision preserves it"
agent_expire() ->
    First = panel_of(create(<<"first">>, args())),
    {error, _} = create(<<"failed">>, args(), fun(_) -> {error, <<"unavailable">>} end),
    ?assertEqual(maps:get(<<"id">>, First), maps:get(<<"id">>, muse_jev:current_panel(?O, ?T))),
    ?assertEqual({ok, #{<<"panel">> => null}},
                 create(<<"agent">>, args(), constant(<<"agent">>, #{<<"a">> => 1, <<"b">> => 2}))),
    ?assertEqual(undefined, muse_jev:current_panel(?O, ?T)),
    ?assertMatch({error, _}, muse_jev:select(?O, ?T, action(First, <<"a">>))).

%% "ordinary-turn expiry rejects stale actions while preserving a concurrent selection"
turn_expiry() ->
    First = panel_of(create(<<"first">>, args())),
    Snapshot = muse_jev:head_snapshot(?O, ?T),
    ?assertMatch(#{<<"selectedId">> := null}, Snapshot),
    A = action(First, <<"a">>),
    {ok, _} = muse_jev:select(?O, ?T, A),
    ?assertNot(muse_jev:expire_if_unchanged(?O, ?T, Snapshot, <<"turn">>)),
    ?assertMatch(<<"I choose “Kelp Forest”"/utf8, _/binary>>, continuation(muse_jev:select(?O, ?T, A))),
    Selected = muse_jev:head_snapshot(?O, ?T),
    ?assert(muse_jev:expire_if_unchanged(?O, ?T, Selected, <<"turn">>)),
    ?assertEqual(undefined, muse_jev:current_panel(?O, ?T)),
    ?assertEqual(undefined, muse_jev:head_snapshot(?O, ?T)),
    ?assertMatch({error, _}, muse_jev:select(?O, ?T, A)),
    ?assertNot(muse_jev:expire_if_unchanged(?O, ?T, undefined, <<"turn">>)).

%% "only the turn that retired a panel may refine it" (conversation-jev)
retired_refine() ->
    First = panel_of(create(<<"first">>, args())),
    ok = muse_jev:expire_on_user_turn(?O, ?T, <<"weather-turn">>),
    ?assertEqual(null, maps:get(<<"currentPanelId">>, head())),
    Refine = (args())#{<<"options">> => [], <<"refinementPanelId">> => maps:get(<<"id">>, First)},
    ?assertEqual({error, <<"The earlier choices are unavailable or superseded">>},
                 create(<<"a-later-turn">>, Refine)),
    ?assertMatch({ok, #{<<"panel">> := #{}}}, create(<<"weather-turn">>, Refine)).

call_tool(Tool, Args) ->
    #{handler := H} = Tool,
    {ok, R} = H(Args, beamai_context:new()),
    R.

clarify() ->
    #{<<"message">> => <<"What next?">>, <<"context">> => <<"User asked">>,
      <<"title">> => <<"Next">>, <<"control">> => <<"clarification">>,
      <<"options">> => [#{<<"id">> => <<"explore">>, <<"label">> => <<"Explore exhibits">>,
                          <<"details">> => [], <<"sources">> => []}]}.

%% "present_choices emits a complete panel and selection uses trusted stored label",
%% "a later ordinary completed turn invalidates a prior choice panel"
tool_sample() ->
    Tool = muse_jev:present_choices_tool(?O, ?T, <<"run-1">>, <<"Help with aquarium trip">>),
    ?assertEqual(<<"present_choices">>, maps:get(name, Tool)),
    #{<<"panel">> := P} = call_tool(Tool, clarify()),
    ?assertMatch(#{<<"mode">> := <<"sample">>, <<"type">> := <<"clarification">>,
                   <<"turnId">> := <<"run-1">>, <<"candidateSetVersion">> := 1,
                   <<"options">> := [#{<<"label">> := <<"Explore exhibits">>}]}, P),
    {ok, Text} = muse_jev_schema:encode_action(action(P, <<"explore">>)),
    ?assertMatch({ok, #{<<"continuation">> := <<"I choose “Explore exhibits” from clarification choices. Continue with that preference."/utf8>>}},
                 muse_jev:choice(?O, ?T, Text)),
    ?assertMatch({ok, _}, muse_jev:choice(?O, ?T, Text)),
    ?assertEqual(<<"explore">>, maps:get(<<"selectedId">>, head())),
    ok = muse_jev:expire_on_user_turn(?O, ?T, <<"run-2">>),
    ?assertEqual(null, maps:get(<<"currentPanelId">>, head())),
    ?assertEqual({error, <<"These choices have been superseded">>}, muse_jev:choice(?O, ?T, Text)),
    %% Schema errors are muse_tool errors; service errors keep `panel: null`.
    ?assertEqual(#{<<"error">> => <<"New choices need at least one option">>},
                 call_tool(Tool, (clarify())#{<<"options">> => []})),
    ?assertEqual(#{<<"error">> => <<"Unrecognized key: \"extra\"">>},
                 call_tool(Tool, (clarify())#{<<"extra">> => 1})),
    ?assertEqual(#{<<"panel">> => null,
                   <<"error">> => <<"Choices need 1–12 distinct options"/utf8>>},
                 call_tool(Tool, (clarify())#{<<"options">> => lists:duplicate(2, hd(maps:get(<<"options">>, clarify())))})),
    ?assertEqual(#{<<"panel">> => null, <<"error">> => <<"Comparison choices need sources">>},
                 call_tool(Tool, (clarify())#{<<"control">> => <<"comparison">>})).

%% §9.2 step 3 errors (conversation-jev "invalid and cross-thread actions ...")
choice_dispatch() ->
    ?assertEqual(not_choice, muse_jev:choice(?O, ?T, <<"ordinary message">>)),
    ?assertEqual({error, <<"The choice could not be read">>},
                 muse_jev:choice(?O, ?T, <<"[OpenMuse choice] bad-json">>)),
    {ok, Cross} = muse_jev_schema:encode_action(#{<<"panelId">> => <<"missing">>, <<"threadId">> => <<"foreign">>,
                                                  <<"candidateSetVersion">> => 1, <<"optionId">> => <<"a">>}),
    ?assertEqual({error, <<"This choice belongs to another conversation">>}, muse_jev:choice(?O, ?T, Cross)),
    {ok, Off} = muse_config:from_env(#{}),
    muse_config:set(Off),
    ?assertNot(muse_jev:enabled()),
    ?assertEqual({error, <<"Choices are unavailable in this conversation">>}, muse_jev:choice(?O, ?T, Cross)),
    ?assertEqual(ok, muse_jev:expire_on_user_turn(?O, ?T, <<"r">>)).

live_tool(Run) ->
    muse_jev:present_choices_tool(?O, ?T, Run, <<"Compare exhibits">>,
                                  #{mode => live, adapter => by_index()}).

comparison(Label, Details, Title, Url) ->
    #{<<"message">> => <<"Compare">>, <<"context">> => <<"Read exhibit page">>,
      <<"title">> => <<"Exhibits">>, <<"control">> => <<"comparison">>,
      <<"options">> => [#{<<"id">> => <<"a">>, <<"label">> => Label, <<"details">> => Details,
                          <<"sources">> => [src(Title, Url)]}]}.

error_of(#{<<"panel">> := null, <<"error">> := E}) -> E.

%% conversation-jev live grounding cases, against stored evidence.
live_grounding() ->
    Url = <<"https://example.org/rocky-shore">>,
    Tool = live_tool(<<"run">>),
    ?assertEqual(<<"Read the source page before comparing: https://example.org/rocky-shore">>,
                 error_of(call_tool(Tool, comparison(<<"Rocky Shore">>, [<<"Touch sea stars">>],
                                                     <<"Rocky Shore">>, Url)))),
    ok = muse_jev:note_evidence(?O, ?T, <<"run">>, web, Url, <<"Rocky   Shore lets visitors Touch sea stars.">>),
    ?assertEqual(<<"Comparison label is not present in source text: Imaginary reef">>,
                 error_of(call_tool(Tool, comparison(<<"Imaginary reef">>, [<<"Touch sea stars">>],
                                                     <<"Rocky Shore">>, Url)))),
    ?assertEqual(<<"Comparison source title is not present in source text: ", Url/binary>>,
                 error_of(call_tool(Tool, comparison(<<"Rocky Shore">>, [<<"Touch sea stars">>],
                                                     <<"Imaginary reef">>, Url)))),
    ?assertEqual(<<"Comparison needs at least one grounded detail: Rocky Shore">>,
                 error_of(call_tool(Tool, comparison(<<"Rocky Shore">>, [], <<"Rocky Shore">>, Url)))),
    ?assertEqual(<<"Comparison detail is not present in source text: Rocky Shore">>,
                 error_of(call_tool(Tool, comparison(<<"Rocky Shore">>, [<<"A bat-ray touch pool">>],
                                                     <<"Rocky Shore">>, Url)))),
    #{<<"panel">> := P} = call_tool(Tool, comparison(<<"rocky shore">>, [<<"touch SEA stars">>],
                                                     <<"Rocky Shore">>, Url)),
    ?assertEqual(<<"live">>, maps:get(<<"mode">>, P)),
    %% Evidence of another run proves nothing.
    ?assertMatch(<<"Read the source page", _/binary>>,
                 error_of(call_tool(live_tool(<<"run-2">>),
                                    comparison(<<"Rocky Shore">>, [<<"Touch sea stars">>], <<"Rocky Shore">>, Url)))).

%% "generic live clarification succeeds without mail, but an unobserved mail thread does not"
live_mail() ->
    Tool = muse_jev:present_choices_tool(?O, ?T, <<"run">>, undefined,
                                         #{mode => live, adapter => constant(<<"clarification">>, #{<<"explore">> => 1})}),
    ?assertMatch(#{<<"panel">> := #{}}, call_tool(Tool, clarify())),
    WithMail = (clarify())#{<<"mailThreadId">> => <<"trip-thread">>},
    ?assertEqual(<<"Read the referenced email before presenting choices.">>, error_of(call_tool(Tool, WithMail))),
    ok = muse_jev:note_evidence(?O, ?T, <<"earlier-run">>, mail, <<"trip-thread">>),
    ?assertMatch(#{<<"error">> := <<"Read the referenced email", _/binary>>}, call_tool(Tool, WithMail)),
    ok = muse_jev:note_evidence(?O, ?T, <<"run">>, mail, <<"trip-thread">>),
    ?assertMatch(#{<<"panel">> := #{}}, call_tool(Tool, WithMail)),
    %% JEV_MODE=live uses the TypeSafe adapter (muse_jev_typesafe_tests)
    ?assertEqual(fun muse_jev_typesafe:decide/1, muse_jev_adapter:for_mode(live)).

%% "live refinement reuses the verified stored sources with no new browse or options"
live_refinement() ->
    Url = <<"https://example.org/exhibit">>,
    ok = muse_jev:note_evidence(?O, ?T, <<"run-1">>, web, Url, <<"Observed exhibit facts">>),
    #{<<"panel">> := P} = call_tool(live_tool(<<"run-1">>),
                                    comparison(<<"Observed exhibit">>, [<<"Observed exhibit facts">>],
                                               <<"Exhibit">>, Url)),
    ok = muse_jev:expire_on_user_turn(?O, ?T, <<"run-2">>),
    Refine = #{<<"message">> => <<"Something hands-on">>, <<"context">> => <<"Earlier verified exhibit">>,
               <<"title">> => <<"Hands-on exhibits">>, <<"control">> => <<"comparison">>,
               <<"options">> => [], <<"refinementPanelId">> => maps:get(<<"id">>, P)},
    #{<<"panel">> := R} = call_tool(live_tool(<<"run-2">>), Refine),
    ?assertEqual([<<"a">>], [I || #{<<"id">> := I} <- maps:get(<<"options">>, R)]),
    ?assertEqual(<<"The earlier choices are unavailable or superseded">>,
                 error_of(call_tool(live_tool(<<"run-3">>), Refine))).

panel_view() ->
    P = panel_of(create(<<"turn">>, args())),
    Id = maps:get(<<"id">>, P),
    ?assertEqual(P, muse_jev:panel(?O, Id)),
    {ok, _} = muse_jev:select(?O, ?T, action(P, <<"b">>)),
    ?assertEqual(<<"b">>, maps:get(<<"selectedId">>, muse_jev:panel(?O, Id))),
    ?assertEqual(undefined, muse_jev:panel(?O, <<"missing">>)),
    ?assertEqual(undefined, muse_jev:panel(<<"other">>, Id)).

%% "Jev judges the person's own message, not the agent's summary of it"
user_message() ->
    Self = self(),
    Adapter = fun(In) -> Self ! {seen, In}, {ok, #{<<"control">> => <<"clarification">>,
                                                   <<"scores">> => #{<<"explore">> => 1}}} end,
    Tool = muse_jev:present_choices_tool(?O, ?T, <<"run">>, <<"  What should I do next?  ">>,
                                         #{adapter => Adapter}),
    #{<<"panel">> := _} = call_tool(Tool, (clarify())#{<<"message">> => <<"Agent paraphrase">>}),
    In = receive {seen, I} -> I end,
    ?assertEqual(<<"What should I do next?">>, maps:get(<<"userMessage">>, In)),
    ?assertEqual(<<"Agent paraphrase">>, maps:get(<<"message">>, In)),
    ?assertEqual([<<"clarification">>, <<"agent">>], maps:get(<<"allowedControls">>, In)),
    ?assertNot(maps:is_key(<<"selectedId">>, In)).

%% Pure: schemas, actions, ranking, sample adapter, ids, prompt

schema_option(Id) ->
    #{<<"id">> => Id, <<"label">> => Id, <<"details">> => [],
      <<"sources">> => [src(<<"Source">>, <<"https://example.org">>)]}.

schema_panel() ->
    #{<<"id">> => <<"p">>, <<"threadId">> => <<"t">>, <<"turnId">> => <<"r">>,
      <<"candidateSetVersion">> => 1, <<"type">> => <<"comparison">>, <<"title">> => <<"Choose">>,
      <<"mode">> => <<"sample">>, <<"options">> => [schema_option(<<"a">>)]}.

%% "panel validation rejects empty, duplicate and unsourced comparison options"
panel_validation_test() ->
    P = schema_panel(),
    ?assertMatch({ok, _}, muse_jev_schema:check_panel(P)),
    ?assertMatch({error, _}, muse_jev_schema:check_panel(P#{<<"options">> => []})),
    ?assertEqual({error, <<"Duplicate option ID">>},
                 muse_jev_schema:check_panel(P#{<<"options">> => [schema_option(<<"a">>), schema_option(<<"a">>)]})),
    ?assertEqual({error, <<"Comparison options need sources">>},
                 muse_jev_schema:check_panel(P#{<<"options">> => [(schema_option(<<"a">>))#{<<"sources">> => []}]})),
    ?assertEqual({error, <<"Source URL must use HTTP or HTTPS">>},
                 muse_jev_schema:check_panel(P#{<<"options">> => [(schema_option(<<"a">>))#{<<"sources">> => [src(<<"bad">>, <<"file:///x">>)]}]})),
    ?assertMatch({error, _}, muse_jev_schema:check_panel(P#{<<"candidateSetVersion">> => 0})),
    ?assertEqual({error, <<"Comparison panel can show at most three options">>},
                 muse_jev_schema:check_panel(P#{<<"options">> => [schema_option(I) || I <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>]]})),
    ?assertMatch({ok, _}, muse_jev_schema:check_panel(
                            P#{<<"type">> => <<"clarification">>,
                               <<"options">> => [(schema_option(I))#{<<"sources">> => []} || I <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>]]})),
    ?assertEqual({error, <<"Unrecognized key: \"extra\"">>}, muse_jev_schema:check_panel(P#{<<"extra">> => 1})).

%% "preferred refinement option must be visible in the panel"
preferred_visible_test() ->
    ?assertMatch({ok, #{<<"preferredId">> := <<"a">>}},
                 muse_jev_schema:check_panel((schema_panel())#{<<"preferredId">> => <<"a">>})),
    ?assertEqual({error, <<"Preferred option is missing">>},
                 muse_jev_schema:check_panel((schema_panel())#{<<"preferredId">> => <<"not-visible">>})),
    ?assertEqual({error, <<"Selected option is missing">>},
                 muse_jev_schema:check_panel((schema_panel())#{<<"selectedId">> => <<"x">>})).

%% "actions round trip and malformed prefixed actions reject"
actions_test() ->
    A = #{<<"panelId">> => <<"p">>, <<"threadId">> => <<"t">>, <<"candidateSetVersion">> => 1,
          <<"optionId">> => <<"a">>},
    {ok, Text} = muse_jev_schema:encode_action(A),
    ?assertEqual(<<"[OpenMuse choice] {\"panelId\":\"p\",\"threadId\":\"t\",\"candidateSetVersion\":1,\"optionId\":\"a\"}">>, Text),
    ?assertEqual(<<"[OpenMuse choice] ">>, muse_jev:action_prefix()),
    ?assertEqual({ok, A}, muse_jev:parse_action(Text)),
    ?assertEqual(error, muse_jev:parse_action(<<"ordinary message">>)),
    ?assertMatch({error, _}, muse_jev:parse_action(<<"[OpenMuse choice] bad-json">>)),
    ?assertEqual({error, <<"Unrecognized key: \"label\"">>},
                 muse_jev:parse_action(<<"[OpenMuse choice] {\"panelId\":\"p\",\"threadId\":\"t\","
                                         "\"candidateSetVersion\":1,\"optionId\":\"a\",\"label\":\"untrusted\"}">>)),
    ?assertMatch({error, _}, muse_jev:parse_action(<<"[OpenMuse choice] {\"panelId\":\"p\",\"threadId\":\"t\","
                                                     "\"candidateSetVersion\":1.5,\"optionId\":\"a\"}">>)),
    ?assertMatch({error, _}, muse_jev:parse_action(<<"[OpenMuse choice] [1]">>)).

ids(L) -> [I || #{<<"id">> := I} <- L].

rank(Options, Scores) ->
    case muse_jev_adapter:rank(Options, #{<<"control">> => <<"comparison">>, <<"scores">> => Scores}) of
        {ok, R} -> ids(R);
        Error -> Error
    end.

%% "ranking uses stable ties and rejects missing, unknown or nonfinite scores",
%% "ranking compares rubric levels, not fractions between them" (+ Node vectors)
ranking_test() ->
    Two = [schema_option(<<"a">>), schema_option(<<"b">>)],
    S = fun(A, B) -> #{<<"a">> => A, <<"b">> => B} end,
    ?assertEqual([<<"a">>, <<"b">>], rank(Two, S(1, 1))),
    ?assertEqual([<<"b">>, <<"a">>], rank(Two, S(0, 2))),
    ?assertEqual({error, <<"Jev returned invalid score IDs">>}, rank(Two, #{<<"a">> => 1})),
    ?assertEqual({error, <<"Jev returned invalid score IDs">>}, rank(Two, (S(1, 2))#{<<"x">> => 3})),
    ?assertEqual({error, <<"Jev returned a missing or invalid score">>}, rank(Two, S(1, nan))),
    ?assertEqual([<<"a">>, <<"b">>], rank(Two, S(1.93, 2.2))),
    ?assertEqual([<<"b">>, <<"a">>], rank(Two, S(2.2, 2.6))),
    ?assertEqual([<<"a">>, <<"b">>], rank(Two, S(2.5, 2.49))),
    ?assertEqual([<<"a">>, <<"b">>], rank(Two, S(-0.5, 0))).

aquarium() ->
    [#{<<"id">> => <<"kelp-forest">>, <<"label">> => <<"Kelp Forest">>,
       <<"details">> => [<<"See a 28-foot-tall kelp exhibit with sardines, leopard sharks, and other fish.">>]},
     #{<<"id">> => <<"open-sea">>, <<"label">> => <<"Open Sea">>,
       <<"details">> => [<<"Watch turtles, sardines, and tuna through the aquarium's 90-foot viewing window.">>]},
     #{<<"id">> => <<"rocky-shore">>, <<"label">> => <<"Rocky Shore">>,
       <<"details">> => [<<"Touch and interact with bat rays in the touch pool.">>]},
     #{<<"id">> => <<"birds">>, <<"label">> => <<"Birds">>, <<"details">> => [<<"Interactive aviary">>]}].

%% Node: SampleJevAdapter + rankJevOptions on the aquarium fixture.
sample_adapter_test() ->
    Decide = fun(Msg, Allowed) ->
                     {ok, D} = muse_jev_sample:decide(#{<<"message">> => Msg, <<"options">> => aquarium(),
                                                        <<"allowedControls">> => Allowed}),
                     D
             end,
    Plain = Decide(<<"Compare exhibits">>, [<<"comparison">>, <<"agent">>]),
    ?assertEqual(#{<<"control">> => <<"comparison">>,
                   <<"scores">> => #{<<"kelp-forest">> => 4, <<"open-sea">> => 3,
                                     <<"rocky-shore">> => 2, <<"birds">> => 1}}, Plain),
    ?assertEqual({ok, [<<"kelp-forest">>, <<"open-sea">>, <<"rocky-shore">>, <<"birds">>]},
                 {ok, rank(aquarium(), maps:get(<<"scores">>, Plain))}),
    lists:foreach(
      fun(Msg) ->
              D = Decide(Msg, [<<"comparison">>, <<"agent">>]),
              ?assertEqual(#{<<"kelp-forest">> => 4, <<"open-sea">> => 3, <<"rocky-shore">> => 10,
                             <<"birds">> => 10}, maps:get(<<"scores">>, D)),
              ?assertEqual([<<"rocky-shore">>, <<"birds">>, <<"kelp-forest">>, <<"open-sea">>],
                           rank(aquarium(), maps:get(<<"scores">>, D)))
      end, [<<"Something hands-on">>, <<"HANDS ON please">>, <<"touchy">>]),
    ?assertEqual(<<"clarification">>,
                 maps:get(<<"control">>, Decide(<<"x">>, [<<"clarification">>, <<"agent">>]))).

%% Node: sha256hex(JSON.stringify({label, details, sources})).slice(0, 32)
option_id_test() ->
    ?assertEqual(<<"b32f9795b5326bfeffbc3eae34fe3bf7">>,
                 muse_jev:option_id(#{<<"label">> => <<"Explore exhibits">>, <<"details">> => [],
                                      <<"sources">> => []})),
    ?assertEqual(<<"9a91e63e5f15fe3b11910cf6a700f345">>,
                 muse_jev:option_id(#{<<"label">> => <<"Kelp Forest">>,
                                      <<"details">> => [<<"See a 28-foot-tall kelp exhibit with sardines, leopard sharks, and other fish.">>],
                                      <<"sources">> => [src(<<"Monterey Bay Aquarium · Kelp Forest"/utf8>>,
                                                            <<"https://www.montereybayaquarium.org/visit/exhibits/kelp-forest/">>)]})),
    ?assertEqual(<<"3f4c85ee09d504e046f7905e2d2bf908">>,
                 muse_jev:option_id(#{<<"label">> => <<"Café “quote” \"x\" \\ 😀"/utf8>>,
                                      <<"details">> => [<<"line\nbreak">>, <<"tab\t">>],
                                      <<"sources">> => [src(<<"T">>, <<"https://example.org/a?b=1&c=é"/utf8>>)]})).

prompt_section_test() ->
    Common = <<" When a request has several possible next steps, call present_choices with factual clarification options. If those choices depend on email, first search and read the relevant thread, then provide its mailThreadId to present_choices. Generic choices need no mail. ">>,
    Tail = <<"To refine a panel, pass its refinementPanelId with empty options; retained candidates will be ranked again. A selection is a preference; continue the user's requested planning from it.">>,
    ?assertEqual(<<Common/binary, "Full-page research comparisons are unavailable without a browser worker. ", Tail/binary>>,
                 muse_jev:prompt_section(false)),
    ?assertEqual(<<Common/binary, "For exhibit or other research comparisons, call browse_web for every cited source before calling present_choices with a comparison. Comparison details must be exact phrases from the returned page text, and each source URL must be the final URL from successful browsing. If source reading fails, report the failure and do not present a sourced comparison. ", Tail/binary>>,
                 muse_jev:prompt_section(true)).

%% "refinement may omit options but new panels still need candidates",
%% "mail-grounded choices name a thread, while generic clarification needs no mail reference"
tool_params_test() ->
    P = muse_jev_schema:tool_params(),
    Base = #{<<"message">> => <<"Refine">>, <<"context">> => <<"Earlier panel">>,
             <<"title">> => <<"Choices">>, <<"control">> => <<"comparison">>},
    ?assertMatch({ok, _}, muse_jev_schema:check(P, Base#{<<"options">> => [], <<"refinementPanelId">> => <<"previous">>})),
    ?assertEqual({error, <<"New choices need at least one option">>},
                 muse_jev_schema:check(P, Base#{<<"options">> => []})),
    Clar = (clarify()),
    ?assertMatch({ok, _}, muse_jev_schema:check(P, Clar)),
    ?assertMatch({ok, #{<<"mailThreadId">> := <<"trip-thread">>}},
                 muse_jev_schema:check(P, Clar#{<<"mailThreadId">> => <<" trip-thread ">>})),
    ?assertEqual({error, <<"Unrecognized key: \"bogus\"">>},
                 muse_jev_schema:check(P, Clar#{<<"options">> => [(hd(maps:get(<<"options">>, Clar)))#{<<"bogus">> => 1}]})),
    ?assertMatch({ok, #{<<"options">> := [#{<<"label">> := <<"x">>}]}},
                 muse_jev_schema:check(P, Clar#{<<"options">> => [#{<<"label">> => <<" x ">>, <<"details">> => [],
                                                                    <<"sources">> => []}]})).
