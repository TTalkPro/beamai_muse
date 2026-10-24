%% @doc IANA time zones from the system tz database (`/usr/share/zoneinfo`).
%%
%% OpenMuse leans on `Intl` for calendar work: validating `timeZone` values,
%% `localDateTime(instant, zone)`, and the server's own zone for sample data.
%% Erlang has no tz library, so this module reads TZif files (RFC 8536, the
%% 64-bit v2+ body) and evaluates the POSIX TZ footer for instants after the
%% last transition (modern "slim" zone files rely on it).
%%
%% Parsed zones are cached in persistent_term.
-module(muse_tz).

-export([valid/1, offset/2, local/2, local_date_time/2, system_zone/0]).

-ifdef(TEST).
-export([parse/1]).
-endif.

-define(ZONEINFO, "/usr/share/zoneinfo").

-type zone() :: binary().

%% @doc True when `Zone` names a zone in the tz database (`UTC` included).
-spec valid(term()) -> boolean().
valid(Zone) when is_binary(Zone) ->
    load(Zone) =/= error;
valid(_) ->
    false.

%% @doc UTC offset in seconds of `Zone` at `UtcMs`.
-spec offset(zone(), integer()) -> integer().
offset(Zone, UtcMs) ->
    case load(Zone) of
        error -> error({unknown_time_zone, Zone});
        Tz -> offset_at(Tz, floor_div(UtcMs, 1000))
    end.

%% @doc Civil date-time of `UtcMs` in `Zone`.
-spec local(zone(), integer()) -> calendar:datetime().
local(Zone, UtcMs) ->
    Secs = floor_div(UtcMs, 1000) + offset(Zone, UtcMs),
    calendar:gregorian_seconds_to_datetime(Secs + 62167219200).

%% @doc OpenMuse `localDateTime(value, timeZone)`: `{Date, Time}` binaries
%% (`YYYY-MM-DD`, `HH:MM`). An unparseable value falls back to slicing the
%% string, as the original does.
-spec local_date_time(binary(), zone()) -> {binary(), binary()}.
local_date_time(Value, Zone) ->
    case muse_time:parse(Value) of
        nan ->
            {slice(Value, 0, 10), slice(Value, 11, 5)};
        Ms ->
            {{Y, Mo, D}, {H, Mi, _}} = local(Zone, Ms),
            {iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, Mo, D])),
             iolist_to_binary(io_lib:format("~2..0B:~2..0B", [H, Mi]))}
    end.

%% @doc The server's zone name (`Intl.DateTimeFormat().resolvedOptions().timeZone`):
%% `TZ` if it names a zone, else the `/etc/localtime` link target, else `UTC`.
-spec system_zone() -> zone().
system_zone() ->
    FromEnv = case os:getenv("TZ") of
                  false -> undefined;
                  ":" ++ EnvName -> list_to_binary(EnvName);
                  EnvName -> list_to_binary(EnvName)
              end,
    case FromEnv =/= undefined andalso valid(FromEnv) of
        true -> FromEnv;
        false ->
            case file:read_link_all("/etc/localtime") of
                {ok, Target} ->
                    case string:split(Target, "zoneinfo/", trailing) of
                        [_, LinkName] -> list_to_binary(LinkName);
                        _ -> <<"UTC">>
                    end;
                _ ->
                    <<"UTC">>
            end
    end.

%% Loading

load(Zone) ->
    case persistent_term:get({?MODULE, Zone}, undefined) of
        undefined ->
            Tz = read_zone(Zone),
            persistent_term:put({?MODULE, Zone}, Tz),
            Tz;
        Tz ->
            Tz
    end.

read_zone(Zone) ->
    case safe_name(Zone) of
        false ->
            error;
        true ->
            case file:read_file(filename:join(?ZONEINFO, binary_to_list(Zone))) of
                {ok, Bin} ->
                    try parse(Bin) catch _:_ -> error end;
                {error, _} ->
                    error
            end
    end.

safe_name(Zone) ->
    re:run(Zone, <<"^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$">>, [{capture, none}]) =:= match
        andalso binary:match(Zone, <<"..">>) =:= nomatch.

%% TZif: skip the v1 (32-bit) block, parse the v2+ 64-bit block and footer.
parse(<<"TZif", Version, _:15/binary, Rest/binary>>) when Version >= $2 ->
    {V1Len, _} = block_len(Rest, 4),
    <<_:V1Len/binary, "TZif", _, _:15/binary, Rest2/binary>> = Rest,
    {Len2, Counts} = block_len(Rest2, 8),
    <<Block:Len2/binary, Footer/binary>> = Rest2,
    {Transitions, Types} = parse_block(Block, Counts),
    [<<>>, Posix | _] = binary:split(Footer, <<"\n">>, [global]),
    #{transitions => Transitions, types => Types, posix => parse_posix(Posix)}.

block_len(<<IsUt:32, IsStd:32, Leap:32, TimeCnt:32, TypeCnt:32, CharCnt:32, _/binary>>, TimeSize) ->
    Len = 24 + TimeCnt * TimeSize + TimeCnt + TypeCnt * 6 + CharCnt
          + Leap * (TimeSize + 4) + IsStd + IsUt,
    {Len, {TimeCnt, TypeCnt}}.

parse_block(<<_:24/binary, Rest/binary>>, {TimeCnt, TypeCnt}) ->
    TLen = TimeCnt * 8,
    <<Times:TLen/binary, Idx:TimeCnt/binary, Rest1/binary>> = Rest,
    TypesLen = TypeCnt * 6,
    <<TypeBin:TypesLen/binary, _/binary>> = Rest1,
    Types = list_to_tuple([Off || <<Off:32/signed, _Dst, _Abbr>> <= TypeBin]),
    Transitions = lists:zip([T || <<T:64/signed>> <= Times], [I || <<I>> <= Idx]),
    {Transitions, Types}.

offset_at(#{transitions := [], types := Types, posix := undefined}, _) ->
    element(1, Types);
offset_at(#{transitions := [], posix := Posix}, Secs) ->
    posix_offset(Posix, Secs);
offset_at(#{transitions := Trans, types := Types, posix := Posix}, Secs) ->
    case lists:last(Trans) of
        {Last, _} when Secs >= Last, Posix =/= undefined ->
            posix_offset(Posix, Secs);
        _ ->
            %% Before the first transition RFC 8536 uses local time type 0.
            case [I || {T, I} <- Trans, T =< Secs] of
                [] -> element(1, Types);
                Before -> element(lists:last(Before) + 1, Types)
            end
    end.

%% POSIX TZ strings, e.g. `PST8PDT,M3.2.0,M11.1.0`, `CST-8`, `<+0330>-3:30`.
%% Offsets in the string are west-positive; we return east-positive seconds.

parse_posix(<<>>) ->
    undefined;
parse_posix(S) ->
    {_StdName, R1} = posix_name(S),
    {StdOff, R2} = posix_offset_str(R1),
    case R2 of
        <<>> ->
            #{std => -StdOff};
        _ ->
            {_DstName, R3} = posix_name(R2),
            {DstOff, R4} = case R3 of
                               <<",", _/binary>> -> {StdOff - 3600, R3};
                               _ -> posix_offset_str(R3)
                           end,
            <<",", Rules/binary>> = R4,
            [StartRule, EndRule] = binary:split(Rules, <<",">>),
            #{std => -StdOff, dst => -DstOff,
              start => posix_rule(StartRule), 'end' => posix_rule(EndRule)}
    end.

posix_name(<<"<", Rest/binary>>) ->
    [Name, R] = binary:split(Rest, <<">">>),
    {Name, R};
posix_name(S) ->
    {match, [{0, Len}]} = re:run(S, <<"^[A-Za-z]+">>, [{capture, first}]),
    {binary:part(S, 0, Len), binary:part(S, Len, byte_size(S) - Len)}.

%% `[+-]hh[:mm[:ss]]` -> seconds; returns the rest of the string.
posix_offset_str(S) ->
    %% Trailing unmatched optional groups are left out of the capture list.
    {match, Groups} = re:run(S, <<"^([+-]?)(\\d{1,3})(?::(\\d{2}))?(?::(\\d{2}))?">>,
                             [{capture, all, binary}]),
    [Whole, Sign, H, M, Sec] = Groups ++ lists:duplicate(5 - length(Groups), <<>>),
    Val = binary_to_integer(H) * 3600 + int0(M) * 60 + int0(Sec),
    Signed = case Sign of <<"-">> -> -Val; _ -> Val end,
    {Signed, binary:part(S, byte_size(Whole), byte_size(S) - byte_size(Whole))}.

int0(<<>>) -> 0;
int0(B) -> binary_to_integer(B).

%% Rule: `Mm.w.d[/time]`, `Jn[/time]` or `n[/time]`; time may be negative or >24h.
posix_rule(Rule) ->
    {Date, Time} = case binary:split(Rule, <<"/">>) of
                       [D, T] -> {D, element(1, posix_offset_str(T))};
                       [D] -> {D, 7200}
                   end,
    Spec = case Date of
               <<"M", MWD/binary>> ->
                   [M, W, Dw] = [binary_to_integer(X) || X <- binary:split(MWD, <<".">>, [global])],
                   {mwd, M, W, Dw};
               <<"J", N/binary>> -> {julian1, binary_to_integer(N)};
               N -> {julian0, binary_to_integer(N)}
           end,
    {Spec, Time}.

posix_offset(#{std := Std} = P, _Secs) when not is_map_key(dst, P) ->
    Std;
posix_offset(#{std := Std, dst := Dst, start := Start, 'end' := End}, Secs) ->
    {{Year, _, _}, _} = calendar:gregorian_seconds_to_datetime(Secs + Std + 62167219200),
    %% Transition instants in UTC: start is given in standard local time,
    %% end in daylight local time.
    StartUtc = rule_local_secs(Start, Year) - Std,
    EndUtc = rule_local_secs(End, Year) - Dst,
    InDst = case StartUtc < EndUtc of
                true -> Secs >= StartUtc andalso Secs < EndUtc;
                false -> not (Secs >= EndUtc andalso Secs < StartUtc)   % southern hemisphere
            end,
    case InDst of
        true -> Dst;
        false -> Std
    end.

rule_local_secs({Spec, Time}, Year) ->
    Day = rule_day(Spec, Year),
    calendar:datetime_to_gregorian_seconds({Day, {0, 0, 0}}) - 62167219200 + Time.

rule_day({mwd, M, W, Dw}, Year) ->
    First = calendar:day_of_the_week(Year, M, 1) rem 7,          % 0 = Sunday
    FirstMatch = 1 + ((Dw - First + 7) rem 7),
    Last = calendar:last_day_of_the_month(Year, M),
    D0 = FirstMatch + (W - 1) * 7,
    D = case D0 > Last of true -> D0 - 7; false -> D0 end,
    {Year, M, D};
rule_day({julian1, N}, Year) ->
    %% 1..365, February 29 never counted.
    Base = calendar:date_to_gregorian_days(Year, 1, 1) + N - 1,
    Adj = case calendar:is_leap_year(Year) andalso N >= 60 of true -> 1; false -> 0 end,
    calendar:gregorian_days_to_date(Base + Adj);
rule_day({julian0, N}, Year) ->
    calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Year, 1, 1) + N).

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

slice(Bin, Start, _Len) when byte_size(Bin) =< Start -> <<>>;
slice(Bin, Start, Len) -> binary:part(Bin, Start, min(Len, byte_size(Bin) - Start)).
