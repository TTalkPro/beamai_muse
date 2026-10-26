%% @doc The form-filling workflow (OpenMuse service.ts `document`, engine
%% spec §5.10), started from a PDF in Files: take the chosen PDF
%% (`input.fileId`), ask for form values, save a filled copy and finish with
%% it. OpenMuse started from a mail attachment and ended with a reviewed
%% reply; mail is gone until the built-in mail exists, so the filled copy is
%% the outcome.
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
        _ -> fill_and_finish(Owner, Task1, Source, Fields, Ctx)
    end.

source(Owner, #{<<"state">> := State} = Task, Ctx) ->
    case maps:get(<<"source">>, State, undefined) of
        #{<<"fileId">> := _} = Source ->
            {Task, Source};
        _ ->
            File = case maps:get(<<"fileId">>, maps:get(<<"input">>, Task), undefined) of
                       FileId when is_binary(FileId) ->
                           case muse_files:get_pdf(Owner, FileId) of
                               {ok, Found} -> Found;
                               {error, {422, NotPdf}} -> muse_agent_service:fail(NotPdf);
                               {error, _} -> muse_agent_service:fail(<<"The chosen PDF is no longer in Files">>)
                           end;
                       _ ->
                           muse_agent_service:fail(<<"Choose a PDF in Files to start this task">>)
                   end,
            guard(Ctx),
            #{<<"id">> := Id, <<"name">> := Name} = File,
            Source = #{<<"fileId">> => Id},
            Plan = indexed_plan(Task, fun(0) -> <<"succeeded">>; (_) -> <<"pending">> end),
            Task1 = checkpoint(Ctx, #{<<"state">> => State#{<<"source">> => Source},
                                      <<"evidence">> => [muse_task:file_evidence(File)],
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

fill_and_finish(Owner, #{<<"id">> := TaskId} = Task0, #{<<"fileId">> := FileId} = Source, Fields, Ctx) ->
    State = maps:get(<<"state">>, Task0),
    {Task, Name} =
        case maps:get(<<"filledId">>, State, undefined) of
            Id when is_binary(Id) ->
                #{<<"name">> := N} = muse_agent_service:must(muse_files:get(Owner, Id)),
                {Task0, N};
            _ ->
                guard(Ctx),
                #{<<"id">> := NewId, <<"name">> := N} =
                    muse_agent_service:must(muse_files:fill(Owner, FileId, Fields, <<"document:", TaskId/binary>>)),
                T = checkpoint(Ctx, #{<<"state">> => State#{<<"source">> => Source, <<"filledId">> => NewId},
                                      <<"artifactIds">> => [NewId],
                                      <<"plan">> => indexed_plan(Task0, fun(I) when I =< 1 -> <<"succeeded">>;
                                                                           (_) -> <<"pending">> end)}),
                event(Ctx, <<"step">>, <<"Saved a filled copy">>, N),
                {T, N}
        end,
    muse_agent_service:finish(Task, Ctx, <<"Saved a filled copy in Files: ", Name/binary>>).

indexed_plan(#{<<"plan">> := Plan}, StatusOf) ->
    [S#{<<"status">> => StatusOf(I)} || {I, S} <- lists:zip(lists:seq(0, length(Plan) - 1), Plan)].

guard(#{guard := G}) -> G().
checkpoint(#{checkpoint := C}, Patch) -> C(Patch).
event(#{event := E}, Kind, Title, Detail) -> E(Kind, Title, Detail).
