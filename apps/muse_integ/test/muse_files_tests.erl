-module(muse_files_tests).
-include_lib("eunit/include/eunit.hrl").

-define(O, <<"local-user">>).

files_test_() ->
    {setup, fun() -> muse_integ_test_env:start(#{}) end, fun muse_integ_test_env:stop/1,
     [fun import_get_list/0, fun keyed_import_is_idempotent/0, fun concurrent_keyed_import/0,
      fun fill_named_and_keyed/0, fun errors/0, fun upload_any_type/0, fun upload_pdf_and_limits/0,
      fun folders_and_moves/0, fun delete_folder_with_contents/0, fun old_records/0]}.

sample() ->
    {ok, Bin} = muse_pdf:sample(),
    Bin.

import_get_list() ->
    {ok, #{<<"id">> := Id} = A} = muse_files:import(?O, <<"dir/Trip slip.pdf">>, sample(), <<"Uploaded by you">>),
    ?assert(muse_ids:is_uuid(Id)),
    ?assertMatch(#{<<"name">> := <<"Trip slip.pdf">>, <<"mimeType">> := <<"application/pdf">>,
                   <<"pageCount">> := 2, <<"source">> := <<"Uploaded by you">>}, A),
    ?assertEqual(6, length(maps:get(<<"fields">>, A))),
    ?assertNot(maps:is_key(<<"parentId">>, A)),
    ?assertMatch(<<"http://localhost:8787/api/files/", _/binary>>, maps:get(<<"url">>, A)),
    {ok, Stored} = muse_files:get(?O, Id),
    ?assertEqual(<<>>, maps:get(<<"url">>, Stored)),
    ?assertEqual({ok, sample()}, muse_files:bytes(?O, Id)),
    ?assertEqual({ok, Stored}, muse_files:get(?O, string:uppercase(Id))),
    ?assert(lists:member(Id, [I || #{<<"id">> := I} <- muse_files:list(?O)])),
    [#{<<"url">> := _} | _] = muse_files:list(?O),
    ?assertNot(lists:any(fun(F) -> maps:is_key(<<"url">>, F) end, muse_files:list(?O, unsigned))),
    ?assertEqual({error, {404, <<"File not found">>}}, muse_files:get(<<"someone-else">>, Id)).

keyed_import_is_idempotent() ->
    {ok, A} = muse_files:import(?O, <<"a.pdf">>, sample(), <<"s">>, undefined, <<"op-1">>),
    {ok, B} = muse_files:import(?O, <<"other name.pdf">>, sample(), <<"s2">>, undefined, <<"op-1">>),
    ?assertEqual(maps:get(<<"id">>, A), maps:get(<<"id">>, B)),
    ?assertEqual(<<"a.pdf">>, maps:get(<<"name">>, B)),
    ?assertEqual(muse_ids:deterministic_file_id(?O, <<"op-1">>), maps:get(<<"id">>, A)).

concurrent_keyed_import() ->
    Self = self(),
    Bin = sample(),
    [spawn(fun() -> Self ! {done, muse_files:import(?O, <<"race.pdf">>, Bin, <<"s">>, undefined, <<"race">>)} end)
     || _ <- lists:seq(1, 8)],
    Ids = lists:usort([Id || _ <- lists:seq(1, 8), {ok, #{<<"id">> := Id}} <- [receive {done, R} -> R end]]),
    ?assertMatch([_], Ids).

fill_named_and_keyed() ->
    {ok, #{<<"id">> := Src}} = muse_files:import(?O, <<"Permission.PDF">>, sample(), <<"s">>),
    Values = #{<<"participant_name">> => <<"Sam">>, <<"permission_granted">> => true},
    {ok, Filled} = muse_files:fill(?O, Src, Values, <<"model:t1:fill_pdf">>),
    ?assertMatch(#{<<"name">> := <<"Permission — filled.pdf"/utf8>>, <<"parentId">> := Src,
                   <<"source">> := <<"Filled from Permission.PDF">>}, Filled),
    Fields = maps:from_list([{N, V} || #{<<"name">> := N, <<"value">> := V} <- maps:get(<<"fields">>, Filled)]),
    ?assertEqual(<<"Sam">>, maps:get(<<"participant_name">>, Fields)),
    ?assertEqual(<<"true">>, maps:get(<<"permission_granted">>, Fields)),
    {ok, Again} = muse_files:fill(?O, Src, Values, <<"model:t1:fill_pdf">>),
    ?assertEqual(maps:get(<<"id">>, Filled), maps:get(<<"id">>, Again)),
    {ok, Fresh} = muse_files:fill(?O, Src, Values),
    ?assertNotEqual(maps:get(<<"id">>, Filled), maps:get(<<"id">>, Fresh)),
    ?assertMatch({error, {422, <<"Unknown PDF field: nope">>}},
                 muse_files:fill(?O, Src, #{<<"nope">> => <<"x">>})).

errors() ->
    ?assertEqual({error, {404, <<"File not found">>}}, muse_files:get(?O, <<"../../etc/passwd">>)),
    ?assertEqual({error, {404, <<"File not found">>}}, muse_files:bytes(?O, muse_ids:uuid())),
    Big = <<"%PDF-", (binary:copy(<<0>>, 10485760))/binary>>,
    ?assertEqual({error, {413, <<"PDFs must be 10 MB or smaller">>}}, muse_files:import(?O, <<"big.pdf">>, Big, <<"s">>)),
    ?assertMatch({error, {422, _}}, muse_files:import(?O, <<"x.pdf">>, <<"not a pdf">>, <<"s">>)).

sanitize_test_() ->
    S = fun muse_files:sanitize_file_name/1,
    [?_assertEqual(<<"c.pdf">>, S(<<"a/b\\c.pdf">>)),
     ?_assertEqual(<<"ab.pdf">>, S(<<"a", 0, 31, "b", 127, ".pdf">>)),
     ?_assertEqual(<<"document.pdf">>, S(<<"dir/">>)),
     ?_assertEqual(<<"document.pdf">>, S(<<1, 2>>)),
     ?_assertEqual(180, string:length(S(binary:copy(<<"汉"/utf8>>, 200)))),
     ?_assertEqual(<<"🙂.pdf"/utf8>>, S(<<"🙂.pdf"/utf8>>))].

%% M9-6: any file type, folders, stars, records from before M9-6

-define(PNG, <<137, "PNG\r\n", 26, "\n", 0, 0, 0, 13, "IHDR">>).

upload_any_type() ->
    {ok, #{<<"id">> := Id} = A} = muse_files:upload(?O, <<"photos/cat.png">>, ?PNG, #{type => <<"image/png">>}),
    ?assertMatch(#{<<"name">> := <<"cat.png">>, <<"mimeType">> := <<"image/png">>, <<"kind">> := <<"image">>,
                   <<"folderId">> := null, <<"starred">> := false, <<"source">> := <<"Uploaded by you">>,
                   <<"size">> := 16, <<"url">> := <<"http://localhost:8787/api/files/", _/binary>>}, A),
    ?assertNot(maps:is_key(<<"fields">>, A)),
    ?assertNot(maps:is_key(<<"pageCount">>, A)),
    ?assertEqual({ok, ?PNG}, muse_files:bytes(?O, Id)),
    ?assertEqual({ok, ?PNG}, muse_blob:get(<<"file/", Id/binary>>)),
    ?assertEqual(not_found, muse_blob:get(<<"pdf/", Id/binary>>)),
    %% code that needs a PDF refuses it
    NotPdf = {error, {422, <<"“cat.png” is not a PDF. Only PDFs can be inspected, filled or copied to a computer."/utf8>>}},
    ?assertEqual(NotPdf, muse_files:get_pdf(?O, Id)),
    ?assertEqual(NotPdf, muse_files:pdf_bytes(?O, Id)),
    ?assertEqual(NotPdf, muse_files:fill(?O, Id, #{})),
    %% the type comes from the bytes, then the extension, then the claim
    {ok, #{<<"mimeType">> := <<"text/plain">>, <<"kind">> := <<"text">>}} =
        muse_files:upload(?O, <<"README">>, <<"hello 你好\n"/utf8>>, #{}),
    {ok, #{<<"mimeType">> := <<"application/octet-stream">>, <<"kind">> := <<"other">>}} =
        muse_files:upload(?O, <<"blob">>, <<0, 1, 2, 255>>, #{}),
    {ok, #{<<"mimeType">> := <<"text/csv">>}} = muse_files:upload(?O, <<"a.csv">>, <<"a,b\n">>, #{type => <<"text/plain">>}),
    {ok, #{<<"mimeType">> := <<"audio/x-custom">>, <<"kind">> := <<"audio">>}} =
        muse_files:upload(?O, <<"noext">>, <<0, 9>>, #{type => <<"Audio/X-Custom; q=1">>}),
    {ok, #{<<"mimeType">> := <<"text/html">>, <<"kind">> := <<"text">>}} =
        muse_files:upload(?O, <<"page.html">>, <<"<script>alert(1)</script>">>, #{}),
    %% a "PDF" that is not one
    ?assertEqual({error, {422, <<"This file is not a valid PDF">>}},
                 muse_files:upload(?O, <<"x.pdf">>, <<"not a pdf">>, #{})),
    ?assertEqual({error, {422, <<"This file is not a valid PDF">>}},
                 muse_files:upload(?O, <<"x">>, <<"not a pdf">>, #{type => <<"application/pdf">>})),
    ?assertEqual({error, {404, <<"Folder not found">>}},
                 muse_files:upload(?O, <<"a.txt">>, <<"x">>, #{folder => muse_ids:uuid()})).

upload_pdf_and_limits() ->
    {ok, #{<<"id">> := Id} = A} = muse_files:upload(?O, <<"slip">>, sample(), #{type => <<"application/octet-stream">>}),
    ?assertMatch(#{<<"kind">> := <<"pdf">>, <<"mimeType">> := <<"application/pdf">>, <<"pageCount">> := 2}, A),
    ?assertEqual(6, length(maps:get(<<"fields">>, A))),
    ?assertEqual({ok, sample()}, muse_blob:get(<<"pdf/", Id/binary>>)),
    {ok, _} = muse_files:get_pdf(?O, Id),
    %% FILES_MAX_MB
    Config = muse_config:all(),
    try
        muse_config:set(Config#{files_max_mb => 1}),
        ?assertEqual(1048576, muse_files:max_bytes()),
        ?assertEqual({error, {413, <<"Files must be 1 MB or smaller">>}},
                     muse_files:upload(?O, <<"big.bin">>, binary:copy(<<1>>, 1048577), #{})),
        {ok, _} = muse_files:upload(?O, <<"ok.bin">>, binary:copy(<<1>>, 1048576), #{})
    after
        muse_config:set(Config)
    end,
    ?assertEqual(25 * 1048576, muse_files:max_bytes()),
    %% PDFs stay at 10 MB
    Big = <<"%PDF-", (binary:copy(<<0>>, 10485760))/binary>>,
    ?assertEqual({error, {413, <<"PDFs must be 10 MB or smaller">>}}, muse_files:upload(?O, <<"big.pdf">>, Big, #{})).

folders_and_moves() ->
    {ok, #{<<"id">> := Work, <<"parentId">> := null, <<"name">> := <<"工作"/utf8>>}} =
        muse_files:create_folder(?O, <<"  工作 "/utf8>>, null),
    {ok, #{<<"id">> := Q3, <<"parentId">> := Work}} = muse_files:create_folder(?O, <<"Q3">>, Work),
    ?assertEqual({error, {409, <<"A folder with this name already exists here">>}},
                 muse_files:create_folder(?O, <<"q3">>, Work)),
    {ok, _} = muse_files:create_folder(?O, <<"Q3">>, null),
    ?assertMatch({error, {422, _}}, muse_files:create_folder(?O, <<"a/b">>, null)),
    ?assertMatch({error, {422, _}}, muse_files:create_folder(?O, <<"   ">>, null)),
    ?assertEqual({error, {404, <<"Folder not found">>}}, muse_files:create_folder(?O, <<"x">>, muse_ids:uuid())),
    ?assertEqual({error, {404, <<"Folder not found">>}}, muse_files:create_folder(?O, <<"x">>, <<"nope">>)),
    {ok, #{<<"name">> := <<"Q4">>}} = muse_files:rename_folder(?O, Q3, <<"Q4">>),
    ?assertEqual([<<"工作"/utf8>>, <<"Q4">>], [N || #{<<"name">> := N} <- muse_files:folder_path(?O, Q3)]),
    ?assertEqual([], muse_files:folder_path(?O, null)),
    ?assert(lists:any(fun(#{<<"id">> := I}) -> I =:= Q3 end, muse_files:folders(?O))),
    %% upload into a folder, move, rename, star
    {ok, #{<<"id">> := F, <<"folderId">> := Q3, <<"updatedAt">> := T0}} =
        muse_files:upload(?O, <<"notes.txt">>, <<"hi">>, #{folder => Q3}),
    {ok, #{<<"folderId">> := Work}} = muse_files:update(?O, F, #{<<"folderId">> => Work}),
    {ok, #{<<"folderId">> := null}} = muse_files:update(?O, F, #{<<"folderId">> => null}),
    ?assertEqual({error, {404, <<"Folder not found">>}}, muse_files:update(?O, F, #{<<"folderId">> => muse_ids:uuid()})),
    {ok, #{<<"name">> := <<"plan.txt">>, <<"starred">> := false}} = muse_files:update(?O, F, #{<<"name">> => <<" plan.txt ">>}),
    ?assertEqual({error, {422, <<"Enter a file name">>}}, muse_files:update(?O, F, #{<<"name">> => <<"  ">>})),
    {ok, #{<<"starred">> := true, <<"updatedAt">> := T1} = Starred} =
        muse_files:update(?O, F, #{<<"starred">> => true}),
    ?assert(T1 >= T0),
    {ok, Starred} = muse_files:get(?O, F),
    ?assertEqual({error, {404, <<"File not found">>}}, muse_files:update(?O, muse_ids:uuid(), #{})),
    %% non-empty folders are kept unless asked
    {ok, _} = muse_files:update(?O, F, #{<<"folderId">> => Q3}),
    ?assertEqual({error, {409, <<"The folder is not empty">>}}, muse_files:delete_folder(?O, Q3, false)),
    ?assertEqual({error, {409, <<"The folder is not empty">>}}, muse_files:delete_folder(?O, Work, false)),
    ok = muse_files:delete(?O, F),
    ?assertEqual({error, {404, <<"File not found">>}}, muse_files:get(?O, F)),
    ?assertEqual(not_found, muse_blob:get(<<"file/", F/binary>>)),
    ?assertEqual({error, {404, <<"File not found">>}}, muse_files:delete(?O, F)),
    {ok, #{files := 0, folders := 1}} = muse_files:delete_folder(?O, Q3, false),
    {ok, #{files := 0, folders := 1}} = muse_files:delete_folder(?O, Work, false),
    ?assertEqual({error, {404, <<"Folder not found">>}}, muse_files:rename_folder(?O, Work, <<"x">>)).

delete_folder_with_contents() ->
    {ok, #{<<"id">> := Top}} = muse_files:create_folder(?O, <<"Top">>, null),
    {ok, #{<<"id">> := Sub}} = muse_files:create_folder(?O, <<"Sub">>, Top),
    {ok, #{<<"id">> := A}} = muse_files:upload(?O, <<"a.txt">>, <<"a">>, #{folder => Top}),
    {ok, #{<<"id">> := B}} = muse_files:upload(?O, <<"b.pdf">>, sample(), #{folder => Sub}),
    {ok, #{<<"id">> := Kept}} = muse_files:upload(?O, <<"kept.txt">>, <<"k">>, #{}),
    %% a filled copy lands next to its source
    {ok, #{<<"folderId">> := Sub}} = muse_files:fill(?O, B, #{<<"participant_name">> => <<"Sam">>}),
    {ok, #{files := 3, folders := 2}} = muse_files:delete_folder(?O, Top, true),
    [?assertEqual({error, {404, <<"File not found">>}}, muse_files:get(?O, I)) || I <- [A, B]],
    ?assertEqual(not_found, muse_blob:get(<<"pdf/", B/binary>>)),
    ?assertEqual({error, {404, <<"Folder not found">>}}, muse_files:folder(?O, Sub)),
    {ok, _} = muse_files:get(?O, Kept).

%% Records written before M9-6: no kind, folderId or starred.
old_records() ->
    Id = muse_ids:uuid(),
    Old = #{<<"id">> => Id, <<"name">> => <<"old.pdf">>, <<"mimeType">> => <<"application/pdf">>,
            <<"size">> => byte_size(sample()), <<"pageCount">> => 2, <<"fields">> => [], <<"url">> => <<>>,
            <<"createdAt">> => muse_time:now_iso(), <<"source">> => <<"Uploaded by you">>},
    ok = muse_blob:put(<<"pdf/", Id/binary>>, sample()),
    _ = muse_store:put(?O, <<"files">>, Old),
    {ok, #{<<"kind">> := <<"pdf">>, <<"folderId">> := null, <<"starred">> := false} = Got} = muse_files:get(?O, Id),
    ?assertEqual(pdf, muse_files:kind(Old)),
    ?assertEqual(null, muse_files:folder_of(Old)),
    ?assertEqual(Got, muse_files:normalize(Old)),
    {ok, _} = muse_files:get_pdf(?O, Id),
    ?assertEqual({ok, sample()}, muse_files:bytes(?O, Id)),
    ?assertEqual({ok, sample()}, muse_files:pdf_bytes(?O, Id)),
    ?assert(lists:any(fun(#{<<"id">> := I, <<"folderId">> := null}) -> I =:= Id; (_) -> false end,
                      muse_files:list(?O))),
    {ok, #{<<"starred">> := true, <<"kind">> := <<"pdf">>}} = muse_files:update(?O, Id, #{<<"starred">> => true}),
    {ok, #{<<"folderId">> := null}} = muse_files:fill(?O, Id, #{}),
    ?assertEqual(<<"pdf/", Id/binary>>, muse_files:blob_key(Old)),
    ?assertEqual(<<"pdf/", Id/binary>>, muse_files:blob_key(Id)).

serve_test_() ->
    S = fun(Mime, Download) -> muse_files:serve(#{<<"mimeType">> => Mime}, Download) end,
    [?_assertEqual({<<"application/pdf">>, inline}, muse_files:serve(#{}, false)),
     ?_assertEqual({<<"application/pdf">>, attachment}, S(<<"application/pdf">>, true)),
     ?_assertEqual({<<"image/png">>, inline}, S(<<"image/png">>, false)),
     ?_assertEqual({<<"image/png">>, attachment}, S(<<"image/png">>, true)),
     ?_assertEqual({<<"audio/mpeg">>, inline}, S(<<"audio/mpeg">>, false)),
     ?_assertEqual({<<"video/mp4">>, inline}, S(<<"video/mp4">>, false)),
     ?_assertEqual({<<"image/tiff">>, attachment}, S(<<"image/tiff">>, false)),
     ?_assertEqual({<<"text/plain">>, attachment}, S(<<"text/plain">>, false)),
     ?_assertEqual({<<"application/zip">>, attachment}, S(<<"application/zip">>, false)),
     ?_assertEqual({<<"application/octet-stream">>, attachment}, S(<<"text/html">>, false)),
     ?_assertEqual({<<"application/octet-stream">>, attachment}, S(<<"image/svg+xml">>, false)),
     ?_assertEqual({<<"application/octet-stream">>, attachment}, S(<<"application/xhtml+xml">>, false))].

detect_mime_test_() ->
    D = fun(Name, Bytes) -> {ok, M} = muse_files:detect_mime(Name, Bytes, undefined), M end,
    Ftyp = fun(Brand) -> <<0, 0, 0, 24, "ftyp", Brand/binary, 0, 0, 0, 0>> end,
    [?_assertEqual(<<"application/pdf">>, D(<<"x.bin">>, <<"%PDF-1.7">>)),
     ?_assertEqual(<<"image/jpeg">>, D(<<"x">>, <<16#FF, 16#D8, 16#FF, 16#E0>>)),
     ?_assertEqual(<<"image/png">>, D(<<"x.gif">>, ?PNG)),
     ?_assertEqual(<<"audio/mp4">>, D(<<"song.m4a">>, Ftyp(<<"isom">>))),
     ?_assertEqual(<<"video/mp4">>, D(<<"clip">>, Ftyp(<<"isom">>))),
     ?_assertEqual(<<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>,
                   D(<<"a.docx">>, <<"PK", 3, 4, 0, 0>>)),
     ?_assertEqual(<<"application/zip">>, D(<<"a.png">>, <<"PK", 3, 4, 0, 0>>)),
     ?_assertEqual(<<"text/markdown">>, D(<<"a.MD">>, <<"# hi">>)),
     ?_assertEqual(<<"image/svg+xml">>, D(<<"a.svg">>, <<"<svg/>">>)),
     ?_assertEqual(<<"text/plain">>, D(<<"x">>, <<>>)),
     ?_assertEqual(archive, muse_files:kind_of_mime(<<"application/gzip">>)),
     ?_assertEqual(text, muse_files:kind_of_mime(<<"application/json">>)),
     ?_assertEqual(other, muse_files:kind_of_mime(<<"application/msword">>))].
