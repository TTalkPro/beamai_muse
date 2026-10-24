%% @doc The chat model from `MODEL=provider/model-id` (designs/03-agent.md §1;
%% OpenMuse tanstack-agent.ts `adapter`).
%%
%% Providers map onto beamai_llm. `openai` uses the Responses API unless
%% `OPENAI_CHAT_COMPLETIONS=true` (gateways without a Responses tool loop).
%% Base URLs given with a trailing `/v1` are trimmed because beamai appends
%% the versioned endpoint itself. beamai has no Gemini provider, so `google`
%% models are rejected as unknown.
%%
%% Tests replace the model with app env `{muse_agent, llm, Config}`.
-module(muse_model).

-export([llm/0, parse/1, configured/0, providers/0]).

-define(MAX_RETRIES, 2).

-spec providers() -> [binary()].
providers() ->
    [<<"openai">>, <<"anthropic">>, <<"zhipu">>, <<"deepseek">>, <<"moonshot">>, <<"kimi">>,
     <<"openrouter">>, <<"siliconflow">>, <<"dashscope">>, <<"xai">>, <<"ollama">>].

%% @doc Whether chat/tasks can call a model (OpenMuse `agentConfigured`).
-spec configured() -> boolean().
configured() ->
    application:get_env(muse_agent, llm) =/= undefined orelse muse_config:agent_configured().

%% @doc beamai_llm config for the configured MODEL.
-spec llm() -> {ok, map()} | {error, binary()}.
llm() ->
    case application:get_env(muse_agent, llm) of
        {ok, Config} -> {ok, Config};
        undefined ->
            case muse_config:get(model) of
                undefined -> {error, <<"A model is required. Configure MODEL and its provider key on the server.">>};
                Spec -> parse(Spec)
            end
    end.

%% @doc Parse `provider/model` or `provider:model` into a beamai config.
-spec parse(binary()) -> {ok, map()} | {error, binary()}.
parse(Spec) ->
    case re:run(string:trim(Spec), <<"^([^/:]*)[/:](.*)$">>, [{capture, all_but_first, binary}, dotall]) of
        {match, [Provider, Model0]} when Provider =/= <<>> ->
            case string:trim(Model0) of
                <<>> -> invalid(Spec);
                Model -> adapter(string:lowercase(Provider), Provider, Model, Spec)
            end;
        _ ->
            invalid(Spec)
    end.

invalid(Spec) ->
    {error, <<"Invalid model string \"", Spec/binary, "\". Use \"openai/gpt-5\", "
              "\"anthropic/claude-sonnet-4.5\", or \"google/gemini-2.5-pro\".">>}.

adapter(<<"openai">>, _, Model, _) ->
    Kind = case muse_config:get(openai_chat_completions) of
               true -> openai;
               false -> openai_responses
           end,
    {ok, create(Kind, Model, <<"openai">>, muse_config:get(openai_base_url))};
adapter(<<"anthropic">>, _, Model, _) ->
    {ok, create(anthropic, Model, <<"anthropic">>, muse_config:get(anthropic_base_url))};
adapter(<<"kimi">>, _, Model, _) ->
    {ok, create(moonshot, Model, <<"kimi">>, undefined)};
adapter(P, Raw, Model, Spec) ->
    case lists:member(P, providers()) of
        true -> {ok, create(binary_to_atom(P), Model, P, undefined)};
        false -> unknown(Raw, Spec)
    end.

unknown(Provider, Spec) ->
    Hint = case muse_config:get(openai_base_url) of
               undefined -> <<>>;
               _ -> <<" For a model on your OPENAI_BASE_URL gateway, use \"openai/", (string:trim(Spec))/binary, "\".">>
           end,
    Supported = iolist_to_binary(lists:join(<<", ">>, providers() -- [<<"kimi">>])),
    {error, <<"Unknown provider \"", Provider/binary, "\" in \"", Spec/binary, "\". Supported: ",
              Supported/binary, ".", Hint/binary>>}.

create(Kind, Model, Provider, BaseUrl) ->
    Key = maps:get(Provider, muse_config:get(provider_keys), undefined),
    Opts0 = #{model => Model, max_retries => ?MAX_RETRIES},
    Opts1 = case Key of undefined -> Opts0; _ -> Opts0#{api_key => Key} end,
    Opts = case BaseUrl of
               undefined -> Opts1;
               _ -> Opts1#{base_url => re:replace(BaseUrl, <<"/v1/?$">>, <<>>, [{return, binary}])}
           end,
    beamai_chat_model:create(Kind, Opts).
