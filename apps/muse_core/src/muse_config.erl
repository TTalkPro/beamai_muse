%% @doc Server configuration from environment variables (and an optional
%% `.env` file), validated in the same order and with the same messages as
%% OpenMuse `config.ts` (designs/ref/openmuse-integrations-spec.md §1).
%%
%% Differences from OpenMuse are listed in designs/00-overview.md §5:
%% no CPK_INTELLIGENCE_API_KEY, no DATABASE_URL, extra model providers,
%% MUSE_UI_SECRET for the aihtml UI, sidecar commands.
%%
%% `load/0` runs once at boot and stores the result in persistent_term;
%% `get/1` reads it. `from_env/1` is the pure core used by tests.
-module(muse_config).

-export([load/0, from_env/1, set/1, get/1, get/2, all/0,
         agent_configured/0, browser_configured/0, provider_key_env/1,
         parse_dotenv/1]).

-define(KEY, {?MODULE, config}).

-type config() :: #{atom() => term()}.
-export_type([config/0]).

-define(LOOPBACK, [<<"127.0.0.1">>, <<"localhost">>, <<"::1">>]).

%% @doc Read `.env` (unless MUSE_ENV_FILE points elsewhere), merge it under the
%% process environment, validate and publish.
-spec load() -> {ok, config()} | {error, binary()}.
load() ->
    File = case os:getenv("MUSE_ENV_FILE") of
               false -> ".env";
               F -> F
           end,
    Env = env_with_dotenv(File),
    case from_env(Env) of
        {ok, Config} ->
            set(Config),
            {ok, Config};
        Error ->
            Error
    end.

-spec set(config()) -> ok.
set(Config) ->
    persistent_term:put(?KEY, Config).

-spec all() -> config().
all() ->
    persistent_term:get(?KEY).

-spec get(atom()) -> term().
get(Key) ->
    maps:get(Key, all()).

-spec get(atom(), term()) -> term().
get(Key, Default) ->
    maps:get(Key, persistent_term:get(?KEY, #{}), Default).

%% @doc Build the configuration from a map of environment variable names to
%% values (binaries). Unset variables are absent from the map.
-spec from_env(#{binary() => binary()}) -> {ok, config()} | {error, binary()}.
from_env(Env) ->
    try
        {ok, build(Env)}
    catch
        throw:{config_error, Msg} -> {error, Msg}
    end.

%% @doc OpenMuse `agentConfigured(config)`, with the provider set extended to
%% every provider beamai_llm supports (designs/03-agent.md §1).
-spec agent_configured() -> boolean().
agent_configured() ->
    agent_configured(all()).

agent_configured(#{agent_backend := sample}) -> true;
agent_configured(#{agent_backend := agui, agent_url := Url}) -> Url =/= undefined;
agent_configured(#{agent_backend := model, model := undefined}) -> false;
agent_configured(#{agent_backend := model, model := Model, provider_keys := Keys}) ->
    case provider_of(Model) of
        undefined -> false;
        <<"ollama">> -> true;
        Provider -> maps:get(Provider, Keys, undefined) =/= undefined
    end.

-spec browser_configured() -> boolean().
browser_configured() ->
    #{worker_url := Url, worker_token := Token} = all(),
    Url =/= undefined andalso Token =/= undefined.

%% @doc Environment variable holding the API key of a MODEL provider.
-spec provider_key_env(binary()) -> binary() | undefined.
provider_key_env(<<"openai">>) -> <<"OPENAI_API_KEY">>;
provider_key_env(<<"anthropic">>) -> <<"ANTHROPIC_API_KEY">>;
provider_key_env(<<"zhipu">>) -> <<"ZHIPU_API_KEY">>;
provider_key_env(<<"deepseek">>) -> <<"DEEPSEEK_API_KEY">>;
provider_key_env(<<"moonshot">>) -> <<"MOONSHOT_API_KEY">>;
provider_key_env(<<"kimi">>) -> <<"MOONSHOT_API_KEY">>;
provider_key_env(<<"openrouter">>) -> <<"OPENROUTER_API_KEY">>;
provider_key_env(<<"siliconflow">>) -> <<"SILICONFLOW_API_KEY">>;
provider_key_env(<<"dashscope">>) -> <<"DASHSCOPE_API_KEY">>;
provider_key_env(<<"xai">>) -> <<"XAI_API_KEY">>;
provider_key_env(_) -> undefined.

%% @doc Parse dotenv text into ordered `{Key, Value}` pairs: `KEY=VALUE`,
%% optional `export `, `#` comments (also after an unquoted value),
%% single/double quotes, `\n` escapes inside double quotes.
-spec parse_dotenv(binary()) -> [{binary(), binary()}].
parse_dotenv(Text) ->
    Lines = binary:split(Text, [<<"\r\n">>, <<"\n">>], [global]),
    lists:filtermap(fun dotenv_line/1, Lines).

%% Internal

build(Env) ->
    Get = fun(K) -> maps:get(K, Env, undefined) end,
    Trimmed = fun(K) -> blank_to_undefined(trim(Get(K))) end,

    Mode = case Get(<<"WORKSPACE_MODE">>) of
               undefined -> sample;
               <<"sample">> -> sample;
               <<"live">> -> live;
               _ -> fail(<<"WORKSPACE_MODE must be sample or live">>)
           end,
    Backend = case Get(<<"AGENT_BACKEND">>) of
                  undefined when Mode =:= sample -> sample;
                  undefined -> model;
                  <<"sample">> -> sample;
                  <<"model">> -> model;
                  <<"agui">> -> agui;
                  _ -> fail(<<"AGENT_BACKEND must be sample, model or agui">>)
              end,
    fail_if(Mode =:= live andalso Backend =:= sample,
            <<"Live workspaces cannot use the sample agent">>),
    JevMode = case Get(<<"JEV_MODE">>) of
                  undefined -> off;
                  <<"off">> -> off;
                  <<"sample">> -> sample;
                  <<"live">> -> live;
                  _ -> fail(<<"JEV_MODE must be off, sample or live">>)
              end,
    TypesafeKey = Trimmed(<<"TYPESAFE_API_KEY">>),
    fail_if(JevMode =:= live andalso TypesafeKey =:= undefined,
            <<"JEV_MODE=live requires a nonblank TYPESAFE_API_KEY">>),
    %% Only the Docker computer is supported (no E2B desktop, see
    %% docs/DIFFERENCES.md).
    Provider = case Trimmed(<<"COMPUTER_PROVIDER">>) of
                   undefined -> docker;
                   <<"docker">> -> docker;
                   _ -> fail(<<"COMPUTER_PROVIDER must be docker (the E2B desktop is not supported)">>)
               end,
    ComputerEnabled = Get(<<"COMPUTER_ENABLED">>) =:= <<"true">>,
    %% Not in OpenMuse: the desktop variant of the Docker computer (Xvfb +
    %% openbox image, use_desktop; docs/DIFFERENCES.md).
    ComputerDesktop = case Trimmed(<<"COMPUTER_DESKTOP">>) of
                          undefined -> false;
                          <<"false">> -> false;
                          <<"true">> -> true;
                          _ -> fail(<<"COMPUTER_DESKTOP must be true or false">>)
                      end,
    DesktopImage = case Get(<<"COMPUTER_DESKTOP_IMAGE">>) of
                       undefined -> <<"openmuse-computer-desktop:local">>;
                       DI ->
                           case re:run(DI, <<"^[a-zA-Z0-9][a-zA-Z0-9._/:@-]{0,250}$">>,
                                       [{capture, none}]) of
                               match -> DI;
                               nomatch -> fail(<<"COMPUTER_DESKTOP_IMAGE must be a local "
                                                 "Docker image name such as "
                                                 "openmuse-computer-desktop:local">>)
                           end
                   end,

    Port = case Get(<<"PORT">>) of
               undefined -> 8787;
               P ->
                   case string:to_integer(P) of
                       {N, <<>>} when N > 0, N < 65536 -> N;
                       _ -> fail(<<"PORT must be a TCP port number">>)
                   end
           end,
    PublicUrl = case Get(<<"PUBLIC_API_URL">>) of
                    undefined -> <<"http://localhost:", (integer_to_binary(Port))/binary>>;
                    U -> U
                end,
    Host = case Get(<<"HOST">>) of
               undefined -> <<"127.0.0.1">>;
               H -> H
           end,
    DataDir = list_to_binary(filename:absname(binary_to_list(
                  case Get(<<"DATA_DIR">>) of
                      undefined -> <<".muse">>;
                      D -> D
                  end))),
    AccessKey = Get(<<"OPENMUSE_ACCESS_KEY">>),
    EncryptionKey = Get(<<"TOKEN_ENCRYPTION_KEY">>),
    UiSecret = blank_to_undefined(Get(<<"MUSE_UI_SECRET">>)),
    case Mode of
        live ->
            AccessOk = AccessKey =/= undefined
                andalso muse_validate:utf16_length(AccessKey) >= 24,
            fail_if(not (AccessOk andalso EncryptionKey =/= undefined),
                    <<"Live mode requires OPENMUSE_ACCESS_KEY (24+ characters) "
                      "and TOKEN_ENCRYPTION_KEY (32-byte base64)">>),
            fail_if(not (UiSecret =/= undefined andalso byte_size(UiSecret) >= 32),
                    <<"Live mode requires MUSE_UI_SECRET (32+ characters)">>);
        sample ->
            fail_if(not lists:member(Host, ?LOOPBACK),
                    <<"Sample workspace is local-only. HOST must be a loopback address.">>)
    end,

    WorkerUrl = case Trimmed(<<"BROWSER_WORKER_URL">>) of
                    undefined -> undefined;
                    W ->
                        case binary:match(W, <<"://">>) of
                            nomatch -> <<"http://", W/binary>>;
                            _ -> W
                        end
                end,
    Model = blank_to_undefined(Get(<<"MODEL">>)),
    ProviderKeys = maps:from_list(
        [{Name, Val} || Name <- providers(),
                        Var <- [provider_key_env(Name)],
                        Val <- [blank_to_undefined(Get(Var))],
                        Val =/= undefined]),
    Origins = case Get(<<"ALLOWED_ORIGINS">>) of
                  undefined -> [<<"http://localhost:8081">>, <<"http://127.0.0.1:8081">>];
                  O -> binary:split(O, <<",">>, [global])
              end,
    #{mode => Mode,
      agent_backend => Backend,
      jev_mode => JevMode,
      typesafe_api_key => TypesafeKey,
      jev_model => default(Trimmed(<<"JEV_MODEL">>), <<"jev-1.13.0">>),
      %% the TypeSafe SDK's TYPESAFE_BASE_URL (trailing slashes dropped)
      typesafe_base_url => strip_slashes(default(Trimmed(<<"TYPESAFE_BASE_URL">>), <<"https://api.typesafe.ai">>)),
      computer_provider => Provider,
      computer_enabled => ComputerEnabled,
      %% names the Docker computer's containers (else PUBLIC_API_URL)
      computer_deployment_id => Trimmed(<<"COMPUTER_DEPLOYMENT_ID">>),
      computer_image => default(Get(<<"COMPUTER_IMAGE">>), <<"openmuse-computer:local">>),
      computer_desktop => ComputerDesktop,
      computer_desktop_image => DesktopImage,
      port => Port,
      public_url => PublicUrl,
      host => Host,
      data_dir => DataDir,
      access_key => AccessKey,
      encryption_key => EncryptionKey,
      ui_secret => UiSecret,
      model => Model,
      provider_keys => ProviderKeys,
      openai_base_url => blank_to_undefined(Get(<<"OPENAI_BASE_URL">>)),
      openai_chat_completions => Get(<<"OPENAI_CHAT_COMPLETIONS">>) =:= <<"true">>,
      anthropic_base_url => blank_to_undefined(Get(<<"ANTHROPIC_BASE_URL">>)),
      agent_url => blank_to_undefined(Get(<<"AGENT_URL">>)),
      agent_token => blank_to_undefined(Get(<<"AGENT_TOKEN">>)),
      google_client_id => blank_to_undefined(Get(<<"GOOGLE_CLIENT_ID">>)),
      google_client_secret => blank_to_undefined(Get(<<"GOOGLE_CLIENT_SECRET">>)),
      google_redirect_uri => <<PublicUrl/binary, "/api/google/callback">>,
      worker_url => WorkerUrl,
      worker_token => blank_to_undefined(Get(<<"WORKER_TOKEN">>)),
      task_worker_enabled => Get(<<"TASK_WORKER_ENABLED">>) =/= <<"false">>,
      web_search_enabled => Get(<<"WEB_SEARCH_ENABLED">>) =/= <<"false">>,
      parallel_api_key => Trimmed(<<"PARALLEL_API_KEY">>),
      allowed_origins => Origins,
      trust_proxy => Get(<<"TRUST_PROXY">>) =:= <<"true">>,
      pdf_sidecar => default(Get(<<"PDF_SIDECAR">>), <<"node sidecars/pdf/index.mjs">>),
      docker_env => maps:with([<<"PATH">>, <<"HOME">>, <<"DOCKER_HOST">>, <<"DOCKER_CONTEXT">>,
                               <<"DOCKER_CONFIG">>, <<"DOCKER_TLS_VERIFY">>,
                               <<"DOCKER_CERT_PATH">>], Env)}.

providers() ->
    [<<"openai">>, <<"anthropic">>, <<"zhipu">>, <<"deepseek">>, <<"moonshot">>,
     <<"kimi">>, <<"openrouter">>, <<"siliconflow">>, <<"dashscope">>, <<"xai">>].

provider_of(Model) ->
    case re:run(Model, <<"^([a-zA-Z0-9_-]+)[/:].+">>, [{capture, all_but_first, binary}]) of
        {match, [P]} -> string:lowercase(P);
        nomatch -> undefined
    end.

-spec fail(binary()) -> no_return().
fail(Msg) ->
    throw({config_error, Msg}).

fail_if(true, Msg) -> fail(Msg);
fail_if(false, _) -> ok.

default(undefined, D) -> D;
default(V, _) -> V.

blank_to_undefined(undefined) -> undefined;
blank_to_undefined(<<>>) -> undefined;
blank_to_undefined(V) -> V.

trim(undefined) -> undefined;
trim(V) -> string:trim(V).

env_with_dotenv(File) ->
    Process = maps:from_list([split_env(E) || E <- os:getenv()]),
    case file:read_file(File) of
        {ok, Text} ->
            Pairs = parse_dotenv(Text),
            Overridden = [K || {K, V} <- Pairs,
                               maps:is_key(K, Process),
                               maps:get(K, Process) =/= V],
            warn_overrides(lists:usort(Overridden)),
            maps:merge(maps:from_list(Pairs), Process);
        {error, _} ->
            Process
    end.

split_env(E) ->
    Bin = unicode:characters_to_binary(E),
    case binary:split(Bin, <<"=">>) of
        [K, V] -> {K, V};
        [K] -> {K, <<>>}
    end.

warn_overrides([]) ->
    ok;
warn_overrides(Keys) ->
    Tail = case Keys of
               [_] -> <<"Unset it to use the .env value.">>;
               _ -> <<"Unset them to use the .env values.">>
           end,
    logger:warning("[OpenMuse] Using ~ts from the environment instead of .env. ~ts",
                   [lists:join(<<", ">>, Keys), Tail]).

dotenv_line(Line0) ->
    Line = string:trim(Line0),
    case Line of
        <<>> -> false;
        <<"#", _/binary>> -> false;
        _ ->
            Body = case Line of
                       <<"export ", Rest/binary>> -> string:trim(Rest, leading);
                       _ -> Line
                   end,
            case binary:split(Body, <<"=">>) of
                [K, V] ->
                    Key = string:trim(K),
                    case re:run(Key, <<"^[A-Za-z_][A-Za-z0-9_.-]*$">>, [{capture, none}]) of
                        match -> {true, {Key, dotenv_value(string:trim(V, leading))}};
                        nomatch -> false
                    end;
                _ ->
                    false
            end
    end.

dotenv_value(<<$", Rest/binary>>) ->
    case binary:split(Rest, <<"\"">>) of
        [Inner, _] -> binary:replace(binary:replace(Inner, <<"\\n">>, <<"\n">>, [global]),
                                     <<"\\r">>, <<"\r">>, [global]);
        [Inner] -> Inner
    end;
dotenv_value(<<$', Rest/binary>>) ->
    hd(binary:split(Rest, <<"'">>));
dotenv_value(V) ->
    Unquoted = case re:run(V, <<"^(.*?)\\s+#">>, [{capture, all_but_first, binary}]) of
                   {match, [Before]} -> Before;
                   nomatch -> case V of <<"#", _/binary>> -> <<>>; _ -> V end
               end,
    string:trim(Unquoted, trailing).

strip_slashes(Url) ->
    string:trim(Url, trailing, "/").
