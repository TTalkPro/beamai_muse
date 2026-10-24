%% @doc Spending analysis of an imported transaction CSV: `analyzeSpending`
%% from finance.ts (designs/ref/openmuse-engine-spec.md §5.7, finance task
%% handler in §5.7 "Finance task handler").
%%
%% Behaviour matches the TS byte for byte:
%%
%% - the 500000 limit counts UTF-16 code units like `csv.length`;
%% - the hand-written CSV parser (quotes, `""` escapes, trailing `\r`
%%   removal, blank-row skipping) runs on UTF-8 bytes, which is equivalent
%%   because every delimiter is ASCII;
%% - `trim` uses the JS WhiteSpace + LineTerminator set, not `string:trim`;
%% - dates follow zod `z.iso.date()` (a real proleptic-Gregorian date) and
%%   cents are `Math.round(Number(amount) * 100)` on doubles;
%% - money values are `cents / 100`: an integer when exact, else the same
%%   double JS produces.
%%
%% Errors are `{error, Message}` with the exact TS `Error` text.
%%
%% `analyze/1` returns a binary-keyed map for Erlang callers; `to_json/1`
%% gives the same data as ordered `{obj, ...}` terms so that
%% `muse_json:encode/1` reproduces `JSON.stringify(analyzeSpending(csv))`
%% exactly (artifact data is shown to users verbatim).
-module(muse_finance).

-export([analyze/1, summary/1, excerpt/1, to_json/1, to_fixed/2]).

-export_type([analysis/0]).

-type analysis() :: #{binary() => term()}.

-define(MAX_UNITS, 500000).
-define(MAX_ROWS, 5000).
-define(MAX_CENTS, 1000000000000).
-define(REQUIRED, [<<"date">>, <<"description">>, <<"amount">>, <<"category">>]).
-define(CONVENTION, <<"Positive expenses; negative income. Values use the source "
                      "currency; no currency conversion.">>).

%% @doc `analyzeSpending(csv)`. The map has keys `income`, `spending`,
%% `saved`, `count`, `categories` (`[#{name, amount}]`), `transactions`
%% (`[#{id, date, description, amount, category}]`), `period`
%% (`#{from, to}`) and `amountConvention`.
-spec analyze(binary()) -> {ok, analysis()} | {error, binary()}.
analyze(Csv) when is_binary(Csv) ->
    try
        {ok, analyze_(Csv)}
    catch
        throw:{finance, Msg} -> {error, Msg}
    end.

%% @doc Artifact summary: `${count} transactions · ${spending.toFixed(2)} spent`.
-spec summary(analysis()) -> binary().
summary(#{<<"count">> := Count, <<"spending">> := Spending}) ->
    <<(integer_to_binary(Count))/binary, " transactions \x{b7} "/utf8,
      (to_fixed(Spending, 2))/binary, " spent">>.

%% @doc Evidence excerpt: `${count} rows; ${from} through ${to}`.
-spec excerpt(analysis()) -> binary().
excerpt(#{<<"count">> := Count, <<"period">> := #{<<"from">> := From, <<"to">> := To}}) ->
    <<(integer_to_binary(Count))/binary, " rows; ", From/binary, " through ", To/binary>>.

%% @doc The analysis with the TS key order, for `muse_json:encode/1`.
-spec to_json(analysis()) -> muse_json:json().
to_json(A) ->
    #{<<"period">> := #{<<"from">> := From, <<"to">> := To}} = A,
    Cats = [{obj, [{<<"name">>, N}, {<<"amount">>, M}]}
            || #{<<"name">> := N, <<"amount">> := M} <- maps:get(<<"categories">>, A)],
    Txs = [{obj, [{K, maps:get(K, T)}
                  || K <- [<<"id">>, <<"date">>, <<"description">>, <<"amount">>,
                           <<"category">>]]}
           || T <- maps:get(<<"transactions">>, A)],
    {obj, [{<<"income">>, maps:get(<<"income">>, A)},
           {<<"spending">>, maps:get(<<"spending">>, A)},
           {<<"saved">>, maps:get(<<"saved">>, A)},
           {<<"count">>, maps:get(<<"count">>, A)},
           {<<"categories">>, Cats},
           {<<"transactions">>, Txs},
           {<<"period">>, {obj, [{<<"from">>, From}, {<<"to">>, To}]}},
           {<<"amountConvention">>, maps:get(<<"amountConvention">>, A)}]}.

%% @doc `Number.prototype.toFixed(Digits)`: exact decimal value of the
%% double, ties toward the larger magnitude, `String(x)` from 1e21 up.
-spec to_fixed(number(), 0..100) -> binary().
to_fixed(X, Digits) when is_integer(X) ->
    to_fixed(float(X), Digits);
to_fixed(X, _Digits) when abs(X) >= 1.0e21 ->
    muse_json:number(X);
to_fixed(X, Digits) when X < 0 ->
    <<"-", (to_fixed(-X, Digits))/binary>>;
to_fixed(X, Digits) ->
    {M, E} = decompose(X),
    Scale = pow10(Digits),
    N = case E >= 0 of
            true -> M * Scale bsl E;
            false ->
                Den = 1 bsl -E,
                (2 * M * Scale + Den) div (2 * Den)
        end,
    S = integer_to_binary(N),
    case Digits of
        0 -> S;
        _ ->
            Padded = pad_zeros(S, Digits + 1),
            IntLen = byte_size(Padded) - Digits,
            <<Int:IntLen/binary, Frac/binary>> = Padded,
            <<Int/binary, ".", Frac/binary>>
    end.

%% Analysis

analyze_(Csv0) ->
    utf16_units(Csv0) > ?MAX_UNITS andalso
        fail(<<"Import at most 500 KB of transaction CSV">>),
    Csv = case Csv0 of
              <<16#EF, 16#BB, 16#BF, Rest/binary>> -> Rest;
              _ -> Csv0
          end,
    {Header, Rows} = case parse(Csv, <<>>, [], [], false) of
                         [] -> {undefined, []};
                         [H | T] -> {[string:lowercase(trim(V)) || V <- H], T}
                     end,
    (Header =:= undefined orelse not lists:all(fun(N) -> lists:member(N, Header) end,
                                               ?REQUIRED))
        andalso fail(<<"CSV needs date,description,amount,category columns">>),
    lists:any(fun(N) -> length([V || V <- Header, V =:= N]) > 1 end, ?REQUIRED)
        andalso fail(<<"CSV has a duplicate required column">>),
    (Rows =:= [] orelse length(Rows) > ?MAX_ROWS)
        andalso fail(<<"Import between 1 and 5,000 transactions">>),
    Index = maps:from_list([{N, index_of(N, Header, 1)} || N <- ?REQUIRED]),
    Txs = transactions(Rows, 2, length(Header), Index, []),
    totals(Txs).

transactions([], _, _, _, Acc) ->
    lists:reverse(Acc);
transactions([Row | Rows], RowNo, Width, Index, Acc) ->
    No = integer_to_binary(RowNo),
    length(Row) =/= Width
        andalso fail(<<"Row ", No/binary, " has the wrong number of columns">>),
    Get = fun(Name) -> trim(lists:nth(maps:get(Name, Index), Row)) end,
    Date = Get(<<"date">>),
    Cents = case is_iso_date(Date) of
                true -> cents(Get(<<"amount">>));
                false -> invalid
            end,
    Cents =:= invalid
        andalso fail(<<"Row ", No/binary, " needs an ISO date and a plain amount with "
                       "at most two decimal places">>),
    Category = case Get(<<"category">>) of
                   <<>> -> <<"Uncategorized">>;
                   C -> C
               end,
    Tx = #{<<"id">> => <<"row-", No/binary>>, <<"date">> => Date,
           <<"description">> => Get(<<"description">>), <<"amount">> => money(Cents),
           <<"category">> => Category, cents => Cents},
    transactions(Rows, RowNo + 1, Width, Index, [Tx | Acc]).

totals(Txs) ->
    Expenses = lists:sum([C || #{cents := C} <- Txs, C > 0]),
    Income = -lists:sum([C || #{cents := C} <- Txs, C < 0]),
    Grouped = lists:foldl(
                fun(#{cents := C, <<"category">> := Cat}, {Order, Sums}) when C > 0 ->
                        case Sums of
                            #{Cat := S} -> {Order, Sums#{Cat := S + C}};
                            _ -> {[Cat | Order], Sums#{Cat => C}}
                        end;
                   (_, Acc) -> Acc
                end, {[], #{}}, Txs),
    {Order, Sums} = Grouped,
    %% lists:sort/2 is stable, like V8's Array.prototype.sort.
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end,
                        [{Cat, maps:get(Cat, Sums)} || Cat <- lists:reverse(Order)]),
    Dates = [D || #{<<"date">> := D} <- Txs],
    #{<<"income">> => money(Income),
      <<"spending">> => money(Expenses),
      <<"saved">> => money(Income - Expenses),
      <<"count">> => length(Txs),
      <<"categories">> => [#{<<"name">> => Cat, <<"amount">> => money(C)}
                           || {Cat, C} <- Sorted],
      <<"transactions">> => [maps:remove(cents, T) || T <- Txs],
      <<"period">> => #{<<"from">> => lists:min(Dates), <<"to">> => lists:max(Dates)},
      <<"amountConvention">> => ?CONVENTION}.

%% `cents / 100` as JS computes it (both operands are exact doubles).
money(Cents) when Cents rem 100 =:= 0 -> Cents div 100;
money(Cents) -> Cents / 100.

-spec fail(binary()) -> no_return().
fail(Msg) -> throw({finance, Msg}).

index_of(N, [N | _], I) -> I;
index_of(N, [_ | T], I) -> index_of(N, T, I + 1).

%% CSV parser (the char loop in finance.ts). Returns the kept rows in order.

parse(<<$", $", Rest/binary>>, Cell, Row, Rows, true) ->
    parse(Rest, <<Cell/binary, $">>, Row, Rows, true);
parse(<<$", Rest/binary>>, Cell, Row, Rows, true) ->
    case Rest of
        <<>> -> ok;
        <<$,, _/binary>> -> ok;
        <<$\n, _/binary>> -> ok;
        <<$\r>> -> ok;
        <<$\r, $\n, _/binary>> -> ok;
        _ -> fail(<<"Invalid quoted CSV field">>)
    end,
    parse(Rest, Cell, Row, Rows, false);
parse(<<$", _/binary>>, Cell, _Row, _Rows, false) when Cell =/= <<>> ->
    fail(<<"Invalid quoted CSV field">>);
parse(<<$", Rest/binary>>, Cell, Row, Rows, false) ->
    parse(Rest, Cell, Row, Rows, true);
parse(<<$,, Rest/binary>>, Cell, Row, Rows, false) ->
    parse(Rest, <<>>, [strip_cr(Cell) | Row], Rows, false);
parse(<<$\n, Rest/binary>>, Cell, Row, Rows, false) ->
    parse(Rest, <<>>, [], keep_row([strip_cr(Cell) | Row], Rows), false);
parse(<<>>, _Cell, _Row, _Rows, true) ->
    fail(<<"CSV has an unclosed quoted field">>);
parse(<<>>, Cell, Row, Rows, false) ->
    lists:reverse(keep_row([strip_cr(Cell) | Row], Rows));
parse(<<C, Rest/binary>>, Cell, Row, Rows, Quoted) ->
    parse(Rest, <<Cell/binary, C>>, Row, Rows, Quoted).

keep_row(RevRow, Rows) ->
    case lists:any(fun(V) -> trim(V) =/= <<>> end, RevRow) of
        true -> [lists:reverse(RevRow) | Rows];
        false -> Rows
    end.

strip_cr(Cell) ->
    case byte_size(Cell) of
        0 -> Cell;
        N ->
            case binary:last(Cell) of
                $\r -> binary:part(Cell, 0, N - 1);
                _ -> Cell
            end
    end.

%% Field validation

%% zod v4 `z.iso.date()`: `YYYY-MM-DD` naming a real date (year 0000 allowed).
is_iso_date(<<Y:4/binary, $-, M:2/binary, $-, D:2/binary>>) ->
    lists:all(fun is_digits/1, [Y, M, D]) andalso
        calendar:valid_date(binary_to_integer(Y), binary_to_integer(M),
                            binary_to_integer(D));
is_iso_date(_) ->
    false.

%% `^[-+]?\d+(?:\.\d{1,2})?$`, then `Math.round(Number(amount) * 100)` with the
%% range check. Returns `invalid` when the pattern does not match.
cents(Amount) ->
    {Neg, Body} = case Amount of
                      <<$-, R/binary>> -> {true, R};
                      <<$+, R/binary>> -> {false, R};
                      _ -> {false, Amount}
                  end,
    {Int, Frac} = case binary:split(Body, <<".">>) of
                      [I] -> {I, <<"0">>};
                      [I, F] -> {I, F}
                  end,
    case Int =/= <<>> andalso is_digits(Int) andalso is_digits(Frac)
        andalso byte_size(Frac) >= 1 andalso byte_size(Frac) =< 2 of
        false -> invalid;
        true -> round_cents(Neg, Int, Frac)
    end.

round_cents(Neg, Int, Frac) ->
    Significant = string:trim(Int, leading, "0"),
    %% 14+ integer digits is >= 1e13, i.e. >= 1e15 cents: out of range in JS
    %% too (and keeps binary_to_float away from megabyte-long literals).
    byte_size(Significant) > 13 andalso fail(<<"Transaction amount is out of range">>),
    Abs = binary_to_float(<<Int/binary, ".", Frac/binary>>),
    X = case Neg of
            true -> -Abs * 100;
            false -> Abs * 100
        end,
    Cents = js_round(X),
    abs(Cents) > ?MAX_CENTS andalso fail(<<"Transaction amount is out of range">>),
    Cents.

%% `Math.round`: nearest integer, ties toward +Infinity.
js_round(X) ->
    F = math:floor(X),
    case X - F >= 0.5 of
        true -> trunc(F) + 1;
        false -> trunc(F)
    end.

is_digits(<<>>) -> true;
is_digits(<<C, R/binary>>) when C >= $0, C =< $9 -> is_digits(R);
is_digits(_) -> false.

%% Strings

%% `String.prototype.length`: UTF-16 code units of the UTF-8 binary.
utf16_units(Bin) when byte_size(Bin) =< ?MAX_UNITS ->
    byte_size(Bin);
utf16_units(Bin) ->
    units(Bin, 0).

units(<<B, R/binary>>, N) when B < 16#80; B >= 16#C0, B < 16#F0 -> units(R, N + 1);
units(<<B, R/binary>>, N) when B >= 16#F0 -> units(R, N + 2);
units(<<_, R/binary>>, N) -> units(R, N);
units(<<>>, N) -> N.

%% `String.prototype.trim`.
trim(Bin) ->
    Lead = skip_ws(Bin),
    binary:part(Lead, 0, last_non_ws(Lead, 0, 0)).

skip_ws(<<C/utf8, R/binary>> = Bin) ->
    case is_ws(C) of
        true -> skip_ws(R);
        false -> Bin
    end;
skip_ws(Bin) ->
    Bin.

%% Byte length up to the end of the last non-whitespace code point.
last_non_ws(Bin, Pos, End) ->
    case Bin of
        <<_:Pos/binary, C/utf8, _/binary>> ->
            Next = Pos + byte_size(<<C/utf8>>),
            last_non_ws(Bin, Next, case is_ws(C) of true -> End; false -> Next end);
        <<_:Pos/binary, _, _/binary>> ->
            last_non_ws(Bin, Pos + 1, Pos + 1);
        _ ->
            End
    end.

%% ECMAScript WhiteSpace and LineTerminator code points.
is_ws(C) when C =:= 9; C =:= 10; C =:= 11; C =:= 12; C =:= 13; C =:= 32;
              C =:= 16#A0; C =:= 16#1680; C =:= 16#2028; C =:= 16#2029;
              C =:= 16#202F; C =:= 16#205F; C =:= 16#3000; C =:= 16#FEFF ->
    true;
is_ws(C) when C >= 16#2000, C =< 16#200A ->
    true;
is_ws(_) ->
    false.

%% Numbers

decompose(X) ->
    <<_:1, Exp:11, Frac:52>> = <<X/float>>,
    case Exp of
        0 -> {Frac, -1074};
        _ -> {Frac bor (1 bsl 52), Exp - 1075}
    end.

pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).

pad_zeros(S, Len) when byte_size(S) >= Len -> S;
pad_zeros(S, Len) -> pad_zeros(<<$0, S/binary>>, Len).
