%% @doc Core JSON routes (OpenMuse app.ts, integrations spec §2.6 #1–#15).
-module(muse_api_core).

-export([public/3, handle/3, propose_fun/0, prepare_owner/1]).

%% @doc Routes that run before authentication.
-spec public(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
public(<<"GET">>, [<<"api">>, <<"health">>], Req) ->
    {{200, #{<<"ok">> => true,
             <<"mode">> => atom_to_binary(muse_config:get(mode)),
             <<"agentConfigured">> => muse_config:agent_configured(),
             <<"browserConfigured">> => muse_config:browser_configured()}}, Req};
public(<<"POST">>, [<<"api">>, <<"session">>], Req) ->
    session(Req);
public(<<"GET">>, [<<"api">>, <<"google">>, <<"callback">>], Req) ->
    google_callback(Req);
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
    _ = muse_workspace:ensure_sample(Owner, propose_fun()),
    ok = muse_agent_service:ensure(Owner),
    ok.

%% @doc The proposal callback the workspace seed uses.
-spec propose_fun() -> fun((binary(), map()) -> term()).
propose_fun() ->
    fun(Owner, Input) -> muse_actions:propose(Owner, Input, undefined, undefined) end.

google_callback(Req) ->
    Html = fun(Status, Body) ->
                   {raw, Status, #{<<"content-type">> => <<"text/html; charset=UTF-8">>}, Body}
           end,
    case muse_http:query(<<"error">>, Req) of
        undefined ->
            case {muse_http:query(<<"state">>, Req), muse_http:query(<<"code">>, Req)} of
                {State, Code} when is_binary(State), State =/= <<>>, is_binary(Code), Code =/= <<>> ->
                    case muse_google_auth:callback(State, Code) of
                        ok -> {Html(200, <<"<h1>Google is connected</h1><p>Return to OpenMuse and refresh your workspace.</p>">>), Req};
                        {error, E} -> {{error, muse_google_api:http_error(E)}, Req}
                    end;
                _ ->
                    {{error, {400, <<"Google callback is incomplete">>}}, Req}
            end;
        _ ->
            {Html(400, <<"<h1>Google connection cancelled</h1><p>You can return to OpenMuse.</p>">>), Req}
    end.

%% Authenticated routes

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(<<"GET">>, [<<"api">>, <<"workspace">>], Req) ->
    Owner = muse_http:owner(Req),
    {case muse_workspace:snapshot(Owner, muse_http:query(<<"q">>, Req)) of
         {ok, Snapshot} -> {200, decorate_workspace(Owner, Snapshot)};
         Error -> Error
     end, Req};
handle(<<"GET">>, [<<"api">>, <<"calendars">>], Req) ->
    {ok_200(muse_workspace:calendars(muse_http:owner(Req))), Req};
handle(<<"GET">>, [<<"api">>, <<"calendar">>, <<"events">>], Req) ->
    {calendar_events(Req), Req};
handle(<<"GET">>, [<<"api">>, <<"mail">>, <<"threads">>, Id], Req) ->
    {ok_200(muse_workspace:thread(muse_http:owner(Req), Id)), Req};
handle(<<"POST">>, [<<"api">>, <<"actions">>], Req0) ->
    with_body(Req0, muse_actions:proposal_schema(),
              fun(Input) ->
                      Owner = muse_http:owner(Req0),
                      case attachments_owned(Owner, Input) of
                          ok -> created(muse_actions:propose(Owner, Input, undefined, undefined));
                          Error -> Error
                      end
              end);
handle(<<"POST">>, [<<"api">>, <<"actions">>, Id, <<"decide">>], Req0) ->
    with_body(Req0, {object, [{<<"hash">>, {string, #{}}},
                              {<<"decision">>, {enum, [<<"approve">>, <<"deny">>]}}]},
              fun(#{<<"hash">> := Hash, <<"decision">> := Decision}) ->
                      ok_200(muse_actions:decide(muse_http:owner(Req0), Id, Hash, binary_to_atom(Decision)))
              end);
handle(<<"GET">>, [<<"api">>, <<"drafts">>], Req) ->
    {{200, muse_workspace:drafts(muse_http:owner(Req))}, Req};
handle(<<"POST">>, [<<"api">>, <<"drafts">>], Req0) ->
    {object, Fields} = muse_gmail:email_draft_schema(),
    Schema = {object, Fields ++ [{<<"id">>, {optional, {refine, {string, #{}}, fun uuid/1}}}]},
    with_body(Req0, Schema, fun(Draft) -> created(muse_workspace:save_draft(muse_http:owner(Req0), Draft)) end);
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

calendar_events(Req) ->
    Iso = {refine, {string, #{}}, fun iso_with_offset/1},
    Schema = {object, [{<<"calendarId">>, {optional, {string, #{min => 1, max => 1024}}}},
                       {<<"timeMin">>, {optional, Iso}},
                       {<<"timeMax">>, {optional, Iso}}]},
    Query = maps:from_list([{K, V} || {K, V} <- cowboy_req:parse_qs(Req), is_binary(V)]),
    case muse_validate:parse(Schema, Query) of
        {ok, Q} ->
            Checked = case Q of
                          #{<<"timeMin">> := _, <<"timeMax">> := _} ->
                              muse_validate:parse(muse_gcal:calendar_range_schema(), Q);
                          _ -> {ok, Q}
                      end,
            case Checked of
                {ok, _} -> ok_200(muse_workspace:events(muse_http:owner(Req), Q));
                Error -> Error
            end;
        Error ->
            Error
    end.

%% zod `z.iso.datetime({offset: true})`.
iso_with_offset(V) ->
    case re:run(V, <<"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(:\\d{2}(\\.\\d+)?)?(Z|[+-]\\d{2}:\\d{2})$">>,
                [{capture, none}]) =:= match andalso muse_time:parse(V) =/= nan of
        true -> ok;
        false -> {error, <<"Invalid ISO datetime">>}
    end.

uuid(V) ->
    case muse_ids:is_uuid(V) of
        true -> ok;
        false -> {error, <<"Invalid UUID">>}
    end.

attachments_owned(Owner, #{<<"kind">> := <<"email.send">>, <<"data">> := Data}) ->
    case [E || Id <- maps:get(<<"attachmentIds">>, Data, []),
               {error, _} = E <- [muse_files:get(Owner, Id)]] of
        [] -> ok;
        [E | _] -> E
    end;
attachments_owned(_, _) ->
    ok.

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
