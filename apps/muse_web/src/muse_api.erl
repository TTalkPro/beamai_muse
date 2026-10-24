%% @doc The JSON API handler for `/api/[...]` (OpenMuse app.ts).
%%
%% Routes before authentication: `GET /api/health`, `POST /api/session`,
%% `GET /api/google/callback`. Everything else needs a Bearer session token,
%% or a valid signature on the signable paths (file content, browser preview
%% and console). Route modules are tried in order; each exports
%% `handle(Method, PathSegments, Req) -> next | {Result, Req}` with Result as
%% described in muse_http. An authenticated request that matches nothing is
%% Hono's plain `404 Not Found`.
-module(muse_api).
-behaviour(cowboy_handler).

-export([init/2, authenticate/1, route_modules/0]).

-spec route_modules() -> [module()].
route_modules() ->
    [muse_api_core, muse_api_agent, muse_api_threads, muse_api_integ, muse_api_computer].

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = segments(cowboy_req:path(Req0)),
    Req = try dispatch(Method, Path, Req0)
          catch Class:Reason ->
              logger:error("[OpenMuse] ~p ~0p", [Class, muse_http:class(Reason)]),
              muse_http:error_reply(502, muse_http:generic_error(), Req0)
          end,
    {ok, Req, State}.

dispatch(Method, Path, Req) ->
    case muse_api_core:public(Method, Path, Req) of
        {Result, Req1} ->
            muse_http:reply(Result, Req1);
        next ->
            case authenticate(Req) of
                {ok, Owner} -> route(route_modules(), Method, Path, Req#{muse_owner => Owner});
                {error, {Status, Msg}} -> muse_http:error_reply(Status, Msg, Req)
            end
    end.

route([], _Method, _Path, Req) ->
    cowboy_req:reply(404, #{<<"content-type">> => <<"text/plain; charset=UTF-8">>}, <<"404 Not Found">>, Req);
route([Module | Rest], Method, Path, Req) ->
    case Module:handle(Method, Path, Req) of
        next -> route(Rest, Method, Path, Req);
        {Result, Req1} -> muse_http:reply(Result, Req1)
    end.

%% @doc Signed URL on signable paths when `signature` is present, else Bearer.
-spec authenticate(cowboy_req:req()) -> {ok, binary()} | {error, {401 | 403, binary()}}.
authenticate(Req) ->
    Path = cowboy_req:path(Req),
    Signature = muse_http:query(<<"signature">>, Req),
    case muse_signing:is_signable_path(Path) andalso Signature =/= undefined andalso Signature =/= <<>> of
        true ->
            muse_signing:verify(Path, muse_http:query(<<"owner">>, Req), muse_http:query(<<"expires">>, Req),
                                Signature);
        false ->
            muse_auth:owner_from_header(cowboy_req:header(<<"authorization">>, Req))
    end.

segments(Path) ->
    [uri_string:percent_decode(S) || S <- binary:split(Path, <<"/">>, [global, trim_all])].
