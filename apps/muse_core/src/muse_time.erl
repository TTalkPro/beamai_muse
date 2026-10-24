%% @doc Wall-clock helpers with JavaScript `Date` semantics.
%%
%% OpenMuse stores every timestamp as `Date.prototype.toISOString()` output
%% (`2026-10-21T09:00:00.000Z`) and compares them with `Date.parse`, where an
%% unparseable value is NaN and never "due". `parse/1` returns `nan` for that.
%%
%% Tests shift the clock with `set_offset/1` instead of mocking callers.
-module(muse_time).

-export([now_ms/0, now_iso/0,
         to_iso/1, parse/1, is_due/2,
         add_ms/2,
         set_offset/1, offset/0]).

-define(OFFSET_KEY, {?MODULE, offset}).

-spec now_ms() -> integer().
now_ms() ->
    erlang:system_time(millisecond) + offset().

-spec now_iso() -> binary().
now_iso() ->
    to_iso(now_ms()).

-spec to_iso(integer()) -> binary().
to_iso(Ms) when is_integer(Ms) ->
    list_to_binary(calendar:system_time_to_rfc3339(Ms, [{unit, millisecond},
                                                       {offset, "Z"}])).

%% @doc `Date.parse` for the ISO-8601 forms OpenMuse writes and accepts:
%% `YYYY-MM-DD`, and `YYYY-MM-DDTHH:MM[:SS[.fff]]` with `Z` or `±HH:MM`.
%% A date-time without an offset is read as UTC (JS would use local time;
%% the server always writes UTC, so this only matters for hand-made input).
-spec parse(term()) -> integer() | nan.
parse(Bin) when is_binary(Bin) ->
    try parse_iso(Bin) of
        Ms -> Ms
    catch
        _:_ -> nan
    end;
parse(_) ->
    nan.

%% @doc True when `Iso` parses and is at or before `NowMs`.
-spec is_due(term(), integer()) -> boolean().
is_due(Iso, NowMs) ->
    case parse(Iso) of
        nan -> false;
        Ms -> Ms =< NowMs
    end.

-spec add_ms(binary(), integer()) -> binary().
add_ms(Iso, Delta) ->
    case parse(Iso) of
        nan -> error({badarg, Iso});
        Ms -> to_iso(Ms + Delta)
    end.

-spec set_offset(integer()) -> ok.
set_offset(0) ->
    _ = persistent_term:erase(?OFFSET_KEY),
    ok;
set_offset(Ms) when is_integer(Ms) ->
    persistent_term:put(?OFFSET_KEY, Ms).

-spec offset() -> integer().
offset() ->
    persistent_term:get(?OFFSET_KEY, 0).

%% Internal

parse_iso(<<Y:4/binary, "-", Mo:2/binary, "-", D:2/binary>>) ->
    date_ms(int(Y), int(Mo), int(D), 0, 0, 0, 0, 0);
parse_iso(<<Y:4/binary, "-", Mo:2/binary, "-", D:2/binary, "T",
            H:2/binary, ":", Mi:2/binary, Rest/binary>>) ->
    {S, Frac, Rest1} = seconds(Rest),
    Offset = zone(Rest1),
    date_ms(int(Y), int(Mo), int(D), int(H), int(Mi), S, Frac, Offset).

seconds(<<":", S:2/binary, ".", Rest/binary>>) ->
    {Digits, Rest1} = digits(Rest, <<>>),
    true = byte_size(Digits) > 0,
    Ms = int(binary:part(<<Digits/binary, "00">>, 0, 3)),
    {int(S), Ms, Rest1};
seconds(<<":", S:2/binary, Rest/binary>>) ->
    {int(S), 0, Rest};
seconds(Rest) ->
    {0, 0, Rest}.

digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    digits(Rest, <<Acc/binary, C>>);
digits(Rest, Acc) ->
    {Acc, Rest}.

zone(<<>>) -> 0;
zone(<<"Z">>) -> 0;
zone(<<Sign, H:2/binary, ":", M:2/binary>>) when Sign =:= $+; Sign =:= $- ->
    Minutes = int(H) * 60 + int(M),
    true = int(H) =< 23 andalso int(M) =< 59,
    case Sign of
        $+ -> Minutes;
        $- -> -Minutes
    end.

date_ms(Y, Mo, D, H, Mi, S, Frac, OffsetMin) ->
    true = calendar:valid_date(Y, Mo, D),
    true = H =< 23 andalso Mi =< 59 andalso S =< 59,
    Secs = calendar:datetime_to_gregorian_seconds({{Y, Mo, D}, {H, Mi, S}})
           - 62167219200,
    (Secs - OffsetMin * 60) * 1000 + Frac.

int(Bin) ->
    true = is_digits(Bin),
    binary_to_integer(Bin).

is_digits(<<>>) -> false;
is_digits(Bin) -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)).
