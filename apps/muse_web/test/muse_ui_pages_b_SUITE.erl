%% UI pages of M6-5 and M6-6 (tasks/M6-ui.md): documents, computer,
%% browser, apps and settings. Each page is rendered with the session
%% cookie, then its actions are called the way the aihtml runtime calls
%% them (POST /aihtml/action with a signed token and an event), and the
%% domain effect is checked. Sample mode; the browser worker is
%% muse_fake_worker, the computer is muse_computer mocked with meck.
-module(muse_ui_pages_b_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(BOUNDARY, "muse-ui-test-boundary-41c9").
-define(OWNER, <<"local-user">>).

all() ->
    [settings_page, documents_page, computer_unconfigured, computer_page, browser_unconfigured,
     browser_console, browser_input_mapping, apps_sample, apps_live, actions_need_session].

init_per_testcase(browser_console, Config) ->
    {ok, _} = application:ensure_all_started(cowboy),
    {Url, Token} = muse_fake_worker:start(),
    Env = muse_web_test_env:start(#{<<"BROWSER_WORKER_URL">> => Url, <<"WORKER_TOKEN">> => Token}),
    ok = meck:new(muse_browser, [passthrough]),
    [{env, Env}, {worker, true} | Config];
init_per_testcase(computer_page, Config) ->
    Env = muse_web_test_env:start(),
    ok = meck:new(muse_computer, [passthrough]),
    [{env, Env} | Config];
init_per_testcase(apps_live, Config) ->
    [{env, muse_web_test_env:start(#{<<"WORKSPACE_MODE">> => <<"live">>,
                                     <<"OPENMUSE_ACCESS_KEY">> => binary:copy(<<"k">>, 24),
                                     <<"TOKEN_ENCRYPTION_KEY">> => base64:encode(crypto:strong_rand_bytes(32)),
                                     <<"GOOGLE_CLIENT_ID">> => <<"client-id.apps.googleusercontent.com">>,
                                     <<"GOOGLE_CLIENT_SECRET">> => <<"client-secret">>,
                                     <<"MUSE_UI_SECRET">> => binary:copy(<<"s">>, 32)})} | Config];
init_per_testcase(_Case, Config) ->
    [{env, muse_web_test_env:start()} | Config].

end_per_testcase(Case, Config) ->
    case Case of
        browser_console -> meck:unload(muse_browser);
        computer_page -> meck:unload(muse_computer);
        _ -> ok
    end,
    muse_web_test_env:stop(?config(env, Config)),
    case ?config(worker, Config) of
        true -> muse_fake_worker:stop();
        _ -> ok
    end.

%% HTTP helpers

host(Config) ->
    #{port := Port} = ?config(env, Config),
    "localhost:" ++ integer_to_list(Port).

%% The UI is served at PUBLIC_API_URL (http://localhost:Port): the browser
%% sends that Origin and Host.
origin(_Config) -> binary_to_list(muse_mw:origin_of(muse_config:get(public_url))).

same_origin(Config) -> [{"origin", origin(Config)}, {"host", host(Config)}].

req(Config, Method, Path, Headers) ->
    req(Config, Method, Path, Headers, undefined).

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

sign_in(Config) -> sign_in(Config, []).

sign_in(Config, Form) ->
    {302, H, _} = req(Config, post, "/login", same_origin(Config), {form, Form}),
    [SetCookie] = [V || {"set-cookie", V} <- H],
    [Pair | _] = string:split(SetCookie, ";"),
    ["muse_session", Value] = string:split(Pair, "="),
    Value.

cookie(Cookie) -> [{"cookie", "muse_session=" ++ Cookie}].

page(Config, Cookie, Path) ->
    {200, _, Html} = req(Config, get, Path, cookie(Cookie)),
    Html.

%% Call an action as the runtime does; the ops of every reply line
%% (one line, or NDJSON lines when the action flushed).
act(Config, Cookie, Ref, Event) ->
    {Status, Lines} = act_raw(Config, cookie(Cookie), Ref, Event),
    ?assertEqual(200, Status),
    lists:append([Ops || #{<<"ops">> := Ops} <- Lines]).

act_raw(Config, Headers, Ref, Event) ->
    Body = muse_json:encode(#{<<"action">> => aihtml_action:token(Ref), <<"event">> => Event}),
    {Status, _, Resp} = req(Config, post, "/aihtml/action", Headers ++ same_origin(Config),
                            {"application/json", Body}),
    Lines = [begin {ok, J} = muse_json:decode(L), J end
             || L <- binary:split(Resp, <<"\n">>, [global, trim_all]), Status =:= 200],
    {Status, Lines}.

%% Everything an op list renders, for substring checks.
rendered(Ops) ->
    iolist_to_binary([[maps:get(K, Op, <<>>) || K <- [<<"html">>, <<"value">>]] || Op <- Ops,
                      is_binary(maps:get(<<"html">>, Op, <<>>)), is_binary(maps:get(<<"value">>, Op, <<>>))]).

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

form(Fields) -> #{<<"type">> => <<"submit">>, <<"form">> => Fields}.

%% Settings

settings_page(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, "/settings"),
    [?assert(has(Html, P), P) || P <- [<<"id=\"settings-identity\"">>, <<"id=\"settings-theme\"">>,
                                       <<"action=\"/logout\"">>, <<"id=\"settings-memories\"">>,
                                       <<"data-ah-subscribe">>, <<"OpenMuse">>]],
    %% identity
    Ops = act(Config, Cookie, {muse_ui_settings, identity, #{}},
              form(#{<<"name">> => <<"Ada">>, <<"tone">> => <<"concise">>, <<"avatar">> => <<"lilac">>,
                     <<"showChatUpdates">> => <<"true">>})),
    ?assert(has(rendered(Ops), <<"身份已保存"/utf8>>)),
    {ok, #{<<"identity">> := Identity}} = muse_agent_service:snapshot(?OWNER),
    ?assertMatch(#{<<"name">> := <<"Ada">>, <<"tone">> := <<"concise">>, <<"avatar">> := <<"lilac">>,
                   <<"showChatUpdates">> := true}, Identity),
    Off = act(Config, Cookie, {muse_ui_settings, identity, #{}},
              form(#{<<"name">> => <<"Ada">>, <<"tone">> => <<"warm">>, <<"avatar">> => <<>>})),
    ?assert(has(rendered(Off), <<"身份已保存"/utf8>>)),
    {ok, #{<<"identity">> := #{<<"showChatUpdates">> := false, <<"tone">> := <<"warm">>}}} =
        muse_agent_service:snapshot(?OWNER),
    %% validation errors are shown, nothing saved
    Bad = act(Config, Cookie, {muse_ui_settings, identity, #{}},
              form(#{<<"name">> => <<"  ">>, <<"tone">> => <<"rude">>})),
    ?assert(has(rendered(Bad), <<"alert">>)),
    {ok, #{<<"identity">> := #{<<"name">> := <<"Ada">>}}} = muse_agent_service:snapshot(?OWNER),
    %% memories: add, edit, forget
    Added = act(Config, Cookie, {muse_ui_settings, add_memory, #{}}, form(#{<<"text">> => <<"Prefers tea">>})),
    ?assert(has(rendered(Added), <<"Prefers tea">>)),
    [#{<<"id">> := MemId, <<"text">> := <<"Prefers tea">>, <<"source">> := <<"You">>}] =
        muse_agent_service:memories(?OWNER),
    ?assert(has(page(Config, Cookie, "/settings"), <<"memory-", MemId/binary>>)),
    Empty = act(Config, Cookie, {muse_ui_settings, add_memory, #{}}, form(#{<<"text">> => <<>>})),
    ?assert(has(rendered(Empty), <<"alert">>)),
    ?assertEqual(1, length(muse_agent_service:memories(?OWNER))),
    Edited = act(Config, Cookie, {muse_ui_settings, update_memory, #{id => MemId}},
                 form(#{<<"text">> => <<"Prefers green tea">>})),
    ?assert(has(rendered(Edited), <<"Prefers green tea">>)),
    [#{<<"text">> := <<"Prefers green tea">>}] = muse_agent_service:memories(?OWNER),
    Forgot = act(Config, Cookie, {muse_ui_settings, forget_memory, #{id => MemId}}, #{<<"type">> => <<"click">>}),
    ?assertNot(has(rendered(Forgot), <<"Prefers green tea">>)),
    [] = muse_agent_service:memories(?OWNER),
    Missing = act(Config, Cookie, {muse_ui_settings, forget_memory, #{id => MemId}}, #{<<"type">> => <<"click">>}),
    ?assert(has(rendered(Missing), <<"Memory not found">>)),
    %% the refresh action re-renders the list
    [_ | _] = act(Config, Cookie, {muse_ui_settings, refresh, #{}}, #{}).

%% Documents

documents_page(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, "/documents"),
    [?assert(has(Html, P), P) || P <- [<<"data-ah=\"upload\"">>, <<"data-ah-url=\"/upload\"">>,
                                       <<"id=\"doc-list\"">>, <<"data-ah-subscribe">>]],
    {ok, Pdf} = muse_pdf:sample(),
    Name = <<"Field trip slip.pdf">>,
    %% upload: session and origin required, then /api/files' rules
    {401, _, _} = req(Config, post, "/upload", same_origin(Config), multipart(Name, Pdf)),
    {403, _, _} = req(Config, post, "/upload", cookie(Cookie) ++ [{"sec-fetch-site", "cross-site"}],
                      multipart(Name, Pdf)),
    {405, _, _} = req(Config, get, "/upload", cookie(Cookie)),
    {400, _, NotPdf} = req(Config, post, "/upload", cookie(Cookie) ++ same_origin(Config),
                           {"application/json", <<"{}">>}),
    ?assert(has(NotPdf, <<"Choose a PDF file">>)),
    {422, _, _} = req(Config, post, "/upload", cookie(Cookie) ++ same_origin(Config),
                      multipart(<<"x.pdf">>, <<"not a pdf">>)),
    {201, _, Uploaded} = req(Config, post, "/upload", cookie(Cookie) ++ same_origin(Config), multipart(Name, Pdf)),
    {ok, #{<<"id">> := Id, <<"name">> := Name, <<"source">> := <<"Uploaded by you">>}} = muse_json:decode(Uploaded),
    ?assert(lists:any(fun(#{<<"id">> := I}) -> I =:= Id end, muse_files:list(?OWNER))),
    %% the upload's change event refreshes the list
    UpOps = act(Config, Cookie, {muse_ui_documents, uploaded, #{}},
                #{<<"type">> => <<"change">>, <<"value">> => iolist_to_binary([$[, Uploaded, $]])}),
    ?assert(has(rendered(UpOps), Name)),
    ?assert(has(rendered(UpOps), <<"/documents/", Id/binary>>)),
    %% detail: signed iframe preview, fields, import
    Detail = page(Config, Cookie, "/documents/" ++ binary_to_list(Id)),
    {match, [Src]} = re:run(Detail, <<"<iframe[^>]*src=\"([^\"]+)\"">>, [{capture, all_but_first, binary}]),
    Path = binary:replace(Src, <<"&amp;">>, <<"&">>, [global]),
    ?assertMatch(<<"/api/files/", _/binary>>, Path),
    {200, ContentHeaders, Pdf} = req(Config, get, binary_to_list(Path), []),
    ?assertEqual("application/pdf", proplists:get_value("content-type", ContentHeaders)),
    ?assert(has(Detail, <<"id=\"doc-fill\"">>)),
    ?assert(has(Detail, <<"id=\"doc-import\"">>)),
    %% fill: inputs are named by field index
    {ok, #{<<"fields">> := Fields}} = muse_files:get(?OWNER, Id),
    ?assertNotEqual([], Fields),
    Indexed = lists:zip(lists:seq(0, length(Fields) - 1), Fields),
    FormFields = maps:from_list([{<<"f", (integer_to_binary(I))/binary>>,
                                  case T of <<"checkbox">> -> <<"true">>; _ -> <<"Alex Rivera">> end}
                                 || {I, #{<<"type">> := T}} <- Indexed, T =/= <<"unsupported">>]),
    FillOps = act(Config, Cookie, {muse_ui_documents, fill, #{id => Id}}, form(FormFields)),
    ?assert(has(rendered(FillOps), <<"已保存填写后的副本"/utf8>>)),
    [#{<<"id">> := FilledId, <<"name">> := FilledName}] =
        [F || F = #{<<"parentId">> := P} <- muse_files:list(?OWNER), P =:= Id],
    ?assertEqual(<<"Field trip slip — filled.pdf"/utf8>>, FilledName),
    {ok, #{<<"fields">> := FilledFields}} = muse_files:get(?OWNER, FilledId),
    ?assert(lists:any(fun(#{<<"value">> := V}) -> V =:= <<"Alex Rivera">> end, FilledFields)),
    %% import into the computer: not configured in sample mode
    ImpOps = act(Config, Cookie, {muse_ui_documents, import, #{id => Id}},
                 form(#{<<"path">> => <<"/workspace/slip.pdf">>})),
    ?assert(has(rendered(ImpOps), <<"Computer is not configured">>)),
    %% another owner's / unknown document
    Unknown = page(Config, Cookie, "/documents/" ++ binary_to_list(muse_ids:uuid())),
    ?assert(has(Unknown, <<"找不到该文档"/utf8>>)),
    BadFill = act(Config, Cookie, {muse_ui_documents, fill, #{id => muse_ids:uuid()}}, form(#{})),
    ?assert(has(rendered(BadFill), <<"File not found">>)).

multipart(Name, Bytes) ->
    B = <<?BOUNDARY>>,
    Body = iolist_to_binary([<<"--", B/binary, "\r\n">>,
                             <<"Content-Disposition: form-data; name=\"file\"; filename=\"", Name/binary, "\"\r\n"
                               "Content-Type: application/pdf\r\n\r\n">>, Bytes, <<"\r\n">>,
                             <<"--", B/binary, "--\r\n">>]),
    {"multipart/form-data; boundary=" ?BOUNDARY, Body}.

%% Computer

computer_unconfigured(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, "/computer"),
    ?assert(has(Html, <<"id=\"comp-unconfigured\"">>)),
    ?assert(has(Html, <<"电脑未配置"/utf8>>)),
    Ops = act(Config, Cookie, {muse_ui_computer, run, #{}}, form(#{<<"command">> => <<"ls">>})),
    ?assert(has(rendered(Ops), <<"Computer is not configured">>)).

computer_page(Config) ->
    Cookie = sign_in(Config),
    Running = #{<<"enabled">> => true, <<"provider">> => <<"docker">>, <<"workspacePath">> => <<"/workspace">>,
                <<"network">> => <<"disabled">>, <<"status">> => <<"running">>, <<"commands">> => []},
    Self = self(),
    meck:expect(muse_computer, snapshot, fun(?OWNER) -> Running end),
    meck:expect(muse_computer, list,
                fun(?OWNER) ->
                        {ok, #{<<"path">> => <<"/workspace">>,
                               <<"entries">> => [#{<<"name">> => <<"notes">>, <<"path">> => <<"/workspace/notes">>,
                                                   <<"type">> => <<"directory">>, <<"size">> => 4096},
                                                 #{<<"name">> => <<"todo.txt">>, <<"path">> => <<"/workspace/todo.txt">>,
                                                   <<"type">> => <<"file">>, <<"size">> => 5}]}}
                end),
    meck:expect(muse_computer, list,
                fun(?OWNER, <<"/workspace/notes">> = P) ->
                        {ok, #{<<"path">> => P,
                               <<"entries">> => [#{<<"name">> => <<"inner.md">>, <<"path">> => <<P/binary, "/inner.md">>,
                                                   <<"type">> => <<"file">>, <<"size">> => 3}]}}
                end),
    meck:expect(muse_computer, read, fun(?OWNER, <<"/workspace/todo.txt">> = P) -> {ok, #{<<"path">> => P, <<"text">> => <<"buy <milk>">>}} end),
    meck:expect(muse_computer, write, fun(?OWNER, P, T) -> Self ! {write, P, T}, {ok, #{<<"path">> => P}} end),
    meck:expect(muse_computer, mkdir, fun(?OWNER, P) -> Self ! {mkdir, P}, {ok, #{<<"path">> => P}} end),
    meck:expect(muse_computer, start, fun(?OWNER) -> {ok, Running} end),
    meck:expect(muse_computer, stop, fun(?OWNER) -> {error, {409, <<"Computer is busy. Wait for the current operation to finish.">>}} end),
    meck:expect(muse_computer, export_pdf,
                fun(?OWNER, <<"/workspace/out.pdf">>) -> {ok, #{<<"id">> => <<"f-1">>, <<"name">> => <<"out.pdf">>}} end),
    meck:expect(muse_computer, import_pdf, fun(?OWNER, P, F) -> Self ! {import, P, F}, {ok, #{<<"path">> => P}} end),
    Stdout = iolist_to_binary([binary:copy(<<"x">>, 5000), <<"é"/utf8>>, <<"\nend of output\n">>]),
    meck:expect(muse_computer, execute,
                fun(?OWNER, #{<<"command">> := <<"ls /workspace">>, <<"cwd">> := <<"/workspace">>}, #{cancel := Pid})
                      when is_pid(Pid) ->
                        {ok, #{<<"id">> => <<"c1">>, <<"command">> => <<"ls /workspace">>, <<"cwd">> => <<"/workspace">>,
                               <<"status">> => <<"succeeded">>, <<"stdout">> => Stdout, <<"stderr">> => <<"warn\n">>,
                               <<"exitCode">> => 0, <<"truncated">> => false}}
                end),
    Html = page(Config, Cookie, "/computer"),
    [?assert(has(Html, P), P) || P <- [<<"id=\"comp-tree\"">>, <<"todo.txt">>, <<"notes">>, <<"id=\"comp-term\"">>,
                                       <<"id=\"comp-run\"">>, <<"运行中"/utf8>>]],
    %% terminal: the reply streams (several NDJSON lines), echo first
    {200, Lines} = act_raw(Config, cookie(Cookie), {muse_ui_computer, run, #{}},
                           form(#{<<"command">> => <<"ls /workspace">>, <<"cwd">> => <<"/workspace">>})),
    ?assert(length(Lines) >= 3),
    [#{<<"ops">> := [#{<<"op">> := <<"text">>, <<"swap">> := <<"append">>, <<"id">> := <<"comp-term">>,
                       <<"value">> := <<"$ ls /workspace\n">>}]} | _] = Lines,
    Term = iolist_to_binary([V || #{<<"ops">> := Ops} <- Lines,
                                  #{<<"op">> := <<"text">>, <<"id">> := <<"comp-term">>, <<"value">> := V} <- Ops]),
    ?assertEqual(<<"$ ls /workspace\n", Stdout/binary, "warn\n[退出码 0 · 成功]\n\n"/utf8>>, Term),
    %% lazy tree
    Load = act(Config, Cookie, {muse_ui_computer, load_dir, #{}},
               #{<<"type">> => <<"ah:load">>, <<"id">> => <<"comp-tree-n0">>,
                 <<"data">> => #{<<"value">> => <<"d:/workspace/notes">>, <<"tree">> => <<"comp-tree">>,
                                 <<"treeId">> => <<"0">>, <<"level">> => <<"1">>}}),
    ?assert(has(rendered(Load), <<"inner.md">>)),
    %% open, save
    Opened = act(Config, Cookie, {muse_ui_computer, open, #{}},
                 #{<<"type">> => <<"change">>, <<"value">> => <<"f:/workspace/todo.txt">>}),
    ?assert(has(rendered(Opened), <<"buy &lt;milk&gt;">>)),
    _ = act(Config, Cookie, {muse_ui_computer, save, #{path => <<"/workspace/todo.txt">>}},
            form(#{<<"text">> => <<"buy bread">>})),
    receive {write, <<"/workspace/todo.txt">>, <<"buy bread">>} -> ok after 5000 -> ct:fail(no_write) end,
    PdfPanel = act(Config, Cookie, {muse_ui_computer, open, #{}},
                   #{<<"type">> => <<"change">>, <<"value">> => <<"f:/workspace/out.pdf">>}),
    ?assert(has(rendered(PdfPanel), <<"导出到文档"/utf8>>)),
    %% mkdir, export, import
    _ = act(Config, Cookie, {muse_ui_computer, mkdir, #{}}, form(#{<<"path">> => <<"/workspace/new">>})),
    receive {mkdir, <<"/workspace/new">>} -> ok after 5000 -> ct:fail(no_mkdir) end,
    Exported = act(Config, Cookie, {muse_ui_computer, export, #{path => <<"/workspace/out.pdf">>}}, #{}),
    ?assert(has(rendered(Exported), <<"/documents/f-1">>)),
    _ = act(Config, Cookie, {muse_ui_computer, import, #{}},
            form(#{<<"path">> => <<"/workspace/a.pdf">>, <<"fileId">> => <<"file-9">>})),
    receive {import, <<"/workspace/a.pdf">>, <<"file-9">>} -> ok after 5000 -> ct:fail(no_import) end,
    %% start / stop (errors are shown)
    Started = act(Config, Cookie, {muse_ui_computer, start, #{}}, #{}),
    ?assert(has(rendered(Started), <<"电脑已启动"/utf8>>)),
    Busy = act(Config, Cookie, {muse_ui_computer, stop, #{}}, #{}),
    ?assert(has(rendered(Busy), <<"Computer is busy">>)),
    %% the documents page imports through the same API
    Documents = act(Config, Cookie, {muse_ui_documents, import, #{id => <<"file-7">>}},
                    form(#{<<"path">> => <<"/workspace/b.pdf">>})),
    ?assert(has(rendered(Documents), <<"已复制到电脑"/utf8>>)),
    receive {import, <<"/workspace/b.pdf">>, <<"file-7">>} -> ok after 5000 -> ct:fail(no_doc_import) end.

%% Browser

browser_unconfigured(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, "/browser"),
    ?assert(has(Html, <<"id=\"browser-unconfigured\"">>)),
    Ops = act(Config, Cookie, {muse_ui_browser, create, #{}}, form(#{<<"url">> => <<"https://example.com/">>})),
    ?assert(has(rendered(Ops), <<"Browser worker is not configured">>)).

browser_console(Config) ->
    Cookie = sign_in(Config),
    List = page(Config, Cookie, "/browser"),
    ?assert(has(List, <<"id=\"browser-new\"">>)),
    ?assertNot(has(List, <<"browser-unconfigured">>)),
    Invalid = act(Config, Cookie, {muse_ui_browser, create, #{}}, form(#{<<"url">> => <<"not a url">>})),
    ?assert(has(rendered(Invalid), <<"有效的网址"/utf8>>)),
    Created = act(Config, Cookie, {muse_ui_browser, create, #{}}, form(#{<<"url">> => <<"https://example.com/">>})),
    [<<"/browser/", Id/binary>>] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Created],
    ?assert(has(page(Config, Cookie, "/browser"), <<"/browser/", Id/binary>>)),
    Console = page(Config, Cookie, "/browser/" ++ binary_to_list(Id)),
    [?assert(has(Console, P), P) || P <- [<<"id=\"browser-shot\"">>, <<"data-ah-poll">>, <<":2000\"">>,
                                          <<"id=\"browser-stage\"">>, <<"tabindex=\"0\"">>,
                                          <<"data-ah-sync=\"fifo\"">>, <<"data-ah-prevent-default">>,
                                          <<"id=\"browser-type\"">>, <<"/api/browsers/", Id/binary, "/preview?owner=">>]],
    %% the poll swaps in a fresh signed screenshot URL, which serves the PNG
    Shot = act(Config, Cookie, {muse_ui_browser, shot, #{id => Id}}, #{<<"type">> => <<"poll">>}),
    [Src] = [V || #{<<"op">> := <<"attr">>, <<"id">> := <<"browser-shot">>, <<"value">> := V} <- Shot],
    ?assertMatch(<<"/api/browsers/", _/binary>>, Src),
    {200, _, <<137, "PNG", _/binary>>} = req(Config, get, binary_to_list(Src), []),
    %% click scaled to the 1280x800 viewport
    Click = act(Config, Cookie, {muse_ui_browser, click, #{id => Id}},
                #{<<"type">> => <<"click">>,
                  <<"pointer">> => #{<<"x">> => 320, <<"y">> => 100, <<"w">> => 640, <<"h">> => 400,
                                     <<"natural_w">> => 1280, <<"natural_h">> => 800}}),
    ?assert(lists:any(fun(#{<<"op">> := O}) -> O =:= <<"attr">> end, Click)),
    ?assert(called_input(Id, #{<<"type">> => <<"click">>, <<"x">> => 640, <<"y">> => 200})),
    %% keys: printable as text, special keys pressed, others ignored
    _ = act(Config, Cookie, {muse_ui_browser, key, #{id => Id}}, #{<<"type">> => <<"keydown">>, <<"key">> => <<"q">>}),
    ?assert(called_input(Id, #{<<"type">> => <<"text">>, <<"text">> => <<"q">>})),
    _ = act(Config, Cookie, {muse_ui_browser, key, #{id => Id}},
            #{<<"type">> => <<"keydown">>, <<"key">> => <<"Tab">>,
              <<"mods">> => #{<<"ctrl">> => false, <<"shift">> => true, <<"alt">> => false, <<"meta">> => false}}),
    ?assert(called_input(Id, #{<<"type">> => <<"key">>, <<"key">> => <<"Shift+Tab">>})),
    Before = length(meck:history(muse_browser)),
    [] = act(Config, Cookie, {muse_ui_browser, key, #{id => Id}}, #{<<"type">> => <<"keydown">>, <<"key">> => <<"F5">>}),
    ?assertEqual(Before, length(meck:history(muse_browser))),
    _ = act(Config, Cookie, {muse_ui_browser, press, #{id => Id, key => <<"Enter">>}}, #{<<"type">> => <<"click">>}),
    ?assert(called_input(Id, #{<<"type">> => <<"key">>, <<"key">> => <<"Enter">>})),
    _ = act(Config, Cookie, {muse_ui_browser, scroll, #{id => Id, delta => 600}}, #{<<"type">> => <<"click">>}),
    ?assert(called_input(Id, #{<<"type">> => <<"scroll">>, <<"deltaY">> => 600})),
    Typed = act(Config, Cookie, {muse_ui_browser, type, #{id => Id}}, form(#{<<"text">> => <<"hello world">>})),
    ?assert(called_input(Id, #{<<"type">> => <<"text">>, <<"text">> => <<"hello world">>})),
    %% the field is cleared after sending
    ?assert(lists:any(fun(Op) -> maps:get(<<"id">>, Op, undefined) =:= <<"browser-text-input">> end, Typed)),
    %% read, navigate, imports
    Read = act(Config, Cookie, {muse_ui_browser, read, #{id => Id}}, #{<<"type">> => <<"click">>}),
    ?assert(has(rendered(Read), <<"browser-page-text">>)),
    ?assert(has(rendered(Read), <<"xxxxxxxx">>)),
    Nav = act(Config, Cookie, {muse_ui_browser, navigate, #{id => Id}}, form(#{<<"url">> => <<"https://example.org/fail">>})),
    ?assert(has(rendered(Nav), <<"The page could not be loaded.">>)),
    Imports = act(Config, Cookie, {muse_ui_browser, imports, #{id => Id}}, #{<<"type">> => <<"click">>}),
    ?assert(has(rendered(Imports), <<"slip.pdf">>)),
    ?assert(lists:any(fun(#{<<"name">> := N}) -> N =:= <<"slip.pdf">> end, muse_files:list(?OWNER))),
    %% a session that is not the owner's: no screenshot, an error
    Other = muse_ids:uuid(),
    NotMine = act(Config, Cookie, {muse_ui_browser, shot, #{id => Other}}, #{<<"type">> => <<"poll">>}),
    ?assertEqual([], [O || O = #{<<"op">> := <<"attr">>} <- NotMine]),
    ?assert(has(rendered(NotMine), <<"Browser session not found">>)),
    ?assert(has(page(Config, Cookie, "/browser/" ++ binary_to_list(Other)), <<"找不到该会话"/utf8>>)),
    %% close
    Closed = act(Config, Cookie, {muse_ui_browser, close, #{id => Id}}, #{<<"type">> => <<"click">>}),
    [<<"/browser">>] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Closed],
    {ok, #{<<"status">> := <<"closed">>}} = muse_browser:get(?OWNER, Id).

called_input(Id, Input) ->
    lists:member({?OWNER, Id, Input}, [list_to_tuple(Args) || {_, {muse_browser, input, Args}, _} <- meck:history(muse_browser)]).

browser_input_mapping(_Config) ->
    %% displayed 640x400 image of a 1280x800 screenshot
    ?assertEqual({640, 200}, muse_ui_browser:scale(#{<<"x">> => 320, <<"y">> => 100, <<"w">> => 640, <<"h">> => 400,
                                                     <<"natural_w">> => 1280, <<"natural_h">> => 800})),
    %% no natural size reported: the displayed size
    ?assertEqual({640, 200}, muse_ui_browser:scale(#{<<"x">> => 320, <<"y">> => 100, <<"w">> => 640, <<"h">> => 400})),
    %% clamped into the viewport
    ?assertEqual({1279, 799}, muse_ui_browser:scale(#{<<"x">> => 640, <<"y">> => 400, <<"w">> => 640, <<"h">> => 400})),
    ?assertEqual({0, 0}, muse_ui_browser:scale(#{<<"x">> => -3, <<"y">> => -1, <<"w">> => 640, <<"h">> => 400})),
    ?assertEqual(undefined, muse_ui_browser:scale(null)),
    ?assertEqual(undefined, muse_ui_browser:scale(#{<<"x">> => 1, <<"y">> => 1, <<"w">> => 0, <<"h">> => 0})),
    Mods = fun(K) -> maps:put(K, true, #{<<"ctrl">> => false, <<"shift">> => false, <<"alt">> => false,
                                         <<"meta">> => false}) end,
    ?assertEqual(#{<<"type">> => <<"text">>, <<"text">> => <<" ">>}, muse_ui_browser:key_input(<<" ">>, null)),
    ?assertEqual(#{<<"type">> => <<"text">>, <<"text">> => <<"é"/utf8>>}, muse_ui_browser:key_input(<<"é"/utf8>>, null)),
    ?assertEqual(#{<<"type">> => <<"key">>, <<"key">> => <<"Backspace">>}, muse_ui_browser:key_input(<<"Backspace">>, null)),
    ?assertEqual(#{<<"type">> => <<"key">>, <<"key">> => <<"ArrowLeft">>}, muse_ui_browser:key_input(<<"ArrowLeft">>, null)),
    ?assertEqual(#{<<"type">> => <<"key">>, <<"key">> => <<"Control+a">>}, muse_ui_browser:key_input(<<"a">>, Mods(<<"ctrl">>))),
    ?assertEqual(#{<<"type">> => <<"key">>, <<"key">> => <<"Meta+a">>}, muse_ui_browser:key_input(<<"a">>, Mods(<<"meta">>))),
    ?assertEqual(undefined, muse_ui_browser:key_input(<<"c">>, Mods(<<"ctrl">>))),
    ?assertEqual(undefined, muse_ui_browser:key_input(<<"Shift">>, Mods(<<"shift">>))),
    ?assertEqual(#{<<"type">> => <<"text">>, <<"text">> => <<"A">>}, muse_ui_browser:key_input(<<"A">>, Mods(<<"shift">>))),
    ?assertEqual(undefined, muse_ui_browser:key_input(null, null)).

%% Apps

apps_sample(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, "/apps"),
    [?assert(has(Html, P), P) || P <- [<<"Gmail">>, <<"Google 日历"/utf8>>, <<"示例数据"/utf8>>,
                                       <<"id=\"apps-disconnect\"">>, <<"alex@example.com">>]],
    ?assert(muse_workspace:connected(?OWNER)),
    Off = act(Config, Cookie, {muse_ui_apps, disconnect, #{}}, #{<<"type">> => <<"click">>}),
    ?assertNot(muse_workspace:connected(?OWNER)),
    ?assert(has(rendered(Off), <<"未连接"/utf8>>)),
    ?assertNot(has(rendered(Off), <<"apps-disconnect">>)),
    On = act(Config, Cookie, {muse_ui_apps, connect, #{capability => read}}, #{<<"type">> => <<"click">>}),
    ?assert(muse_workspace:connected(?OWNER)),
    ?assert(has(rendered(On), <<"示例数据"/utf8>>)).

apps_live(Config) ->
    Cookie = sign_in(Config, [{"accessKey", binary_to_list(binary:copy(<<"k">>, 24))}]),
    Html = page(Config, Cookie, "/apps"),
    ?assert(has(Html, <<"未连接"/utf8>>)),
    ?assertNot(has(Html, <<"apps-disconnect">>)),
    Write = act(Config, Cookie, {muse_ui_apps, connect, #{capability => write}}, #{<<"type">> => <<"click">>}),
    [Url] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Write],
    ?assertMatch(<<"https://accounts.google.com/", _/binary>>, Url),
    ?assert(has(Url, <<"gmail.send">>)),
    Read = act(Config, Cookie, {muse_ui_apps, connect, #{capability => read}}, #{<<"type">> => <<"click">>}),
    [ReadUrl] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Read],
    ?assert(has(ReadUrl, <<"gmail.readonly">>)),
    ?assertNot(has(ReadUrl, <<"gmail.send">>)),
    %% disconnecting with nothing stored is fine
    Off = act(Config, Cookie, {muse_ui_apps, disconnect, #{}}, #{<<"type">> => <<"click">>}),
    ?assert(has(rendered(Off), <<"Google 已断开"/utf8>>)).

%% Every action needs the session cookie (muse_ui:authorize/1).
actions_need_session(Config) ->
    Cookie = sign_in(Config),
    lists:foreach(
      fun(Ref) ->
              {401, _} = act_raw(Config, [], Ref, #{}),
              {401, _} = act_raw(Config, cookie("nope"), Ref, #{})
      end,
      [{muse_ui_settings, add_memory, #{}}, {muse_ui_documents, refresh, #{}}, {muse_ui_computer, start, #{}},
       {muse_ui_browser, shot, #{id => muse_ids:uuid()}}, {muse_ui_apps, disconnect, #{}}]),
    %% pages render for the session
    [?assert(has(page(Config, Cookie, P), <<"id=\"muse-shell\"">>), P)
     || P <- ["/documents", "/computer", "/browser", "/apps", "/settings"]].
