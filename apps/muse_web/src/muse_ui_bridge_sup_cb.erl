%% @doc simple_one_for_one supervisor callback for per-owner UI bridges
%% (`[]`) and per-thread chat relays (`{Module}`).
-module(muse_ui_bridge_sup_cb).
-behaviour(supervisor).

-export([init/1]).

-spec init([] | {module()}) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    init({muse_ui_bridge});
init({Module}) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 10},
          [#{id => Module, start => {Module, start_link, []}, restart => temporary}]}}.
