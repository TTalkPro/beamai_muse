%% @doc Watched-page comparison: page-diff.ts plus the pure text helpers of
%% the monitor observe step in service.ts (designs/ref/openmuse-engine-spec.md
%% §5.5 "Monitor observe" steps 3, 4 and 6, and §5.6).
%%
%% JS string semantics are reproduced on UTF-8 binaries:
%%
%% - `\s` and `trim` use the ECMAScript whitespace set (an explicit class;
%%   PCRE's own `\s` differs);
%% - `\b` and `\d` stay ASCII; with the `iu` flags `\w` also covers U+017F and
%%   U+212A, so the relative-time pattern spells its boundaries out;
%% - `slice` counts UTF-16 code units (`slice/2`). A cut through a surrogate
%%   pair drops the whole character, where JS would keep a lone surrogate.
%%
%% A diff is `#{added, updated, removed}`, each a list of lines.
-module(muse_page_diff).

-export([page_lines/1, page_lines/2,
         without_relative_times/1,
         diff_page/2, describe_page_diff/1, count_page_diff/1,
         collapse_text/1, matches_contains/2, matches_price/2,
         slice/2]).

-export_type([diff/0]).

-type diff() :: #{added := [binary()], updated := [binary()], removed := [binary()]}.

-define(WS, "[\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}"
            "\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]").
-define(IU_WORD, "[A-Za-z0-9_\\x{17F}\\x{212A}]").

%% @doc `pageLines(text)`: at most 2000 unique lines.
-spec page_lines(binary()) -> [binary()].
page_lines(Text) ->
    page_lines(Text, 2000).

%% @doc `pageLines(text, limit)`: split on `\r?\n`, collapse whitespace, trim,
%% cut to 300 UTF-16 units, drop empties, dedupe in first-seen order.
-spec page_lines(binary(), non_neg_integer()) -> [binary()].
page_lines(Text, Limit) ->
    lines(binary:split(Text, [<<"\r\n">>, <<"\n">>], [global]), Limit, #{}, 0, []).

lines([], _Limit, _Seen, _N, Acc) ->
    lists:reverse(Acc);
lines([Raw | Rest], Limit, Seen, N0, Acc0) ->
    Line = slice(collapse_text(Raw), 300),
    {Seen1, N, Acc} = case Line =:= <<>> orelse is_map_key(Line, Seen) of
                          true -> {Seen, N0, Acc0};
                          false -> {Seen#{Line => true}, N0 + 1, [Line | Acc0]}
                      end,
    case N >= Limit of
        true -> lists:reverse(Acc);
        false -> lines(Rest, Limit, Seen1, N, Acc)
    end.

%% @doc `withoutRelativeTimes(text)`: every relative time becomes `<time>`.
-spec without_relative_times(binary()) -> binary().
without_relative_times(Text) ->
    re:replace(Text, mp(relative_time), <<"<time>">>, [global, {return, binary}]).

%% @doc `diffPage(previous, current)`.
-spec diff_page([binary()], [binary()]) -> diff().
diff_page(Previous, Current) ->
    {_, SameUnpaired, SameLeft} = pair(Previous, Current, fun(L) -> L end),
    {_, RetimedUnpaired, RetimedLeft} =
        pair(SameLeft, SameUnpaired, fun without_relative_times/1),
    {Paired, Unpaired, Left} = pair(RetimedLeft, RetimedUnpaired, fun numberless/1),
    #{added => Unpaired, updated => Paired, removed => Left}.

%% @doc `describePageDiff(diff)`: "New/Updated/Removed" sections, or `<<>>`.
-spec describe_page_diff(diff()) -> binary().
describe_page_diff(#{added := Added, updated := Updated, removed := Removed}) ->
    Lines = section(<<"New">>, Added, 8) ++ section(<<"Updated">>, Updated, 4)
        ++ section(<<"Removed">>, Removed, 4),
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

%% @doc `countPageDiff(diff)`, e.g. `3 lines changed (2 new, 1 updated)`, or `<<>>`.
-spec count_page_diff(diff()) -> binary().
count_page_diff(#{added := Added, updated := Updated, removed := Removed}) ->
    Counts = [{length(Added), <<" new">>}, {length(Updated), <<" updated">>},
              {length(Removed), <<" removed">>}],
    case lists:sum([N || {N, _} <- Counts]) of
        0 -> <<>>;
        Total ->
            Parts = [[integer_to_binary(N), Label] || {N, Label} <- Counts, N > 0],
            iolist_to_binary([integer_to_binary(Total),
                              case Total of 1 -> <<" line">>; _ -> <<" lines">> end,
                              <<" changed (">>, lists:join(<<", ">>, Parts), <<")">>])
    end.

%% @doc Observe step 3: `text.replace(/\s+/g, " ").trim()`.
-spec collapse_text(binary()) -> binary().
collapse_text(Text) ->
    Collapsed = re:replace(Text, mp(whitespace), <<" ">>, [global, {return, binary}]),
    trim_space(Collapsed).

%% @doc The `contains` condition: case-insensitive substring test
%% (`text.toLowerCase().includes(value.toLowerCase())`).
-spec matches_contains(binary(), binary()) -> boolean().
matches_contains(_Text, <<>>) ->
    true;
matches_contains(Text, Value) ->
    binary:match(lower(Text), lower(Value)) =/= nomatch.

%% @doc The `price_below` condition (`matchesPrice(text, Number(value))`):
%% some `$`/`USD` amount on the page is below the threshold. A binary
%% threshold is converted with JS `Number()` semantics.
-spec matches_price(binary(), number() | binary()) -> boolean().
matches_price(Text, Value) when is_binary(Value) ->
    case js_number(Value) of
        nan -> false;
        Threshold -> matches_price(Text, Threshold)
    end;
matches_price(Text, Threshold) ->
    case re:run(Text, mp(price), [global, {capture, all_but_first, binary}]) of
        nomatch -> false;
        {match, Groups} ->
            lists:any(fun([Digits]) ->
                              below(price(binary:replace(Digits, <<",">>, <<>>, [global])),
                                    Threshold)
                      end, Groups)
    end.

%% @doc `String.prototype.slice(0, Units)` measured in UTF-16 code units.
-spec slice(binary(), non_neg_integer()) -> binary().
slice(Bin, Units) ->
    binary:part(Bin, 0, slice_bytes(Bin, 0, Units)).

%% Internals

section(_Title, [], _Limit) ->
    [];
section(Title, Lines, Limit) ->
    Shown = [<<"\x{2022} "/utf8, (slice(L, 160))/binary>> || L <- lists:sublist(Lines, Limit)],
    More = case length(Lines) > Limit of
               true -> [<<"+", (integer_to_binary(length(Lines) - Limit))/binary, " more">>];
               false -> []
           end,
    [<<Title/binary, ":">> | Shown ++ More].

%% Pairs each current line with one unused previous line of the same key.
%% Returns {Paired, Unpaired, Left}; Left filters by value like the TS.
pair(Previous, Current, Key) ->
    Open0 = lists:foldl(fun(L, M) ->
                                K = Key(L),
                                M#{K => [L | maps:get(K, M, [])]}
                        end, #{}, Previous),
    Open = maps:map(fun(_, Ls) -> lists:reverse(Ls) end, Open0),
    {_, Used, Paired, Unpaired} =
        lists:foldl(fun(L, {O, U, P, Un}) ->
                            K = Key(L),
                            case O of
                                #{K := [Match | Rest]} ->
                                    {O#{K := Rest}, U#{Match => true}, [L | P], Un};
                                _ ->
                                    {O, U, P, [L | Un]}
                            end
                    end, {Open, #{}, [], []}, Current),
    {lists:reverse(Paired), lists:reverse(Unpaired),
     [L || L <- Previous, not is_map_key(L, Used)]}.

%% Any number change is news: digits become `#`, a plural `s` is dropped.
numberless(Line) ->
    Hashed = re:replace(without_relative_times(Line), mp(number), <<"#">>,
                        [global, {return, binary}]),
    lower(re:replace(Hashed, mp(plural), <<"\\1">>, [global, {return, binary}])).

lower(Bin) ->
    unicode:characters_to_binary(string:lowercase(Bin)).

trim_space(<<" ", Rest/binary>>) ->
    trim_space(Rest);
trim_space(Bin) ->
    case byte_size(Bin) of
        0 -> Bin;
        N ->
            case binary:last(Bin) of
                $\s -> binary:part(Bin, 0, N - 1);
                _ -> Bin
            end
    end.

slice_bytes(_Bin, Pos, 0) ->
    Pos;
slice_bytes(Bin, Pos, Units) ->
    case Bin of
        <<_:Pos/binary, C/utf8, _/binary>> when C > 16#FFFF, Units >= 2 ->
            slice_bytes(Bin, Pos + 4, Units - 2);
        <<_:Pos/binary, C/utf8, _/binary>> when C > 16#FFFF ->
            Pos;
        <<_:Pos/binary, C/utf8, _/binary>> ->
            slice_bytes(Bin, Pos + byte_size(<<C/utf8>>), Units - 1);
        <<_:Pos/binary, _, _/binary>> ->
            slice_bytes(Bin, Pos + 1, Units - 1);
        _ ->
            Pos
    end.

price(Digits) ->
    case binary:split(Digits, <<".">>) of
        [Int] -> decimal(Int, <<"0">>, <<>>);
        [Int, Frac] -> decimal(Int, Frac, <<>>)
    end.

below(inf, _) -> false;
below(_, inf) -> true;
below(_, neg_inf) -> false;
below(_, nan) -> false;
below(P, T) -> P < T.

%% A non-negative decimal literal as a double; `inf` past the double range.
decimal(Int, Frac, Exp) ->
    try binary_to_float(<<Int/binary, ".", Frac/binary, Exp/binary>>)
    catch
        error:badarg ->
            case string:trim(<<Int/binary, Frac/binary>>, both, "0") of
                <<>> -> 0.0;
                _ -> case Exp of
                         <<"e-", _/binary>> -> 0.0;
                         _ -> inf
                     end
            end
    end.

%% JS `Number(string)` for the threshold value.
js_number(Value) ->
    case trim_space(collapse_text(Value)) of
        <<>> -> 0;
        <<"Infinity">> -> inf;
        <<"+Infinity">> -> inf;
        <<"-Infinity">> -> neg_inf;
        <<"0", X, Rest/binary>> when X =:= $x; X =:= $X -> radix(Rest, 16);
        <<"0", X, Rest/binary>> when X =:= $o; X =:= $O -> radix(Rest, 8);
        <<"0", X, Rest/binary>> when X =:= $b; X =:= $B -> radix(Rest, 2);
        Trimmed ->
            case re:run(Trimmed, <<"^([+-]?)(\\d*)(?:\\.(\\d*))?(?:[eE]([+-]?\\d+))?$">>,
                        [{capture, all_but_first, binary}]) of
                {match, Caps} ->
                    [Sign, Int, Frac, Exp] = lists:sublist(Caps ++ [<<>>, <<>>, <<>>], 4),
                    number_parts(Sign, Int, Frac, Exp);
                _ -> nan
            end
    end.

number_parts(_Sign, <<>>, <<>>, _Exp) ->
    nan;
number_parts(Sign, Int, Frac, Exp) ->
    V = decimal(zero(Int), zero(Frac), case Exp of <<>> -> <<>>; _ -> <<"e", Exp/binary>> end),
    case {Sign, V} of
        {<<"-">>, inf} -> neg_inf;
        {<<"-">>, F} -> -F;
        {_, F} -> F
    end.

zero(<<>>) -> <<"0">>;
zero(Digits) -> Digits.

radix(<<>>, _) -> nan;
radix(<<S, _/binary>>, _) when S =:= $+; S =:= $- -> nan;
radix(Digits, Base) ->
    try binary_to_integer(Digits, Base) of
        I -> try float(I) catch error:_ -> inf end
    catch error:_ -> nan
    end.

mp(Name) ->
    Key = {?MODULE, Name},
    case persistent_term:get(Key, undefined) of
        undefined ->
            {ok, MP} = re:compile(pattern(Name), options(Name)),
            persistent_term:put(Key, MP),
            MP;
        MP -> MP
    end.

pattern(whitespace) ->
    <<?WS "+">>;
pattern(relative_time) ->
    <<"(?<!" ?IU_WORD ")(?:\\d+|an?|one)" ?WS "+"
      "(?:sec(?:ond)?|min(?:ute)?|hour|hr|day|week|month|year)s?" ?WS "+ago(?!" ?IU_WORD ")"
      "|(?<!" ?IU_WORD ")vor" ?WS "+(?:\\d+|einer?|einem)" ?WS "+"
      "(?:sekunde|minute|stunde|tag|woche|monat|jahr)(?:e|en|n)?(?!" ?IU_WORD ")">>;
pattern(number) ->
    <<"\\d+(?:[.,]\\d+)*">>;
pattern(plural) ->
    <<"(\\p{L})s\\b">>;
pattern(price) ->
    <<"(?:\\$|USD)" ?WS "*(\\d+(?:,\\d{3})*(?:\\.\\d{1,2})?)">>.

options(relative_time) -> [unicode, caseless];
options(_) -> [unicode].
