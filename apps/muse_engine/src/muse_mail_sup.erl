%% @doc Supervisor of the mail sync processes (muse_mail_sync, one per
%% account, transient). Started by muse_engine_sup where the task worker
%% runs; right after it starts, every stored account gets its process.
-module(muse_mail_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    case supervisor:start_link({local, ?MODULE}, ?MODULE, []) of
        {ok, Pid} ->
            _ = proc_lib:spawn(fun start_all/0),
            {ok, Pid};
        Other ->
            Other
    end.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 60},
          [#{id => muse_mail_sync, start => {muse_mail_sync, start_link, []},
             restart => transient, shutdown => 10000, modules => [muse_mail_sync]}]}}.

start_all() ->
    lists:foreach(fun({Owner, #{<<"id">> := Id}}) -> muse_mail_sync:ensure(Owner, Id) end,
                  muse_store:scan(<<"mail-accounts">>)).
