%% @doc `POST /upload`: the Documents page's PDF upload (designs/05-web-ui.md
%% §1, the `ah_upload` component posts each file here as multipart).
%%
%% The UI has no Bearer token, so the owner comes from the session cookie;
%% the multipart parsing, size limits and import are `POST /api/files`
%% itself (muse_api_integ), answering the same JSON: the Artifact (201), or
%% `{"error": Msg}`, which the upload component shows on the file's row.
-module(muse_ui_b_upload).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req = case {cowboy_req:method(Req0), muse_ui:owner(Req0)} of
              {<<"POST">>, {ok, Owner}} ->
                  case same_origin(Req0) of
                      true -> upload(Owner, Req0);
                      false -> muse_http:error_reply(403, <<"Origin is not allowed">>, Req0)
                  end;
              {<<"POST">>, error} ->
                  muse_http:error_reply(401, <<"Sign in again to upload">>, Req0);
              _ ->
                  cowboy_req:reply(405, #{<<"allow">> => <<"POST">>}, <<>>, Req0)
          end,
    {ok, Req, State}.

upload(Owner, Req0) ->
    try muse_api_integ:handle(<<"POST">>, [<<"api">>, <<"files">>], Req0#{muse_owner => Owner}) of
        {Result, Req} -> muse_http:reply(Result, Req)
    catch
        Class:Reason ->
            logger:error("ui upload ~p ~0p", [Class, muse_http:class(Reason)]),
            muse_http:error_reply(502, muse_http:generic_error(), Req0)
    end.

%% muse_mw already refuses foreign origins. Browsers send Origin on every
%% form POST; without it (non-browser clients) only an explicit cross-site
%% fetch is refused. The session cookie is SameSite=Lax as well.
same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> cowboy_req:header(<<"sec-fetch-site">>, Req) =/= <<"cross-site">>;
        _ -> true
    end.
