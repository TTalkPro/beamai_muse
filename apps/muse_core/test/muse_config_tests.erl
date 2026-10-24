-module(muse_config_tests).
-include_lib("eunit/include/eunit.hrl").

err(Env) ->
    {error, Msg} = muse_config:from_env(Env),
    Msg.

defaults_test() ->
    {ok, C} = muse_config:from_env(#{}),
    ?assertMatch(#{mode := sample, agent_backend := sample, jev_mode := off, port := 8787,
                   host := <<"127.0.0.1">>, public_url := <<"http://localhost:8787">>,
                   computer_provider := docker, computer_enabled := false,
                   task_worker_enabled := true, web_search_enabled := true,
                   trust_proxy := false, worker_url := undefined,
                   google_redirect_uri := <<"http://localhost:8787/api/google/callback">>,
                   allowed_origins := [<<"http://localhost:8081">>, <<"http://127.0.0.1:8081">>]},
                 C),
    ?assertEqual(<<".muse">>, filename:basename(maps:get(data_dir, C))).

validation_order_test_() ->
    Live = #{<<"WORKSPACE_MODE">> => <<"live">>},
    [?_assertEqual(<<"WORKSPACE_MODE must be sample or live">>,
                   err(#{<<"WORKSPACE_MODE">> => <<"x">>, <<"AGENT_BACKEND">> => <<"x">>})),
     ?_assertEqual(<<"AGENT_BACKEND must be sample, model or agui">>,
                   err(#{<<"AGENT_BACKEND">> => <<"x">>, <<"JEV_MODE">> => <<"x">>})),
     ?_assertEqual(<<"Live workspaces cannot use the sample agent">>,
                   err(Live#{<<"AGENT_BACKEND">> => <<"sample">>})),
     ?_assertEqual(<<"JEV_MODE must be off, sample or live">>, err(#{<<"JEV_MODE">> => <<"on">>})),
     ?_assertEqual(<<"JEV_MODE=live requires a nonblank TYPESAFE_API_KEY">>,
                   err(#{<<"JEV_MODE">> => <<"live">>, <<"TYPESAFE_API_KEY">> => <<"  ">>})),
     ?_assertEqual(<<"COMPUTER_PROVIDER must be docker (the E2B desktop is not supported)">>,
                   err(#{<<"COMPUTER_PROVIDER">> => <<"vm">>})),
     ?_assertEqual(<<"COMPUTER_PROVIDER must be docker (the E2B desktop is not supported)">>,
                   err(#{<<"COMPUTER_PROVIDER">> => <<"e2b-desktop">>, <<"COMPUTER_ENABLED">> => <<"true">>})),
     ?_assertEqual(<<"Live mode requires OPENMUSE_ACCESS_KEY (24+ characters) and TOKEN_ENCRYPTION_KEY (32-byte base64)">>,
                   err(Live#{<<"OPENMUSE_ACCESS_KEY">> => <<"short">>})),
     ?_assertEqual(<<"Live mode requires MUSE_UI_SECRET (32+ characters)">>,
                   err(Live#{<<"OPENMUSE_ACCESS_KEY">> => binary:copy(<<"a">>, 24),
                             <<"TOKEN_ENCRYPTION_KEY">> => <<"k">>})),
     ?_assertEqual(<<"Sample workspace is local-only. HOST must be a loopback address.">>,
                   err(#{<<"HOST">> => <<"0.0.0.0">>}))].

live_ok_test() ->
    {ok, C} = muse_config:from_env(#{<<"WORKSPACE_MODE">> => <<"live">>,
                                     <<"OPENMUSE_ACCESS_KEY">> => binary:copy(<<"a">>, 24),
                                     <<"TOKEN_ENCRYPTION_KEY">> => <<"k">>,
                                     <<"MUSE_UI_SECRET">> => binary:copy(<<"s">>, 32),
                                     <<"HOST">> => <<"0.0.0.0">>,
                                     <<"BROWSER_WORKER_URL">> => <<" worker:8790 ">>,
                                     <<"ALLOWED_ORIGINS">> => <<"https://a, https://b">>}),
    ?assertMatch(#{mode := live, agent_backend := model, worker_url := <<"http://worker:8790">>,
                   allowed_origins := [<<"https://a">>, <<" https://b">>]}, C).

agent_configured_test() ->
    Check = fun(Env) ->
                {ok, C} = muse_config:from_env(Env),
                muse_config:set(C),
                muse_config:agent_configured()
            end,
    ?assert(Check(#{})),
    ?assertNot(Check(#{<<"AGENT_BACKEND">> => <<"model">>})),
    ?assertNot(Check(#{<<"AGENT_BACKEND">> => <<"model">>, <<"MODEL">> => <<"openai/gpt-5">>})),
    ?assert(Check(#{<<"AGENT_BACKEND">> => <<"model">>, <<"MODEL">> => <<"openai/gpt-5">>,
                    <<"OPENAI_API_KEY">> => <<"k">>})),
    ?assert(Check(#{<<"AGENT_BACKEND">> => <<"model">>, <<"MODEL">> => <<"zhipu:glm-4.7">>,
                    <<"ZHIPU_API_KEY">> => <<"k">>})),
    ?assertNot(Check(#{<<"AGENT_BACKEND">> => <<"agui">>})),
    ?assert(Check(#{<<"AGENT_BACKEND">> => <<"agui">>, <<"AGENT_URL">> => <<"http://x">>})).

dotenv_test() ->
    Text = <<"# comment\nexport A=1\nB = \"two\\nlines\"  \nC='single # not comment'\n"
             "D=value # trailing comment\nE=  # only comment\nbad line\n">>,
    ?assertEqual([{<<"A">>, <<"1">>}, {<<"B">>, <<"two\nlines">>},
                  {<<"C">>, <<"single # not comment">>}, {<<"D">>, <<"value">>},
                  {<<"E">>, <<>>}],
                 muse_config:parse_dotenv(Text)).

%% The desktop variant of the Docker computer (not in OpenMuse).

computer_desktop_test_() ->
    Get = fun(Env, Key) -> {ok, C} = muse_config:from_env(Env), maps:get(Key, C) end,
    BadFlag = <<"COMPUTER_DESKTOP must be true or false">>,
    BadImage = <<"COMPUTER_DESKTOP_IMAGE must be a local Docker image name such as "
                 "openmuse-computer-desktop:local">>,
    [?_assertEqual(false, Get(#{}, computer_desktop)),
     ?_assertEqual(<<"openmuse-computer-desktop:local">>, Get(#{}, computer_desktop_image)),
     ?_assertEqual(true, Get(#{<<"COMPUTER_DESKTOP">> => <<"true">>}, computer_desktop)),
     ?_assertEqual(true, Get(#{<<"COMPUTER_DESKTOP">> => <<" true ">>}, computer_desktop)),
     ?_assertEqual(false, Get(#{<<"COMPUTER_DESKTOP">> => <<"false">>}, computer_desktop)),
     ?_assertEqual(false, Get(#{<<"COMPUTER_DESKTOP">> => <<"">>}, computer_desktop)),
     ?_assertEqual(BadFlag, err(#{<<"COMPUTER_DESKTOP">> => <<"yes">>})),
     ?_assertEqual(BadFlag, err(#{<<"COMPUTER_DESKTOP">> => <<"TRUE">>})),
     ?_assertEqual(<<"registry.local/desk:2">>,
                   Get(#{<<"COMPUTER_DESKTOP_IMAGE">> => <<"registry.local/desk:2">>},
                       computer_desktop_image)),
     ?_assertEqual(BadImage, err(#{<<"COMPUTER_DESKTOP_IMAGE">> => <<"bad image">>})),
     ?_assertEqual(BadImage, err(#{<<"COMPUTER_DESKTOP_IMAGE">> => <<"-flag">>})),
     ?_assertEqual(BadImage, err(#{<<"COMPUTER_DESKTOP_IMAGE">> => <<>>})),
     %% the light image setting is unchanged and E2B stays unsupported
     ?_assertEqual(<<"openmuse-computer:local">>,
                   Get(#{<<"COMPUTER_DESKTOP">> => <<"true">>}, computer_image)),
     ?_assertEqual(<<"COMPUTER_PROVIDER must be docker (the E2B desktop is not supported)">>,
                   err(#{<<"COMPUTER_PROVIDER">> => <<"e2b-desktop">>,
                         <<"COMPUTER_DESKTOP">> => <<"true">>}))].
