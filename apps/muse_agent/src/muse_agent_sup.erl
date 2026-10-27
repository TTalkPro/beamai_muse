-module(muse_agent_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    %% models.dev, for the configured model's limits (muse_model_info)
    Info = #{id => muse_model_info, start => {muse_model_info, start_link, []}},
    {ok, {SupFlags, [Info]}}.
