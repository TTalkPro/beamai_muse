%% The desktop variant of the Docker computer (COMPUTER_DESKTOP=true) on the
%% computer page and the `/api/computer/desktop*` routes. `muse_docker:run/2`
%% is mocked with a fixture of a running desktop container, so neither
%% Docker nor the desktop image is needed; everything above it
%% (muse_computer_docker, muse_computer_desktop, the lease, receipts and
%% screenshot storage) is real.
-module(muse_ui_desktop_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([desktop_page/1, desktop_poll/1, stopped_page/1, light_variant/1, desktop_api/1,
         use_desktop_card/1, management_page/1, network_hint/1]).

-define(OWNER, <<"local-user">>).
-define(T, muse_ui_desktop_fixture).
-define(JPEG, <<255, 216, 255, 224, "fake">>).
%% An older version's default computer, which keeps OpenMuse's names.
-define(LEGACY(O), {O, muse_computers:legacy_id(O)}).

all() ->
    [desktop_page, desktop_poll, stopped_page, light_variant, desktop_api, use_desktop_card,
     management_page, network_hint].

init_per_testcase(Case, Config) ->
    Desktop = case Case of
                  light_variant -> <<"false">>;
                  _ -> <<"true">>
              end,
    Network = case Case of
                  network_hint -> <<"bridge">>;
                  _ -> <<"none">>
              end,
    Env = muse_web_test_env:start(#{<<"COMPUTER_ENABLED">> => <<"true">>,
                                    <<"COMPUTER_DESKTOP">> => Desktop,
                                    <<"COMPUTER_NETWORK">> => Network,
                                    <<"COMPUTER_DEPLOYMENT_ID">> => <<"dep-ui">>}),
    Holder = spawn(fun() -> receive stop -> ok end end),
    ?T = ets:new(?T, [named_table, public, {heir, none}]),
    ets:give_away(?T, Holder, none),
    ets:insert(?T, [{running, true}, {variant, binary_to_atom(Desktop) =:= true}, {network, Network}]),
    ok = meck:new(muse_docker, [passthrough]),
    meck:expect(muse_docker, run, fun runner/2),
    [{env, Env}, {holder, Holder} | Config].

end_per_testcase(_Case, Config) ->
    meck:unload(muse_docker),
    ?config(holder, Config) ! stop,
    muse_web_test_env:stop(?config(env, Config)).

%% Docker fixture: a desktop (or light) container of the owner.

ok(Out) ->
    #{stdout => Out, stderr => <<>>, exit_code => 0, timed_out => false, interrupted => false,
      truncated => false}.

runner(Args, _Opts) ->
    ets:insert(?T, {{call, erlang:unique_integer([monotonic, positive])}, Args}),
    reply(Args).

reply([<<"container">>, <<"ls">> | Rest]) ->
    case lists:member(<<"label=dev.openmuse.managed=computer-v1">>, Rest) of
        %% the pool's listing: the owner's default container, when running
        true ->
            #{container := C, owner_hash := H} = muse_computer:identity(?LEGACY(?OWNER)),
            case ets:lookup(?T, running) of
                [{running, true}] -> ok(<<C/binary, "\trunning\t", H/binary, "\t\t\n">>);
                _ -> ok(<<>>)
            end;
        %% find: only the default container exists
        false ->
            #{container := C} = muse_computer:identity(?LEGACY(?OWNER)),
            case lists:member(<<"name=^/", C/binary, "$">>, Rest) of
                true -> ok(<<"cid\n">>);
                false -> ok(<<>>)
            end
    end;
reply([<<"volume">>, <<"ls">>, <<"--filter">>, <<"name=^", Filter/binary>> | _]) ->
    ok(binary:part(Filter, 0, byte_size(Filter) - 1));
reply([<<"container">>, <<"stats">> | _]) ->
    #{container := C} = muse_computer:identity(?LEGACY(?OWNER)),
    ok(<<C/binary, "\t1.50%\t20MiB / 1.5GiB\n">>);
reply([<<"container">>, <<"inspect">> | _]) -> ok(muse_json:encode([container()]));
reply([<<"volume">>, <<"inspect">> | _]) ->
    #{volume := V, labels := L} = muse_computer:identity(?LEGACY(?OWNER)),
    ok(muse_json:encode([#{<<"Name">> => V, <<"Labels">> => maps:from_list(L),
                           <<"Driver">> => <<"local">>, <<"Options">> => null,
                           <<"Scope">> => <<"local">>}]));
reply([<<"exec">> | _] = Args) ->
    case lists:member(muse_computer_desktop:input_script(), Args) of
        true -> ok(<<>>);
        false -> ok(base64:encode(?JPEG))
    end;
reply(_) -> ok(<<>>).

container() ->
    #{container := C, volume := V, labels := L} = muse_computer:identity(?LEGACY(?OWNER)),
    [{running, Running}] = ets:lookup(?T, running),
    [{network, Network}] = ets:lookup(?T, network),
    #{<<"Id">> => <<"cid">>, <<"Name">> => <<"/", C/binary>>,
      <<"Config">> => #{<<"Image">> => <<"openmuse-computer-desktop:local">>,
                        <<"User">> => <<"1000:1000">>,
                        <<"Labels">> => maps:from_list([{<<"dev.openmuse.variant">>, <<"desktop">>} | L]),
                        <<"Env">> => [<<"PATH=/usr/bin:/bin">>, <<"HOME=/workspace">>,
                                      <<"LANG=C.UTF-8">>, <<"DISPLAY=:0">>],
                        <<"Entrypoint">> => [<<"/opt/openmuse/desktop-init">>], <<"Cmd">> => null,
                        <<"WorkingDir">> => <<"/workspace">>},
      <<"HostConfig">> => #{<<"ReadonlyRootfs">> => true, <<"Privileged">> => false,
                            <<"CapDrop">> => [<<"ALL">>], <<"CapAdd">> => null,
                            <<"SecurityOpt">> => [<<"no-new-privileges">>],
                            <<"NetworkMode">> => Network,
                            <<"Memory">> => 1610612736, <<"MemorySwap">> => 1610612736,
                            <<"PidsLimit">> => 512, <<"NanoCpus">> => 2000000000,
                            <<"Binds">> => null, <<"Devices">> => [], <<"DeviceRequests">> => null,
                            <<"PortBindings">> => #{}, <<"PidMode">> => <<>>,
                            <<"IpcMode">> => <<"private">>,
                            <<"Tmpfs">> => #{<<"/tmp">> =>
                                                 <<"rw,nosuid,nodev,noexec,size=268435456,mode=1777">>},
                            <<"RestartPolicy">> => #{<<"Name">> => <<"no">>}},
      <<"Mounts">> => [#{<<"Type">> => <<"volume">>, <<"Name">> => V,
                         <<"Destination">> => <<"/workspace">>, <<"RW">> => true}],
      <<"NetworkSettings">> => #{<<"Networks">> => #{Network => #{}}},
      <<"State">> => #{<<"Running">> => Running}}.

calls() ->
    [A || {_, A} <- lists:sort([{N, A} || {{call, N}, A} <- ets:tab2list(?T)])].

%% The xdotool argv of every input exec, in order.
inputs() ->
    Script = muse_computer_desktop:input_script(),
    [lists:nthtail(16, A) || A = [<<"exec">> | _] <- calls(), lists:member(Script, A)].

%% HTTP helpers (as in muse_ui_pages_b_SUITE)

host(Config) ->
    #{port := Port} = ?config(env, Config),
    "localhost:" ++ integer_to_list(Port).

origin(_Config) -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

same_origin(Config) -> [{"origin", origin(Config)}, {"host", host(Config)}].

req(Config, Method, Path, Headers, Body) ->
    Url = muse_web_test_env:base(?config(env, Config)) ++ Path,
    Request = case Body of
                  undefined -> {Url, Headers};
                  {form, Form} -> {Url, Headers, "application/x-www-form-urlencoded", uri_string:compose_query(Form)};
                  {Type, Bin} -> {Url, Headers, Type, Bin}
              end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{autoredirect, false}, {timeout, 30000}], [{body_format, binary}]),
    {Status, RespHeaders, RespBody}.

sign_in(Config) ->
    {302, H, _} = req(Config, post, "/login", same_origin(Config), {form, []}),
    [SetCookie] = [V || {"set-cookie", V} <- H],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

cookie(Cookie) -> [{"cookie", "muse_session=" ++ Cookie}].

page(Config, Cookie, Path) ->
    {200, _, Html} = req(Config, get, Path, cookie(Cookie), undefined),
    Html.

act(Config, Cookie, Ref, Event) ->
    Body = muse_json:encode(#{<<"action">> => aihtml_action:token(Ref), <<"event">> => Event}),
    {200, _, Resp} = req(Config, post, "/aihtml/action", cookie(Cookie) ++ same_origin(Config),
                         {"application/json", Body}),
    lists:append([Ops || L <- binary:split(Resp, <<"\n">>, [global, trim_all]),
                         {ok, #{<<"ops">> := Ops}} <- [muse_json:decode(L)]]).

rendered(Ops) ->
    iolist_to_binary([[V || K <- [<<"html">>, <<"value">>], V <- [maps:get(K, Op, <<>>)], is_binary(V)]
                      || Op <- Ops]).

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

click() -> #{<<"type">> => <<"click">>}.

%% The fixture's container is an older version's default computer (the
%% legacy computer, OpenMuse's names); its page needs its record.
detail() ->
    #{<<"id">> := Id} = muse_computers:ensure(?OWNER, <<"user">>),
    "/computer/" ++ binary_to_list(Id).

%% A computer route of the legacy computer.
capi(Path) ->
    Path ++ case lists:member($?, Path) of true -> "&"; false -> "?" end
        ++ "computer=" ++ binary_to_list(muse_computers:legacy_id(?OWNER)).

%% Cases

%% `/computer`: the table of the owner's computers (pool records), with the
%% live state and resources from Docker, and the list actions.
management_page(Config) ->
    Cookie = sign_in(Config),
    Empty = page(Config, Cookie, "/computer"),
    ?assert(has(Empty, <<"还没有电脑"/utf8>>)),
    {ok, #{<<"id">> := Thread}} = muse_threads:create_side(?OWNER, <<"写季度报告"/utf8>>),
    {?OWNER, ThreadId} = muse_computer:ensure(?OWNER, <<"thread:", Thread/binary>>),
    {?OWNER, TaskId} = muse_computer:ensure(?OWNER, <<"task:k-1">>),
    {?OWNER, _} = muse_computer:ensure(?OWNER, <<"user">>),
    Html = page(Config, Cookie, "/computer"),
    [?assert(has(Html, P), P) || P <- [<<"id=\"comp-table\"">>, <<"muse-table">>,
                                       <<"写季度报告"/utf8>>, <<"旧的默认电脑"/utf8>>, <<"task:k-1">>,
                                       <<"运行中"/utf8>>, <<"已停止"/utf8>>, <<"桌面"/utf8>>,
                                       <<"CPU 1.50%">>, <<"20MiB / 1.5GiB">>,
                                       <<"运行中 1 / 上限 4"/utf8>>, <<"空闲 15 分钟后自动停止"/utf8>>,
                                       <<"/computer/", ThreadId/binary>>, <<"/computer/", TaskId/binary>>,
                                       <<"删除"/utf8>>, <<"data-variant=\"desktop\"">>]],
    %% the computer's own page; an unknown id is not found
    Detail = page(Config, Cookie, "/computer/" ++ binary_to_list(ThreadId)),
    ?assert(has(Detail, <<"写季度报告"/utf8>>)),
    ?assert(has(Detail, <<"全部电脑"/utf8>>)),
    ?assert(has(Detail, <<"/chat/", Thread/binary>>)),
    ?assert(has(page(Config, Cookie, "/computer/0123456789abcdef"), <<"找不到该电脑"/utf8>>)),
    %% delete from the list: the container and the record go
    Deleted = act(Config, Cookie, {muse_ui_computer, list_delete, #{id => TaskId}}, click()),
    ?assert(has(rendered(Deleted), <<"电脑已删除"/utf8>>)),
    ?assertEqual(undefined, muse_computers:get(?OWNER, TaskId)),
    #{volume := TaskVolume} = muse_computer:identity({?OWNER, TaskId}),
    ?assert(lists:member([<<"volume">>, <<"rm">>, TaskVolume], calls())),
    %% a deleted computer's actions report it
    Gone = act(Config, Cookie, {muse_ui_computer, list_start, #{id => TaskId}}, click()),
    ?assert(has(rendered(Gone), <<"找不到该电脑"/utf8>>)).

%% COMPUTER_NETWORK=bridge: the status says the computer is online.
network_hint(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, detail()),
    ?assert(has(Html, <<"可联网"/utf8>>)),
    ?assertNot(has(Html, <<"电脑不联网"/utf8>>)).

%% The page only watches the desktop: a live picture, no input controls,
%% no terminal; the agent's commands are listed with their output.
desktop_page(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, detail()),
    [?assert(has(Html, P), P) || P <- [<<"id=\"comp-desktop-shot\"">>, <<"id=\"comp-desktop-stage\"">>,
                                       <<"data-ah-poll">>, <<":2000\"">>,
                                       <<"/api/computer/desktop/screenshot?owner=local-user&amp;expires=">>,
                                       <<"&amp;live=1">>, <<"只读的实时画面"/utf8>>, <<"命令记录"/utf8>>,
                                       <<"旧版本的默认电脑"/utf8>>]],
    [?assertNot(has(Html, P), P) || P <- [<<"comp-desktop-actions">>, <<"comp-desktop-type">>,
                                          <<"comp-desktop-key">>, <<"comp-term">>, <<"comp-run">>,
                                          <<"comp-mkdir">>, <<"comp-import">>, <<"cursor-crosshair">>]],
    %% no screenshot was taken while rendering (the browser loads the live frame)
    ?assertEqual([], [A || A = [<<"exec">> | _] <- calls(), lists:member(<<"DISPLAY=:0">>, A)]).

%% The poll swaps in a fresh signed live-frame URL and sends no input.
desktop_poll(Config) ->
    Cookie = sign_in(Config),
    #{<<"id">> := Id} = muse_computers:ensure(?OWNER, <<"user">>),
    Poll = act(Config, Cookie, {muse_ui_computer, desktop_frame, #{id => Id}}, #{<<"type">> => <<"poll">>}),
    ?assert(lists:any(fun(#{<<"id">> := <<"comp-desktop-shot">>, <<"value">> := V}) ->
                              has(V, <<"&live=1">>) andalso has(V, <<"&computer=", Id/binary>>);
                         (_) -> false
                      end, Poll), Poll),
    ?assertEqual([], inputs()),
    ?assertEqual([], muse_store:list(?OWNER, <<"computer-desktop-actions">>)).

stopped_page(Config) ->
    Cookie = sign_in(Config),
    ets:insert(?T, {running, false}),
    Html = page(Config, Cookie, detail()),
    ?assertNot(has(Html, <<"comp-desktop">>)),
    ?assert(has(Html, <<"启动电脑后可以查看"/utf8>>)).

light_variant(Config) ->
    Cookie = sign_in(Config),
    %% COMPUTER_DESKTOP off: a desktop container is refused, there is no card and no route
    Html = page(Config, Cookie, detail()),
    ?assertNot(has(Html, <<"comp-desktop">>)),
    ?assert(has(Html, <<"is the desktop variant but COMPUTER_DESKTOP is not enabled">>)),
    Env = ?config(env, Config),
    T = muse_web_test_env:login(Env),
    {404, <<"404 Not Found">>, _} = muse_web_test_env:http(Env, get, "/api/computer/desktop", T),
    {404, <<"404 Not Found">>, _} = muse_web_test_env:http(Env, post, "/api/computer/desktop/actions", T,
                                                           #{<<"action">> => <<"screenshot">>}),
    {404, <<"404 Not Found">>, _} = muse_web_test_env:http(Env, get, "/api/computer/desktop/screenshot?live=1", T),
    ?assertEqual([], [A || A = [<<"exec">> | _] <- calls()]).

desktop_api(Config) ->
    Env = ?config(env, Config),
    _ = muse_computers:ensure(?OWNER, <<"user">>),
    T = muse_web_test_env:login(Env),
    H = fun(Method, Path, Token) -> muse_web_test_env:http(Env, Method, Path, Token) end,
    {200, S0} = H(get, capi("/api/computer/desktop"), T),
    ?assertEqual(#{<<"status">> => <<"running">>, <<"running">> => true, <<"width">> => 1280,
                   <<"height">> => 800, <<"screenshot">> => null, <<"takenAt">> => null}, S0),
    {200, Reply} = muse_web_test_env:http(Env, post, capi("/api/computer/desktop/actions"), T,
                                          #{<<"action">> => <<"screenshot">>}),
    #{<<"receipt">> := #{<<"id">> := Id, <<"command">> := <<"desktop screenshot">>,
                         <<"status">> := <<"succeeded">>},
      <<"width">> := 1280, <<"height">> := 800} = Reply,
    ?assertNot(maps:is_key(<<"warning">>, Reply)),
    ?assertNot(maps:is_key(<<"data">>, Reply)),
    {200, #{<<"screenshot">> := Url, <<"receiptId">> := Id}} = H(get, capi("/api/computer/desktop"), T),
    {422, #{<<"error">> := <<"Use xdotool key names, e.g. ctrl+l">>}} =
        muse_web_test_env:http(Env, post, capi("/api/computer/desktop/actions"), T,
                               #{<<"action">> => <<"key">>, <<"text">> => <<"a;b">>}),
    {422, #{<<"error">> := <<"The screen is 1280x800">>}} =
        muse_web_test_env:http(Env, post, capi("/api/computer/desktop/actions"), T,
                               #{<<"action">> => <<"left_click">>, <<"coordinate">> => [1280, 0]}),
    {400, _} = muse_web_test_env:http(Env, post, capi("/api/computer/desktop/actions"), T, {raw, "application/json", <<"{">>}),
    %% the screenshot: Bearer or a signed URL, never cached
    {200, ?JPEG, Headers} = H(get, capi("/api/computer/desktop/screenshot"), T),
    ?assertEqual("image/jpeg", proplists:get_value("content-type", Headers)),
    ?assertEqual("no-store", proplists:get_value("cache-control", Headers)),
    {200, ?JPEG, _} = H(get, binary_to_list(Url), undefined),
    {200, ?JPEG, LiveHeaders} = H(get, binary_to_list(muse_computer_desktop:frame_url(?LEGACY(?OWNER))), undefined),
    ?assertEqual("no-store", proplists:get_value("cache-control", LiveHeaders)),
    {404, #{<<"error">> := <<"No desktop screenshot yet">>}} =
        H(get, binary_to_list(muse_computer_desktop:screenshot_url(?LEGACY(?OWNER), <<"r-9">>)), undefined),
    {401, _} = H(get, capi("/api/computer/desktop/screenshot"), undefined),
    {401, _} = H(get, capi("/api/computer/desktop/screenshot?live=1"), undefined),
    %% a signature only opens the screenshot, not the other desktop routes
    Query = tl(lists:dropwhile(fun(C) -> C =/= $? end, binary_to_list(Url))),
    {401, _} = H(get, "/api/computer/desktop?" ++ Query, undefined),
    %% a stopped computer: status says so, live frames are a 409
    ets:insert(?T, {running, false}),
    {200, #{<<"status">> := <<"stopped">>, <<"running">> := false}} = H(get, capi("/api/computer/desktop"), T),
    {409, #{<<"error">> := <<"Start the computer before using its terminal or files">>}} =
        H(get, capi("/api/computer/desktop/screenshot?live=1"), T).

use_desktop_card(_Config) ->
    Card = iolist_to_binary(aihtml_html:render(
                              muse_ui_cards:render(?OWNER, <<"t1">>, <<"c1">>, <<"use_desktop">>,
                                                   #{<<"action">> => <<"screenshot">>},
                                                   muse_json:encode(#{<<"status">> => <<"succeeded">>,
                                                                      <<"action">> => <<"desktop screenshot">>,
                                                                      <<"screenshot">> => <<"attached as an image for this step only">>,
                                                                      <<"screenshotUrl">> => <<"/api/computer/desktop/screenshot?owner=x">>})))),
    %% one line, "操作了桌面 · 截图", that opens to the screenshot
    ?assert(has(Card, <<"操作了桌面 · 截图"/utf8>>)),
    ?assert(has(Card, <<"src=\"/api/computer/desktop/screenshot?owner=x\"">>)),
    ?assert(has(Card, <<"<details">>)),
    Failed = iolist_to_binary(aihtml_html:render(
                                muse_ui_cards:render(?OWNER, <<"t1">>, <<"c2">>, <<"use_desktop">>, #{},
                                                     muse_json:encode(#{<<"error">> => <<"Start the computer first">>})))),
    ?assert(has(Failed, <<"Start the computer first">>)),
    ?assertNot(has(Failed, <<"<img">>)).
