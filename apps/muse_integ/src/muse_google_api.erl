%% @doc Google REST request rules shared by Gmail and Calendar
%% (designs/ref/openmuse-integrations-spec.md §9.5, google.ts `request`).
%%
%% A client is a map holding a token function, so the Gmail and Calendar
%% modules never touch credentials themselves: `client/1,2` binds it to
%% `muse_google_auth:access_token/2`, tests pass their own.
%%
%% Errors follow the muse convention `{error, {Status, Message}}`, with two
%% extra tags for OpenMuse errors that are not AppErrors:
%%
%% - `{outcome_unknown, Msg}`: OutcomeUnknownError. A write may have reached
%%   Google; the action becomes `outcome_unknown` and is never retried.
%% - `{internal, Msg}`: a plain `Error`. Actions record `Msg`; HTTP answers
%%   502 with the generic text (`http_error/1`).
%%
%% GoogleApiError is `{502, <<"Google API (S): detail">>}`, RecurringEventError
%% and schema failures are `{422, Msg}`.
-module(muse_google_api).

-export([client/1, client/2, token_client/1,
         get/2, request/5,
         http_error/1, form_encode/1, encode_uri_component/1,
         id_path/1, calendar_path/1, single_line/2,
         pmap/2, js_trim/1, utf16_length/1, slice_utf16/2]).

-export_type([client/0, error/0, json/0]).

-define(TIMEOUT, 30000).
-define(MAX_JSON_BYTES, 14729560).
-define(CALENDAR, "https://www.googleapis.com/calendar/v3").
-define(OUTCOME_UNKNOWN,
        <<"Google may have completed this action. Check Google before trying again.">>).

-type json() :: term().
-type error() :: {pos_integer(), binary()} | {outcome_unknown, binary()} | {internal, binary()}.
-type client() :: #{token := fun(() -> {ok, binary()} | {error, error()})}.

%% @doc Client for `Owner`'s stored Google credentials.
-spec client(binary()) -> client().
client(Owner) ->
    client(Owner, undefined).

%% @doc Like `client/1`, failing with 409 when the connection is not `ConnId`.
-spec client(binary(), binary() | undefined) -> client().
client(Owner, ConnId) ->
    #{token => fun() -> muse_google_auth:access_token(Owner, ConnId) end}.

-spec token_client(fun(() -> {ok, binary()} | {error, error()})) -> client().
token_client(Fun) ->
    #{token => Fun}.

-spec get(client(), iodata()) -> {ok, json()} | {error, error()}.
get(Client, Url) ->
    request(Client, get, Url, undefined, []).

%% @doc One authenticated call. `Body` is JSON (encoded with `muse_json`) or
%% `undefined`; `Extra` adds conditional headers such as If-Match.
%% Returns `{ok, undefined}` for `DELETE` answered with 204.
-spec request(client(), get | post | patch | put | delete, iodata(),
              json() | undefined, [{binary(), binary()}]) ->
          {ok, json()} | {error, error()}.
request(#{token := TokenFun}, Method, Url, Body, Extra) ->
    Write = Method =/= get,
    case TokenFun() of
        {ok, Token} when is_binary(Token) ->
            case valid_token(Token) of
                true -> dispatch(Method, iolist_to_binary(Url), Token, Body, Extra, Write);
                false -> internal(<<"Google access token is missing or invalid; reconnect Google">>)
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc The HTTP status and message for an error (OpenMuse `onError`).
-spec http_error(error()) -> {pos_integer(), binary()}.
http_error({Status, Msg}) when is_integer(Status) -> {Status, Msg};
http_error(_) -> {502, <<"Request failed. Check the server setup and try again.">>}.

%% @doc `URLSearchParams.toString()` for ordered pairs.
-spec form_encode([{iodata(), iodata()}]) -> binary().
form_encode(Pairs) ->
    iolist_to_binary(lists:join($&, [[form_component(K), $=, form_component(V)]
                                     || {K, V} <- Pairs])).

%% @doc JavaScript `encodeURIComponent` of a UTF-8 binary.
-spec encode_uri_component(binary()) -> binary().
encode_uri_component(Bin) ->
    << <<(uri_byte(B))/binary>> || <<B>> <= Bin >>.

-spec id_path(binary()) -> {ok, binary()} | {error, error()}.
id_path(Id) when is_binary(Id) ->
    case re:run(Id, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) of
        match -> {ok, Id};
        nomatch -> internal(<<"Invalid Google resource ID">>)
    end;
id_path(_) ->
    internal(<<"Invalid Google resource ID">>).

%% @doc `${CALENDAR}/calendars/<id>/events` after the calendarPath checks.
-spec calendar_path(binary()) -> {ok, binary()} | {error, error()}.
calendar_path(CalId) when is_binary(CalId), CalId =/= <<>>, CalId =/= <<".">>,
                          CalId =/= <<"..">> ->
    Controls = [C || <<C>> <= CalId, C =< 32 orelse C =:= 127],
    case Controls =:= [] andalso utf16_length(CalId) =< 1024 of
        true ->
            {ok, <<?CALENDAR, "/calendars/", (encode_uri_component(CalId))/binary, "/events">>};
        false ->
            internal(<<"Invalid Google calendar ID">>)
    end;
calendar_path(_) ->
    internal(<<"Invalid Google calendar ID">>).

%% @doc google.ts `singleLine`: no character below 0x20 or equal to 0x7F.
-spec single_line(binary(), binary()) -> {ok, binary()} | {error, error()}.
single_line(Value, Field) ->
    case [C || <<C>> <= Value, C < 32 orelse C =:= 127] of
        [] -> {ok, Value};
        _ -> internal(<<"Invalid ", Field/binary, ": header control characters are not allowed">>)
    end.

%% @doc `Promise.all` over `Fun`: run every item concurrently; the first
%% error in list order wins.
-spec pmap(fun((term()) -> {ok, term()} | {error, error()}), [term()]) ->
          {ok, [term()]} | {error, error()}.
pmap(_Fun, []) ->
    {ok, []};
pmap(Fun, [Item]) ->
    case Fun(Item) of
        {ok, V} -> {ok, [V]};
        Error -> Error
    end;
pmap(Fun, Items) ->
    Parent = self(),
    Workers = [spawn_monitor(fun() -> Parent ! {?MODULE, self(), Fun(I)} end) || I <- Items],
    Results = [receive
                   {?MODULE, Pid, Result} ->
                       erlang:demonitor(Ref, [flush]),
                       pmap_result(Result);
                   {'DOWN', Ref, process, Pid, _} ->
                       pmap_result(crashed)
               end || {Pid, Ref} <- Workers],
    case [E || {error, _} = E <- Results] of
        [] -> {ok, [V || {ok, V} <- Results]};
        [First | _] -> First
    end.

%% @doc JavaScript `String.prototype.trim`.
-spec js_trim(binary()) -> binary().
js_trim(Bin) ->
    Ws = "\s\t\n\r\v\f\x{A0}\x{1680}\x{2000}\x{2001}\x{2002}\x{2003}\x{2004}\x{2005}"
         "\x{2006}\x{2007}\x{2008}\x{2009}\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}"
         "\x{3000}\x{FEFF}",
    Chars = unicode:characters_to_list(Bin),
    Strip = fun(L) -> lists:dropwhile(fun(C) -> lists:member(C, Ws) end, L) end,
    unicode:characters_to_binary(lists:reverse(Strip(lists:reverse(Strip(Chars))))).

%% @doc JavaScript `string.length` of UTF-8 text.
-spec utf16_length(binary()) -> non_neg_integer().
utf16_length(Bin) ->
    utf16_length(Bin, 0).

%% @doc `string.slice(0, N)` in UTF-16 units; a pair split by the cut is dropped.
-spec slice_utf16(binary(), non_neg_integer()) -> binary().
slice_utf16(Bin, N) ->
    slice_utf16(Bin, N, <<>>).

%% Internal

dispatch(Method, Url, Token, Body, Extra, Write) ->
    Headers = [{<<"Authorization">>, <<"Bearer ", Token/binary>>}]
              ++ case Body of
                     undefined -> [];
                     _ -> [{<<"Content-Type">>, <<"application/json">>}]
                 end ++ Extra,
    Payload = case Body of
                  undefined -> <<>>;
                  _ -> muse_json:encode(Body)
              end,
    Result = try beamai_http:request_meta(Method, Url, Headers, Payload, #{timeout => ?TIMEOUT})
             catch _:_ -> {error, exception}
             end,
    response(Result, Method, Write).

response({ok, Resp, #{status := S} = Meta}, Method, Write) when is_integer(S), S >= 200, S < 300 ->
    case {Method, S} of
        {delete, 204} ->
            {ok, undefined};
        _ ->
            case oversized(Meta) of
                true -> invalid_body(Write);
                false -> json_body(Resp, Write)
            end
    end;
response({ok, _, _}, _Method, Write) ->
    %% fetch(redirect: "error") rejects 3xx before the body is read.
    unreachable(Write);
response({error, {http_error, S, Body, _Headers}}, _Method, Write) ->
    http_failure(S, Body, Write);
response({error, {http_error, S, Body}}, _Method, Write) ->
    http_failure(S, Body, Write);
response({error, _}, _Method, Write) ->
    unreachable(Write).

http_failure(S, _Body, true) when S >= 500; S =:= 408 ->
    {error, {outcome_unknown, ?OUTCOME_UNKNOWN}};
http_failure(S, Body, _Write) ->
    Detail = case decode_json(Body) of
                 {ok, #{<<"error">> := #{<<"message">> := Msg}}} when is_binary(Msg) ->
                     slice_utf16(Msg, 500);
                 _ ->
                     reason_phrase(S)
             end,
    {error, {502, <<"Google API (", (integer_to_binary(S))/binary, "): ", Detail/binary>>}}.

unreachable(true) -> {error, {outcome_unknown, ?OUTCOME_UNKNOWN}};
unreachable(false) -> internal(<<"Could not reach Google; check the connection and try again">>).

invalid_body(true) -> {error, {outcome_unknown, ?OUTCOME_UNKNOWN}};
invalid_body(false) -> internal(<<"Google returned an invalid or oversized response">>).

oversized(#{headers := Headers}) when is_list(Headers) ->
    case [V || {K, V} <- Headers, string:lowercase(K) =:= <<"content-length">>] of
        [Len | _] ->
            try binary_to_integer(string:trim(Len)) > ?MAX_JSON_BYTES
            catch _:_ -> false
            end;
        [] ->
            false
    end;
oversized(_) ->
    false.

%% beamai_http decodes JSON already; a binary is either not JSON or JSON that
%% OTP's decoder refused (lone UTF-16 surrogates, which V8 accepts).
json_body(Resp, Write) when is_binary(Resp) ->
    case byte_size(Resp) =< ?MAX_JSON_BYTES andalso decode_json(Resp) of
        {ok, Json} when is_map(Json); is_list(Json) -> {ok, Json};
        _ -> invalid_body(Write)
    end;
json_body(Resp, _Write) ->
    {ok, Resp}.

decode_json(Bin) when is_binary(Bin) ->
    try {ok, json:decode(Bin)}
    catch _:_ ->
        try {ok, json:decode(well_formed_escapes(Bin))}
        catch _:_ -> error
        end
    end;
decode_json(Term) ->
    {ok, Term}.

%% Lone `\uD8xx`/`\uDCxx` escapes become U+FFFD (String.prototype.toWellFormed).
well_formed_escapes(Bin) ->
    Pairs = re:replace(Bin, <<"\\\\u([dD][89abAB][0-9a-fA-F]{2})\\\\u([dD][c-fC-F][0-9a-fA-F]{2})">>,
                       <<"\\\\U\\1\\\\U\\2">>, [global, {return, binary}]),
    Lone = re:replace(Pairs, <<"\\\\u[dD][89a-fA-F][0-9a-fA-F]{2}">>, <<"\\\\ufffd">>,
                      [global, {return, binary}]),
    re:replace(Lone, <<"\\\\U">>, <<"\\\\u">>, [global, {return, binary}]).

pmap_result({ok, _} = Ok) -> Ok;
pmap_result({error, _} = Error) -> Error;
pmap_result(_) -> internal(<<"Google request failed">>).

valid_token(<<>>) -> false;
valid_token(Token) -> binary:match(Token, [<<"\r">>, <<"\n">>]) =:= nomatch.

internal(Msg) ->
    {error, {internal, Msg}}.

form_component(V) ->
    << <<(form_byte(B))/binary>> || <<B>> <= iolist_to_binary(V) >>.

form_byte($\s) -> <<"+">>;
form_byte(B) when B >= $a, B =< $z; B >= $A, B =< $Z; B >= $0, B =< $9;
                  B =:= $*; B =:= $-; B =:= $.; B =:= $_ -> <<B>>;
form_byte(B) -> pct(B).

uri_byte(B) when B >= $a, B =< $z; B >= $A, B =< $Z; B >= $0, B =< $9 -> <<B>>;
uri_byte(B) when B =:= $-; B =:= $_; B =:= $.; B =:= $!; B =:= $~; B =:= $*;
                 B =:= $'; B =:= $(; B =:= $) -> <<B>>;
uri_byte(B) -> pct(B).

pct(B) -> <<"%", (binary:encode_hex(<<B>>, uppercase))/binary>>.

utf16_length(<<>>, N) -> N;
utf16_length(<<C/utf8, Rest/binary>>, N) when C > 16#FFFF -> utf16_length(Rest, N + 2);
utf16_length(<<_/utf8, Rest/binary>>, N) -> utf16_length(Rest, N + 1);
utf16_length(<<_, Rest/binary>>, N) -> utf16_length(Rest, N + 1).

slice_utf16(_, N, Acc) when N =< 0 -> Acc;
slice_utf16(<<>>, _, Acc) -> Acc;
slice_utf16(<<C/utf8, _/binary>>, 1, Acc) when C > 16#FFFF -> Acc;
slice_utf16(<<C/utf8, Rest/binary>>, N, Acc) ->
    slice_utf16(Rest, N - units(C), <<Acc/binary, C/utf8>>);
slice_utf16(<<B, Rest/binary>>, N, Acc) ->
    slice_utf16(Rest, N - 1, <<Acc/binary, B>>).

units(C) when C > 16#FFFF -> 2;
units(_) -> 1.

%% fetch `statusText`; HTTP/2 has none, so fall back like the original.
reason_phrase(400) -> <<"Bad Request">>;
reason_phrase(401) -> <<"Unauthorized">>;
reason_phrase(403) -> <<"Forbidden">>;
reason_phrase(404) -> <<"Not Found">>;
reason_phrase(405) -> <<"Method Not Allowed">>;
reason_phrase(408) -> <<"Request Timeout">>;
reason_phrase(409) -> <<"Conflict">>;
reason_phrase(410) -> <<"Gone">>;
reason_phrase(412) -> <<"Precondition Failed">>;
reason_phrase(413) -> <<"Payload Too Large">>;
reason_phrase(429) -> <<"Too Many Requests">>;
reason_phrase(500) -> <<"Internal Server Error">>;
reason_phrase(502) -> <<"Bad Gateway">>;
reason_phrase(503) -> <<"Service Unavailable">>;
reason_phrase(504) -> <<"Gateway Timeout">>;
reason_phrase(_) -> <<"Request failed">>.
