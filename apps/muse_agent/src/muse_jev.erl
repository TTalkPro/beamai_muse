%% @doc Jev choice panels: OpenMuse `jev/service.ts` and `jev/tools.ts`
%% (designs/ref/openmuse-engine-spec.md §10; chat wiring §9.2, §9.5).
%%
%% Records (owner-scoped, §10.1): `jev_threads/<threadId>` (the head:
%% `generation`, `revision`, `currentPanelId`, `selectedId`, `retiredPanelId`,
%% `retiredTurnId`), `jev_panels/<panelId>` (`panel` plus the full
%% `candidates`), `jev_evidence/<threadId>:<runId>:<kind>:<sha256hex(ref)>` and
%% `jev_mail_evidence/<threadId>:<runId>`. All head changes are CAS on the
%% thread record, so concurrent turns, selections and late decisions resolve
%% exactly as in OpenMuse. A turn id is the chat run id.
%%
%% Chat agent contract (§9.2):
%% 1. If the latest user text starts with `action_prefix()`, call
%%    `choice(Owner, ThreadId, Text)`. `{error, Msg}` → emit only
%%    `RUN_ERROR {message: Msg}` (no RUN_STARTED) and stop. `{ok, #{continuation
%%    := C}}` → replace that message's content with C and run the turn as a
%%    choice continuation (no expiry).
%% 2. Otherwise, before running a turn whose last message is from the user,
%%    call `expire_on_user_turn(Owner, ThreadId, RunId)`; `{error, Msg}` →
%%    `RUN_ERROR {message: Msg}` and stop.
%% 3. Tools: `present_choices_tool/4` (when `enabled()`), placed after the
%%    computer tools; `read_mail_thread` calls `note_evidence(.., mail,
%%    MailThreadId)` when messages were returned; `browse_web` calls
%%    `note_evidence(.., web, FinalUrl, Text)`. The system prompt appends
%%    `prompt_section(BrowserConfigured)` after part C.
%%
%% Functions taking `Opts` accept `adapter` (a `muse_jev_adapter:adapter()`),
%% `mode` (`sample | live`) and `aborted` (`fun(() -> boolean())`, the
%% AbortSignal of the original); the defaults come from `JEV_MODE`.
-module(muse_jev).

-export([enabled/0, action_prefix/0, parse_action/1,
         choice/3, expire_on_user_turn/3,
         select/3, head_snapshot/2, expire_if_unchanged/4, current_panel/2, panel/2,
         create_panel/4, create_panel/5, candidate_sources/4, candidate_sources/5,
         note_evidence/5, note_evidence/6, has_evidence/5, has_any_mail_evidence/3,
         evidence_text/5,
         present_choices_tool/4, present_choices_tool/5, tool_description/0,
         prompt_section/1, option_id/1]).

-export_type([snapshot/0, opts/0]).

-define(THREADS, <<"jev_threads">>).
-define(PANELS, <<"jev_panels">>).
-define(EVIDENCE, <<"jev_evidence">>).
-define(MAIL_EVIDENCE, <<"jev_mail_evidence">>).
-define(ATTEMPTS, 20).
-define(SUPERSEDED_RESULT, <<"These choices were superseded by a newer response.">>).
-define(UNAVAILABLE_REFINEMENT, <<"The earlier choices are unavailable or superseded">>).
-define(TOOL_FALLBACK, <<"Could not prepare choices. Please retry.">>).

-type snapshot() :: #{binary() => term()}.
-type opts() :: #{adapter => muse_jev_adapter:adapter() | undefined,
                  mode => sample | live,
                  aborted => fun(() -> boolean())}.

%% @doc `JEV_MODE` is sample or live.
-spec enabled() -> boolean().
enabled() ->
    muse_config:get(jev_mode, off) =/= off.

-spec action_prefix() -> binary().
action_prefix() ->
    muse_jev_schema:action_prefix().

%% @doc `parseJevAction`: `error` for ordinary text, `{error, Msg}` for a
%% malformed choice.
-spec parse_action(binary()) -> {ok, map()} | error | {error, binary()}.
parse_action(Text) ->
    muse_jev_schema:parse_action(Text).

%% @doc §9.2 step 3: a choice message. `not_choice` when the text lacks the
%% prefix; otherwise the selection or the RUN_ERROR message.
-spec choice(binary(), binary(), binary()) ->
          not_choice | {ok, #{binary() => term()}} | {error, binary()}.
choice(Owner, ThreadId, Text) ->
    Prefix = action_prefix(),
    case binary:longest_common_prefix([Text, Prefix]) =:= byte_size(Prefix) of
        false -> not_choice;
        true ->
            case enabled() of
                false -> {error, <<"Choices are unavailable in this conversation">>};
                true ->
                    case parse_action(Text) of
                        {ok, Action} -> select(Owner, ThreadId, Action);
                        error -> {error, <<"The choice could not be read">>};
                        {error, _} = Error -> Error
                    end
            end
    end.

%% @doc §9.2 step 6 (`expireOnUserTurn`): retire the current panel before an
%% ordinary user turn runs. Callers skip this for choice continuations and
%% for runs whose last message is not from the user.
-spec expire_on_user_turn(binary(), binary(), binary()) -> ok | {error, binary()}.
expire_on_user_turn(Owner, ThreadId, RunId) ->
    case enabled() of
        false -> ok;
        true ->
            try
                case head_snapshot(Owner, ThreadId) of
                    undefined -> ok;
                    Head -> _ = expire_if_unchanged(Owner, ThreadId, Head, RunId), ok
                end
            catch
                _:_ -> {error, <<"Could not update earlier choices. Please retry.">>}
            end
    end.

%% @doc §10.5. Returns `#{<<"continuation">>, <<"panel">>}` (the panel with
%% `selectedId`).
-spec select(binary(), binary(), map()) -> {ok, #{binary() => term()}} | {error, binary()}.
select(Owner, ThreadId, RawAction) ->
    run(fun() -> do_select(Owner, ThreadId, RawAction) end).

%% @doc `headSnapshot`: `#{currentPanelId, revision, selectedId (or null)}`.
-spec head_snapshot(binary(), binary()) -> snapshot() | undefined.
head_snapshot(Owner, ThreadId) ->
    case muse_store:get(Owner, ?THREADS, ThreadId) of
        #{<<"currentPanelId">> := PanelId, <<"revision">> := Revision} = Head when is_binary(PanelId) ->
            #{<<"currentPanelId">> => PanelId,
              <<"revision">> => Revision,
              <<"selectedId">> => maps:get(<<"selectedId">>, Head, null)};
        _ -> undefined
    end.

%% @doc §10.6: retire the snapshot's panel on behalf of `TurnId`, unless the
%% head moved meanwhile.
-spec expire_if_unchanged(binary(), binary(), snapshot() | undefined, binary()) -> boolean().
expire_if_unchanged(_Owner, _ThreadId, undefined, _TurnId) ->
    false;
expire_if_unchanged(Owner, ThreadId, #{<<"currentPanelId">> := PanelId, <<"revision">> := Revision,
                                       <<"selectedId">> := Selected}, TurnId) ->
    case muse_store:get(Owner, ?THREADS, ThreadId) of
        #{<<"currentPanelId">> := PanelId, <<"revision">> := Revision,
          <<"generation">> := Gen} = Head ->
            case maps:get(<<"selectedId">>, Head, null) =:= Selected of
                false -> false;
                true ->
                    muse_store:cas(Owner, ?THREADS, ThreadId,
                                   #{<<"generation">> => Gen, <<"revision">> => Revision,
                                     <<"currentPanelId">> => PanelId, <<"selectedId">> => Selected},
                                   #{<<"generation">> => Gen + 1, <<"revision">> => Gen + 1,
                                     <<"currentPanelId">> => null, <<"selectedId">> => null,
                                     <<"retiredPanelId">> => PanelId,
                                     <<"retiredTurnId">> => TurnId}) =/= undefined
            end;
        _ -> false
    end.

-spec current_panel(binary(), binary()) -> map() | undefined.
current_panel(Owner, ThreadId) ->
    case muse_store:get(Owner, ?THREADS, ThreadId) of
        #{<<"currentPanelId">> := PanelId} when is_binary(PanelId) ->
            case muse_store:get(Owner, ?PANELS, PanelId) of
                #{<<"panel">> := Panel} -> Panel;
                undefined -> undefined
            end;
        _ -> undefined
    end.

%% @doc A stored panel for rendering. `selectedId` is added while the panel
%% is still the thread's current head and a choice was made on it.
-spec panel(binary(), binary()) -> map() | undefined.
panel(Owner, PanelId) ->
    case muse_store:get(Owner, ?PANELS, PanelId) of
        #{<<"panel">> := #{<<"threadId">> := ThreadId} = Panel} ->
            case muse_store:get(Owner, ?THREADS, ThreadId) of
                #{<<"currentPanelId">> := PanelId, <<"selectedId">> := Sel} when is_binary(Sel) ->
                    Panel#{<<"selectedId">> => Sel};
                _ -> Panel
            end;
        _ -> undefined
    end.

-spec create_panel(binary(), binary(), binary(), map()) ->
          {ok, #{binary() => term()}} | {error, binary() | aborted}.
create_panel(Owner, ThreadId, TurnId, Input) ->
    create_panel(Owner, ThreadId, TurnId, Input, #{}).

%% @doc §10.4. `Input`: `message`, `context`, `title`, `control`, `options`,
%% optional `refinementPanelId` and `userMessage` (defaults to `message`).
%% Returns `#{<<"panel">> => Panel | null}`, plus `<<"error">>` when a newer
%% head superseded this one; failures are `{error, Msg}`.
-spec create_panel(binary(), binary(), binary(), map(), opts()) ->
          {ok, #{binary() => term()}} | {error, binary() | aborted}.
create_panel(Owner, ThreadId, TurnId, Input, Opts) ->
    run(fun() -> do_create(Owner, ThreadId, TurnId, Input, opts(Opts)) end).

-spec candidate_sources(binary(), binary(), binary(), binary()) -> {ok, [binary()]} | {error, binary()}.
candidate_sources(Owner, ThreadId, TurnId, PanelId) ->
    candidate_sources(Owner, ThreadId, TurnId, PanelId, #{}).

%% @doc Every distinct source URL of a refinable panel's full candidate set.
%% Live mode refuses panels produced in sample mode.
-spec candidate_sources(binary(), binary(), binary(), binary(), opts()) ->
          {ok, [binary()]} | {error, binary()}.
candidate_sources(Owner, ThreadId, TurnId, PanelId, Opts) ->
    #{mode := Mode} = opts(Opts),
    Head = muse_store:get(Owner, ?THREADS, ThreadId),
    case muse_store:get(Owner, ?PANELS, PanelId) of
        #{<<"panel">> := #{<<"threadId">> := ThreadId, <<"mode">> := PanelMode},
          <<"candidates">> := Candidates} ->
            case refinable(Head, PanelId, TurnId)
                 andalso not (Mode =:= live andalso PanelMode =/= <<"live">>) of
                true ->
                    Urls = [U || #{<<"sources">> := Ss} <- Candidates, #{<<"url">> := U} <- Ss],
                    {ok, uniq(Urls)};
                false -> {error, ?UNAVAILABLE_REFINEMENT}
            end;
        _ -> {error, ?UNAVAILABLE_REFINEMENT}
    end.

-spec note_evidence(binary(), binary(), binary(), mail | web, binary()) -> ok.
note_evidence(Owner, ThreadId, RunId, Kind, Reference) ->
    note_evidence(Owner, ThreadId, RunId, Kind, Reference, undefined).

%% @doc Record what this run read: a mail thread (plus the run's mail marker)
%% or a web page's text (bounded to 30000 UTF-16 units; blank text is ignored).
-spec note_evidence(binary(), binary(), binary(), mail | web, binary(), binary() | undefined) -> ok.
note_evidence(Owner, ThreadId, RunId, web, Reference, Text) ->
    case is_binary(Text) andalso string:trim(Text) =/= <<>> of
        false -> ok;
        true ->
            _ = muse_store:put(Owner, ?EVIDENCE,
                               #{<<"id">> => evidence_id(ThreadId, RunId, web, Reference),
                                 <<"threadId">> => ThreadId, <<"runId">> => RunId,
                                 <<"kind">> => <<"web">>, <<"reference">> => Reference,
                                 <<"text">> => muse_js:slice(Text, 30000)}),
            ok
    end;
note_evidence(Owner, ThreadId, RunId, mail, Reference, _Text) ->
    _ = muse_store:insert_if_absent(Owner, ?EVIDENCE,
                                    #{<<"id">> => evidence_id(ThreadId, RunId, mail, Reference),
                                      <<"threadId">> => ThreadId, <<"runId">> => RunId,
                                      <<"kind">> => <<"mail">>, <<"reference">> => Reference}),
    _ = muse_store:insert_if_absent(Owner, ?MAIL_EVIDENCE,
                                    #{<<"id">> => <<ThreadId/binary, ":", RunId/binary>>}),
    ok.

-spec has_evidence(binary(), binary(), binary(), mail | web, binary()) -> boolean().
has_evidence(Owner, ThreadId, RunId, Kind, Reference) ->
    muse_store:get(Owner, ?EVIDENCE, evidence_id(ThreadId, RunId, Kind, Reference)) =/= undefined.

-spec has_any_mail_evidence(binary(), binary(), binary()) -> boolean().
has_any_mail_evidence(Owner, ThreadId, RunId) ->
    muse_store:get(Owner, ?MAIL_EVIDENCE, <<ThreadId/binary, ":", RunId/binary>>) =/= undefined.

-spec evidence_text(binary(), binary(), binary(), web, binary()) -> binary() | undefined.
evidence_text(Owner, ThreadId, RunId, web, Reference) ->
    case muse_store:get(Owner, ?EVIDENCE, evidence_id(ThreadId, RunId, web, Reference)) of
        #{<<"text">> := Text} when is_binary(Text) ->
            case string:trim(Text) of
                <<>> -> undefined;
                _ -> Text
            end;
        _ -> undefined
    end.

-spec present_choices_tool(binary(), binary(), binary(), binary() | undefined) -> map().
present_choices_tool(Owner, ThreadId, RunId, LatestUserText) ->
    present_choices_tool(Owner, ThreadId, RunId, LatestUserText, #{}).

%% @doc The `present_choices` chat tool (§10.3). Its result is
%% `#{<<"panel">> => Panel | null}` with `<<"error">>` on failure; invalid
%% arguments come back as muse_tool's `#{<<"error">> => Msg}`.
-spec present_choices_tool(binary(), binary(), binary(), binary() | undefined, opts()) -> map().
present_choices_tool(Owner, ThreadId, RunId, LatestUserText, Opts0) ->
    Opts = opts(Opts0),
    UserMessage = case LatestUserText of
                      undefined -> undefined;
                      T -> case string:trim(T) of <<>> -> undefined; Trimmed -> Trimmed end
                  end,
    Handler = fun(Input, _Ctx) ->
                      present(Owner, ThreadId, RunId, Input, UserMessage, Opts)
              end,
    Spec = muse_tool:define(<<"present_choices">>, tool_description(),
                            muse_jev_schema:tool_params(), Handler, #{link_run => true}),
    Validated = maps:get(handler, Spec),
    Strict = fun(Args, Ctx) ->
                     case muse_jev_schema:check(muse_jev_schema:tool_params(), Args) of
                         {ok, _} -> Validated(Args, Ctx);
                         {error, Msg} -> {ok, #{<<"error">> => Msg}}
                     end
             end,
    Spec#{handler := Strict}.

-spec tool_description() -> binary().
tool_description() ->
    <<"Present prepared clarification buttons or a sourced comparison after reading evidence. "
      "For choices based on a read email, include its mailThreadId; generic choices need no mail. "
      "Give 1–12 factual options for a new panel. Each comparison option needs at least one "
      "detail; its label, source titles, and details must be exact excerpts from the read "
      "source page text. To refine an earlier panel, supply refinementPanelId and leave options "
      "empty; the server reuses the full original candidate set. This only asks the user for a "
      "preference and performs no external action."/utf8>>.

%% @doc Part D of the chat system prompt (§9.5), verbatim, including its
%% leading space and no trailing space.
-spec prompt_section(boolean()) -> binary().
prompt_section(BrowserConfigured) ->
    Research = case BrowserConfigured of
                   true ->
                       <<"For exhibit or other research comparisons, call browse_web for every "
                         "cited source before calling present_choices with a comparison. "
                         "Comparison details must be exact phrases from the returned page text, "
                         "and each source URL must be the final URL from successful browsing. If "
                         "source reading fails, report the failure and do not present a sourced "
                         "comparison. ">>;
                   false ->
                       <<"Full-page research comparisons are unavailable without a browser worker. ">>
               end,
    <<" When a request has several possible next steps, call present_choices with factual "
      "clarification options. If those choices depend on email, first search and read the "
      "relevant thread, then provide its mailThreadId to present_choices. Generic choices need "
      "no mail. ", Research/binary,
      "To refine a panel, pass its refinementPanelId with empty options; retained candidates "
      "will be ranked again. A selection is a preference; continue the user's requested "
      "planning from it.">>.

%% @doc Id of an option given without one:
%% `sha256hex(JSON.stringify({label, details, sources})).slice(0, 32)`.
-spec option_id(map()) -> binary().
option_id(Option) ->
    Sources = case maps:get(<<"sources">>, Option, undefined) of
                  L when is_list(L) ->
                      [case S of
                           #{} -> {obj, [{<<"title">>, maps:get(<<"title">>, S, undefined)},
                                         {<<"url">>, maps:get(<<"url">>, S, undefined)}]};
                           _ -> S
                       end || S <- L];
                  Other -> Other
              end,
    Json = muse_json:encode({obj, [{<<"label">>, maps:get(<<"label">>, Option, undefined)},
                                   {<<"details">>, maps:get(<<"details">>, Option, undefined)},
                                   {<<"sources">>, Sources}]}),
    binary:part(muse_ids:sha256hex(Json), 0, 32).

%% Internal: service

run(Fun) ->
    try Fun()
    catch
        throw:{jev, aborted} -> {error, aborted};
        throw:{jev, Msg} -> {error, Msg}
    end.

-spec fail(binary() | aborted) -> no_return().
fail(Msg) -> throw({jev, Msg}).

opts(Opts) ->
    Mode = maps:get(mode, Opts, case muse_config:get(jev_mode, off) of
                                    live -> live;
                                    _ -> sample
                                end),
    Adapter = case maps:find(adapter, Opts) of
                  {ok, A} -> A;
                  error -> muse_jev_adapter:for_mode(muse_config:get(jev_mode, off))
              end,
    #{mode => Mode, adapter => Adapter,
      aborted => maps:get(aborted, Opts, fun() -> false end)}.

check_aborted(#{aborted := Aborted}) ->
    case Aborted() of
        true -> fail(aborted);
        false -> ok
    end.

%% A panel may be refined by `TurnId` while it is current, or when this very
%% turn retired it.
refinable(#{} = Head, PanelId, TurnId) ->
    maps:get(<<"currentPanelId">>, Head, undefined) =:= PanelId
        orelse (maps:get(<<"retiredPanelId">>, Head, undefined) =:= PanelId
                andalso maps:get(<<"retiredTurnId">>, Head, undefined) =:= TurnId);
refinable(_, _, _) ->
    false.

reserve(Owner, ThreadId, TurnId, Ref) ->
    _ = muse_store:insert_if_absent(Owner, ?THREADS, #{<<"id">> => ThreadId, <<"revision">> => 0,
                                                       <<"generation">> => 0}),
    reserve(Owner, ThreadId, TurnId, Ref, ?ATTEMPTS).

reserve(_Owner, _ThreadId, _TurnId, _Ref, 0) ->
    fail(<<"Choices thread changed too many times; please retry">>);
reserve(Owner, ThreadId, TurnId, Ref, Attempts) ->
    Current = case muse_store:get(Owner, ?THREADS, ThreadId) of
                  undefined -> fail(<<"Choices thread is unavailable">>);
                  C -> C
              end,
    Ref =/= undefined andalso not refinable(Current, Ref, TurnId)
        andalso fail(<<"The earlier choices have been superseded">>),
    #{<<"generation">> := Gen} = Current,
    Guard = case Ref of
                undefined -> #{};
                _ ->
                    case maps:get(<<"currentPanelId">>, Current, undefined) of
                        Ref -> #{<<"currentPanelId">> => Ref};
                        _ -> #{<<"retiredPanelId">> => Ref, <<"retiredTurnId">> => TurnId}
                    end
            end,
    case muse_store:cas(Owner, ?THREADS, ThreadId, Guard#{<<"generation">> => Gen},
                        #{<<"generation">> => Gen + 1}) of
        undefined -> reserve(Owner, ThreadId, TurnId, Ref, Attempts - 1);
        Updated -> Updated
    end.

%% The CAS guard "the head is still what reserve/4 returned".
reserved(Reserved) ->
    maps:with([<<"generation">>, <<"revision">>, <<"currentPanelId">>, <<"selectedId">>], Reserved).

publish(Owner, ThreadId, Reserved, PanelId) ->
    muse_store:cas(Owner, ?THREADS, ThreadId, reserved(Reserved),
                   #{<<"revision">> => maps:get(<<"generation">>, Reserved),
                     <<"currentPanelId">> => PanelId, <<"selectedId">> => null,
                     <<"retiredPanelId">> => null, <<"retiredTurnId">> => null}).

do_create(Owner, ThreadId, TurnId, Input, #{adapter := Adapter, mode := Mode} = Opts) ->
    check_aborted(Opts),
    Adapter =:= undefined andalso fail(<<"Choices are unavailable in this conversation">>),
    Ref = maps:get(<<"refinementPanelId">>, Input, undefined),
    Control = maps:get(<<"control">>, Input),
    Previous = case Ref of
                   undefined -> undefined;
                   _ ->
                       Prev = muse_store:get(Owner, ?PANELS, Ref),
                       PriorHead = muse_store:get(Owner, ?THREADS, ThreadId),
                       case Prev of
                           #{<<"panel">> := #{<<"threadId">> := ThreadId}} ->
                               refinable(PriorHead, Ref, TurnId)
                                   orelse fail(?UNAVAILABLE_REFINEMENT),
                               Prev;
                           _ -> fail(?UNAVAILABLE_REFINEMENT)
                       end
               end,
    Candidates = case Previous of
                     #{<<"candidates">> := Cs} -> Cs;
                     undefined -> [candidate(C) || C <- maps:get(<<"options">>, Input, [])]
                 end,
    Ids = [Id || #{<<"id">> := Id} <- Candidates],
    (Candidates =:= [] orelse length(Candidates) > 12 orelse length(lists:usort(Ids)) =/= length(Ids))
        andalso fail(<<"Choices need 1–12 distinct options"/utf8>>),
    Control =:= <<"comparison">> andalso lists:any(fun(#{<<"sources">> := S}) -> S =:= [] end, Candidates)
        andalso fail(<<"Comparison choices need sources">>),
    Reserved = reserve(Owner, ThreadId, TurnId, Ref),
    PriorSelected = case maps:get(<<"selectedId">>, Reserved, null) of
                        null -> undefined;
                        S -> S
                    end,
    Message = maps:get(<<"message">>, Input),
    DecisionInput = maps:merge(
                      #{<<"userMessage">> => maps:get(<<"userMessage">>, Input, Message),
                        <<"message">> => Message,
                        <<"context">> => maps:get(<<"context">>, Input),
                        <<"options">> => Candidates,
                        <<"allowedControls">> => [Control, <<"agent">>]},
                      case PriorSelected of
                          undefined -> #{};
                          _ -> #{<<"selectedId">> => PriorSelected}
                      end),
    Decision = case Adapter(DecisionInput) of
                   {ok, D} -> D;
                   {error, Msg} -> fail(Msg)
               end,
    check_aborted(Opts),
    case maps:get(<<"control">>, Decision, undefined) of
        <<"agent">> ->
            case publish(Owner, ThreadId, Reserved, null) of
                undefined -> {ok, #{<<"panel">> => null, <<"error">> => ?SUPERSEDED_RESULT}};
                _ -> {ok, #{<<"panel">> => null}}
            end;
        Control ->
            Ranked = case muse_jev_adapter:rank(Candidates, Decision) of
                         {ok, R} -> R;
                         {error, RankMsg} -> fail(RankMsg)
                     end,
            Visible0 = case Control of
                           <<"comparison">> -> lists:sublist(Ranked, 3);
                           _ -> Ranked
                       end,
            InRanked = fun(Id) -> lists:any(fun(#{<<"id">> := I}) -> I =:= Id end, Ranked) end,
            Preferred = case Previous =/= undefined andalso PriorSelected =/= undefined
                             andalso InRanked(PriorSelected) of
                            true -> PriorSelected;
                            false -> undefined
                        end,
            Visible = with_preferred(Visible0, Ranked, Preferred),
            Gen = maps:get(<<"generation">>, Reserved),
            Panel0 = #{<<"id">> => muse_ids:uuid(), <<"threadId">> => ThreadId,
                       <<"turnId">> => TurnId, <<"candidateSetVersion">> => Gen,
                       <<"type">> => Control, <<"title">> => maps:get(<<"title">>, Input),
                       <<"options">> => Visible, <<"mode">> => atom_to_binary(Mode)},
            Panel1 = case Preferred of
                         undefined -> Panel0;
                         _ -> Panel0#{<<"preferredId">> => Preferred}
                     end,
            Panel = case muse_jev_schema:check_panel(Panel1) of
                        {ok, P} -> P;
                        {error, PanelMsg} -> fail(PanelMsg)
                    end,
            check_aborted(Opts),
            _ = muse_store:insert_if_absent(Owner, ?PANELS,
                                            #{<<"id">> => maps:get(<<"id">>, Panel),
                                              <<"panel">> => Panel,
                                              <<"candidates">> => Candidates}),
            check_aborted(Opts),
            case publish(Owner, ThreadId, Reserved, maps:get(<<"id">>, Panel)) of
                undefined -> {ok, #{<<"panel">> => null, <<"error">> => ?SUPERSEDED_RESULT}};
                _ -> {ok, #{<<"panel">> => Panel}}
            end;
        _ ->
            fail(<<"Jev returned an unexpected control">>)
    end.

candidate(C) ->
    Option = case maps:find(<<"id">>, C) of
                 {ok, Id} when Id =/= undefined -> C;
                 _ -> C#{<<"id">> => option_id(C)}
             end,
    case muse_jev_schema:check(muse_jev_schema:option(), Option) of
        {ok, Valid} -> Valid;
        {error, Msg} -> fail(Msg)
    end.

with_preferred(Visible, _Ranked, undefined) ->
    Visible;
with_preferred(Visible, Ranked, Preferred) ->
    case lists:any(fun(#{<<"id">> := I}) -> I =:= Preferred end, Visible) of
        true -> Visible;
        false ->
            [P | _] = [O || #{<<"id">> := I} = O <- Ranked, I =:= Preferred],
            lists:droplast(Visible) ++ [P]
    end.

do_select(Owner, ThreadId, RawAction) ->
    Action = case muse_jev_schema:check(muse_jev_schema:action(), RawAction) of
                 {ok, A} -> A;
                 {error, Msg} -> fail(Msg)
             end,
    #{<<"panelId">> := PanelId, <<"threadId">> := ActionThread,
      <<"candidateSetVersion">> := Version, <<"optionId">> := OptionId} = Action,
    ActionThread =:= ThreadId orelse fail(<<"This choice belongs to another conversation">>),
    Record = case muse_store:get(Owner, ?PANELS, PanelId) of
                 #{<<"panel">> := #{<<"threadId">> := ThreadId, <<"candidateSetVersion">> := V}} = R
                   when V == Version -> R;
                 _ -> fail(<<"This choice is unavailable or out of date">>)
             end,
    #{<<"panel">> := Panel, <<"candidates">> := Candidates} = Record,
    Option = case [O || #{<<"id">> := I} = O <- Candidates, I =:= OptionId] of
                 [O | _] -> O;
                 [] -> fail(<<"This option is unavailable">>)
             end,
    lists:any(fun(#{<<"id">> := I}) -> I =:= OptionId end, maps:get(<<"options">>, Panel))
        orelse fail(<<"This option is unavailable">>),
    Head = muse_store:get(Owner, ?THREADS, ThreadId),
    case Head of
        #{<<"revision">> := Rev, <<"currentPanelId">> := PanelId} when Rev == Version -> ok;
        _ -> fail(<<"These choices have been superseded">>)
    end,
    case maps:get(<<"selectedId">>, Head, null) of
        OptionId -> ok;
        null ->
            Claimed = muse_store:cas(Owner, ?THREADS, ThreadId,
                                     #{<<"revision">> => maps:get(<<"revision">>, Head),
                                       <<"currentPanelId">> => PanelId, <<"selectedId">> => null},
                                     #{<<"selectedId">> => OptionId}),
            Claimed =:= undefined andalso
                case muse_store:get(Owner, ?THREADS, ThreadId) of
                    #{<<"selectedId">> := OptionId, <<"currentPanelId">> := PanelId} -> ok;
                    _ -> fail(<<"This choice has changed">>)
                end;
        _ -> fail(<<"A different choice was already selected">>)
    end,
    #{<<"label">> := Label} = Option,
    #{<<"type">> := Type} = Panel,
    {ok, #{<<"continuation">> => <<"I choose “"/utf8, Label/binary, "” from "/utf8, Type/binary,
                                   " choices. Continue with that preference.">>,
           <<"panel">> => Panel#{<<"selectedId">> => maps:get(<<"id">>, Option)}}}.

evidence_id(ThreadId, RunId, Kind, Reference) ->
    <<ThreadId/binary, ":", RunId/binary, ":", (atom_to_binary(Kind))/binary, ":",
      (muse_ids:sha256hex(Reference))/binary>>.

uniq(L) -> uniq(L, #{}, []).

uniq([], _, Acc) -> lists:reverse(Acc);
uniq([X | T], Seen, Acc) when is_map_key(X, Seen) -> uniq(T, Seen, Acc);
uniq([X | T], Seen, Acc) -> uniq(T, Seen#{X => true}, [X | Acc]).

%% Internal: tool

present(Owner, ThreadId, RunId, Input, UserMessage, #{mode := Mode} = Opts) ->
    Result = run(fun() ->
                         Mode =:= live andalso grounded(Owner, ThreadId, RunId, Input, Opts),
                         Input1 = case UserMessage of
                                      undefined -> Input;
                                      _ -> Input#{<<"userMessage">> => UserMessage}
                                  end,
                         do_create(Owner, ThreadId, RunId, Input1, Opts)
                 end),
    case Result of
        {ok, _} = Ok -> Ok;
        {error, aborted} -> exit(aborted);
        {error, Msg} ->
            {ok, #{<<"panel">> => null,
                   <<"error">> => case muse_validate:utf16_length(Msg) < 300 of
                                      true -> Msg;
                                      false -> ?TOOL_FALLBACK
                                  end}}
    end.

%% Live-mode grounding checks (§10.3), run before the panel is created.
grounded(Owner, ThreadId, RunId, Input, Opts) ->
    case maps:find(<<"mailThreadId">>, Input) of
        {ok, Mail} ->
            has_evidence(Owner, ThreadId, RunId, mail, Mail)
                orelse fail(<<"Read the referenced email before presenting choices.">>);
        error -> ok
    end,
    case Input of
        #{<<"control">> := <<"comparison">>, <<"refinementPanelId">> := Ref} ->
            case candidate_sources(Owner, ThreadId, RunId, Ref, Opts) of
                {ok, _} -> ok;
                {error, Msg} -> fail(Msg)
            end;
        #{<<"control">> := <<"comparison">>, <<"options">> := Options} ->
            lists:foreach(fun(O) -> grounded_option(Owner, ThreadId, RunId, O) end, Options);
        _ -> ok
    end,
    true.

grounded_option(Owner, ThreadId, RunId, #{<<"label">> := Label, <<"details">> := Details,
                                          <<"sources">> := Sources}) ->
    Texts = [begin
                 Observed = case evidence_text(Owner, ThreadId, RunId, web, Url) of
                                undefined ->
                                    fail(<<"Read the source page before comparing: ", Url/binary>>);
                                T -> T
                            end,
                 Text = normalize(Observed),
                 contains(Text, normalize(Title))
                     orelse fail(<<"Comparison source title is not present in source text: ",
                                   Url/binary>>),
                 Text
             end || #{<<"title">> := Title, <<"url">> := Url} <- Sources],
    InSome = fun(Needle) -> lists:any(fun(T) -> contains(T, normalize(Needle)) end, Texts) end,
    InSome(Label)
        orelse fail(<<"Comparison label is not present in source text: ", Label/binary>>),
    Details =/= []
        orelse fail(<<"Comparison needs at least one grounded detail: ", Label/binary>>),
    lists:foreach(fun(D) ->
                          InSome(D) orelse
                              fail(<<"Comparison detail is not present in source text: ",
                                     Label/binary>>)
                  end, Details).

%% `value.replace(/\s+/g, " ").toLowerCase()`
normalize(Text) ->
    string:lowercase(re:replace(Text, <<"\\s+">>, <<" ">>, [global, unicode, ucp, {return, binary}])).

contains(_Haystack, <<>>) -> true;
contains(Haystack, Needle) -> binary:match(Haystack, Needle) =/= nomatch.
