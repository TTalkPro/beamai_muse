-module(muse_core_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

-spec start_link(binary()) -> {ok, pid()} | ignore | {error, term()}.
start_link(DataDir) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, DataDir).

-spec init(binary()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(DataDir) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Casks = [cask(events, DataDir, []),
             cask(chat, DataDir, []),
             cask(chat_index, DataDir, [{analyzer, jieba}]),
             cask(blobs, DataDir, [])],
    RateLimit = #{id => muse_rate_limit,
                  start => {muse_rate_limit, start_link, []}},
    {ok, {SupFlags, [RateLimit | Casks]}}.

cask(Name, DataDir, Opts) ->
    Dir = filename:join([DataDir, "bitcask", atom_to_list(Name)]),
    #{id => {muse_cask, Name},
      start => {muse_cask, start_link, [Name, Dir, Opts]},
      shutdown => 10000}.
