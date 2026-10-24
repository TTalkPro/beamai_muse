%% @doc Documents, Gmail attachment import, Google connect and browser
%% routes (OpenMuse app.ts; integrations spec §2.6 #16–#31, §4.6, §5, §7.4,
%% §9.1, §9.4).
%%
%% `GET /api/files/:id/content` and `/api/browsers/:id/(preview|console)` are
%% also reached through signed URLs; muse_api has already resolved the owner.
-module(muse_api_integ).

-export([handle/3]).

-define(CHOOSE_PDF, <<"Choose a PDF file">>).
-define(TOO_LARGE, <<"Request is too large; PDFs must be 10 MB or smaller">>).
-define(URL, {string, #{url => true, max => 4096}}).
-define(CONSOLE_CSP, <<"default-src 'self'; img-src 'self' blob:; script-src 'unsafe-inline'; "
                       "style-src 'unsafe-inline'; connect-src 'self'">>).

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(<<"POST">>, [<<"api">>, <<"files">>], Req) ->
    upload(Req);
handle(<<"GET">>, [<<"api">>, <<"files">>, Id, <<"content">>], Req) ->
    O = muse_http:owner(Req),
    {maybe
         {ok, #{<<"id">> := FileId, <<"name">> := Name}} ?= muse_files:get(O, Id),
         {ok, Bytes} ?= muse_files:bytes(O, FileId),
         {raw, 200, #{<<"content-type">> => <<"application/pdf">>,
                      <<"content-disposition">> =>
                          <<"inline; filename*=UTF-8''", (muse_signing:encode_uri_component(Name))/binary>>},
          Bytes}
     end, Req};
handle(<<"POST">>, [<<"api">>, <<"files">>, Id, <<"fill">>], Req) ->
    body(Req, {object, [{<<"fields">>, {record, {union, [{string, #{}}, boolean]}, #{}}}]},
         fun(#{<<"fields">> := Fields}) -> created(muse_files:fill(muse_http:owner(Req), Id, Fields)) end);
handle(<<"POST">>, [<<"api">>, <<"mail">>, <<"import-attachment">>], Req) ->
    body(Req, {object, [{<<"reference">>, {string, #{}}}]},
         fun(#{<<"reference">> := Ref}) ->
                 created(muse_workspace:import_attachment(muse_http:owner(Req), Ref))
         end);
handle(<<"POST">>, [<<"api">>, <<"google">>, <<"connect">>], Req) ->
    body(Req, {object, [{<<"capability">>, {enum, [<<"read">>, <<"write">>]}}]},
         fun(#{<<"capability">> := Capability}) ->
                 Owner = muse_http:owner(Req),
                 case muse_config:get(mode) of
                     sample ->
                         _ = muse_store:put(Owner, <<"settings">>,
                                            #{<<"id">> => <<"google">>, <<"enabled">> => true,
                                              <<"connectionId">> => muse_ids:uuid()}),
                         {200, #{<<"url">> => null, <<"connected">> => true}};
                     live ->
                         ok_200(muse_google_auth:connect(Owner, Capability =:= <<"write">>))
                 end
         end);
handle(<<"POST">>, [<<"api">>, <<"google">>, <<"disconnect">>], Req) ->
    Owner = muse_http:owner(Req),
    Result = case muse_config:get(mode) of
                 sample ->
                     _ = muse_store:put(Owner, <<"settings">>,
                                        #{<<"id">> => <<"google">>, <<"enabled">> => false}),
                     ok;
                 live ->
                     muse_google_auth:disconnect(Owner)
             end,
    {case Result of
         ok -> {200, #{<<"ok">> => true}};
         Error -> Error
     end, Req};
handle(M, [<<"api">>, <<"browsers">> | Rest], Req) ->
    browser(M, Rest, muse_http:owner(Req), Req);
handle(_, _, _) ->
    next.

browser(<<"POST">>, [], O, Req) ->
    body(Req, {object, [{<<"url">>, ?URL}]},
         fun(#{<<"url">> := Url}) -> created(muse_browser:create(O, Url)) end);
browser(<<"GET">>, [Id], O, Req) ->
    {case muse_browser:get(O, Id) of
         {ok, Session} -> {200, muse_browser:decorate(O, Session)};
         Error -> Error
     end, Req};
browser(<<"POST">>, [Id, <<"navigate">>], O, Req) ->
    body(Req, {object, [{<<"url">>, ?URL}]},
         fun(#{<<"url">> := Url}) -> ok_200(muse_browser:navigate(O, Id, Url)) end);
browser(<<"POST">>, [Id, <<"close">>], O, Req) ->
    {ok_200(muse_browser:close(O, Id)), Req};
browser(<<"GET">>, [Id, <<"read">>], O, Req) ->
    {ok_200(muse_browser:read(O, Id)), Req};
browser(<<"POST">>, [Id, <<"reopen">>], O, Req0) ->
    case muse_http:body(Req0, {object, [{<<"url">>, {optional, ?URL}}]}, allow_empty) of
        {ok, B, Req} -> {ok_200(muse_browser:reopen(O, Id, maps:get(<<"url">>, B, undefined))), Req};
        {error, E, Req} -> {{error, E}, Req}
    end;
browser(<<"POST">>, [Id, <<"import-downloads">>], O, Req) ->
    {ok_200(muse_browser:imports(O, Id)), Req};
browser(<<"GET">>, [Id, <<"preview">>], O, Req) ->
    {case muse_browser:preview(O, Id) of
         {ok, Png} -> {raw, 200, #{<<"content-type">> => <<"image/png">>}, Png};
         Error -> Error
     end, Req};
browser(<<"GET">>, [Id, <<"console">>], O, Req) ->
    {case muse_browser:console(O, Id) of
         {ok, Html} -> {raw, 200, #{<<"content-type">> => <<"text/html; charset=UTF-8">>,
                                    <<"content-security-policy">> => ?CONSOLE_CSP}, Html};
         Error -> Error
     end, Req};
browser(<<"POST">>, [Id, <<"console">>], O, Req0) ->
    case muse_http:json_body(Req0) of
        {ok, Input, Req} ->
            {case muse_browser:input(O, Id, Input) of
                 {ok, _} -> {200, #{<<"ok">> => true}};
                 Error -> Error
             end, Req};
        {error, E, Req} ->
            {{error, E}, Req}
    end;
browser(_, _, _, _) ->
    next.

%% POST /api/files: the last `file` field must be a file part (Hono
%% parseBody); anything else, including a non-multipart body, is 400.
upload(Req0) ->
    case is_multipart(Req0) of
        false ->
            {{error, {400, ?CHOOSE_PDF}}, Req0};
        true ->
            case read_parts(Req0) of
                {ok, {Name, Bytes}, Req} ->
                    {created(muse_files:import(muse_http:owner(Req), Name, Bytes, <<"Uploaded by you">>)), Req};
                {ok, _, Req} ->
                    {{error, {400, ?CHOOSE_PDF}}, Req};
                {error, E, Req} ->
                    {{error, E}, Req}
            end
    end.

is_multipart(Req) ->
    try cowboy_req:parse_header(<<"content-type">>, Req) of
        {<<"multipart">>, <<"form-data">>, Params} -> lists:keymember(<<"boundary">>, 1, Params);
        _ -> false
    catch _:_ -> false
    end.

read_parts(Req) ->
    try read_parts(Req, 0, undefined)
    catch
        error:_ -> {error, {400, ?CHOOSE_PDF}, Req};
        exit:{request_error, _, _} -> {error, {400, ?CHOOSE_PDF}, Req}
    end.

read_parts(Req0, Size, File) ->
    case cowboy_req:read_part(Req0, #{length => 65536, period => 30000}) of
        {done, Req} ->
            {ok, File, Req};
        {ok, Headers, Req1} ->
            case part_body(Req1, Size, <<>>) of
                {ok, Body, Size1, Req} ->
                    File1 = case cow_multipart:form_data(Headers) of
                                {file, <<"file">>, Filename, _Type} -> {Filename, Body};
                                {data, <<"file">>} -> undefined;
                                _ -> File
                            end,
                    read_parts(Req, Size1, File1);
                Error ->
                    Error
            end
    end.

part_body(Req0, Size, Acc) ->
    {More, Data, Req} = cowboy_req:read_part_body(Req0, #{length => 1048576, period => 30000}),
    Size1 = Size + byte_size(Data),
    case Size1 > muse_http:max_body() of
        true -> {error, {413, ?TOO_LARGE}, Req};
        false ->
            Body = <<Acc/binary, Data/binary>>,
            case More of
                ok -> {ok, Body, Size1, Req};
                more -> part_body(Req, Size1, Body)
            end
    end.

body(Req0, Schema, Fun) ->
    case muse_http:body(Req0, Schema) of
        {ok, V, Req} -> {Fun(V), Req};
        {error, E, Req} -> {{error, E}, Req}
    end.

ok_200({ok, V}) -> {200, V};
ok_200({error, E}) -> {error, E}.

created({ok, V}) -> {201, V};
created({error, E}) -> {error, E}.
