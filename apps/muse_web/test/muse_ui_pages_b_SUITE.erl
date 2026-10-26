%% UI pages of M6-5 and M6-6 (tasks/M6-ui.md): documents, computer,
%% browser and settings. Each page is rendered with the session
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
    [settings_page, documents_page, documents_manager, documents_previews, computer_unconfigured, computer_page, browser_unconfigured,
     browser_console, browser_input_mapping, no_apps_page, actions_need_session].

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
    ?assertNot(has(Html, <<"settings-apps">>)),
    [?assert(has(Html, P), P) || P <- [<<"id=\"settings-identity\"">>,
                                       <<"action=\"/logout\"">>, <<"id=\"settings-memories\"">>,
                                       <<"data-ah-subscribe">>, <<"BeamAI Muse">>]],
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
                                       <<"id=\"doc-list\"">>, <<"data-ah-subscribe">>, <<"id=\"doc-sync\"">>,
                                       <<"id=\"doc-q\"">>, <<"id=\"doc-type\"">>, <<"id=\"doc-time\"">>,
                                       <<"id=\"doc-view\"">>, <<"id=\"doc-starred-filter\"">>,
                                       <<"id=\"doc-crumbs\"">>, <<"id=\"doc-new-folder\"">>,
                                       <<"id=\"doc-upload-win\"">>, <<"上传文件"/utf8>>, <<"新建文件夹"/utf8>>]],
    {ok, Pdf} = muse_pdf:sample(),
    Name = <<"Field trip slip.pdf">>,
    %% upload: session and origin required, then /api/files' rules
    {401, _, _} = req(Config, post, "/upload", same_origin(Config), multipart(Name, Pdf)),
    {403, _, _} = req(Config, post, "/upload", cookie(Cookie) ++ [{"sec-fetch-site", "cross-site"}],
                      multipart(Name, Pdf)),
    {405, _, _} = req(Config, get, "/upload", cookie(Cookie)),
    {400, _, NotPdf} = req(Config, post, "/upload", cookie(Cookie) ++ same_origin(Config),
                           {"application/json", <<"{}">>}),
    ?assert(has(NotPdf, <<"Choose a file">>)),
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
    %% detail: signed iframe preview, fields
    Detail = page(Config, Cookie, "/documents/" ++ binary_to_list(Id)),
    {match, [Src]} = re:run(Detail, <<"<iframe[^>]*src=\"([^\"]+)\"">>, [{capture, all_but_first, binary}]),
    Path = binary:replace(Src, <<"&amp;">>, <<"&">>, [global]),
    ?assertMatch(<<"/api/files/", _/binary>>, Path),
    {200, ContentHeaders, Pdf} = req(Config, get, binary_to_list(Path), []),
    ?assertEqual("application/pdf", proplists:get_value("content-type", ContentHeaders)),
    ?assert(has(Detail, <<"id=\"doc-fill\"">>)),
    ?assertNot(has(Detail, <<"id=\"doc-import\"">>)),
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
    %% another owner's / unknown document
    Unknown = page(Config, Cookie, "/documents/" ++ binary_to_list(muse_ids:uuid())),
    ?assert(has(Unknown, <<"找不到该文件"/utf8>>)),
    BadFill = act(Config, Cookie, {muse_ui_documents, fill, #{id => muse_ids:uuid()}}, form(#{})),
    ?assert(has(rendered(BadFill), <<"File not found">>)).

multipart(Name, Bytes) ->
    multipart(Name, Bytes, []).

multipart(Name, Bytes, Fields) ->
    B = <<?BOUNDARY>>,
    Body = iolist_to_binary([[[<<"--", B/binary, "\r\n">>,
                               <<"Content-Disposition: form-data; name=\"", K/binary, "\"\r\n\r\n">>, V, <<"\r\n">>]
                              || {K, V} <- Fields],
                             <<"--", B/binary, "\r\n">>,
                             <<"Content-Disposition: form-data; name=\"file\"; filename=\"", Name/binary, "\"\r\n"
                               "Content-Type: application/pdf\r\n\r\n">>, Bytes, <<"\r\n">>,
                             <<"--", B/binary, "--\r\n">>]),
    {"multipart/form-data; boundary=" ?BOUNDARY, Body}.

%% The file manager (M9-6): folders, upload into a folder, filters and
%% search, views, star, rename, move, delete.

values(Extra) ->
    maps:merge(#{<<"doc-q">> => <<>>, <<"doc-type">> => <<"all">>, <<"doc-time">> => <<"all">>,
                 <<"doc-view">> => <<"grid">>, <<"doc-starred">> => <<"0">>}, Extra).

click(Extra) -> #{<<"type">> => <<"click">>, <<"values">> => values(Extra)}.

submit(Form) -> #{<<"type">> => <<"submit">>, <<"form">> => Form, <<"values">> => values(#{})}.

ids_in(Bin) ->
    {match, Ms} = re:run(Bin, <<"id=\"doc-([0-9a-f-]{36})\"">>, [global, {capture, all_but_first, binary}]),
    lists:usort(lists:append(Ms)).

documents_manager(Config) ->
    Cookie = sign_in(Config),
    Up = fun(Name, Bytes, Fields) ->
                 {201, _, Body} = req(Config, post, "/upload", cookie(Cookie) ++ same_origin(Config),
                                      multipart(Name, Bytes, Fields)),
                 {ok, J} = muse_json:decode(Body),
                 J
         end,
    %% a folder from the dialog
    Created = act(Config, Cookie, {muse_ui_documents, create_folder, #{parent => null}},
                  submit(#{<<"name">> => <<"项目"/utf8>>})),
    ?assert(has(rendered(Created), <<"已新建文件夹"/utf8>>)),
    [#{<<"id">> := Proj}] = muse_files:folders(?OWNER),
    ?assert(has(rendered(Created), <<"doc-folder-", Proj/binary>>)),
    Dup = act(Config, Cookie, {muse_ui_documents, create_folder, #{parent => null}},
              submit(#{<<"name">> => <<"项目"/utf8>>})),
    ?assert(has(rendered(Dup), <<"already exists">>)),
    %% uploads of any type, one into the folder
    Png = <<137, "PNG\r\n", 26, "\n", 0, 0, 0, 13, "IHDR">>,
    #{<<"id">> := Cat, <<"kind">> := <<"image">>, <<"folderId">> := Proj} =
        Up(<<"cat.png">>, Png, [{<<"folder">>, Proj}]),
    #{<<"id">> := Notes, <<"kind">> := <<"text">>, <<"folderId">> := null} = Up(<<"notes.txt">>, <<"todo">>, []),
    #{<<"id">> := Song, <<"kind">> := <<"audio">>} = Up(<<"song.mp3">>, <<"ID3", 3, 0>>, []),
    %% the folder page: breadcrumbs, the upload carries the folder
    FolderHtml = page(Config, Cookie, "/documents?folder=" ++ binary_to_list(Proj)),
    [?assert(has(FolderHtml, P), P) || P <- [<<"项目"/utf8>>, <<"doc-", Cat/binary>>, <<"data-ah-extra">>, Proj]],
    ?assertNot(has(FolderHtml, <<"doc-", Notes/binary>>)),
    ?assert(has(page(Config, Cookie, "/documents?folder=" ++ binary_to_list(muse_ids:uuid())),
                <<"找不到该文件夹"/utf8>>)),
    %% the root: the folder card with its count, root files only
    Root = page(Config, Cookie, "/documents"),
    ?assert(has(Root, <<"doc-folder-", Proj/binary>>)),
    ?assert(has(Root, <<"1 个文件"/utf8>>)),
    Sample = [I || #{<<"id">> := I} <- muse_files:list(?OWNER, unsigned), not lists:member(I, [Cat, Notes, Song])],
    ?assertEqual(lists:sort([Notes, Song | Sample]), ids_in(Root) -- [Proj]),
    ?assert(has(Root, <<"data-ah-confirm">>)),
    ?assert(has(Root, <<"danger">>)),
    %% grid/list toggle
    Filter = {muse_ui_documents, filter, #{folder => null, set => #{view => list}}},
    ListOps = act(Config, Cookie, Filter, click(#{})),
    ?assert(has(rendered(ListOps), <<"id=\"doc-table\"">>)),
    ?assert(has(rendered(ListOps), <<"value=\"list\"">>)),
    GridOps = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null}}, click(#{})),
    ?assert(has(rendered(GridOps), <<"id=\"doc-grid\"">>)),
    ?assertNot(has(rendered(GridOps), <<"id=\"doc-table\"">>)),
    ListAgain = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null}}, click(#{<<"doc-view">> => <<"list">>})),
    ?assert(has(rendered(ListAgain), <<"id=\"doc-table\"">>)),
    %% search covers every folder and shows where each result is
    Search = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null}}, click(#{<<"doc-q">> => <<"CAT">>})),
    ?assertEqual([Cat], ids_in(rendered(Search))),
    ?assert(has(rendered(Search), <<"muse-file-where">>)),
    ?assert(has(rendered(Search), <<"搜索结果"/utf8>>)),
    None = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null}}, click(#{<<"doc-q">> => <<"zzz">>})),
    ?assert(has(rendered(None), <<"没有匹配的文件"/utf8>>)),
    %% type and time filters
    Audio = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null}}, click(#{<<"doc-type">> => <<"audio">>})),
    ?assertEqual([Song], ids_in(rendered(Audio)) -- [Proj]),
    Today = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null}}, click(#{<<"doc-time">> => <<"today">>})),
    ?assertEqual(lists:sort([Notes, Song | Sample]), ids_in(rendered(Today)) -- [Proj]),
    _ = muse_store:update(?OWNER, <<"files">>, Song,
                          fun(F) -> {ok, F#{<<"updatedAt">> => <<"2020-01-01T00:00:00.000Z">>}} end),
    Week = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null}}, click(#{<<"doc-time">> => <<"week">>})),
    ?assertEqual(lists:sort([Notes | Sample]), ids_in(rendered(Week)) -- [Proj]),
    %% star, and the starred quick filter (every folder)
    Star = act(Config, Cookie, {muse_ui_documents, star, #{id => Cat, starred => true, from => {list, null}}}, click(#{})),
    ?assert(has(rendered(Star), <<"muse-star muse-on">>) orelse has(rendered(Star), <<"★"/utf8>>)),
    {ok, #{<<"starred">> := true}} = muse_files:get(?OWNER, Cat),
    Starred = act(Config, Cookie, {muse_ui_documents, filter, #{folder => null, set => #{starred => true}}}, click(#{})),
    ?assertEqual([Cat], ids_in(rendered(Starred))),
    ?assert(has(rendered(Starred), <<"value=\"1\"">>)),
    %% rename (a dialog), move, errors stay in the dialog
    Ask = act(Config, Cookie, {muse_ui_documents, ask_rename, #{type => file, id => Notes, from => {list, null}}}, click(#{})),
    ?assert(has(rendered(Ask), <<"doc-rename-form">>)),
    ?assert(has(rendered(Ask), <<"notes.txt">>)),
    Renamed = act(Config, Cookie, {muse_ui_documents, rename, #{type => file, id => Notes, from => {list, null}}},
                  submit(#{<<"name">> => <<"plan.txt">>})),
    ?assert(has(rendered(Renamed), <<"plan.txt">>)),
    {ok, #{<<"name">> := <<"plan.txt">>}} = muse_files:get(?OWNER, Notes),
    Blank = act(Config, Cookie, {muse_ui_documents, rename, #{type => file, id => Notes, from => {list, null}}},
                submit(#{<<"name">> => <<"  ">>})),
    ?assert(has(rendered(Blank), <<"Enter a file name">>)),
    _ = act(Config, Cookie, {muse_ui_documents, rename, #{type => folder, id => Proj, from => {list, null}}},
            submit(#{<<"name">> => <<"Projects">>})),
    {ok, #{<<"name">> := <<"Projects">>}} = muse_files:folder(?OWNER, Proj),
    AskMove = act(Config, Cookie, {muse_ui_documents, ask_move, #{id => Notes, from => {list, null}}}, click(#{})),
    ?assert(has(rendered(AskMove), <<"doc-move-form">>)),
    ?assert(has(rendered(AskMove), <<"全部文件 / Projects"/utf8>>)),
    _ = act(Config, Cookie, {muse_ui_documents, move, #{id => Notes, from => {list, null}}},
            submit(#{<<"folder">> => Proj})),
    {ok, #{<<"folderId">> := Proj}} = muse_files:get(?OWNER, Notes),
    _ = act(Config, Cookie, {muse_ui_documents, move, #{id => Notes, from => {list, Proj}}},
            submit(#{<<"folder">> => <<"root">>})),
    {ok, #{<<"folderId">> := null}} = muse_files:get(?OWNER, Notes),
    %% download goes to a fresh signed URL
    Dl = act(Config, Cookie, {muse_ui_documents, download, #{id => Cat}}, click(#{})),
    [Url] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Dl],
    {200, DlHeaders, Png} = req(Config, get, binary_to_list(Url), []),
    ?assertMatch("attachment;" ++ _, proplists:get_value("content-disposition", DlHeaders)),
    %% delete a file, then the folder with its contents
    Del = act(Config, Cookie, {muse_ui_documents, delete, #{id => Song, from => {list, null}}}, click(#{})),
    ?assert(has(rendered(Del), <<"已删除"/utf8>>)),
    {error, {404, _}} = muse_files:get(?OWNER, Song),
    DelFolder = act(Config, Cookie, {muse_ui_documents, delete_folder, #{id => Proj, from => {list, null}}}, click(#{})),
    ?assert(has(rendered(DelFolder), <<"已删除文件夹"/utf8>>)),
    {error, {404, _}} = muse_files:get(?OWNER, Cat),
    [] = muse_files:folders(?OWNER),
    %% the other tabs are told; a refresh re-renders with the tab's state
    Refresh = act(Config, Cookie, {muse_ui_documents, refresh, #{folder => null}}, click(#{<<"doc-view">> => <<"list">>})),
    ?assert(has(rendered(Refresh), <<"id=\"doc-table\"">>)),
    Gone = act(Config, Cookie, {muse_ui_documents, refresh, #{folder => Proj}}, click(#{})),
    ?assert(has(rendered(Gone), <<"这个文件夹已被删除"/utf8>>)).

%% A file's page by kind, and a PDF record from before M9-6.
documents_previews(Config) ->
    Cookie = sign_in(Config),
    Up = fun(Name, Bytes) ->
                 {201, _, Body} = req(Config, post, "/upload", cookie(Cookie) ++ same_origin(Config),
                                      multipart(Name, Bytes)),
                 {ok, #{<<"id">> := Id}} = muse_json:decode(Body),
                 Id
         end,
    Detail = fun(Id) -> page(Config, Cookie, "/documents/" ++ binary_to_list(Id)) end,
    Png = Up(<<"cat.png">>, <<137, "PNG\r\n", 26, "\n", 0, 0, 0, 13, "IHDR">>),
    ImgHtml = Detail(Png),
    ?assertMatch({match, _}, re:run(ImgHtml, <<"<img[^>]*id=\"doc-image\"[^>]*src=\"/api/files/">>)),
    [?assert(has(ImgHtml, P), P) || P <- [<<"doc-crumbs">>, <<"doc-star-", Png/binary>>, <<"下载"/utf8>>,
                                          <<"重命名"/utf8>>, <<"移动"/utf8>>, <<"删除"/utf8>>, <<"doc-sync">>]],
    ?assertNot(has(ImgHtml, <<"doc-fill">>)),
    ?assert(has(Detail(Up(<<"song.mp3">>, <<"ID3", 3, 0>>)), <<"<audio">>)),
    ?assert(has(Detail(Up(<<"clip.webm">>, <<16#1A, 16#45, 16#DF, 16#A3, 0>>)), <<"<video">>)),
    TextHtml = Detail(Up(<<"notes.txt">>, <<"line one <b>not bold</b>\n">>)),
    ?assert(has(TextHtml, <<"<pre">>)),
    ?assert(has(TextHtml, <<"&lt;b&gt;not bold">>)),
    Zip = Up(<<"a.zip">>, <<"PK", 3, 4, 0, 0>>),
    ZipHtml = Detail(Zip),
    ?assert(has(ZipHtml, <<"无法在这里预览"/utf8>>)),
    ?assert(has(ZipHtml, <<"doc-download">>)),
    ?assertNot(has(ZipHtml, <<"<iframe">>)),
    %% star and delete from the file's page
    _ = act(Config, Cookie, {muse_ui_documents, star, #{id => Zip, starred => true, from => {detail, Zip}}}, click(#{})),
    {ok, #{<<"starred">> := true}} = muse_files:get(?OWNER, Zip),
    Del = act(Config, Cookie, {muse_ui_documents, delete, #{id => Zip, from => {detail, Zip}}}, click(#{})),
    [<<"/documents">>] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Del],
    %% an old PDF record (no kind, folderId, starred) still lists, previews and fills
    {ok, Pdf} = muse_pdf:sample(),
    Old = muse_ids:uuid(),
    ok = muse_blob:put(<<"pdf/", Old/binary>>, Pdf),
    {ok, #{<<"pageCount">> := Pages, <<"fields">> := Fields}} = muse_pdf:inspect(Pdf),
    _ = muse_store:put(?OWNER, <<"files">>,
                       #{<<"id">> => Old, <<"name">> => <<"Legacy.pdf">>, <<"mimeType">> => <<"application/pdf">>,
                         <<"size">> => byte_size(Pdf), <<"pageCount">> => Pages, <<"fields">> => Fields,
                         <<"url">> => <<>>, <<"createdAt">> => <<"2026-01-02T03:04:05.000Z">>,
                         <<"source">> => <<"Uploaded by you">>}),
    ?assert(has(page(Config, Cookie, "/documents"), <<"doc-", Old/binary>>)),
    OldHtml = Detail(Old),
    ?assert(has(OldHtml, <<"<iframe">>)),
    ?assert(has(OldHtml, <<"id=\"doc-fill\"">>)),
    {match, [Src]} = re:run(OldHtml, <<"<iframe[^>]*src=\"([^\"]+)\"">>, [{capture, all_but_first, binary}]),
    {200, _, Pdf} = req(Config, get, binary_to_list(binary:replace(Src, <<"&amp;">>, <<"&">>, [global])), []).

%% Computer

computer_unconfigured(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, "/computer"),
    ?assert(has(Html, <<"id=\"comp-unconfigured\"">>)),
    ?assert(has(Html, <<"电脑未配置"/utf8>>)),
    %% there is no default computer: its old address is not found
    ?assert(has(page(Config, Cookie, "/computer/" ++ binary_to_list(muse_computers:legacy_id(?OWNER))),
                <<"找不到该电脑"/utf8>>)),
    ?assertEqual([], muse_computers:list(?OWNER)),
    %% a conversation's computer shows the unconfigured state
    {_, Id} = muse_computer:ensure(?OWNER, <<"thread:t-1">>),
    ?assert(has(page(Config, Cookie, "/computer/" ++ binary_to_list(Id)), <<"id=\"comp-unconfigured\"">>)).

%% `/computer/<id>`: watch and manage only. Status with start/stop, files
%% to download (PDFs also into Files) and upload, the agent's commands.
computer_page(Config) ->
    Cookie = sign_in(Config),
    Tid = muse_ids:uuid(),
    {ok, _} = muse_threads:create(?OWNER, Tid, <<"整理照片"/utf8>>),
    {?OWNER, Id} = Ref = muse_computer:ensure(?OWNER, <<"thread:", Tid/binary>>),
    Stdout = <<"total 0\n<dir>\n">>,
    Running = #{<<"enabled">> => true, <<"provider">> => <<"docker">>, <<"workspacePath">> => <<"/workspace">>,
                <<"network">> => <<"disabled">>, <<"status">> => <<"running">>,
                <<"commands">> => [#{<<"id">> => <<"c1">>, <<"command">> => <<"ls -la /workspace">>,
                                     <<"status">> => <<"succeeded">>, <<"exitCode">> => 0,
                                     <<"stdout">> => Stdout, <<"stderr">> => <<>>,
                                     <<"startedAt">> => muse_time:now_iso()}]},
    Self = self(),
    meck:expect(muse_computer, snapshot, fun(R) when R =:= Ref -> Running end),
    meck:expect(muse_computer, list,
                fun(R) when R =:= Ref ->
                        {ok, #{<<"path">> => <<"/workspace">>,
                               <<"entries">> => [#{<<"name">> => <<"notes">>, <<"path">> => <<"/workspace/notes">>,
                                                   <<"type">> => <<"directory">>, <<"size">> => 4096},
                                                 #{<<"name">> => <<"todo.txt">>, <<"path">> => <<"/workspace/todo.txt">>,
                                                   <<"type">> => <<"file">>, <<"size">> => 5}]}}
                end),
    meck:expect(muse_computer, list,
                fun(R, <<"/workspace/notes">> = P) when R =:= Ref ->
                        {ok, #{<<"path">> => P,
                               <<"entries">> => [#{<<"name">> => <<"inner.md">>, <<"path">> => <<P/binary, "/inner.md">>,
                                                   <<"type">> => <<"file">>, <<"size">> => 3}]}}
                end),
    meck:expect(muse_computer, start, fun(R) when R =:= Ref -> {ok, Running} end),
    meck:expect(muse_computer, stop, fun(_) -> {error, {409, <<"Computer is busy. Wait for the current operation to finish.">>}} end),
    meck:expect(muse_computer, export_pdf,
                fun(R, <<"/workspace/out.pdf">>) when R =:= Ref -> {ok, #{<<"id">> => <<"f-1">>, <<"name">> => <<"out.pdf">>}} end),
    meck:expect(muse_computer, download,
                fun(R, <<"/workspace/照片 1.jpg"/utf8>>) when R =:= Ref -> {ok, #{name => <<"照片 1.jpg"/utf8>>, bytes => <<"JPEG">>}};
                   (_, _) -> {error, {422, <<"Computer file operation failed.">>}}
                end),
    meck:expect(muse_computer, upload, fun(R, P, B) when R =:= Ref -> Self ! {upload, P, B}, {ok, #{<<"path">> => P}} end),
    Html = page(Config, Cookie, "/computer/" ++ binary_to_list(Id)),
    [?assert(has(Html, P), P) || P <- [<<"id=\"comp-tree\"">>, <<"todo.txt">>, <<"notes">>, <<"运行中"/utf8>>,
                                       <<"整理照片"/utf8>>, <<"/chat/", Tid/binary>>, <<"id=\"comp-upload\"">>,
                                       <<"/computer-files/", Id/binary, "/upload?dir=%2Fworkspace">>,
                                       <<"命令记录"/utf8>>, <<"ls -la /workspace">>, <<"&lt;dir&gt;">>, <<"退出码 0"/utf8>>]],
    %% no terminal, editor or folder form
    [?assertNot(has(Html, P), P) || P <- [<<"comp-term">>, <<"comp-run">>, <<"comp-mkdir">>, <<"comp-import">>,
                                          <<"comp-edit">>]],
    A = #{id => Id},
    %% lazy tree
    Load = act(Config, Cookie, {muse_ui_computer, load_dir, A},
               #{<<"type">> => <<"ah:load">>, <<"id">> => <<"comp-tree-n0">>,
                 <<"data">> => #{<<"value">> => <<"d:/workspace/notes">>, <<"tree">> => <<"comp-tree">>,
                                 <<"treeId">> => <<"0">>, <<"level">> => <<"1">>}}),
    ?assert(has(rendered(Load), <<"inner.md">>)),
    %% a file: download link; a PDF: also the copy into Files
    Opened = rendered(act(Config, Cookie, {muse_ui_computer, open, A},
                          #{<<"type">> => <<"change">>, <<"value">> => <<"f:/workspace/todo.txt">>})),
    ?assert(has(Opened, <<"/computer-files/", Id/binary, "/download?path=%2Fworkspace%2Ftodo.txt">>)),
    ?assertNot(has(Opened, <<"存到「文件」"/utf8>>)),
    PdfPanel = rendered(act(Config, Cookie, {muse_ui_computer, open, A},
                            #{<<"type">> => <<"change">>, <<"value">> => <<"f:/workspace/out.pdf">>})),
    ?assert(has(PdfPanel, <<"存到「文件」"/utf8>>)),
    Exported = act(Config, Cookie, {muse_ui_computer, export, A#{path => <<"/workspace/out.pdf">>}}, #{}),
    ?assert(has(rendered(Exported), <<"/documents/f-1">>)),
    %% download and upload over the session cookie
    Base = "/computer-files/" ++ binary_to_list(Id),
    {200, DH, <<"JPEG">>} = req(Config, get, Base ++ "/download?path=%2Fworkspace%2F%E7%85%A7%E7%89%87%201.jpg",
                                cookie(Cookie)),
    ?assertEqual("attachment; filename*=UTF-8''%E7%85%A7%E7%89%87%201.jpg",
                 proplists:get_value("content-disposition", DH)),
    {422, _, _} = req(Config, get, Base ++ "/download?path=%2Fetc%2Fpasswd", cookie(Cookie)),
    {401, _, _} = req(Config, get, Base ++ "/download?path=%2Fworkspace%2Fa", []),
    {404, _, _} = req(Config, get, "/computer-files/0123456789abcdef/download?path=%2Fworkspace%2Fa", cookie(Cookie)),
    Boundary = "muse-comp-boundary",
    Multipart = iolist_to_binary(["--", Boundary, "\r\n",
                                  "Content-Disposition: form-data; name=\"file\"; filename=\"../a b.bin\"\r\n",
                                  "Content-Type: application/octet-stream\r\n\r\n", <<0, 1, 2>>, "\r\n",
                                  "--", Boundary, "--\r\n"]),
    {201, _, UpBody} = req(Config, post, Base ++ "/upload?dir=%2Fworkspace%2Fnotes%2F",
                           cookie(Cookie) ++ same_origin(Config),
                           {"multipart/form-data; boundary=" ++ Boundary, Multipart}),
    ?assertMatch({ok, #{<<"path">> := <<"/workspace/notes/a b.bin">>}}, muse_json:decode(UpBody)),
    receive {upload, <<"/workspace/notes/a b.bin">>, <<0, 1, 2>>} -> ok after 5000 -> ct:fail(no_upload) end,
    {400, _, _} = req(Config, post, Base ++ "/upload", cookie(Cookie) ++ same_origin(Config),
                      {"application/json", <<"{}">>}),
    Uploaded = act(Config, Cookie, {muse_ui_computer, uploaded, A},
                   #{<<"type">> => <<"change">>,
                     <<"value">> => muse_json:encode([#{<<"name">> => <<"a b.bin">>,
                                                        <<"path">> => <<"/workspace/a b.bin">>}])}),
    ?assert(has(rendered(Uploaded), <<"已上传到 /workspace"/utf8>>)),
    %% start / stop (errors are shown)
    Started = act(Config, Cookie, {muse_ui_computer, start, A}, #{}),
    ?assert(has(rendered(Started), <<"电脑已启动"/utf8>>)),
    Busy = act(Config, Cookie, {muse_ui_computer, stop, A}, #{}),
    ?assert(has(rendered(Busy), <<"Computer is busy">>)),
    %% an action without a computer of the owner
    Gone = act(Config, Cookie, {muse_ui_computer, start, #{}}, #{}),
    ?assert(has(rendered(Gone), <<"找不到该电脑"/utf8>>)).

%% Browser

browser_unconfigured(Config) ->
    Cookie = sign_in(Config),
    Html = page(Config, Cookie, "/browser"),
    ?assert(has(Html, <<"id=\"browser-unconfigured\"">>)),
    ?assert(has(Html, <<"id=\"browser-none\"">>)),
    %% no request_takeover without a worker
    ?assertEqual([], [N || #{name := N} <- muse_chat_agent:tools(?OWNER, <<"t">>, <<"r">>, <<"t:m">>, undefined),
                           N =:= <<"request_takeover">> orelse N =:= <<"browse_web">>]).

browser_console(Config) ->
    Cookie = sign_in(Config),
    %% no browser page of its own (M9-5): /browser says sessions open from
    %% conversations, and the sidebar has no browser link
    None = page(Config, Cookie, "/browser"),
    [?assert(has(None, P), P) || P <- [<<"id=\"browser-none\"">>, <<"浏览器在对话里打开"/utf8>>, <<"href=\"/chat\"">>]],
    [?assertNot(has(None, P), P) || P <- [<<"browser-new">>, <<"browser-sessions">>, <<"browser-unconfigured">>,
                                          <<"href=\"/browser\"">>]],
    {ok, #{<<"id">> := Id}} = muse_browser:create(?OWNER, <<"https://www.example.com/">>),
    Console = page(Config, Cookie, "/browser/" ++ binary_to_list(Id)),
    [?assert(has(Console, P), P) || P <- [<<"处理浏览器 · example.com"/utf8>>, <<"id=\"browser-hint\"">>,
                                          <<"完成后回到对话点「处理好了，继续」"/utf8>>]],
    %% not a conversation's session: no way back to one, and no session list
    ?assertNot(has(Console, <<"browser-back">>)),
    ?assertNot(has(Console, <<"全部会话"/utf8>>)),
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
    %% close: back to the chat
    Closed = act(Config, Cookie, {muse_ui_browser, close, #{id => Id}}, #{<<"type">> => <<"click">>}),
    [<<"/chat">>] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Closed],
    {ok, #{<<"status">> := <<"closed">>}} = muse_browser:get(?OWNER, Id),
    takeover_tool(Config, Cookie).

%% request_takeover opens the conversation's browser and returns at once;
%% the console leads back to the conversation.
takeover_tool(Config, Cookie) ->
    Tid = muse_ids:uuid(),
    {ok, _} = muse_threads:create(?OWNER, Tid, <<"Book a table">>),
    Tools = muse_chat_agent:tools(?OWNER, Tid, <<"r">>, <<Tid/binary, ":m">>, undefined),
    [#{description := Browse}] = [T || T = #{name := <<"browse_web">>} <- Tools],
    ?assertNotEqual(nomatch, binary:match(Browse, <<"call request_takeover">>)),
    [#{handler := Takeover, parameters := Params}] = [T || T = #{name := <<"request_takeover">>} <- Tools],
    [#{handler := ReadCurrent}] = [T || T = #{name := <<"read_current_page">>} <- Tools],
    ?assertMatch(#{<<"reason">> := #{required := true}, <<"kind">> := #{enum := [_, _, _, _]},
                   <<"url">> := #{required := false}}, Params),
    Ctx = beamai_context:new(),
    %% a conversation that never browsed needs a url
    {ok, #{<<"error">> := _}} = Takeover(#{<<"reason">> => <<"Sign in">>, <<"kind">> => <<"login">>}, Ctx),
    {ok, #{<<"error">> := _}} = ReadCurrent(#{}, Ctx),
    {ok, #{<<"error">> := _}} = Takeover(#{<<"reason">> => binary:copy(<<"x">>, 301), <<"kind">> => <<"login">>,
                                           <<"url">> => <<"https://example.com/">>}, Ctx),
    {ok, #{<<"error">> := _}} = Takeover(#{<<"reason">> => <<"Sign in">>, <<"kind">> => <<"bribe">>,
                                           <<"url">> => <<"https://example.com/">>}, Ctx),
    {ok, #{<<"sessionId">> := Sid, <<"kind">> := <<"login">>, <<"reason">> := <<"Sign in to the shop">>,
           <<"url">> := <<"https://example.com/login">>, <<"consoleUrl">> := Console}} =
        Takeover(#{<<"reason">> => <<" Sign in to the shop ">>, <<"kind">> => <<"login">>,
                   <<"url">> => <<"https://example.com/login">>}, Ctx),
    ?assertEqual(<<"/browser/", Sid/binary>>, Console),
    %% the conversation's one session: browse_web uses it too
    #{<<"sessionId">> := Sid} = muse_store:get(?OWNER, <<"chat-browsers">>, Tid),
    {ok, Tid} = muse_browser:thread_of(?OWNER, Sid),
    %% without a url it stays where it is, re-opened if the worker lost it
    ok = muse_fake_worker:forget(Sid),
    {ok, #{<<"sessionId">> := Sid, <<"kind">> := <<"confirm">>}} =
        Takeover(#{<<"reason">> => <<"Confirm the booking">>, <<"kind">> => <<"confirm">>}, Ctx),
    %% after the person is done: read the page where they left it; nothing
    %% is opened or reloaded (the fake worker's page is https://example.com/)
    true = ets:match_delete(muse_fake_worker, {call, '_'}),
    {ok, #{<<"sessionId">> := Sid, <<"url">> := <<"https://example.com/">>, <<"truncated">> := true,
           <<"text">> := ReadText}} = ReadCurrent(#{}, Ctx),
    ?assertEqual(30000, string:length(ReadText)),
    SessionPath = <<"/sessions/", Sid/binary>>,
    ?assertEqual([{<<"GET">>, <<SessionPath/binary, "/read">>}], muse_fake_worker:calls()),
    Page = page(Config, Cookie, "/browser/" ++ binary_to_list(Sid)),
    ?assert(has(Page, <<"id=\"browser-back\"">>)),
    ?assert(has(Page, <<"href=\"/chat/", Tid/binary, "\"">>)),
    ?assert(has(Page, <<"回到对话"/utf8>>)),
    Closed = act(Config, Cookie, {muse_ui_browser, close, #{id => Sid}}, #{<<"type">> => <<"click">>}),
    [<<"/chat/", Tid/binary>>] = [V || #{<<"op">> := <<"redirect">>, <<"value">> := V} <- Closed].

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

%% Apps: the account connection page is gone.

no_apps_page(Config) ->
    Cookie = sign_in(Config),
    {404, _, _} = req(Config, get, "/apps", cookie(Cookie)),
    ?assertNot(lists:keymember(apps, 1, muse_ui_page:modules())).

%% Every action needs the session cookie (muse_ui:authorize/1).
actions_need_session(Config) ->
    Cookie = sign_in(Config),
    lists:foreach(
      fun(Ref) ->
              {401, _} = act_raw(Config, [], Ref, #{}),
              {401, _} = act_raw(Config, cookie("nope"), Ref, #{})
      end,
      [{muse_ui_settings, add_memory, #{}}, {muse_ui_documents, refresh, #{}}, {muse_ui_computer, start, #{}},
       {muse_ui_browser, shot, #{id => muse_ids:uuid()}}]),
    %% pages render for the session
    [?assert(has(page(Config, Cookie, P), <<"id=\"muse-shell\"">>), P)
     || P <- ["/documents", "/computer", "/browser", "/settings"]].
