%% @doc Starting and stopping chat turns (designs/05-web-ui.md §4).
%%
%% Used by the UI and by the AG-UI HTTP endpoint. A turn runs in the
%% thread's beamai_agui session (one run at a time; a disconnect does not
%% stop it). Before the agent starts, `prepare_input/2` applies the Jev
%% rules of OpenMuse `ConversationAgent.run` (engine spec §9.2): a
%% "[OpenMuse choice] " message is resolved into its continuation, and any
%% other user turn retires the previous choice panel. Their failures are
%% returned as `{error, Message}` (OpenMuse reports them as a RUN_ERROR
%% without RUN_STARTED).
-module(muse_chat).

-export([start_turn/4, prepare_input/2, run_input/4, stop/1, session/1]).

-type owner() :: binary().

%% @doc Start a turn with the user's `Text`. `Opts`: `message_id` (stable id
%% of the user message; replays with the same id are idempotent), `tools`
%% (frontend tools), `context`.
-spec start_turn(owner(), binary(), binary(), map()) ->
    {started, binary(), integer(), pid()} | {busy, binary()} | {error, binary()}.
start_turn(Owner, ThreadId, Text, Opts) ->
    Input0 = run_input(ThreadId, Text, maps:get(message_id, Opts, muse_ids:uuid()), Opts),
    case prepare_input(Owner, Input0) of
        {ok, Input} ->
            {ok, Session} = beamai_agui_sessions:ensure(ThreadId),
            case beamai_agui_session:start_run(Session, Input, muse_chat_agent:factory(Owner),
                                               #{run_opts => muse_chat_agent:run_opts(Owner)}) of
                {started, RunId, Since} ->
                    ok = muse_threads:touch(Owner, ThreadId),
                    {started, RunId, Since, Session};
                {busy, RunId} ->
                    {busy, RunId};
                {error, Reason} ->
                    logger:error("[OpenMuse] chat run did not start: ~0p",
                                 [case Reason of T when is_tuple(T), tuple_size(T) > 0 -> element(1, T); A -> A end]),
                    {error, <<"Could not start the reply">>}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc A single-message RunAgentInput.
-spec run_input(binary(), binary(), binary(), map()) -> map().
run_input(ThreadId, Text, MessageId, Opts) ->
    #{thread_id => ThreadId,
      run_id => muse_ids:uuid(),
      parent_run_id => undefined,
      messages => [#{<<"id">> => MessageId, <<"role">> => <<"user">>, <<"content">> => Text}],
      tools => maps:get(tools, Opts, []),
      context => maps:get(context, Opts, []),
      resume => [],
      state => #{},
      forwarded_props => #{}}.

%% @doc Jev handling before a run (choice continuation / expire on user turn).
-spec prepare_input(owner(), map()) -> {ok, map()} | {error, binary()}.
prepare_input(Owner, Input) ->
    ThreadId = beamai_agui_types:thread_id(Input),
    Messages = beamai_agui_types:messages(Input),
    case latest_user(Messages) of
        {ok, #{<<"content">> := Text} = Latest} when is_binary(Text) ->
            case muse_jev:choice(Owner, ThreadId, Text) of
                not_choice -> expire_on_user_turn(Owner, ThreadId, Input, Messages);
                {error, Msg} -> {error, Msg};
                {ok, #{<<"continuation">> := Continuation}} ->
                    {ok, Input#{messages => [case M of
                                                 Latest -> M#{<<"content">> => Continuation};
                                                 _ -> M
                                             end || M <- Messages]}}
            end;
        _ ->
            expire_on_user_turn(Owner, ThreadId, Input, Messages)
    end.

%% A new user turn retires the current panel before the agent runs.
expire_on_user_turn(Owner, ThreadId, Input, Messages) ->
    case lists:reverse(Messages) of
        [#{<<"role">> := <<"user">>} | _] ->
            case muse_jev:expire_on_user_turn(Owner, ThreadId, beamai_agui_types:run_id(Input)) of
                {error, Msg} -> {error, Msg};
                _ -> {ok, Input}
            end;
        _ ->
            {ok, Input}
    end.

latest_user(Messages) ->
    case lists:reverse([M || M = #{<<"role">> := <<"user">>} <- Messages]) of
        [Latest | _] -> {ok, Latest};
        [] -> none
    end.

%% @doc Stop the thread's running reply (the draft stays with the UI).
-spec stop(binary()) -> boolean().
stop(ThreadId) ->
    case session(ThreadId) of
        {ok, Session} -> beamai_agui_session:stop_run(Session);
        error -> false
    end.

-spec session(binary()) -> {ok, pid()} | error.
session(ThreadId) ->
    case beamai_agui_sessions:ensure(ThreadId) of
        {ok, Pid} -> {ok, Pid};
        _ -> error
    end.
