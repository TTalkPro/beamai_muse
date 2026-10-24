%% @doc Jev decision adapters: OpenMuse `jev/adapter.ts`
%% (designs/ref/openmuse-engine-spec.md §10.4 step 7, §10.7).
%%
%% An adapter is a fun `fun(Input) -> {ok, Decision} | {error, Msg}`:
%%
%% ```
%% Input    #{<<"userMessage">>, <<"message">>, <<"context">>,
%%            <<"options">> => [JevOption], <<"allowedControls">> => [Control],
%%            <<"selectedId">> => Id (absent when none)}
%% Decision #{<<"control">> => <<"clarification">> | <<"comparison">> | <<"agent">>,
%%            <<"scores">> => #{OptionId => number()}}
%% '''
%%
%% Modules implementing the `decide/1` callback plug in as
%% `fun Mod:decide/1`. `JEV_MODE=sample` uses `muse_jev_sample`,
%% `JEV_MODE=live` the TypeSafe System One adapter `muse_jev_typesafe`.
-module(muse_jev_adapter).

-export([for_mode/1, rank/2]).

-export_type([adapter/0, decision/0]).

-type decision() :: #{binary() => term()}.
-type adapter() :: fun((map()) -> {ok, decision()} | {error, binary()}).

-callback decide(Input :: map()) -> {ok, decision()} | {error, binary()}.

-spec for_mode(off | sample | live) -> adapter() | undefined.
for_mode(sample) -> fun muse_jev_sample:decide/1;
for_mode(live) -> fun muse_jev_typesafe:decide/1;
for_mode(off) -> undefined.

%% @doc `rankJevOptions`: scores must cover exactly the option ids with
%% finite numbers; sort by `Math.round(score)` descending, stable on ties.
-spec rank([map()], decision()) -> {ok, [map()]} | {error, binary()}.
rank(Options, #{<<"scores">> := Scores}) when is_map(Scores) ->
    Ids = [Id || #{<<"id">> := Id} <- Options],
    case map_size(Scores) =:= length(Options)
         andalso lists:all(fun(K) -> lists:member(K, Ids) end, maps:keys(Scores)) of
        false ->
            {error, <<"Jev returned invalid score IDs">>};
        true ->
            case lists:all(fun(Id) -> is_number(maps:get(Id, Scores, undefined)) end, Ids) of
                false ->
                    {error, <<"Jev returned a missing or invalid score">>};
                true ->
                    Level = fun(#{<<"id">> := Id}) -> js_round(maps:get(Id, Scores)) end,
                    Indexed = lists:zip(lists:seq(1, length(Options)), Options),
                    Sorted = lists:sort(fun({Ia, A}, {Ib, B}) ->
                                                {-Level(A), Ia} =< {-Level(B), Ib}
                                        end, Indexed),
                    {ok, [O || {_, O} <- Sorted]}
            end
    end;
rank(_, _) ->
    {error, <<"Jev returned invalid score IDs">>}.

%% Math.round: halves round towards +Infinity.
js_round(X) -> floor(X + 0.5).
