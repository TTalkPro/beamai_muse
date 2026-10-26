-module(muse_web_sup).
-behaviour(supervisor).

-export([start_link/0, init/1, dispatch/0]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% The cowboy listener is embedded in this supervisor (ranch:child_spec/5):
%% a listener started with cowboy:start_clear/3 lives under ranch_sup and
%% would ignore our shutdown, hanging application:stop/1.
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, Ip} = inet:parse_address(binary_to_list(host())),
    Listener = ranch:child_spec(muse_http, ranch_tcp,
                                #{socket_opts => [{ip, Ip}, {port, muse_config:get(port)}]},
                                cowboy_clear,
                                #{env => #{dispatch => dispatch()},
                                  middlewares => [muse_mw, cowboy_router, cowboy_handler],
                                  idle_timeout => 120000}),
    {ok, {SupFlags, [muse_ui_bridge:child_spec(), muse_chat_relay:child_spec(), Listener]}}.

host() ->
    case muse_config:get(host) of
        <<"localhost">> -> <<"127.0.0.1">>;
        H -> H
    end.

-spec dispatch() -> cowboy_router:dispatch_rules().
dispatch() ->
    Pages = [{iolist_to_binary(["/", atom_to_binary(Key), "/[...]"]), muse_ui_page, Key}
             || {Key, _} <- muse_ui_page:modules()],
    %% aihtml's action and events endpoints, behind the session cookie
    %% (also re-checked by the events stream at every heartbeat); Origin may
    %% be the public URL's as well as the request's host (behind a proxy)
    Gated = aihtml_cowboy:routes(#{static => false, authorize => fun muse_ui:authorize/1,
                                   origins => muse_mw:allowed_origins()}),
    cowboy_router:compile(
      [{'_', Gated ++
             [{"/", muse_root, #{}},
              {"/login", muse_ui_login, login},
              {"/logout", muse_ui_login, logout},
              {"/upload", muse_ui_b_upload, #{}},
              {"/computer-files/:id/:op", muse_ui_computer_files, #{}},
              {"/mail-content/:id/:op", muse_ui_mail_content, #{}},
              {"/static/[...]", cowboy_static, {priv_dir, muse_web, "static"}},
              {"/aihtml/[...]", cowboy_static, {priv_dir, aihtml, "static"}},
              {"/api/agui/[...]", muse_agui_handler, #{}},
              {"/api/[...]", muse_api, #{}}]
             ++ Pages}]).
