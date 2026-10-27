%% The chat page (tasks/M6-ui.md M6-2): threads, sending with live relay
%% pushes, the send queue, stop, delegate, history re-render, the browser
%% help request (M9-5).
-module(muse_ui_chat_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [{group, sample}, {group, model}].

groups() ->
    [{sample, [], [page_and_threads, send_permission_slip, suggestions]},
     {model, [], [queue_while_running, stop_keeps_running_state_consistent, takeover_help_request]}].

init_per_group(sample, Config) -> [{env_map, #{}} | Config];
init_per_group(model, Config) -> [{env_map, #{<<"AGENT_BACKEND">> => <<"model">>}} | Config].

end_per_group(_, _Config) -> ok.

init_per_testcase(takeover_help_request, Config) ->
    ok = muse_fake_browser:start(),
    Env = muse_web_test_env:start(maps:merge(proplists:get_value(env_map, Config, #{}),
                                             #{<<"BROWSER_ENABLED">> => <<"true">>})),
    [{env, Env}, {cookie, sign_in(Env)}, {worker, true} | Config];
init_per_testcase(_Case, Config) ->
    Env = muse_web_test_env:start(proplists:get_value(env_map, Config, #{})),
    Cookie = sign_in(Env),
    [{env, Env}, {cookie, Cookie} | Config].

end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)),
    case ?config(worker, Config) of
        true -> muse_fake_browser:stop();
        _ -> ok
    end.

%% HTTP helpers

origin() -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

sign_in(Env) ->
    Url = muse_web_test_env:base(Env) ++ "/login",
    {ok, {{_, 302, _}, H, _}} = httpc:request(post, {Url, [{"origin", origin()}], "application/x-www-form-urlencoded", ""},
                                              [{autoredirect, false}], [{body_format, binary}]),
    [SetCookie] = [V || {"set-cookie", V} <- H],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

page(Config, Path) ->
    Url = muse_web_test_env:base(?config(env, Config)) ++ Path,
    {ok, {{_, Status, _}, _, Body}} = httpc:request(get, {Url, [{"cookie", "muse_session=" ++ ?config(cookie, Config)}]},
                                                    [{autoredirect, false}], [{body_format, binary}]),
    {Status, Body}.

%% Run an action as the browser does; the reply's ops.
act(Config, Name, Args, Event) ->
    Token = aihtml_action:token({muse_ui_chat, Name, Args}),
    Body = muse_json:encode(#{<<"action">> => Token,
                              <<"event">> => maps:merge(#{<<"type">> => <<"click">>, <<"id">> => <<"x">>}, Event)}),
    Url = muse_web_test_env:base(?config(env, Config)) ++ "/aihtml/action",
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {Url, [{"cookie", "muse_session=" ++ ?config(cookie, Config)}, {"origin", origin()}],
                             "application/json", Body}, [{timeout, 30000}], [{body_format, binary}]),
    {ok, #{<<"ops">> := Ops}} = muse_json:decode(Resp),
    Ops.

form(Fields) -> #{<<"type">> => <<"submit">>, <<"form">> => Fields}.

main() ->
    {ok, #{<<"id">> := Tid}} = muse_threads:main_thread(?O),
    Tid.

%% Pushes to the thread's topic, until the composer is back to "send".
watch(Tid) ->
    ok = aihtml_push:join([muse_ui:topic(?O, {thread, Tid})]).

collect_run() -> collect_run([]).

collect_run(Acc) ->
    receive
        {aihtml_push, _, Json} ->
            Ops = case muse_json:decode(iolist_to_binary(Json)) of
                      {ok, #{<<"ops">> := L}} -> L;
                      {ok, L} when is_list(L) -> L
                  end,
            All = Acc ++ Ops,
            case [O || O = #{<<"id">> := <<"chat-actions">>, <<"html">> := H} <- Ops,
                       binary:match(H, <<"发送"/utf8>>) =/= nomatch] of
                [_ | _] -> All;
                [] -> collect_run(All)
            end
    after 15000 -> error({run_not_finished, Acc})
    end.

html_of(Ops) ->
    iolist_to_binary([[V || V <- [maps:get(<<"html">>, O, <<>>), maps:get(<<"value">>, O, <<>>)], is_binary(V)]
                      || O <- Ops]).

%% Cases

page_and_threads(Config) ->
    %% /chat is a new conversation: greeting, composer, starters; the shell
    %% has the sidebar (new conversation, the list) and no feature pages
    %% beyond tasks, files and settings here
    {200, Html} = page(Config, "/chat"),
    [?assertNotEqual(nomatch, binary:match(Html, Id), Id)
     || Id <- [<<"id=\"chat-log\"">>, <<"id=\"chat-composer\"">>, <<"id=\"chat-threads\"">>, <<"muse-composer">>,
               <<"muse-scroll">>, <<"id=\"muse-new-chat\"">>, <<"id=\"chat-empty\"">>, <<"muse-chat-empty">>,
               <<"id=\"muse-rename\"">>, <<"还没有会话"/utf8>>]],
    [?assertEqual(nomatch, binary:match(Html, Gone), Gone)
     || Gone <- [<<"href=\"/goals\"">>, <<"href=\"/monitors\"">>, <<"href=\"/ideas\"">>, <<"委派任务"/utf8>>,
                 <<"主会话"/utf8>>]],
    {match, [Tid]} = re:run(Html, <<"data-thread=\"([0-9a-f-]{36})\"">>, [{capture, all_but_first, binary}]),
    {error, {404, _}} = muse_threads:get(?O, Tid),
    %% the first message creates the conversation, titled after it
    watch(Tid),
    Ops = act(Config, send, #{thread => Tid, new => true}, form(#{<<"text">> => <<"Plan a picnic\nwith details">>})),
    ?assertMatch([_ | _], [O || O = #{<<"op">> := <<"url">>} <- Ops]),
    _ = collect_run(),
    {ok, #{<<"title">> := <<"Plan a picnic">>, <<"kind">> := <<"chat">>}} = muse_threads:get(?O, Tid),
    {200, Page} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    ?assertNotEqual(nomatch, binary:match(Page, <<"Plan a picnic">>)),
    ?assertEqual(nomatch, binary:match(Page, <<"muse-chat-empty">>)),
    %% pin, rename (the dialog's form), delete
    _ = act(Config, pin, #{thread => Tid, pinned => true}, #{}),
    {ok, #{<<"pinned">> := true}} = muse_threads:get(?O, Tid),
    {200, Pinned} = page(Config, "/chat"),
    ?assertNotEqual(nomatch, binary:match(Pinned, <<"置顶"/utf8>>)),
    _ = act(Config, rename, #{}, form(#{<<"thread">> => Tid, <<"title">> => <<"  Trip ">>})),
    {ok, #{<<"title">> := <<"Trip">>}} = muse_threads:get(?O, Tid),
    _ = act(Config, delete, #{thread => Tid}, #{}),
    {error, {404, _}} = muse_threads:get(?O, Tid),
    %% an unknown thread id (e.g. another owner's) does not start a turn
    _ = act(Config, send, #{thread => <<"not-mine">>}, form(#{<<"text">> => <<"hi">>})),
    false = muse_chat_relay:running(<<"not-mine">>),
    %% search: nothing matches
    SearchOps = act(Config, search, #{}, form(#{<<"q">> => <<"Plate">>})),
    ?assertNotEqual(nomatch, binary:match(html_of(SearchOps), <<"没有结果"/utf8>>)).

send_permission_slip(Config) ->
    Tid = main(),
    watch(Tid),
    Ops = act(Config, send, #{thread => Tid}, form(#{<<"text">> => <<"Complete the permission slip">>})),
    %% the composer is cleared in the sender's reply
    ?assertMatch([#{<<"op">> := <<"val">>, <<"id">> := <<"chat-text">>} | _], Ops),
    Pushed = collect_run(),
    Html = html_of(Pushed),
    %% user bubble, stop button, streamed text, the delegate_task card
    ?assertNotEqual(nomatch, binary:match(Html, <<"Complete the permission slip">>)),
    ?assertNotEqual(nomatch, binary:match(Html, <<"停止"/utf8>>)),
    ?assertMatch([_ | _], [O || O = #{<<"op">> := <<"text">>, <<"swap">> := <<"append">>} <- Pushed]),
    ?assertNotEqual(nomatch, binary:match(Html, <<"I found the permission slip.">>)),
    ?assertNotEqual(nomatch, binary:match(Html, <<"task-card-">>)),
    ?assertNotEqual(nomatch, binary:match(Html, <<"正在安排任务"/utf8>>)),
    %% the task exists; the relay is gone
    [_] = [T || T = #{<<"kind">> := <<"document">>} <- muse_store:list(?O, <<"tasks">>)],
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    %% a reload renders the history, including the card
    {200, Page} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    ?assertNotEqual(nomatch, binary:match(Page, <<"task-card-">>)),
    %% the text said together with the tool call is part of the history too
    %% (beamai 805b0ac keeps it)
    ?assertNotEqual(nomatch, binary:match(Page, <<"I found the permission slip.">>)),
    %% the refresh action re-renders the log
    Refresh = act(Config, refresh, #{thread => Tid}, #{}),
    ?assertNotEqual(nomatch, binary:match(html_of(Refresh), <<"Complete the permission slip">>)),
    %% and history is searchable
    Search = act(Config, search, #{}, form(#{<<"q">> => <<"Permission">>})),
    ?assertNotEqual(nomatch, binary:match(html_of(Search), <<"Main conversation">>)).

suggestions(Config) ->
    %% an empty conversation offers starters; clicking one sends it
    {200, Html} = page(Config, "/chat"),
    ?assertNotEqual(nomatch, binary:match(Html, <<"总结一下 copilotkit.ai"/utf8>>)),
    {match, [Tid]} = re:run(Html, <<"data-thread=\"([0-9a-f-]{36})\"">>, [{capture, all_but_first, binary}]),
    watch(Tid),
    _ = act(Config, suggest, #{thread => Tid, text => <<"总结一下 copilotkit.ai"/utf8>>}, #{}),
    _ = collect_run(),
    {ok, #{<<"title">> := <<"总结一下 copilotkit.ai"/utf8>>}} = muse_threads:get(?O, Tid),
    {ok, Messages} = muse_threads:messages(?O, Tid),
    ?assertMatch([#{role := user, content := <<"总结一下 copilotkit.ai"/utf8>>} | _], Messages).

queue_while_running(Config) ->
    muse_script_llm:set([{sleep, 1500}, {text, <<"second reply">>}]),
    Tid = main(),
    watch(Tid),
    _ = act(Config, send, #{thread => Tid}, form(#{<<"text">> => <<"first">>})),
    true = muse_chat_relay:running(Tid),
    _ = act(Config, send, #{thread => Tid}, form(#{<<"text">> => <<"second">>})),
    {ok, #{<<"pending">> := [<<"second">>]}} = muse_threads:get(?O, Tid),
    {200, Page} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    ?assertNotEqual(nomatch, binary:match(Page, <<"回复结束后依次发送"/utf8>>)),
    First = collect_run(),
    ?assertNotEqual(nomatch, binary:match(html_of(First), <<"late">>)),
    %% the queued message starts by itself
    Second = collect_run(),
    ?assertNotEqual(nomatch, binary:match(html_of(Second), <<"second reply">>)),
    {ok, #{<<"pending">> := []}} = muse_threads:get(?O, Tid),
    {ok, Messages} = muse_threads:messages(?O, Tid),
    ?assertEqual([<<"first">>, <<"second">>], [C || #{role := user, content := C} <- Messages]).

stop_keeps_running_state_consistent(Config) ->
    muse_script_llm:set([{sleep, 5000}]),
    Tid = main(),
    watch(Tid),
    _ = act(Config, send, #{thread => Tid}, form(#{<<"text">> => <<"slow">>})),
    timer:sleep(300),
    _ = act(Config, stop, #{thread => Tid}, #{}),
    _ = collect_run(),
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    {200, Page} = page(Config, "/chat"),
    ?assertEqual(nomatch, binary:match(Page, <<"停止"/utf8>>)).

%% The agent asks for help in the conversation; the user acts in the
%% console, then "处理好了，继续" starts the next turn with the agreed text.
takeover_help_request(Config) ->
    muse_script_llm:set([{call, <<"request_takeover">>, #{<<"reason">> => <<"The shop asks you to sign in">>,
                                                          <<"kind">> => <<"login">>,
                                                          <<"url">> => <<"https://example.com/login">>}},
                         {text, <<"Please sign in in the browser, then tell me.">>},
                         {text, <<"Thanks, continuing with the booking.">>}]),
    Tid = main(),
    watch(Tid),
    _ = act(Config, send, #{thread => Tid}, form(#{<<"text">> => <<"Book a table">>})),
    Pushed = html_of(collect_run()),
    ?assertNotEqual(nomatch, binary:match(Pushed, <<"需要你登录"/utf8>>)),
    %% the tool returned at once with the session and the console
    #{<<"sessionId">> := Sid} = muse_store:get(?O, <<"chat-browsers">>, Tid),
    [_, {2, Msgs} | _] = muse_script_llm:requests(),
    [Content] = [C || #{role := tool, content := C} <- Msgs],
    {ok, #{<<"sessionId">> := Sid, <<"kind">> := <<"login">>, <<"reason">> := <<"The shop asks you to sign in">>,
           <<"consoleUrl">> := <<"/browser/", Sid/binary>>}} = muse_json:decode(Content),
    %% the prompt tells the agent when to ask
    [{1, First} | _] = muse_script_llm:requests(),
    [#{content := System}] = [M || M = #{role := system} <- First],
    ?assertNotEqual(nomatch, binary:match(System, muse_chat_agent:takeover_prompt())),
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    %% the card stands in the log, outside the folded steps
    {200, Page} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    [?assertNotEqual(nomatch, binary:match(Page, P), P)
     || P <- [<<"muse-takeover">>, <<"需要你登录"/utf8>>, <<"The shop asks you to sign in">>, <<"example.com">>,
              <<"href=\"/browser/", Sid/binary, "\"">>, <<"打开浏览器处理"/utf8>>, <<"处理好了，继续"/utf8>>]],
    {match, [CallId]} = re:run(Page, <<"id=\"tc-([^\"]+)-go\"">>, [{capture, all_but_first, binary}]),
    {CardAt, _} = binary:match(Page, <<"muse-takeover">>),
    Before = binary:part(Page, 0, CardAt),
    ?assertEqual(length(binary:matches(Before, <<"<details">>)), length(binary:matches(Before, <<"</details>">>))),
    %% "处理好了，继续": the agreed message starts the next turn; the button is done
    Ops = act(Config, continue, #{thread => Tid, call => CallId}, #{}),
    [Done] = [H || #{<<"id">> := Id, <<"html">> := H} <- Ops, Id =:= <<"tc-", CallId/binary, "-go">>],
    ?assertNotEqual(nomatch, binary:match(Done, <<"已通知继续"/utf8>>)),
    ?assertEqual([], [O || O = #{<<"id">> := <<"chat-text">>} <- Ops]),
    Next = html_of(collect_run()),
    ?assertNotEqual(nomatch, binary:match(Next, <<"Thanks, continuing with the booking.">>)),
    {ok, Messages} = muse_threads:messages(?O, Tid),
    ?assertEqual([<<"Book a table">>, <<"我已经处理好了，请继续。"/utf8>>],
                 [C || #{role := user, content := C} <- Messages]),
    %% a reload shows the request as handled
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    {200, After} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    ?assertNotEqual(nomatch, binary:match(After, <<"已通知继续"/utf8>>)),
    ?assertEqual(nomatch, binary:match(After, <<"处理好了，继续"/utf8>>)).

wait_until(F) -> wait_until(F, 50).
wait_until(_F, 0) -> error(timeout);
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(100), wait_until(F, N - 1)
    end.
