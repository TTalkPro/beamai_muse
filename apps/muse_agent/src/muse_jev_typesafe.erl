%% @doc Live Jev decisions: OpenMuse `LiveJevAdapter` over the TypeSafe
%% System One HTTP API (designs/ref/openmuse-engine-spec.md §10.7).
%%
%% The protocol is the one `@typesafe-ai/sdk` 0.7.0 speaks (read from its
%% dist/index.mjs, tasks M7-2):
%%
%%   POST {TYPESAFE_BASE_URL}/v1/systemone      default https://api.typesafe.ai
%%   Authorization: Bearer KEY, Accept/Content-Type: application/json
%%   {"model", "state", "questions": {Name: {"type": "choice" | "score",
%%                                           "instructions", "criteria"}}}
%%   -> {"model", "answers": {Name: {"type", "choice" | "score", "confidence", ...}}, "usage"}
%%
%% `choice` criteria are a map of label to description, `score` criteria a
%% list indexed by score. OpenMuse sets a 5 s timeout and 1 retry; the SDK
%% retries transport errors and HTTP 408, 429 and 5xx with backoff (500 ms
%% doubling, 25% jitter, `Retry-After` honoured up to 60 s), sending
%% `X-TypeSafe-Retry-Count` on retries.
-module(muse_jev_typesafe).
-behaviour(muse_jev_adapter).

-export([decide/1, decide/2, questions/1]).

-define(TIMEOUT, 5000).
-define(MAX_RETRIES, 1).
-define(BACKOFF_MS, 500).
-define(MAX_RETRY_AFTER_MS, 60000).
-define(OVERRIDE_CONFIDENCE, 0.5).
-define(RETRY_MSG, <<"Jev could not evaluate these choices. Please retry.">>).
-define(NO_RETRY_MSG, <<"Jev is unavailable for these choices. Do not retry; answer the user in prose.">>).

-type request_fun() :: fun((binary(), [{binary(), binary()}], binary(), pos_integer()) ->
                                  {ok, integer(), [{binary(), binary()}], binary()} | {error, term()}).
-type opts() :: #{api_key => binary(), model => binary(), base_url => binary(),
                  request => request_fun(), sleep => fun((non_neg_integer()) -> term())}.

%% @doc The adapter with the configured key, model and base URL.
-spec decide(map()) -> {ok, muse_jev_adapter:decision()} | {error, binary()}.
decide(Input) ->
    decide(Input, #{}).

%% @doc `Opts` (tests): `api_key`, `model`, `base_url`, `request`
%% (`request_fun()`), `sleep` (`fun((Ms) -> ok)`).
-spec decide(map(), opts()) -> {ok, muse_jev_adapter:decision()} | {error, binary()}.
decide(#{<<"allowedControls">> := []}, _Opts) ->
    {error, <<"Jev has no allowed controls">>};
decide(Input, Opts) ->
    Key = opt(api_key, Opts, typesafe_api_key),
    Body = #{<<"model">> => opt(model, Opts, jev_model),
             <<"state">> => #{<<"userMessage">> => maps:get(<<"userMessage">>, Input, <<>>),
                              <<"agentSummary">> => maps:get(<<"message">>, Input, <<>>),
                              <<"context">> => maps:get(<<"context">>, Input, <<>>),
                              <<"selectedId">> => maps:get(<<"selectedId">>, Input, null),
                              <<"options">> => maps:get(<<"options">>, Input, [])},
             <<"questions">> => questions(Input)},
    Url = <<(opt(base_url, Opts, typesafe_base_url))/binary, "/v1/systemone">>,
    Headers = [{<<"authorization">>, <<"Bearer ", (to_bin(Key))/binary>>},
               {<<"accept">>, <<"application/json">>},
               {<<"content-type">>, <<"application/json">>},
               {<<"user-agent">>, <<"beamai_muse (typesafe-sdk/0.7.0 protocol)">>}],
    Request = maps:get(request, Opts, fun request/4),
    Sleep = maps:get(sleep, Opts, fun timer:sleep/1),
    case send(Request, Sleep, Url, Headers, muse_json:encode(Body), 0) of
        {ok, Result} -> answers(Input, Result);
        {failed, Retryable, Detail} ->
            logger:error(#{phase => <<"jev.decide">>, detail => Detail}),
            {error, case Retryable of true -> ?RETRY_MSG; false -> ?NO_RETRY_MSG end}
    end.

%% An option, else the configured value (looked up only when needed).
opt(Key, Opts, ConfigKey) ->
    case maps:find(Key, Opts) of
        {ok, V} -> V;
        error -> muse_config:get(ConfigKey)
    end.

%% @doc The System One questions: the control choice and one fit score per
%% option, referenced by position (labels come from untrusted pages and
%% stay in the state).
-spec questions(map()) -> map().
questions(#{<<"allowedControls">> := Controls} = Input) ->
    Control = #{<<"type">> => <<"choice">>,
                <<"instructions">> =>
                    <<"Which interaction best serves the user's latest message in `userMessage`? Present prepared "
                      "choices when they let the user select a useful, supported next step. Choose an ordinary "
                      "agent response only when those options are unhelpful or unsupported.">>,
                <<"criteria">> => maps:from_list([{C, control_label(C)} || C <- Controls])},
    Fits = [{<<"fit_", (integer_to_binary(I))/binary>>,
             #{<<"type">> => <<"score">>,
               <<"instructions">> =>
                   <<"How well does `options[", (integer_to_binary(I))/binary, "]` fit the user's latest message in "
                     "`userMessage`? Use only the details of `options[", (integer_to_binary(I))/binary,
                     "]` as evidence.">>,
               <<"criteria">> => [<<"Does not fit">>, <<"Some fit">>, <<"Good fit">>, <<"Best fit">>]}}
            || I <- lists:seq(0, length(maps:get(<<"options">>, Input, [])) - 1)],
    maps:from_list([{<<"control">>, Control} | Fits]).

control_label(<<"clarification">>) -> <<"Present the prepared options as clickable next steps">>;
control_label(<<"comparison">>) -> <<"Present the sourced candidates as clickable comparison cards">>;
control_label(<<"agent">>) -> <<"Answer the user in prose without choice cards">>.

%% Transport with the SDK's retry policy (1 retry here).

send(Request, Sleep, Url, Headers0, Body, Attempt) ->
    Headers = case Attempt of
                  0 -> Headers0;
                  _ -> [{<<"x-typesafe-retry-count">>, integer_to_binary(Attempt)} | Headers0]
              end,
    Left = ?MAX_RETRIES - Attempt,
    case Request(Url, Headers, Body, ?TIMEOUT) of
        {ok, Status, _RespHeaders, RespBody} when Status >= 200, Status < 300 ->
            case muse_json:decode(RespBody) of
                {ok, Result} -> {ok, Result};
                _ -> {ok, invalid}
            end;
        {ok, Status, RespHeaders, _} ->
            Retryable = retryable_status(Status),
            case Retryable andalso Left > 0 of
                true ->
                    Sleep(delay(Attempt, RespHeaders)),
                    send(Request, Sleep, Url, Headers0, Body, Attempt + 1);
                false ->
                    %% only 4xx other than 408 / 429 is final for the user
                    {failed, not (Status >= 400 andalso Status < 500 andalso Status =/= 408 andalso Status =/= 429),
                     #{status => Status, request_id => header(<<"x-typesafe-request-id">>, RespHeaders)}}
            end;
        {error, _Reason} when Left > 0 ->
            Sleep(delay(Attempt, [])),
            send(Request, Sleep, Url, Headers0, Body, Attempt + 1);
        {error, Reason} ->
            {failed, true, #{reason => Reason}}
    end.

retryable_status(S) -> S =:= 408 orelse S =:= 429 orelse (S >= 500 andalso S < 600).

delay(Attempt, Headers) ->
    case retry_after(Headers) of
        Ms when is_integer(Ms), Ms =< ?MAX_RETRY_AFTER_MS -> Ms;
        _ ->
            Exp = min(?BACKOFF_MS bsl Attempt, 5000),
            round(Exp * (1 - rand:uniform() * 0.25))
    end.

retry_after(Headers) ->
    case header(<<"retry-after-ms">>, Headers) of
        undefined ->
            case header(<<"retry-after">>, Headers) of
                undefined -> undefined;
                V -> try binary_to_integer(V) * 1000 catch _:_ -> undefined end
            end;
        V -> try binary_to_integer(V) catch _:_ -> undefined end
    end.

header(Name, Headers) ->
    case [V || {K, V} <- Headers, string:lowercase(to_bin(K)) =:= Name] of
        [V | _] -> to_bin(V);
        [] -> undefined
    end.

%% Answers -> decision (LiveJevAdapter.decide's validation)

answers(#{<<"allowedControls">> := Controls} = Input, #{<<"answers">> := Answers}) when is_map(Answers) ->
    case maps:get(<<"control">>, Answers, undefined) of
        #{<<"type">> := <<"choice">>, <<"choice">> := Chosen, <<"confidence">> := Conf}
          when is_number(Conf), Conf >= 0, Conf =< 1 ->
            case lists:member(Chosen, Controls) of
                false -> {error, <<"Jev returned an invalid control">>};
                true ->
                    Control = case Conf < ?OVERRIDE_CONFIDENCE of
                                  true -> hd(Controls);
                                  false -> Chosen
                              end,
                    scores(Answers, maps:get(<<"options">>, Input, []), 0, #{}, Control)
            end;
        _ -> {error, <<"Jev returned an invalid control">>}
    end;
answers(_Input, _Result) ->
    {error, <<"Jev returned invalid answers">>}.

scores(_Answers, [], _I, Acc, Control) ->
    {ok, #{<<"control">> => Control, <<"scores">> => Acc}};
scores(Answers, [#{<<"id">> := Id} | Rest], I, Acc, Control) ->
    case maps:get(<<"fit_", (integer_to_binary(I))/binary>>, Answers, undefined) of
        #{<<"type">> := <<"score">>, <<"score">> := S} when is_number(S), S >= 0, S =< 3 ->
            scores(Answers, Rest, I + 1, Acc#{Id => S}, Control);
        _ -> {error, <<"Jev returned an invalid score">>}
    end.

%% The real request (beamai_http, no retries of its own).
-spec request(binary(), [{binary(), binary()}], binary(), pos_integer()) ->
          {ok, integer(), [{binary(), binary()}], binary()} | {error, term()}.
request(Url, Headers, Body, Timeout) ->
    try beamai_http:request_meta(post, Url, Headers, Body, #{timeout => Timeout, retry => 0}) of
        {ok, Resp, #{status := Status} = Meta} when is_integer(Status) ->
            {ok, Status, maps:get(headers, Meta, []), to_bin(Resp)};
        {ok, _Resp, _Meta} ->
            {error, no_status};
        {error, {http_error, Status, Resp, RespHeaders}} ->
            {ok, Status, RespHeaders, to_bin(Resp)};
        {error, {http_error, Status, Resp}} ->
            {ok, Status, [], to_bin(Resp)};
        {error, Reason} ->
            {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(M) when is_map(M) -> muse_json:encode(M);
to_bin(undefined) -> <<>>;
to_bin(A) when is_atom(A) -> atom_to_binary(A).
