%% Real desktop variant of the Docker computer (COMPUTER_DESKTOP=true). Runs
%% only with MUSE_TEST_DOCKER=1; builds openmuse-computer-desktop:local from
%% computer/Dockerfile.desktop when it is missing. Uses a unique deployment
%% id and removes its container and volume afterwards.
-module(muse_computer_desktop_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([network_refused/1, pool_desktop/1, browser_in_desktop/1]).
-export([isolation/1, display/1, screenshot/1, type_into_xterm/1, live_frame/1,
         offline_apps/1, variant_refused/1, stop_and_restart/1]).

-define(O, <<"local-user">>).
-define(IMAGE, <<"openmuse-computer-desktop:local">>).
%% An older version's default computer, which keeps OpenMuse's names.
-define(LEGACY(O), {O, muse_computers:legacy_id(O)}).

all() -> [{group, desktop}].

groups() ->
    [{desktop, [sequence],
      [isolation, display, screenshot, type_into_xterm, live_frame, offline_apps,
       variant_refused, network_refused, stop_and_restart, pool_desktop, browser_in_desktop]}].

init_per_suite(Config) ->
    case os:getenv("MUSE_TEST_DOCKER") of
        "1" -> setup(Config);
        _ -> {skip, "Set MUSE_TEST_DOCKER=1 to run the Docker desktop computer suite"}
    end.

setup(Config) ->
    {ok, _} = application:ensure_all_started(erlexec),
    ok = muse_store:init(#{storage => ram}),
    Dir = filename:join(?config(priv_dir, Config), "data"),
    ok = filelib:ensure_path(Dir),
    ok = muse_signing:init(Dir),
    configure(Dir, true),
    ensure_image(),
    [{identity, muse_computer:identity(?LEGACY(?O))}, {muse_data_dir, Dir} | Config].

configure(Dir, Desktop) ->
    configure(Dir, Desktop, #{}).

configure(Dir, Desktop, Extra) ->
    Passthrough = [<<"PATH">>, <<"HOME">>, <<"DOCKER_HOST">>, <<"DOCKER_CONTEXT">>,
                   <<"DOCKER_CONFIG">>, <<"DOCKER_TLS_VERIFY">>, <<"DOCKER_CERT_PATH">>],
    Env = maps:from_list([{K, list_to_binary(V)} || K <- Passthrough,
                                                    V <- [os:getenv(binary_to_list(K))],
                                                    V =/= false]),
    Deployment = case persistent_term:get({?MODULE, deployment}, undefined) of
                     undefined ->
                         D = <<"ct-desk-", (muse_ids:uuid())/binary>>,
                         persistent_term:put({?MODULE, deployment}, D),
                         D;
                     D -> D
                 end,
    {ok, C} = muse_config:from_env(maps:merge(Env#{<<"COMPUTER_ENABLED">> => <<"true">>,
                                                   <<"COMPUTER_DESKTOP">> => atom_to_binary(Desktop),
                                                   <<"COMPUTER_DEPLOYMENT_ID">> => Deployment,
                                                   <<"DATA_DIR">> => list_to_binary(Dir)}, Extra)),
    muse_config:set(C).

%% Every container and volume of this run's deployment.
end_per_suite(Config) ->
    #{container := Container, volume := Volume} = proplists:get_value(identity, Config),
    Label = <<"label=dev.openmuse.deployment=", (muse_computer:deployment())/binary>>,
    #{stdout := Cs} = muse_docker:run([<<"container">>, <<"ls">>, <<"--all">>, <<"--filter">>, Label,
                                       <<"--format">>, <<"{{.Names}}">>], #{timeout => 20000}),
    Containers = binary:split(Cs, <<"\n">>, [global, trim_all]),
    _ = [muse_docker:run([<<"container">>, <<"rm">>, <<"--force">>, N], #{timeout => 20000}) || N <- Containers],
    #{stdout := Vs} = muse_docker:run([<<"volume">>, <<"ls">>, <<"--filter">>, Label,
                                       <<"--format">>, <<"{{.Name}}">>], #{timeout => 20000}),
    Volumes = binary:split(Vs, <<"\n">>, [global, trim_all]),
    _ = [muse_docker:run([<<"volume">>, <<"rm">>, V], #{timeout => 20000}) || V <- Volumes],
    persistent_term:erase({?MODULE, deployment}),
    muse_store:stop(),
    ct:pal("removed containers ~p and volumes ~p", [Containers, Volumes]),
    ?assert(lists:member(Container, Containers)),
    ?assert(lists:member(Volume, Volumes)),
    #{stdout := Left} = muse_docker:run([<<"container">>, <<"ls">>, <<"--all">>, <<"--filter">>, Label,
                                         <<"--format">>, <<"{{.Names}}">>], #{timeout => 20000}),
    ?assertEqual(<<>>, Left),
    ok.

ensure_image() ->
    case muse_docker:run([<<"image">>, <<"inspect">>, ?IMAGE], #{timeout => 20000}) of
        #{exit_code := 0} ->
            ok;
        _ ->
            Dir = list_to_binary(computer_dir()),
            ct:pal("building ~s from ~s", [?IMAGE, Dir]),
            ?assertMatch(#{exit_code := 0},
                         muse_docker:run([<<"build">>, <<"--build-context">>,
                                          <<"browser=", (filename:join(filename:dirname(Dir), <<"browser">>))/binary>>,
                                          <<"-t">>, ?IMAGE, <<"-f">>,
                                          <<Dir/binary, "/Dockerfile.desktop">>, Dir],
                                         #{timeout => 1800000}))
    end.

computer_dir() ->
    Starts = [filename:dirname(code:which(?MODULE)), element(2, file:get_cwd())],
    hd([D || S <- Starts, D <- [find_up(filename:absname(S))], D =/= false]).

find_up("/") -> false;
find_up(Dir) ->
    Candidate = filename:join(Dir, "computer"),
    case filelib:is_regular(filename:join(Candidate, "Dockerfile.desktop")) of
        true -> Candidate;
        false -> find_up(filename:dirname(Dir))
    end.

run(Command) ->
    {ok, R} = muse_computer:execute(?LEGACY(?O), #{command => Command}),
    R.

act(Action) ->
    muse_computer_desktop:desktop_action(?LEGACY(?O), Action).

container(Config) ->
    maps:get(container, proplists:get_value(identity, Config)).

jpeg(<<16#FF, 16#D8, 16#FF, _/binary>> = Bin) -> byte_size(Bin) > 1000;
jpeg(_) -> false.

%% Poll a command until its stdout matches.
until(Command, Expected, 0) ->
    ?assertMatch(#{<<"stdout">> := Expected}, run(Command));
until(Command, Expected, N) ->
    case run(Command) of
        #{<<"stdout">> := Expected} -> ok;
        _ -> timer:sleep(500), until(Command, Expected, N - 1)
    end.

%% Cases

isolation(Config) ->
    %% COMPUTER_NETWORK=bridge (the default)
    ?assertMatch(#{<<"status">> := <<"stopped">>, <<"network">> := <<"enabled">>},
                 muse_computer:snapshot(?LEGACY(?O))),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?LEGACY(?O))),
    #{stdout := Json} = muse_docker:run(muse_docker:inspect_args(container(Config)),
                                        #{timeout => 10000}),
    {ok, [#{<<"HostConfig">> := H, <<"Config">> := C}]} = muse_json:decode(Json),
    ?assertMatch(#{<<"ReadonlyRootfs">> := true, <<"NetworkMode">> := <<"bridge">>,
                   <<"PidsLimit">> := 1024, <<"Privileged">> := false, <<"Init">> := true,
                   <<"CapDrop">> := [<<"ALL">>], <<"Memory">> := 2684354560,
                   <<"MemorySwap">> := 2684354560, <<"NanoCpus">> := 2000000000,
                   <<"ShmSize">> := 536870912, <<"IpcMode">> := <<"private">>}, H),
    %% the browser's seccomp profile (Chromium's sandbox), as it carries the browser
    ?assert(muse_browser_docker:security_opts(maps:get(<<"SecurityOpt">>, H))),
    ?assertEqual(#{}, maps:get(<<"PortBindings">>, H)),
    ?assertMatch(#{<<"User">> := <<"1000:1000">>, <<"Image">> := ?IMAGE,
                   <<"Entrypoint">> := [<<"/opt/openmuse/desktop-init">>],
                   <<"Labels">> := #{<<"dev.openmuse.variant">> := <<"desktop">>}}, C),
    ?assert(lists:member(<<"DISPLAY=:0">>, maps:get(<<"Env">>, C))),
    ?assertMatch(#{<<"stdout">> := <<"eth0\nlo\n">>}, run(<<"ls /sys/class/net">>)),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"stdout">> := <<"200\n">>},
                 run(<<"node -e 'fetch(\"https://example.com\").then(r => console.log(r.status))'">>)),
    ?assertMatch(#{<<"stdout">> := <<"1000\n">>}, run(<<"id -u">>)),
    ?assertMatch(#{<<"status">> := <<"failed">>}, run(<<"touch /usr/bin/openmuse-must-fail">>)),
    ?assertMatch(#{<<"stdout">> := <<"0000000000000000\n">>},
                 run(<<"grep CapEff /proc/self/status | cut -f2">>)).

display(_Config) ->
    %% the X server may still be starting right after `docker start`
    until(<<"xdotool getdisplaygeometry; echo ok">>, <<"1280 800\nok\n">>, 20),
    ?assertMatch(#{<<"stdout">> := <<":0\n">>}, run(<<"echo $DISPLAY">>)),
    until(<<"xprop -root _NET_SUPPORTING_WM_CHECK >/dev/null 2>&1 && echo wm">>, <<"wm\n">>, 20).

screenshot(Config) ->
    {ok, #{image := Image, receipt := R = #{<<"id">> := Id}, uncertain := false,
           warning := undefined}} = act(#{<<"action">> => <<"screenshot">>}),
    ?assert(jpeg(Image)),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"exitCode">> := 0,
                   <<"stdout">> := <<"Screenshot 1280x800">>}, R),
    {ok, #{bytes := Image}} = muse_computer_desktop:latest_screenshot(?LEGACY(?O), Id),
    Stored = filename:join([?config(muse_data_dir, Config), "desktop-screens",
                            <<(muse_ids:sha256hex(?O))/binary, ".jpg">>]),
    ?assertEqual({ok, Image}, file:read_file(Stored)),
    ct:pal("screenshot ~b bytes", [byte_size(Image)]).

type_into_xterm(_Config) ->
    %% `gui` detaches the app, so the command returns at once
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"stdout">> := <<"started xterm", _/binary>>},
                 run(<<"gui xterm -T musetest -geometry 80x20+0+0">>)),
    until(<<"xdotool search --name musetest >/dev/null && echo up">>, <<"up\n">>, 20),
    %% Xft fonts from the image's XTerm app-defaults: no "cannot load font" for the missing bitmap font
    ?assertMatch(#{<<"stdout">> := <<"0\n">>},
                 run(<<"grep -c 'cannot load font' /tmp/gui-xterm.log || true">>)),
    ?assertMatch(#{<<"status">> := <<"failed">>, <<"exitCode">> := 127},
                 run(<<"gui no-such-app">>)),
    %% focus it by clicking inside, then type a command with shell syntax:
    %% the text reaches xterm literally (single quotes keep it unexpanded)
    {ok, #{uncertain := false}} = act(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [100, 100]}),
    Text = <<"echo 'typed $(id) ok' > /workspace/typed.txt">>,
    {ok, #{uncertain := false, image := Image}} = act(#{<<"action">> => <<"type">>, <<"text">> => Text}),
    ?assert(jpeg(Image)),
    {ok, #{uncertain := false}} = act(#{<<"action">> => <<"key">>, <<"text">> => <<"Return">>}),
    until(<<"cat /workspace/typed.txt 2>/dev/null">>, <<"typed $(id) ok\n">>, 20),
    Receipts = muse_store:list(?O, <<"computer-desktop-actions">>),
    ?assert(lists:any(fun(#{<<"command">> := C}) ->
                              C =:= <<"desktop type \"echo 'typed $(id) ok' > /workspace/typed.txt\"">>
                      end, Receipts)),
    %% xdotool command names never chain from a key action
    ?assertEqual({error, {422, <<"Use xdotool key names, e.g. ctrl+l">>}},
                 act(#{<<"action">> => <<"key">>, <<"text">> => <<"shift Exec touch pwned">>})),
    ?assertMatch(#{<<"stdout">> := <<"no\n">>},
                 run(<<"ls /workspace/pwned 2>/dev/null || echo no">>)),
    %% idempotent replay never types again
    Key = <<"ct:replay">>,
    Wait = #{<<"action">> => <<"wait">>, <<"duration">> => 0.1},
    {ok, #{receipt := R1}} = muse_computer_desktop:desktop_action(?LEGACY(?O), Wait, #{idempotency_key => Key}),
    {ok, #{receipt := R1, warning := <<"This operation ID already has a receipt", _/binary>>}} =
        muse_computer_desktop:desktop_action(?LEGACY(?O), Wait, #{idempotency_key => Key}).

live_frame(_Config) ->
    Before = length(muse_store:list(?O, <<"computer-desktop-actions">>)),
    {ok, #{bytes := Frame, mime_type := <<"image/jpeg">>}} = muse_computer_desktop:frame(?LEGACY(?O)),
    ?assert(jpeg(Frame)),
    ?assertEqual(Before, length(muse_store:list(?O, <<"computer-desktop-actions">>))).

offline_apps(_Config) ->
    ?assertMatch(#{<<"status">> := <<"succeeded">>},
                 run(<<"command -v xterm mupdf soffice openbox scrot xdotool">>)),
    %% the right-click menu offers no web browser (the computer is offline)
    ?assertMatch(#{<<"stdout">> := <<"0\n">>},
                 run(<<"grep -c www-browser /etc/xdg/openbox/menu.xml || true">>)),
    ?assertMatch(#{<<"stdout">> := <<"xterm\n">>},
                 run(<<"grep -o '<execute>xterm</execute>' /etc/xdg/openbox/menu.xml | sed 's/<[^>]*>//g'">>)),
    #{<<"stdout">> := Fonts} = run(<<"fc-list : family | grep -c 'Noto Sans CJK'">>),
    ?assert(binary_to_integer(string:trim(Fonts)) > 0),
    %% LibreOffice works headless on the read-only root (profile in /workspace)
    Convert = run(<<"printf '你好 desktop\\n' > /workspace/hello.txt && "
                    "timeout 25 soffice --headless --convert-to pdf --outdir /workspace "
                    "/workspace/hello.txt >/dev/null 2>&1; head -c 5 /workspace/hello.pdf"/utf8>>),
    ct:pal("soffice: ~p", [Convert]),
    ?assertMatch(#{<<"stdout">> := <<"%PDF-">>}, Convert).

variant_refused(Config) ->
    %% the same container with COMPUTER_DESKTOP off is refused
    configure(?config(muse_data_dir, Config), false),
    try
        ?assertMatch({error, {409, <<"The existing computer container is the desktop variant", _/binary>>}},
                     muse_computer:execute(?LEGACY(?O), #{command => <<"true">>}))
    after
        configure(?config(muse_data_dir, Config), true)
    end,
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, run(<<"true">>)).

network_refused(Config) ->
    %% the same (bridge) container with COMPUTER_NETWORK=none is refused
    configure(?config(muse_data_dir, Config), true, #{<<"COMPUTER_NETWORK">> => <<"none">>}),
    try
        ?assertMatch({error, {409, <<"The existing computer container was created with a different "
                                     "COMPUTER_NETWORK setting", _/binary>>}},
                     muse_computer:execute(?LEGACY(?O), #{command => <<"true">>})),
        ?assertMatch(#{<<"status">> := <<"error">>, <<"network">> := <<"disabled">>},
                     muse_computer:snapshot(?LEGACY(?O)))
    after
        configure(?config(muse_data_dir, Config), true)
    end,
    ?assertMatch(#{<<"status">> := <<"succeeded">>}, run(<<"true">>)).

%% A conversation's own desktop computer: started by the first action,
%% its own screenshot, deleted with its volume.
pool_desktop(_Config) ->
    P = muse_computer:ensure(?O, <<"thread:ct-desk">>),
    {ok, #{image := Image, receipt := #{<<"id">> := Id} = R}} = first_shot(P, 30),
    ?assert(jpeg(Image)),
    ?assertEqual(muse_computer:computer_id(P), maps:get(<<"computerId">>, R)),
    ?assertMatch(#{<<"status">> := <<"running">>}, muse_computer:snapshot(P)),
    ?assertNotEqual(nomatch, binary:match(muse_computer_desktop:screenshot_url(P, Id), <<"&computer=">>)),
    ?assertMatch({ok, #{bytes := Image}}, muse_computer_desktop:latest_screenshot(P, Id)),
    %% the default computer's latest screenshot is a different one
    ?assertNotMatch({ok, #{bytes := Image}}, muse_computer_desktop:latest_screenshot(?LEGACY(?O), Id)),
    #{container := C, volume := V} = muse_computer:identity(P),
    ?assertEqual(ok, muse_computer:delete(P)),
    ?assertMatch(#{exit_code := 1}, muse_docker:run(muse_docker:inspect_args(C), #{timeout => 10000})),
    ?assertMatch(#{exit_code := 1}, muse_docker:run(muse_docker:volume_inspect_args(V), #{timeout => 10000})),
    ?assertMatch({error, {404, _}}, muse_computer_desktop:latest_screenshot(P)).

%% A conversation's browser session runs in the conversation's desktop
%% computer (designs/04-integrations.md §4.2): without one it is in the
%% owner's browser container (muse-browser:local must be built); once the
%% conversation has a computer the next request moves it there, re-opened at
%% its last URL, with the page area the 1280x800 desktop leaves; when the
%% computer is gone it moves back.
browser_in_desktop(Config) ->
    configure(?config(muse_data_dir, Config), true, #{<<"BROWSER_ENABLED">> => <<"true">>}),
    Thread = <<"ct-browse-", (muse_ids:uuid())/binary>>,
    {ok, #{<<"sessionId">> := Sid, <<"url">> := <<"https://example.com/">>}} =
        muse_browser:observe_for_thread(?O, Thread, <<"https://example.com/">>),
    ?assertEqual(own, muse_browser_docker:host(?O, Sid)),
    ?assertEqual(<<"thread:", Thread/binary>>, muse_browser:scope_of(?O, Sid)),
    %% the conversation gets a desktop computer: the session moves there
    P = muse_computer:ensure(?O, <<"thread:", Thread/binary>>),
    {ok, #{<<"url">> := <<"https://example.com/">>, <<"text">> := Text}} = muse_browser:read_for_thread(?O, Thread),
    ?assertNotEqual(nomatch, binary:match(Text, <<"documentation">>)),
    #{container := C} = muse_computer:identity(P),
    Cid = muse_computer:computer_id(P),
    ?assertEqual({computer, Cid, C}, muse_browser_docker:host(?O, Sid)),
    ?assertMatch(#{<<"host">> := <<"computer:", Cid/binary>>}, muse_store:get(?O, <<"browser-placement">>, Sid)),
    #{stdout := Ps} = muse_docker:run([<<"exec">>, C, <<"ps">>, <<"-eo">>, <<"args">>], #{timeout => 10000}),
    ?assertNotEqual(nomatch, binary:match(Ps, <<"/usr/lib/chromium/chromium">>)),
    ?assertNotEqual(nomatch, binary:match(Ps, <<"browserd.py">>)),
    %% the page area is what the desktop leaves; screenshots and input use it
    {ok, Png} = muse_browser:preview(?O, Sid),
    <<137, "PNG", _:8/binary, "IHDR", W:32, H:32, _/binary>> = Png,
    ct:pal("page area in the desktop: ~bx~b", [W, H]),
    ?assert(W =< 1280 andalso W > 1200 andalso H < 800 andalso H > 600),
    ?assertMatch({ok, _}, muse_browser:input(?O, Sid, #{<<"type">> => <<"click">>, <<"x">> => W - 10, <<"y">> => H - 10})),
    ?assertMatch({error, {502, _}}, muse_browser:input(?O, Sid, #{<<"type">> => <<"click">>, <<"x">> => 5, <<"y">> => H + 5})),
    %% the console's live view shows the computer's screen
    {ok, Vnc} = muse_browser:vnc(?O, Sid),
    ?assert(lists:member(C, Vnc)),
    %% the window left in the owner's browser container was closed
    {ok, #{} = Listed} = muse_browser_docker:call(?O, #{<<"op">> => <<"sessions">>}, 20000),
    ct:pal("browser container sessions: ~p", [Listed]),
    ?assertEqual(nomatch, binary:match(muse_json:encode(Listed), Sid)),
    %% the computer is deleted: back to the owner's browser container
    ?assertEqual(ok, muse_computer:delete(P)),
    {ok, #{<<"url">> := <<"https://example.com/">>}} = muse_browser:read_for_thread(?O, Thread),
    ?assertEqual(own, muse_browser_docker:host(?O, Sid)),
    configure(?config(muse_data_dir, Config), true).

%% The first action starts the computer; the X server needs a moment.
first_shot(P, N) ->
    Key = <<"ct-desk-", (integer_to_binary(N))/binary>>,
    case muse_computer_desktop:desktop_action(P, #{<<"action">> => <<"screenshot">>},
                                              #{idempotency_key => Key, auto_start => true}) of
        {ok, _} = Ok -> Ok;
        Error when N =:= 0 -> Error;
        _ -> timer:sleep(500), first_shot(P, N - 1)
    end.

stop_and_restart(_Config) ->
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?LEGACY(?O))),
    ?assertEqual({error, {409, <<"Start the computer before using its terminal or files">>}},
                 act(#{<<"action">> => <<"screenshot">>})),
    %% a restart gets a fresh /tmp, so the X server starts again
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?LEGACY(?O))),
    until(<<"xdotool getdisplaygeometry">>, <<"1280 800\n">>, 20),
    {ok, #{image := Image}} = act(#{<<"action">> => <<"screenshot">>}),
    ?assert(jpeg(Image)),
    ?assertMatch(#{<<"stdout">> := <<"typed $(id) ok\n">>}, run(<<"cat /workspace/typed.txt">>)),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>}}, muse_computer:stop(?LEGACY(?O))).
