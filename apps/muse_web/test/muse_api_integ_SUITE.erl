%% Documents, attachments, Google connect, browser and computer routes
%% (integrations spec §2.6 #16–#31, §6.9) on the booted app, sample mode.
%% Browser routes run against muse_fake_worker (muse_integ test helper);
%% computer routes mock muse_computer, so no docker is needed.
-module(muse_api_integ_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(CSP, "default-src 'self'; img-src 'self' blob:; script-src 'unsafe-inline'; "
             "style-src 'unsafe-inline'; connect-src 'self'").
-define(BOUNDARY, "muse-test-boundary-7d2f").

all() ->
    [files_flow, upload_errors, attachment_and_google, browser_unconfigured, browser_routes,
     computer_routes, computer_desktop].

init_per_testcase(browser_routes, Config) ->
    {ok, _} = application:ensure_all_started(cowboy),
    {Url, Token} = muse_fake_worker:start(),
    Env = muse_web_test_env:start(#{<<"BROWSER_WORKER_URL">> => Url, <<"WORKER_TOKEN">> => Token}),
    [{env, Env}, {worker, true} | Config];
init_per_testcase(computer_routes, Config) ->
    Env = muse_web_test_env:start(),
    ok = meck:new(muse_computer, [passthrough]),
    [{env, Env} | Config];
init_per_testcase(_Case, Config) ->
    [{env, muse_web_test_env:start()} | Config].

end_per_testcase(computer_routes, Config) ->
    meck:unload(muse_computer),
    muse_web_test_env:stop(?config(env, Config));
end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)),
    case ?config(worker, Config) of
        true -> muse_fake_worker:stop();
        _ -> ok
    end.

h(Config, Method, Path, Token) -> muse_web_test_env:http(?config(env, Config), Method, Path, Token).
h(Config, Method, Path, Token, Body) -> muse_web_test_env:http(?config(env, Config), Method, Path, Token, Body).

files_flow(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {ok, Pdf} = muse_pdf:sample(),
    Name = <<"Trip form é (1).pdf"/utf8>>,
    {201, #{<<"id">> := Id, <<"name">> := Name, <<"source">> := <<"Uploaded by you">>,
            <<"mimeType">> := <<"application/pdf">>, <<"url">> := Url, <<"fields">> := Fields} = File} =
        h(Config, post, "/api/files", T,
          multipart([{field, <<"note">>, <<"ignored">>}, {file, <<"file">>, Name, Pdf}])),
    ?assertEqual(byte_size(Pdf), maps:get(<<"size">>, File)),
    {200, #{<<"files">> := Files}} = h(Config, get, "/api/workspace", T),
    ?assert(lists:any(fun(#{<<"id">> := I}) -> I =:= Id end, Files)),

    %% content with Bearer
    ContentPath = "/api/files/" ++ binary_to_list(Id) ++ "/content",
    {200, Pdf, Headers} = h(Config, get, ContentPath, T),
    ?assertEqual("application/pdf", proplists:get_value("content-type", Headers)),
    ?assertEqual("inline; filename*=UTF-8''Trip%20form%20%C3%A9%20(1).pdf",
                 proplists:get_value("content-disposition", Headers)),
    %% content with the signed URL, no Bearer
    Signed = path_of(Url),
    {200, Pdf, _} = h(Config, get, Signed, undefined),
    Owner = binary_to_list(muse_auth:owner()),
    {401, #{<<"error">> := <<"Document link expired; refresh the workspace">>}} =
        h(Config, get, ContentPath ++ "?owner=" ++ Owner ++ "&expires=1&signature=" ++ lists:duplicate(64, $a),
          undefined),
    Later = integer_to_list(erlang:system_time(millisecond) + 600000),
    {403, #{<<"error">> := <<"Invalid access link">>}} =
        h(Config, get, ContentPath ++ "?owner=" ++ Owner ++ "&expires=" ++ Later ++ "&signature=" ++
                           lists:duplicate(64, $a), undefined),
    %% a signature for one file does not open another
    #{query := Query} = uri_string:parse(Url),
    [Other | _] = [I || #{<<"id">> := I} <- Files, I =/= Id],
    {403, _} = h(Config, get, "/api/files/" ++ binary_to_list(Other) ++ "/content?" ++ binary_to_list(Query), undefined),
    %% unknown and malformed ids
    {404, #{<<"error">> := <<"File not found">>}} =
        h(Config, get, "/api/files/" ++ binary_to_list(muse_ids:uuid()) ++ "/content", T),
    {404, #{<<"error">> := <<"File not found">>}} = h(Config, get, "/api/files/nope/content", T),

    %% fill
    Values = maps:from_list([{N, case Type of <<"checkbox">> -> true; _ -> <<"Ada">> end}
                             || #{<<"name">> := N, <<"type">> := Type} <- Fields, Type =/= <<"unsupported">>]),
    ?assert(map_size(Values) > 0),
    {201, #{<<"name">> := <<"Trip form é (1) — filled.pdf"/utf8>>, <<"parentId">> := Id}} =
        h(Config, post, "/api/files/" ++ binary_to_list(Id) ++ "/fill", T, #{<<"fields">> => Values}),
    {422, _} = h(Config, post, "/api/files/" ++ binary_to_list(Id) ++ "/fill", T, #{<<"fields">> => #{<<"a">> => 1}}),
    {422, _} = h(Config, post, "/api/files/" ++ binary_to_list(Id) ++ "/fill", T, #{}),
    {404, _} = h(Config, post, "/api/files/" ++ binary_to_list(muse_ids:uuid()) ++ "/fill", T,
                 #{<<"fields">> => #{}}).

upload_errors(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    Choose = #{<<"error">> => <<"Choose a PDF file">>},
    {400, Choose} = h(Config, post, "/api/files", T, multipart([{field, <<"file">>, <<"not a file">>}])),
    {400, Choose} = h(Config, post, "/api/files", T, multipart([{file, <<"other">>, <<"a.pdf">>, <<"%PDF">>}])),
    {400, Choose} = h(Config, post, "/api/files", T, #{<<"file">> => <<"x">>}),
    {400, Choose} = h(Config, post, "/api/files", T, {raw, "multipart/form-data; boundary=" ?BOUNDARY, <<"junk">>}),
    {Status, #{<<"error">> := _}} =
        h(Config, post, "/api/files", T, multipart([{file, <<"file">>, <<"a.pdf">>, <<"hello">>}])),
    ?assert(Status >= 400 andalso Status < 500),
    {401, _} = h(Config, post, "/api/files", undefined, multipart([{file, <<"file">>, <<"a.pdf">>, <<"x">>}])).

attachment_and_google(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {400, #{<<"error">> := <<"Attachment reference is invalid">>}} =
        h(Config, post, "/api/mail/import-attachment", T, #{<<"reference">> => <<"abc">>}),
    {422, _} = h(Config, post, "/api/mail/import-attachment", T, #{}),
    {400, #{<<"error">> := <<"Invalid request data">>}} =
        h(Config, post, "/api/mail/import-attachment", T, {raw, "application/json", <<"{">>}),
    ?assertEqual(<<"sample">>, google_status(Config, T)),

    {200, #{<<"ok">> := true}} = h(Config, post, "/api/google/disconnect", T),
    ?assertEqual(<<"disconnected">>, google_status(Config, T)),
    {409, #{<<"error">> := <<"Google is disconnected">>}} =
        h(Config, post, "/api/mail/import-attachment", T, #{<<"reference">> => <<"abc">>}),

    {422, _} = h(Config, post, "/api/google/connect", T, #{<<"capability">> => <<"admin">>}),
    {200, #{<<"url">> := null, <<"connected">> := true}} =
        h(Config, post, "/api/google/connect", T, #{<<"capability">> => <<"write">>}),
    ?assertEqual(<<"sample">>, google_status(Config, T)),
    #{<<"enabled">> := true, <<"connectionId">> := ConnId} =
        muse_store:get(muse_auth:owner(), <<"settings">>, <<"google">>),
    ?assert(muse_ids:is_uuid(ConnId)).

browser_unconfigured(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {503, #{<<"error">> := <<"Browser worker is not configured. Start it using the setup guide.">>}} =
        h(Config, post, "/api/browsers", T, #{<<"url">> => <<"https://example.com/">>}),
    {422, _} = h(Config, post, "/api/browsers", T, #{<<"url">> => <<"not a url">>}),
    {422, _} = h(Config, post, "/api/browsers", T, #{<<"url">> => <<"https://example.com/", (binary:copy(<<"a">>, 4096))/binary>>}),
    NotFound = #{<<"error">> => <<"Browser session not found">>},
    Unknown = "/api/browsers/" ++ binary_to_list(muse_ids:uuid()),
    {404, NotFound} = h(Config, get, Unknown, T),
    {404, NotFound} = h(Config, get, "/api/browsers/nope", T),
    {404, NotFound} = h(Config, get, Unknown ++ "/console", T),
    {404, NotFound} = h(Config, get, Unknown ++ "/preview", T),
    {404, NotFound} = h(Config, post, Unknown ++ "/close", T),
    {404, <<"404 Not Found">>, _} = h(Config, get, Unknown ++ "/elsewhere", T).

browser_routes(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {201, #{<<"id">> := Id, <<"status">> := <<"active">>, <<"consoleUrl">> := ConsoleUrl,
            <<"previewUrl">> := PreviewUrl}} =
        h(Config, post, "/api/browsers", T, #{<<"url">> => <<"https://example.com/">>}),
    Base = "/api/browsers/" ++ binary_to_list(Id),
    {200, #{<<"id">> := Id, <<"consoleUrl">> := _, <<"previewUrl">> := _}} = h(Config, get, Base, T),
    {200, #{<<"url">> := <<"https://example.org/x">>}} =
        h(Config, post, Base ++ "/navigate", T, #{<<"url">> => <<"https://example.org/x">>}),
    {422, _} = h(Config, post, Base ++ "/navigate", T, #{}),
    {502, #{<<"error">> := <<"The page could not be loaded.">>}} =
        h(Config, post, Base ++ "/navigate", T, #{<<"url">> => <<"https://example.org/fail">>}),
    {200, #{<<"title">> := <<"Example">>, <<"truncated">> := false, <<"text">> := _}} = h(Config, get, Base ++ "/read", T),
    %% reopen: empty body, a URL, invalid JSON
    {200, #{<<"status">> := <<"active">>}} = h(Config, post, Base ++ "/reopen", T),
    {200, #{<<"url">> := <<"https://example.net/">>}} =
        h(Config, post, Base ++ "/reopen", T, #{<<"url">> => <<"https://example.net/">>}),
    {400, #{<<"error">> := <<"Invalid request data">>}} =
        h(Config, post, Base ++ "/reopen", T, {raw, "application/json", <<"{">>}),
    {422, _} = h(Config, post, Base ++ "/reopen", T, #{<<"url">> => <<"nope">>}),
    {200, #{<<"files">> := [#{<<"name">> := <<"slip.pdf">>}], <<"failures">> := [#{<<"id">> := <<"d2">>}]}} =
        h(Config, post, Base ++ "/import-downloads", T),
    %% preview: Bearer and signed
    {200, <<137, "PNG", _/binary>>, PngHeaders} = h(Config, get, Base ++ "/preview", T),
    ?assertEqual("image/png", proplists:get_value("content-type", PngHeaders)),
    {200, <<137, "PNG", _/binary>>, _} = h(Config, get, path_of(PreviewUrl), undefined),
    %% console page over the signed URL
    {200, Html, HtmlHeaders} = h(Config, get, path_of(ConsoleUrl), undefined),
    ?assertEqual(?CSP, proplists:get_value("content-security-policy", HtmlHeaders)),
    ?assertEqual("text/html; charset=UTF-8", proplists:get_value("content-type", HtmlHeaders)),
    ?assertMatch({_, _}, binary:match(Html, <<"<title>OpenMuse browser</title>">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"/api/browsers/", Id/binary, "/preview?owner=">>)),
    {200, _, _} = h(Config, get, Base ++ "/console", T),
    {403, _} = h(Config, get, Base ++ "/console?owner=local-user&expires=99999999999999&signature=" ++
                     lists:duplicate(64, $b), undefined),
    %% console input over the signed URL
    {200, #{<<"ok">> := true}} =
        h(Config, post, path_of(ConsoleUrl), undefined, #{<<"type">> => <<"scroll">>, <<"deltaY">> => 600}),
    {422, #{<<"error">> := <<"A JSON object is required for browser input">>}} =
        h(Config, post, Base ++ "/console", T, {raw, "application/json", <<"[1]">>}),
    {400, _} = h(Config, post, Base ++ "/console", T),
    {200, #{<<"status">> := <<"closed">>}} = h(Config, post, Base ++ "/close", T),
    {404, _} = h(Config, get, "/api/browsers/" ++ binary_to_list(muse_ids:uuid()) ++ "/read", T).

computer_routes(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    Owner = muse_auth:owner(),
    {200, #{<<"enabled">> := false, <<"status">> := <<"unconfigured">>, <<"provider">> := <<"docker">>,
            <<"commands">> := []}} = h(Config, get, "/api/computer", T),
    {503, #{<<"error">> := <<"Computer is not configured. Enable COMPUTER_ENABLED and build the local computer image.">>}} =
        h(Config, post, "/api/computer/start", T),

    Snapshot = #{<<"enabled">> => true, <<"status">> => <<"running">>},
    meck:expect(muse_computer, start, fun(O) when O =:= Owner -> {ok, Snapshot} end),
    meck:expect(muse_computer, stop, fun(_) -> {error, {409, <<"Computer is busy. Wait for the current operation to finish.">>}} end),
    {200, Snapshot} = h(Config, post, "/api/computer/start", T),
    {409, #{<<"error">> := <<"Computer is busy. Wait for the current operation to finish.">>}} =
        h(Config, post, "/api/computer/stop", T),

    %% commands: validated body; the request process is the cancel signal
    meck:expect(muse_computer, execute,
                fun(_, #{<<"command">> := Cmd, <<"cwd">> := Cwd}, #{cancel := Pid}) when Pid =:= self() ->
                        {ok, #{<<"command">> => Cmd, <<"cwd">> => Cwd, <<"status">> => <<"succeeded">>}}
                end),
    {200, #{<<"command">> := <<"ls -la">>, <<"cwd">> := <<"/workspace">>, <<"status">> := <<"succeeded">>}} =
        h(Config, post, "/api/computer/commands", T, #{<<"command">> => <<"  ls -la ">>}),
    {200, #{<<"cwd">> := <<"/workspace/a">>}} =
        h(Config, post, "/api/computer/commands", T, #{<<"command">> => <<"pwd">>, <<"cwd">> => <<"/workspace/a">>}),
    {422, _} = h(Config, post, "/api/computer/commands", T, #{<<"command">> => <<"   ">>}),
    {400, _} = h(Config, post, "/api/computer/commands", T, {raw, "application/json", <<"nope">>}),

    %% files
    meck:expect(muse_computer, list, fun(_) -> {ok, #{<<"path">> => <<"/workspace">>, <<"entries">> => []}} end),
    meck:expect(muse_computer, list, fun(_, P) -> {ok, #{<<"path">> => P, <<"entries">> => []}} end),
    {200, #{<<"path">> := <<"/workspace">>}} = h(Config, get, "/api/computer/files", T),
    {200, #{<<"path">> := <<"/workspace/sub dir">>}} = h(Config, get, "/api/computer/files?path=%2Fworkspace%2Fsub%20dir", T),
    meck:expect(muse_computer, read, fun(_, _) -> {error, {422, <<"Choose an absolute path inside /workspace">>}} end),
    {422, #{<<"error">> := <<"Choose an absolute path inside /workspace">>}} =
        h(Config, post, "/api/computer/files/read", T, #{<<"path">> => <<"/etc/passwd">>}),
    {422, _} = h(Config, post, "/api/computer/files/read", T, #{<<"path">> => <<>>}),
    meck:expect(muse_computer, write, fun(_, P, <<"hi">>) -> {ok, #{<<"path">> => P}} end),
    {200, #{<<"path">> := <<"/workspace/a.txt">>}} =
        h(Config, post, "/api/computer/files/write", T, #{<<"path">> => <<"/workspace/a.txt">>, <<"text">> => <<"hi">>}),
    {422, _} = h(Config, post, "/api/computer/files/write", T, #{<<"path">> => <<"/workspace/a.txt">>}),
    meck:expect(muse_computer, mkdir, fun(_, _) -> error(boom) end),
    {502, #{<<"error">> := <<"Request failed. Check the server setup and try again.">>}} =
        h(Config, post, "/api/computer/files/mkdir", T, #{<<"path">> => <<"/workspace/d">>}),
    %% import: the real function looks up the owned document first
    {404, #{<<"error">> := <<"File not found">>}} =
        h(Config, post, "/api/computer/files/import", T,
          #{<<"path">> => <<"/workspace/a.pdf">>, <<"fileId">> => muse_ids:uuid()}),
    {422, _} = h(Config, post, "/api/computer/files/import", T, #{<<"path">> => <<"/workspace/a.pdf">>}),
    meck:expect(muse_computer, export_pdf, fun(_, P) -> {ok, #{<<"id">> => <<"f">>, <<"source">> => <<"Computer: ", P/binary>>}} end),
    {201, #{<<"source">> := <<"Computer: /workspace/a.pdf">>}} =
        h(Config, post, "/api/computer/files/export", T, #{<<"path">> => <<"/workspace/a.pdf">>}),
    meck:expect(muse_computer, export_pdf, fun(_, _) -> {error, {503, <<"Computer is not running">>}} end),
    {503, _} = h(Config, post, "/api/computer/files/export", T, #{<<"path">> => <<"/workspace/a.pdf">>}),

    {404, <<"404 Not Found">>, _} = h(Config, get, "/api/computer/nothing", T),
    {401, _} = h(Config, get, "/api/computer", undefined).

%% No E2B desktop: OpenMuse's desktop routes do not exist.
computer_desktop(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {404, <<"404 Not Found">>, _} = h(Config, get, "/api/computer/desktop", T),
    {404, <<"404 Not Found">>, _} = h(Config, post, "/api/computer/desktop/actions", T, #{<<"action">> => <<"screenshot">>}),
    {404, <<"404 Not Found">>, _} = h(Config, get, "/api/computer/desktop/screenshot?receipt=x", T).

%% Helpers

google_status(Config, T) ->
    {200, #{<<"connections">> := Connections}} = h(Config, get, "/api/workspace", T),
    [Status] = [S || #{<<"id">> := <<"google">>, <<"status">> := S} <- Connections],
    Status.

%% Path and query of an absolute signed URL.
path_of(Url) ->
    #{path := P, query := Q} = uri_string:parse(Url),
    binary_to_list(<<P/binary, "?", Q/binary>>).

multipart(Parts) ->
    B = <<?BOUNDARY>>,
    Body = iolist_to_binary([[[<<"--", B/binary, "\r\n">>, part(P), <<"\r\n">>] || P <- Parts],
                             <<"--", B/binary, "--\r\n">>]),
    {raw, "multipart/form-data; boundary=" ?BOUNDARY, Body}.

part({file, Name, Filename, Bytes}) ->
    [<<"Content-Disposition: form-data; name=\"", Name/binary, "\"; filename=\"", Filename/binary, "\"\r\n"
       "Content-Type: application/pdf\r\n\r\n">>, Bytes];
part({field, Name, Value}) ->
    [<<"Content-Disposition: form-data; name=\"", Name/binary, "\"\r\n\r\n">>, Value].
