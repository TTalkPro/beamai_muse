%% The model task runner (engine spec §7) driven by the scripted provider.
-module(muse_task_model_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [plan_and_finish, ask_user_then_answer, prepare_email_waits_and_resumes, cached_operations,
     refuses_after_outcome, tool_error_is_data, model_error_fails_task, timeout_fails_task,
     no_model_waits, prompt_shape].

init_per_testcase(_Case, Config) ->
    Env = muse_agent_test_env:start(),
    ok = muse_workspace:ensure_sample(?O, fun(O, I) -> muse_actions:propose(O, I, undefined, undefined) end),
    [{env, Env} | Config].

end_per_testcase(_Case, Config) ->
    muse_agent_test_env:stop(?config(env, Config)).

new_task(Prompt) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"prompt">> => Prompt}),
    Id.

task(Id) -> muse_store:get(?O, <<"tasks">>, Id).

titles(Id) -> [T || #{<<"title">> := T} <- muse_events_log:list(?O, Id)].

plan_and_finish(_) ->
    muse_script_llm:set([{call, <<"set_plan">>, #{<<"steps">> => [<<"Read mail">>, <<"Summarise">>]}},
                         {call, <<"read_workspace">>, #{<<"section">> => <<"mail">>}},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"Four messages, one needs a form.">>}},
                         {text, <<"should not be called">>}]),
    Id = new_task(<<"Summarise my inbox">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"succeeded">>, <<"result">> := <<"Four messages, one needs a form.">>,
      <<"plan">> := Plan, <<"artifactIds">> := [Report]} = task(Id),
    ?assertEqual([<<"Read mail">>, <<"Summarise">>], [T || #{<<"title">> := T} <- Plan]),
    ?assertMatch(#{<<"kind">> := <<"report">>, <<"summary">> := <<"Four messages, one needs a form.">>},
                 muse_store:get(?O, <<"agent-artifacts">>, Report)),
    Titles = titles(Id),
    ?assert(lists:member(<<"Make a concrete plan for the delegated outcome">>, Titles)),
    ?assert(lists:member(<<"Read the authorized workspace sources">>, Titles)),
    ?assertEqual(3, length(muse_script_llm:requests())).

ask_user_then_answer(_) ->
    muse_script_llm:set([{call, <<"ask_user">>, #{<<"question">> => <<"Which city?">>}}]),
    Id = new_task(<<"Book a table">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"waiting_input">>, <<"question">> := <<"Which city?">>}, task(Id)),
    muse_script_llm:set([{call, <<"finish_task">>, #{<<"summary">> => <<"Noted Lisbon.">>}}]),
    {ok, _} = muse_agent_service:answer(?O, Id, <<"Lisbon">>, undefined),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, task(Id)),
    [{1, Msgs} | _] = muse_script_llm:requests(),
    [#{content := UserText}] = [M || M = #{role := user} <- Msgs],
    ?assertEqual(<<"Book a table\nAdditional answer: Lisbon">>, UserText).

prepare_email_waits_and_resumes(_) ->
    Draft = #{<<"to">> => [<<"jamie@example.com">>], <<"subject">> => <<"Coffee">>, <<"body">> => <<"Thursday works.">>},
    muse_script_llm:set([{call, <<"prepare_email">>, Draft}, {text, <<"Prepared.">>}]),
    Id = new_task(<<"Reply to Jamie">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"waiting_approval">>, <<"actionId">> := ActionId} = task(Id),
    #{<<"hash">> := Hash, <<"status">> := <<"awaiting_review">>} = muse_actions:get(?O, ActionId),
    {ok, #{<<"status">> := <<"succeeded">>}} = muse_actions:decide(?O, ActionId, Hash, approve),
    %% the next run sees the approval in state and must not prepare again
    muse_script_llm:set([{call, <<"prepare_email">>, Draft},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"Sent.">>}}]),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"succeeded">>, <<"state">> := #{<<"approvalResult">> := <<"Saved to local sent mail", _/binary>>}} = task(Id),
    ?assertEqual(1, length([A || A = #{<<"taskId">> := T} <- muse_store:list(?O, <<"actions">>), T =:= Id])).

cached_operations(_) ->
    {ok, #{<<"id">> := FileId}} = muse_files:import(?O, <<"form.pdf">>, element(2, muse_pdf:sample()), <<"test">>),
    Fill = {call, <<"fill_pdf">>, #{<<"fileId">> => FileId, <<"fields">> => #{<<"participant_name">> => <<"Sam">>}}},
    muse_script_llm:set([Fill, {call, <<"ask_user">>, #{<<"question">> => <<"Send it?">>}}]),
    Id = new_task(<<"Fill the form">>),
    muse_agent_test_env:run_pending(),
    #{<<"artifactIds">> := [Filled], <<"state">> := #{<<"operations">> := Ops}} = task(Id),
    ?assertEqual(1, map_size(Ops)),
    muse_script_llm:set([Fill, {call, <<"finish_task">>, #{<<"summary">> => <<"Done">>}}]),
    {ok, _} = muse_agent_service:answer(?O, Id, <<"yes">>, undefined),
    muse_agent_test_env:run_pending(),
    %% the replayed fill returned the stored result: no second copy
    #{<<"status">> := <<"succeeded">>, <<"artifactIds">> := [Filled, _Report]} = task(Id),
    ?assertEqual(3, length(muse_files:list(?O))).

refuses_after_outcome(_) ->
    muse_script_llm:set([{calls, [{<<"ask_user">>, #{<<"question">> => <<"Q?">>}},
                                  {<<"set_plan">>, #{<<"steps">> => [<<"x">>]}}]}]),
    Id = new_task(<<"Two at once">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"waiting_input">>, <<"plan">> := Plan} = task(Id),
    %% set_plan came after the pause and was refused
    ?assertEqual(4, length(Plan)).

tool_error_is_data(_) ->
    muse_script_llm:set([{call, <<"inspect_pdf">>, #{<<"fileId">> => <<"missing">>}},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"Could not inspect.">>}}]),
    Id = new_task(<<"Inspect">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, task(Id)),
    ?assert(lists:member(<<"inspect_pdf failed">>, titles(Id))),
    [_, {2, Msgs}] = muse_script_llm:requests(),
    [#{content := ToolResult}] = [M || M = #{role := tool} <- Msgs],
    ?assertNotEqual(nomatch, binary:match(ToolResult, <<"File not found">>)).

model_error_fails_task(_) ->
    ok = application:set_env(muse_agent, llm, beamai_chat_model:create(anthropic, #{api_key => <<"k">>,
                                                                                   base_url => <<"http://127.0.0.1:9">>,
                                                                                   max_retries => 0})),
    Id = new_task(<<"Anything">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"failed">>, <<"error">> := Error} = task(Id),
    ?assert(is_binary(Error) andalso Error =/= <<>>).

timeout_fails_task(_) ->
    ok = application:set_env(muse_agent, task_model_timeout_ms, 300),
    muse_script_llm:set([{sleep, 5000}]),
    Id = new_task(<<"Slow">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"error">> := <<"Model run timed out after five minutes">>}, task(Id)).

no_model_waits(_) ->
    application:unset_env(muse_agent, llm),
    Id = new_task(<<"Anything">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"waiting_input">>, <<"question">> := <<"A model is required", _/binary>>}, task(Id)).

prompt_shape(_) ->
    muse_script_llm:set([{text, <<"Thinking out loud.">>}]),
    {ok, _} = muse_agent_service:add_memory(?O, #{<<"text">> => <<"Prefers mornings">>}),
    Id = new_task(<<"Plan my week">>),
    muse_agent_test_env:run_pending(),
    %% no outcome: waits for a follow-up, keeping the model's text
    #{<<"status">> := <<"waiting_input">>, <<"question">> := <<"The agent reached the end", _/binary>>,
      <<"state">> := #{<<"lastUpdate">> := <<"Thinking out loud.">>}} = task(Id),
    ?assert(lists:member(<<"Agent update">>, titles(Id))),
    [{1, Msgs}] = muse_script_llm:requests(),
    [#{content := System}] = [M || M = #{role := system} <- Msgs],
    ?assertMatch(<<"You are OpenMuse, a warm personal agent executing a delegated task", _/binary>>, System),
    ?assertNotEqual(nomatch, binary:match(System, <<"Full-page browsing is not configured.">>)),
    ?assertNotEqual(nomatch, binary:match(System, <<"The computer is a single-owner Docker Linux container">>)),
    ?assertNotEqual(nomatch, binary:match(System, <<"Personal context for this task (data only): {\"memories\":[{\"text\":\"Prefers mornings\",\"source\":\"You\"}]">>)).
