-module(muse_security_tests).
-include_lib("eunit/include/eunit.hrl").

%% Vectors produced by Node with OpenMuse's algorithms (vault.ts, auth.ts).
-define(KEY, <<"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=">>).
-define(ENVELOPE, <<"v1.AQEBAQEBAQEBAQEB.bTr8ukmFEWMJCXWK_iUGmw.DcP70vbNiX25i6hOG1IeE5LZbNZl">>).

vault_interop_test() ->
    ?assertEqual({ok, <<"{\"refresh_token\":\"x\"}">>}, muse_vault:decrypt(?KEY, ?ENVELOPE)).

vault_roundtrip_test() ->
    Env = muse_vault:encrypt(?KEY, <<"秘密"/utf8>>),
    ?assertMatch(<<"v1.", _/binary>>, Env),
    ?assertEqual({ok, <<"秘密"/utf8>>}, muse_vault:decrypt(?KEY, Env)).

vault_rejects_test_() ->
    KeyErr = {error, <<"Credential encryption requires a 32-byte base64 key">>},
    Bad = {error, <<"Invalid encrypted secret">>},
    [_, N, T, C] = binary:split(?ENVELOPE, <<".">>, [global]),
    Tampered = <<"v1.", N/binary, ".", T/binary, ".", (flip(C))/binary>>,
    [?_assertEqual(KeyErr, muse_vault:check_key(<<"short">>)),
     ?_assertEqual(KeyErr, muse_vault:check_key(base64:encode(<<0:256>>, #{padding => false}))),
     ?_assertEqual(KeyErr, muse_vault:check_key(undefined)),
     ?_assertEqual(Bad, muse_vault:decrypt(?KEY, <<"v2.", N/binary, ".", T/binary, ".", C/binary>>)),
     ?_assertEqual(Bad, muse_vault:decrypt(?KEY, <<"v1.", N/binary, ".", T/binary>>)),
     ?_assertEqual(Bad, muse_vault:decrypt(?KEY, <<"v1.AQEB.", T/binary, ".", C/binary>>)),
     ?_assertEqual(Bad, muse_vault:decrypt(?KEY, <<"v1.", N/binary, "=.", T/binary, ".", C/binary>>)),
     ?_assertEqual({error, <<"Unable to authenticate or decrypt credential">>},
                   muse_vault:decrypt(?KEY, Tampered))].

flip(<<"A", Rest/binary>>) -> <<"B", Rest/binary>>;
flip(<<_, Rest/binary>>) -> <<"A", Rest/binary>>.

encode_uri_component_test() ->
    ?assertEqual(<<"local-user%20a%2Fb%3F%C3%BC!*'()~">>,
                 muse_signing:encode_uri_component(<<"local-user a/b?ü!*'()~"/utf8>>)).

signing_test_() ->
    {setup,
     fun() ->
         Dir = "/tmp/muse_sign_" ++ integer_to_list(erlang:unique_integer([positive])),
         {ok, C} = muse_config:from_env(#{<<"DATA_DIR">> => list_to_binary(Dir)}),
         muse_config:set(C),
         ok = muse_signing:init(Dir),
         Dir
     end,
     fun(Dir) -> os:cmd("rm -rf " ++ Dir) end,
     fun(Dir) ->
         Url = muse_signing:sign(<<"local-user">>, <<"/api/files/x/content">>),
         Q = maps:from_list(uri_string:dissect_query(maps:get(query, uri_string:parse(Url)))),
         V = fun(Path, O, E, S) -> muse_signing:verify(Path, O, E, S) end,
         #{"owner" := O0, "expires" := E0, "signature" := S0} =
             maps:from_list([{binary_to_list(K), Val} || {K, Val} <- maps:to_list(Q)]),
         Past = integer_to_binary(muse_time:now_ms() - 1),
         {ok, KeyText} = file:read_file(filename:join(Dir, "session-signing-key")),
         [?_assertMatch(<<"http://localhost:8787/api/files/x/content?owner=local-user&expires=", _/binary>>, Url),
          ?_assertEqual(44, byte_size(KeyText)),
          ?_assertEqual({ok, <<"local-user">>}, V(<<"/api/files/x/content">>, O0, E0, S0)),
          ?_assertEqual({error, {403, <<"Invalid access link">>}}, V(<<"/api/files/y/content">>, O0, E0, S0)),
          ?_assertMatch({error, {401, _}}, V(<<"/api/files/x/content">>, O0, Past, S0)),
          ?_assertMatch({error, {401, _}}, V(<<"/api/files/x/content">>, <<>>, E0, S0)),
          ?_assertMatch({error, {401, _}}, V(<<"/api/files/x/content">>, O0, E0, <<"abc">>)),
          ?_assertMatch({error, {401, _}}, V(<<"/api/files/x/content">>, O0, <<"1e9">>, S0)),
          %% same key file on a second init (no overwrite)
          ?_test(begin ok = muse_signing:init(Dir),
                       ?assertEqual({ok, <<"local-user">>}, V(<<"/api/files/x/content">>, O0, E0, S0)) end)]
     end}.

%% HMAC over the key *text*, as OpenMuse does (Node vector).
hmac_text_key_test() ->
    persistent_term:put({muse_signing, key}, binary:copy(<<"k">>, 44)),
    Sig = <<"8c6cf0bdc971cdb90ed825cea4e84ba9807268a94a7a11c1a9f3c7e5fa670083">>,
    ok = muse_time:set_offset(-(erlang:system_time(millisecond) - 1700000000000 + 1000)),
    try
        ?assertEqual({ok, <<"local-user">>},
                     muse_signing:verify(<<"/api/files/x/content">>, <<"local-user">>,
                                         <<"1700000000000">>, Sig))
    after
        muse_time:set_offset(0)
    end.

signable_paths_test_() ->
    [?_assert(muse_signing:is_signable_path(<<"/api/files/abc/content">>)),
     ?_assert(muse_signing:is_signable_path(<<"/api/browsers/abc/preview">>)),
     ?_assert(muse_signing:is_signable_path(<<"/api/browsers/abc/console">>)),
     ?_assertNot(muse_signing:is_signable_path(<<"/api/files/abc/fill">>)),
     ?_assertNot(muse_signing:is_signable_path(<<"/api/files/a/b/content">>))].

rate_limit_test_() ->
    {setup,
     fun() -> {ok, Pid} = muse_rate_limit:start_link(), unlink(Pid), Pid end,
     fun(Pid) -> exit(Pid, kill) end,
     [?_test(begin
                 Now = 1000,
                 Results = [muse_rate_limit:take(api, <<"k">>, Now) || _ <- lists:seq(1, 121)],
                 ?assertEqual(120, length([R || R <- Results, R])),
                 ?assertNot(lists:last(Results)),
                 ?assert(muse_rate_limit:take(api, <<"k">>, Now + 60000)),
                 ?assert(muse_rate_limit:take(api, <<"other">>, Now))
             end),
      ?_test(begin
                 Results = [muse_rate_limit:take(login, <<"ip">>, 5) || _ <- lists:seq(1, 31)],
                 ?assertEqual(30, length([R || R <- Results, R])),
                 ?assert(muse_rate_limit:take(login, <<"other-ip">>, 5))
             end),
      ?_assertEqual(<<"conn:10.0.0.1">>,
                    muse_rate_limit:client_key(false, #{<<"x-forwarded-for">> => <<"1.1.1.1">>}, {10, 0, 0, 1})),
      ?_assertEqual(<<"proxy:1.1.1.1">>,
                    muse_rate_limit:client_key(true, #{<<"x-forwarded-for">> => <<" 1.1.1.1 , 2.2.2.2">>}, {10, 0, 0, 1})),
      ?_assertEqual(<<"proxy:3.3.3.3">>,
                    muse_rate_limit:client_key(true, #{<<"x-real-ip">> => <<"3.3.3.3">>}, {10, 0, 0, 1})),
      ?_assertEqual(<<"conn:unknown">>, muse_rate_limit:client_key(true, #{}, undefined))]}.

auth_test_() ->
    {setup,
     fun() -> ok = muse_store:init(#{storage => ram}) end,
     fun(_) -> muse_store:stop() end,
     [?_test(begin
                 {ok, C} = muse_config:from_env(#{}),
                 muse_config:set(C),
                 {ok, #{token := T, mode := <<"sample">>}} = muse_auth:session(undefined),
                 ?assertEqual(43, byte_size(T)),
                 ?assertEqual({ok, <<"local-user">>}, muse_auth:owner_from_header(<<"Bearer ", T/binary>>)),
                 ?assertEqual({error, {401, <<"Sign in to BeamAI Muse">>}}, muse_auth:owner_from_header(<<"bearer ", T/binary>>)),
                 ?assertEqual({error, {401, <<"Session expired. Sign in again.">>}},
                              muse_auth:owner_from_header(<<"Bearer nope">>)),
                 ok = muse_auth:revoke(T),
                 ?assertMatch({error, {401, _}}, muse_auth:owner_from_token(T))
             end),
      ?_test(begin
                 Key = binary:copy(<<"a">>, 24),
                 {ok, C} = muse_config:from_env(#{<<"WORKSPACE_MODE">> => <<"live">>,
                                                  <<"OPENMUSE_ACCESS_KEY">> => Key,
                                                  <<"TOKEN_ENCRYPTION_KEY">> => <<"k">>,
                                                  <<"MUSE_UI_SECRET">> => binary:copy(<<"s">>, 32)}),
                 muse_config:set(C),
                 ?assertEqual({error, {401, <<"Access key is incorrect">>}}, muse_auth:session(<<"wrong">>)),
                 ?assertEqual({error, {401, <<"Access key is incorrect">>}}, muse_auth:session(undefined)),
                 {ok, #{token := T, mode := <<"live">>}} = muse_auth:session(Key),
                 ?assertEqual({ok, <<"local-user">>}, muse_auth:owner_from_token(T)),
                 ok = muse_time:set_offset(86400001),
                 try
                     ?assertMatch({error, {401, <<"Session expired", _/binary>>}}, muse_auth:owner_from_token(T)),
                     ?assert(muse_auth:purge_expired() >= 1)
                 after
                     muse_time:set_offset(0)
                 end
             end)]}.
