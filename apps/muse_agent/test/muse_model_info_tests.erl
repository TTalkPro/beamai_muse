-module(muse_model_info_tests).
-include_lib("eunit/include/eunit.hrl").

%% muse_model_info over a small catalogue shaped like models.dev's api.json.

catalogue() ->
    #{<<"alibaba">> =>
          #{<<"id">> => <<"alibaba">>,
            <<"models">> =>
                #{<<"qwen3.8-flash">> =>
                      #{<<"id">> => <<"qwen3.8-flash">>, <<"canonical_model_id">> => <<"alibaba/qwen3.8-flash">>,
                        <<"limit">> => #{<<"context">> => 1000000, <<"output">> => 131072},
                        <<"reasoning">> => true, <<"tool_call">> => true}}},
      <<"somegateway">> =>
          #{<<"models">> =>
                #{<<"qwen3.8-flash">> =>
                      #{<<"canonical_model_id">> => <<"alibaba/qwen3.8-flash">>,
                        <<"limit">> => #{<<"context">> => 32000, <<"output">> => 8192}},
                  <<"Small/Tiny-1">> =>
                      #{<<"limit">> => #{<<"context">> => 8192, <<"output">> => 2048}},
                  <<"shared-model">> =>
                      #{<<"limit">> => #{<<"context">> => 64000, <<"output">> => 20000}}}},
      <<"othergateway">> =>
          #{<<"models">> =>
                #{<<"shared-model">> =>
                      #{<<"limit">> => #{<<"context">> => 128000, <<"output">> => 4000}}}}}.

setup() ->
    Dir = "/tmp/muse_model_info_" ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, C} = muse_config:from_env(#{<<"DATA_DIR">> => list_to_binary(Dir), <<"MODELS_DEV_URL">> => <<"off">>}),
    muse_config:set(C),
    persistent_term:put({muse_model_info, index}, muse_model_info:index(catalogue())),
    Dir.

cleanup(Dir) ->
    persistent_term:erase({muse_model_info, index}),
    os:cmd("rm -rf " ++ Dir).

model_info_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [{"the vendor's own entry wins over a gateway's",
       fun() ->
               {ok, I} = muse_model_info:lookup(<<"openai/qwen3.8-flash">>),
               ?assertMatch(#{provider := <<"alibaba">>, output := 131072, context := 1000000,
                              reasoning := true, tool_call := true}, I)
       end},
      {"without a vendor entry the most conservative limits win",
       fun() ->
               {ok, I} = muse_model_info:lookup(<<"shared-model">>),
               ?assertMatch(#{output := 4000, context := 64000}, I)
       end},
      {"case-insensitive, also by the part after /",
       fun() ->
               ?assertMatch({ok, #{output := 2048}}, muse_model_info:lookup(<<"openai/small/tiny-1">>)),
               ?assertMatch({ok, #{output := 2048}}, muse_model_info:lookup(<<"tiny-1">>)),
               ?assertEqual(undefined, muse_model_info:lookup(<<"openai/no-such-model">>))
       end},
      {"max_tokens: the output limit capped, the fallback, the override",
       fun() ->
               ?assertEqual(muse_model_info:cap(), muse_model_info:max_tokens(<<"openai/qwen3.8-flash">>)),
               ?assertEqual(2048, muse_model_info:max_tokens(<<"tiny-1">>)),
               ?assertEqual(muse_model_info:fallback(), muse_model_info:max_tokens(<<"openai/unknown">>)),
               {ok, C} = muse_config:from_env(#{<<"MODEL_MAX_TOKENS">> => <<"9000">>}),
               muse_config:set(C),
               ?assertEqual(9000, muse_model_info:max_tokens(<<"openai/qwen3.8-flash">>))
       end},
      {"refresh is off when MODELS_DEV_URL is off",
       fun() -> ?assertEqual({error, disabled}, muse_model_info:refresh()) end}]}.
