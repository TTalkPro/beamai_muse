%% @doc The permission-slip workflow (OpenMuse service.ts `document`,
%% engine spec §5.10): find the attached PDF, ask for form values, save a
%% filled copy, prepare a reply for review, finish once it is sent.
%%
%% Runs inside a task executor; failures throw (see muse_agent_service).
-module(muse_document_flow).

-export([run/3]).

-spec run(binary(), map(), muse_task_run:ctx()) -> map().
run(Owner, Task0, Ctx) ->
    {Task1, Source} = source(Owner, Task0, Ctx),
    #{<<"input">> := Input, <<"state">> := State} = Task1,
    Fields = case maps:get(<<"fields">>, Input, undefined) of
                 undefined -> #{};
                 F when is_map(F) ->
                     case muse_validate:check({record, {union, [{string, #{}}, boolean]}, #{}}, F) of
                         {ok, V} -> V;
                         {error, [Msg | _]} -> muse_agent_service:fail(Msg)
                     end;
                 Other ->
                     {error, [Msg | _]} = muse_validate:check({record, any, #{}}, Other),
                     muse_agent_service:fail(Msg)
             end,
    case map_size(Fields) of
        0 -> ask_for_fields(Owner, Source, State);
        _ -> fill_and_prepare(Owner, Task1, Source, Fields, Ctx)
    end.

source(Owner, #{<<"state">> := State} = Task, Ctx) ->
    case maps:get(<<"source">>, State, undefined) of
        #{<<"mail">> := _, <<"fileId">> := _} = Source ->
            {Task, Source};
        _ ->
            MessageId = maps:get(<<"messageId">>, maps:get(<<"input">>, Task), undefined),
            {ok, #{<<"mail">> := Mail}} = muse_workspace:snapshot(Owner, undefined),
            M = case [X || X = #{<<"id">> := Id} <- Mail, Id =:= MessageId] of
                    [Found | _] -> Found;
                    [] -> muse_agent_service:fail(<<"Choose a current email with a PDF attachment to start this task">>)
                end,
            Ref = case maps:get(<<"attachments">>, M, []) of
                      [R | _] -> R;
                      [] -> muse_agent_service:fail(<<"This email has no PDF attachment">>)
                  end,
            guard(Ctx),
            File = case muse_files:get(Owner, Ref) of
                       {ok, Known} -> Known;
                       {error, {404, _}} -> muse_agent_service:must(muse_workspace:import_attachment(Owner, Ref))
                   end,
            #{<<"id">> := FileId, <<"name">> := Name} = File,
            Source = #{<<"mail">> => M, <<"fileId">> => FileId},
            Plan = indexed_plan(Task, fun(0) -> <<"succeeded">>; (_) -> <<"pending">> end),
            Task1 = checkpoint(Ctx, #{<<"state">> => State#{<<"source">> => Source},
                                      <<"evidence">> => [muse_task:mail_evidence(M)],
                                      <<"plan">> => Plan}),
            event(Ctx, <<"step">>, <<"Found the document">>, Name),
            {Task1, Source}
    end.

ask_for_fields(Owner, #{<<"fileId">> := FileId} = Source, State) ->
    File = muse_agent_service:must(muse_files:get(Owner, FileId)),
    Supported = [F || F = #{<<"type">> := T} <- maps:get(<<"fields">>, File, []), T =/= <<"unsupported">>],
    case Supported of
        [] -> muse_agent_service:fail(<<"This PDF has no supported fillable fields. Open it in Files to review it.">>);
        _ -> ok
    end,
    Names = iolist_to_binary(lists:join(<<", ">>, [N || #{<<"name">> := N} <- Supported])),
    #{<<"status">> => <<"waiting_input">>,
      <<"question">> => <<"Enter the form values you want to use. Supported fields: ", Names/binary,
                          ". The original PDF will stay intact.">>,
      <<"state">> => State#{<<"source">> => Source, <<"missingFields">> => Supported}}.

fill_and_prepare(Owner, #{<<"id">> := TaskId, <<"input">> := Input} = Task0, Source, Fields, Ctx) ->
    #{<<"mail">> := Mail, <<"fileId">> := FileId} = Source,
    {Task, FilledId} =
        case maps:get(<<"filledId">>, maps:get(<<"state">>, Task0), undefined) of
            Id when is_binary(Id) -> {Task0, Id};
            _ ->
                guard(Ctx),
                #{<<"id">> := NewId, <<"name">> := Name} =
                    muse_agent_service:must(muse_files:fill(Owner, FileId, Fields, <<"document:", TaskId/binary>>)),
                T = checkpoint(Ctx, #{<<"state">> => (maps:get(<<"state">>, Task0))#{<<"source">> => Source,
                                                                                    <<"filledId">> => NewId},
                                      <<"artifactIds">> => [NewId],
                                      <<"plan">> => indexed_plan(Task0, fun(I) when I =< 1 -> <<"succeeded">>;
                                                                           (_) -> <<"pending">> end)}),
                event(Ctx, <<"step">>, <<"Saved a filled copy">>, Name),
                {T, NewId}
        end,
    Subject = maps:get(<<"subject">>, Mail),
    ReplySubject = case re:run(Subject, <<"^re:">>, [caseless, {capture, none}]) of
                       match -> Subject;
                       nomatch -> <<"Re: ", Subject/binary>>
                   end,
    Body = case maps:get(<<"reply">>, Input, undefined) of
               R when is_binary(R) -> R;
               _ -> <<"Hello,\n\nPlease find the completed form attached.\n\nThank you.">>
           end,
    Proposal = #{<<"kind">> => <<"email.send">>,
                 <<"data">> => #{<<"to">> => [maps:get(<<"from">>, Mail)],
                                 <<"cc">> => [], <<"bcc">> => [],
                                 <<"subject">> => ReplySubject,
                                 <<"body">> => Body,
                                 <<"attachmentIds">> => [FilledId],
                                 <<"threadId">> => maps:get(<<"threadId">>, Mail),
                                 <<"replyToMessageId">> => maps:get(<<"id">>, Mail)}},
    #{<<"id">> := ActionId} = muse_agent_service:prepare(Owner, Task, Proposal, <<"document-reply">>, Ctx),
    #{<<"status">> => <<"waiting_approval">>,
      <<"actionId">> => ActionId,
      <<"plan">> => indexed_plan(Task, fun(I) when I < 3 -> <<"succeeded">>;
                                          (3) -> <<"waiting">>;
                                          (_) -> <<"pending">> end)}.

indexed_plan(#{<<"plan">> := Plan}, StatusOf) ->
    [S#{<<"status">> => StatusOf(I)} || {I, S} <- lists:zip(lists:seq(0, length(Plan) - 1), Plan)].

guard(#{guard := G}) -> G().
checkpoint(#{checkpoint := C}, Patch) -> C(Patch).
event(#{event := E}, Kind, Title, Detail) -> E(Kind, Title, Detail).
