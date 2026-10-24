%% Test helper: stub beamai_http:request_meta/5 with meck.
%%
%% `stub(Fun)`: Fun(Method, Url :: #{path, query, host}, Headers, Body) returns
%%   {json, Status, Term} | {status, Status} | {raw, Status, Bin} | {error, Reason}
-module(muse_google_test_http).
-export([start/0, stop/0, stub/1, calls/0, json/1, json/2, url/1, client/0, header/2,
         body_json/1]).

start() ->
    meck:new(beamai_http, [no_link]).

stop() ->
    meck:unload(beamai_http).

stub(Fun) ->
    meck:expect(beamai_http, request_meta,
                fun(Method, Url, Headers, Body, _Opts) ->
                        to_beamai(Fun(Method, url(Url), Headers, Body))
                end).

%% [{Method, Url, Headers, Body}] in call order.
calls() ->
    [{M, url(U), H, B} || {_, {beamai_http, request_meta, [M, U, H, B, _]}, _} <- meck:history(beamai_http)].

json(Term) -> {json, 200, Term}.
json(Status, Term) -> {json, Status, Term}.

client() ->
    muse_google_api:token_client(fun() -> {ok, <<"synthetic-access-token">>} end).

header(Name, Headers) ->
    Lower = string:lowercase(Name),
    case [V || {K, V} <- Headers, string:lowercase(K) =:= Lower] of
        [V | _] -> V;
        [] -> undefined
    end.

body_json(<<>>) -> undefined;
body_json(Bin) -> json:decode(iolist_to_binary(Bin)).

url(Url) ->
    U = uri_string:parse(iolist_to_binary(Url)),
    Query = case maps:get(query, U, <<>>) of
                <<>> -> [];
                Q -> uri_string:dissect_query(Q)
            end,
    #{host => maps:get(host, U), path => maps:get(path, U), query => Query,
      raw_path => maps:get(path, U)}.

to_beamai({json, S, Term}) when S >= 200, S < 300 ->
    {ok, Term, #{status => S, headers => []}};
to_beamai({json, S, Term}) ->
    {error, {http_error, S, iolist_to_binary(json:encode(Term)), []}};
to_beamai({status, S}) when S < 300 ->
    {ok, <<>>, #{status => S, headers => []}};
to_beamai({status, S}) when S < 400 ->
    {ok, <<>>, #{status => S, headers => []}};
to_beamai({status, S}) ->
    {error, {http_error, S, <<>>, []}};
to_beamai({raw, S, Bin}) when S < 400 ->
    {ok, Bin, #{status => S, headers => []}};
to_beamai({raw, S, Bin}) ->
    {error, {http_error, S, Bin, []}};
to_beamai({error, R}) ->
    {error, R}.
