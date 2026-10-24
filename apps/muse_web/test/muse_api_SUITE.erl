%% JSON API: middleware, auth and the core/agent/thread routes
%% (integrations spec §2.2–§2.6, engine spec §12.1), on the booted app.
-module(muse_api_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [middleware, auth_and_session, workspace_routes, actions_and_drafts, conversation_and_threads,
     agent_routes, login_limit, live_access_key].

init_per_testcase(live_access_key, Config) ->
    Env = muse_web_test_env:start(#{<<"WORKSPACE_MODE">> => <<"live">>,
                                    <<"OPENMUSE_ACCESS_KEY">> => binary:copy(<<"k">>, 24),
                                    <<"TOKEN_ENCRYPTION_KEY">> => base64:encode(crypto:strong_rand_bytes(32)),
                                    <<"MUSE_UI_SECRET">> => binary:copy(<<"s">>, 32)}),
    [{env, Env} | Config];
init_per_testcase(_Case, Config) ->
    [{env, muse_web_test_env:start()} | Config].

end_per_testcase(_Case, Config) ->
    muse_web_test_env:stop(?config(env, Config)).

h(Config, Method, Path, Token) -> muse_web_test_env:http(?config(env, Config), Method, Path, Token).
h(Config, Method, Path, Token, Body) -> muse_web_test_env:http(?config(env, Config), Method, Path, Token, Body).

middleware(Config) ->
    Env = ?config(env, Config),
    {403, #{<<"error">> := <<"Origin is not allowed">>}} =
        h(Config, get, "/api/health", {headers, [{"origin", "https://evil.example"}]}),
    {200, _} = h(Config, get, "/api/health", {headers, [{"origin", "http://localhost:8081"}]}),
    %% preflight ends in the middleware, with CORS headers for allowed origins
    {ok, {{_, 204, _}, Headers, _}} =
        httpc:request(options, {muse_web_test_env:base(Env) ++ "/api/workspace",
                                [{"origin", "http://localhost:8081"},
                                 {"access-control-request-method", "POST"}]}, [], []),
    ?assertEqual("http://localhost:8081", proplists:get_value("access-control-allow-origin", Headers)),
    ?assertEqual("GET,POST,PUT,PATCH,DELETE,OPTIONS", proplists:get_value("access-control-allow-methods", Headers)),
    {200, _, RootHeaders} = case h(Config, get, "/", undefined) of
                                {200, Json} -> {200, Json, []};
                                Other -> Other
                            end,
    _ = RootHeaders,
    %% security headers everywhere
    {ok, {{_, 200, _}, H2, _}} = httpc:request(get, {muse_web_test_env:base(Env) ++ "/api/health", []}, [], []),
    ?assertEqual("nosniff", proplists:get_value("x-content-type-options", H2)),
    ?assertEqual("no-store", proplists:get_value("cache-control", H2)),
    ?assertEqual("no-referrer", proplists:get_value("referrer-policy", H2)),
    %% body limit by content length
    Big = binary:copy(<<"x">>, 12582913),
    {413, #{<<"error">> := <<"Request is too large; PDFs must be 10 MB or smaller">>}} =
        h(Config, post, "/api/session", undefined, {raw, "application/json", Big}),
    %% invalid JSON
    {400, #{<<"error">> := <<"Invalid request data">>}} =
        h(Config, post, "/api/session", undefined, {raw, "application/json", <<"{">>}).

auth_and_session(Config) ->
    {200, #{<<"ok">> := true, <<"mode">> := <<"sample">>, <<"agentConfigured">> := true,
            <<"browserConfigured">> := false}} = h(Config, get, "/api/health", undefined),
    {401, #{<<"error">> := <<"Sign in to OpenMuse">>}} = h(Config, get, "/api/workspace", undefined),
    {401, #{<<"error">> := <<"Session expired. Sign in again.">>}} = h(Config, get, "/api/workspace", <<"nope">>),
    {200, #{<<"token">> := Token, <<"mode">> := <<"sample">>}} = h(Config, post, "/api/session", undefined, #{}),
    {200, #{<<"mode">> := <<"sample">>}} = h(Config, get, "/api/workspace", Token),
    %% unknown authenticated route: Hono's plain 404
    {404, <<"404 Not Found">>, _} = h(Config, get, "/api/nothing-here", Token),
    %% signature on a non-signable path does not authenticate
    {401, _} = h(Config, get, "/api/workspace?owner=local-user&expires=99999999999999&signature=" ++
                     lists:duplicate(64, $a), undefined).

workspace_routes(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {200, #{<<"mail">> := Mail, <<"events">> := [_, _, _], <<"connections">> := [#{<<"status">> := <<"sample">>} | _],
            <<"actions">> := [#{<<"status">> := <<"awaiting_review">>}]}} = h(Config, get, "/api/workspace", T),
    ?assertEqual(4, length(Mail)),
    {200, #{<<"mail">> := [_]}} = h(Config, get, "/api/workspace?q=bluebird", T),
    {200, [#{<<"id">> := <<"primary">>}]} = h(Config, get, "/api/calendars", T),
    {200, [_, _, _]} = h(Config, get, "/api/calendar/events", T),
    {422, _} = h(Config, get, "/api/calendar/events?timeMin=yesterday", T),
    {422, #{<<"error">> := _}} = h(Config, get, "/api/calendar/events?timeMin=2030-01-02T00:00:00Z&timeMax=2030-01-01T00:00:00Z", T),
    {200, [#{<<"id">> := <<"mail-fieldtrip">>}]} = h(Config, get, "/api/mail/threads/trip-thread", T),
    {404, #{<<"error">> := <<"Mail thread not found">>}} = h(Config, get, "/api/mail/threads/none", T).

actions_and_drafts(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    Draft = #{<<"to">> => [<<"jamie@example.com">>], <<"subject">> => <<"Hi">>, <<"body">> => <<"Thursday">>},
    {201, #{<<"id">> := Id, <<"hash">> := Hash, <<"status">> := <<"awaiting_review">>}} =
        h(Config, post, "/api/actions", T, #{<<"kind">> => <<"email.send">>, <<"data">> => Draft}),
    {404, #{<<"error">> := <<"File not found">>}} =
        h(Config, post, "/api/actions", T, #{<<"kind">> => <<"email.send">>,
                                             <<"data">> => Draft#{<<"attachmentIds">> => [muse_ids:uuid()]}}),
    {422, _} = h(Config, post, "/api/actions", T, #{<<"kind">> => <<"nope">>}),
    {422, _} = h(Config, post, "/api/actions/" ++ binary_to_list(Id) ++ "/decide", T, #{<<"hash">> => Hash}),
    {200, #{<<"status">> := <<"succeeded">>, <<"result">> := <<"Saved to local sent mail", _/binary>>}} =
        h(Config, post, "/api/actions/" ++ binary_to_list(Id) ++ "/decide", T,
          #{<<"hash">> => Hash, <<"decision">> => <<"approve">>}),
    {201, #{<<"id">> := D, <<"createdAt">> := C}} = h(Config, post, "/api/drafts", T, Draft),
    {201, #{<<"id">> := D, <<"createdAt">> := C, <<"subject">> := <<"Changed">>}} =
        h(Config, post, "/api/drafts", T, Draft#{<<"id">> => D, <<"subject">> => <<"Changed">>}),
    {404, #{<<"error">> := <<"Draft not found">>}} = h(Config, post, "/api/drafts", T, Draft#{<<"id">> => muse_ids:uuid()}),
    {422, _} = h(Config, post, "/api/drafts", T, Draft#{<<"id">> => <<"not-a-uuid">>}),
    {200, [#{<<"id">> := D}]} = h(Config, get, "/api/drafts", T).

conversation_and_threads(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {200, #{<<"threadId">> := Main, <<"existing">> := true}} = h(Config, get, "/api/main-thread", T),
    {200, #{<<"threadId">> := Main}} = h(Config, get, "/api/main-thread", T),
    {200, #{<<"messages">> := []}} = h(Config, get, "/api/conversation", T),
    Msg = #{<<"id">> => <<"m1">>, <<"role">> => <<"user">>, <<"content">> => <<"hi">>},
    {200, #{<<"ok">> := true}} = h(Config, put, "/api/conversation", T, #{<<"messages">> => [Msg]}),
    {200, #{<<"messages">> := [Msg]}} = h(Config, get, "/api/conversation", T),
    {422, _} = h(Config, put, "/api/conversation", T, #{<<"messages">> => [#{<<"role">> => <<"alien">>}]}),
    {422, _} = h(Config, put, "/api/conversation", T, #{}),
    {201, #{<<"id">> := Side, <<"kind">> := <<"side">>}} = h(Config, post, "/api/threads", T, #{<<"title">> => <<"Trip">>}),
    {200, #{<<"title">> := <<"Lisbon">>, <<"archived">> := true}} =
        h(Config, post, "/api/threads/" ++ binary_to_list(Side), T, #{<<"title">> => <<"Lisbon">>, <<"archived">> => true}),
    {409, _} = h(Config, post, "/api/threads/" ++ binary_to_list(Main), T, #{<<"archived">> => true}),
    {200, [_, _]} = h(Config, get, "/api/threads", T),
    {200, []} = h(Config, get, "/api/threads/" ++ binary_to_list(Side) ++ "/messages", T),
    {404, _} = h(Config, get, "/api/threads/none/messages", T).

agent_routes(Config) ->
    T = muse_web_test_env:login(?config(env, Config)),
    {200, #{<<"tasks">> := [], <<"ideas">> := Ideas, <<"identity">> := #{<<"name">> := <<"OpenMuse">>}}} =
        h(Config, get, "/api/agent", T),
    ?assert(length(Ideas) >= 1),
    {201, #{<<"id">> := Task}} = h(Config, post, "/api/agent/tasks", T, #{<<"prompt">> => <<"Plan">>, <<"requestId">> => <<"r1">>}),
    {201, #{<<"id">> := Task}} = h(Config, post, "/api/agent/tasks", T, #{<<"prompt">> => <<"Plan">>, <<"requestId">> => <<"r1">>}),
    ?assertEqual(muse_ids:sha256hex(<<"task:r1">>), Task),
    TP = "/api/agent/tasks/" ++ binary_to_list(Task),
    {200, #{<<"task">> := #{<<"id">> := Task}, <<"events">> := []}} = h(Config, get, TP, T),
    {404, #{<<"error">> := <<"Task not found">>}} = h(Config, get, "/api/agent/tasks/nope", T),
    {200, #{<<"status">> := <<"paused">>}} = h(Config, post, TP ++ "/control", T, #{<<"action">> => <<"pause">>}),
    {422, _} = h(Config, post, TP ++ "/control", T, #{<<"action">> => <<"explode">>}),
    {409, #{<<"error">> := <<"This task is not waiting for input">>}} = h(Config, post, TP ++ "/input", T, #{<<"answer">> => <<"x">>}),
    {201, #{<<"id">> := G, <<"milestones">> := [#{<<"id">> := M}]}} =
        h(Config, post, "/api/agent/goals", T, #{<<"title">> => <<"Garden">>, <<"milestones">> => [<<"Soil">>]}),
    {200, #{<<"milestones">> := [#{<<"done">> := true}]}} =
        h(Config, post, "/api/agent/goals/" ++ binary_to_list(G) ++ "/milestones/" ++ binary_to_list(M), T, #{<<"done">> => true}),
    {200, #{<<"status">> := <<"completed">>}} = h(Config, post, "/api/agent/goals/" ++ binary_to_list(G), T, #{<<"status">> => <<"completed">>}),
    {201, #{<<"id">> := Mon}} = h(Config, post, "/api/agent/monitors", T,
                                  #{<<"title">> => <<"Menu">>, <<"url">> => <<"sample://availability">>}),
    {200, #{<<"status">> := <<"paused">>}} = h(Config, post, "/api/agent/monitors/" ++ binary_to_list(Mon) ++ "/control", T,
                                               #{<<"action">> => <<"pause">>}),
    {200, #{<<"ok">> := true}} = h(Config, post, "/api/agent/sample-page", T, #{<<"text">> => <<"Tables!">>}),
    {200, [_ | _]} = h(Config, post, "/api/agent/ideas/refresh", T),
    {201, #{<<"id">> := Mem, <<"source">> := <<"You">>}} = h(Config, post, "/api/agent/memories", T, #{<<"text">> => <<"Tea">>}),
    {200, #{<<"text">> := <<"Green tea">>}} = h(Config, post, "/api/agent/memories/" ++ binary_to_list(Mem), T, #{<<"text">> => <<"Green tea">>}),
    {200, #{<<"ok">> := true}} = h(Config, post, "/api/agent/memories/" ++ binary_to_list(Mem) ++ "/forget", T),
    {404, _} = h(Config, post, "/api/agent/memories/" ++ binary_to_list(Mem) ++ "/forget", T),
    {200, #{<<"name">> := <<"Muse">>}} = h(Config, post, "/api/agent/identity", T, #{<<"name">> => <<"Muse">>, <<"tone">> => <<"concise">>}),
    {200, Notifications} = h(Config, get, "/api/agent/notifications", T),
    ?assert(is_list(Notifications)),
    {404, #{<<"error">> := <<"Notification not found">>}} = h(Config, post, "/api/agent/notifications/x/read", T).

login_limit(Config) ->
    Results = [element(1, h(Config, post, "/api/session", undefined, #{})) || _ <- lists:seq(1, 31)],
    ?assertEqual(30, length([S || S <- Results, S =:= 200])),
    ?assertEqual(429, lists:last(Results)).

live_access_key(Config) ->
    {401, #{<<"error">> := <<"Access key is incorrect">>}} = h(Config, post, "/api/session", undefined, #{<<"accessKey">> => <<"wrong">>}),
    {200, #{<<"mode">> := <<"live">>}} = h(Config, post, "/api/session", undefined, #{<<"accessKey">> => binary:copy(<<"k">>, 24)}).
