%% @doc Text helpers behind Gmail message parsing
%% (designs/ref/openmuse-integrations-spec.md §9.7, google.ts helpers).
%%
%% - `decode/2`: `TextDecoder` for the WHATWG labels of UTF-8,
%%   windows-1252 (which WHATWG also uses for latin1 and us-ascii) and
%%   UTF-16LE/BE, with U+FFFD for invalid input and BOM stripping. Other
%%   labels are reported as unsupported.
%% - `decode_header/1` (RFC 2047), `addresses/1`, `decode_snippet/1`.
%% - `html_to_text/1`: the original parses with parse5 and walks the tree.
%%   This is a small HTML tokenizer plus an open-element stack with the
%%   implied end tags that matter for text layout (`p`, `li`, `dd`/`dt`,
%%   table cells and rows, headings). Raw-text and RCDATA elements, comments
%%   and the HTML5 legacy entities are handled; the full named-entity table
%%   and the adoption agency are not.
-module(muse_mail_text).

-export([decode/2, decoder/1, utf8_lossy/1, decode_header/1, addresses/1,
         decode_snippet/1, html_to_text/1, well_formed/1]).

-define(BLOCKS, [<<"address">>, <<"article">>, <<"aside">>, <<"blockquote">>, <<"div">>,
                 <<"footer">>, <<"form">>, <<"h1">>, <<"h2">>, <<"h3">>, <<"h4">>, <<"h5">>,
                 <<"h6">>, <<"header">>, <<"hr">>, <<"li">>, <<"main">>, <<"ol">>, <<"p">>,
                 <<"pre">>, <<"section">>, <<"table">>, <<"tr">>, <<"ul">>]).
-define(EXCLUDED, [<<"script">>, <<"style">>, <<"head">>, <<"template">>, <<"noscript">>,
                   <<"iframe">>, <<"object">>, <<"svg">>, <<"math">>]).
-define(VOID, [<<"area">>, <<"base">>, <<"basefont">>, <<"bgsound">>, <<"br">>, <<"col">>,
               <<"embed">>, <<"hr">>, <<"img">>, <<"image">>, <<"input">>, <<"keygen">>,
               <<"link">>, <<"meta">>, <<"param">>, <<"source">>, <<"track">>, <<"wbr">>]).
-define(RAWTEXT, [<<"script">>, <<"style">>, <<"xmp">>, <<"iframe">>, <<"noembed">>,
                  <<"noframes">>, <<"noscript">>]).
-define(RCDATA, [<<"title">>, <<"textarea">>]).
%% Start tags that close an open <p>.
-define(CLOSES_P, [<<"address">>, <<"article">>, <<"aside">>, <<"blockquote">>, <<"center">>,
                   <<"details">>, <<"dialog">>, <<"dir">>, <<"div">>, <<"dl">>, <<"fieldset">>,
                   <<"figcaption">>, <<"figure">>, <<"footer">>, <<"form">>, <<"h1">>, <<"h2">>,
                   <<"h3">>, <<"h4">>, <<"h5">>, <<"h6">>, <<"header">>, <<"hgroup">>, <<"hr">>,
                   <<"li">>, <<"dd">>, <<"dt">>, <<"listing">>, <<"main">>, <<"menu">>,
                   <<"nav">>, <<"ol">>, <<"p">>, <<"plaintext">>, <<"pre">>, <<"search">>,
                   <<"section">>, <<"summary">>, <<"table">>, <<"ul">>, <<"xmp">>]).
-define(HEADINGS, [<<"h1">>, <<"h2">>, <<"h3">>, <<"h4">>, <<"h5">>, <<"h6">>]).

-define(IS_ALPHA(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z))).

-type encoding() :: utf8 | windows1252 | utf16le | utf16be.

%% @doc `TextDecoder(label).decode(bytes)`, UTF-8 when the label is not
%% supported (google.ts `decoderFor`).
-spec decode(binary(), binary()) -> binary().
decode(Label, Bytes) ->
    case decoder(Label) of
        {ok, Enc} -> decode_with(Enc, Bytes);
        unsupported -> decode_with(utf8, Bytes)
    end.

%% @doc Resolve a charset label.
-spec decoder(binary()) -> {ok, encoding()} | unsupported.
decoder(Label) ->
    L = string:lowercase(string:trim(Label, both, "\t\n\f\r ")),
    case lists:member(L, [<<"unicode-1-1-utf-8">>, <<"unicode11utf8">>, <<"unicode20utf8">>,
                          <<"utf-8">>, <<"utf8">>, <<"x-unicode20utf8">>]) of
        true -> {ok, utf8};
        false ->
            case lists:member(L, [<<"ansi_x3.4-1968">>, <<"ascii">>, <<"cp1252">>, <<"cp819">>,
                                  <<"csisolatin1">>, <<"ibm819">>, <<"iso-8859-1">>,
                                  <<"iso-ir-100">>, <<"iso8859-1">>, <<"iso88591">>,
                                  <<"iso_8859-1">>, <<"iso_8859-1:1987">>, <<"l1">>,
                                  <<"latin1">>, <<"us-ascii">>, <<"windows-1252">>,
                                  <<"x-cp1252">>]) of
                true -> {ok, windows1252};
                false ->
                    case L of
                        _ when L =:= <<"utf-16be">>; L =:= <<"unicodefffe">> -> {ok, utf16be};
                        _ ->
                            case lists:member(L, [<<"csunicode">>, <<"iso-10646-ucs-2">>,
                                                  <<"ucs-2">>, <<"unicode">>,
                                                  <<"unicodefeff">>, <<"utf-16">>,
                                                  <<"utf-16le">>]) of
                                true -> {ok, utf16le};
                                false -> unsupported
                            end
                    end
            end
    end.

%% @doc WHATWG UTF-8 decode: invalid sequences become U+FFFD.
-spec utf8_lossy(binary()) -> binary().
utf8_lossy(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Valid when is_binary(Valid) -> Valid;
        _ -> utf8_slow(Bin, <<>>)
    end.

%% @doc `String.prototype.toWellFormed` for text that came in as bytes.
-spec well_formed(binary()) -> binary().
well_formed(Bin) ->
    utf8_lossy(Bin).

%% @doc RFC 2047 encoded words (google.ts `decodeHeader`).
-spec decode_header(binary()) -> binary().
decode_header(Value) ->
    Folded = re:replace(Value, <<"(\\?=)(?:[ \\t]|\\r\\n[ \\t])+(?==\\?)">>, <<"\\1">>,
                        [global, {return, binary}]),
    case re:run(Folded, <<"=\\?([^?]+)\\?([bq])\\?([^?]*)\\?=">>,
                [global, caseless, {capture, all, index}]) of
        nomatch ->
            Folded;
        {match, Matches} ->
            splice(Folded, Matches, 0, [])
    end.

%% @doc Addresses outside quoted display names (google.ts `addresses`).
-spec addresses(binary()) -> [binary()].
addresses(Value) ->
    Unquoted = re:replace(Value, <<"\"(?:[^\"\\\\]|\\\\.)*\"\\s*(?=<)">>, <<" ">>,
                          [global, {return, binary}]),
    case re:run(Unquoted, <<"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+">>,
                [global, {capture, first, binary}]) of
        {match, Found} -> [A || [A] <- Found];
        nomatch -> []
    end.

%% @doc Gmail snippets carry a few HTML entities (google.ts `decodeSnippet`).
-spec decode_snippet(binary()) -> binary().
decode_snippet(Value) ->
    case re:run(Value, <<"&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);">>,
                [global, caseless, {capture, all, index}]) of
        nomatch ->
            Value;
        {match, Matches} ->
            splice_snippet(Value, Matches, 0, [])
    end.

%% @doc google.ts `htmlToPlainText`.
-spec html_to_text(binary()) -> binary().
html_to_text(Html) ->
    Input = binary:replace(
              binary:replace(binary:replace(Html, <<"\r\n">>, <<"\n">>, [global]),
                             <<"\r">>, <<"\n">>, [global]),
              <<0>>, <<>>, [global]),
    Text = iolist_to_binary(walk(tokens(Input, []), [], undefined, [])),
    S1 = re:replace(Text, <<"[\\t \\x{a0}]+">>, <<" ">>, [global, unicode, {return, binary}]),
    S2 = re:replace(S1, <<" *\\n *">>, <<"\n">>, [global, {return, binary}]),
    S3 = re:replace(S2, <<"\\n{3,}">>, <<"\n\n">>, [global, {return, binary}]),
    muse_google_api:js_trim(S3).

%% Charsets

decode_with(utf8, <<16#EF, 16#BB, 16#BF, Rest/binary>>) -> utf8_lossy(Rest);
decode_with(utf8, Bin) -> utf8_lossy(Bin);
decode_with(windows1252, Bin) -> << <<(cp1252(B))/utf8>> || <<B>> <= Bin >>;
decode_with(utf16le, <<16#FF, 16#FE, Rest/binary>>) -> utf16(Rest, little, <<>>);
decode_with(utf16le, Bin) -> utf16(Bin, little, <<>>);
decode_with(utf16be, <<16#FE, 16#FF, Rest/binary>>) -> utf16(Rest, big, <<>>);
decode_with(utf16be, Bin) -> utf16(Bin, big, <<>>).

utf16(<<>>, _, Acc) -> Acc;
utf16(<<_>>, _, Acc) -> <<Acc/binary, 16#FFFD/utf8>>;
utf16(Bin, E, Acc) ->
    {U, Rest} = unit(Bin, E),
    if
        U >= 16#D800, U =< 16#DBFF ->
            case byte_size(Rest) >= 2 andalso unit(Rest, E) of
                {L, Rest1} when L >= 16#DC00, L =< 16#DFFF ->
                    C = 16#10000 + ((U - 16#D800) bsl 10) + (L - 16#DC00),
                    utf16(Rest1, E, <<Acc/binary, C/utf8>>);
                _ ->
                    utf16(Rest, E, <<Acc/binary, 16#FFFD/utf8>>)
            end;
        U >= 16#DC00, U =< 16#DFFF ->
            utf16(Rest, E, <<Acc/binary, 16#FFFD/utf8>>);
        true ->
            utf16(Rest, E, <<Acc/binary, U/utf8>>)
    end.

unit(<<U:16/little, Rest/binary>>, little) -> {U, Rest};
unit(<<U:16/big, Rest/binary>>, big) -> {U, Rest}.

utf8_slow(<<>>, Acc) ->
    Acc;
utf8_slow(<<B, Rest/binary>>, Acc) when B < 16#80 ->
    utf8_slow(Rest, <<Acc/binary, B>>);
utf8_slow(<<B, Rest/binary>> = Bin, Acc) ->
    {Need, Lower, Upper, Init} =
        if
            B >= 16#C2, B =< 16#DF -> {1, 16#80, 16#BF, B band 16#1F};
            B =:= 16#E0 -> {2, 16#A0, 16#BF, B band 16#0F};
            B =:= 16#ED -> {2, 16#80, 16#9F, B band 16#0F};
            B >= 16#E1, B =< 16#EF -> {2, 16#80, 16#BF, B band 16#0F};
            B =:= 16#F0 -> {3, 16#90, 16#BF, B band 16#07};
            B =:= 16#F4 -> {3, 16#80, 16#8F, B band 16#07};
            B >= 16#F1, B =< 16#F3 -> {3, 16#80, 16#BF, B band 16#07};
            true -> {0, 0, 0, 0}
        end,
    case Need of
        0 -> utf8_slow(Rest, <<Acc/binary, 16#FFFD/utf8>>);
        _ -> utf8_cont(Rest, Need, Lower, Upper, Init, Bin, Acc)
    end.

utf8_cont(Rest, 0, _, _, Cp, _, Acc) ->
    utf8_slow(Rest, <<Acc/binary, Cp/utf8>>);
utf8_cont(<<B, Rest/binary>>, Need, Lower, Upper, Cp, Start, Acc) when B >= Lower, B =< Upper ->
    utf8_cont(Rest, Need - 1, 16#80, 16#BF, (Cp bsl 6) bor (B band 16#3F), Start, Acc);
utf8_cont(Rest, _, _, _, _, _, Acc) ->
    %% The offending byte is not consumed; it starts the next sequence.
    utf8_slow(Rest, <<Acc/binary, 16#FFFD/utf8>>).

cp1252(B) when B >= 16#80, B =< 16#9F ->
    element(B - 16#7F, {16#20AC, 16#81, 16#201A, 16#192, 16#201E, 16#2026, 16#2020, 16#2021,
                        16#2C6, 16#2030, 16#160, 16#2039, 16#152, 16#8D, 16#17D, 16#8F,
                        16#90, 16#2018, 16#2019, 16#201C, 16#201D, 16#2022, 16#2013, 16#2014,
                        16#2DC, 16#2122, 16#161, 16#203A, 16#153, 16#9D, 16#17E, 16#178});
cp1252(B) -> B.

%% RFC 2047

splice(Bin, [], Pos, Acc) ->
    iolist_to_binary(lists:reverse([binary:part(Bin, Pos, byte_size(Bin) - Pos) | Acc]));
splice(Bin, [[{Start, Len}, Cs, Enc, Txt] | More], Pos, Acc) ->
    Original = binary:part(Bin, Start, Len),
    Word = encoded_word(part(Bin, Cs), string:lowercase(part(Bin, Enc)), part(Bin, Txt), Original),
    splice(Bin, More, Start + Len, [Word, binary:part(Bin, Pos, Start - Pos) | Acc]).

part(Bin, {S, L}) -> binary:part(Bin, S, L).

encoded_word(Charset, Encoding, Text, Original) ->
    [Label | _] = binary:split(Charset, <<"*">>),
    case decoder(Label) of
        {ok, Enc} ->
            Bytes = case Encoding of
                        <<"b">> -> base64_lenient(Text);
                        <<"q">> -> q_bytes(unicode:characters_to_list(utf8_lossy(Text)), <<>>)
                    end,
            decode_with(Enc, Bytes);
        unsupported ->
            Original
    end.

q_bytes([], Acc) -> Acc;
q_bytes([$_ | Rest], Acc) -> q_bytes(Rest, <<Acc/binary, $\s>>);
q_bytes([$=, H, L | Rest], Acc) ->
    case is_hex(H) andalso is_hex(L) of
        true -> q_bytes(Rest, <<Acc/binary, (list_to_integer([H, L], 16))>>);
        false -> q_bytes([H, L | Rest], <<Acc/binary, $=>>)
    end;
q_bytes([C | Rest], Acc) -> q_bytes(Rest, <<Acc/binary, (C band 16#FF)>>).

is_hex(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)
                 orelse (C >= $A andalso C =< $F).

%% Node `Buffer.from(text, "base64")`: both alphabets, other characters
%% skipped, stops at `=`, a dangling sextet is dropped.
base64_lenient(Text) ->
    [Body | _] = binary:split(Text, <<"=">>),
    Sextets = [S || <<C>> <= Body, (S = sextet(C)) =/= skip],
    Bits = << <<S:6>> || S <- Sextets >>,
    Whole = bit_size(Bits) div 8,
    <<Bytes:Whole/binary, _/bitstring>> = Bits,
    Bytes.

sextet(C) when C >= $A, C =< $Z -> C - $A;
sextet(C) when C >= $a, C =< $z -> C - $a + 26;
sextet(C) when C >= $0, C =< $9 -> C - $0 + 52;
sextet(C) when C =:= $+; C =:= $- -> 62;
sextet(C) when C =:= $/; C =:= $_ -> 63;
sextet(_) -> skip.

%% Snippet entities

splice_snippet(Bin, [], Pos, Acc) ->
    iolist_to_binary(lists:reverse([binary:part(Bin, Pos, byte_size(Bin) - Pos) | Acc]));
splice_snippet(Bin, [[{Start, Len}, Name] | More], Pos, Acc) ->
    Original = binary:part(Bin, Start, Len),
    Entity = part(Bin, Name),
    Text = case string:lowercase(Entity) of
               <<"amp">> -> <<"&">>;
               <<"lt">> -> <<"<">>;
               <<"gt">> -> <<">">>;
               <<"quot">> -> <<"\"">>;
               <<"apos">> -> <<"'">>;
               <<"nbsp">> -> <<" ">>;
               <<"#x", Hex/binary>> -> code_point(binary_to_integer(Hex, 16), Original);
               <<"#", Dec/binary>> -> code_point(binary_to_integer(Dec), Original)
           end,
    splice_snippet(Bin, More, Start + Len, [Text, binary:part(Bin, Pos, Start - Pos) | Acc]).

code_point(C, _) when C >= 16#D800, C =< 16#DFFF -> <<16#FFFD/utf8>>;
code_point(C, _) when C >= 0, C =< 16#10FFFF -> <<C/utf8>>;
code_point(_, Original) -> Original.

%% HTML tokenizer: [{text, Bin} | {start, Name, SelfClosing} | {'end', Name}]

tokens(<<>>, Acc) ->
    lists:reverse(Acc);
tokens(<<"<!--", Rest/binary>>, Acc) ->
    tokens(after_comment(Rest), Acc);
tokens(<<"<!", Rest/binary>>, Acc) ->
    tokens(after_char(Rest, $>), Acc);
tokens(<<"<?", Rest/binary>>, Acc) ->
    tokens(after_char(Rest, $>), Acc);
tokens(<<"</>", Rest/binary>>, Acc) ->
    tokens(Rest, Acc);
tokens(<<"</", C, _/binary>> = Bin, Acc) when ?IS_ALPHA(C) ->
    <<"</", Rest/binary>> = Bin,
    {Name, Rest1} = tag_name(Rest, <<>>),
    case attributes(Rest1) of
        {ok, _, Rest2} -> tokens(Rest2, [{'end', Name} | Acc]);
        eof -> lists:reverse(Acc)
    end;
tokens(<<"</", Rest/binary>>, Acc) ->
    tokens(after_char(Rest, $>), Acc);
tokens(<<"<", C, _/binary>> = Bin, Acc) when ?IS_ALPHA(C) ->
    <<"<", Rest/binary>> = Bin,
    {Name, Rest1} = tag_name(Rest, <<>>),
    case attributes(Rest1) of
        eof ->
            lists:reverse(Acc);
        {ok, SelfClosing, Rest2} ->
            Start = {start, Name, SelfClosing},
            case {lists:member(Name, ?RAWTEXT), lists:member(Name, ?RCDATA)} of
                {false, false} when Name =:= <<"plaintext">> ->
                    lists:reverse([{text, Rest2}, Start | Acc]);
                {false, false} ->
                    tokens(Rest2, [Start | Acc]);
                {Raw, _} ->
                    {Content, Rest3} = raw_until(Rest2, Name),
                    Text = case Raw of
                               true -> Content;
                               false -> iolist_to_binary(entities(Content, []))
                           end,
                    tokens(Rest3, [{'end', Name}, {text, Text}, Start | Acc])
            end
    end;
tokens(<<"<", Rest/binary>>, Acc) ->
    tokens(Rest, [{text, <<"<">>} | Acc]);
tokens(Bin, Acc) ->
    {Text, Rest} = text_run(Bin, 0),
    tokens(Rest, [{text, iolist_to_binary(entities(Text, []))} | Acc]).

text_run(Bin, N) ->
    case Bin of
        <<_:N/binary, $<, _/binary>> -> split_binary(Bin, N);
        <<_:N/binary, _, _/binary>> -> text_run(Bin, N + 1);
        _ -> {Bin, <<>>}
    end.

after_comment(Bin) ->
    case binary:match(Bin, <<"-->">>) of
        {P, 3} -> binary:part(Bin, P + 3, byte_size(Bin) - P - 3);
        nomatch -> <<>>
    end.

after_char(Bin, Char) ->
    case binary:match(Bin, <<Char>>) of
        {P, 1} -> binary:part(Bin, P + 1, byte_size(Bin) - P - 1);
        nomatch -> <<>>
    end.

tag_name(<<C, Rest/binary>>, Acc) when C =/= $\s, C =/= $\t, C =/= $\n, C =/= $\f,
                                       C =/= $/, C =/= $> ->
    tag_name(Rest, <<Acc/binary, (lower(C))>>);
tag_name(Rest, Acc) ->
    {Acc, Rest}.

lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

%% Skip attributes; returns {ok, SelfClosing, Rest} or eof.
attributes(<<>>) -> eof;
attributes(<<">", Rest/binary>>) -> {ok, false, Rest};
attributes(<<"/>", Rest/binary>>) -> {ok, true, Rest};
attributes(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\f; C =:= $/ ->
    attributes(Rest);
attributes(Bin) ->
    attr_name(Bin).

attr_name(<<>>) -> eof;
attr_name(<<C, _/binary>> = Bin) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\f; C =:= $/;
                                      C =:= $> ->
    attr_value(Bin);
attr_name(<<$=, Rest/binary>>) -> value(skip_ws(Rest));
attr_name(<<_, Rest/binary>>) -> attr_name(Rest).

attr_value(Bin) ->
    case skip_ws(Bin) of
        <<$=, Rest/binary>> -> value(skip_ws(Rest));
        Other -> attributes(Other)
    end.

value(<<Q, Rest/binary>>) when Q =:= $"; Q =:= $' ->
    case binary:match(Rest, <<Q>>) of
        {P, 1} -> attributes(binary:part(Rest, P + 1, byte_size(Rest) - P - 1));
        nomatch -> eof
    end;
value(Bin) ->
    unquoted(Bin).

unquoted(<<>>) -> eof;
unquoted(<<">", Rest/binary>>) -> {ok, false, Rest};
unquoted(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\f ->
    attributes(Rest);
unquoted(<<_, Rest/binary>>) -> unquoted(Rest).

skip_ws(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\f -> skip_ws(Rest);
skip_ws(Bin) -> Bin.

raw_until(Bin, Name) ->
    case re:run(Bin, <<"</", Name/binary, "[\\t\\n\\f />]">>, [caseless, {capture, first, index}]) of
        {match, [{P, _}]} ->
            Rest = binary:part(Bin, P, byte_size(Bin) - P),
            {_, Rest1} = tag_name(binary:part(Rest, 2, byte_size(Rest) - 2), <<>>),
            After = case attributes(Rest1) of
                        {ok, _, R} -> R;
                        eof -> <<>>
                    end,
            {binary:part(Bin, 0, P), After};
        nomatch ->
            {Bin, <<>>}
    end.

%% Character references in text.
entities(<<>>, Acc) ->
    lists:reverse(Acc);
entities(<<"&#", X, Rest/binary>>, Acc) when X =:= $x; X =:= $X ->
    case hex_digits(Rest, <<>>) of
        {<<>>, _} -> entities(Rest, [[$&, $#, X] | Acc]);
        {Digits, Rest1} -> entities(semicolon(Rest1), [numeric(binary_to_integer(Digits, 16)) | Acc])
    end;
entities(<<"&#", Rest/binary>>, Acc) ->
    case dec_digits(Rest, <<>>) of
        {<<>>, _} -> entities(Rest, [<<"&#">> | Acc]);
        {Digits, Rest1} -> entities(semicolon(Rest1), [numeric(binary_to_integer(Digits)) | Acc])
    end;
entities(<<"&", Rest/binary>>, Acc) ->
    {Name, Rest1} = alnum(Rest, <<>>),
    case {Rest1, named(Name)} of
        {<<";", Rest2/binary>>, {ok, Text}} ->
            entities(Rest2, [Text | Acc]);
        _ ->
            case legacy_prefix(Name, byte_size(Name)) of
                {Text, Len} ->
                    <<_:Len/binary, Tail/binary>> = Name,
                    entities(<<Tail/binary, Rest1/binary>>, [Text | Acc]);
                none ->
                    entities(Rest, [<<"&">> | Acc])
            end
    end;
entities(Bin, Acc) ->
    case binary:match(Bin, <<"&">>) of
        nomatch -> lists:reverse([Bin | Acc]);
        {P, 1} -> entities(binary:part(Bin, P, byte_size(Bin) - P), [binary:part(Bin, 0, P) | Acc])
    end.

semicolon(<<";", Rest/binary>>) -> Rest;
semicolon(Rest) -> Rest.

hex_digits(<<C, Rest/binary>>, Acc) when (C >= $0 andalso C =< $9); (C >= $a andalso C =< $f);
                                         (C >= $A andalso C =< $F) ->
    hex_digits(Rest, <<Acc/binary, C>>);
hex_digits(Rest, Acc) -> {Acc, Rest}.

dec_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 -> dec_digits(Rest, <<Acc/binary, C>>);
dec_digits(Rest, Acc) -> {Acc, Rest}.

alnum(<<C, Rest/binary>>, Acc) when ?IS_ALPHA(C); C >= $0, C =< $9 -> alnum(Rest, <<Acc/binary, C>>);
alnum(Rest, Acc) -> {Acc, Rest}.

numeric(0) -> <<16#FFFD/utf8>>;
numeric(C) when C > 16#10FFFF -> <<16#FFFD/utf8>>;
numeric(C) when C >= 16#D800, C =< 16#DFFF -> <<16#FFFD/utf8>>;
numeric(C) when C >= 16#80, C =< 16#9F -> <<(cp1252(C))/utf8>>;
numeric(C) -> <<C/utf8>>.

legacy_prefix(_, 0) ->
    none;
legacy_prefix(Name, Len) ->
    Prefix = binary:part(Name, 0, Len),
    case lists:member(Prefix, legacy()) andalso named(Prefix) of
        {ok, Text} -> {Text, Len};
        _ -> legacy_prefix(Name, Len - 1)
    end.

named(Name) ->
    case lists:keyfind(Name, 1, entity_table()) of
        {_, C} -> {ok, <<C/utf8>>};
        false -> error
    end.

legacy() ->
    [<<"AMP">>, <<"LT">>, <<"GT">>, <<"QUOT">>, <<"COPY">>, <<"REG">>, <<"amp">>, <<"lt">>,
     <<"gt">>, <<"quot">> | [N || {N, C} <- entity_table(), C >= 160, C =< 255]].

entity_table() ->
    Latin1 = [<<"nbsp">>, <<"iexcl">>, <<"cent">>, <<"pound">>, <<"curren">>, <<"yen">>,
              <<"brvbar">>, <<"sect">>, <<"uml">>, <<"copy">>, <<"ordf">>, <<"laquo">>,
              <<"not">>, <<"shy">>, <<"reg">>, <<"macr">>, <<"deg">>, <<"plusmn">>, <<"sup2">>,
              <<"sup3">>, <<"acute">>, <<"micro">>, <<"para">>, <<"middot">>, <<"cedil">>,
              <<"sup1">>, <<"ordm">>, <<"raquo">>, <<"frac14">>, <<"frac12">>, <<"frac34">>,
              <<"iquest">>, <<"Agrave">>, <<"Aacute">>, <<"Acirc">>, <<"Atilde">>, <<"Auml">>,
              <<"Aring">>, <<"AElig">>, <<"Ccedil">>, <<"Egrave">>, <<"Eacute">>, <<"Ecirc">>,
              <<"Euml">>, <<"Igrave">>, <<"Iacute">>, <<"Icirc">>, <<"Iuml">>, <<"ETH">>,
              <<"Ntilde">>, <<"Ograve">>, <<"Oacute">>, <<"Ocirc">>, <<"Otilde">>, <<"Ouml">>,
              <<"times">>, <<"Oslash">>, <<"Ugrave">>, <<"Uacute">>, <<"Ucirc">>, <<"Uuml">>,
              <<"Yacute">>, <<"THORN">>, <<"szlig">>, <<"agrave">>, <<"aacute">>, <<"acirc">>,
              <<"atilde">>, <<"auml">>, <<"aring">>, <<"aelig">>, <<"ccedil">>, <<"egrave">>,
              <<"eacute">>, <<"ecirc">>, <<"euml">>, <<"igrave">>, <<"iacute">>, <<"icirc">>,
              <<"iuml">>, <<"eth">>, <<"ntilde">>, <<"ograve">>, <<"oacute">>, <<"ocirc">>,
              <<"otilde">>, <<"ouml">>, <<"divide">>, <<"oslash">>, <<"ugrave">>, <<"uacute">>,
              <<"ucirc">>, <<"uuml">>, <<"yacute">>, <<"thorn">>, <<"yuml">>],
    lists:zip(Latin1, lists:seq(160, 255)) ++
        [{<<"amp">>, $&}, {<<"AMP">>, $&}, {<<"lt">>, $<}, {<<"LT">>, $<}, {<<"gt">>, $>},
         {<<"GT">>, $>}, {<<"quot">>, $"}, {<<"QUOT">>, $"}, {<<"apos">>, $'},
         {<<"COPY">>, 169}, {<<"REG">>, 174}, {<<"OElig">>, 16#152}, {<<"oelig">>, 16#153},
         {<<"Scaron">>, 16#160}, {<<"scaron">>, 16#161}, {<<"Yuml">>, 16#178},
         {<<"fnof">>, 16#192}, {<<"circ">>, 16#2C6}, {<<"tilde">>, 16#2DC},
         {<<"ensp">>, 16#2002}, {<<"emsp">>, 16#2003}, {<<"thinsp">>, 16#2009},
         {<<"zwnj">>, 16#200C}, {<<"zwj">>, 16#200D}, {<<"lrm">>, 16#200E}, {<<"rlm">>, 16#200F},
         {<<"ndash">>, 16#2013}, {<<"mdash">>, 16#2014}, {<<"lsquo">>, 16#2018},
         {<<"rsquo">>, 16#2019}, {<<"sbquo">>, 16#201A}, {<<"ldquo">>, 16#201C},
         {<<"rdquo">>, 16#201D}, {<<"bdquo">>, 16#201E}, {<<"dagger">>, 16#2020},
         {<<"Dagger">>, 16#2021}, {<<"bull">>, 16#2022}, {<<"hellip">>, 16#2026},
         {<<"permil">>, 16#2030}, {<<"prime">>, 16#2032}, {<<"Prime">>, 16#2033},
         {<<"lsaquo">>, 16#2039}, {<<"rsaquo">>, 16#203A}, {<<"oline">>, 16#203E},
         {<<"euro">>, 16#20AC}, {<<"trade">>, 16#2122}, {<<"larr">>, 16#2190},
         {<<"uarr">>, 16#2191}, {<<"rarr">>, 16#2192}, {<<"darr">>, 16#2193},
         {<<"harr">>, 16#2194}, {<<"minus">>, 16#2212}, {<<"le">>, 16#2264},
         {<<"ge">>, 16#2265}, {<<"ne">>, 16#2260}, {<<"infin">>, 16#221E},
         {<<"hearts">>, 16#2665}, {<<"check">>, 16#2713}, {<<"star">>, 16#2606},
         {<<"starf">>, 16#2605}].

%% Tree walk over the token stream. Stack holds open element names (top
%% first); Skip is the stack depth of an excluded element being skipped.

walk([], Stack, Skip, Out) ->
    {_, _, Out1} = pop_all(Stack, Skip, Out),
    lists:reverse(Out1);
walk([{text, T} | Rest], Stack, Skip, Out) ->
    walk(Rest, Stack, Skip, emit(Skip, T, Out));
walk([{start, Name, SelfClosing} | Rest], Stack, Skip, Out) ->
    case lists:member(Name, [<<"html">>, <<"head">>, <<"body">>, <<"frameset">>]) of
        true -> walk(Rest, Stack, Skip, Out);
        false -> start(Name, SelfClosing, Rest, Stack, Skip, Out)
    end;
walk([{'end', Name} | Rest], Stack, Skip, Out) when Name =:= <<"html">>; Name =:= <<"head">>;
                                                    Name =:= <<"body">> ->
    walk(Rest, Stack, Skip, Out);
walk([{'end', <<"br">>} | Rest], Stack, Skip, Out) ->
    walk(Rest, Stack, Skip, emit(Skip, <<"\n">>, Out));
walk([{'end', Name} | Rest], Stack, Skip, Out) ->
    case lists:member(Name, Stack) of
        true ->
            {Stack1, Skip1, Out1} = pop_to(Name, Stack, Skip, Out),
            walk(Rest, Stack1, Skip1, Out1);
        false when Name =:= <<"p">> ->
            walk(Rest, Stack, Skip, emit(Skip, <<"\n\n">>, Out));
        false ->
            walk(Rest, Stack, Skip, Out)
    end.

start(Name, SelfClosing, Rest, Stack0, Skip0, Out0) when Skip0 =/= undefined ->
    %% Inside an excluded subtree only nesting matters (foreign content
    %% honours `/>`).
    case lists:member(Name, ?VOID) orelse SelfClosing of
        true -> walk(Rest, Stack0, Skip0, Out0);
        false -> walk(Rest, [Name | Stack0], Skip0, Out0)
    end;
start(Name, SelfClosing, Rest, Stack0, Skip0, Out0) ->
    {Stack, Skip, Out} = implied_end(Name, Stack0, Skip0, Out0),
    Foreign = Name =:= <<"svg">> orelse Name =:= <<"math">>,
    case lists:member(Name, ?EXCLUDED) of
        true when Foreign, SelfClosing ->
            walk(Rest, Stack, Skip, Out);
        true ->
            walk(Rest, [Name | Stack], length(Stack) + 1, Out);
        false ->
            case Name of
                <<"br">> ->
                    walk(Rest, Stack, Skip, [<<"\n">> | Out]);
                <<"hr">> ->
                    walk(Rest, Stack, Skip, [<<"\n\n">> | Out]);
                _ ->
                    case lists:member(Name, ?VOID) of
                        true ->
                            walk(Rest, Stack, Skip, Out);
                        false ->
                            Out1 = case lists:member(Name, ?BLOCKS) of
                                       true -> [<<"\n">> | Out];
                                       false -> Out
                                   end,
                            walk(Rest, [Name | Stack], Skip, Out1)
                    end
            end
    end.

implied_end(Name, Stack, Skip, Out) ->
    S1 = close_if(lists:member(Name, ?CLOSES_P), <<"p">>, [<<"button">>, <<"table">>, <<"td">>,
                                                           <<"th">>], {Stack, Skip, Out}),
    S2 = case Name of
             <<"li">> -> close_if(true, <<"li">>, [<<"ul">>, <<"ol">>, <<"table">>], S1);
             _ when Name =:= <<"dd">>; Name =:= <<"dt">> ->
                 close_if(true, <<"dd">>, [<<"dl">>, <<"table">>],
                          close_if(true, <<"dt">>, [<<"dl">>, <<"table">>], S1));
             _ when Name =:= <<"td">>; Name =:= <<"th">> ->
                 close_if(true, <<"td">>, [<<"tr">>, <<"table">>],
                          close_if(true, <<"th">>, [<<"tr">>, <<"table">>], S1));
             <<"tr">> ->
                 close_if(true, <<"tr">>, [<<"table">>], S1);
             _ ->
                 S1
         end,
    heading_end(Name, S2).

%% A heading start tag closes a heading that is the current node.
heading_end(Name, {[Top | _] = Stack, Skip, Out} = State) ->
    case lists:member(Name, ?HEADINGS) andalso lists:member(Top, ?HEADINGS) of
        true -> pop_to(Top, Stack, Skip, Out);
        false -> State
    end;
heading_end(_, State) ->
    State.

%% Close the nearest open `Target` unless a scope boundary comes first.
close_if(false, _, _, State) ->
    State;
close_if(true, Target, Boundaries, {Stack, Skip, Out} = State) ->
    case in_scope(Target, Boundaries, Stack) of
        true -> pop_to(Target, Stack, Skip, Out);
        false -> State
    end.

in_scope(_, _, []) -> false;
in_scope(Target, _, [Target | _]) -> true;
in_scope(Target, Boundaries, [Name | Rest]) ->
    not lists:member(Name, Boundaries) andalso in_scope(Target, Boundaries, Rest).

pop_to(Name, [Name | Rest], Skip, Out) ->
    close(Name, Rest, Skip, Out);
pop_to(Name, [Top | Rest], Skip, Out) ->
    {Rest1, Skip1, Out1} = close(Top, Rest, Skip, Out),
    pop_to(Name, Rest1, Skip1, Out1).

pop_all([], Skip, Out) -> {[], Skip, Out};
pop_all([Top | Rest], Skip, Out) ->
    {Rest1, Skip1, Out1} = close(Top, Rest, Skip, Out),
    pop_all(Rest1, Skip1, Out1).

%% Closing the element at depth length(Rest)+1.
close(Name, Rest, Skip, Out) ->
    Depth = length(Rest) + 1,
    case Skip of
        Depth -> {Rest, undefined, Out};
        undefined ->
            Out1 = case {lists:member(Name, ?BLOCKS), Name} of
                       {true, _} -> [<<"\n">> | Out];
                       {false, <<"td">>} -> [<<"\t">> | Out];
                       {false, <<"th">>} -> [<<"\t">> | Out];
                       _ -> Out
                   end,
            {Rest, undefined, Out1};
        _ ->
            {Rest, Skip, Out}
    end.

emit(undefined, T, Out) -> [T | Out];
emit(_, _, Out) -> Out.
