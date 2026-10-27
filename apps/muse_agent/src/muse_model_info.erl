%% @doc Model facts from models.dev (not in OpenMuse): the output and
%% context limits of the configured MODEL, so muse does not hard-code them
%% (beamai's chat-completions default of 4096 output tokens cut long tool
%% arguments of a reasoning model off).
%%
%% The catalogue (`MODELS_DEV_URL`, default https://models.dev/api.json;
%% `off` disables it) is fetched when the worker starts and once a day, and
%% kept in `DATA_DIR/models-dev.json`, so a restart without network still
%% knows the models. Lookups never wait for the network: they read the index
%% in persistent_term (or, before the worker has loaded it, the cache file).
%%
%% A MODEL is `provider/model` where the provider is often only the protocol
%% of a gateway (`openai/qwen3.8-flash` through litegate), so the model is
%% found by its id across all providers, case-insensitively, also by the
%% part after a `/` (`Qwen/Qwen3.8-27B`). Of several entries the vendor's
%% own (the provider named in `canonical_model_id`, e.g. `alibaba` for
%% `alibaba/qwen3.8-flash`) wins, else the most conservative limits.
%%
%% `max_tokens/1`: MODEL_MAX_TOKENS when set, else the model's output limit
%% capped at 32768 (asking a gateway for the whole 131072 a model allows
%% makes it reserve credit for all of it), else 16384.
-module(muse_model_info).
-behaviour(gen_server).

-export([start_link/0, lookup/1, max_tokens/1, refresh/0]).
-export([index/1, pick/1, cap/0, fallback/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(URL, <<"https://models.dev/api.json">>).
-define(REFRESH_MS, 24 * 3600 * 1000).
-define(KEY, {?MODULE, index}).
-define(CAP, 32768).
-define(FALLBACK, 16384).
-define(CACHE_FILE, "models-dev.json").

-type info() :: #{provider := binary(), id := binary(), canonical := binary() | undefined,
                  context := pos_integer() | undefined, output := pos_integer() | undefined,
                  reasoning := boolean(), tool_call := boolean()}.

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec cap() -> pos_integer().
cap() -> ?CAP.

-spec fallback() -> pos_integer().
fallback() -> ?FALLBACK.

%% @doc The facts of a model (`provider/model` or a bare model id).
-spec lookup(binary()) -> {ok, info()} | undefined.
lookup(Spec) ->
    Index = loaded(),
    Model = model_id(Spec),
    Keys = lists:usort([lower(Model), lower(suffix(Model))]),
    case lists:append([maps:get(K, Index, []) || K <- Keys]) of
        [] -> undefined;
        Entries -> {ok, pick(Entries)}
    end.

%% @doc The `max_tokens` of a model's replies (see the module doc).
-spec max_tokens(binary()) -> pos_integer().
max_tokens(Spec) ->
    case muse_config:get(model_max_tokens, undefined) of
        N when is_integer(N), N > 0 -> N;
        _ ->
            case lookup(Spec) of
                {ok, #{output := Out}} when is_integer(Out), Out > 0 -> min(Out, ?CAP);
                _ -> ?FALLBACK
            end
    end.

%% @doc Fetch the catalogue now, keep it and index it.
-spec refresh() -> ok | {error, term()}.
refresh() ->
    case url() of
        off -> {error, disabled};
        Url ->
            case fetch(Url) of
                {ok, Json, Raw} ->
                    _ = save(Raw),
                    install(Json),
                    report(),
                    ok;
                {error, Reason} = Error ->
                    logger:warning("models.dev: could not fetch ~ts: ~0p", [Url, Reason]),
                    Error
            end
    end.

%% @doc models.dev's api.json -> model id (lower case, also the part after
%% `/`) -> entries.
-spec index(map()) -> #{binary() => [info()]}.
index(Json) when is_map(Json) ->
    Pairs = [{K, info(Provider, Id, M)}
             || {Provider, P} <- maps:to_list(Json), is_map(P),
                {Id, M} <- maps:to_list(models(P)), is_map(M),
                K <- lists:usort([lower(Id), lower(suffix(Id))])],
    lists:foldl(fun({K, I}, Acc) -> maps:update_with(K, fun(L) -> [I | L] end, [I], Acc) end,
                #{}, Pairs).

%% @doc The entry to use: the vendor's own, else the most conservative.
-spec pick([info()]) -> info().
pick(Entries) ->
    Own = [E || E = #{provider := P, canonical := C} <- Entries, is_binary(C),
                hd(binary:split(C, <<"/">>)) =:= P],
    case Own of
        [E | _] -> E;
        [] ->
            Min = fun(K) -> case [V || #{K := V} <- Entries, is_integer(V)] of
                                [] -> undefined;
                                Vs -> lists:min(Vs)
                            end
                  end,
            (hd(Entries))#{context := Min(context), output := Min(output)}
    end.

%% gen_server

init([]) ->
    _ = loaded(),
    self() ! refresh,
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(refresh, State) ->
    _ = refresh(),
    erlang:send_after(?REFRESH_MS, self(), refresh),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Internal

url() ->
    case muse_config:get(models_dev_url, ?URL) of
        <<"off">> -> off;
        U -> U
    end.

%% The index, loading the cache file on first use.
loaded() ->
    case persistent_term:get(?KEY, undefined) of
        undefined ->
            Index = case file:read_file(cache_path()) of
                        {ok, Raw} ->
                            case muse_json:decode(Raw) of
                                {ok, Json} when is_map(Json) -> index(Json);
                                _ -> #{}
                            end;
                        _ -> #{}
                    end,
            persistent_term:put(?KEY, Index),
            Index;
        Index ->
            Index
    end.

install(Json) ->
    persistent_term:put(?KEY, index(Json)).

report() ->
    case muse_config:get(model, undefined) of
        Spec when is_binary(Spec) ->
            case lookup(Spec) of
                {ok, #{provider := P, context := C, output := O}} ->
                    logger:notice("models.dev: ~ts is ~ts's (context ~p, output ~p); max_tokens ~p",
                                  [Spec, P, C, O, max_tokens(Spec)]);
                undefined ->
                    logger:notice("models.dev: ~ts is not listed; max_tokens ~p", [Spec, max_tokens(Spec)])
            end;
        _ -> ok
    end.

fetch(Url) ->
    try beamai_http:request_meta(get, Url, [{<<"accept">>, <<"application/json">>}], <<>>,
                                 #{timeout => 60000, retry => 1}) of
        {ok, Resp, #{status := 200}} -> decoded(Resp);
        {ok, Resp, Meta} when not is_map_key(status, Meta) -> decoded(Resp);
        {ok, _, #{status := Status}} -> {error, {status, Status}};
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

decoded(Json) when is_map(Json) ->
    {ok, Json, muse_json:encode(Json)};
decoded(Raw) when is_binary(Raw) ->
    case muse_json:decode(Raw) of
        {ok, Json} when is_map(Json), map_size(Json) > 0 -> {ok, Json, Raw};
        _ -> {error, invalid_json}
    end;
decoded(_Other) ->
    {error, unexpected_body}.

save(Raw) ->
    Path = cache_path(),
    Tmp = Path ++ ".tmp",
    ok = filelib:ensure_dir(Path),
    case file:write_file(Tmp, Raw) of
        ok -> file:rename(Tmp, Path);
        Error -> Error
    end.

cache_path() ->
    filename:join(binary_to_list(muse_config:get(data_dir, <<".muse">>)), ?CACHE_FILE).

models(P) ->
    case maps:get(<<"models">>, P, #{}) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

info(Provider, Id, M) ->
    Limit = case maps:get(<<"limit">>, M, #{}) of L when is_map(L) -> L; _ -> #{} end,
    Int = fun(K) -> case maps:get(K, Limit, undefined) of V when is_integer(V), V > 0 -> V; _ -> undefined end end,
    #{provider => Provider, id => Id,
      canonical => case maps:get(<<"canonical_model_id">>, M, undefined) of C when is_binary(C) -> C; _ -> undefined end,
      context => Int(<<"context">>), output => Int(<<"output">>),
      reasoning => maps:get(<<"reasoning">>, M, false) =:= true,
      tool_call => maps:get(<<"tool_call">>, M, false) =:= true}.

%% `openai/qwen3.8-flash` -> `qwen3.8-flash`; a bare id stays.
model_id(Spec) ->
    case binary:split(Spec, [<<"/">>, <<":">>]) of
        [_Provider, Model] -> Model;
        [Model] -> Model
    end.

suffix(Id) ->
    lists:last(binary:split(Id, <<"/">>, [global])).

lower(B) -> string:lowercase(B).
