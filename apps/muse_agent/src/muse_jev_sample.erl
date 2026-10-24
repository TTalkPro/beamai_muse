%% @doc `SampleJevAdapter` of OpenMuse `jev/adapter.ts`
%% (designs/ref/openmuse-engine-spec.md §10.7): a deterministic stand-in
%% for Jev used by `JEV_MODE=sample` and the demo fixtures.
-module(muse_jev_sample).

-behaviour(muse_jev_adapter).

-export([decide/1]).

%% @doc Prefers the agent's prepared comparison, otherwise its first allowed
%% control. Options score `n - index`, except that a hands-on request scores
%% touch/rocky/interactive options 10.
-spec decide(map()) -> {ok, muse_jev_adapter:decision()}.
decide(#{<<"message">> := Message, <<"options">> := Options, <<"allowedControls">> := Allowed}) ->
    HandsOn = matches(Message, <<"hands[ -]?on|touch|interactive">>),
    N = length(Options),
    Scores = maps:from_list(
               [{Id, case HandsOn andalso matches(text(O), <<"touch|rocky|interactive">>) of
                         true -> 10;
                         false -> N - I
                     end}
                || {I, #{<<"id">> := Id} = O} <- lists:zip(lists:seq(0, N - 1), Options)]),
    Control = case lists:member(<<"comparison">>, Allowed) of
                  true -> <<"comparison">>;
                  false -> hd(Allowed)
              end,
    {ok, #{<<"control">> => Control, <<"scores">> => Scores}}.

text(#{<<"label">> := Label, <<"details">> := Details}) ->
    iolist_to_binary([Label, " ", lists:join(" ", Details)]).

matches(Text, Re) ->
    re:run(Text, Re, [caseless, unicode, {capture, none}]) =:= match.
