%% Real browser: the per-user Chromium container (browser/, built as
%% MUSE_TEST_BROWSER_IMAGE, default muse-browser:chrome-test, from browser/
%% when missing). Runs only with MUSE_TEST_BROWSER=1; needs Docker and the
%% internet (example.com, wikipedia.org, httpbin.org, w3.org). Uses a unique
%% deployment id and removes every container and volume of that deployment
%% afterwards; never touches other containers.
-module(muse_browser_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([hardening/1, open_read/1, screenshot/1, click_and_type/1, parallel_sessions/1,
         egress_blocked/1, pdf_download/1, not_automated/1, restart_revive/1, idle_stop/1,
         close_session/1]).

-define(O, <<"local-user">>).
-define(MIN, 60000).

all() ->
    [hardening, open_read, screenshot, click_and_type, parallel_sessions, egress_blocked, pdf_download,
     not_automated, restart_revive, idle_stop, close_session].

image() ->
    case os:getenv("MUSE_TEST_BROWSER_IMAGE") of
        false -> "muse-browser:chrome-test";
        I -> I
    end.

root() ->
    filename:dirname(filename:dirname(filename:dirname(filename:dirname(?FILE)))).

init_per_suite(Config) ->
    case os:getenv("MUSE_TEST_BROWSER") of
        "1" ->
            case os:cmd("docker image inspect --format ok " ++ image() ++ " 2>&1") of
                "ok\n" -> ok;
                _ ->
                    ct:pal("building ~s from browser/", [image()]),
                    Out = os:cmd("docker build -q -t " ++ image() ++ " " ++ filename:join(root(), "browser") ++ " 2>&1"),
                    ct:pal("~s", [Out])
            end,
            Deployment = "browser-suite-" ++ integer_to_list(erlang:unique_integer([positive])) ++ "-"
                ++ os:getpid(),
            {ok, _} = application:ensure_all_started(erlexec),
            Passthrough = [<<"PATH">>, <<"HOME">>, <<"DOCKER_HOST">>, <<"DOCKER_CONTEXT">>,
                           <<"DOCKER_CONFIG">>, <<"DOCKER_TLS_VERIFY">>, <<"DOCKER_CERT_PATH">>],
            Docker = maps:from_list([{K, list_to_binary(V)} || K <- Passthrough,
                                                               V <- [os:getenv(binary_to_list(K))],
                                                               V =/= false]),
            Env = muse_integ_test_env:start(Docker#{<<"BROWSER_ENABLED">> => <<"true">>,
                                                    <<"BROWSER_IMAGE">> => list_to_binary(image()),
                                                    <<"COMPUTER_DEPLOYMENT_ID">> => list_to_binary(Deployment)}),
            application:set_env(muse_integ, browser_pool_timer, false),
            {ok, Pool} = muse_browser_pool:start_link(),
            unlink(Pool),
            [{env, Env}, {pool, Pool}, {label, muse_computer:deployment()} | Config];
        _ ->
            {skip, "set MUSE_TEST_BROWSER=1 (needs Docker and the internet)"}
    end.

end_per_suite(Config) ->
    Label = binary_to_list(?config(label, Config)),
    ct:pal("cleanup: ~s~s",
           [os:cmd("for c in $(docker ps -aq --filter label=dev.openmuse.deployment=" ++ Label
                   ++ "); do docker rm -f $c; done"),
            os:cmd("for v in $(docker volume ls -q --filter label=dev.openmuse.deployment=" ++ Label
                   ++ "); do docker volume rm $v; done")]),
    gen_server:stop(?config(pool, Config)),
    application:unset_env(muse_integ, browser_pool_timer),
    muse_time:set_offset(0),
    muse_integ_test_env:stop(?config(env, Config)).

%% Helpers

container() ->
    binary_to_list(maps:get(container, muse_browser_docker:identity(?O))).

diag(Id, What) -> diag(Id, What, null).
diag(Id, What, Url) ->
    {ok, R} = muse_browser_docker:call(?O, #{<<"op">> => <<"diag">>, <<"session">> => Id,
                                             <<"what">> => What, <<"url">> => Url}, 30000),
    R.

in_container(Cmd) ->
    os:cmd("docker exec " ++ container() ++ " sh -c '" ++ Cmd ++ "' 2>&1").

png_size(<<137, "PNG", 13, 10, 26, 10, _:4/binary, "IHDR", W:32, H:32, _/binary>>) -> {W, H}.

open(Url) ->
    {ok, #{<<"id">> := Id, <<"status">> := <<"active">>} = S} = muse_browser:create(?O, Url),
    {Id, S}.

contains(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

%% Cases

%% The container is created with the hardening settings, and Chrome runs
%% with its sandbox on (renderers in their own user, pid and network
%% namespaces), without CDP or automation switches.
hardening(_Config) ->
    {_, _} = open(<<"https://example.com/">>),
    {ok, [Info]} = muse_json:decode(list_to_binary(os:cmd("docker inspect " ++ container()))),
    #{<<"HostConfig">> := H, <<"Config">> := C, <<"Mounts">> := Mounts} = Info,
    true = maps:get(<<"ReadonlyRootfs">>, H),
    false = maps:get(<<"Privileged">>, H),
    [<<"ALL">>] = maps:get(<<"CapDrop">>, H),
    null = maps:get(<<"CapAdd">>, H),
    [<<"no-new-privileges">>, <<"seccomp={", _/binary>>] = lists:sort(maps:get(<<"SecurityOpt">>, H)),
    2147483648 = maps:get(<<"Memory">>, H),
    1024 = maps:get(<<"PidsLimit">>, H),
    2000000000 = maps:get(<<"NanoCpus">>, H),
    null = maps:get(<<"Binds">>, H),
    #{} = maps:get(<<"PortBindings">>, H),
    [#{<<"Type">> := <<"volume">>, <<"Destination">> := <<"/data">>}] = Mounts,
    <<"1000:1000">> = maps:get(<<"User">>, C),
    Ps = list_to_binary(in_container("ps -eo args")),
    ?assert(contains(Ps, <<"/usr/lib/chromium/chromium">>)),
    [?assertNot(contains(Ps, Bad), Bad) || Bad <- [<<"--no-sandbox">>, <<"--remote-debugging">>,
                                                   <<"--enable-automation">>, <<"--headless">>,
                                                   <<"--load-extension">>]],
    Ns = string:split(string:trim(in_container(
        "r=$(pgrep -f -- \"--type=renderer\" | head -1); readlink /proc/1/ns/user /proc/$r/ns/user "
        "/proc/1/ns/pid /proc/$r/ns/pid")), "\n", all),
    [U1, U2, P1, P2] = Ns,
    ?assertNotEqual(U1, U2),
    ?assertNotEqual(P1, P2),
    %% the root filesystem is read-only, /tmp is not executable
    ?assert(contains(list_to_binary(in_container("touch /opt/x")), <<"Read-only">>)),
    ?assertEqual("1000\n", in_container("id -u")).

open_read(_Config) ->
    {Id, #{<<"title">> := <<"Example Domain">>, <<"url">> := <<"https://example.com/">>,
           <<"consoleUrl">> := _, <<"previewUrl">> := _}} = open(<<"https://example.com/">>),
    {ok, #{<<"title">> := <<"Example Domain">>, <<"text">> := Text, <<"truncated">> := false}} =
        muse_browser:read(?O, Id),
    ?assert(contains(Text, <<"documentation examples">>)),
    %% Markdown, not innerText: the link is a Markdown link
    ?assert(contains(Text, <<"[Learn more](https://">>)),
    %% the chat tool: the thread's session, capped text
    {ok, #{<<"sessionId">> := S, <<"title">> := <<"Wikipedia">>}} =
        muse_browser:observe_for_thread(?O, <<"thread-real">>, <<"https://www.wikipedia.org/">>),
    {ok, #{<<"sessionId">> := S, <<"url">> := <<"https://www.wikipedia.org/">>}} =
        muse_browser:read_for_thread(?O, <<"thread-real">>).

screenshot(_Config) ->
    {Id, _} = open(<<"https://example.com/">>),
    {ok, Png} = muse_browser:preview(?O, Id),
    ?assertEqual({1280, 800}, png_size(Png)),
    %% a page Chrome will not capture (about:blank after a blocked
    %% redirect) falls back to an X screenshot of the window
    {error, {502, _}} = muse_browser:navigate(?O, Id, <<"https://httpbin.org/redirect-to?url=http%3A%2F%2F127.0.0.1%2F">>),
    {ok, Blank} = muse_browser:preview(?O, Id),
    ?assertEqual({1280, 800}, png_size(Blank)).

%% Clicks land exactly where asked (trusted events), text (CJK included)
%% and keys reach the page; humanised (agent) and direct (person) input.
click_and_type(_Config) ->
    {Id, _} = open(<<"https://www.wikipedia.org/">>),
    #{<<"x">> := X, <<"y">> := Y, <<"w">> := W, <<"h">> := H} = diag(Id, <<"rect">>, <<"#searchInput">>),
    _ = diag(Id, <<"clicks">>),
    Cx = round(X + W / 2), Cy = round(Y + H / 2),
    {ok, _} = muse_browser:input(?O, Id, #{<<"type">> => <<"click">>, <<"x">> => Cx, <<"y">> => Cy}, human),
    [#{<<"x">> := Cx, <<"y">> := Cy, <<"trusted">> := true} | _] = diag(Id, <<"clicks">>),
    {ok, _} = muse_browser:input(?O, Id, #{<<"type">> => <<"text">>, <<"text">> => <<"Erlang 北京"/utf8>>}, human),
    #{<<"tag">> := <<"input">>, <<"value">> := <<"Erlang 北京"/utf8>>} = diag(Id, <<"active">>),
    %% the console's direct input: select all, replace, Enter
    {ok, _} = muse_browser:input(?O, Id, #{<<"type">> => <<"key">>, <<"key">> => <<"Control+a">>}),
    {ok, _} = muse_browser:input(?O, Id, #{<<"type">> => <<"text">>, <<"text">> => <<"Erlang">>}),
    #{<<"value">> := <<"Erlang">>} = diag(Id, <<"active">>),
    {ok, _} = muse_browser:input(?O, Id, #{<<"type">> => <<"key">>, <<"key">> => <<"Enter">>}),
    timer:sleep(3000),
    {ok, #{<<"url">> := Url, <<"text">> := Text}} = muse_browser:read(?O, Id),
    ct:pal("after Enter: ~s", [Url]),
    ?assert(contains(Url, <<"Erlang">>) orelse contains(Url, <<"search">>)),
    ?assert(contains(Text, <<"Erlang">>)),
    {ok, _} = muse_browser:input(?O, Id, #{<<"type">> => <<"scroll">>, <<"deltaY">> => 600}),
    {error, {502, <<"Unsupported browser input or coordinates.">>}} =
        muse_browser:input(?O, Id, #{<<"type">> => <<"click">>, <<"x">> => 1280, <<"y">> => 10}).

%% Two sessions at once, each its own window; a covered window's screenshot
%% is its own page, unchanged.
parallel_sessions(_Config) ->
    Self = self(),
    [spawn_link(fun() -> Self ! {N, muse_browser:create(?O, U)} end)
     || {N, U} <- [{a, <<"https://example.com/">>}, {b, <<"https://www.wikipedia.org/">>}]],
    {ok, #{<<"id">> := A, <<"title">> := <<"Example Domain">>}} = receive {a, Ra} -> Ra after 90000 -> error(a) end,
    {ok, #{<<"id">> := B, <<"title">> := <<"Wikipedia">>}} = receive {b, Rb} -> Rb after 90000 -> error(b) end,
    {ok, A1} = muse_browser:preview(?O, A),
    {ok, _} = muse_browser:navigate(?O, B, <<"https://www.wikipedia.org/">>),
    %% B's window is in front now; A's screenshot is still A's page
    {ok, A2} = muse_browser:preview(?O, A),
    {ok, B1} = muse_browser:preview(?O, B),
    ?assertEqual(A1, A2),
    ?assertNotEqual(A1, B1),
    {ok, #{<<"title">> := <<"Example Domain">>}} = muse_browser:read(?O, A),
    {ok, #{<<"title">> := <<"Wikipedia">>}} = muse_browser:read(?O, B),
    #{<<"sessions">> := Open} = diag_sessions(),
    ?assert(lists:member(A, Open) andalso lists:member(B, Open)).

diag_sessions() ->
    {ok, R} = muse_browser_docker:call(?O, #{<<"op">> => <<"sessions">>}, 10000),
    R.

%% Neither our navigations nor the page itself reach loopback, the LAN or
%% the cloud metadata address: refused before Chrome (our navigations) and
%% by the egress proxy (page fetches, page navigations, redirects).
egress_blocked(_Config) ->
    Blocked = [<<"http://127.0.0.1:8787/">>, <<"http://192.168.3.13/">>, <<"http://192.168.3.13:8787/api/health">>,
               <<"http://169.254.169.254/latest/meta-data/">>, <<"http://localhost/">>, <<"http://[::1]/">>,
               <<"file:///etc/passwd">>, <<"view-source:https://example.com/">>, <<"data:text/html,x">>,
               <<"chrome://version/">>, <<"javascript:alert(1)">>],
    [{error, {502, <<"Only public HTTP(S) destinations on ports 80 and 443 are allowed.">>}} =
         muse_browser:create(?O, U) || U <- Blocked],
    {Id, _} = open(<<"https://example.com/">>),
    Targets = [<<"http://127.0.0.1:8118/">>, <<"http://127.0.0.1:8787/api/health">>,
               <<"http://192.168.3.13:8787/api/health">>, <<"http://192.168.3.13/">>,
               <<"http://169.254.169.254/latest/meta-data/">>, <<"http://[::1]:8118/">>],
    [_ = diag(Id, <<"fetch">>, T) || T <- Targets],
    #{<<"ok">> := false} = diag(Id, <<"fetch">>, <<"https://192.168.3.13/">>),
    %% a public destination works the same way (the check is not "block all")
    #{<<"ok">> := true} = diag(Id, <<"fetch">>, <<"https://www.wikipedia.org/">>),
    #{<<"lines">> := Lines} = diag(Id, <<"egress">>),
    Log = iolist_to_binary(lists:join(<<"\n">>, Lines)),
    [?assert(contains(Log, <<"blocked GET ", T/binary>>), T) || T <- Targets],
    ?assert(contains(Log, <<"blocked CONNECT 192.168.3.13:443">>)),
    %% the page navigates itself: the proxy refuses, read refuses the URL
    [begin
         #{<<"url">> := U} = diag(Id, <<"assign">>, U),
         {error, {502, <<"Only public HTTP(S) destinations on ports 80 and 443 are allowed.">>}} =
             muse_browser:read(?O, Id),
         {ok, _} = muse_browser:navigate(?O, Id, <<"https://example.com/">>)
     end || U <- [<<"http://192.168.3.13:8787/">>, <<"http://169.254.169.254/">>, <<"http://127.0.0.1:8118/">>]],
    #{<<"lines">> := Lines2} = diag(Id, <<"egress">>),
    ?assert(contains(iolist_to_binary(Lines2), <<"blocked GET http://169.254.169.254/">>)),
    %% a public page redirecting to a private address
    {error, {502, <<"The page could not be loaded. It may be unreachable or contain a blocked destination.">>}} =
        muse_browser:navigate(?O, Id, <<"https://httpbin.org/redirect-to?url=http%3A%2F%2F192.168.3.13%3A8787%2F">>),
    %% ... leaves the session on about:blank, which is not readable
    {error, {502, <<"Only public HTTP(S) destinations on ports 80 and 443 are allowed.">>}} =
        muse_browser:read(?O, Id).

pdf_download(_Config) ->
    {Id, _} = open(<<"https://example.com/">>),
    {ok, _} = muse_browser:navigate(?O, Id, <<"https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf">>),
    timer:sleep(1500),
    {ok, #{<<"files">> := [#{<<"id">> := F, <<"name">> := <<"dummy.pdf">>}], <<"failures">> := []}} =
        muse_browser:imports(?O, Id),
    {ok, #{<<"name">> := <<"dummy.pdf">>}} = muse_files:get(?O, F),
    %% imported once
    {ok, #{<<"files">> := [#{<<"id">> := F}]}} = muse_browser:imports(?O, Id),
    %% a non-PDF download is reported, not imported
    {ok, _} = muse_browser:navigate(?O, Id, <<"https://httpbin.org/response-headers?Content-Disposition=attachment%3B%20filename%3Dx.txt">>),
    timer:sleep(1500),
    {ok, #{<<"files">> := [_], <<"failures">> := Failures}} = muse_browser:imports(?O, Id),
    ct:pal("failures: ~p", [Failures]),
    ?assertMatch([#{<<"code">> := <<"UNSUPPORTED_DOWNLOAD">>} | _], Failures).

%% No automation traces: navigator.webdriver false, no CDP Runtime trace,
%% the PDF viewer plugins present, Chinese locale and Shanghai time.
not_automated(_Config) ->
    {Id, _} = open(<<"https://example.com/">>),
    P = diag(Id, <<"probe">>),
    ct:pal("probe: ~p", [P]),
    false = maps:get(<<"webdriver">>, P),
    false = maps:get(<<"cdpRuntimeTrace">>, P),
    5 = maps:get(<<"plugins">>, P),
    <<"Asia/Shanghai">> = maps:get(<<"timezone">>, P),
    <<"zh-CN", _/binary>> = maps:get(<<"languages">>, P),
    <<"1280x800">> = maps:get(<<"inner">>, P),
    ?assertNot(contains(maps:get(<<"ua">>, P), <<"Headless">>)),
    ?assertNot(contains(maps:get(<<"webglRenderer">>, P), <<"SwiftShader">>)).

%% docker restart: the windows are gone; every session re-opens at its
%% last URL on next use.
restart_revive(_Config) ->
    {Id, _} = open(<<"https://www.wikipedia.org/">>),
    os:cmd("docker restart -t 2 " ++ container()),
    {ok, #{<<"url">> := <<"https://www.wikipedia.org/">>, <<"title">> := <<"Wikipedia">>}} =
        muse_browser:read(?O, Id),
    {ok, Png} = muse_browser:preview(?O, Id),
    {1280, 800} = png_size(Png).

%% BROWSER_IDLE_MINUTES (30) without use: the container is stopped, its
%% volume kept; the next request starts it again and revives the session.
idle_stop(_Config) ->
    {Id, _} = open(<<"https://example.com/">>),
    running = muse_browser_docker:state(?O),
    muse_browser_pool:sweep(),
    running = muse_browser_docker:state(?O),
    muse_time:set_offset(31 * ?MIN),
    muse_browser_pool:sweep(),
    stopped = muse_browser_docker:state(?O),
    Volume = binary_to_list(maps:get(volume, muse_browser_docker:identity(?O))),
    ?assertEqual(Volume ++ "\n", os:cmd("docker volume ls -q --filter name=" ++ Volume)),
    {ok, #{<<"title">> := <<"Example Domain">>}} = muse_browser:read(?O, Id),
    running = muse_browser_docker:state(?O),
    muse_time:set_offset(0).

close_session(_Config) ->
    {Id, _} = open(<<"https://example.com/">>),
    {ok, #{<<"status">> := <<"closed">>, <<"url">> := <<"https://example.com/">>}} = muse_browser:close(?O, Id),
    #{<<"sessions">> := Open} = diag_sessions(),
    ?assertNot(lists:member(Id, Open)).
