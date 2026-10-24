-module(muse_files_tests).
-include_lib("eunit/include/eunit.hrl").

-define(O, <<"local-user">>).

files_test_() ->
    {setup, fun() -> muse_integ_test_env:start(#{}) end, fun muse_integ_test_env:stop/1,
     [fun import_get_list/0, fun keyed_import_is_idempotent/0, fun concurrent_keyed_import/0,
      fun fill_named_and_keyed/0, fun errors/0]}.

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
