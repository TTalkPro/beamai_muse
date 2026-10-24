%% @doc Scripted beamai provider for tests and demos: `{custom, muse_script_llm}`.
%% `set(Script)` installs replies (`{text, Bin}` | `{call, Name, Args}`),
%% consumed in order (the last one repeats). Every request's message list is
%% recorded and can be read back with `requests/0`.
-module(muse_script_llm).

-export([default_config/0, chat/2, stream_chat/3, set/1, requests/0, model/0]).

-spec model() -> map().
-spec default_config() -> map().
-spec set([term()]) -> ok.
-spec requests() -> [{pos_integer(), [map()]}].
-spec chat(map(), term()) -> {ok, map()}.
-spec stream_chat(map(), term(), fun((map()) -> term())) -> {ok, map()}.

model() ->
    beamai_chat_model:create({custom, ?MODULE}, #{}).

default_config() ->
    #{model => <<"script">>}.

set(Script) ->
    persistent_term:put(?MODULE, {Script, counters:new(1, [])}),
    persistent_term:put({?MODULE, requests}, ets_new()),
    ok.

requests() ->
    lists:sort(ets:tab2list(persistent_term:get({?MODULE, requests}))).

chat(_Config, Req) ->
    {Script, C} = persistent_term:get(?MODULE),
    counters:add(C, 1, 1),
    N = counters:get(C, 1),
    ets:insert(persistent_term:get({?MODULE, requests}), {N, beamai_chat_request:messages(Req)}),
    {ok, mk(lists:nth(min(N, length(Script)), Script))}.

stream_chat(Config, Req, Cb) ->
    {ok, R} = chat(Config, Req),
    case beamai_chat_response:content(R) of
        null -> ok;
        T -> Cb(#{<<"choices">> => [#{<<"delta">> => #{<<"content">> => T}}]})
    end,
    {ok, R}.

mk({text, T}) ->
    beamai_chat_response:new(#{content => T, finish_reason => complete});
mk({sleep, Ms}) ->
    timer:sleep(Ms),
    beamai_chat_response:new(#{content => <<"late">>, finish_reason => complete});
mk({calls, Calls}) ->
    beamai_chat_response:new(#{content => null, finish_reason => tool_use,
                               tool_calls => [#{id => <<"call_", (integer_to_binary(I))/binary, "_", Name/binary>>,
                                                name => Name, arguments => Args,
                                                raw_arguments => iolist_to_binary(json:encode(Args))}
                                              || {I, {Name, Args}} <- lists:enumerate(Calls)]});
mk({call, Name, Args}) ->
    beamai_chat_response:new(#{content => null, finish_reason => tool_use,
                               tool_calls => [#{id => <<"call_", Name/binary>>, name => Name,
                                                arguments => Args,
                                                raw_arguments => iolist_to_binary(json:encode(Args))}]}).

ets_new() ->
    Heir = whereis(init),
    ets:new(?MODULE, [public, ordered_set, {heir, Heir, none}]).
