%% @doc The scripted sample-mode "model" (OpenMuse conversation.ts `sample`,
%% engine spec §9.4) as a beamai custom provider: `{custom, muse_sample_llm}`
%% with config `#{owner, request_key}`.
%%
%% First call: pick the reply by the original regex order and, when work is
%% needed, return that text together with a `delegate_task` call (the text
%% precedes the tool call, like OpenMuse). Second call (after the tool
%% result): an empty final answer. Strings keep their typographic quotes.
-module(muse_sample_llm).

-export([default_config/0, chat/2, stream_chat/3, reply/2]).

-spec default_config() -> map().
default_config() ->
    #{model => <<"sample">>}.

-spec chat(map(), term()) -> {ok, map()}.
chat(#{owner := Owner}, Req) ->
    Messages = beamai_chat_request:messages(Req),
    case lists:last(Messages) of
        #{role := tool} ->
            {ok, beamai_chat_response:new(#{content => <<>>, finish_reason => complete})};
        _ ->
            Prompt = last_user_text(Messages),
            {ok, response(reply(Owner, Prompt))}
    end.

-spec stream_chat(map(), term(), fun((map()) -> term())) -> {ok, map()}.
stream_chat(Config, Req, Callback) ->
    {ok, Resp} = chat(Config, Req),
    case beamai_chat_response:content(Resp) of
        C when is_binary(C), C =/= <<>> ->
            Callback(#{<<"choices">> => [#{<<"delta">> => #{<<"content">> => C}}]});
        _ -> ok
    end,
    {ok, Resp}.

%% @doc `{Content, undefined | TaskArgs}` for a user prompt.
-spec reply(binary(), binary()) -> {binary(), map() | undefined}.
reply(Owner, Prompt) ->
    Match = fun(Re) -> re:run(Prompt, Re, [caseless, unicode, {capture, none}]) =:= match end,
    Short = muse_validate:utf16_length(Prompt) < 70,
    case {Match(<<"show.*calendar|what.*calendar|plan my day">>),
          Match(<<"what can|help|hello|^hi[!. ]*$">>) andalso Short,
          Match(<<"permission|pdf|form">>)} of
        {true, _, _} ->
            {ok, #{<<"events">> := Events}} = muse_workspace:snapshot(Owner, undefined),
            {<<"Your local calendar has ", (integer_to_binary(length(Events)))/binary,
               " events. Open Calendar to see the details, or ask me to take care of a document.">>, undefined};
        {_, true, _} ->
            {<<"What would you like to take off your plate? I can prepare the permission slip, keep an eye on a "
               "website, or organize your spending. For open-ended requests, connect a model in Apps.">>, undefined};
        {_, _, true} ->
            {ok, #{<<"mail">> := Mail}} = muse_workspace:snapshot(Owner, undefined),
            case [M || M = #{<<"label">> := L} <- Mail, maps:get(<<"attachments">>, M, []) =/= [],
                       re:run(L, <<"^Sent\\b">>, [caseless, {capture, none}]) =/= match] of
                [] ->
                    {<<"There isn’t an email with a PDF here yet. Open Mail and choose a document first."/utf8>>, undefined};
                [#{<<"id">> := MessageId} | _] ->
                    {<<"I found the permission slip. I’ll prepare a copy and ask for the details I need. You can "
                       "follow along here or come back when it’s ready for review."/utf8>>,
                     #{<<"kind">> => <<"document">>, <<"prompt">> => Prompt,
                       <<"title">> => <<"Complete the permission slip">>,
                       <<"input">> => #{<<"messageId">> => MessageId}}}
            end;
        _ ->
            Task = case Prompt of <<>> -> <<"Help with my next task">>; _ -> Prompt end,
            Title = muse_js:slice(string:trim(Task), 90),
            {<<"I’ve saved “"/utf8, Title/binary,
               "” in Activity. Connect a model to start this task; your request will be waiting."/utf8>>,
             #{<<"kind">> => <<"agent">>, <<"prompt">> => Task}}
    end.

response({Content, undefined}) ->
    beamai_chat_response:new(#{content => Content, finish_reason => complete});
response({Content, Args}) ->
    beamai_chat_response:new(#{content => Content, finish_reason => tool_use,
                               tool_calls => [#{id => <<"call_", (muse_ids:uuid())/binary>>,
                                                name => <<"delegate_task">>, arguments => Args,
                                                raw_arguments => muse_json:encode(Args)}]}).

last_user_text(Messages) ->
    case [C || #{role := user, content := C} <- Messages] of
        [] -> <<>>;
        Users -> text(lists:last(Users))
    end.

text(C) when is_binary(C) -> C;
text(Parts) when is_list(Parts) -> iolist_to_binary([T || #{type := text, text := T} <- Parts]);
text(_) -> <<>>.
