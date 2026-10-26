%% @doc Files and browser routes (OpenMuse app.ts; integrations spec
%% §2.6 #16–#31, §5, §7.4, §9.1, §9.4). OpenMuse's mail attachment import
%% and account connect routes are gone (docs/DIFFERENCES.md).
%%
%% Files (M9-6, designs/04-integrations.md §2) keep OpenMuse's routes for
%% PDFs and add, in the same style:
%% - `GET /api/files[?folder=<id>|root]` the listing (`{"files": [...]}`);
%% - `POST /api/files` any type of file (a `folder` field or `?folder=`);
%% - `GET /api/files/:id/content[?download=1]` with the file's own type,
%%   inline only for PDFs, raster images, audio and video, always
%%   `x-content-type-options: nosniff`;
%% - `PATCH /api/files/:id` `{name?, folderId?, starred?}`, `DELETE`;
%% - `GET|POST /api/file-folders`, `PATCH|DELETE /api/file-folders/:id`
%%   (`?recursive=true` deletes a folder with its contents).
%%
%% `GET /api/files/:id/content` and `/api/browsers/:id/(preview|console)` are
%% also reached through signed URLs; muse_api has already resolved the owner.
-module(muse_api_integ).

-export([handle/3, read_upload/1, read_upload/2]).

-define(CHOOSE_FILE, <<"Choose a file">>).
-define(TOO_LARGE, <<"Request is too large">>).
-define(URL, {string, #{url => true, max => 4096}}).
-define(CONSOLE_CSP, <<"default-src 'self'; img-src 'self' blob:; script-src 'unsafe-inline'; "
                       "style-src 'unsafe-inline'; connect-src 'self'">>).

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(<<"GET">>, [<<"api">>, <<"files">>], Req) ->
    O = muse_http:owner(Req),
    {case muse_http:query(<<"folder">>, Req) of
         undefined -> {200, #{<<"files">> => muse_files:list(O)}};
         F when F =:= <<"root">>; F =:= <<>> -> {200, #{<<"files">> => in_folder(O, null)}};
         F -> case muse_files:folder(O, F) of
                  {ok, #{<<"id">> := FolderId}} -> {200, #{<<"files">> => in_folder(O, FolderId)}};
                  Error -> Error
              end
     end, Req};
handle(<<"POST">>, [<<"api">>, <<"files">>], Req) ->
    upload(Req);
handle(<<"GET">>, [<<"api">>, <<"files">>, Id, <<"content">>], Req) ->
    O = muse_http:owner(Req),
    Download = lists:member(muse_http:query(<<"download">>, Req), [<<"1">>, <<"true">>]),
    {maybe
         {ok, #{<<"id">> := FileId, <<"name">> := Name} = File} ?= muse_files:get(O, Id),
         {ok, Bytes} ?= muse_files:bytes(O, FileId),
         {Type, Disposition} = muse_files:serve(File, Download),
         {raw, 200, #{<<"content-type">> => Type,
                      <<"x-content-type-options">> => <<"nosniff">>,
                      <<"content-disposition">> =>
                          <<(atom_to_binary(Disposition))/binary, "; filename*=UTF-8''",
                            (muse_signing:encode_uri_component(Name))/binary>>},
          Bytes}
     end, Req};
handle(<<"PATCH">>, [<<"api">>, <<"files">>, Id], Req) ->
    body(Req, {object, [{<<"name">>, {optional, {string, #{min => 1, max => 400}}}},
                        {<<"folderId">>, {optional, {nullable, {string, #{max => 64}}}}},
                        {<<"starred">>, {optional, boolean}}]},
         fun(Patch) -> ok_200(muse_files:update(muse_http:owner(Req), Id, Patch)) end);
handle(<<"DELETE">>, [<<"api">>, <<"files">>, Id], Req) ->
    {case muse_files:delete(muse_http:owner(Req), Id) of
         ok -> {200, #{<<"ok">> => true}};
         Error -> Error
     end, Req};
handle(M, [<<"api">>, <<"file-folders">> | Rest], Req) ->
    folders(M, Rest, muse_http:owner(Req), Req);
handle(<<"POST">>, [<<"api">>, <<"files">>, Id, <<"fill">>], Req) ->
    body(Req, {object, [{<<"fields">>, {record, {union, [{string, #{}}, boolean]}, #{}}}]},
         fun(#{<<"fields">> := Fields}) -> created(muse_files:fill(muse_http:owner(Req), Id, Fields)) end);
handle(M, [<<"api">>, <<"browsers">> | Rest], Req) ->
    browser(M, Rest, muse_http:owner(Req), Req);
handle(_, _, _) ->
    next.

folders(<<"GET">>, [], O, Req) ->
    {{200, #{<<"folders">> => muse_files:folders(O)}}, Req};
folders(<<"POST">>, [], O, Req) ->
    body(Req, {object, [{<<"name">>, {string, #{max => 400}}},
                        {<<"parentId">>, {optional, {nullable, {string, #{max => 64}}}}}]},
         fun(#{<<"name">> := Name} = B) ->
                 created(muse_files:create_folder(O, Name, maps:get(<<"parentId">>, B, null)))
         end);
folders(<<"PATCH">>, [Id], O, Req) ->
    body(Req, {object, [{<<"name">>, {string, #{max => 400}}}]},
         fun(#{<<"name">> := Name}) -> ok_200(muse_files:rename_folder(O, Id, Name)) end);
folders(<<"DELETE">>, [Id], O, Req) ->
    Recursive = muse_http:query(<<"recursive">>, Req) =:= <<"true">>,
    {case muse_files:delete_folder(O, Id, Recursive) of
         {ok, #{files := Files, folders := Folders}} ->
             {200, #{<<"ok">> => true, <<"files">> => Files, <<"folders">> => Folders}};
         Error -> Error
     end, Req};
folders(_, _, _, _) ->
    next.

in_folder(O, Folder) ->
    [F || F <- muse_files:list(O), muse_files:folder_of(F) =:= Folder].

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
%% parseBody); anything else, including a non-multipart body, is 400. The
%% folder is the `folder` field, else `?folder=`; the parts may be as large
%% as FILES_MAX_MB (muse_files checks the exact limit).
upload(Req0) ->
    case is_multipart(Req0) of
        false ->
            {{error, {400, ?CHOOSE_FILE}}, Req0};
        true ->
            case read_parts(Req0, muse_files:max_bytes() + 65536) of
                {ok, #{file := {Name, Bytes, Type}} = Parts, Req} ->
                    Folder = maps:get(folder, Parts, muse_http:query(<<"folder">>, Req)),
                    {created(muse_files:upload(muse_http:owner(Req), Name, Bytes,
                                               #{folder => Folder, type => Type})), Req};
                {ok, _, Req} ->
                    {{error, {400, ?CHOOSE_FILE}}, Req};
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

%% @doc The `file` part of a multipart body (at most muse_http:max_body/0):
%% its filename and bytes, `undefined` without one; also used by the
%% computer page's upload (muse_ui_computer_files).
-spec read_upload(cowboy_req:req()) ->
          {ok, {binary(), binary()} | undefined, cowboy_req:req()} | {error, {400 | 413, binary()}, cowboy_req:req()}.
read_upload(Req0) ->
    case read_upload(Req0, muse_http:max_body()) of
        {ok, {Name, Bytes, _Type}, Req} -> {ok, {Name, Bytes}, Req};
        Other -> Other
    end.

%% @doc As `read_upload/1' with a size limit, also giving the claimed type
%% (the mail compose window's uploads, at most FILES_MAX_MB).
-spec read_upload(cowboy_req:req(), pos_integer()) ->
          {ok, {binary(), binary(), binary() | undefined} | undefined, cowboy_req:req()}
          | {error, {400 | 413, binary()}, cowboy_req:req()}.
read_upload(Req0, Limit) ->
    case is_multipart(Req0) of
        true ->
            case read_parts(Req0, Limit) of
                {ok, #{file := {Name, Bytes, Type}}, Req} -> {ok, {Name, Bytes, Type}, Req};
                {ok, _, Req} -> {ok, undefined, Req};
                Error -> Error
            end;
        false -> {error, {400, <<"Send the file as multipart/form-data">>}, Req0}
    end.

%% The parts of a multipart body, at most `Limit` bytes in all: `file`
%% (name, bytes and claimed type of the last `file` part) and `folder`.
read_parts(Req, Limit) ->
    try read_parts(Req, Limit, 0, #{})
    catch
        error:_ -> {error, {400, ?CHOOSE_FILE}, Req};
        exit:{request_error, _, _} -> {error, {400, ?CHOOSE_FILE}, Req}
    end.

read_parts(Req0, Limit, Size, Parts) ->
    case cowboy_req:read_part(Req0, #{length => 65536, period => 30000}) of
        {done, Req} ->
            {ok, Parts, Req};
        {ok, Headers, Req1} ->
            case part_body(Req1, Limit, Size, <<>>) of
                {ok, Body, Size1, Req} ->
                    Parts1 = case cow_multipart:form_data(Headers) of
                                 {file, <<"file">>, Filename, Type} -> Parts#{file => {Filename, Body, Type}};
                                 {data, <<"file">>} -> maps:remove(file, Parts);
                                 {data, <<"folder">>} -> Parts#{folder => Body};
                                 _ -> Parts
                             end,
                    read_parts(Req, Limit, Size1, Parts1);
                Error ->
                    Error
            end
    end.

part_body(Req0, Limit, Size, Acc) ->
    {More, Data, Req} = cowboy_req:read_part_body(Req0, #{length => 1048576, period => 30000}),
    Size1 = Size + byte_size(Data),
    case Size1 > Limit of
        true -> {error, {413, too_large(Limit)}, Req};
        false ->
            Body = <<Acc/binary, Data/binary>>,
            case More of
                ok -> {ok, Body, Size1, Req};
                more -> part_body(Req, Limit, Size1, Body)
            end
    end.

too_large(Limit) ->
    <<?TOO_LARGE/binary, "; files must be ", (integer_to_binary(Limit div 1048576))/binary, " MB or smaller">>.

body(Req0, Schema, Fun) ->
    case muse_http:body(Req0, Schema) of
        {ok, V, Req} -> {Fun(V), Req};
        {error, E, Req} -> {{error, E}, Req}
    end.

ok_200({ok, V}) -> {200, V};
ok_200({error, E}) -> {error, E}.

created({ok, V}) -> {201, V};
created({error, E}) -> {error, E}.
