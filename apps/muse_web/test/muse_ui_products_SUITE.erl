%% The "全部文件" card under a chat reply and its preview window (M9-11):
%% the card live at the run's end and after a reload, no card without
%% files, the preview of every kind, downloads and the zip route's headers
%% and checks. The conversation's computer is muse_computer mocked (no
%% Docker).
-module(muse_ui_products_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).

all() ->
    [card_live_and_after_reload, no_card_without_files, preview_every_kind, downloads_and_zip,
     zip_too_large, zip_route_checks].

init_per_testcase(_Case, Config) ->
    Env = muse_web_test_env:start(#{<<"AGENT_BACKEND">> => <<"model">>, <<"FILES_MAX_MB">> => <<"2">>}),
    Cookie = sign_in(Env),
    ok = muse_workspace:ensure_sample(?O),
    ok = meck:new(muse_computer, [passthrough]),
    ok = meck:expect(muse_computer, ref, fun(O, S) -> {O, <<"pc-", S/binary>>} end),
    ok = meck:expect(muse_computer, ensure, fun(O, S) -> {O, <<"pc-", S/binary>>} end),
    ok = meck:expect(muse_computer, ensure_running, fun(_) -> ok end),
    ok = meck:expect(muse_computer, write, fun(_, P, _) -> {ok, #{<<"path">> => P}} end),
    workspace(#{}),
    [{env, Env}, {cookie, Cookie} | Config].

end_per_testcase(_Case, Config) ->
    meck:unload(muse_computer),
    muse_web_test_env:stop(?config(env, Config)).

workspace(Files) ->
    ok = meck:expect(muse_computer, changed_since,
                     fun(_, _, _) ->
                             {ok, #{<<"files">> => [#{<<"path">> => P, <<"size">> => byte_size(B), <<"mtime">> => 1}
                                                    || {P, B} <- lists:sort(maps:to_list(Files))],
                                    <<"skipped">> => [], <<"truncated">> => false}}
                     end),
    ok = meck:expect(muse_computer, download,
                     fun(_, P) ->
                             case maps:find(P, Files) of
                                 {ok, B} -> {ok, #{name => filename:basename(P), bytes => B}};
                                 error -> {error, {422, <<"no">>}}
                             end
                     end).

%% HTTP helpers (as muse_ui_chat_SUITE)

origin() -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

sign_in(Env) ->
    Url = muse_web_test_env:base(Env) ++ "/login",
    {ok, {{_, 302, _}, H, _}} = httpc:request(post, {Url, [{"origin", origin()}], "application/x-www-form-urlencoded", ""},
                                              [{autoredirect, false}], [{body_format, binary}]),
    [SetCookie] = [V || {"set-cookie", V} <- H],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

page(Config, Path) ->
    Url = muse_web_test_env:base(?config(env, Config)) ++ Path,
    {ok, {{_, Status, _}, _, Body}} = httpc:request(get, {Url, [{"cookie", "muse_session=" ++ ?config(cookie, Config)}]},
                                                    [{autoredirect, false}], [{body_format, binary}]),
    {Status, Body}.

get(Config, Path) ->
    Url = muse_web_test_env:base(?config(env, Config)) ++ binary_to_list(Path),
    {ok, {{_, Status, _}, Headers, Body}} = httpc:request(get, {Url, []}, [{autoredirect, false}],
                                                          [{body_format, binary}]),
    {Status, Headers, Body}.

act(Config, Module, Name, Args, Event) ->
    Token = aihtml_action:token({Module, Name, Args}),
    Body = muse_json:encode(#{<<"action">> => Token,
                              <<"event">> => maps:merge(#{<<"type">> => <<"click">>, <<"id">> => <<"x">>}, Event)}),
    Url = muse_web_test_env:base(?config(env, Config)) ++ "/aihtml/action",
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {Url, [{"cookie", "muse_session=" ++ ?config(cookie, Config)}, {"origin", origin()}],
                             "application/json", Body}, [{timeout, 30000}], [{body_format, binary}]),
    {ok, #{<<"ops">> := Ops}} = muse_json:decode(Resp),
    Ops.

products(Config, Name, Args) -> act(Config, muse_ui_products, Name, Args, #{}).

html_of(Ops) ->
    iolist_to_binary([[V || V <- [maps:get(<<"html">>, O, <<>>), maps:get(<<"value">>, O, <<>>)], is_binary(V)]
                      || O <- Ops]).

redirect(Ops) ->
    [Url] = [U || #{<<"op">> := <<"redirect">>, <<"value">> := U} <- Ops],
    Url.

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

watch(Tid) ->
    ok = aihtml_push:join([muse_ui:topic(?O, {thread, Tid})]).

collect_run() -> collect_run([]).

collect_run(Acc) ->
    receive
        {aihtml_push, _, Json} ->
            Ops = case muse_json:decode(iolist_to_binary(Json)) of
                      {ok, #{<<"ops">> := L}} -> L;
                      {ok, L} when is_list(L) -> L
                  end,
            All = Acc ++ Ops,
            case [O || O = #{<<"id">> := <<"chat-actions">>, <<"html">> := H} <- Ops,
                       binary:match(H, <<"发送"/utf8>>) =/= nomatch] of
                [_ | _] -> All;
                [] -> collect_run(All)
            end
    after 15000 -> error({run_not_finished, Acc})
    end.

wait_until(F) -> wait_until(F, 50).
wait_until(_F, 0) -> error(timeout);
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(100), wait_until(F, N - 1)
    end.

thread(Title) ->
    Tid = muse_ids:uuid(),
    {ok, _} = muse_threads:create(?O, Tid, Title),
    Tid.

png() -> <<137, "PNG\r\n", 26, "\n", 0, 0, 0, 13, "IHDR">>.

sample_pdf() ->
    [Id] = [I || #{<<"id">> := I, <<"kind">> := <<"pdf">>} <- muse_files:list(?O, unsigned)],
    {ok, Pdf} = muse_files:pdf_bytes(?O, Id),
    Pdf.

facts() ->
    #{since => muse_time:now_ms(), computer => true, written => [], exported => [], imported => #{}}.

%% Cases

card_live_and_after_reload(Config) ->
    Tid = thread(<<"Hello script">>),
    workspace(#{<<"/workspace/hello.py">> => <<"print('hi')\n">>, <<"/workspace/out.png">> => png()}),
    muse_script_llm:set([{call, <<"write_computer_file">>, #{<<"path">> => <<"/workspace/hello.py">>,
                                                             <<"text">> => <<"print('hi')\n">>}},
                         {text, <<"Done: hello.py and a chart.">>}]),
    watch(Tid),
    _ = act(Config, muse_ui_chat, send, #{thread => Tid}, #{<<"type">> => <<"submit">>,
                                                           <<"form">> => #{<<"text">> => <<"Write it">>}}),
    %% live: the log re-rendered at the run's end carries the card
    Live = html_of(collect_run()),
    [?assert(has(Live, P), P) || P <- [<<"muse-products">>, <<"全部文件"/utf8>>, <<"预览或者下载文件 · 2 个文件"/utf8>>,
                                         <<">预览<"/utf8>>]],
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    %% after a reload: in the reply's bubble, after its text, before its tools
    {200, Page} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    {TextAt, _} = binary:match(Page, <<"Done: hello.py and a chart.">>),
    {CardAt, _} = binary:match(Page, <<"class=\"muse-products\"">>),
    {ToolsAt, _} = binary:match(Page, <<"muse-msg-tools">>, [{scope, {TextAt, byte_size(Page) - TextAt}}]),
    ?assert(TextAt < CardAt andalso CardAt < ToolsAt),
    ?assertEqual(1, length(binary:matches(Page, <<"class=\"muse-products\"">>))),
    %% and the page has the preview window
    ?assert(has(Page, <<"id=\"products-win\"">>)),
    %% a second reply without files adds no card; the first keeps its own
    muse_script_llm:set([{text, <<"Anything else?">>}]),
    _ = act(Config, muse_ui_chat, send, #{thread => Tid}, #{<<"type">> => <<"submit">>,
                                                           <<"form">> => #{<<"text">> => <<"Thanks">>}}),
    _ = collect_run(),
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    {200, Page2} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    ?assertEqual(1, length(binary:matches(Page2, <<"class=\"muse-products\"">>))),
    {Card2, _} = binary:match(Page2, <<"class=\"muse-products\"">>),
    {Second, _} = binary:match(Page2, <<"Anything else?">>),
    ?assert(Card2 < Second).

no_card_without_files(Config) ->
    Tid = thread(<<"Just talk">>),
    muse_script_llm:set([{text, <<"Hello there.">>}]),
    watch(Tid),
    _ = act(Config, muse_ui_chat, send, #{thread => Tid}, #{<<"type">> => <<"submit">>,
                                                           <<"form">> => #{<<"text">> => <<"Hi">>}}),
    Live = html_of(collect_run()),
    ?assert(has(Live, <<"Hello there.">>)),
    ?assertNot(has(Live, <<"muse-products-title">>)),
    ok = wait_until(fun() -> not muse_chat_relay:running(Tid) end),
    {200, Page} = page(Config, "/chat/" ++ binary_to_list(Tid)),
    ?assertNot(has(Page, <<"muse-products-title">>)),
    %% the computer was not even looked at
    ?assertEqual(0, meck:num_calls(muse_computer, changed_since, '_')).

preview_every_kind(Config) ->
    Tid = thread(<<"Kinds">>),
    Files = #{<<"/workspace/README.md">> => <<"# Title\n\n**bold** words\n">>,
              <<"/workspace/report.pdf">> => sample_pdf(),
              <<"/workspace/chart.png">> => png(),
              <<"/workspace/song.mp3">> => <<"ID3", 3, 0, 0, 0, 0, 0, 0>>,
              <<"/workspace/clip.mp4">> => <<0, 0, 0, 24, "ftypisom", 0, 0, 0, 0>>,
              <<"/workspace/main.py">> => <<"print('<b>hi</b>')\n">>,
              <<"/workspace/big.log">> => binary:copy(<<"line of log text\n">>, 15000),
              <<"/workspace/logo.svg">> => <<"<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>">>,
              <<"/workspace/page.html">> => <<"<html><script>alert(1)</script></html>">>,
              <<"/workspace/data.bin">> => <<0, 1, 2, 3, 255, 254>>},
    workspace(Files),
    {ok, #{<<"runId">> := Run, <<"files">> := Listed}} = muse_chat_products:collect(?O, Tid, <<"run-k">>, facts()),
    ?assertEqual(10, length(Listed)),
    Ids = maps:from_list([{N, I} || #{<<"name">> := N, <<"id">> := I} <- Listed]),
    %% open: the header (count, 全部下载), the list, the first file
    Open = products(Config, open, #{thread => Tid, run => Run}),
    OpenHtml = html_of(Open),
    [?assert(has(OpenHtml, P), P) || P <- [<<"10 个文件"/utf8>>, <<"全部下载"/utf8>>, <<"products-list">>,
                                             <<"README.md">>, <<"song.mp3">>, <<"pv-markdown">>,
                                             <<"<strong>bold</strong>">>, <<"在文件中打开"/utf8>>,
                                             <<"href=\"/documents/", (maps:get(<<"README.md">>, Ids))/binary, "\"">>]],
    [_] = [O || O = #{<<"op">> := <<"call">>} <- Open],
    View = fun(Name) -> html_of(products(Config, select, #{thread => Tid, run => Run, file => maps:get(Name, Ids)})) end,
    Pdf = View(<<"report.pdf">>),
    ?assert(has(Pdf, <<"<iframe">>) andalso has(Pdf, <<"/api/files/", (maps:get(<<"report.pdf">>, Ids))/binary, "/content?owner=">>)),
    ?assert(has(View(<<"chart.png">>), <<"id=\"pv-image\"">>)),
    ?assert(has(View(<<"song.mp3">>), <<"<audio">>)),
    ?assert(has(View(<<"clip.mp4">>), <<"<video">>)),
    Py = View(<<"main.py">>),
    ?assert(has(Py, <<"id=\"pv-text\"">>) andalso has(Py, <<"&lt;b&gt;hi&lt;/b&gt;">>)),
    Big = View(<<"big.log">>),
    ?assert(has(Big, <<"id=\"pv-cut\"">>) andalso has(Big, <<"200 KB">>)),
    ?assertNot(has(Py, <<"id=\"pv-cut\"">>)),
    %% never inline active content: SVG gets its details, HTML its source
    Svg = View(<<"logo.svg">>),
    ?assert(has(Svg, <<"无法在这里预览"/utf8>>)),
    ?assertNot(has(Svg, <<"<img">>)),
    Html = View(<<"page.html">>),
    ?assert(has(Html, <<"&lt;script&gt;">>)),
    ?assertNot(has(Html, <<"<script>alert">>)),
    ?assert(has(View(<<"data.bin">>), <<"无法在这里预览"/utf8>>)),
    %% the selected file is marked in the list
    ?assert(has(View(<<"song.mp3">>), <<"muse-pv-active">>)),
    %% a file that is not this reply's is not shown
    NotMine = html_of(products(Config, select, #{thread => Tid, run => Run, file => muse_ids:uuid()})),
    ?assert(has(NotMine, <<"已经不在了"/utf8>>)).

downloads_and_zip(Config) ->
    Tid = thread(<<"报告"/utf8>>),
    workspace(#{<<"/workspace/a.txt">> => <<"alpha">>, <<"/workspace/sub/a.txt">> => <<"beta">>,
                <<"/workspace/图.png"/utf8>> => png()}),
    {ok, #{<<"runId">> := Run, <<"files">> := [#{<<"id">> := A} | _]}} =
        muse_chat_products:collect(?O, Tid, <<"run-z">>, facts()),
    %% one file: a fresh signed URL, an attachment, nosniff
    Url = redirect(products(Config, download, #{file => A})),
    ?assert(has(Url, <<"download=1">>)),
    {200, H1, <<"alpha">>} = get(Config, Url),
    ?assertMatch("attachment; filename*=UTF-8''a.txt", proplists:get_value("content-disposition", H1)),
    ?assertEqual("nosniff", proplists:get_value("x-content-type-options", H1)),
    %% all of them: a zip
    ZipUrl = redirect(products(Config, zip, #{thread => Tid, run => Run})),
    ?assert(has(ZipUrl, <<"/api/threads/", Tid/binary, "/products/run-z/zip?owner=">>)),
    {200, H2, Zip} = get(Config, ZipUrl),
    ?assertEqual("application/zip", proplists:get_value("content-type", H2)),
    ?assertEqual("nosniff", proplists:get_value("x-content-type-options", H2)),
    Disposition = list_to_binary(proplists:get_value("content-disposition", H2)),
    ?assert(has(Disposition, <<"attachment;">>)),
    ?assert(has(Disposition, <<"filename*=UTF-8''", (muse_signing:encode_uri_component(<<"报告-文件.zip"/utf8>>))/binary>>)),
    {ok, Entries} = zip:unzip(Zip, [memory]),
    ?assertEqual(#{<<"a.txt">> => <<"alpha">>, <<"a (2).txt">> => <<"beta">>, <<"图.png"/utf8>> => png()},
                 maps:from_list([{unicode:characters_to_binary(N), B} || {N, B} <- Entries])).

zip_too_large(Config) ->
    %% FILES_MAX_MB=2: a zip holds at most 8 MB
    Tid = thread(<<"Large">>),
    workspace(#{<<"/workspace/a.txt">> => <<"a">>}),
    {ok, #{<<"runId">> := Run, <<"files">> := [#{<<"id">> := Id}]}} =
        muse_chat_products:collect(?O, Tid, <<"run-l">>, facts()),
    _ = muse_store:update(?O, <<"files">>, Id, fun(F) -> {ok, F#{<<"size">> => 9 * 1048576}} end),
    Ops = products(Config, zip, #{thread => Tid, run => Run}),
    ?assertEqual([], [O || O = #{<<"op">> := <<"redirect">>} <- Ops]),
    ?assert(has(html_of(Ops), <<"超过 8 MB，无法打包下载"/utf8>>)),
    Path = muse_signing:signed_path(?O, muse_ui_products:zip_path(Tid, Run)),
    {413, _} = muse_web_test_env:http(?config(env, Config), get, binary_to_list(Path), undefined).

zip_route_checks(Config) ->
    Env = ?config(env, Config),
    Tid = thread(<<"Checks">>),
    workspace(#{<<"/workspace/a.txt">> => <<"a">>}),
    {ok, #{<<"runId">> := Run}} = muse_chat_products:collect(?O, Tid, <<"run-c">>, facts()),
    Path = muse_ui_products:zip_path(Tid, Run),
    %% no session, no signature
    {401, _} = muse_web_test_env:http(Env, get, binary_to_list(Path), undefined),
    %% a signature for this path made for someone else: not their conversation
    {404, _} = muse_web_test_env:http(Env, get, binary_to_list(muse_signing:signed_path(<<"intruder">>, Path)),
                                      undefined),
    %% a signature for another path does not open this one
    Other = muse_signing:signed_path(?O, muse_ui_products:zip_path(Tid, <<"other">>)),
    [_, Query] = binary:split(Other, <<"?">>),
    {403, _} = muse_web_test_env:http(Env, get, binary_to_list(<<Path/binary, "?", Query/binary>>), undefined),
    %% the session token works too, and the listing shows the reply
    Token = muse_web_test_env:login(Env),
    {200, _, _} = muse_web_test_env:http(Env, get, binary_to_list(Path), Token),
    {200, #{<<"turns">> := [#{<<"runId">> := <<"run-c">>, <<"files">> := [_]}]}} =
        muse_web_test_env:http(Env, get, "/api/threads/" ++ binary_to_list(Tid) ++ "/products", Token),
    {404, _} = muse_web_test_env:http(Env, get, "/api/threads/" ++ binary_to_list(muse_ids:uuid()) ++ "/products/x/zip",
                                      Token),
    %% another owner's actions see nothing
    ?assertMatch({error, {404, _}}, muse_chat_products:files(<<"intruder">>, Tid, Run)).
