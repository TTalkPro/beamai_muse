-module(muse_ids_tests).
-include_lib("eunit/include/eunit.hrl").

uuid_test() ->
    U = muse_ids:uuid(),
    ?assert(muse_ids:is_uuid(U)),
    ?assertMatch(<<_:14/binary, "4", _/binary>>, U),
    ?assertNotEqual(U, muse_ids:uuid()).

is_uuid_test_() ->
    [?_assert(muse_ids:is_uuid(<<"B84A2263-7E61-54CE-B889-E0CE9033BB8B">>)),
     ?_assertNot(muse_ids:is_uuid(<<"b84a2263-7e61-04ce-b889-e0ce9033bb8b">>)),
     ?_assertNot(muse_ids:is_uuid(<<"../etc/passwd">>)),
     ?_assertNot(muse_ids:is_uuid(undefined))].

%% Expected ids computed by OpenMuse's deterministicFileId in Node.
deterministic_file_id_test() ->
    ?assertEqual(<<"b84a2263-7e61-54ce-b889-e0ce9033bb8b">>,
                 muse_ids:deterministic_file_id(<<"local-user">>, <<"model:task1:fill_pdf">>)),
    ?assertEqual(<<"eb226db8-d016-578c-bdcb-74e9ddd68983">>,
                 muse_ids:deterministic_file_id(<<"o\"wner">>, <<"键"/utf8>>)).

sha256hex_test() ->
    ?assertEqual(<<"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>,
                 muse_ids:sha256hex(<<>>)).

chat_key_test() ->
    Key = muse_ids:chat_key(<<"t:m">>, <<"task">>, #{<<"prompt">> => <<"x">>}),
    ?assertEqual(<<"t:m:task:", (muse_ids:sha256hex(<<"{\"prompt\":\"x\"}">>))/binary>>, Key).
