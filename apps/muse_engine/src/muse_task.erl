%% @doc Task domain: input schemas and record construction
%% (OpenMuse packages/domain/src/agent.ts, engine spec §2–§3).
%%
%% Records are JSON-shaped binary-keyed maps. A task is always created with
%% `leaseId => null` and `leaseUntil => null`: CAS expectations such as
%% `#{<<"leaseId">> => null}` only match a key that is present.
-module(muse_task).

-export([create_schema/0, goal_schema/0, monitor_schema/0, memory_schema/0, identity_schema/0,
         answer_schema/0, goal_update_schema/0,
         new/4, plan_titles/1, steps/2, is_terminal/1, terminal/0,
         default_identity/0, mail_evidence/1]).

-define(KINDS, [<<"agent">>, <<"document">>, <<"monitor">>, <<"finance">>, <<"plan">>]).

%% @doc `createTaskSchema`.
-spec create_schema() -> muse_validate:schema().
create_schema() ->
    {object, [{<<"title">>, {optional, {string, #{trim => true, min => 1, max => 160}}}},
              {<<"prompt">>, {string, #{trim => true, min => 1, max => 12000}}},
              {<<"kind">>, {default, {enum, ?KINDS}, <<"agent">>}},
              {<<"goalId">>, {optional, {string, #{}}}},
              {<<"milestoneId">>, {optional, {string, #{min => 1, max => 200}}}},
              {<<"input">>, {default, {record, any, #{}}, #{}}}]}.

%% @doc `goalInputSchema`.
-spec goal_schema() -> muse_validate:schema().
goal_schema() ->
    {object, [{<<"title">>, {string, #{trim => true, min => 1, max => 160}}},
              {<<"description">>, {default, {string, #{max => 4000}}, <<>>}},
              {<<"category">>, {default, {string, #{max => 80}}, <<"Personal">>}},
              {<<"milestones">>, {default, {array, {string, #{min => 1, max => 200}}, #{max => 20}}, []}}]}.

%% @doc `monitorInputSchema` including its refinements.
-spec monitor_schema() -> muse_validate:schema().
monitor_schema() ->
    Base = {object, [{<<"title">>, {string, #{min => 1, max => 160}}},
                     {<<"url">>, {string, #{url => true, max => 4096}}},
                     {<<"condition">>, {default, {enum, [<<"change">>, <<"contains">>, <<"price_below">>]},
                                        <<"change">>}},
                     {<<"value">>, {default, {string, #{max => 300}}, <<>>}},
                     {<<"intervalMinutes">>, {default, {integer, #{min => 1, max => 10080}}, 15}}]},
    {refine, Base, fun refine_monitor/1}.

refine_monitor(#{<<"condition">> := Cond, <<"value">> := Value}) ->
    Blank = string:trim(Value) =:= <<>>,
    if
        Cond =/= <<"change">>, Blank -> {error, <<"Enter a condition value">>};
        Cond =:= <<"price_below">> ->
            case muse_js:number(Value) of
                N when is_number(N), N > 0 -> ok;
                _ -> {error, <<"Enter a positive price">>}
            end;
        true -> ok
    end.

-spec memory_schema() -> muse_validate:schema().
memory_schema() ->
    {object, [{<<"text">>, {string, #{trim => true, min => 1, max => 4000}}},
              {<<"source">>, {optional, {string, #{trim => true, min => 1, max => 200}}}}]}.

-spec identity_schema() -> muse_validate:schema().
identity_schema() ->
    {object, [{<<"name">>, {string, #{trim => true, min => 1, max => 80}}},
              {<<"tone">>, {enum, [<<"warm">>, <<"concise">>, <<"thoughtful">>]}},
              {<<"avatar">>, {optional, {enum, [<<"sky">>, <<"sand">>, <<"lilac">>]}}},
              {<<"showChatUpdates">>, {optional, boolean}}]}.

-spec answer_schema() -> muse_validate:schema().
answer_schema() ->
    {object, [{<<"answer">>, {string, #{trim => true, min => 1, max => 12000}}},
              {<<"fields">>, {optional, {record, {union, [{string, #{max => 12000}}, boolean]},
                                         #{key => {string, #{min => 1, max => 300}}}}}}]}.

-spec goal_update_schema() -> muse_validate:schema().
goal_update_schema() ->
    {object, [{<<"status">>, {optional, {enum, [<<"active">>, <<"paused">>, <<"completed">>]}}},
              {<<"milestones">>, {optional, {array, {object, [{<<"id">>, {string, #{min => 1, max => 200}}},
                                                              {<<"title">>, {string, #{trim => true, min => 1, max => 200}}},
                                                              {<<"done">>, boolean}]},
                                             #{max => 100}}}}]}.

%% @doc A new task record from validated input (spec §5.1 step 7).
-spec new(binary(), map(), binary(), map()) -> map().
new(Id, Input, Status, State) ->
    #{<<"prompt">> := Prompt, <<"kind">> := Kind, <<"input">> := TaskInput} = Input,
    Now = muse_time:now_iso(),
    Task = #{<<"id">> => Id,
             <<"title">> => maps:get(<<"title">>, Input, muse_js:slice(Prompt, 90)),
             <<"prompt">> => Prompt,
             <<"kind">> => Kind,
             <<"status">> => Status,
             <<"plan">> => steps(plan_titles(Kind), <<"pending">>),
             <<"evidence">> => [],
             <<"input">> => TaskInput,
             <<"state">> => State,
             <<"createdAt">> => Now,
             <<"updatedAt">> => Now,
             <<"attempts">> => 0,
             <<"leaseId">> => null,
             <<"leaseUntil">> => null,
             <<"artifactIds">> => []},
    maps:merge(Task, maps:with([<<"goalId">>, <<"milestoneId">>], Input)).

-spec plan_titles(binary()) -> [binary()].
plan_titles(<<"document">>) ->
    [<<"Find the source document">>, <<"Fill a new copy">>, <<"Prepare a reply">>,
     <<"Wait for your decision">>, <<"Record the outcome">>];
plan_titles(<<"monitor">>) ->
    [<<"Check the source">>, <<"Compare with the last observation">>, <<"Report a meaningful change">>];
plan_titles(<<"finance">>) ->
    [<<"Validate transactions">>, <<"Calculate the summary">>, <<"Save your tracker">>];
plan_titles(_) ->
    [<<"Understand the outcome">>, <<"Plan the work">>, <<"Use connected tools">>, <<"Return a result">>].

-spec steps([binary()], binary()) -> [map()].
steps(Titles, Status) ->
    [#{<<"id">> => integer_to_binary(I), <<"title">> => T, <<"status">> => Status}
     || {I, T} <- lists:zip(lists:seq(0, length(Titles) - 1), Titles)].

-spec terminal() -> [binary()].
terminal() ->
    [<<"succeeded">>, <<"failed">>, <<"cancelled">>].

-spec is_terminal(binary()) -> boolean().
is_terminal(Status) ->
    lists:member(Status, terminal()).

-spec default_identity() -> map().
default_identity() ->
    #{<<"name">> => <<"OpenMuse">>, <<"tone">> => <<"warm">>}.

%% @doc `mailEvidence(mail)`.
-spec mail_evidence(map()) -> map().
mail_evidence(#{<<"id">> := Id, <<"subject">> := Subject} = Mail) ->
    #{<<"id">> => Id, <<"kind">> => <<"mail">>, <<"title">> => Subject,
      <<"excerpt">> => muse_js:slice(maps:get(<<"body">>, Mail, <<>>), 400)}.
