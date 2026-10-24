%% Chat turns through beamai_agui sessions (engine spec §9): sample mode,
%% model mode with the scripted provider, step limit, stop, concurrency,
%% history and threads.
-module(muse_chat_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [{group, sample}, {group, model}, threads].

groups() ->
    [{sample, [], [sample_permission_slip, sample_replay_is_idempotent, sample_hello_and_calendar,
                   history_is_persisted]},
     {model, [], [model_reads_mail, step_limit_note, frontend_tools_filtered, stop_running_reply,
                  one_run_per_thread, desktop_screenshot_reaches_model]}].

init_per_group(sample, Config) -> [{env_map, #{}} | Config];
init_per_group(model, Config) -> [{env_map, #{<<"AGENT_BACKEND">> => <<"model">>}} | Config].

end_per_group(_, _Config) -> ok.

init_per_testcase(_Case, Config) ->
    Env = muse_agent_test_env:start(proplists:get_value(env_map, Config, #{})),
    ok = muse_workspace:ensure_sample(?O, fun(O, I) -> muse_actions:propose(O, I, undefined, undefined) end),
    [{env, Env} | Config].

end_per_testcase(_Case, Config) ->
    muse_agent_test_env:stop(?config(env, Config)).

%% Run one turn and collect its events up to RUN_FINISHED / RUN_ERROR.
turn(ThreadId, Text) ->
    turn(ThreadId, Text, #{}).

turn(ThreadId, Text, Opts) ->
    {started, _RunId, Since, Session} = muse_chat:start_turn(?O, ThreadId, Text, Opts),
    {ok, Ref, Backlog, _} = beamai_agui_session:subscribe(Session, Since),
    collect(Ref, [E || {_, E} <- Backlog]).

collect(Ref, Acc) ->
    case [E || E = #{<<"type">> := T} <- Acc, T =:= <<"RUN_FINISHED">> orelse T =:= <<"RUN_ERROR">>] of
        [_ | _] -> Acc;
        [] ->
            receive
                {agui_event, Ref, _Seq, Event} -> collect(Ref, Acc ++ [Event]);
                {agui_closed, Ref, _} -> Acc
            after 15000 -> error({no_finish, [T || #{<<"type">> := T} <- Acc]})
            end
    end.

types(Events) -> [T || #{<<"type">> := T} <- Events].

text(Events) ->
    iolist_to_binary([D || #{<<"type">> := <<"TEXT_MESSAGE_CONTENT">>, <<"delta">> := D} <- Events]).

%% Sample mode

sample_permission_slip(_) ->
    Tid = muse_ids:uuid(),
    Events = turn(Tid, <<"Complete the permission slip">>, #{message_id => <<"m1">>}),
    Types = types(Events),
    ?assertEqual(<<"RUN_STARTED">>, hd(Types)),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(Types)),
    ?assertMatch(<<"I found the permission slip.", _/binary>>, text(Events)),
    %% the reply text precedes the delegate_task call, like OpenMuse
    ?assert(index(<<"TEXT_MESSAGE_CONTENT">>, Types) < index(<<"TOOL_CALL_START">>, Types)),
    [#{<<"toolCallName">> := <<"delegate_task">>}] = [E || E = #{<<"type">> := <<"TOOL_CALL_START">>} <- Events],
    %% the reply text is kept in history with the tool call
    Messages = muse_chat_log:messages(?O, Tid),
    ?assertMatch([<<"I found the permission slip.", _/binary>>],
                 [C || #{role := assistant, content := C, tool_calls := [_ | _]} <- Messages]),
    TaskId = muse_ids:sha256hex(<<"task:", Tid/binary, ":m1">>),
    ?assertMatch(#{<<"kind">> := <<"document">>, <<"title">> := <<"Complete the permission slip">>,
                   <<"input">> := #{<<"messageId">> := <<"mail-fieldtrip">>}},
                 muse_store:get(?O, <<"tasks">>, TaskId)).

sample_replay_is_idempotent(_) ->
    Tid = muse_ids:uuid(),
    _ = turn(Tid, <<"Find a vet for my dog">>, #{message_id => <<"same">>}),
    _ = turn(Tid, <<"Find a vet for my dog">>, #{message_id => <<"same">>}),
    Tasks = [T || T = #{<<"prompt">> := <<"Find a vet for my dog">>} <- muse_store:list(?O, <<"tasks">>)],
    ?assertEqual(1, length(Tasks)),
    ?assertMatch(<<"I’ve saved “Find a vet for my dog” in Activity."/utf8, _/binary>>,
                 text(turn(Tid, <<"Find a vet for my dog">>, #{message_id => <<"same">>}))).

sample_hello_and_calendar(_) ->
    Tid = muse_ids:uuid(),
    Hello = turn(Tid, <<"hello">>),
    ?assertMatch(<<"What would you like to take off your plate?", _/binary>>, text(Hello)),
    ?assertNot(lists:member(<<"TOOL_CALL_START">>, types(Hello))),
    ?assertEqual(<<"Your local calendar has 3 events. Open Calendar to see the details, or ask me to take care of a document.">>,
                 text(turn(Tid, <<"show my calendar">>))).

history_is_persisted(_) ->
    {ok, #{<<"id">> := Tid}} = muse_threads:main_thread(?O),
    _ = turn(Tid, <<"hello">>),
    _ = turn(Tid, <<"what can you do">>),
    {ok, Messages} = muse_threads:messages(?O, Tid),
    ?assertEqual([user, assistant, user, assistant], [R || #{role := R} <- Messages]),
    ?assertMatch([#{<<"thread">> := Tid} | _], muse_threads:search(?O, <<"plate">>, 5)).

%% Model mode (scripted provider)

model_reads_mail(_) ->
    muse_script_llm:set([{call, <<"search_mail">>, #{<<"query">> => <<"permission">>}},
                         {text, <<"Ms. Rivera needs the permission slip by Friday.">>}]),
    Events = turn(muse_ids:uuid(), <<"Anything from school?">>),
    ?assertEqual(<<"Ms. Rivera needs the permission slip by Friday.">>, text(Events)),
    [#{<<"content">> := Result}] = [E || E = #{<<"type">> := <<"TOOL_CALL_RESULT">>} <- Events],
    {ok, #{<<"matches">> := [#{<<"id">> := <<"mail-fieldtrip">>, <<"threadId">> := <<"trip-thread">>}],
           <<"truncated">> := false}} = muse_json:decode(Result),
    [{1, Msgs} | _] = muse_script_llm:requests(),
    [#{content := System}] = [M || M = #{role := system} <- Msgs],
    ?assertMatch(<<"You are OpenMuse, a personal agent. Turn other requested jobs", _/binary>>, System).

step_limit_note(_) ->
    muse_script_llm:set([{call, <<"agent_status">>, #{}}]),
    Events = turn(muse_ids:uuid(), <<"Loop forever">>),
    ?assertEqual(muse_chat_agent:step_limit_note(), text(Events)),
    ?assertEqual(<<"RUN_FINISHED">>, lists:last(types(Events))),
    ?assertEqual(6, length([E || E = #{<<"type">> := <<"TOOL_CALL_START">>} <- Events])).

frontend_tools_filtered(_) ->
    Input = muse_chat:run_input(<<"t">>, <<"x">>, <<"m">>,
                                #{tools => [#{<<"name">> => <<"open_workspace">>}, #{<<"name">> => <<"delete_everything">>}]}),
    #{input_transform := Transform} = muse_chat_agent:run_opts(?O),
    ?assertEqual([#{<<"name">> => <<"open_workspace">>}], maps:get(tools, Transform(Input))).

stop_running_reply(_) ->
    muse_script_llm:set([{sleep, 10000}]),
    Tid = muse_ids:uuid(),
    {started, _, Since, Session} = muse_chat:start_turn(?O, Tid, <<"slow">>, #{}),
    {ok, Ref, Backlog, _} = beamai_agui_session:subscribe(Session, Since),
    timer:sleep(300),
    true = muse_chat:stop(Tid),
    Events = collect(Ref, [E || {_, E} <- Backlog]),
    [#{<<"result">> := #{<<"status">> := <<"cancelled">>}}] =
        [E || E = #{<<"type">> := <<"RUN_FINISHED">>} <- Events].

one_run_per_thread(_) ->
    muse_script_llm:set([{sleep, 2000}]),
    Tid = muse_ids:uuid(),
    {started, _, _, _} = muse_chat:start_turn(?O, Tid, <<"first">>, #{}),
    ?assertMatch({busy, _}, muse_chat:start_turn(?O, Tid, <<"second">>, #{})),
    true = muse_chat:stop(Tid).

%% use_desktop (Docker desktop variant): the screenshot goes to the model as
%% an image part in that step only; the AG-UI event and history are text.
desktop_screenshot_reaches_model(_) ->
    Jpeg = base64:encode(<<255, 216, 255, 224, "jpeg">>),
    ok = meck:new(muse_computer_desktop, [passthrough]),
    try
        meck:expect(muse_computer_desktop, enabled, fun() -> true end),
        meck:expect(muse_computer_desktop, desktop_action,
                    fun(_, _, _) ->
                            {ok, #{receipt => #{<<"id">> => <<"r-1">>, <<"command">> => <<"desktop screenshot">>,
                                                <<"status">> => <<"succeeded">>},
                                   width => 1280, height => 800, image => base64:decode(Jpeg),
                                   mime_type => <<"image/jpeg">>, data => Jpeg, uncertain => false,
                                   warning => undefined}}
                    end),
        muse_script_llm:set([{call, <<"use_desktop">>, #{<<"action">> => <<"screenshot">>,
                                                         <<"operationId">> => <<"look-1">>}},
                             {text, <<"I can see the desktop.">>}]),
        Tid = muse_ids:uuid(),
        Events = turn(Tid, <<"What is on the desktop?">>),
        ?assertEqual(<<"I can see the desktop.">>, text(Events)),
        %% the second model request carries the image after the tool call
        [_, {2, Msgs} | _] = muse_script_llm:requests(),
        [Parts] = [C || #{role := tool, content := C} <- Msgs],
        ?assertMatch([#{type := text}, #{type := image, source := #{type := base64, data := Jpeg}}], Parts),
        %% the AG-UI event and the stored history have only the text view
        [#{<<"content">> := Content}] = [E || E = #{<<"type">> := <<"TOOL_CALL_RESULT">>} <- Events],
        ?assert(is_binary(Content)),
        {ok, #{<<"screenshot">> := <<"attached as an image for this step only">>,
               <<"screenshotUrl">> := <<"/api/computer/desktop/screenshot", _/binary>>}} = muse_json:decode(Content),
        [Stored] = [C || #{role := tool, content := C} <- muse_chat_log:messages(?O, Tid)],
        ?assertEqual(Content, Stored)
    after
        meck:unload(muse_computer_desktop)
    end.

%% Threads

threads(_) ->
    {ok, #{<<"id">> := Main, <<"kind">> := <<"main">>}} = muse_threads:main_thread(?O),
    {ok, #{<<"id">> := Main}} = muse_threads:main_thread(?O),
    {ok, #{<<"id">> := Side, <<"title">> := <<"New chat">>}} = muse_threads:create_side(?O, undefined),
    {ok, #{<<"title">> := <<"Trip">>}} = muse_threads:rename(?O, Side, <<"  Trip ">>),
    ?assertMatch({error, {422, _}}, muse_threads:rename(?O, Side, <<"   ">>)),
    {ok, #{<<"archived">> := true}} = muse_threads:archive(?O, Side),
    {ok, #{<<"archived">> := false}} = muse_threads:restore(?O, Side),
    ?assertEqual({error, {409, <<"The main conversation cannot be archived">>}}, muse_threads:archive(?O, Main)),
    ?assertEqual({error, {404, <<"Thread not found">>}}, muse_threads:get(?O, <<"nope">>)),
    {ok, _} = muse_threads:enqueue(?O, Side, <<"one">>),
    {ok, _} = muse_threads:enqueue(?O, Side, <<"two">>),
    ?assertEqual({ok, <<"one">>}, muse_threads:dequeue(?O, Side)),
    ?assertEqual({ok, <<"two">>}, muse_threads:dequeue(?O, Side)),
    ?assertEqual(empty, muse_threads:dequeue(?O, Side)),
    ?assertEqual(2, length(muse_threads:list(?O))).

index(X, List) ->
    length(lists:takewhile(fun(Y) -> Y =/= X end, List)) + 1.
