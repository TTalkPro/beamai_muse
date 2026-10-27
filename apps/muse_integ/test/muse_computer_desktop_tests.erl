-module(muse_computer_desktop_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%% The desktop variant of the Docker computer (muse_computer_desktop and
%% the desktop parts of muse_computer_docker). The pure parts port OpenMuse
%% tests/computer-e2b-desktop.test.ts to argv; the service parts replace
%% `muse_docker:run/2` with a fixture runner, as muse_computer_tests does.

-define(O, <<"owner-desk">>).
-define(T, muse_desktop_fixture).
-define(JPEG, <<255, 216, 255, 224, "fake jpeg bytes">>).
-define(ACTIONS, <<"computer-desktop-actions">>).
-define(REFUSE, <<"Computer ownership or isolation does not match this deployment; "
                  "refusing to attach">>).
-define(UNCERTAIN, <<"The desktop input outcome is unknown: it may already have been performed. "
                     "Inspect a fresh screenshot before repeating the action; do not "
                     "automatically retry it.">>).
%% An older version's default computer, which keeps OpenMuse's names.
-define(LEGACY(O), {O, muse_computers:legacy_id(O)}).

%% Pure: schema, describe, argv, scripts

parse(Raw) -> muse_validate:parse(muse_computer_desktop:action_schema(), Raw).

input(Raw) ->
    {ok, A} = parse(Raw),
    muse_computer_desktop:input_argv(A).

describe(Raw) ->
    {ok, A} = parse(Raw),
    muse_computer_desktop:describe_action(A).

b(L) -> [list_to_binary(S) || S <- L].

input_argv_test() ->
    ?assertEqual(undefined, input(#{<<"action">> => <<"screenshot">>})),
    ?assertEqual(b(["xdotool", "mousemove", "--sync", "640", "400", "click", "1"]),
                 input(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [640, 400]})),
    ?assertEqual(b(["xdotool", "click", "1"]), input(#{<<"action">> => <<"left_click">>})),
    ?assertEqual(b(["xdotool", "mousemove", "--sync", "0", "0", "click", "--repeat", "2",
                    "--delay", "120", "1"]),
                 input(#{<<"action">> => <<"double_click">>, <<"coordinate">> => [0, 0]})),
    ?assertEqual(b(["xdotool", "mousemove", "--sync", "5", "6", "click", "3"]),
                 input(#{<<"action">> => <<"right_click">>, <<"coordinate">> => [5, 6]})),
    ?assertEqual(b(["xdotool", "mousemove", "--sync", "7", "8"]),
                 input(#{<<"action">> => <<"mouse_move">>, <<"coordinate">> => [7, 8]})),
    ?assertEqual(b(["xdotool", "key", "--", "ctrl+l", "Return"]),
                 input(#{<<"action">> => <<"key">>, <<"text">> => <<"  ctrl+l   Return ">>})),
    ?assertEqual(b(["xdotool", "mousemove", "--sync", "10", "20", "click", "--repeat", "5", "4"]),
                 input(#{<<"action">> => <<"scroll">>, <<"coordinate">> => [10, 20],
                         <<"scroll_direction">> => <<"up">>, <<"scroll_amount">> => 5})),
    ?assertEqual(b(["xdotool", "click", "--repeat", "3", "5"]),
                 input(#{<<"action">> => <<"scroll">>, <<"scroll_direction">> => <<"down">>})),
    ?assertEqual(b(["xdotool", "click", "--repeat", "1", "6"]),
                 input(#{<<"action">> => <<"scroll">>, <<"scroll_direction">> => <<"left">>,
                         <<"scroll_amount">> => 1})),
    ?assertEqual(b(["xdotool", "click", "--repeat", "3", "7"]),
                 input(#{<<"action">> => <<"scroll">>, <<"scroll_direction">> => <<"right">>})),
    ?assertEqual(b(["sleep", "2"]), input(#{<<"action">> => <<"wait">>, <<"duration">> => 2})),
    ?assertEqual(b(["sleep", "0.5"]), input(#{<<"action">> => <<"wait">>, <<"duration">> => 0.5})),
    ?assertEqual(b(["sleep", "1"]), input(#{<<"action">> => <<"wait">>})).

%% Typed text is one argv element, never quoted into a shell string.
type_text_is_argv_test() ->
    Text = <<"it's $(touch /tmp/pwned); `id` \"q\" \n中文 -- --help"/utf8>>,
    ?assertEqual([<<"xdotool">>, <<"type">>, <<"--delay">>, <<"12">>, <<"--">>, Text],
                 input(#{<<"action">> => <<"type">>, <<"text">> => Text})),
    Script = muse_computer_desktop:input_script(),
    ?assertEqual(nomatch, binary:match(Script, <<"touch">>)),
    Argv = muse_docker:desktop_args(<<"c">>, Script, input(#{<<"action">> => <<"type">>,
                                                            <<"text">> => Text})),
    ?assertEqual(Text, lists:last(Argv)),
    ?assertEqual([<<"-c">>, Script, <<"openmuse-desktop">>, <<"xdotool">>],
                 lists:sublist(Argv, 14, 4)).

scripts_test() ->
    ?assertEqual(<<"case \"$1\" in xdotool|sleep) ;; *) exit 2 ;; esac\n"
                   "[ \"$1\" = xdotool ] && xdotool keyup Shift_L Shift_R Control_L Control_R "
                   "Alt_L Alt_R Super_L Super_R Meta_L Meta_R ISO_Level3_Shift\n"
                   "\"$@\" || exit 3">>,
                 muse_computer_desktop:input_script()),
    ?assertEqual(<<"sleep 0.5 || exit 3\nsleep 0.5\n"
                   "scrot --pointer --quality 80 --overwrite /tmp/s.jpg || exit 4\n"
                   "base64 -w0 /tmp/s.jpg || exit 4">>,
                 muse_computer_desktop:shot_script(true, <<"/tmp/s.jpg">>)),
    ?assertEqual(<<"scrot --pointer --quality 80 --overwrite /tmp/s.jpg || exit 4\n"
                   "base64 -w0 /tmp/s.jpg || exit 4">>,
                 muse_computer_desktop:shot_script(false, <<"/tmp/s.jpg">>)).

action_validation_test() ->
    E = fun(Raw) -> {error, {422, Msg}} = parse(Raw), Msg end,
    ?assertEqual(<<"mouse_move needs coordinate">>, E(#{<<"action">> => <<"mouse_move">>})),
    ?assertEqual(<<"type needs text">>, E(#{<<"action">> => <<"type">>})),
    ?assertEqual(<<"key needs text">>, E(#{<<"action">> => <<"key">>})),
    ?assertEqual(<<"Use xdotool key names, e.g. ctrl+l">>,
                 E(#{<<"action">> => <<"key">>, <<"text">> => <<"ctrl+l; rm -rf /">>})),
    ?assertEqual(<<"scroll needs scroll_direction">>, E(#{<<"action">> => <<"scroll">>})),
    %% not in OpenMuse: xdotool command names would chain (`key -- shift exec rm x`)
    [?assertEqual(<<"Use xdotool key names, e.g. ctrl+l">>,
                  E(#{<<"action">> => <<"key">>, <<"text">> => T}), T)
     || T <- [<<"shift exec rm -rf x">>, <<"Return EXEC sh">>, <<"Exec">>, <<"ctrl+l windowkill">>,
              <<"a Windowclose">>, <<"getactivewindow">>, <<"set_window">>, <<"mousemove 1 1">>,
              <<"a keydown b">>, <<"a type x">>, <<"a sleep 9">>, <<"search">>, <<"behave_screen_edge">>,
              <<"click 1">>, <<"selectwindow">>]],
    [?assertMatch({ok, _}, parse(#{<<"action">> => <<"key">>, <<"text">> => T}), T)
     || T <- [<<"Return">>, <<"ctrl+l">>, <<"alt+F4">>, <<"super">>, <<"Escape Tab BackSpace">>,
              <<"KP_Enter">>, <<"shift+Insert">>, <<"Execute">>, <<"Select">>, <<"space minus plus">>,
              <<"ctrl+shift+t">>, <<"F11">>, <<"Page_Down">>]],
    ?assertEqual(<<"The screen is 1280x800">>,
                 E(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [1280, 10]})),
    ?assertEqual(<<"The screen is 1280x800">>,
                 E(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [10, 800]})),
    ?assertEqual(<<"Too small: expected array to have >=2 items">>,
                 E(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [10]})),
    ?assertEqual(<<"Too small: expected number to be >=0">>,
                 E(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [-1, 0]})),
    ?assertEqual(<<"Invalid input: expected int, received number">>,
                 E(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [1.5, 0]})),
    ?assertEqual(<<"Invalid option: expected one of \"screenshot\"|\"left_click\"|\"double_click\"|"
                   "\"right_click\"|\"mouse_move\"|\"type\"|\"key\"|\"scroll\"|\"wait\"">>,
                 E(#{<<"action">> => <<"drag">>})),
    ?assertEqual(<<"Too big: expected number to be <=15">>,
                 E(#{<<"action">> => <<"scroll">>, <<"scroll_direction">> => <<"up">>,
                     <<"scroll_amount">> => 16})),
    ?assertEqual(<<"Too small: expected number to be >=0.1">>,
                 E(#{<<"action">> => <<"wait">>, <<"duration">> => 0.05})),
    ?assertEqual(<<"Too big: expected number to be <=10">>,
                 E(#{<<"action">> => <<"wait">>, <<"duration">> => 11})),
    ?assertEqual(<<"Too big: expected string to have <=1000 characters">>,
                 E(#{<<"action">> => <<"type">>, <<"text">> => binary:copy(<<"a">>, 1001)})),
    %% every superRefine issue, in order
    ?assertEqual(<<"scroll needs scroll_direction; The screen is 1280x800">>,
                 E(#{<<"action">> => <<"scroll">>, <<"coordinate">> => [1300, 0]})),
    ?assertEqual(<<"mouse_move needs coordinate">>,
                 E(#{<<"action">> => <<"mouse_move">>, <<"text">> => <<"x">>})),
    ?assertMatch({ok, #{<<"action">> := <<"key">>, <<"text">> := <<"ctrl+l Return">>}},
                 parse(#{<<"action">> => <<"key">>, <<"text">> => <<"ctrl+l Return">>,
                         <<"extra">> => 1})),
    ?assertMatch({ok, _}, parse(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [1279, 799]})).

describe_test() ->
    ?assertEqual(<<"desktop left_click (640, 400)">>,
                 describe(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [640, 400]})),
    ?assertEqual(<<"desktop screenshot">>, describe(#{<<"action">> => <<"screenshot">>})),
    ?assertEqual(<<"desktop type \"it's \\\"quoted\\\"\"">>,
                 describe(#{<<"action">> => <<"type">>, <<"text">> => <<"it's \"quoted\"">>})),
    Long = binary:copy(<<"x">>, 205),
    ?assertEqual(<<"desktop type \"", (binary:copy(<<"x">>, 200))/binary, "\"">>,
                 describe(#{<<"action">> => <<"type">>, <<"text">> => Long})),
    ?assertEqual(<<"desktop scroll (1, 2) down 3">>,
                 describe(#{<<"action">> => <<"scroll">>, <<"coordinate">> => [1, 2],
                            <<"scroll_direction">> => <<"down">>})),
    ?assertEqual(<<"desktop key \"ctrl+l\"">>,
                 describe(#{<<"action">> => <<"key">>, <<"text">> => <<"ctrl+l">>})),
    ?assertEqual(<<"desktop wait 1s">>, describe(#{<<"action">> => <<"wait">>})),
    ?assertEqual(<<"desktop wait 2.5s">>,
                 describe(#{<<"action">> => <<"wait">>, <<"duration">> => 2.5})).

%% Service (fixture runner)

service_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [{"disabled variant is a 404 and never invokes Docker", fun disabled/0},
      {"screenshot runs scrot without input and stores the latest image", fun screenshot/0},
      {"input runs as argv, after releasing modifiers, then a settled screenshot", fun input/0},
      {"intent is persisted as interrupted before input", fun intent/0},
      {"an idempotent replay never sends input again", fun replay/0},
      {"replay with a different action is refused", fun replay_mismatch/0},
      {"exit 3 leaves an uncertain receipt and still takes a screenshot", fun input_failed/0},
      {"exit 4 after input keeps the receipt without an image", fun shot_failed_after_input/0},
      {"a failed plain screenshot is a 502 with a failed receipt", fun shot_failed/0},
      {"screenshots are stored atomically, owner-private", fun storage/0},
      {"a stopped computer refuses actions", fun stopped/0},
      {"actions hold the computer lease", fun lease/0},
      {"live frames take no lease and leave no receipt", fun frame/0},
      {"status reports the screen and the latest screenshot", fun status/0},
      {"start creates the desktop container", fun start_desktop/0},
      {"attach refuses a container of the other variant", fun variant_mismatch/0},
      {"attach checks the desktop isolation settings", fun desktop_isolation/0},
      {"light variant is unchanged with the desktop off", fun light_unchanged/0}]}.

setup() ->
    ok = muse_store:init(#{storage => ram}),
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"),
                        "muse-desktop-" ++ integer_to_list(erlang:unique_integer([positive]))),
    config(true, #{<<"DATA_DIR">> => list_to_binary(Dir)}),
    ok = muse_signing:init(Dir),
    Holder = spawn(fun() -> receive stop -> ok end end),
    ets:new(?T, [named_table, public, {heir, none}]) =:= ?T orelse error(ets),
    ets:give_away(?T, Holder, none),
    ets:insert(?T, [{hook, fun(_, _) -> default end}, {inspect, sandbox(desktop, true)},
                    {missing, false}, {dir, Dir}]),
    meck:new(muse_docker, [passthrough]),
    meck:expect(muse_docker, run, fun runner/2),
    Holder.

cleanup(Holder) ->
    meck:unload(),
    [{dir, Dir}] = ets:lookup(?T, dir),
    _ = file:del_dir_r(Dir),
    Holder ! stop,
    muse_store:stop().

config(Desktop) ->
    [{dir, Dir}] = ets:lookup(?T, dir),
    config(Desktop, #{<<"DATA_DIR">> => list_to_binary(Dir)}).

config(Desktop, Extra) ->
    %% the fixture containers are OpenMuse's `--network none`
    Env = maps:merge(#{<<"COMPUTER_ENABLED">> => <<"true">>, <<"COMPUTER_NETWORK">> => <<"none">>,
                       <<"COMPUTER_DESKTOP">> => atom_to_binary(Desktop)}, Extra),
    {ok, C} = muse_config:from_env(Env),
    muse_config:set(C).

ok(Stdout) ->
    #{stdout => Stdout, stderr => <<>>, exit_code => 0, timed_out => false,
      interrupted => false, truncated => false}.

exit_code(Code) ->
    (ok(<<>>))#{exit_code := Code}.

hook(Fun) -> ets:insert(?T, {hook, Fun}).

calls() ->
    [A || {_, A, _} <- lists:sort([{N, A, O} || {{call, N}, A, O} <- ets:tab2list(?T)])].

desktop_calls() ->
    [A || A = [<<"exec">>, <<"--user">>, <<"1000:1000">>, <<"--env">>, <<"DISPLAY=:0">> | _] <- calls()].

input_calls() ->
    Script = muse_computer_desktop:input_script(),
    [A || A <- desktop_calls(), lists:member(Script, A)].

shot_calls() ->
    desktop_calls() -- input_calls().

runner(Args, Opts) ->
    ets:insert(?T, {{call, erlang:unique_integer([monotonic, positive])}, Args, Opts}),
    [{hook, Hook}] = ets:lookup(?T, hook),
    case Hook(Args, Opts) of
        default -> default_reply(Args);
        Result -> Result
    end.

default_reply([<<"container">>, <<"ls">> | _]) ->
    case ets:lookup(?T, missing) of
        [{missing, true}] -> ok(<<>>);
        _ -> ok(<<"container-id\n">>)
    end;
default_reply([<<"container">>, <<"inspect">> | _]) ->
    [{inspect, I}] = ets:lookup(?T, inspect),
    ok(muse_json:encode([I]));
default_reply([<<"volume">>, <<"ls">> | _]) ->
    ok(maps:get(volume, muse_computer:identity(?LEGACY(?O))));
default_reply([<<"volume">>, <<"inspect">> | _]) ->
    #{volume := V, labels := L} = muse_computer:identity(?LEGACY(?O)),
    ok(muse_json:encode([#{<<"Name">> => V, <<"Labels">> => maps:from_list(L),
                           <<"Driver">> => <<"local">>, <<"Options">> => null,
                           <<"Scope">> => <<"local">>}]));
default_reply([<<"exec">> | _] = Args) ->
    case lists:member(muse_computer_desktop:input_script(), Args) of
        true -> ok(<<>>);
        false -> ok(base64:encode(?JPEG))
    end;
default_reply(_) ->
    ok(<<>>).

sandbox(Variant, Running) ->
    #{container := C, volume := V, labels := L} = muse_computer:identity(?LEGACY(?O)),
    Light = #{<<"Id">> => <<"container-id">>,
              <<"Name">> => <<"/", C/binary>>,
              <<"Config">> => #{<<"Image">> => <<"openmuse-computer:local">>,
                                <<"User">> => <<"1000:1000">>,
                                <<"Labels">> => maps:from_list(L),
                                <<"Env">> => [<<"PATH=/usr/local/bin:/usr/bin:/bin">>,
                                              <<"HOME=/workspace">>, <<"LANG=C.UTF-8">>],
                                <<"Entrypoint">> => [<<"/usr/bin/sleep">>],
                                <<"Cmd">> => [<<"infinity">>],
                                <<"WorkingDir">> => <<"/workspace">>},
              <<"HostConfig">> => #{<<"ReadonlyRootfs">> => true, <<"Privileged">> => false,
                                    <<"CapDrop">> => [<<"ALL">>], <<"CapAdd">> => null,
                                    <<"SecurityOpt">> => [<<"no-new-privileges">>],
                                    <<"NetworkMode">> => <<"none">>,
                                    <<"Memory">> => 536870912, <<"MemorySwap">> => 536870912,
                                    <<"PidsLimit">> => 128, <<"NanoCpus">> => 1000000000,
                                    <<"Binds">> => null, <<"Devices">> => [],
                                    <<"DeviceRequests">> => null, <<"PortBindings">> => #{},
                                    <<"PidMode">> => <<>>, <<"IpcMode">> => <<"private">>,
                                    <<"Tmpfs">> => #{<<"/tmp">> =>
                                                         <<"rw,nosuid,nodev,noexec,size=67108864,mode=1777">>},
                                    <<"RestartPolicy">> => #{<<"Name">> => <<"no">>}},
              <<"Mounts">> => [#{<<"Type">> => <<"volume">>, <<"Name">> => V,
                                 <<"Destination">> => <<"/workspace">>, <<"RW">> => true}],
              <<"NetworkSettings">> => #{<<"Networks">> => #{<<"none">> => #{}}},
              <<"State">> => #{<<"Running">> => Running}},
    case Variant of
        light ->
            Light;
        desktop ->
            #{<<"Config">> := Cfg, <<"HostConfig">> := H} = Light,
            Light#{<<"Config">> := Cfg#{<<"Image">> := <<"openmuse-computer-desktop:local">>,
                                        <<"Labels">> := maps:from_list(
                                                          [{<<"dev.openmuse.variant">>, <<"desktop">>} | L]),
                                        <<"Env">> := [<<"PATH=/usr/local/bin:/usr/bin:/bin">>,
                                                      <<"HOME=/workspace">>, <<"LANG=C.UTF-8">>,
                                                      <<"DISPLAY=:0">>],
                                        <<"Entrypoint">> := [<<"/opt/openmuse/desktop-init">>],
                                        <<"Cmd">> := null},
                   <<"HostConfig">> := H#{<<"Memory">> := 1610612736, <<"MemorySwap">> := 1610612736,
                                          <<"PidsLimit">> := 512, <<"NanoCpus">> := 2000000000,
                                          <<"Tmpfs">> := #{<<"/tmp">> =>
                                                               <<"rw,nosuid,nodev,noexec,size=268435456,mode=1777">>}}}
    end.

put_in(Map, [K], V) -> Map#{K => V};
put_in(Map, [K | Rest], V) -> Map#{K => put_in(maps:get(K, Map), Rest, V)}.

act(Raw) -> muse_computer_desktop:desktop_action(?LEGACY(?O), Raw).
act(Raw, Key) -> muse_computer_desktop:desktop_action(?LEGACY(?O), Raw, #{idempotency_key => Key}).

receipts() -> muse_store:list(?O, ?ACTIONS).

%% Cases

disabled() ->
    config(false),
    NotEnabled = {error, {404, <<"This computer has no desktop. Set COMPUTER_DESKTOP=true and "
                                 "build the desktop computer image.">>}},
    ?assertEqual(NotEnabled, act(#{<<"action">> => <<"screenshot">>})),
    ?assertEqual(NotEnabled, muse_computer_desktop:latest_screenshot(?LEGACY(?O))),
    ?assertEqual(NotEnabled, muse_computer_desktop:frame(?LEGACY(?O))),
    ?assertEqual(NotEnabled, muse_computer_desktop:status(?LEGACY(?O))),
    ?assertNot(muse_computer_desktop:enabled()),
    ?assertEqual([], calls()),
    %% the computer itself is off: the 503 of the service, still no Docker
    config(true, #{<<"COMPUTER_ENABLED">> => <<"false">>}),
    ?assertMatch({error, {503, <<"Computer is not configured.", _/binary>>}},
                 act(#{<<"action">> => <<"screenshot">>})),
    ?assertEqual([], calls()).

screenshot() ->
    {ok, Shot} = act(#{<<"action">> => <<"screenshot">>}),
    #{receipt := R = #{<<"id">> := Id}, image := Image, data := Data, width := 1280,
      height := 800, uncertain := false, warning := undefined, mime_type := <<"image/jpeg">>} = Shot,
    ?assertEqual(?JPEG, Image),
    ?assertEqual(base64:encode(?JPEG), Data),
    ?assertMatch(#{<<"command">> := <<"desktop screenshot">>, <<"status">> := <<"succeeded">>,
                   <<"exitCode">> := 0, <<"stdout">> := <<"Screenshot 1280x800">>,
                   <<"stderr">> := <<>>, <<"cwd">> := <<"/workspace">>}, R),
    ?assertNot(maps:is_key(<<"actionHash">>, R)),
    ?assertEqual([], input_calls()),
    [Shot1] = shot_calls(),
    #{container := C} = muse_computer:identity(?LEGACY(?O)),
    ?assertEqual([<<"exec">>, <<"--user">>, <<"1000:1000">>, <<"--env">>, <<"DISPLAY=:0">>, C,
                  <<"/usr/bin/timeout">>, <<"--signal=TERM">>, <<"--kill-after=2s">>, <<"30s">>,
                  <<"/bin/bash">>, <<"--noprofile">>, <<"--norc">>, <<"-c">>,
                  muse_computer_desktop:shot_script(false, <<"/tmp/openmuse-screenshot.jpg">>),
                  <<"openmuse-desktop">>], Shot1),
    ?assertEqual({ok, #{mime_type => <<"image/jpeg">>, bytes => ?JPEG}},
                 muse_computer_desktop:latest_screenshot(?LEGACY(?O))),
    ?assertEqual({ok, #{mime_type => <<"image/jpeg">>, bytes => ?JPEG}},
                 muse_computer_desktop:latest_screenshot(?LEGACY(?O), Id)),
    ?assertEqual({error, {404, <<"No desktop screenshot yet">>}},
                 muse_computer_desktop:latest_screenshot(?LEGACY(?O), <<"other">>)),
    ?assertEqual([R], receipts()).

input() ->
    Text = <<"héllo 'x' $(id)"/utf8>>,
    {ok, #{receipt := R, uncertain := false, warning := undefined}} =
        act(#{<<"action">> => <<"type">>, <<"text">> => Text}),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"exitCode">> := 0,
                   <<"command">> := <<"desktop type \"héllo 'x' $(id)\""/utf8>>}, R),
    [In] = input_calls(),
    ?assertEqual([<<"-c">>, muse_computer_desktop:input_script(), <<"openmuse-desktop">>,
                  <<"xdotool">>, <<"type">>, <<"--delay">>, <<"12">>, <<"--">>, Text],
                 lists:nthtail(13, In)),
    [Shot] = shot_calls(),
    ?assert(lists:member(muse_computer_desktop:shot_script(true, <<"/tmp/openmuse-screenshot.jpg">>),
                         Shot)),
    %% input before the screenshot
    ?assertEqual([In, Shot], desktop_calls()),
    {ok, _} = act(#{<<"action">> => <<"left_click">>, <<"coordinate">> => [640, 400]}),
    ?assertEqual([<<"xdotool">>, <<"mousemove">>, <<"--sync">>, <<"640">>, <<"400">>,
                  <<"click">>, <<"1">>], lists:nthtail(16, lists:last(input_calls()))).

intent() ->
    Self = self(),
    hook(fun([<<"exec">> | _] = Args, _) ->
                 case lists:member(muse_computer_desktop:input_script(), Args) of
                     true -> Self ! {at_input, receipts()}, default;
                     false -> default
                 end;
            (_, _) -> default
         end),
    {ok, #{receipt := #{<<"id">> := Id}}} = act(#{<<"action">> => <<"key">>, <<"text">> => <<"Return">>}),
    receive
        {at_input, [Intent]} ->
            ?assertMatch(#{<<"id">> := Id, <<"status">> := <<"interrupted">>,
                           <<"stderr">> := <<"Desktop input is being dispatched", _/binary>>}, Intent)
    after 1000 -> error(no_input)
    end.

replay() ->
    Click = #{<<"action">> => <<"left_click">>, <<"coordinate">> => [1, 2]},
    {ok, #{receipt := R1}} = act(Click, <<"chat:t:op-1">>),
    ?assertMatch(#{<<"actionHash">> := _}, R1),
    ?assertEqual(muse_ids:sha256hex(<<"computer-desktop-action:chat:t:op-1">>), maps:get(<<"id">>, R1)),
    {ok, #{receipt := R2, image := Image, warning := W}} = act(Click, <<"chat:t:op-1">>),
    ?assertEqual(R1, R2),
    ?assertEqual(?JPEG, Image),
    ?assertEqual(<<"This operation ID already has a receipt; no new desktop input was sent. "
                   "The saved screenshot is attached.">>, W),
    ?assertEqual(1, length(input_calls())),
    ?assertEqual(1, length(shot_calls())),
    %% once a newer screenshot replaced it, the replay has no image and still sends nothing
    {ok, _} = act(#{<<"action">> => <<"screenshot">>}),
    {ok, #{image := <<>>, data := <<>>, warning := W2}} = act(Click, <<"chat:t:op-1">>),
    ?assertEqual(<<"This operation ID already has a receipt; no new desktop input was sent. "
                   "Take a fresh screenshot before deciding what to do next.">>, W2),
    ?assertEqual(1, length(input_calls())).

replay_mismatch() ->
    {ok, _} = act(#{<<"action">> => <<"type">>, <<"text">> => <<"a">>}, <<"k">>),
    ?assertEqual({error, {409, <<"This operation ID already belongs to a different desktop action">>}},
                 act(#{<<"action">> => <<"type">>, <<"text">> => <<"b">>}, <<"k">>)),
    ?assertEqual(1, length(input_calls())).

input_failed() ->
    Script = muse_computer_desktop:input_script(),
    hook(fun([<<"exec">> | _] = Args, _) ->
                 case lists:member(Script, Args) of
                     true -> exit_code(3);
                     false -> default
                 end;
            (_, _) -> default
         end),
    {ok, #{receipt := R, uncertain := true, warning := ?UNCERTAIN, image := ?JPEG}} =
        act(#{<<"action">> => <<"key">>, <<"text">> => <<"ctrl+s">>}),
    ?assertMatch(#{<<"status">> := <<"interrupted">>, <<"stdout">> := ?UNCERTAIN,
                   <<"stderr">> := ?UNCERTAIN}, R),
    ?assertNot(maps:is_key(<<"exitCode">>, R)),
    ?assertEqual(1, length(shot_calls())),
    %% a timed-out input is uncertain as well
    hook(fun([<<"exec">> | _] = Args, _) ->
                 case lists:member(Script, Args) of
                     true -> (exit_code(null))#{timed_out := true};
                     false -> default
                 end;
            (_, _) -> default
         end),
    {ok, #{uncertain := true}} = act(#{<<"action">> => <<"wait">>}).

shot_failed_after_input() ->
    hook(fun([<<"exec">> | _] = Args, _) ->
                 case lists:member(muse_computer_desktop:input_script(), Args) of
                     true -> default;
                     false -> exit_code(4)
                 end;
            (_, _) -> default
         end),
    {ok, #{receipt := R, uncertain := false, image := <<>>, data := <<>>, warning := W}} =
        act(#{<<"action">> => <<"left_click">>}),
    ?assertEqual(<<"Action performed; the screenshot could not be taken. Take a screenshot "
                   "before retrying the action.">>, W),
    ?assertMatch(#{<<"status">> := <<"succeeded">>, <<"exitCode">> := 0, <<"stdout">> := W}, R),
    ?assertEqual({error, {404, <<"No desktop screenshot yet">>}},
                 muse_computer_desktop:latest_screenshot(?LEGACY(?O))),
    %% output that is not a JPEG is a failed screenshot too
    hook(fun([<<"exec">> | _], _) -> ok(base64:encode(<<"not a jpeg">>)); (_, _) -> default end),
    {ok, #{image := <<>>, warning := W}} = act(#{<<"action">> => <<"right_click">>}).

shot_failed() ->
    hook(fun([<<"exec">> | _], _) -> exit_code(4); (_, _) -> default end),
    ?assertEqual({error, {502, <<"The desktop screenshot failed">>}},
                 act(#{<<"action">> => <<"screenshot">>})),
    ?assertMatch([#{<<"status">> := <<"failed">>, <<"stderr">> := <<"The desktop screenshot failed">>}],
                 receipts()),
    %% the lease was released
    ?assertMatch({ok, _}, muse_computer:execute(?LEGACY(?O), #{command => <<"true">>})).

storage() ->
    {ok, #{receipt := #{<<"id">> := Id}}} = act(#{<<"action">> => <<"screenshot">>}),
    [{dir, Dir}] = ets:lookup(?T, dir),
    Screens = filename:join(Dir, "desktop-screens"),
    Blob = <<(muse_ids:sha256hex(?O))/binary, ".jpg">>,
    ?assertEqual({ok, ?JPEG}, file:read_file(filename:join(Screens, Blob))),
    ?assertEqual([binary_to_list(Blob)], element(2, file:list_dir(Screens))),
    {ok, #file_info{mode = DirMode}} = file:read_file_info(Screens),
    {ok, #file_info{mode = FileMode}} = file:read_file_info(filename:join(Screens, Blob)),
    ?assertEqual(8#700, DirMode band 8#777),
    ?assertEqual(8#600, FileMode band 8#777),
    ?assertMatch(#{<<"receiptId">> := Id, <<"blob">> := Blob, <<"mimeType">> := <<"image/jpeg">>,
                   <<"takenAt">> := _},
                 muse_store:get(?O, <<"computer-desktop-screens">>, <<"latest">>)),
    %% a missing file is a 404, never another owner's image
    ok = file:delete(filename:join(Screens, Blob)),
    ?assertEqual({error, {404, <<"No desktop screenshot yet">>}},
                 muse_computer_desktop:latest_screenshot(?LEGACY(?O))).

stopped() ->
    ets:insert(?T, {inspect, sandbox(desktop, false)}),
    ?assertEqual({error, {409, <<"Start the computer before using its terminal or files">>}},
                 act(#{<<"action">> => <<"left_click">>})),
    ?assertEqual({error, {409, <<"Start the computer before using its terminal or files">>}},
                 muse_computer_desktop:frame(?LEGACY(?O))),
    ?assertEqual([], desktop_calls()),
    ?assertEqual([], receipts()).

lease() ->
    Self = self(),
    hook(fun([<<"exec">> | _] = Args, _) ->
                 case lists:member(muse_computer_desktop:input_script(), Args) of
                     true -> Self ! {in_input, self()}, receive go -> default end;
                     false -> default
                 end;
            (_, _) -> default
         end),
    Pid = spawn(fun() -> Self ! {done, act(#{<<"action">> => <<"wait">>})} end),
    Worker = receive {in_input, W} -> W after 5000 -> error(timeout) end,
    ?assertEqual({error, {409, <<"Computer is busy. Wait for the current operation to finish.">>}},
                 muse_computer:execute(?LEGACY(?O), #{command => <<"true">>})),
    ?assertEqual({error, {409, <<"Computer is busy. Wait for the current operation to finish.">>}},
                 act(#{<<"action">> => <<"screenshot">>})),
    Worker ! go,
    receive {done, R} -> ?assertMatch({ok, _}, R) after 5000 -> error(timeout) end,
    ?assertNot(is_process_alive(Pid)).

frame() ->
    {ok, #{mime_type := <<"image/jpeg">>, bytes := ?JPEG}} = muse_computer_desktop:frame(?LEGACY(?O)),
    [Shot] = shot_calls(),
    ?assert(lists:member(muse_computer_desktop:shot_script(false, <<"/tmp/openmuse-frame.jpg">>), Shot)),
    ?assertEqual([], receipts()),
    ?assertEqual(undefined, muse_store:get(?O, <<"computer-desktop-screens">>, <<"latest">>)),
    ?assertEqual(undefined, muse_store:get(?O, <<"computer-state">>, <<"lease">>)),
    hook(fun([<<"exec">> | _], _) -> exit_code(4); (_, _) -> default end),
    ?assertEqual({error, {502, <<"The desktop screenshot failed">>}}, muse_computer_desktop:frame(?LEGACY(?O))).

status() ->
    {ok, S0} = muse_computer_desktop:status(?LEGACY(?O)),
    ?assertEqual(#{<<"status">> => <<"running">>, <<"running">> => true, <<"width">> => 1280,
                   <<"height">> => 800, <<"screenshot">> => null, <<"takenAt">> => null}, S0),
    {ok, #{receipt := #{<<"id">> := Id}}} = act(#{<<"action">> => <<"screenshot">>}),
    {ok, #{<<"screenshot">> := Url, <<"receiptId">> := Id, <<"takenAt">> := T}} =
        muse_computer_desktop:status(?LEGACY(?O)),
    ?assert(is_binary(T)),
    ?assertMatch(<<"/api/computer/desktop/screenshot?owner=owner-desk&expires=", _/binary>>, Url),
    ?assertNotEqual(nomatch, binary:match(Url, <<"&receipt=", Id/binary>>)),
    ets:insert(?T, {inspect, sandbox(desktop, false)}),
    ?assertMatch({ok, #{<<"status">> := <<"stopped">>, <<"running">> := false}},
                 muse_computer_desktop:status(?LEGACY(?O))).

start_desktop() ->
    ets:insert(?T, {missing, true}),
    hook(fun([<<"container">>, <<"start">> | _], _) ->
                 ets:insert(?T, {missing, false}), default;
            (_, _) -> default
         end),
    ?assertMatch({ok, #{<<"status">> := <<"running">>}}, muse_computer:start(?LEGACY(?O))),
    Id = muse_computer:identity(?LEGACY(?O)),
    [Create] = [A || A = [<<"container">>, <<"create">> | _] <- calls()],
    ?assertEqual(muse_docker:create_args(Id, <<"openmuse-computer-desktop:local">>, desktop), Create),
    %% COMPUTER_DESKTOP_IMAGE picks the image
    [{dir, Dir}] = ets:lookup(?T, dir),
    config(true, #{<<"COMPUTER_DESKTOP_IMAGE">> => <<"desk:2">>, <<"DATA_DIR">> => list_to_binary(Dir)}),
    ?assertEqual({ok, <<"desk:2">>}, muse_computer_docker:image()).

variant_mismatch() ->
    %% COMPUTER_DESKTOP=true, a light container
    ets:insert(?T, {inspect, sandbox(light, true)}),
    LightFound = {error, {409, <<"The existing computer container is not the desktop variant but "
                                 "COMPUTER_DESKTOP is enabled; refusing to attach. Remove the "
                                 "container to switch variants (the /workspace volume is kept).">>}},
    ?assertEqual(LightFound, act(#{<<"action">> => <<"screenshot">>})),
    ?assertEqual(LightFound, muse_computer:execute(?LEGACY(?O), #{command => <<"pwd">>})),
    ?assertEqual(LightFound, muse_computer:start(?LEGACY(?O))),
    ?assertMatch(#{<<"status">> := <<"error">>, <<"message">> := <<"The existing computer container is not", _/binary>>},
                 muse_computer:snapshot(?LEGACY(?O))),
    %% COMPUTER_DESKTOP off, a desktop container
    config(false),
    ets:insert(?T, {inspect, sandbox(desktop, true)}),
    DesktopFound = {error, {409, <<"The existing computer container is the desktop variant but "
                                   "COMPUTER_DESKTOP is not enabled; refusing to attach. Remove the "
                                   "container to switch variants (the /workspace volume is kept).">>}},
    ?assertEqual(DesktopFound, muse_computer:execute(?LEGACY(?O), #{command => <<"pwd">>})),
    ?assertEqual([], [A || A = [<<"exec">> | _] <- calls()]),
    %% another owner's container of the other variant is a plain refusal
    ets:insert(?T, {inspect, put_in(sandbox(desktop, true), [<<"Config">>, <<"Labels">>],
                                    #{<<"dev.openmuse.variant">> => <<"desktop">>})}),
    ?assertEqual({error, {409, ?REFUSE}}, muse_computer:execute(?LEGACY(?O), #{command => <<"pwd">>})),
    %% an unknown variant label is a plain refusal
    config(true),
    ets:insert(?T, {inspect, put_in(sandbox(desktop, true), [<<"Config">>, <<"Labels">>],
                                    maps:put(<<"dev.openmuse.variant">>, <<"gpu">>,
                                             maps:from_list(maps:get(labels, muse_computer:identity(?LEGACY(?O))))))}),
    ?assertEqual({error, {409, ?REFUSE}}, act(#{<<"action">> => <<"screenshot">>})).

desktop_isolation() ->
    Mods = [fun(I) -> put_in(I, [<<"HostConfig">>, <<"Memory">>], 3221225472) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"MemorySwap">>], -1) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"PidsLimit">>], 2048) end,
            %% a seccomp profile other than the browser's, or none at all
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"SecurityOpt">>],
                             [<<"no-new-privileges">>, <<"seccomp={\"defaultAction\":\"SCMP_ACT_ALLOW\"}">>]) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"SecurityOpt">>], [<<"seccomp=unconfined">>]) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"NanoCpus">>], 4000000000) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"NetworkMode">>], <<"bridge">>) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"ReadonlyRootfs">>], false) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"CapAdd">>], [<<"SYS_ADMIN">>]) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"PortBindings">>],
                             #{<<"5900/tcp">> => [#{<<"HostPort">> => <<"5900">>}]}) end,
            fun(I) -> put_in(I, [<<"HostConfig">>, <<"Tmpfs">>],
                             #{<<"/tmp">> => <<"rw,nosuid,nodev,noexec,size=67108864,mode=1777">>}) end,
            fun(I) -> put_in(I, [<<"Config">>, <<"Entrypoint">>], [<<"/usr/bin/sleep">>]) end,
            fun(I) -> put_in(I, [<<"Config">>, <<"Cmd">>], [<<"/bin/sh">>]) end,
            fun(I) -> put_in(I, [<<"Config">>, <<"Image">>], <<"openmuse-computer:local">>) end,
            fun(I = #{<<"Config">> := C = #{<<"Env">> := E}}) ->
                    I#{<<"Config">> := C#{<<"Env">> := E ++ [<<"XAUTHORITY=/x">>]}}
            end,
            fun(I) -> put_in(I, [<<"NetworkSettings">>, <<"Networks">>], #{<<"bridge">> => #{}}) end],
    lists:foreach(
      fun(Mod) ->
              ets:insert(?T, {inspect, Mod(sandbox(desktop, true))}),
              ?assertEqual({error, {409, ?REFUSE}}, act(#{<<"action">> => <<"screenshot">>}))
      end, Mods),
    ?assertEqual([], desktop_calls()),
    ets:insert(?T, {inspect, sandbox(desktop, true)}),
    ?assertMatch({ok, _}, act(#{<<"action">> => <<"screenshot">>})),
    %% a desktop created since it carries the browser: the browser's seccomp profile
    {ok, Profile} = file:read_file(muse_browser_docker:seccomp_profile()),
    ets:insert(?T, {inspect, put_in(sandbox(desktop, true), [<<"HostConfig">>, <<"SecurityOpt">>],
                                    [<<"no-new-privileges">>, <<"seccomp=", Profile/binary>>])}),
    ?assertMatch({ok, _}, act(#{<<"action">> => <<"screenshot">>})).

light_unchanged() ->
    config(false),
    ets:insert(?T, {inspect, sandbox(light, true)}),
    ?assertMatch({ok, #{<<"status">> := <<"succeeded">>}},
                 muse_computer:execute(?LEGACY(?O), #{command => <<"pwd">>})),
    ?assertEqual({ok, <<"openmuse-computer:local">>}, muse_computer_docker:image()),
    ?assertEqual(light, muse_computer_docker:variant()),
    %% the light limits still apply to a light container
    ets:insert(?T, {inspect, put_in(sandbox(light, true), [<<"HostConfig">>, <<"Memory">>], 1610612736)}),
    ?assertEqual({error, {409, ?REFUSE}}, muse_computer:execute(?LEGACY(?O), #{command => <<"pwd">>})).
