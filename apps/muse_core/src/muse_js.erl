%% @doc Small JavaScript string/number semantics the OpenMuse port relies on.
%%
%% JS strings count UTF-16 code units, so `text.slice(0, N)` and length
%% limits differ from code points for characters outside the BMP. A pair
%% that would be cut in half is dropped (JS would keep a lone surrogate,
%% which cannot be represented in UTF-8).
-module(muse_js).

-export([slice/2, number/1, collapse_ws/1]).

%% @doc `text.slice(0, N)`.
-spec slice(binary(), non_neg_integer()) -> binary().
slice(Bin, N) ->
    case muse_validate:utf16_length(Bin) =< N of
        true -> Bin;
        false -> take(unicode:characters_to_list(Bin), N, [])
    end.

take([], _, Acc) -> unicode:characters_to_binary(lists:reverse(Acc));
take(_, 0, Acc) -> unicode:characters_to_binary(lists:reverse(Acc));
take([C | _], 1, Acc) when C > 16#FFFF -> unicode:characters_to_binary(lists:reverse(Acc));
take([C | Rest], N, Acc) when C > 16#FFFF -> take(Rest, N - 2, [C | Acc]);
take([C | Rest], N, Acc) -> take(Rest, N - 1, [C | Acc]).

%% @doc `Number(text)` for decimal literals (with optional exponent);
%% `nan` for anything else. Empty/blank text is 0, like JS.
-spec number(binary()) -> number() | nan.
number(Text) ->
    T = string:trim(Text),
    case T of
        <<>> -> 0;
        _ ->
            case re:run(T, <<"^([+-]?)(\\d*)(?:\\.(\\d*))?(?:[eE]([+-]?\\d+))?$">>,
                        [{capture, all_but_first, binary}]) of
                {match, Groups} ->
                    [Sign, Int, Frac, Exp] = Groups ++ lists:duplicate(4 - length(Groups), <<>>),
                    case Int =:= <<>> andalso Frac =:= <<>> of
                        true -> nan;
                        false ->
                            Lit = <<(z(Int))/binary, ".", (z(Frac))/binary, "e", (z(Exp))/binary>>,
                            V = binary_to_float(Lit),
                            case Sign of <<"-">> -> -V; _ -> V end
                    end;
                nomatch ->
                    nan
            end
    end.

z(<<>>) -> <<"0">>;
z(B) -> B.

%% @doc `text.replace(/\s+/g, " ").trim()`.
-spec collapse_ws(binary()) -> binary().
collapse_ws(Text) ->
    string:trim(re:replace(Text, <<"\\s+">>, <<" ">>, [global, unicode, ucp, {return, binary}])).
