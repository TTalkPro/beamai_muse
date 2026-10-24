%% The chat page (tasks/M6-ui.md M6-2): threads, sending with live relay
%% pushes, the send queue, stop, delegate, history re-render.
-module(muse_ui_chat_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [{group, sample}, {group, model}].

groups() ->
    [{sample, [], [page_and_threads, send_permission_slip, delegate_finance]},
     {model, [], [queue_while_running, stop_keeps_running_state_consistent]}].

init_per_group(sample, Config) -> [{env_map, #{}} | Config];
init_per_group(model, Config) -> [{env_map, #{<<"AGENT_BACKEND">> => <<"model">>}} | Config].

end_per_group(_, _Config) -> ok.

init_per_testcase(_Case, Config) ->
    Env = muse_web_test_env:start(proplists:get_value(env_map, Config, #{})),
    Cookie = sign_in(Env),
    [{env, Env}, {cookie, Cookie} | Config].

end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)).

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
    iolist_to_binary([[maps:get(<<"html">>, O, <<>>), maps:get(<<"value">>, O, <<>>)] || O <- Ops]).

%% Cases

page_and_threads(Config) ->
    {200, Html} = page(Config, "/chat"),
    [?assertNotEqual(nomatch, binary:match(Html, Id), Id)
     || Id <- [<<"id=\"chat-log\"">>, <<"id=\"chat-composer\"">>, <<"id=\"chat-threads\"">>, <<"muse-composer">>,
               <<"muse-scroll">>, <<"委派任务"/utf8>>]],
    [#{<<"op">> := <<"redirect">>, <<"value">> := <<"/chat/", Side/binary>>}] = act(Config, new_thread, #{}, #{}),
    {200, SideHtml} = page(Config, "/chat/" ++ binary_to_list(Side)),
    ?assertNotEqual(nomatch, binary:match(SideHtml, <<"New chat">>)),
    _ = act(Config, rename, #{thread => Side}, form(#{<<"title">> => <<"  Trip ">>})),
    {ok, #{<<"title">> := <<"Trip">>}} = muse_threads:get(?O, Side),
    [#{<<"op">> := <<"redirect">>, <<"value">> := <<"/chat">>}] = act(Config, archive, #{thread => Side}, #{}),
    {ok, #{<<"archived">> := true}} = muse_threads:get(?O, Side),
    %% the main thread cannot be archived
    [_ | _] = act(Config, archive, #{thread => main()}, #{}),
    {ok, #{<<"archived">> := false}} = muse_threads:get(?O, main()),
    _ = act(Config, restore, #{thread => Side}, #{}),
    {ok, #{<<"archived">> := false}} = muse_threads:get(?O, Side),
    %% an unknown thread id (e.g. another owner's) does not start a turn
    _ = act(Config, send, #{thread => <<"not-mine">>}, form(#{<<"text">> => <<"hi">>})),
    false = muse_chat_relay:running(<<"not-mine">>),
    %% search: nothing yet, then a hit after a turn
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
    ?assertNotEqual(nomatch, binary:match(Html, <<"委派任务"/utf8>>)),
    %% the task exists; the relay is gone
    [_] = [T || T = #{<<"kind">> := <<"document">>} <- muse_store:list(?O, <<"tasks">>)],
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    %% a reload renders the history, including the card
    {200, Page} = page(Config, "/chat"),
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

delegate_finance(Config) ->
    [#{<<"op">> := <<"val">>, <<"value">> := Csv}] = act(Config, sample_csv, #{}, #{}),
    [#{<<"op">> := <<"redirect">>, <<"value">> := <<"/activity/", Id/binary>>}] =
        act(Config, delegate, #{}, form(#{<<"kind">> => <<"finance">>, <<"prompt">> => <<"Summarize my spending">>,
                                         <<"csv">> => Csv})),
    #{<<"kind">> := <<"finance">>, <<"input">> := #{<<"csv">> := Csv}} = muse_store:get(?O, <<"tasks">>, Id),
    %% validation errors are shown in place
    Ops = act(Config, delegate, #{}, form(#{<<"kind">> => <<"agent">>, <<"prompt">> => <<"  ">>})),
    [#{<<"id">> := <<"delegate-result">>}] = Ops.

queue_while_running(Config) ->
    muse_script_llm:set([{sleep, 1500}, {text, <<"second reply">>}]),
    Tid = main(),
    watch(Tid),
    _ = act(Config, send, #{thread => Tid}, form(#{<<"text">> => <<"first">>})),
    true = muse_chat_relay:running(Tid),
    _ = act(Config, send, #{thread => Tid}, form(#{<<"text">> => <<"second">>})),
    {ok, #{<<"pending">> := [<<"second">>]}} = muse_threads:get(?O, Tid),
    {200, Page} = page(Config, "/chat"),
    ?assertNotEqual(nomatch, binary:match(Page, <<"待发送"/utf8>>)),
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

wait_until(F) -> wait_until(F, 50).
wait_until(_F, 0) -> error(timeout);
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(100), wait_until(F, N - 1)
    end.
