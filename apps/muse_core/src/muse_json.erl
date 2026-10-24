%% @doc JSON encoding that matches JavaScript `JSON.stringify` byte for byte.
%%
%% OpenMuse derives ids and review hashes from `sha256hex(JSON.stringify(x))`,
%% so key order, string escaping and number formatting must all agree with V8:
%%
%% - `{obj, [{Key, Value}]}` keeps insertion order. Plain maps are emitted in
%%   Erlang term order of their keys, which is deterministic but is not JS
%%   insertion order; use `obj` wherever the TS code hashes an object literal.
%% - `undefined` members are dropped from objects (and become `null` inside
%%   arrays), like JS.
%% - Strings: only `"`, `\`, and control characters below 0x20 are escaped;
%%   `\b \f \n \r \t` use short forms, the rest `\u00xx` (lowercase hex).
%% - Numbers follow `Number.prototype.toString` (`1.0` -> `1`, `1e21` -> `1e+21`).
-module(muse_json).

-export([encode/1, decode/1, decode_object/1, number/1]).

-export_type([json/0]).

-type json() :: null | boolean() | number() | binary()
              | [json()] | #{binary() | atom() => json()}
              | {obj, [{binary() | atom(), json() | undefined}]}.

-spec encode(json()) -> binary().
encode(Term) ->
    iolist_to_binary(enc(Term)).

%% @doc Decode JSON text. Objects become binary-keyed maps, `null` the atom.
-spec decode(iodata()) -> {ok, json()} | {error, invalid_json}.
decode(Data) ->
    try json:decode(iolist_to_binary(Data)) of
        Term -> {ok, Term}
    catch
        error:_ -> {error, invalid_json}
    end.

%% @doc Decode and require a JSON object (the shape every request body has).
-spec decode_object(iodata()) -> {ok, map()} | {error, invalid_json | not_object}.
decode_object(Data) ->
    case decode(Data) of
        {ok, Map} when is_map(Map) -> {ok, Map};
        {ok, _} -> {error, not_object};
        Error -> Error
    end.

%% @doc `Number.prototype.toString` for finite numbers.
-spec number(number()) -> binary().
number(I) when is_integer(I) ->
    integer_to_binary(I);
number(F) when is_float(F) ->
    js_float(F).

%% Encoder

enc(null) -> <<"null">>;
enc(true) -> <<"true">>;
enc(false) -> <<"false">>;
enc(undefined) -> <<"null">>;
enc(N) when is_number(N) -> number(N);
enc(B) when is_binary(B) -> string(B);
enc(A) when is_atom(A) -> string(atom_to_binary(A, utf8));
enc({obj, Pairs}) when is_list(Pairs) -> object(Pairs);
enc(M) when is_map(M) -> object(lists:sort(maps:to_list(M)));
enc(L) when is_list(L) -> [$[, join([enc(V) || V <- L]), $]].

object(Pairs) ->
    Members = [[string(key(K)), $:, enc(V)] || {K, V} <- Pairs, V =/= undefined],
    [${, join(Members), $}].

key(K) when is_binary(K) -> K;
key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_integer(K) -> integer_to_binary(K).

join([]) -> [];
join([H | T]) -> [H | [[$,, X] || X <- T]].

string(B) ->
    [$", escape(B, B, 0, 0, []), $"].

%% Copy unescaped runs as sub-binaries; only touch bytes that need escaping.
escape(<<>>, Orig, Start, Len, Acc) ->
    lists:reverse([binary:part(Orig, Start, Len) | Acc]);
escape(<<C, Rest/binary>>, Orig, Start, Len, Acc)
  when C < 16#20; C =:= $"; C =:= $\\ ->
    Run = binary:part(Orig, Start, Len),
    escape(Rest, Orig, Start + Len + 1, 0, [esc(C), Run | Acc]);
escape(<<_, Rest/binary>>, Orig, Start, Len, Acc) ->
    escape(Rest, Orig, Start, Len + 1, Acc).

esc($") -> <<"\\\"">>;
esc($\\) -> <<"\\\\">>;
esc($\b) -> <<"\\b">>;
esc($\f) -> <<"\\f">>;
esc($\n) -> <<"\\n">>;
esc($\r) -> <<"\\r">>;
esc($\t) -> <<"\\t">>;
esc(C) -> iolist_to_binary(io_lib:format("\\u~4.16.0b", [C])).

%% Number::toString (ECMA-262 6.1.6.1.20) on the shortest round-trip digits.
js_float(F) when F == 0.0 -> <<"0">>;
js_float(F) when F < 0 -> <<"-", (js_float(-F))/binary>>;
js_float(F) ->
    {Digits, N} = shortest_digits(F),
    K = byte_size(Digits),
    if
        K =< N, N =< 21 ->
            <<Digits/binary, (zeros(N - K))/binary>>;
        0 < N, N =< 21 ->
            <<(binary:part(Digits, 0, N))/binary, ".",
              (binary:part(Digits, N, K - N))/binary>>;
        -6 < N, N =< 0 ->
            <<"0.", (zeros(-N))/binary, Digits/binary>>;
        true ->
            Exp = N - 1,
            Sign = case Exp >= 0 of true -> <<"+">>; false -> <<"-">> end,
            Mant = case K of
                       1 -> Digits;
                       _ -> <<(binary:part(Digits, 0, 1))/binary, ".",
                              (binary:part(Digits, 1, K - 1))/binary>>
                   end,
            <<Mant/binary, "e", Sign/binary, (integer_to_binary(abs(Exp)))/binary>>
    end.

%% Returns {Digits, N} with value = 0.Digits * 10^N, Digits without
%% leading/trailing zeros.
shortest_digits(F) ->
    Short = float_to_binary(F, [short]),
    {Mantissa, Exp} = case binary:split(Short, <<"e">>) of
                          [M, E] -> {M, binary_to_integer(E)};
                          [M] -> {M, 0}
                      end,
    {IntPart, FracPart} = case binary:split(Mantissa, <<".">>) of
                              [I, Fr] -> {I, Fr};
                              [I] -> {I, <<>>}
                          end,
    All = <<IntPart/binary, FracPart/binary>>,
    Lead = count_leading_zeros(All),
    Trimmed0 = binary:part(All, Lead, byte_size(All) - Lead),
    Trimmed = strip_trailing_zeros(Trimmed0),
    N = byte_size(IntPart) - Lead + Exp,
    {Trimmed, N}.

count_leading_zeros(<<$0, Rest/binary>>) -> 1 + count_leading_zeros(Rest);
count_leading_zeros(_) -> 0.

strip_trailing_zeros(<<>>) -> <<>>;
strip_trailing_zeros(B) ->
    case binary:last(B) of
        $0 -> strip_trailing_zeros(binary:part(B, 0, byte_size(B) - 1));
        _ -> B
    end.

zeros(N) -> binary:copy(<<"0">>, N).
