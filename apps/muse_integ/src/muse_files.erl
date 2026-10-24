%% @doc Documents: owned PDFs (OpenMuse files.ts, integrations spec §5).
%%
%% Metadata lives in Mnesia (`files` records, the Artifact shape with
%% `url: ""`); bytes live in the `blobs` cask under `pdf/<id>`, written before
%% the record so a visible record always has its bytes.
%%
%% Keyed imports (agent tools pass an operation key) derive the id from
%% owner + key, so retries return the same artifact. OpenMuse made that
%% race-safe with `link()` on the file system; here concurrent keyed imports of
%% one id are serialised with `global:trans/2`.
-module(muse_files).

-export([import/4, import/6, signed/2, list/2, list/1, get/2, bytes/2,
         fill/3, fill/4, sanitize_file_name/1, blob_key/1]).

-define(MAX_BYTES, 10485760).

-type artifact() :: #{binary() => term()}.
-type error() :: {error, {pos_integer(), binary()}}.

-spec import(binary(), binary(), binary(), binary()) -> {ok, artifact()} | error().
import(Owner, Name, Bytes, Source) ->
    import(Owner, Name, Bytes, Source, undefined, undefined).

-spec import(binary(), binary(), binary(), binary(), binary() | undefined, binary() | undefined) ->
    {ok, artifact()} | error().
import(Owner, Name, Bytes, Source, ParentId, undefined) ->
    store(Owner, muse_ids:uuid(), Name, Bytes, Source, ParentId);
import(Owner, Name, Bytes, Source, ParentId, OperationKey) ->
    Id = muse_ids:deterministic_file_id(Owner, OperationKey),
    global:trans({{?MODULE, Id}, self()},
                 fun() ->
                     case muse_store:get(Owner, <<"files">>, Id) of
                         undefined -> store(Owner, Id, Name, Bytes, Source, ParentId);
                         Existing -> {ok, signed(Owner, Existing)}
                     end
                 end, [node()], infinity).

%% @doc The artifact with a fresh signed content URL.
-spec signed(binary(), artifact()) -> artifact().
signed(Owner, #{<<"id">> := Id} = File) ->
    File#{<<"url">> => muse_signing:sign(Owner, <<"/api/files/", Id/binary, "/content">>)}.

%% @doc All documents, most recently updated first, signed.
-spec list(binary()) -> [artifact()].
list(Owner) ->
    [signed(Owner, F) || F <- muse_store:list(Owner, <<"files">>)].

%% @doc Like `list/1` but `unsigned` drops the `url` (agent tool payloads).
-spec list(binary(), signed | unsigned) -> [artifact()].
list(Owner, signed) -> list(Owner);
list(Owner, unsigned) -> [maps:remove(<<"url">>, F) || F <- muse_store:list(Owner, <<"files">>)].

%% @doc The stored (unsigned) record.
-spec get(binary(), term()) -> {ok, artifact()} | error().
get(Owner, Id) ->
    case muse_ids:is_uuid(Id) of
        false -> not_found();
        true ->
            case muse_store:get(Owner, <<"files">>, string:lowercase(Id)) of
                undefined -> not_found();
                File -> {ok, File}
            end
    end.

-spec bytes(binary(), term()) -> {ok, binary()} | error().
bytes(Owner, Id) ->
    case get(Owner, Id) of
        {ok, #{<<"id">> := FileId}} ->
            case muse_blob:get(blob_key(FileId)) of
                {ok, Bin} -> {ok, Bin};
                not_found -> not_found()
            end;
        Error ->
            Error
    end.

-spec fill(binary(), binary(), #{binary() => binary() | boolean()}) -> {ok, artifact()} | error().
fill(Owner, Id, Values) ->
    fill(Owner, Id, Values, undefined).

%% @doc Save a filled copy. The name gets ` — filled.pdf`; with an operation
%% key the copy id is stable for the same source and values.
-spec fill(binary(), binary(), #{binary() => binary() | boolean()}, binary() | undefined) ->
    {ok, artifact()} | error().
fill(Owner, Id, Values, OperationKey) ->
    maybe
        {ok, #{<<"id">> := FileId, <<"name">> := Name}} ?= get(Owner, Id),
        {ok, Bin} ?= bytes(Owner, FileId),
        {ok, Out} ?= muse_pdf:fill(Bin, Values),
        Base = re:replace(Name, <<"\\.pdf$">>, <<>>, [caseless, {return, binary}]),
        Key = case OperationKey of
                  undefined -> undefined;
                  _ ->
                      Entries = [[K, V] || {K, V} <- lists:sort(maps:to_list(Values))],
                      muse_json:encode([<<"fill">>, OperationKey, FileId, Entries])
              end,
        import(Owner, <<Base/binary, " — filled.pdf"/utf8>>, Out,
               <<"Filled from ", Name/binary>>, FileId, Key)
    end.

%% @doc Last path segment, control characters removed, at most 180 code
%% points; `document.pdf` when nothing is left.
-spec sanitize_file_name(binary()) -> binary().
sanitize_file_name(Name) ->
    Base = lists:last(binary:split(Name, [<<"/">>, <<"\\">>], [global])),
    Chars = case unicode:characters_to_list(Base) of
                L when is_list(L) -> L;
                _ -> []
            end,
    Clean = lists:sublist([C || C <- Chars, C >= 32, C =/= 127], 180),
    case Clean of
        [] -> <<"document.pdf">>;
        _ -> unicode:characters_to_binary(Clean)
    end.

-spec blob_key(binary()) -> binary().
blob_key(Id) ->
    <<"pdf/", Id/binary>>.

%% Internal

store(Owner, Id, Name, Bytes, Source, ParentId) ->
    maybe
        ok ?= check_size(Bytes),
        {ok, #{<<"pageCount">> := Pages, <<"fields">> := Fields}} ?= muse_pdf:inspect(Bytes),
        ok ?= check_pages(Pages),
        ok ?= muse_blob:put(blob_key(Id), Bytes),
        Artifact0 = #{<<"id">> => Id,
                      <<"name">> => sanitize_file_name(Name),
                      <<"mimeType">> => <<"application/pdf">>,
                      <<"size">> => byte_size(Bytes),
                      <<"pageCount">> => Pages,
                      <<"fields">> => Fields,
                      <<"url">> => <<>>,
                      <<"createdAt">> => muse_time:now_iso(),
                      <<"source">> => Source},
        Artifact = case ParentId of
                       undefined -> Artifact0;
                       _ -> Artifact0#{<<"parentId">> => ParentId}
                   end,
        _ = muse_store:put(Owner, <<"files">>, Artifact),
        {ok, signed(Owner, Artifact)}
    else
        {error, {_, _}} = Error -> Error;
        {error, Reason} -> error({blob_write_failed, Reason})
    end.

check_size(Bytes) when byte_size(Bytes) > ?MAX_BYTES ->
    {error, {413, <<"PDFs must be 10 MB or smaller">>}};
check_size(_) ->
    ok.

check_pages(Pages) when Pages > 500 ->
    {error, {422, <<"PDFs must have 500 pages or fewer">>}};
check_pages(_) ->
    ok.

not_found() ->
    {error, {404, <<"File not found">>}}.
