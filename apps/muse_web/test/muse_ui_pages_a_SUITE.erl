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
    [activity_list_detail_controls, activity_global_review, task_review_flow, permission_slip_flow, task_card_and_pushes,
     notifications_page, actions_need_session].

init_per_testcase(_Case, Config) ->
    Env = muse_web_test_env:start(),
    %% reviews use the test-only action kind (production registers only calendar.event)
    ok = muse_test_action_kind:register(),
    C = [{env, Env} | Config],
    [{cookie, sign_in(C)} | C].

end_per_testcase(_Case, Config) ->
    ok = muse_test_action_kind:unregister(),
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

note(Text) ->
    #{<<"kind">> => <<"test.note">>, <<"data">> => #{<<"text">> => Text}}.

activity_global_review(Config) ->
    %% the sample workspace seeds no proposal any more
    [] = muse_store:list(?O, <<"actions">>),
    {ok, #{<<"id">> := AId, <<"hash">> := Hash}} = muse_actions:propose(?O, note(<<"Visit">>), undefined, undefined),
    %% a stored proposal of a kind that is not registered (an old email.send)
    Old = #{<<"id">> => <<"old-mail">>, <<"kind">> => <<"email.send">>, <<"title">> => <<"Send “Trip”"/utf8>>,
            <<"status">> => <<"expired">>, <<"hash">> => <<"h">>,
            <<"data">> => #{<<"subject">> => <<"Trip">>, <<"to">> => [<<"office@lincoln.example">>]},
            <<"createdAt">> => muse_time:now_iso(), <<"expiresAt">> => muse_time:now_iso()},
    _ = muse_store:put(?O, <<"actions">>, Old),
    %% 审批 (`/approvals`) lists the pending review; 任务 links there
    List = page(Config, "/approvals"),
    has(List, <<"approval-", AId/binary>>),
    has(page(Config, "/activity"), <<"href=\"/approvals\"">>),
    has(List, binary:part(Hash, 0, 16)),
    %% the kind's display: title and fields
    has(List, <<"Write “Visit”"/utf8>>),
    has(List, <<"内容"/utf8>>),
    has(List, <<"批准"/utf8>>),
    ?assertEqual(nomatch, binary:match(List, <<"本地批准"/utf8>>)),
    %% a stale hash is refused
    {200, R1} = act(Config, muse_ui_activity, decide,
                    #{action => AId, hash => <<"stale">>, decision => approve, scope => approvals}, #{}),
    ?assert(contains(R1, <<"This proposal changed">>)),
    ?assertMatch(#{<<"status">> := <<"awaiting_review">>}, muse_actions:get(?O, AId)),
    R2 = ok_act(Config, muse_ui_activity, decide, #{action => AId, hash => Hash, decision => deny, scope => approvals}, #{}),
    ?assert(contains(R2, <<"approvals-body">>)),
    ?assertMatch(#{<<"status">> := <<"denied">>}, muse_actions:get(?O, AId)),
    %% the unregistered kind still renders from its stored title and data
    Card = iolist_to_binary(aihtml_html:render(muse_ui_activity:approval_card(?O, Old, list))),
    has(Card, <<"Send “Trip”"/utf8>>),
    has(Card, <<"office@lincoln.example">>),
    %% both are now under 已处理 on 审批
    History = page(Config, "/approvals"),
    has(History, <<"approval-row-", AId/binary>>),
    has(History, <<"approval-row-old-mail">>),
    has(History, <<"没有等待审批的事项"/utf8>>).

%% A task waiting on a review: the card in the task, approve with the hash,
%% the receipt.
task_review_flow(Config) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"prompt">> => <<"Write a note">>}),
    {ok, #{<<"id">> := AId, <<"hash">> := Hash}} = muse_actions:propose(?O, note(<<"Hello">>), undefined, Id),
    #{} = muse_store:cas(?O, <<"tasks">>, Id, #{}, #{<<"status">> => <<"waiting_approval">>, <<"actionId">> => AId}),
    Path = "/activity/" ++ binary_to_list(Id),
    Review = page(Config, Path),
    has(Review, <<"approval-", AId/binary>>),
    has(Review, <<"Write “Hello”"/utf8>>),
    has(Review, Hash),
    R = ok_act(Config, muse_ui_activity, decide,
               #{action => AId, hash => Hash, decision => approve, scope => {task, Id}}, #{}),
    ?assert(contains(R, <<"task-body-", Id/binary>>)),
    #{<<"status">> := <<"succeeded">>, <<"result">> := Receipt} = muse_actions:get(?O, AId),
    ?assertMatch(<<"Saved note · "/utf8, _/binary>>, Receipt),
    Done = page(Config, Path),
    has(Done, <<"data-receipt">>),
    has(Done, Receipt).

%% Acceptance (M6-3, now from Files): the permission slip in sample mode,
%% driven from the UI: fields -> a filled copy in Files -> succeeded.
permission_slip_flow(Config) ->
    [#{<<"id">> := FileId}] = muse_store:list(?O, <<"files">>),
    {ok, #{<<"id">> := Id}} =
        muse_agent_service:create_task(?O, #{<<"kind">> => <<"document">>,
                                             <<"title">> => <<"Complete the permission slip">>,
                                             <<"prompt">> => <<"Complete the permission slip">>,
                                             <<"input">> => #{<<"fileId">> => FileId}}),
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
    #{<<"status">> := <<"succeeded">>, <<"artifactIds">> := [Filled], <<"result">> := Result} = task(Id),
    ?assertEqual([], muse_store:list(?O, <<"actions">>)),
    Done = page(Config, Path),
    has(Done, Result),
    has(Done, <<"/api/files/", Filled/binary, "/content">>),
    has(Done, <<"查看 PDF"/utf8>>),
    %% the signed PDF link works
    {match, [Url]} = re:run(Done, <<"href=\"([^\"]*/api/files/", Filled/binary, "/content[^\"]*)\"">>,
                            [{capture, all_but_first, list}]),
    {200, PdfHeaders, Pdf} = case unescape(Url) of
                                 "/" ++ _ = P -> req(Config, get, P, [], undefined);
                                 Abs -> req_url(Abs, get, [], undefined)
                             end,
    ?assertMatch("application/pdf" ++ _, proplists:get_value("content-type", PdfHeaders)),
    ?assertMatch(<<"%PDF", _/binary>>, Pdf),
    has(page(Config, "/notifications"), <<"Complete the permission slip">>).

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
    ok = muse_ui_notifications:on_event(?O, {notification, <<"n">>}),
    ?assertEqual(<<>>, drain(<<>>)),
    _ = aihtml_push:leave(Topics),
    ok.

drain(Acc) ->
    receive
        {aihtml_push, _, Json} -> drain(<<Acc/binary, Json/binary>>)
    after 300 -> Acc
    end.

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
