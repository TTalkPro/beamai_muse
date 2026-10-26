%% @doc Core JSON routes (OpenMuse app.ts, integrations spec §2.6 #1–#15).
%%
%% The OpenMuse mail, calendar, draft and account connection routes are gone
%% (docs/DIFFERENCES.md); `POST /api/actions` takes the registered action
%% kinds (muse_actions).
-module(muse_api_core).

-export([public/3, handle/3, prepare_owner/1]).

%% @doc Routes that run before authentication.
-spec public(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
public(<<"GET">>, [<<"api">>, <<"health">>], Req) ->
    {{200, #{<<"ok">> => true,
             <<"mode">> => atom_to_binary(muse_config:get(mode)),
             <<"agentConfigured">> => muse_config:agent_configured(),
             <<"browserConfigured">> => muse_config:browser_configured()}}, Req};
public(<<"POST">>, [<<"api">>, <<"session">>], Req) ->
    session(Req);
public(_, _, _) ->
    next.

session(Req0) ->
    Key = maps:get(muse_client_key, Req0, <<"conn:unknown">>),
    case muse_rate_limit:take(login, Key) of
        false ->
            {{error, {429, <<"Too many sign-in attempts. Try again in a minute.">>}}, Req0};
        true ->
            case muse_http:body(Req0, {object, [{<<"accessKey">>, {optional, {string, #{}}}}]}) of
                {ok, Body, Req} ->
                    case muse_auth:session(maps:get(<<"accessKey">>, Body, undefined)) of
                        {ok, #{token := Token, mode := Mode}} ->
                            Owner = muse_auth:owner(),
                            ok = prepare_owner(Owner),
                            {{200, #{<<"token">> => Token, <<"mode">> => Mode}}, Req};
                        Error ->
                            {Error, Req}
                    end;
                {error, E, Req} ->
                    {{error, E}, Req}
            end
    end.

%% @doc Sample data and agent identity for the owner, as OpenMuse does on
%% sign-in (without its first Ideas: the UI has none).
-spec prepare_owner(binary()) -> ok.
prepare_owner(Owner) ->
    _ = muse_workspace:ensure_sample(Owner),
    ok = muse_agent_service:ensure(Owner),
    ok.

%% Authenticated routes

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(<<"GET">>, [<<"api">>, <<"workspace">>], Req) ->
    Owner = muse_http:owner(Req),
    {ok, Snapshot} = muse_workspace:snapshot(Owner),
    {{200, decorate_workspace(Owner, Snapshot)}, Req};
handle(<<"POST">>, [<<"api">>, <<"actions">>], Req0) ->
    with_body(Req0, muse_actions:proposal_schema(),
              fun(Input) -> created(muse_actions:propose(muse_http:owner(Req0), Input, undefined, undefined)) end);
handle(<<"POST">>, [<<"api">>, <<"actions">>, Id, <<"decide">>], Req0) ->
    with_body(Req0, {object, [{<<"hash">>, {string, #{}}},
                              {<<"decision">>, {enum, [<<"approve">>, <<"deny">>]}}]},
              fun(#{<<"hash">> := Hash, <<"decision">> := Decision}) ->
                      ok_200(muse_actions:decide(muse_http:owner(Req0), Id, Hash, binary_to_atom(Decision)))
              end);
handle(<<"GET">>, [<<"api">>, <<"main-thread">>], Req) ->
    {ok, #{<<"id">> := ThreadId}} = muse_threads:main_thread(muse_http:owner(Req)),
    {{200, #{<<"threadId">> => ThreadId, <<"existing">> => true}}, Req};
handle(<<"GET">>, [<<"api">>, <<"conversation">>], Req) ->
    {{200, case muse_store:get(muse_http:owner(Req), <<"conversations">>, <<"default">>) of
               undefined -> #{<<"messages">> => []};
               Conversation -> Conversation
           end}, Req};
handle(<<"PUT">>, [<<"api">>, <<"conversation">>], Req0) ->
    with_body(Req0, {object, [{<<"messages">>, {array, message_schema(), #{max => 1000}}}]},
              fun(#{<<"messages">> := Messages}) ->
                      _ = muse_store:put(muse_http:owner(Req0), <<"conversations">>,
                                         #{<<"id">> => <<"default">>, <<"messages">> => Messages}),
                      {200, #{<<"ok">> => true}}
              end);
handle(_, _, _) ->
    next.

%% Browsers get signed URLs; a configured worker that does not answer is
%% `unavailable`, not ready.
decorate_workspace(Owner, #{<<"browsers">> := Browsers, <<"connections">> := Connections} = S) ->
    Reachable = muse_browser:reachable(),
    S#{<<"browsers">> => [muse_browser:decorate(Owner, B) || B <- Browsers],
       <<"connections">> => [case C of
                                 #{<<"id">> := <<"browser">>, <<"status">> := <<"connected">>} when not Reachable ->
                                     C#{<<"status">> => <<"unavailable">>};
                                 _ -> C
                             end || C <- Connections]}.

%% AG-UI `Message` (the parts the store relies on): an id and a known role.
message_schema() ->
    {object, [{<<"id">>, {string, #{}}},
              {<<"role">>, {enum, [<<"developer">>, <<"system">>, <<"assistant">>, <<"user">>, <<"tool">>,
                                   <<"activity">>, <<"reasoning">>]}},
              {<<"content">>, {optional, any}},
              {<<"name">>, {optional, {string, #{}}}},
              {<<"toolCalls">>, {optional, {array, any, #{}}}},
              {<<"toolCallId">>, {optional, {string, #{}}}},
              {<<"error">>, {optional, {string, #{}}}},
              {<<"activityType">>, {optional, {string, #{}}}}]}.

with_body(Req0, Schema, Fun) ->
    case muse_http:body(Req0, Schema) of
        {ok, V, Req} -> {Fun(V), Req};
        {error, E, Req} -> {{error, E}, Req}
    end.

ok_200({ok, V}) -> {200, V};
ok_200({error, E}) -> {error, E}.

created({ok, V}) -> {201, V};
created({error, E}) -> {error, E}.
