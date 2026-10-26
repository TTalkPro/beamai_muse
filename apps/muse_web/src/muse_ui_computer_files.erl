%% @doc The computer page's file transfers (designs/05-web-ui.md §5; not in
%% OpenMuse): `GET /computer-files/<id>/download?path=<file>` sends a file
%% of the computer's /workspace as an attachment, and `POST
%% /computer-files/<id>/upload?dir=<directory>` writes the multipart `file`
%% part into that directory (the `ah_upload` component posts each file
%% here). Both are at most 10 MB (muse_computer:download/2, upload/3).
%%
%% Like `/upload` (muse_ui_b_upload) the owner comes from the session
%% cookie, and the computer must be one of the owner's. Errors are
%% `{"error": Msg}`, which the upload component shows on the file's row.
-module(muse_ui_computer_files).
-behaviour(cowboy_handler).

-export([init/2, download_url/2, upload_url/2]).

-spec download_url(binary(), binary()) -> binary().
download_url(Id, Path) ->
    <<"/computer-files/", Id/binary, "/download?path=", (muse_signing:encode_uri_component(Path))/binary>>.

-spec upload_url(binary(), binary()) -> binary().
upload_url(Id, Dir) ->
    <<"/computer-files/", Id/binary, "/upload?dir=", (muse_signing:encode_uri_component(Dir))/binary>>.

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Op = {cowboy_req:method(Req0), cowboy_req:binding(op, Req0)},
    Req = case muse_ui:owner(Req0) of
              error ->
                  muse_http:error_reply(401, <<"Sign in again">>, Req0);
              {ok, Owner} ->
                  case muse_computers:get(Owner, cowboy_req:binding(id, Req0)) of
                      undefined ->
                          muse_http:error_reply(404, <<"Computer not found">>, Req0);
                      #{<<"id">> := Id} ->
                          handle(Op, muse_computer:ref_of(Owner, Id), Req0)
                  end
          end,
    {ok, Req, State}.

handle({<<"GET">>, <<"download">>}, Ref, Req) ->
    case muse_computer:download(Ref, case muse_http:query(<<"path">>, Req) of
                                         undefined -> <<>>;
                                         P -> P
                                     end) of
        {ok, #{name := Name, bytes := Bytes}} ->
            cowboy_req:reply(200, #{<<"content-type">> => <<"application/octet-stream">>,
                                    <<"content-disposition">> =>
                                        <<"attachment; filename*=UTF-8''",
                                          (muse_signing:encode_uri_component(Name))/binary>>,
                                    <<"cache-control">> => <<"no-store">>},
                             Bytes, Req);
        Error ->
            reply(Error, Req)
    end;
handle({<<"POST">>, <<"upload">>}, Ref, Req0) ->
    case same_origin(Req0) of
        false ->
            muse_http:error_reply(403, <<"Origin is not allowed">>, Req0);
        true ->
            case muse_api_integ:read_upload(Req0) of
                {ok, {Filename, Bytes}, Req} ->
                    Dir = case muse_http:query(<<"dir">>, Req) of
                              undefined -> <<"/workspace">>;
                              D -> string:trim(D, trailing, "/")
                          end,
                    Path = <<Dir/binary, "/", (filename:basename(Filename))/binary>>,
                    reply(case muse_computer:upload(Ref, Path, Bytes) of
                              {ok, _} -> {ok, #{<<"path">> => Path, <<"name">> => filename:basename(Filename)}};
                              Error -> Error
                          end, Req);
                {ok, undefined, Req} ->
                    muse_http:error_reply(400, <<"Choose a file">>, Req);
                {error, {413, Msg}, Req} ->
                    muse_http:error_reply(413, Msg, Req);
                {error, _, Req} ->
                    muse_http:error_reply(400, <<"Choose a file">>, Req)
            end
    end;
handle(_, _, Req) ->
    cowboy_req:reply(405, #{}, <<>>, Req).

reply({ok, Body}, Req) -> muse_http:reply({201, Body}, Req);
reply({error, {Status, Msg}}, Req) -> muse_http:error_reply(Status, Msg, Req).

%% As muse_ui_b_upload: Origin is checked by muse_mw already.
same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> cowboy_req:header(<<"sec-fetch-site">>, Req) =/= <<"cross-site">>;
        _ -> true
    end.
