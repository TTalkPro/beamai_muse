%% @doc Suggestions derived from the workspace (OpenMuse service.ts
%% `refreshIdeas` / `decideIdea`, engine spec §5.12).
%%
%% Sources: mail with a form-like attachment (document ideas), mail about
%% meeting up (coordination ideas), active goals without milestones (plan
%% ideas). Ideas whose mail was answered or already handled are retired.
%% Accepting an idea creates (or links) its task; every accepted idea that is
%% not already tied to a goal creates one.
-module(muse_ideas).

-export([refresh/1, decide/4]).

-type owner() :: binary().

-define(IDEAS, <<"ideas">>).

-spec refresh(owner()) -> {ok, [map()]} | {error, term()}.
refresh(Owner) ->
    maybe
        {ok, #{<<"mail">> := Mail}} ?= muse_workspace:snapshot(Owner, undefined),
        SentIds = [Id || #{<<"id">> := Id, <<"label">> := L} <- Mail, is_sent(L)],
        Completed = [<<K/binary, ":", M/binary>>
                     || #{<<"kind">> := K, <<"input">> := #{<<"messageId">> := M}}
                            <- muse_store:list_by_status(Owner, <<"tasks">>, <<"succeeded">>),
                        is_binary(M)],
        Obsolete = fun(Kind, MessageId) ->
                           is_binary(MessageId) andalso
                               (lists:member(MessageId, SentIds)
                                orelse lists:member(<<Kind/binary, ":", MessageId/binary>>, Completed))
                   end,
        %% Retire earlier suggestions too; a concurrent acceptance wins its own CAS.
        _ = [muse_store:cas(Owner, ?IDEAS, Id, #{<<"status">> => <<"new">>}, #{<<"status">> => <<"dismissed">>})
         || #{<<"id">> := Id, <<"kind">> := K, <<"input">> := In} <- muse_store:list_by_status(Owner, ?IDEAS, <<"new">>),
            Obsolete(K, maps:get(<<"messageId">>, In, undefined))],
        Now = muse_time:now_iso(),
        Docs = lists:sublist([M || M <- Mail, not Obsolete(<<"document">>, id(M)),
                                   maps:get(<<"attachments">>, M, []) =/= [],
                                   matches(M, <<"form|permission|complete|fill|sign">>)], 5),
        _ = [insert(Owner, document_idea(M, Now)) || M <- Docs],
        Meets = lists:sublist([M || M <- Mail, not Obsolete(<<"agent">>, id(M)),
                                    matches(M, <<"coffee|meet|available|schedule">>)], 5),
        _ = [insert(Owner, coordination_idea(M, Now)) || M <- Meets],
        _ = [insert(Owner, goal_idea(G, Now)) || G = #{<<"milestones">> := []}
                                                 <- muse_store:list_by_status(Owner, <<"goals">>, <<"active">>)],
        ok = muse_agent_service:ensure(Owner),
        _ = muse_store:cas(Owner, <<"agent-settings">>, <<"identity">>, #{}, #{<<"lastIdeasAt">> => Now}),
        muse_events:emit(Owner, {idea, all}),
        {ok, muse_store:list(Owner, ?IDEAS)}
    end.

document_idea(#{<<"id">> := Id, <<"subject">> := Subject, <<"sender">> := Sender} = M, Now) ->
    #{<<"id">> => muse_ids:sha256hex(<<"document:", Id/binary, ":", (maps:get(<<"body">>, M, <<>>))/binary>>),
      <<"title">> => <<"I can help with ", Subject/binary>>,
      <<"reason">> => <<Sender/binary, " sent a document that may need your attention. I can prepare it and a "
                        "reply for your review.">>,
      <<"evidence">> => [muse_task:mail_evidence(M)],
      <<"prompt">> => <<"Help complete the PDF from “"/utf8, Subject/binary,
                        "” and prepare a reply for review."/utf8>>,
      <<"kind">> => <<"document">>,
      <<"input">> => #{<<"messageId">> => Id},
      <<"status">> => <<"new">>,
      <<"createdAt">> => Now}.

coordination_idea(#{<<"id">> := Id, <<"subject">> := Subject, <<"sender">> := Sender} = M, Now) ->
    #{<<"id">> => muse_ids:sha256hex(<<"coordination:", Id/binary>>),
      <<"title">> => <<"I can help coordinate ", Subject/binary>>,
      <<"reason">> => <<Sender/binary, " mentioned getting together. I can check your calendar and prepare a "
                        "response for review.">>,
      <<"evidence">> => [muse_task:mail_evidence(M)],
      <<"prompt">> => <<"Review the email “"/utf8, Subject/binary,
                        "”, check my calendar, and propose a next step. Ask me about missing preferences "
                        "before preparing a reply."/utf8>>,
      <<"kind">> => <<"agent">>,
      <<"input">> => #{<<"messageId">> => Id},
      <<"status">> => <<"new">>,
      <<"createdAt">> => Now}.

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

accept_new(Owner, #{<<"id">> := Id, <<"kind">> := Kind, <<"input">> := Input} = Idea, Prompt) ->
    %% A task already working on (or done with) the same email is opened instead.
    Handling = case maps:get(<<"messageId">>, Input, undefined) of
                   M when is_binary(M) ->
                       [T || T = #{<<"kind">> := K, <<"input">> := TI, <<"status">> := S}
                                 <- muse_store:list(Owner, <<"tasks">>),
                             K =:= Kind, maps:get(<<"messageId">>, TI, undefined) =:= M,
                             S =/= <<"failed">>, S =/= <<"cancelled">>];
                   _ -> []
               end,
    case Handling of
        [#{<<"id">> := TaskId} | _] ->
            Saved = muse_store:cas(Owner, ?IDEAS, Id, #{<<"status">> => <<"new">>},
                                   #{<<"status">> => <<"accepted">>, <<"taskId">> => TaskId}),
            muse_events:emit(Owner, {idea, Id}),
            {ok, null_or(case Saved of undefined -> muse_store:get(Owner, ?IDEAS, Id); _ -> Saved end)};
        [] ->
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
            end
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

id(#{<<"id">> := Id}) -> Id.

is_sent(Label) ->
    re:run(Label, <<"^Sent\\b">>, [caseless, unicode, {capture, none}]) =:= match.

matches(M, Pattern) ->
    Text = <<(maps:get(<<"subject">>, M, <<>>))/binary, " ", (maps:get(<<"body">>, M, <<>>))/binary>>,
    re:run(Text, Pattern, [caseless, unicode, {capture, none}]) =:= match.
