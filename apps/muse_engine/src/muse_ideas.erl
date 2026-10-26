%% @doc Suggestions derived from the workspace (OpenMuse service.ts
%% `refreshIdeas` / `decideIdea`, engine spec §5.12).
%%
%% Source: active goals without milestones (plan ideas). OpenMuse also
%% suggested document and coordination work from mail; mail is gone, so
%% suggestions still waiting on an email are retired. Accepting an idea
%% creates (or links) its task; every accepted idea that is not already tied
%% to a goal creates one.
-module(muse_ideas).

-export([refresh/1, decide/4]).

-type owner() :: binary().

-define(IDEAS, <<"ideas">>).

-spec refresh(owner()) -> {ok, [map()]} | {error, term()}.
refresh(Owner) ->
    %% Retire mail-based suggestions; a concurrent acceptance wins its own CAS.
    _ = [muse_store:cas(Owner, ?IDEAS, Id, #{<<"status">> => <<"new">>}, #{<<"status">> => <<"dismissed">>})
         || #{<<"id">> := Id, <<"input">> := In} <- muse_store:list_by_status(Owner, ?IDEAS, <<"new">>),
            is_map_key(<<"messageId">>, In)],
    Now = muse_time:now_iso(),
    _ = [insert(Owner, goal_idea(G, Now)) || G = #{<<"milestones">> := []}
                                             <- muse_store:list_by_status(Owner, <<"goals">>, <<"active">>)],
    ok = muse_agent_service:ensure(Owner),
    _ = muse_store:cas(Owner, <<"agent-settings">>, <<"identity">>, #{}, #{<<"lastIdeasAt">> => Now}),
    muse_events:emit(Owner, {idea, all}),
    {ok, muse_store:list(Owner, ?IDEAS)}.

goal_idea(#{<<"id">> := Id, <<"title">> := Title} = G, Now) ->
    Desc = maps:get(<<"description">>, G, <<>>),
    #{<<"id">> => muse_ids:sha256hex(<<"goal:", Id/binary, ":", Desc/binary>>),
      <<"title">> => <<"Let's make a plan for ", Title/binary>>,
      <<"reason">> => <<"This goal has no milestones yet. A concrete plan will give it a next step.">>,
      <<"evidence">> => [#{<<"id">> => Id, <<"kind">> => <<"user">>, <<"title">> => Title, <<"excerpt">> => Desc}],
      <<"prompt">> => <<"Create an actionable plan for ", Title/binary, ". ", Desc/binary>>,
      <<"kind">> => <<"plan">>,
      <<"input">> => #{<<"goalId">> => Id},
      <<"status">> => <<"new">>,
      <<"createdAt">> => Now}.

insert(Owner, Idea) ->
    muse_store:insert_if_absent(Owner, ?IDEAS, Idea).

%% @doc accept | dismiss (spec §5.12 decideIdea). Returns the idea; a lost
%% dismiss race yields `{ok, null}` like OpenMuse.
-spec decide(owner(), binary(), binary(), binary() | undefined) -> {ok, map() | null} | {error, term()}.
decide(Owner, Id, Action, Prompt) ->
    case muse_store:get(Owner, ?IDEAS, Id) of
        undefined ->
            {error, {404, <<"Idea not found">>}};
        #{<<"status">> := <<"dismissed">>} = Idea ->
            {ok, Idea};
        #{<<"status">> := <<"accepted">>} = Idea when Action =:= <<"dismiss">> ->
            {ok, Idea};
        _ when Action =:= <<"dismiss">> ->
            Saved = muse_store:cas(Owner, ?IDEAS, Id, #{<<"status">> => <<"new">>}, #{<<"status">> => <<"dismissed">>}),
            muse_events:emit(Owner, {idea, Id}),
            {ok, null_or(Saved)};
        #{<<"status">> := <<"new">>} = Idea ->
            accept_new(Owner, Idea, Prompt);
        Idea ->
            ensure_task(Owner, Idea)
    end.

accept_new(Owner, #{<<"id">> := Id} = Idea, Prompt) ->
    Claimed = muse_store:cas(Owner, ?IDEAS, Id, #{<<"status">> => <<"new">>},
                             #{<<"status">> => <<"accepted">>,
                               <<"taskId">> => muse_ids:sha256hex(<<"task:idea:", Id/binary>>),
                               <<"prompt">> => case Prompt of
                                                   undefined -> maps:get(<<"prompt">>, Idea);
                                                   _ -> Prompt
                                               end}),
    case case Claimed of undefined -> muse_store:get(Owner, ?IDEAS, Id); _ -> Claimed end of
        #{<<"status">> := <<"accepted">>} = Accepted -> ensure_task(Owner, Accepted);
        Other -> {ok, null_or(Other)}
    end.

ensure_task(Owner, #{<<"id">> := Id} = Idea) ->
    TaskId = maps:get(<<"taskId">>, Idea, undefined),
    case is_binary(TaskId) andalso muse_store:get(Owner, <<"tasks">>, TaskId) =/= undefined of
        true ->
            {ok, Idea};
        false ->
            #{<<"title">> := Title, <<"reason">> := Reason, <<"input">> := Input} = Idea,
            maybe
                {ok, GoalId} ?= case maps:get(<<"goalId">>, Input, undefined) of
                                    G when is_binary(G) -> {ok, G};
                                    _ ->
                                        maybe
                                            {ok, #{<<"id">> := NewGoal}} ?=
                                                muse_agent_service:create_goal(
                                                  Owner, #{<<"title">> => Title, <<"description">> => Reason},
                                                  muse_ids:sha256hex(<<"idea-goal:", Id/binary>>)),
                                            {ok, NewGoal}
                                        end
                                end,
                {ok, #{<<"id">> := NewTask}} ?=
                    muse_agent_service:create_task(Owner, #{<<"title">> => Title,
                                                            <<"prompt">> => maps:get(<<"prompt">>, Idea),
                                                            <<"kind">> => maps:get(<<"kind">>, Idea),
                                                            <<"input">> => Input,
                                                            <<"goalId">> => GoalId},
                                                   <<"idea:", Id/binary>>, false),
                _ = muse_store:cas(Owner, ?IDEAS, Id, #{<<"status">> => <<"new">>},
                                   #{<<"status">> => <<"accepted">>, <<"taskId">> => NewTask}),
                muse_events:emit(Owner, {idea, Id}),
                {ok, null_or(muse_store:get(Owner, ?IDEAS, Id))}
            end
    end.

null_or(undefined) -> null;
null_or(V) -> V.
