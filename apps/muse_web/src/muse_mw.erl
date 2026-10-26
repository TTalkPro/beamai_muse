%% @doc Cowboy middleware applied to every request before routing
%% (OpenMuse app.ts middleware, integrations spec §2.2):
%% 1. origin gate: an `Origin` outside ALLOWED_ORIGINS ∪ origin(PUBLIC_API_URL)
%%    is 403 `{"error":"Origin is not allowed"}`; otherwise security headers;
%% 2. CORS for allowed origins, and preflight requests end here with 204;
%% 3. body limit by Content-Length (12 MiB; streamed bodies are capped by
%%    muse_http:read_body/1);
%% 4. rate limit on `/api/*` (120 per client per minute).
-module(muse_mw).
-behaviour(cowboy_middleware).

-export([execute/2, allowed_origins/0, origin_of/1]).

-spec execute(cowboy_req:req(), cowboy_middleware:env()) ->
    {ok, cowboy_req:req(), cowboy_middleware:env()} | {stop, cowboy_req:req()}.
execute(Req0, Env) ->
    Origin = cowboy_req:header(<<"origin">>, Req0),
    case Origin =:= undefined orelse origin_allowed(Origin) of
        false ->
            {stop, muse_http:error_reply(403, <<"Origin is not allowed">>, Req0)};
        true ->
            Req1 = lists:foldl(fun({K, V}, R) -> cowboy_req:set_resp_header(K, V, R) end, Req0,
                               [{<<"x-content-type-options">>, <<"nosniff">>},
                                {<<"referrer-policy">>, referrer_policy(Req0)},
                                {<<"cache-control">>, <<"no-store">>}]),
            Req = cors(Origin, Req1),
            case preflight(Req) of
                true ->
                    {stop, cowboy_req:reply(204, #{<<"access-control-allow-methods">> => <<"GET,POST,PUT,PATCH,DELETE,OPTIONS">>,
                                                   <<"access-control-allow-headers">> => <<"Content-Type,Authorization">>},
                                            Req)};
                false ->
                    limits(Req, Env)
            end
    end.

limits(Req, Env) ->
    case cowboy_req:body_length(Req) of
        Len when is_integer(Len), Len > 12582912 ->
            {stop, muse_http:error_reply(413, <<"Request is too large; PDFs must be 10 MB or smaller">>, Req)};
        _ ->
            case cowboy_req:path(Req) of
                <<"/api/", _/binary>> -> rate_limit(Req, Env);
                _ -> {ok, Req, Env}
            end
    end.

rate_limit(Req, Env) ->
    {Peer, _} = cowboy_req:peer(Req),
    Key = muse_rate_limit:client_key(muse_config:get(trust_proxy), cowboy_req:headers(Req), Peer),
    case muse_rate_limit:take(api, Key) of
        true -> {ok, Req#{muse_client_key => Key}, Env};
        false -> {stop, muse_http:error_reply(429, <<"Too many requests. Try again in a minute.">>, Req)}
    end.

%% The JSON API keeps OpenMuse's `no-referrer`. The UI's pages use
%% `same-origin`: under `no-referrer` browsers send `Origin: null` with the
%% pages' own form posts (sign-in) and actions, which the Origin check above
%% must refuse; `same-origin` still sends nothing to other sites.
referrer_policy(Req) ->
    case cowboy_req:path(Req) of
        <<"/api/", _/binary>> -> <<"no-referrer">>;
        _ -> <<"same-origin">>
    end.

cors(undefined, Req) ->
    Req;
cors(Origin, Req0) ->
    Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req0),
    Req2 = cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req1),
    cowboy_req:set_resp_header(<<"vary">>, <<"Origin">>, Req2).

preflight(Req) ->
    cowboy_req:method(Req) =:= <<"OPTIONS">>
        andalso cowboy_req:header(<<"access-control-request-method">>, Req) =/= undefined.

%% `ALLOWED_ORIGINS=*` admits every Origin (not in OpenMuse); CORS responses
%% still echo the request's Origin, since credentials rule out a literal `*`.
origin_allowed(Origin) ->
    Allowed = allowed_origins(),
    lists:member(<<"*">>, Allowed) orelse lists:member(Origin, Allowed).

%% @doc ALLOWED_ORIGINS (split on commas, not trimmed, as OpenMuse) plus the
%% origin of PUBLIC_API_URL.
-spec allowed_origins() -> [binary()].
allowed_origins() ->
    [origin_of(muse_config:get(public_url)) | muse_config:get(allowed_origins)].

%% @doc `new URL(u).origin`: scheme://host[:port], default ports dropped.
-spec origin_of(binary()) -> binary().
origin_of(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = U ->
            S = string:lowercase(Scheme),
            Port = case {S, maps:get(port, U, undefined)} of
                       {_, undefined} -> <<>>;
                       {<<"http">>, 80} -> <<>>;
                       {<<"https">>, 443} -> <<>>;
                       {_, P} -> <<":", (integer_to_binary(P))/binary>>
                   end,
            <<S/binary, "://", (string:lowercase(Host))/binary, Port/binary>>;
        _ ->
            Url
    end.
