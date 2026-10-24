-module(muse_core_app).
-behaviour(application).

-export([start/2, stop/1]).

%% Boot order: configuration, signing key, Mnesia (+ action recovery), then
%% the supervisor that owns the bitcask directories and rate-limit tables.
%%
%% App env `{muse_core, [{env, #{<<"NAME">> => <<"value">>}}]}` replaces the
%% process environment (tests); `{storage, ram}` keeps Mnesia in memory.
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case load_config() of
        {ok, #{data_dir := DataDir} = Config} ->
            ok = muse_signing:init(DataDir),
            ok = ui_secret(Config),
            Storage = application:get_env(muse_core, storage, disc),
            case muse_store:init(#{dir => filename:join(DataDir, "mnesia"), storage => Storage}) of
                ok ->
                    Recovered = muse_store:recover_interrupted_actions(),
                    Recovered > 0 andalso
                        logger:warning("~b interrupted action(s) marked outcome_unknown", [Recovered]),
                    muse_core_sup:start_link(DataDir);
                {error, Reason} ->
                    {error, {store, Reason}}
            end;
        {error, Msg} ->
            logger:error("[OpenMuse] ~ts", [Msg]),
            {error, {config, Msg}}
    end.

%% Mnesia is not stopped here: application:stop(mnesia) from inside the
%% application controller's stop of muse_core deadlocks. The release stops
%% it with the node; tests stop it after their applications.
-spec stop(term()) -> ok.
stop(_State) ->
    ok.

%% The aihtml signing secret (actions, push topics): MUSE_UI_SECRET, or in
%% sample mode a random one kept in DATA_DIR/ui-secret so open pages keep
%% working across restarts. Set before aihtml starts (it starts after us).
ui_secret(#{ui_secret := Secret}) when is_binary(Secret) ->
    application:set_env(aihtml, secret, Secret);
ui_secret(#{data_dir := DataDir}) ->
    Path = filename:join(DataDir, "ui-secret"),
    Secret = case file:read_file(Path) of
                 {ok, S} when byte_size(S) >= 32 -> S;
                 _ ->
                     S = muse_ids:random_token(32),
                     ok = file:write_file(Path, S),
                     ok = file:change_mode(Path, 8#600),
                     S
             end,
    application:set_env(aihtml, secret, Secret).

load_config() ->
    case application:get_env(muse_core, env) of
        {ok, Env} when is_map(Env) ->
            case muse_config:from_env(Env) of
                {ok, Config} -> muse_config:set(Config), {ok, Config};
                Error -> Error
            end;
        undefined ->
            muse_config:load()
    end.
