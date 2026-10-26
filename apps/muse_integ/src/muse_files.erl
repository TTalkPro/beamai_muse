%% @doc The file library: owned files of any type in folders (OpenMuse
%% files.ts, integrations spec §5; M9-6 extends it beyond PDFs).
%%
%% Metadata lives in Mnesia (`files` records, the OpenMuse Artifact shape
%% with `url: ""`); bytes live in the `blobs` cask, written before the record
%% so a visible record always has its bytes. PDFs keep their key `pdf/<id>`
%% (records and blobs from before M9-6 need no migration); every other file
%% is under `file/<id>`, so a maintenance sweep can tell the two apart.
%%
%% A record has `id, name, mimeType, size, url, createdAt, source` as in
%% OpenMuse, plus `kind` (`pdf | image | audio | video | text | archive |
%% other`), `folderId` (`null` is the root), `starred` and `updatedAt`
%% (rename and move). PDFs also have `pageCount`, `fields` and, for a filled
%% copy, `parentId`; other files have no fields. Records written before M9-6
%% have none of the new keys: `normalize/1` reads them as root, `pdf`, not
%% starred.
%%
%% Two ways in:
%% - `import/4,6` is the PDF path (agent tools, computer export, browser
%%   downloads, fill, the sample): anything that is not a PDF is refused, as
%%   in OpenMuse.
%% - `upload/4` takes any file of at most FILES_MAX_MB (default 25 MB) and
%%   derives the MIME type from its first bytes, its extension and the
%%   uploader's claim, in that order; a PDF goes through the PDF path
%%   (inspected, at most 10 MB and 500 pages).
%%
%% Code that needs a PDF uses `get_pdf/2` / `pdf_bytes/2`, which refuse other
%% kinds with a clear 422.
%%
%% Folders are `file-folders` records `{id, name, parentId, createdAt}`
%% (`parentId` `null` at the root), nested freely; files are moved between
%% them with `update/3`. A folder is deleted only when empty, unless the
%% caller asks for its contents to go too.
%%
%% Keyed imports (agent tools pass an operation key) derive the id from
%% owner + key, so retries return the same artifact. OpenMuse made that
%% race-safe with `link()` on the file system; here concurrent keyed imports of
%% one id are serialised with `global:trans/2`.
-module(muse_files).

-export([import/4, import/6, upload/4, signed/2, list/2, list/1, get/2, get_pdf/2,
         bytes/2, pdf_bytes/2, fill/3, fill/4, update/3, delete/2,
         sanitize_file_name/1, blob_key/1, normalize/1, kind/1, folder_of/1,
         max_bytes/0, detect_mime/3, kind_of_mime/1, serve/2]).
-export([folders/1, folder/2, folder_path/2, create_folder/3, rename_folder/3,
         delete_folder/3]).

-define(PDF_MAX_BYTES, 10485760).
-define(FILES, <<"files">>).
-define(FOLDERS, <<"file-folders">>).
-define(PDF, <<"application/pdf">>).
-define(OCTET, <<"application/octet-stream">>).

-type artifact() :: #{binary() => term()}.
-type folder() :: #{binary() => term()}.
-type kind() :: pdf | image | audio | video | text | archive | other.
-type error() :: {error, {pos_integer(), binary()}}.
-export_type([artifact/0, folder/0, kind/0]).

%%%===================================================================
%%% Files
%%%===================================================================

-spec import(binary(), binary(), binary(), binary()) -> {ok, artifact()} | error().
import(Owner, Name, Bytes, Source) ->
    import(Owner, Name, Bytes, Source, undefined, undefined).

%% @doc Import a PDF (refusing anything else) at the root.
-spec import(binary(), binary(), binary(), binary(), binary() | undefined, binary() | undefined) ->
    {ok, artifact()} | error().
import(Owner, Name, Bytes, Source, ParentId, OperationKey) ->
    keyed(Owner, OperationKey,
          fun(Id) -> store_pdf(Owner, Id, Name, Bytes, Source, #{parent => ParentId, folder => null}) end).

%% @doc Store a file of any type. `Opts`: `folder` (a folder id, `null` or
%% absent for the root), `type` (the MIME type the uploader claims) and
%% `source` (default "Uploaded by you").
-spec upload(binary(), binary(), binary(),
             #{folder => binary() | null, type => binary() | undefined, source => binary()}) ->
    {ok, artifact()} | error().
upload(Owner, Name, Bytes, Opts) ->
    Folder = case maps:get(folder, Opts, null) of
                 undefined -> null;
                 F -> F
             end,
    Source = maps:get(source, Opts, <<"Uploaded by you">>),
    maybe
        ok ?= check_size(Bytes),
        {ok, FolderId} ?= existing_folder(Owner, Folder),
        {ok, Mime} ?= detect_mime(Name, Bytes, maps:get(type, Opts, undefined)),
        case Mime of
            ?PDF -> store_pdf(Owner, muse_ids:uuid(), Name, Bytes, Source, #{parent => undefined, folder => FolderId});
            _ -> store_other(Owner, muse_ids:uuid(), Name, Bytes, Source, Mime, FolderId)
        end
    end.

%% @doc The artifact with a fresh signed content URL.
-spec signed(binary(), artifact()) -> artifact().
signed(Owner, #{<<"id">> := Id} = File) ->
    (normalize(File))#{<<"url">> => muse_signing:sign(Owner, <<"/api/files/", Id/binary, "/content">>)}.

%% @doc All files, most recently updated first, signed.
-spec list(binary()) -> [artifact()].
list(Owner) ->
    [signed(Owner, F) || F <- muse_store:list(Owner, ?FILES)].

%% @doc Like `list/1` but `unsigned` drops the `url` (agent tool payloads).
-spec list(binary(), signed | unsigned) -> [artifact()].
list(Owner, signed) -> list(Owner);
list(Owner, unsigned) -> [maps:remove(<<"url">>, normalize(F)) || F <- muse_store:list(Owner, ?FILES)].

%% @doc The stored (unsigned) record, normalized.
-spec get(binary(), term()) -> {ok, artifact()} | error().
get(Owner, Id) ->
    case muse_ids:is_uuid(Id) of
        false -> not_found();
        true ->
            case muse_store:get(Owner, ?FILES, string:lowercase(Id)) of
                undefined -> not_found();
                File -> {ok, normalize(File)}
            end
    end.

%% @doc `get/2` for code that needs a PDF (fill, inspect, the computer).
-spec get_pdf(binary(), term()) -> {ok, artifact()} | error().
get_pdf(Owner, Id) ->
    case get(Owner, Id) of
        {ok, #{<<"kind">> := <<"pdf">>} = File} -> {ok, File};
        {ok, #{<<"name">> := Name}} ->
            {error, {422, <<"“"/utf8, Name/binary, "” is not a PDF. Only PDFs can be inspected, filled "
                            "or copied to a computer."/utf8>>}};
        Error -> Error
    end.

-spec bytes(binary(), term()) -> {ok, binary()} | error().
bytes(Owner, Id) ->
    case get(Owner, Id) of
        {ok, File} -> blob(File);
        Error -> Error
    end.

-spec pdf_bytes(binary(), term()) -> {ok, binary()} | error().
pdf_bytes(Owner, Id) ->
    case get_pdf(Owner, Id) of
        {ok, File} -> blob(File);
        Error -> Error
    end.

-spec fill(binary(), binary(), #{binary() => binary() | boolean()}) -> {ok, artifact()} | error().
fill(Owner, Id, Values) ->
    fill(Owner, Id, Values, undefined).

%% @doc Save a filled copy (in the source's folder). The name gets
%% ` — filled.pdf`; with an operation key the copy id is stable for the same
%% source and values.
-spec fill(binary(), binary(), #{binary() => binary() | boolean()}, binary() | undefined) ->
    {ok, artifact()} | error().
fill(Owner, Id, Values, OperationKey) ->
    maybe
        {ok, #{<<"id">> := FileId, <<"name">> := Name} = Src} ?= get_pdf(Owner, Id),
        {ok, Bin} ?= blob(Src),
        {ok, Out} ?= muse_pdf:fill(Bin, Values),
        Base = re:replace(Name, <<"\\.pdf$">>, <<>>, [caseless, {return, binary}]),
        Key = case OperationKey of
                  undefined -> undefined;
                  _ ->
                      Entries = [[K, V] || {K, V} <- lists:sort(maps:to_list(Values))],
                      muse_json:encode([<<"fill">>, OperationKey, FileId, Entries])
              end,
        keyed(Owner, Key,
              fun(NewId) ->
                      store_pdf(Owner, NewId, <<Base/binary, " — filled.pdf"/utf8>>, Out,
                                <<"Filled from ", Name/binary>>,
                                #{parent => FileId, folder => folder_of(Src)})
              end)
    end.

%% @doc Rename, move or star a file. `Patch` may hold `name` (sanitized),
%% `folderId` (a folder id or `null` for the root) and `starred`.
%% Renaming and moving touch `updatedAt`; starring does not.
-spec update(binary(), term(), #{binary() => term()}) -> {ok, artifact()} | error().
update(Owner, Id, Patch) ->
    maybe
        {ok, #{<<"id">> := FileId}} ?= get(Owner, Id),
        {ok, Changes} ?= file_changes(Owner, Patch),
        Touch = maps:is_key(<<"name">>, Changes) orelse maps:is_key(<<"folderId">>, Changes),
        Stamp = case Touch of
                    true -> #{<<"updatedAt">> => muse_time:now_iso()};
                    false -> #{}
                end,
        case muse_store:update(Owner, ?FILES, FileId,
                               fun(Old) -> {ok, maps:merge(normalize(Old), maps:merge(Changes, Stamp))} end) of
            undefined -> not_found();
            New -> {ok, New}
        end
    end.

%% @doc Delete a file: the record first, then its bytes (a crash in between
%% leaves an orphan blob, never a record without bytes).
-spec delete(binary(), term()) -> ok | error().
delete(Owner, Id) ->
    case get(Owner, Id) of
        {ok, File} -> remove_file(Owner, File);
        Error -> Error
    end.

%% @doc Last path segment, control characters removed, at most 180 code
%% points; `document.pdf` when nothing is left.
-spec sanitize_file_name(binary()) -> binary().
sanitize_file_name(Name) ->
    sanitize_file_name(Name, <<"document.pdf">>).

sanitize_file_name(Name, Default) ->
    Base = lists:last(binary:split(Name, [<<"/">>, <<"\\">>], [global])),
    Chars = case unicode:characters_to_list(Base) of
                L when is_list(L) -> L;
                _ -> []
            end,
    Clean = lists:sublist([C || C <- Chars, C >= 32, C =/= 127], 180),
    case Clean of
        [] -> Default;
        _ -> unicode:characters_to_binary(Clean)
    end.

%% @doc The blob key of a file: `pdf/<id>` for a PDF (or a bare id, as
%% before M9-6), `file/<id>` for anything else.
-spec blob_key(binary() | artifact()) -> binary().
blob_key(Id) when is_binary(Id) ->
    <<"pdf/", Id/binary>>;
blob_key(#{<<"id">> := Id} = File) ->
    case kind(File) of
        pdf -> blob_key(Id);
        _ -> <<"file/", Id/binary>>
    end.

%% @doc A record with the M9-6 keys filled in for records written before:
%% `kind` from the MIME type (`pdf` without one), root folder, not starred.
-spec normalize(artifact()) -> artifact().
normalize(File) ->
    Mime = maps:get(<<"mimeType">>, File, ?PDF),
    maps:merge(#{<<"mimeType">> => Mime,
                 <<"kind">> => atom_to_binary(kind_of_mime(Mime)),
                 <<"folderId">> => null,
                 <<"starred">> => false},
               File).

-spec kind(artifact()) -> kind().
kind(File) ->
    case maps:get(<<"kind">>, File, undefined) of
        <<"pdf">> -> pdf;
        <<"image">> -> image;
        <<"audio">> -> audio;
        <<"video">> -> video;
        <<"text">> -> text;
        <<"archive">> -> archive;
        <<"other">> -> other;
        _ -> kind_of_mime(maps:get(<<"mimeType">>, File, ?PDF))
    end.

%% @doc The folder id of a file, `null` at the root.
-spec folder_of(artifact()) -> binary() | null.
folder_of(File) ->
    case maps:get(<<"folderId">>, File, null) of
        F when is_binary(F) -> F;
        _ -> null
    end.

%% @doc FILES_MAX_MB in bytes.
-spec max_bytes() -> pos_integer().
max_bytes() ->
    muse_config:get(files_max_mb, 25) * 1048576.

%% @doc The MIME type of a file: magic bytes first, refined or replaced by
%% the extension, then the uploader's claim, then text or binary. A name or
%% claim saying PDF over bytes that are not one is refused.
-spec detect_mime(binary(), binary(), binary() | undefined) -> {ok, binary()} | error().
detect_mime(Name, Bytes, Declared) ->
    Sniffed = sniff(Bytes),
    Ext = ext_mime(Name),
    Claimed = clean_mime(Declared),
    Mime = if
               Sniffed =:= ?PDF -> ?PDF;
               Ext =:= ?PDF; Ext =:= undefined, Claimed =:= ?PDF -> invalid_pdf;
               Sniffed =/= undefined, Ext =/= undefined ->
                   case refines(Sniffed, Ext) of
                       true -> Ext;
                       false -> Sniffed
                   end;
               Sniffed =/= undefined -> Sniffed;
               Ext =/= undefined -> Ext;
               Claimed =/= undefined -> Claimed;
               true ->
                   case is_text(Bytes) of
                       true -> <<"text/plain">>;
                       false -> ?OCTET
                   end
           end,
    case Mime of
        invalid_pdf -> {error, {422, <<"This file is not a valid PDF">>}};
        _ -> {ok, Mime}
    end.

-spec kind_of_mime(binary()) -> kind().
kind_of_mime(?PDF) -> pdf;
kind_of_mime(<<"image/", _/binary>>) -> image;
kind_of_mime(<<"audio/", _/binary>>) -> audio;
kind_of_mime(<<"video/", _/binary>>) -> video;
kind_of_mime(<<"text/", _/binary>>) -> text;
kind_of_mime(M) ->
    case lists:member(M, [<<"application/json">>, <<"application/xml">>, <<"application/javascript">>,
                          <<"application/x-yaml">>, <<"application/toml">>, <<"application/sql">>,
                          <<"application/x-sh">>, <<"application/ld+json">>]) of
        true -> text;
        false ->
            case lists:member(M, [<<"application/zip">>, <<"application/gzip">>, <<"application/x-tar">>,
                                  <<"application/x-7z-compressed">>, <<"application/vnd.rar">>,
                                  <<"application/x-bzip2">>, <<"application/x-xz">>]) of
                true -> archive;
                false -> other
            end
    end.

%% @doc How the content route sends a file: the Content-Type and the
%% disposition. PDFs, raster images, audio and video are inline unless a
%% download is asked for; everything else is an attachment. HTML, SVG and
%% XML are never inline and go out as `application/octet-stream`.
-spec serve(artifact(), boolean()) -> {binary(), inline | attachment}.
serve(File, Download) ->
    Mime = maps:get(<<"mimeType">>, File, ?PDF),
    case {is_active(Mime), Download orelse not is_inline(Mime)} of
        {true, _} -> {?OCTET, attachment};
        {false, true} -> {Mime, attachment};
        {false, false} -> {Mime, inline}
    end.

%%%===================================================================
%%% Folders
%%%===================================================================

%% @doc All folders of the owner, by name.
-spec folders(binary()) -> [folder()].
folders(Owner) ->
    lists:sort(fun(#{<<"name">> := A}, #{<<"name">> := B}) -> string:lowercase(A) =< string:lowercase(B) end,
               muse_store:list(Owner, ?FOLDERS)).

-spec folder(binary(), term()) -> {ok, folder()} | error().
folder(Owner, Id) ->
    case muse_ids:is_uuid(Id) andalso muse_store:get(Owner, ?FOLDERS, string:lowercase(Id)) of
        Folder when is_map(Folder) -> {ok, Folder};
        _ -> folder_not_found()
    end.

%% @doc The folders from the root down to `Id` (breadcrumbs); `[]` for the
%% root or an unknown folder.
-spec folder_path(binary(), binary() | null) -> [folder()].
folder_path(Owner, Id) ->
    folder_path(Owner, Id, []).

folder_path(_Owner, _Id, Acc) when length(Acc) > 64 ->
    Acc;
folder_path(Owner, Id, Acc) when is_binary(Id) ->
    case folder(Owner, Id) of
        {ok, #{<<"parentId">> := Parent} = F} -> folder_path(Owner, Parent, [F | Acc]);
        _ -> Acc
    end;
folder_path(_Owner, _, Acc) ->
    Acc.

-spec create_folder(binary(), term(), binary() | null) -> {ok, folder()} | error().
create_folder(Owner, Name0, Parent0) ->
    maybe
        {ok, Name} ?= folder_name(Name0),
        {ok, Parent} ?= existing_folder(Owner, Parent0),
        ok ?= unique_name(Owner, Parent, Name, undefined),
        Folder = #{<<"id">> => muse_ids:uuid(), <<"name">> => Name, <<"parentId">> => Parent,
                   <<"createdAt">> => muse_time:now_iso()},
        {ok, muse_store:put(Owner, ?FOLDERS, Folder)}
    end.

-spec rename_folder(binary(), term(), term()) -> {ok, folder()} | error().
rename_folder(Owner, Id, Name0) ->
    maybe
        {ok, #{<<"id">> := FolderId, <<"parentId">> := Parent}} ?= folder(Owner, Id),
        {ok, Name} ?= folder_name(Name0),
        ok ?= unique_name(Owner, Parent, Name, FolderId),
        case muse_store:update(Owner, ?FOLDERS, FolderId, fun(F) -> {ok, F#{<<"name">> => Name}} end) of
            undefined -> folder_not_found();
            New -> {ok, New}
        end
    end.

%% @doc Delete a folder. Without `Recursive` it must be empty (409); with it
%% the subfolders and every file in them go too. Returns what was deleted.
-spec delete_folder(binary(), term(), boolean()) ->
    {ok, #{files := non_neg_integer(), folders := pos_integer()}} | error().
delete_folder(Owner, Id, Recursive) ->
    maybe
        {ok, #{<<"id">> := FolderId}} ?= folder(Owner, Id),
        Ids = [FolderId | descendants(muse_store:list(Owner, ?FOLDERS), FolderId)],
        Files = [F || F <- muse_store:list(Owner, ?FILES), lists:member(folder_of(F), Ids)],
        ok ?= case Recursive orelse (Files =:= [] andalso length(Ids) =:= 1) of
                  true -> ok;
                  false -> {error, {409, <<"The folder is not empty">>}}
              end,
        lists:foreach(fun(F) -> remove_file(Owner, normalize(F)) end, Files),
        lists:foreach(fun(I) -> muse_store:remove(Owner, ?FOLDERS, I) end, Ids),
        {ok, #{files => length(Files), folders => length(Ids)}}
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

keyed(_Owner, undefined, Store) ->
    Store(muse_ids:uuid());
keyed(Owner, OperationKey, Store) ->
    Id = muse_ids:deterministic_file_id(Owner, OperationKey),
    global:trans({{?MODULE, Id}, self()},
                 fun() ->
                     case muse_store:get(Owner, ?FILES, Id) of
                         undefined -> Store(Id);
                         Existing -> {ok, signed(Owner, Existing)}
                     end
                 end, [node()], infinity).

store_pdf(Owner, Id, Name, Bytes, Source, #{parent := ParentId, folder := Folder}) ->
    maybe
        ok ?= check_pdf_size(Bytes),
        {ok, #{<<"pageCount">> := Pages, <<"fields">> := Fields}} ?= muse_pdf:inspect(Bytes),
        ok ?= check_pages(Pages),
        Artifact0 = (base(Id, sanitize_file_name(Name), ?PDF, Bytes, Source, Folder))
                        #{<<"pageCount">> => Pages, <<"fields">> => Fields},
        Artifact = case ParentId of
                       undefined -> Artifact0;
                       _ -> Artifact0#{<<"parentId">> => ParentId}
                   end,
        put_file(Owner, Artifact, Bytes)
    end.

store_other(Owner, Id, Name, Bytes, Source, Mime, Folder) ->
    put_file(Owner, base(Id, sanitize_file_name(Name, <<"file">>), Mime, Bytes, Source, Folder), Bytes).

base(Id, Name, Mime, Bytes, Source, Folder) ->
    Now = muse_time:now_iso(),
    #{<<"id">> => Id,
      <<"name">> => Name,
      <<"mimeType">> => Mime,
      <<"kind">> => atom_to_binary(kind_of_mime(Mime)),
      <<"size">> => byte_size(Bytes),
      <<"url">> => <<>>,
      <<"createdAt">> => Now,
      <<"updatedAt">> => Now,
      <<"source">> => Source,
      <<"folderId">> => Folder,
      <<"starred">> => false}.

put_file(Owner, Artifact, Bytes) ->
    case muse_blob:put(blob_key(Artifact), Bytes) of
        ok ->
            _ = muse_store:put(Owner, ?FILES, Artifact),
            {ok, signed(Owner, Artifact)};
        {error, Reason} ->
            error({blob_write_failed, Reason})
    end.

blob(File) ->
    case muse_blob:get(blob_key(File)) of
        {ok, Bin} -> {ok, Bin};
        not_found -> not_found()
    end.

remove_file(Owner, #{<<"id">> := Id} = File) ->
    ok = muse_store:remove(Owner, ?FILES, Id),
    _ = muse_blob:delete(blob_key(File)),
    ok.

file_changes(Owner, Patch) ->
    maps:fold(fun(_, _, {error, _} = E) -> E;
                 (<<"name">>, Name, {ok, Acc}) when is_binary(Name) ->
                     case sanitize_file_name(string:trim(Name), <<>>) of
                         <<>> -> {error, {422, <<"Enter a file name">>}};
                         Clean -> {ok, Acc#{<<"name">> => Clean}}
                     end;
                 (<<"folderId">>, Folder, {ok, Acc}) ->
                     case existing_folder(Owner, Folder) of
                         {ok, F} -> {ok, Acc#{<<"folderId">> => F}};
                         Error -> Error
                     end;
                 (<<"starred">>, S, {ok, Acc}) when is_boolean(S) -> {ok, Acc#{<<"starred">> => S}};
                 (_, _, {ok, Acc}) -> {ok, Acc}
              end, {ok, #{}}, Patch).

%% `null` (or an empty id) is the root.
existing_folder(_Owner, Root) when Root =:= null; Root =:= <<>>; Root =:= undefined ->
    {ok, null};
existing_folder(Owner, Id) ->
    case folder(Owner, Id) of
        {ok, #{<<"id">> := FolderId}} -> {ok, FolderId};
        Error -> Error
    end.

folder_name(Name) when is_binary(Name) ->
    Chars = case unicode:characters_to_list(Name) of
                L when is_list(L) -> string:trim(L);
                _ -> []
            end,
    Bad = lists:any(fun(C) -> C < 32 orelse C =:= 127 orelse C =:= $/ orelse C =:= $\\ end, Chars),
    if
        Chars =:= [] -> {error, {422, <<"Enter a folder name">>}};
        Bad -> {error, {422, <<"Folder names cannot contain / or \\">>}};
        length(Chars) > 80 -> {error, {422, <<"Folder names must be 80 characters or fewer">>}};
        true -> {ok, unicode:characters_to_binary(Chars)}
    end;
folder_name(_) ->
    {error, {422, <<"Enter a folder name">>}}.

unique_name(Owner, Parent, Name, Self) ->
    Lower = string:lowercase(Name),
    case [F || F = #{<<"id">> := I, <<"name">> := N, <<"parentId">> := P} <- muse_store:list(Owner, ?FOLDERS),
               P =:= Parent, I =/= Self, string:lowercase(N) =:= Lower] of
        [] -> ok;
        _ -> {error, {409, <<"A folder with this name already exists here">>}}
    end.

descendants(All, Id) ->
    Children = [C || #{<<"id">> := C, <<"parentId">> := P} <- All, P =:= Id],
    Children ++ lists:append([descendants(All, C) || C <- Children]).

check_size(Bytes) ->
    Max = max_bytes(),
    case byte_size(Bytes) > Max of
        true -> {error, {413, <<"Files must be ", (integer_to_binary(Max div 1048576))/binary, " MB or smaller">>}};
        false -> ok
    end.

check_pdf_size(Bytes) when byte_size(Bytes) > ?PDF_MAX_BYTES ->
    {error, {413, <<"PDFs must be 10 MB or smaller">>}};
check_pdf_size(_) ->
    ok.

check_pages(Pages) when Pages > 500 ->
    {error, {422, <<"PDFs must have 500 pages or fewer">>}};
check_pages(_) ->
    ok.

not_found() ->
    {error, {404, <<"File not found">>}}.

folder_not_found() ->
    {error, {404, <<"Folder not found">>}}.

%% MIME helpers

sniff(<<"%PDF-", _/binary>>) -> ?PDF;
sniff(<<137, "PNG\r\n", 26, "\n", _/binary>>) -> <<"image/png">>;
sniff(<<16#FF, 16#D8, 16#FF, _/binary>>) -> <<"image/jpeg">>;
sniff(<<"GIF8", _/binary>>) -> <<"image/gif">>;
sniff(<<"RIFF", _:4/binary, "WEBP", _/binary>>) -> <<"image/webp">>;
sniff(<<"RIFF", _:4/binary, "WAVE", _/binary>>) -> <<"audio/wav">>;
sniff(<<"BM", _:4/binary, 0, 0, 0, 0, _/binary>>) -> <<"image/bmp">>;
sniff(<<"ID3", _/binary>>) -> <<"audio/mpeg">>;
sniff(<<"fLaC", _/binary>>) -> <<"audio/flac">>;
sniff(<<"OggS", _/binary>>) -> <<"audio/ogg">>;
sniff(<<_:4/binary, "ftyp", Brand:4/binary, _/binary>>) ->
    case Brand of
        <<"M4A ">> -> <<"audio/mp4">>;
        <<"avif">> -> <<"image/avif">>;
        <<"qt  ">> -> <<"video/quicktime">>;
        _ -> <<"video/mp4">>
    end;
sniff(<<16#1A, 16#45, 16#DF, 16#A3, _/binary>>) -> <<"video/webm">>;
sniff(<<"PK", 3, 4, _/binary>>) -> <<"application/zip">>;
sniff(<<16#1F, 16#8B, _/binary>>) -> <<"application/gzip">>;
sniff(<<"7z", 16#BC, 16#AF, 16#27, 16#1C, _/binary>>) -> <<"application/x-7z-compressed">>;
sniff(<<"Rar!", 16#1A, 7, _/binary>>) -> <<"application/vnd.rar">>;
sniff(_) -> undefined.

%% The extension's type is more precise than the magic bytes for media
%% containers and zip-based formats (an .m4a in an MP4 box, an .mkv in EBML,
%% a .docx in a zip); otherwise the bytes win (a PNG named .gif is a PNG).
refines(Sniffed, Ext) ->
    Family = fun(M) -> hd(binary:split(M, <<"/">>)) end,
    Zip = Sniffed =:= <<"application/zip">>,
    Media = lists:member(Family(Sniffed), [<<"audio">>, <<"video">>]),
    (Zip andalso lists:member(Ext, zip_based()))
        orelse (Media andalso lists:member(Family(Ext), [<<"audio">>, <<"video">>])).

zip_based() ->
    [<<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>,
     <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>,
     <<"application/vnd.openxmlformats-officedocument.presentationml.presentation">>,
     <<"application/vnd.oasis.opendocument.text">>,
     <<"application/vnd.oasis.opendocument.spreadsheet">>,
     <<"application/vnd.oasis.opendocument.presentation">>,
     <<"application/epub+zip">>, <<"application/java-archive">>].

ext_mime(Name) ->
    case string:lowercase(filename:extension(Name)) of
        <<".", Ext/binary>> -> maps:get(Ext, extensions(), undefined);
        _ -> undefined
    end.

extensions() ->
    #{<<"pdf">> => ?PDF,
      <<"png">> => <<"image/png">>, <<"jpg">> => <<"image/jpeg">>, <<"jpeg">> => <<"image/jpeg">>,
      <<"gif">> => <<"image/gif">>, <<"webp">> => <<"image/webp">>, <<"bmp">> => <<"image/bmp">>,
      <<"avif">> => <<"image/avif">>, <<"ico">> => <<"image/x-icon">>, <<"svg">> => <<"image/svg+xml">>,
      <<"heic">> => <<"image/heic">>, <<"tif">> => <<"image/tiff">>, <<"tiff">> => <<"image/tiff">>,
      <<"mp3">> => <<"audio/mpeg">>, <<"wav">> => <<"audio/wav">>, <<"ogg">> => <<"audio/ogg">>,
      <<"oga">> => <<"audio/ogg">>, <<"opus">> => <<"audio/ogg">>, <<"m4a">> => <<"audio/mp4">>,
      <<"aac">> => <<"audio/aac">>, <<"flac">> => <<"audio/flac">>, <<"weba">> => <<"audio/webm">>,
      <<"mp4">> => <<"video/mp4">>, <<"m4v">> => <<"video/mp4">>, <<"webm">> => <<"video/webm">>,
      <<"ogv">> => <<"video/ogg">>, <<"mov">> => <<"video/quicktime">>, <<"mkv">> => <<"video/x-matroska">>,
      <<"avi">> => <<"video/x-msvideo">>,
      <<"txt">> => <<"text/plain">>, <<"log">> => <<"text/plain">>, <<"md">> => <<"text/markdown">>,
      <<"markdown">> => <<"text/markdown">>, <<"csv">> => <<"text/csv">>, <<"tsv">> => <<"text/tab-separated-values">>,
      <<"json">> => <<"application/json">>, <<"xml">> => <<"application/xml">>, <<"yaml">> => <<"application/x-yaml">>,
      <<"yml">> => <<"application/x-yaml">>, <<"toml">> => <<"application/toml">>, <<"ini">> => <<"text/plain">>,
      <<"conf">> => <<"text/plain">>, <<"sql">> => <<"application/sql">>, <<"sh">> => <<"application/x-sh">>,
      <<"html">> => <<"text/html">>, <<"htm">> => <<"text/html">>, <<"css">> => <<"text/css">>,
      <<"js">> => <<"application/javascript">>, <<"mjs">> => <<"application/javascript">>,
      <<"ts">> => <<"text/plain">>, <<"erl">> => <<"text/plain">>, <<"hrl">> => <<"text/plain">>,
      <<"py">> => <<"text/plain">>, <<"rb">> => <<"text/plain">>, <<"go">> => <<"text/plain">>,
      <<"rs">> => <<"text/plain">>, <<"c">> => <<"text/plain">>, <<"h">> => <<"text/plain">>,
      <<"java">> => <<"text/plain">>, <<"ex">> => <<"text/plain">>, <<"exs">> => <<"text/plain">>,
      <<"zip">> => <<"application/zip">>, <<"gz">> => <<"application/gzip">>, <<"tgz">> => <<"application/gzip">>,
      <<"tar">> => <<"application/x-tar">>, <<"7z">> => <<"application/x-7z-compressed">>,
      <<"rar">> => <<"application/vnd.rar">>, <<"bz2">> => <<"application/x-bzip2">>, <<"xz">> => <<"application/x-xz">>,
      <<"doc">> => <<"application/msword">>, <<"xls">> => <<"application/vnd.ms-excel">>,
      <<"ppt">> => <<"application/vnd.ms-powerpoint">>,
      <<"docx">> => <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>,
      <<"xlsx">> => <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>,
      <<"pptx">> => <<"application/vnd.openxmlformats-officedocument.presentationml.presentation">>,
      <<"odt">> => <<"application/vnd.oasis.opendocument.text">>,
      <<"ods">> => <<"application/vnd.oasis.opendocument.spreadsheet">>,
      <<"odp">> => <<"application/vnd.oasis.opendocument.presentation">>,
      <<"epub">> => <<"application/epub+zip">>, <<"jar">> => <<"application/java-archive">>}.

%% A claimed type: `type/subtype`, lower case, parameters dropped.
clean_mime(undefined) -> undefined;
clean_mime(T) when is_binary(T) ->
    M = string:lowercase(string:trim(hd(binary:split(T, <<";">>)))),
    case re:run(M, <<"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$">>, [{capture, none}]) of
        match when M =/= ?OCTET -> M;
        _ -> undefined
    end;
clean_mime(_) -> undefined.

%% UTF-8 without control characters other than tab, line breaks, form feed
%% and escape in the first 8 KB (a cut multibyte character at the end is
%% fine).
is_text(Bytes) ->
    Head = binary:part(Bytes, 0, min(byte_size(Bytes), 8192)),
    lists:all(fun(C) -> C >= 32 orelse lists:member(C, [9, 10, 12, 13, 27]) end, binary_to_list(Head)) andalso
        case unicode:characters_to_list(Head) of
            L when is_list(L) -> true;
            {incomplete, _, _} -> true;
            _ -> false
        end.

%% Types a browser would run as a document (scripts): never inline.
is_active(Mime) ->
    lists:member(Mime, [<<"text/html">>, <<"application/xhtml+xml">>, <<"image/svg+xml">>,
                        <<"text/xml">>, <<"application/xml">>, <<"text/javascript">>,
                        <<"application/javascript">>]).

is_inline(?PDF) -> true;
is_inline(<<"audio/", _/binary>>) -> true;
is_inline(<<"video/", _/binary>>) -> true;
is_inline(Mime) ->
    lists:member(Mime, [<<"image/png">>, <<"image/jpeg">>, <<"image/gif">>, <<"image/webp">>,
                        <<"image/avif">>, <<"image/bmp">>, <<"image/x-icon">>]).
