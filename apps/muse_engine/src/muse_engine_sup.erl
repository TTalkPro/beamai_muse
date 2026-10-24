-module(muse_engine_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% The task worker and maintenance run only when TASK_WORKER_ENABLED is not
%% "false" (a separate worker node may take that role).
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Events = #{id => muse_events, start => {muse_events, start_link, []}},
    Workers = case muse_config:get(task_worker_enabled, true) of
                  true ->
                      [#{id => muse_task_worker, start => {muse_task_worker, start_link, []},
                         shutdown => 15000},
                       #{id => muse_maintainer, start => {muse_maintainer, start_link, []}}];
                  false ->
                      []
              end,
    {ok, {SupFlags, [Events | Workers]}}.
