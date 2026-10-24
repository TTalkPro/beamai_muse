%% @doc Relays one chat run's AG-UI events to the pages watching the thread
%% (designs/05-web-ui.md §4). One process per running thread, registered
%% globally as `{muse_chat_relay, ThreadId}` (so "is a reply running" is
%% `running/1`). Events are coalesced for 80 ms and published to
%% `{thread, Tid}` as DOM operations:
%%
%%   TEXT_MESSAGE_START    a new assistant bubble
%%   TEXT_MESSAGE_CONTENT  text appended to the bubble (aihtml text op)
%%   TEXT_MESSAGE_END      the bubble re-rendered as Markdown
%%   TOOL_CALL_START/ARGS  a loading card
%%   TOOL_CALL_RESULT      the tool's card (muse_ui_cards)
%%   RUN_FINISHED / ERROR  the composer back to "send", then the next queued
%%                         message, if any, starts a new run
%%
%% Pushes are at most once; a page that reconnects re-renders the thread
%% from the chat log (muse_ui_chat refresh).
-module(muse_chat_relay).
-behaviour(gen_server).

-export([start/4, running/1, child_spec/0, start_link/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK, 80).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => muse_chat_relay_sup, type => supervisor,
      start => {supervisor, start_link, [{local, muse_chat_relay_sup}, muse_ui_bridge_sup_cb, {muse_chat_relay}]}}.

%% @doc Relay the run that `muse_chat:start_turn/4` started on `Session`,
%% from event `Since`.
-spec start(binary(), binary(), pid(), integer()) -> ok.
start(Owner, Tid, Session, Since) ->
    case supervisor:start_child(muse_chat_relay_sup, [Owner, Tid, Session, Since]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason} -> logger:warning("chat relay ~ts: ~p", [Tid, Reason]), ok
    end.

-spec running(binary()) -> boolean().
running(Tid) ->
    is_pid(global:whereis_name({?MODULE, Tid})).

-spec start_link(binary(), binary(), pid(), integer()) -> {ok, pid()} | {error, term()}.
start_link(Owner, Tid, Session, Since) ->
    gen_server:start_link({global, {?MODULE, Tid}}, ?MODULE, {Owner, Tid, Session, Since}, []).

init({Owner, Tid, Session, Since}) ->
    {ok, Ref, Backlog, _} = beamai_agui_session:subscribe(Session, Since),
    MRef = monitor(process, Session),
    State = #{owner => Owner, tid => Tid, ref => Ref, mref => MRef, pending => [],
              timer => undefined, texts => #{}, calls => #{}},
    {ok, lists:foldl(fun({_, E}, S) -> queue_event(E, S) end, State, Backlog)}.

handle_call(_Msg, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.

handle_info({agui_event, Ref, _Seq, Event}, #{ref := Ref} = S) ->
    {noreply, queue_event(Event, S)};
handle_info(flush, S) ->
    flush(S#{timer => undefined});
handle_info({agui_closed, Ref, _}, #{ref := Ref} = S) ->
    finish(undefined, S);
handle_info({'DOWN', MRef, process, _, _}, #{mref := MRef} = S) ->
    finish(<<"会话已结束"/utf8>>, S);
handle_info(_Msg, S) ->
    {noreply, S}.

queue_event(Event, #{pending := P, timer := T} = S) ->
    Timer = case T of
                undefined -> erlang:send_after(?TICK, self(), flush);
                _ -> T
            end,
    S#{pending => [Event | P], timer => Timer}.

%% Publish the coalesced events; stop after the run's last event.
flush(#{pending := Pending} = S0) ->
    {Ops, Final, S} = lists:foldl(fun step/2, {[], none, S0#{pending => []}}, lists:reverse(Pending)),
    publish(S, lists:reverse(Ops)),
    case Final of
        none -> {noreply, S};
        {error, Msg} -> finish(Msg, S);
        finished -> finish(undefined, S)
    end.

%% Each step adds functions of the aihtml ctx to the op list.
step(_E, {Ops, Final, S}) when Final =/= none ->
    {Ops, Final, S};
step(#{<<"type">> := <<"TEXT_MESSAGE_START">>, <<"messageId">> := Mid}, {Ops, F, #{texts := Ts} = S}) ->
    Op = fun(C) -> aihtml_action:html(C, {id, <<"chat-log">>}, muse_ui_chat:streaming_bubble(Mid), append) end,
    {[Op | Ops], F, S#{texts => Ts#{Mid => <<>>}}};
step(#{<<"type">> := <<"TEXT_MESSAGE_CONTENT">>, <<"messageId">> := Mid, <<"delta">> := D}, {Ops, F, #{texts := Ts} = S}) ->
    Ensure = case maps:is_key(Mid, Ts) of
                 true -> [];
                 false -> [fun(C) -> aihtml_action:html(C, {id, <<"chat-log">>}, muse_ui_chat:streaming_bubble(Mid), append) end]
             end,
    Op = fun(C) -> aihtml_action:text(C, {id, muse_ui_chat:bubble_text_id(Mid)}, D, append) end,
    {[Op | Ensure ++ Ops], F, S#{texts => Ts#{Mid => <<(maps:get(Mid, Ts, <<>>))/binary, D/binary>>}}};
step(#{<<"type">> := <<"TEXT_MESSAGE_END">>, <<"messageId">> := Mid}, {Ops, F, #{texts := Ts} = S}) ->
    Text = maps:get(Mid, Ts, <<>>),
    Op = fun(C) -> aihtml_action:html(C, {id, muse_ui_chat:bubble_id(Mid)}, muse_ui_chat:assistant_bubble(Mid, Text), outer) end,
    {[Op | Ops], F, S};
step(#{<<"type">> := <<"TOOL_CALL_START">>, <<"toolCallId">> := Id, <<"toolCallName">> := Name},
     {Ops, F, #{calls := Cs, owner := O, tid := T} = S}) ->
    Op = fun(C) -> aihtml_action:html(C, {id, <<"chat-log">>}, muse_ui_cards:render(O, T, Id, Name, #{}, pending), append) end,
    {[Op | Ops], F, S#{calls => Cs#{Id => {Name, <<>>}}}};
step(#{<<"type">> := <<"TOOL_CALL_ARGS">>, <<"toolCallId">> := Id, <<"delta">> := D}, {Ops, F, #{calls := Cs} = S}) ->
    case maps:find(Id, Cs) of
        {ok, {Name, Args}} -> {Ops, F, S#{calls => Cs#{Id => {Name, <<Args/binary, D/binary>>}}}};
        error -> {Ops, F, S}
    end;
step(#{<<"type">> := <<"TOOL_CALL_RESULT">>, <<"toolCallId">> := Id, <<"content">> := Content},
     {Ops, F, #{calls := Cs, owner := O, tid := T} = S}) ->
    {Name, ArgsJson} = maps:get(Id, Cs, {<<"tool">>, <<>>}),
    Args = case muse_json:decode(ArgsJson) of
               {ok, #{} = A} -> A;
               _ -> #{}
           end,
    Card = muse_ui_cards:render(O, T, Id, Name, Args, Content),
    Op = fun(C) -> aihtml_action:html(C, {id, muse_ui_cards:card_id(Id)}, Card, outer) end,
    {[Op | Ops], F, S};
step(#{<<"type">> := <<"RUN_FINISHED">>}, {Ops, _, S}) ->
    {Ops, finished, S};
step(#{<<"type">> := <<"RUN_ERROR">>} = E, {Ops, _, S}) ->
    {Ops, {error, maps:get(<<"message">>, E, <<"回复失败"/utf8>>)}, S};
step(_E, Acc) ->
    Acc.

publish(_S, []) ->
    ok;
publish(#{owner := Owner, tid := Tid}, Ops) ->
    muse_ui:publish(Owner, {thread, Tid}, fun(C) -> lists:foreach(fun(Op) -> Op(C) end, Ops) end).

%% The run is over: the composer goes back to "send" (with an error when
%% the run failed), then the next queued message starts.
finish(Error, #{owner := Owner, tid := Tid} = S) ->
    muse_ui:publish(Owner, {thread, Tid},
                    fun(C) ->
                            case Error of
                                undefined -> ok;
                                _ -> aihtml_action:html(C, {id, <<"chat-log">>}, muse_ui_chat:error_note(Error), append)
                            end,
                            aihtml_action:html(C, {id, <<"chat-actions">>}, muse_ui_chat:composer_actions(Tid, false), outer)
                    end),
    %% leave the global name before starting the next run's relay
    _ = global:unregister_name({?MODULE, Tid}),
    _ = muse_ui_chat:send_next(Owner, Tid),
    {stop, normal, S}.
