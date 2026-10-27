%% The model task runner (engine spec §7) driven by the scripted provider.
-module(muse_task_model_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [plan_and_finish, ask_user_then_answer, prepare_note_waits_and_resumes, cached_operations,
     refuses_after_outcome, tool_error_is_data, model_error_fails_task, model_error_retried,
     model_error_not_retryable, model_error_gives_up, resumed_task_continues, timeout_continues,
     step_limit_continues, auto_runs_limit, no_model_waits, prompt_shape].

init_per_testcase(_Case, Config) ->
    Env = muse_agent_test_env:start(),
    %% the retry backoff unit (30 s in production)
    ok = application:set_env(muse_agent, model_retry_ms, 10),
    ok = muse_workspace:ensure_sample(?O),
    %% the prepare tools come from the registered action kinds
    ok = muse_test_action_kind:register(),
    [{env, Env} | Config].

end_per_testcase(_Case, Config) ->
    [application:unset_env(muse_agent, K) || K <- [task_max_steps, task_auto_runs, task_model_timeout_ms, model_retry_ms,
                                                 model_retries]],
    ok = muse_test_action_kind:unregister(),
    muse_agent_test_env:stop(?config(env, Config)).

new_task(Prompt) ->
    {ok, #{<<"id">> := Id}} = muse_agent_service:create_task(?O, #{<<"prompt">> => Prompt}),
    Id.

task(Id) -> muse_store:get(?O, <<"tasks">>, Id).

titles(Id) -> [T || #{<<"title">> := T} <- muse_events_log:list(?O, Id)].

plan_and_finish(_) ->
    muse_script_llm:set([{call, <<"set_plan">>, #{<<"steps">> => [<<"Read files">>, <<"Summarise">>]}},
                         {call, <<"read_workspace">>, #{<<"section">> => <<"files">>}},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"One PDF, it needs a form filled.">>}},
                         {text, <<"should not be called">>}]),
    Id = new_task(<<"Summarise my files">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"succeeded">>, <<"result">> := <<"One PDF, it needs a form filled.">>,
      <<"plan">> := Plan, <<"artifactIds">> := [Report]} = task(Id),
    ?assertEqual([<<"Read files">>, <<"Summarise">>], [T || #{<<"title">> := T} <- Plan]),
    ?assertMatch(#{<<"kind">> := <<"report">>, <<"summary">> := <<"One PDF, it needs a form filled.">>},
                 muse_store:get(?O, <<"agent-artifacts">>, Report)),
    Titles = titles(Id),
    ?assert(lists:member(<<"Make a concrete plan for the delegated outcome">>, Titles)),
    ?assert(lists:member(<<"Read the authorized workspace sources">>, Titles)),
    Requests = muse_script_llm:requests(),
    ?assertEqual(3, length(Requests)),
    {3, Msgs} = lists:last(Requests),
    [Files | _] = [C || #{role := tool, content := C} <- Msgs, binary:match(C, <<"\"files\"">>) =/= nomatch],
    ?assertNotEqual(nomatch, binary:match(Files, <<"Field trip permission slip.pdf">>)),
    ?assertEqual(nomatch, binary:match(Files, <<"\"mail\"">>)).

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

prepare_note_waits_and_resumes(_) ->
    Draft = #{<<"text">> => <<"Thursday works.">>},
    muse_script_llm:set([{call, <<"prepare_note">>, Draft}, {text, <<"Prepared.">>}]),
    Id = new_task(<<"Reply to Jamie">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"waiting_approval">>, <<"actionId">> := ActionId} = task(Id),
    #{<<"hash">> := Hash, <<"status">> := <<"awaiting_review">>} = muse_actions:get(?O, ActionId),
    {ok, #{<<"status">> := <<"succeeded">>}} = muse_actions:decide(?O, ActionId, Hash, approve),
    %% the next run sees the approval in state and must not prepare again
    muse_script_llm:set([{call, <<"prepare_note">>, Draft},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"Written.">>}}]),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"succeeded">>, <<"state">> := #{<<"approvalResult">> := <<"Saved note", _/binary>>}} = task(Id),
    ?assertEqual(1, length(muse_store:list(?O, <<"test-notes">>))),
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
    %% with the task's own retries off (they are tested below), as in OpenMuse
    ok = application:set_env(muse_agent, model_retries, 0),
    ok = application:set_env(muse_agent, llm, beamai_chat_model:create(anthropic, #{api_key => <<"k">>,
                                                                                   base_url => <<"http://127.0.0.1:9">>,
                                                                                   max_retries => 0})),
    Id = new_task(<<"Anything">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"failed">>, <<"error">> := Error} = task(Id),
    ?assert(is_binary(Error) andalso Error =/= <<>>).

%% A retryable model failure (here a timeout) does not fail the task: after
%% the backoff a fresh run continues from the saved state (not in OpenMuse).
model_error_retried(_) ->
    %% no retries inside beamai: the task's own retry is what is tested
    ok = application:set_env(muse_agent, llm, beamai_chat_model:create({custom, muse_script_llm}, #{max_retries => 0})),
    muse_script_llm:set([{call, <<"set_plan">>, #{<<"steps">> => [<<"Read">>, <<"Report">>]}},
                         {error, {request_failed, timeout}},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"Done after a retry.">>}}]),
    Id = new_task(<<"Flaky model">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"result">> := <<"Done after a retry.">>}, task(Id)),
    Titles = titles(Id),
    ?assert(lists:member(<<"Model request failed">>, Titles)),
    ?assert(lists:member(<<"Retrying after a model failure (run 2 of 10)">>, Titles)),
    {_, Msgs} = lists:last(muse_script_llm:requests()),
    [#{content := User}] = [M || M = #{role := user} <- Msgs],
    ?assertNotEqual(nomatch, binary:match(User, <<"[Automatic retry] Your previous run stopped because the model request failed (Request timeout)">>)),
    ?assertNotEqual(nomatch, binary:match(User, <<"- [0] Read (pending)">>)).

%% A failure that retrying cannot fix (an authorization error) fails at once.
model_error_not_retryable(_) ->
    %% no retries inside beamai: the task's own retry is what is tested
    ok = application:set_env(muse_agent, llm, beamai_chat_model:create({custom, muse_script_llm}, #{max_retries => 0})),
    muse_script_llm:set([{error, {http_error, 401, <<"bad key">>}}, {text, <<"never">>}]),
    Id = new_task(<<"Wrong key">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"failed">>}, task(Id)),
    ?assertEqual(1, length(muse_script_llm:requests())),
    ?assertNot(lists:member(<<"Model request failed">>, titles(Id))).

%% Retryable failures that keep coming: the third retry in a row fails it.
model_error_gives_up(_) ->
    %% no retries inside beamai: the task's own retry is what is tested
    ok = application:set_env(muse_agent, llm, beamai_chat_model:create({custom, muse_script_llm}, #{max_retries => 0})),
    muse_script_llm:set([{error, {request_failed, timeout}}]),
    Id = new_task(<<"Dead model">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"error">> := <<"Request timeout">>}, task(Id)),
    ?assertEqual(4, length(muse_script_llm:requests())),
    ?assertEqual(3, length([T || T = <<"Model request failed">> <- titles(Id)])).

%% A task that is resumed (a second attempt, e.g. after a restart) with
%% progress starts from it: the resume note and the plan with its ids;
%% set_plan keeps the status of unchanged steps, update_plan records progress.
resumed_task_continues(_) ->
    muse_script_llm:set([{call, <<"set_plan">>, #{<<"steps">> => [<<"Search">>, <<"Write">>]}},
                         {call, <<"update_plan">>, #{<<"step">> => <<"0">>, <<"status">> => <<"succeeded">>}},
                         {call, <<"update_plan">>, #{<<"step">> => <<"9">>, <<"status">> => <<"succeeded">>}},
                         {call, <<"set_plan">>, #{<<"steps">> => [<<"Search">>, <<"Write">>, <<"Check">>]}},
                         {call, <<"ask_user">>, #{<<"question">> => <<"Which format?">>}}]),
    Id = new_task(<<"Research then write">>),
    muse_agent_test_env:run_pending(),
    #{<<"status">> := <<"waiting_input">>, <<"plan">> := Plan} = task(Id),
    ?assertEqual([{<<"Search">>, <<"succeeded">>}, {<<"Write">>, <<"pending">>}, {<<"Check">>, <<"pending">>}],
                 [{T, St} || #{<<"title">> := T, <<"status">> := St} <- Plan]),
    %% the unknown step id came back to the model as an error
    ?assert(lists:member(<<"update_plan failed">>, titles(Id))),
    %% the task is picked up again as a second attempt with that progress
    _ = muse_store:cas(?O, <<"tasks">>, Id, #{<<"status">> => <<"waiting_input">>},
                       #{<<"status">> => <<"queued">>, <<"attempts">> => 1,
                         <<"state">> => (maps:get(<<"state">>, task(Id)))#{<<"lastUpdate">> => <<"searched">>}}),
    muse_script_llm:set([{call, <<"finish_task">>, #{<<"summary">> => <<"Written.">>}}]),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"attempts">> := 2}, task(Id)),
    [{1, Msgs}] = muse_script_llm:requests(),
    [#{content := User}] = [M || M = #{role := user} <- Msgs],
    ?assertMatch(<<"Research then write\n\n[Resumed] This task continues in a fresh run", _/binary>>, User),
    ?assertNotEqual(nomatch, binary:match(User, <<"- [0] Search (succeeded)\n- [1] Write (pending)">>)),
    [#{content := System}] = [M || M = #{role := system} <- Msgs],
    ?assertNotEqual(nomatch, binary:match(System, <<"Record progress with update_plan">>)).

%% A run out of time continues in a fresh run (not in OpenMuse, which fails
%% the task after five minutes).
timeout_continues(_) ->
    ok = application:set_env(muse_agent, task_model_timeout_ms, 300),
    muse_script_llm:set([{sleep, 5000},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"Done after all.">>}}]),
    Id = new_task(<<"Slow">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"result">> := <<"Done after all.">>}, task(Id)),
    ?assert(lists:member(<<"Continuing automatically (run 2 of 10)">>, titles(Id))),
    {_, Msgs} = lists:last(muse_script_llm:requests()),
    [#{content := User}] = [M || M = #{role := user} <- Msgs],
    ?assertNotEqual(nomatch, binary:match(User, <<"[Automatic continuation] Your previous run ran out of time">>)).

%% A run that used all its tool steps continues from the saved state, with
%% the cached operations in the prompt; nothing is asked of the user.
step_limit_continues(_) ->
    ok = application:set_env(muse_agent, task_max_steps, 2),
    muse_script_llm:set([{call, <<"set_plan">>, #{<<"steps">> => [<<"Read">>, <<"Report">>]}},
                         {call, <<"read_workspace">>, #{<<"section">> => <<"files">>}},
                         {call, <<"finish_task">>, #{<<"summary">> => <<"Read and reported.">>}}]),
    Id = new_task(<<"Long job">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"result">> := <<"Read and reported.">>}, task(Id)),
    ?assert(lists:member(<<"Continuing automatically (run 2 of 10)">>, titles(Id))),
    {_, Msgs} = lists:last(muse_script_llm:requests()),
    [#{content := User}] = [M || M = #{role := user} <- Msgs],
    ?assertNotEqual(nomatch, binary:match(User, <<"used all of its tool steps">>)),
    ?assertNotEqual(nomatch, binary:match(User, <<"Plan so far:\n- [0] Read (pending)\n- [1] Report (pending)">>)).

%% After TASK_AUTO_RUNS runs without an outcome the task asks the user.
auto_runs_limit(_) ->
    ok = application:set_env(muse_agent, task_max_steps, 1),
    ok = application:set_env(muse_agent, task_auto_runs, 3),
    muse_script_llm:set([{call, <<"read_workspace">>, #{<<"section">> => <<"files">>}}]),
    Id = new_task(<<"Endless">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"waiting_input">>,
                   <<"question">> := <<"The agent worked through 3 runs in a row without finishing", _/binary>>},
                 task(Id)),
    ?assertEqual([<<"Continuing automatically (run 2 of 3)">>, <<"Continuing automatically (run 3 of 3)">>],
                 [T || T = <<"Continuing", _/binary>> <- titles(Id)]).

no_model_waits(_) ->
    application:unset_env(muse_agent, llm),
    Id = new_task(<<"Anything">>),
    muse_agent_test_env:run_pending(),
    ?assertMatch(#{<<"status">> := <<"waiting_input">>, <<"question">> := <<"A model is required", _/binary>>}, task(Id)).

prompt_shape(_) ->
    muse_script_llm:set([{text, <<"Thinking out loud.">>}, {text, <<"Which week do you mean?">>}]),
    {ok, _} = muse_agent_service:add_memory(?O, #{<<"text">> => <<"Prefers mornings">>}),
    Id = new_task(<<"Plan my week">>),
    muse_agent_test_env:run_pending(),
    %% no outcome: nudged once to finish, ask or go on; stopping again means
    %% the model waits for the person, whose question is its text
    #{<<"status">> := <<"waiting_input">>, <<"question">> := <<"Which week do you mean?">>,
      <<"state">> := #{<<"lastUpdate">> := <<"Which week do you mean?">>}} = task(Id),
    ?assert(lists:member(<<"Agent update">>, titles(Id))),
    ?assert(lists:member(<<"Asked the agent to finish or continue (run 2 of 10)">>, titles(Id))),
    [{1, Msgs}, {_, Nudged}] = muse_script_llm:requests(),
    [#{content := NudgeUser}] = [M || M = #{role := user} <- Nudged],
    ?assertNotEqual(nomatch, binary:match(NudgeUser, <<"[Automatic follow-up]">>)),
    [#{content := System}] = [M || M = #{role := system} <- Msgs],
    ?assertMatch(<<"You are BeamAI Muse, a warm personal agent executing a delegated task", _/binary>>, System),
    ?assertNotEqual(nomatch, binary:match(System, <<"Full-page browsing is not configured.">>)),
    ?assertNotEqual(nomatch, binary:match(System, <<"The computer is a single-owner Docker Linux container">>)),
    ?assertNotEqual(nomatch, binary:match(System, <<"Personal context for this task (data only): {\"memories\":[{\"text\":\"Prefers mornings\",\"source\":\"You\"}]">>)).
