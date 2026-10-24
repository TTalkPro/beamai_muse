%% UI pages of M6-3 / M6-4 (tasks/M6-ui.md): Activity (task list, detail,
%% controls, input form, reviews), Goals, Monitors, Ideas, Notifications.
%% Pages are fetched with the session cookie; actions are posted to
%% /aihtml/action with tokens built like the pages build them.
-module(muse_ui_pages_a_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [activity_list_detail_controls, activity_global_review, permission_slip_flow, task_card_and_pushes,
     goals_page, monitors_page, ideas_page, notifications_page, actions_need_session].

init_per_testcase(_Case, Config) ->
    Env = muse_web_test_env:start(),
    C = [{env, Env} | Config],
    [{cookie, sign_in(C)} | C].

end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)).

%% HTTP helpers

req(Config, Method, Path, Headers, Body) ->
    req_url(muse_web_test_env:base(?config(env, Config)) ++ Path, Method, Headers, Body).

req_url(Url, Method, Headers, Body) ->
    Request = case Body of
                  undefined -> {Url, Headers};
                  {Type, B} -> {Url, Headers, Type, B}
              end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{autoredirect, false}, {timeout, 30000}], [{body_format, binary}]),
    {Status, RespHeaders, RespBody}.

origin() -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

sign_in(Config) ->
    {302, H, _} = req(Config, post, "/login", [{"origin", origin()}],
                      {"application/x-www-form-urlencoded", <<>>}),
    [SetCookie] = [V || {"set-cookie", V} <- H],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

cookie(Config) -> [{"cookie", "muse_session=" ++ ?config(cookie, Config)}].

page(Config, Path) ->
    {200, _, Html} = req(Config, get, Path, cookie(Config), undefined),
    Html.

%% Post an action as the browser does; {Status, DecodedReply}.
act(Config, Mod, Name, Args, Event) ->
    act(Config, cookie(Config), Mod, Name, Args, Event).

act(Config, Cookie, Mod, Name, Args, Event) ->
    Token = aihtml_action:token({Mod, Name, Args}),
    Body = muse_json:encode(#{<<"action">> => Token, <<"event">> => Event}),
    %% the page's own origin (PUBLIC_API_URL), as a browser on it sends
    _ = Config,
    {Status, _, Resp} = req_url(binary_to_list(muse_config:get(public_url)) ++ "/aihtml/action", post,
                                Cookie ++ [{"origin", origin()}], {"application/json", Body}),
    {ok, Json} = muse_json:decode(Resp),
    {Status, Json}.

%% A successful action reply without an error toast.
ok_act(Config, Mod, Name, Args, Event) ->
    {200, Reply} = act(Config, Mod, Name, Args, Event),
    ?assertNot(contains(Reply, <<"操作失败"/utf8>>), Reply),
    Reply.

contains(B, Needle) when is_binary(B) -> binary:match(B, Needle) =/= nomatch;
contains(L, Needle) when is_list(L) -> lists:any(fun(X) -> contains(X, Needle) end, L);
contains(M, Needle) when is_map(M) -> contains(maps:values(M), Needle);
contains(_, _) -> false.

has(Html, Needle) ->
    ?assertNotEqual(nomatch, binary:match(Html, Needle), Needle).

form(Fields) -> #{<<"type">> => <<"submit">>, <<"form">> => Fields}.

task(Id) -> muse_store:get(?O, <<"tasks">>, Id).

run_pending() -> run_pending(50).
run_pending(0) -> error(runs_did_not_settle);
run_pending(N) ->
    Started = muse_task_worker:tick(),
    wait_idle(200),
    case Started of
        [] -> ok;
        _ -> run_pending(N - 1)
    end.

wait_idle(0) -> error(timeout_waiting);
wait_idle(N) ->
    case muse_task_worker:in_flight() of
        [] -> ok;
        _ -> timer:sleep(50), wait_idle(N - 1)
    end.

%% Cases

activity_list_detail_controls(Config) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"Plan a picnic">>}),
    List = page(Config, "/activity"),
    has(List, <<"href=\"/activity/", Id/binary, "\"">>),
    has(List, <<"task-row-", Id/binary>>),
    has(List, <<"id=\"activity-body\"">>),
    has(List, <<"data-ah-subscribe">>),
    Detail = page(Config, "/activity/" ++ binary_to_list(Id)),
    has(Detail, <<"Plan a picnic">>),
    has(Detail, <<"task-body-", Id/binary>>),
    has(Detail, <<"task-timeline-", Id/binary>>),
    has(Detail, <<"data-ah-subscribe">>),
    %% cancel asks first
    has(Detail, <<"data-ah-confirm">>),
    Ctl = fun(Op) -> act(Config, muse_ui_activity, control, #{task => Id, op => Op}, #{<<"type">> => <<"click">>}) end,
    {200, R1} = Ctl(<<"pause">>),
    ?assert(contains(R1, <<"task-body-", Id/binary>>)),
    ?assertMatch(#{<<"status">> := <<"paused">>}, task(Id)),
    {200, _} = Ctl(<<"resume">>),
    ?assertMatch(#{<<"status">> := <<"queued">>}, task(Id)),
    {200, _} = Ctl(<<"cancel">>),
    ?assertMatch(#{<<"status">> := <<"cancelled">>}, task(Id)),
    %% a refused control is a toast, nothing changes
    {200, R2} = Ctl(<<"retry">>),
    ?assert(contains(R2, <<"Only failed tasks can be retried">>)),
    ?assertMatch(#{<<"status">> := <<"cancelled">>}, task(Id)),
    %% the timeline shows the status events
    has(page(Config, "/activity/" ++ binary_to_list(Id)), <<"Task cancelled">>),
    %% an unknown task
    has(page(Config, "/activity/nope"), <<"找不到这个任务"/utf8>>),
    %% refresh actions re-render
    ?assert(contains(ok_act(Config, muse_ui_activity, refresh_list, #{}, #{}), <<"activity-body">>)),
    ?assert(contains(ok_act(Config, muse_ui_activity, refresh_task, #{task => Id}, #{}), <<"task-body-", Id/binary>>)).

activity_global_review(Config) ->
    %% the sample workspace seeds one proposal awaiting review
    [#{<<"id">> := AId, <<"hash">> := Hash}] =
        [A || A = #{<<"status">> := <<"awaiting_review">>} <- muse_store:list(?O, <<"actions">>)],
    List = page(Config, "/activity"),
    has(List, <<"approval-", AId/binary>>),
    has(List, binary:part(Hash, 0, 16)),
    has(List, <<"本地批准"/utf8>>),
    %% a stale hash is refused
    {200, R1} = act(Config, muse_ui_activity, decide,
                    #{action => AId, hash => <<"stale">>, decision => approve, scope => list}, #{}),
    ?assert(contains(R1, <<"This proposal changed">>)),
    ?assertMatch(#{<<"status">> := <<"awaiting_review">>}, muse_actions:get(?O, AId)),
    R2 = ok_act(Config, muse_ui_activity, decide, #{action => AId, hash => Hash, decision => deny, scope => list}, #{}),
    ?assert(contains(R2, <<"activity-body">>)),
    ?assertMatch(#{<<"status">> := <<"denied">>}, muse_actions:get(?O, AId)).

%% Acceptance (M6-3): the permission slip in sample mode, driven from the UI:
%% fields -> review card with the PDF -> approve with the hash -> receipt.
permission_slip_flow(Config) ->
    {ok, #{<<"id">> := Id}} =
        muse_agent_service:create_task(?O, #{<<"kind">> => <<"document">>,
                                             <<"title">> => <<"Complete the permission slip">>,
                                             <<"prompt">> => <<"Complete the permission slip">>,
                                             <<"input">> => #{<<"messageId">> => <<"mail-fieldtrip">>}}),
    run_pending(),
    #{<<"status">> := <<"waiting_input">>} = task(Id),
    Path = "/activity/" ++ binary_to_list(Id),
    Waiting = page(Config, Path),
    has(Waiting, <<"task-input-", Id/binary>>),
    has(Waiting, <<"name=\"f.participant_name\"">>),
    has(Waiting, <<"name=\"f.permission_granted\"">>),
    has(Waiting, <<"Supported fields: participant_name">>),
    %% submit the form as the browser does (a ticked checkbox sends its value)
    ok_act(Config, muse_ui_activity, answer, #{task => Id},
           form(#{<<"answer">> => <<>>, <<"f.participant_name">> => <<"Sam">>,
                  <<"f.permission_granted">> => <<"true">>})),
    #{<<"status">> := <<"queued">>, <<"input">> := #{<<"fields">> := Fields}} = task(Id),
    ?assertEqual(#{<<"participant_name">> => <<"Sam">>, <<"permission_granted">> => true}, Fields),
    run_pending(),
    #{<<"status">> := <<"waiting_approval">>, <<"actionId">> := AId, <<"artifactIds">> := [Filled]} = task(Id),
    #{<<"hash">> := Hash, <<"status">> := <<"awaiting_review">>} = muse_actions:get(?O, AId),
    Review = page(Config, Path),
    has(Review, <<"approval-", AId/binary>>),
    has(Review, <<"Re: A little reminder: permission slips are due Friday">>),
    has(Review, <<"office@lincoln.example">>),
    has(Review, <<"/api/files/", Filled/binary, "/content">>),
    has(Review, <<"查看 PDF"/utf8>>),
    has(Review, Hash),
    %% the signed PDF link works
    {match, [Url]} = re:run(Review, <<"href=\"([^\"]*/api/files/", Filled/binary, "/content[^\"]*)\"">>,
                            [{capture, all_but_first, list}]),
    {200, PdfHeaders, Pdf} = case unescape(Url) of
                                 "/" ++ _ = P -> req(Config, get, P, [], undefined);
                                 Abs -> req_url(Abs, get, [], undefined)
                             end,
    ?assertMatch("application/pdf" ++ _, proplists:get_value("content-type", PdfHeaders)),
    ?assertMatch(<<"%PDF", _/binary>>, Pdf),
    %% approve with the hash
    R = ok_act(Config, muse_ui_activity, decide,
               #{action => AId, hash => Hash, decision => approve, scope => {task, Id}}, #{}),
    ?assert(contains(R, <<"task-body-", Id/binary>>)),
    #{<<"status">> := <<"succeeded">>, <<"result">> := Receipt} = muse_actions:get(?O, AId),
    ?assertMatch(<<"Saved to local sent mail · "/utf8, _/binary>>, Receipt),
    run_pending(),
    #{<<"status">> := <<"succeeded">>} = task(Id),
    Done = page(Config, Path),
    has(Done, <<"data-receipt">>),
    has(Done, Receipt),
    has(Done, <<"Approved action completed">>),
    has(page(Config, "/notifications"), <<"Ready for your review">>).

unescape(Url) ->
    binary_to_list(binary:replace(list_to_binary(Url), <<"&amp;">>, <<"&">>, [global])).

task_card_and_pushes(_Config) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"Card me">>}),
    Card = iolist_to_binary(aihtml:render(muse_ui_activity:task_card(?O, Id))),
    has(Card, <<"id=\"task-card-", Id/binary, "\"">>),
    has(Card, <<"href=\"/activity/", Id/binary, "\"">>),
    has(Card, <<"queued">>),
    Topics = [muse_ui:topic(?O, T) || T <- [{task_card, Id}, {task, Id}, activity]],
    ok = aihtml_push:join(Topics),
    {ok, _} = muse_agent_service:control(?O, Id, <<"pause">>),
    ok = muse_ui_activity:on_event(?O, {task, Id}),
    Pushed = drain(<<>>),
    has(Pushed, <<"task-card-", Id/binary>>),
    has(Pushed, <<"task-body-", Id/binary>>),
    has(Pushed, <<"activity-body">>),
    has(Pushed, <<"paused">>),
    ok = muse_ui_activity:on_event(?O, {run_event, Id, #{}}),
    has(drain(<<>>), <<"task-timeline-", Id/binary>>),
    %% nobody follows: nothing is rendered or sent
    ok = muse_ui_goals:on_event(?O, {goal, <<"g">>}),
    ok = muse_ui_monitors:on_event(?O, {monitor, <<"m">>}),
    ok = muse_ui_ideas:on_event(?O, {idea, all}),
    ok = muse_ui_notifications:on_event(?O, {notification, <<"n">>}),
    ?assertEqual(<<>>, drain(<<>>)),
    _ = aihtml_push:leave(Topics),
    ok.

drain(Acc) ->
    receive
        {aihtml_push, _, Json} -> drain(<<Acc/binary, Json/binary>>)
    after 300 -> Acc
    end.

goals_page(Config) ->
    has(page(Config, "/goals"), <<"goal-form">>),
    ok_act(Config, muse_ui_goals, create, #{},
           form(#{<<"title">> => <<"Autumn trip">>, <<"description">> => <<"Plan it">>,
                  <<"milestones">> => <<"Book train\r\n\r\nPack bags\r\n">>})),
    [#{<<"id">> := GId, <<"milestones">> := [#{<<"id">> := M1, <<"title">> := <<"Book train">>},
                                              #{<<"title">> := <<"Pack bags">>}]}] =
        muse_store:list(?O, <<"goals">>),
    Html = page(Config, "/goals"),
    has(Html, <<"goal-", GId/binary>>),
    has(Html, <<"Autumn trip">>),
    has(Html, <<"ms-", GId/binary, "-", M1/binary>>),
    ok_act(Config, muse_ui_goals, milestone, #{goal => GId, milestone => M1},
           #{<<"type">> => <<"change">>, <<"checked">> => true}),
    #{<<"milestones">> := [#{<<"done">> := true}, #{<<"done">> := false}]} = muse_store:get(?O, <<"goals">>, GId),
    ok_act(Config, muse_ui_goals, milestone, #{goal => GId, milestone => M1},
           #{<<"type">> => <<"change">>, <<"checked">> => false}),
    #{<<"milestones">> := [#{<<"done">> := false}, _]} = muse_store:get(?O, <<"goals">>, GId),
    ok_act(Config, muse_ui_goals, status, #{goal => GId, status => <<"paused">>}, #{}),
    #{<<"status">> := <<"paused">>} = muse_store:get(?O, <<"goals">>, GId),
    ok_act(Config, muse_ui_goals, status, #{goal => GId, status => <<"completed">>}, #{}),
    #{<<"status">> := <<"completed">>} = muse_store:get(?O, <<"goals">>, GId),
    %% invalid input is a toast
    {200, R} = act(Config, muse_ui_goals, create, #{}, form(#{<<"title">> => <<"  ">>})),
    ?assert(contains(R, <<"操作失败"/utf8>>)),
    ?assert(contains(ok_act(Config, muse_ui_goals, refresh, #{}, #{}), <<"goals-body">>)).

%% README "Try it" step 2 in the UI: watch the sample availability page,
%% change it, check now, get the alert.
monitors_page(Config) ->
    Html0 = page(Config, "/monitors"),
    has(Html0, <<"monitor-form">>),
    has(Html0, <<"sample-page-form">>),
    ok_act(Config, muse_ui_monitors, sample_page, #{check => false},
           form(#{<<"text">> => <<"No tables available tonight.">>})),
    ok_act(Config, muse_ui_monitors, create, #{},
           form(#{<<"title">> => <<"Dinner">>, <<"url">> => <<"sample://availability">>,
                  <<"condition">> => <<"contains">>, <<"value">> => <<"table for 2">>,
                  <<"intervalMinutes">> => <<"5">>})),
    ok_act(Config, muse_ui_monitors, create, #{},
           form(#{<<"title">> => <<"Any change">>, <<"url">> => <<"sample://availability">>,
                  <<"condition">> => <<"change">>, <<"value">> => <<>>, <<"intervalMinutes">> => <<"15">>})),
    Monitors = muse_store:list(?O, <<"monitors">>),
    [#{<<"id">> := Mid}] = [M || M = #{<<"title">> := <<"Dinner">>} <- Monitors],
    [#{<<"id">> := Cid, <<"taskId">> := CTask}] = [M || M = #{<<"title">> := <<"Any change">>} <- Monitors],
    #{<<"condition">> := <<"contains">>, <<"intervalMinutes">> := 5} = muse_store:get(?O, <<"monitors">>, Mid),
    run_pending(),
    #{<<"checks">> := 1} = muse_store:get(?O, <<"monitors">>, Mid),
    ?assertEqual([], [N || N = #{<<"title">> := <<"Dinner">>} <- muse_agent_service:notifications(?O)]),
    %% edit the test page and check now
    ok_act(Config, muse_ui_monitors, sample_page, #{check => true},
           form(#{<<"text">> => <<"Good news: one table for 2 at 7pm.">>})),
    #{<<"text">> := <<"Good news: one table for 2 at 7pm.">>} =
        muse_store:get(?O, <<"sample-pages">>, <<"availability">>),
    run_pending(),
    #{<<"checks">> := 2} = muse_store:get(?O, <<"monitors">>, Mid),
    [#{<<"body">> := Alert}] = [N || N = #{<<"title">> := <<"Dinner">>} <- muse_agent_service:notifications(?O)],
    has(Alert, <<"table for 2">>),
    Html = page(Config, "/monitors"),
    has(Html, <<"monitor-", Mid/binary>>),
    has(Html, <<"Good news">>),
    %% the change watch shows the latest change as a diff
    has(Html, <<"monitor-diff-", CTask/binary>>),
    has(Html, <<"ah-diff">>),
    %% controls
    Ctl = fun(Op) -> ok_act(Config, muse_ui_monitors, control, #{monitor => Mid, op => Op}, #{}) end,
    Ctl(<<"pause">>),
    #{<<"status">> := <<"paused">>} = muse_store:get(?O, <<"monitors">>, Mid),
    Ctl(<<"resume">>),
    #{<<"status">> := <<"active">>} = muse_store:get(?O, <<"monitors">>, Mid),
    Ctl(<<"check">>),
    Ctl(<<"stop">>),
    #{<<"status">> := <<"stopped">>} = muse_store:get(?O, <<"monitors">>, Mid),
    {200, R} = act(Config, muse_ui_monitors, control, #{monitor => Mid, op => <<"resume">>}, #{}),
    ?assert(contains(R, <<"Create a new watch">>)),
    #{<<"status">> := <<"active">>} = muse_store:get(?O, <<"monitors">>, Cid),
    %% validation errors come back as a toast
    {200, R2} = act(Config, muse_ui_monitors, create, #{},
                    form(#{<<"title">> => <<"Bad">>, <<"url">> => <<"ftp://x">>, <<"condition">> => <<"change">>})),
    ?assert(contains(R2, <<"操作失败"/utf8>>)),
    ?assert(contains(ok_act(Config, muse_ui_monitors, refresh, #{}, #{}), <<"monitors-body">>)).

ideas_page(Config) ->
    Ideas = muse_store:list(?O, <<"ideas">>),
    [#{<<"id">> := Doc}] = [I || I = #{<<"kind">> := <<"document">>, <<"status">> := <<"new">>} <- Ideas],
    [#{<<"id">> := Other} | _] = [I || I = #{<<"kind">> := K, <<"status">> := <<"new">>} <- Ideas, K =/= <<"document">>],
    Html = page(Config, "/ideas"),
    has(Html, <<"idea-", Doc/binary>>),
    has(Html, <<"idea-prompt-", Doc/binary>>),
    has(Html, <<"A little reminder: permission slips are due Friday">>),
    ok_act(Config, muse_ui_ideas, accept, #{idea => Doc},
           form(#{<<"prompt">> => <<"  Fill the slip for Sam and draft a reply  ">>})),
    #{<<"status">> := <<"accepted">>, <<"taskId">> := TaskId} = muse_store:get(?O, <<"ideas">>, Doc),
    #{<<"prompt">> := <<"Fill the slip for Sam and draft a reply">>, <<"kind">> := <<"document">>} = task(TaskId),
    ok_act(Config, muse_ui_ideas, dismiss, #{idea => Other}, #{}),
    #{<<"status">> := <<"dismissed">>} = muse_store:get(?O, <<"ideas">>, Other),
    has(page(Config, "/ideas"), <<"/activity/", TaskId/binary>>),
    %% an empty prompt is refused
    {200, R} = act(Config, muse_ui_ideas, accept, #{idea => Other}, form(#{<<"prompt">> => <<"   ">>})),
    ?assert(contains(R, <<"操作失败"/utf8>>)),
    ?assert(contains(ok_act(Config, muse_ui_ideas, find, #{}, #{}), <<"ideas-body">>)).

notifications_page(Config) ->
    ok = muse_agent_service:notify(?O, <<"Hello there">>, <<"First body">>, undefined, undefined),
    {ok, #{<<"id">> := TaskId}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"p">>}),
    ok = muse_agent_service:notify(?O, <<"About a task">>, <<"Second">>, TaskId, undefined),
    Ns = muse_agent_service:notifications(?O),
    [#{<<"id">> := N1}] = [N || N = #{<<"title">> := <<"Hello there">>} <- Ns],
    [#{<<"id">> := N2}] = [N || N = #{<<"title">> := <<"About a task">>} <- Ns],
    Html = page(Config, "/notifications"),
    has(Html, <<"notification-", N1/binary>>),
    has(Html, <<"First body">>),
    ok_act(Config, muse_ui_notifications, read, #{id => N1}, #{}),
    #{<<"read">> := true} = muse_store:get(?O, <<"notifications">>, N1),
    R = ok_act(Config, muse_ui_notifications, open, #{id => N2, task => TaskId}, #{}),
    ?assert(contains(R, <<"/activity/", TaskId/binary>>)),
    #{<<"read">> := true} = muse_store:get(?O, <<"notifications">>, N2),
    ok = muse_agent_service:notify(?O, <<"Third">>, <<"x">>, undefined, undefined),
    ok_act(Config, muse_ui_notifications, read_all, #{}, #{}),
    ?assertEqual([], [N || N = #{<<"read">> := false} <- muse_agent_service:notifications(?O)]),
    ?assert(contains(ok_act(Config, muse_ui_notifications, refresh, #{}, #{}), <<"notifications-body">>)).

actions_need_session(Config) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"p">>}),
    {401, _} = act(Config, [], muse_ui_activity, control, #{task => Id, op => <<"cancel">>}, #{}),
    {401, _} = act(Config, [{"cookie", "muse_session=nope"}], muse_ui_activity, control,
                   #{task => Id, op => <<"cancel">>}, #{}),
    ?assertMatch(#{<<"status">> := <<"queued">>}, task(Id)).
