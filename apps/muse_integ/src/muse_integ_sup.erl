-module(muse_integ_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [#{id => muse_pdf, start => {muse_pdf, start_link, []},
                  shutdown => 5000, modules => [muse_pdf]},
                %% the IMAP/SMTP sidecar (built-in mail, M9-8)
                #{id => muse_mail_client, start => {muse_mail_client, start_link, []},
                  shutdown => 5000, modules => [muse_mail_client]},
                %% computer pool: idle stop, retention, reconcile
                #{id => muse_computer_pool, start => {muse_computer_pool, start_link, []},
                  shutdown => 5000, modules => [muse_computer_pool]},
                %% per-user browser containers: idle stop, activity table
                #{id => muse_browser_pool, start => {muse_browser_pool, start_link, []},
                  shutdown => 5000, modules => [muse_browser_pool]}],
    {ok, {SupFlags, Children}}.
