%% @doc The scripted sample-mode "model" (OpenMuse conversation.ts `sample`,
%% engine spec §9.4) as a beamai custom provider: `{custom, muse_sample_llm}`
%% with config `#{owner, request_key}`.
%%
%% First call: pick the reply by the original regex order and, when work is
%% needed, return that text together with a `delegate_task` call (the text
%% precedes the tool call, like OpenMuse). Second call (after the tool
%% result): an empty final answer. Strings keep their typographic quotes.
%% Without mail and calendar, the calendar reply is gone and the document
%% task starts from the first fillable PDF in Files (the seeded permission
%% slip) instead of a mail attachment.
%%
%% Not in OpenMuse: a question about the schedule ("我明天有什么安排",
%% "show my calendar") is answered from the built-in calendar directly
%% (today, tomorrow, else the next seven days), without a tool call.
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
    case {Match(<<"what can|help|hello|^hi[!. ]*$">>) andalso Short,
          Match(<<"permission|pdf|form">>)} of
        {false, false} when Short ->
            case Match(<<"日程|安排|calendar|schedule|agenda"/utf8>>) of
                true -> {schedule(Owner, Match), undefined};
                false -> other(Prompt)
            end;
        {true, _} ->
            {<<"What would you like to take off your plate? I can prepare the permission slip, keep an eye on a "
               "website, or organize your spending. For open-ended requests, configure a model on the server.">>, undefined};
        {_, true} ->
            case fillable_pdfs(Owner) of
                [] ->
                    {<<"There isn’t a fillable PDF in Files yet. Upload one in Files first."/utf8>>, undefined};
                [#{<<"id">> := FileId} | _] ->
                    {<<"I found the permission slip. I’ll prepare a filled copy and ask for the details I need. "
                       "You can follow along here or come back when it’s ready."/utf8>>,
                     #{<<"kind">> => <<"document">>, <<"prompt">> => Prompt,
                       <<"title">> => <<"Complete the permission slip">>,
                       <<"input">> => #{<<"fileId">> => FileId}}}
            end;
        _ ->
            other(Prompt)
    end.

other(Prompt) ->
    Task = case Prompt of <<>> -> <<"Help with my next task">>; _ -> Prompt end,
    Title = muse_js:slice(string:trim(Task), 90),
    {<<"I’ve saved “"/utf8, Title/binary,
       "” in Activity. Connect a model to start this task; your request will be waiting."/utf8>>,
     #{<<"kind">> => <<"agent">>, <<"prompt">> => Task}}.

%% The schedule of today, tomorrow or the next seven days.
schedule(Owner, Match) ->
    Today = muse_calendar:today(),
    {Label, From, Days} = case {Match(<<"明天|tomorrow"/utf8>>), Match(<<"今天|today"/utf8>>)} of
                              {true, _} -> {<<"明天"/utf8>>, muse_calendar:add_days(Today, 1), 1};
                              {_, true} -> {<<"今天"/utf8>>, Today, 1};
                              _ -> {<<"接下来 7 天"/utf8>>, Today, 7}
                          end,
    Events = muse_calendar:occurrences(Owner, From, muse_calendar:add_days(From, Days), #{}),
    case Events of
        [] ->
            <<Label/binary, "没有安排。"/utf8>>;
        _ ->
            Lines = [[<<"\n- "/utf8>>, muse_calendar:describe_time(E), <<" "/utf8>>, maps:get(<<"title">>, E),
                      <<"（"/utf8>>, maps:get(<<"calendarName">>, E, <<>>), <<"）"/utf8>>]
                     || E <- lists:sublist(Events, 20)],
            iolist_to_binary([Label, <<"有 "/utf8>>, integer_to_binary(length(Events)), <<" 项安排："/utf8>>, Lines])
    end.

%% Original PDFs in Files (not filled copies) with a supported form field,
%% oldest first: the seeded permission slip in sample mode.
fillable_pdfs(Owner) ->
    lists:reverse([F || F = #{<<"fields">> := Fields} <- muse_files:list(Owner, unsigned),
                        not is_map_key(<<"parentId">>, F),
                        lists:any(fun(#{<<"type">> := T}) -> T =/= <<"unsupported">>;
                                     (_) -> false
                                  end, Fields)]).

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
