%% @doc Request and tool-argument validation modelled on the zod schemas of
%% OpenMuse.
%%
%% A schema is plain data:
%%
%% ```
%% {string, Opts}       Opts: trim, min, max, regex, email, url, nonblank,
%%                      single_line, enum => [Bin]
%% {integer, Opts}      Opts: min, max
%% {number, Opts}       Opts: min, max
%% boolean
%% {literal, Value}
%% {enum, [Bin]}
%% {array, Item, Opts}  Opts: min, max
%% {object, [{Key, Schema}]}             unknown keys are stripped
%% {record, ValueSchema, Opts}           Opts: key => StringSchema, max
%% {union, [Schema]}                     first match wins
%% {tagged, Key, #{Tag => ObjectSchema}} discriminated union on Key
%% {optional, Schema}                    absent or null-free; missing stays missing
%% {nullable, Schema}
%% {default, Schema, Value}
%% {refine, Schema, fun((V) -> ok | {error, Msg})}
%% {desc, Text, Schema}                 validates as Schema; Text documents the field for LLM tools
%% any
%% '''
%%
%% Every leaf option map may carry `message => Bin` to replace the default
%% messages. Lengths count UTF-16 code units like JavaScript `string.length`.
%%
%% `check/2` returns `{ok, Normalised}` or `{error, [Message]}`; `parse/2`
%% returns `{error, {422, Joined}}` with messages joined by `"; "` (the
%% OpenMuse HTTP error contract).
-module(muse_validate).

-export([check/2, parse/2, ordered/2, utf16_length/1, is_email/1, is_url/1]).

-export_type([schema/0]).

-type schema() :: term().

-spec parse(schema(), term()) -> {ok, term()} | {error, {422, binary()}}.
parse(Schema, Value) ->
    case check(Schema, Value) of
        {ok, V} -> {ok, V};
        {error, Msgs} -> {error, {422, join(Msgs)}}
    end.

-spec check(schema(), term()) -> {ok, term()} | {error, [binary()]}.
check(Schema, Value) ->
    case v(Schema, Value) of
        {ok, V} -> {ok, V};
        {error, Msgs} -> {error, lists:flatten([Msgs])}
    end.

%% @doc Re-express a normalised value as `muse_json` ordered objects, keys in
%% schema order, so hashes match `JSON.stringify` of the zod output.
-spec ordered(schema(), term()) -> muse_json:json().
ordered({object, Fields}, Map) when is_map(Map) ->
    {obj, [{K, ordered(S, maps:get(K, Map))} || {K, S} <- Fields, maps:is_key(K, Map)]};
ordered({tagged, Key, Variants}, Map) when is_map(Map) ->
    ordered(maps:get(maps:get(Key, Map), Variants), Map);
ordered({array, Item, _}, List) when is_list(List) ->
    [ordered(Item, X) || X <- List];
ordered({Wrap, S}, V) when Wrap =:= optional; Wrap =:= nullable ->
    ordered(S, V);
ordered({default, S, _}, V) -> ordered(S, V);
ordered({refine, S, _}, V) -> ordered(S, V);
ordered({desc, _, S}, V) -> ordered(S, V);
ordered(_, V) -> V.

-spec utf16_length(binary()) -> non_neg_integer().
utf16_length(Bin) ->
    lists:foldl(fun(C, N) when C > 16#FFFF -> N + 2; (_, N) -> N + 1 end,
                0, unicode:characters_to_list(Bin)).

-spec is_email(binary()) -> boolean().
is_email(Bin) ->
    %% zod v4's default email pattern (no quoted local parts, ASCII domain).
    re:run(Bin, <<"^(?!\\.)(?!.*\\.\\.)([A-Za-z0-9_'+\\-\\.]*)[A-Za-z0-9_+-]@"
                  "([A-Za-z0-9][A-Za-z0-9\\-]*\\.)+[A-Za-z]{2,}$">>,
           [{capture, none}]) =:= match.

-spec is_url(binary()) -> boolean().
is_url(Bin) ->
    case uri_string:parse(Bin) of
        #{scheme := S, host := H} when S =/= <<>>, H =/= <<>> -> true;
        #{scheme := S} when S =/= <<>> -> true;
        _ -> false
    end.

%% Validators. Each returns {ok, V} | {error, Msgs}.

v(any, V) -> {ok, V};
v({desc, _, S}, V) -> v(S, V);
v({optional, _}, undefined) -> {ok, undefined};
v({optional, S}, V) -> v(S, V);
v({nullable, _}, null) -> {ok, null};
v({nullable, S}, V) -> v(S, V);
v({default, _, D}, undefined) -> {ok, D};
v({default, S, _}, V) -> v(S, V);
v({refine, S, Fun}, V) ->
    case v(S, V) of
        {ok, V1} ->
            case Fun(V1) of
                ok -> {ok, V1};
                {ok, V2} -> {ok, V2};
                {error, Msg} -> {error, [Msg]}
            end;
        Error -> Error
    end;
v({literal, L}, L) -> {ok, L};
v({literal, L}, V) ->
    {error, [<<"Invalid input: expected ", (muse_json:encode(L))/binary,
               (received(V))/binary>>]};
v(boolean, V) when is_boolean(V) -> {ok, V};
v(boolean, V) -> type_error(<<"boolean">>, V);
v({enum, Allowed}, V) when is_binary(V) ->
    case lists:member(V, Allowed) of
        true -> {ok, V};
        false -> {error, [enum_message(Allowed)]}
    end;
v({enum, Allowed}, _) -> {error, [enum_message(Allowed)]};
v({string, Opts}, V) when is_binary(V) -> string(Opts, V);
v({string, Opts}, V) -> type_error(<<"string">>, V, Opts);
v({integer, Opts}, V) when is_integer(V) -> range(Opts, V, <<"number">>);
v({integer, Opts}, V) when is_float(V), V == trunc(V) -> range(Opts, trunc(V), <<"number">>);
v({integer, Opts}, V) -> type_error(<<"int">>, V, Opts);
v({number, Opts}, V) when is_number(V) -> range(Opts, V, <<"number">>);
v({number, Opts}, V) -> type_error(<<"number">>, V, Opts);
v({array, Item, Opts}, L) when is_list(L) -> array(Item, Opts, L);
v({array, _, Opts}, V) -> type_error(<<"array">>, V, Opts);
v({object, Fields}, M) when is_map(M) -> object(Fields, M);
v({object, _}, V) -> type_error(<<"object">>, V);
v({record, ValS, Opts}, M) when is_map(M) -> record(ValS, Opts, M);
v({record, _, Opts}, V) -> type_error(<<"record">>, V, Opts);
v({union, Schemas}, V) -> union(Schemas, V, []);
v({tagged, Key, Variants}, M) when is_map(M) ->
    case maps:find(Key, M) of
        {ok, Tag} when is_map_key(Tag, Variants) -> v(maps:get(Tag, Variants), M);
        _ ->
            {error, [<<"Invalid input: expected ", Key/binary, " to be one of ",
                       (options(maps:keys(Variants)))/binary>>]}
    end;
v({tagged, _, _}, V) -> type_error(<<"object">>, V).

string(Opts, V0) ->
    V = case maps:get(trim, Opts, false) of
            true -> trim(V0);
            false -> V0
        end,
    Len = utf16_length(V),
    Checks = [fun() -> min_len(Opts, Len) end,
              fun() -> max_len(Opts, Len) end,
              fun() -> nonblank(Opts, V) end,
              fun() -> single_line(Opts, V) end,
              fun() -> pattern(Opts, V) end,
              fun() -> format(Opts, V) end,
              fun() -> one_of(Opts, V) end],
    case first_error(Checks) of
        ok -> {ok, V};
        {error, Msg} -> {error, [custom(Opts, Msg)]}
    end.

min_len(#{min := Min}, Len) when Len < Min ->
    {error, <<"Too small: expected string to have >=", (integer_to_binary(Min))/binary,
              " characters">>};
min_len(_, _) -> ok.

max_len(#{max := Max}, Len) when Len > Max ->
    {error, <<"Too big: expected string to have <=", (integer_to_binary(Max))/binary,
              " characters">>};
max_len(_, _) -> ok.

nonblank(#{nonblank := true}, V) ->
    case trim(V) of
        <<>> -> {error, <<"Too small: expected a nonblank string">>};
        _ -> ok
    end;
nonblank(_, _) -> ok.

single_line(#{single_line := true}, V) ->
    case binary:match(V, [<<"\r">>, <<"\n">>]) of
        nomatch -> ok;
        _ -> {error, <<"Must be a single line">>}
    end;
single_line(_, _) -> ok.

pattern(#{regex := Re}, V) ->
    case re:run(V, Re, [unicode, {capture, none}]) of
        match -> ok;
        nomatch -> {error, <<"Invalid string: must match pattern">>}
    end;
pattern(_, _) -> ok.

format(#{email := true}, V) ->
    case is_email(V) of
        true -> ok;
        false -> {error, <<"Invalid email address">>}
    end;
format(#{url := true}, V) ->
    case is_url(V) of
        true -> ok;
        false -> {error, <<"Invalid URL">>}
    end;
format(_, _) -> ok.

one_of(#{enum := Allowed}, V) ->
    case lists:member(V, Allowed) of
        true -> ok;
        false -> {error, enum_message(Allowed)}
    end;
one_of(_, _) -> ok.

range(Opts, V, What) ->
    Min = maps:get(min, Opts, undefined),
    Max = maps:get(max, Opts, undefined),
    if
        Min =/= undefined, V < Min ->
            {error, [custom(Opts, <<"Too small: expected ", What/binary, " to be >=",
                                    (muse_json:number(Min))/binary>>)]};
        Max =/= undefined, V > Max ->
            {error, [custom(Opts, <<"Too big: expected ", What/binary, " to be <=",
                                    (muse_json:number(Max))/binary>>)]};
        true ->
            {ok, V}
    end.

array(Item, Opts, L) ->
    Len = length(L),
    case {maps:get(min, Opts, undefined), maps:get(max, Opts, undefined)} of
        {Min, _} when Min =/= undefined, Len < Min ->
            {error, [custom(Opts, <<"Too small: expected array to have >=",
                                    (integer_to_binary(Min))/binary, " items">>)]};
        {_, Max} when Max =/= undefined, Len > Max ->
            {error, [custom(Opts, <<"Too big: expected array to have <=",
                                    (integer_to_binary(Max))/binary, " items">>)]};
        _ ->
            collect([v(Item, X) || X <- L])
    end.

object(Fields, M) ->
    Results = [{K, v(S, maps:get(K, M, undefined))} || {K, S} <- Fields],
    case [Msgs || {_, {error, Msgs}} <- Results] of
        [] -> {ok, maps:from_list([{K, V} || {K, {ok, V}} <- Results, V =/= undefined])};
        Errors -> {error, lists:append(Errors)}
    end.

record(ValS, Opts, M) ->
    KeyS = maps:get(key, Opts, {string, #{}}),
    case maps:get(max, Opts, undefined) of
        Max when is_integer(Max), map_size(M) > Max ->
            {error, [custom(Opts, <<"Too big: expected record to have <=",
                                    (integer_to_binary(Max))/binary, " entries">>)]};
        _ ->
            Results = [{v(KeyS, K), v(ValS, V)} || {K, V} <- lists:sort(maps:to_list(M))],
            Errors = lists:append([E || {{error, E}, _} <- Results] ++
                                  [E || {_, {error, E}} <- Results]),
            case Errors of
                [] -> {ok, maps:from_list([{K, V} || {{ok, K}, {ok, V}} <- Results])};
                _ -> {error, Errors}
            end
    end.

union([], _V, Errors) ->
    {error, [<<"Invalid input">> | lists:reverse(Errors)]};
union([S | Rest], V, Errors) ->
    case v(S, V) of
        {ok, _} = Ok -> Ok;
        {error, _} -> union(Rest, V, Errors)
    end.

collect(Results) ->
    case [Msgs || {error, Msgs} <- Results] of
        [] -> {ok, [V || {ok, V} <- Results]};
        Errors -> {error, lists:append(Errors)}
    end.

first_error([]) -> ok;
first_error([F | Rest]) ->
    case F() of
        ok -> first_error(Rest);
        Error -> Error
    end.

custom(#{message := Msg}, _) -> Msg;
custom(_, Msg) -> Msg.

type_error(Expected, V) -> type_error(Expected, V, #{}).

type_error(Expected, V, Opts) ->
    {error, [custom(Opts, <<"Invalid input: expected ", Expected/binary,
                            (received(V))/binary>>)]}.

received(undefined) -> <<", received undefined">>;
received(null) -> <<", received null">>;
received(V) when is_binary(V) -> <<", received string">>;
received(V) when is_boolean(V) -> <<", received boolean">>;
received(V) when is_number(V) -> <<", received number">>;
received(V) when is_list(V) -> <<", received array">>;
received(V) when is_map(V) -> <<", received object">>;
received(_) -> <<>>.

enum_message(Allowed) ->
    <<"Invalid option: expected one of ", (options(Allowed))/binary>>.

options(Allowed) ->
    iolist_to_binary(lists:join(<<"|">>, [muse_json:encode(A) || A <- Allowed])).

join(Msgs) ->
    iolist_to_binary(lists:join(<<"; ">>, Msgs)).

%% JavaScript String.prototype.trim: strips WhiteSpace and LineTerminator.
trim(Bin) ->
    Ws = [$\s, $\t, $\n, $\r, 16#0B, 16#0C, 16#A0, 16#1680, 16#2000, 16#2001,
          16#2002, 16#2003, 16#2004, 16#2005, 16#2006, 16#2007, 16#2008, 16#2009,
          16#200A, 16#2028, 16#2029, 16#202F, 16#205F, 16#3000, 16#FEFF],
    Chars = unicode:characters_to_list(Bin),
    Strip = fun(L) -> lists:dropwhile(fun(C) -> lists:member(C, Ws) end, L) end,
    unicode:characters_to_binary(lists:reverse(Strip(lists:reverse(Strip(Chars))))).
