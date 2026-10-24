%% @doc `/api/agent/*` (OpenMuse engine/routes.ts, engine spec §12.1).
-module(muse_api_agent).

-export([handle/3]).

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(M, [<<"api">>, <<"agent">> | Rest], Req) ->
    route(M, Rest, muse_http:owner(Req), Req);
handle(_, _, _) ->
    next.

route(<<"GET">>, [], O, Req) ->
    {ok_200(muse_agent_service:snapshot(O)), Req};
route(<<"POST">>, [<<"tasks">>], O, Req) ->
    {object, Fields} = muse_task:create_schema(),
    body(Req, {object, Fields ++ [{<<"requestId">>, {optional, {string, #{min => 1, max => 200}}}}]},
         fun(Input) ->
                 created(muse_agent_service:create_task(O, maps:remove(<<"requestId">>, Input),
                                                        maps:get(<<"requestId">>, Input, undefined), false))
         end);
route(<<"GET">>, [<<"tasks">>, Id], O, Req) ->
    {ok_200(muse_agent_service:detail(O, Id)), Req};
route(<<"POST">>, [<<"tasks">>, Id, <<"control">>], O, Req) ->
    body(Req, {object, [{<<"action">>, {enum, [<<"pause">>, <<"resume">>, <<"cancel">>, <<"retry">>]}}]},
         fun(#{<<"action">> := A}) -> ok_200(muse_agent_service:control(O, Id, A)) end);
route(<<"POST">>, [<<"tasks">>, Id, <<"input">>], O, Req) ->
    body(Req, muse_task:answer_schema(),
         fun(#{<<"answer">> := Answer} = B) ->
                 ok_200(muse_agent_service:answer(O, Id, Answer, maps:get(<<"fields">>, B, undefined)))
         end);
route(<<"POST">>, [<<"goals">>], O, Req) ->
    raw_body(Req, fun(Raw) -> created(muse_agent_service:create_goal(O, Raw)) end);
route(<<"POST">>, [<<"goals">>, Id], O, Req) ->
    body(Req, muse_task:goal_update_schema(), fun(Patch) -> ok_200(muse_agent_service:update_goal(O, Id, Patch)) end);
route(<<"POST">>, [<<"goals">>, Id, <<"milestones">>, Milestone], O, Req) ->
    body(Req, {object, [{<<"done">>, boolean}]},
         fun(#{<<"done">> := Done}) -> ok_200(muse_agent_service:set_milestone_done(O, Id, Milestone, Done)) end);
route(<<"POST">>, [<<"monitors">>], O, Req) ->
    raw_body(Req, fun(Raw) -> created(muse_monitors:create(O, Raw, undefined)) end);
route(<<"POST">>, [<<"monitors">>, Id, <<"control">>], O, Req) ->
    body(Req, {object, [{<<"action">>, {enum, [<<"pause">>, <<"resume">>, <<"stop">>, <<"check">>]}}]},
         fun(#{<<"action">> := A}) -> ok_200(muse_monitors:control(O, Id, A)) end);
route(<<"POST">>, [<<"ideas">>, <<"refresh">>], O, Req) ->
    {ok_200(muse_ideas:refresh(O)), Req};
route(<<"POST">>, [<<"ideas">>, Id], O, Req) ->
    body(Req, {object, [{<<"action">>, {enum, [<<"accept">>, <<"dismiss">>]}},
                        {<<"prompt">>, {optional, {string, #{trim => true, min => 1, max => 12000}}}}]},
         fun(#{<<"action">> := A} = B) -> ok_200(muse_ideas:decide(O, Id, A, maps:get(<<"prompt">>, B, undefined))) end);
route(<<"POST">>, [<<"memories">>], O, Req) ->
    raw_body(Req, fun(Raw) -> created(muse_agent_service:add_memory(O, Raw)) end);
route(<<"POST">>, [<<"memories">>, Id], O, Req) ->
    raw_body(Req, fun(Raw) -> ok_200(muse_agent_service:update_memory(O, Id, Raw)) end);
route(<<"POST">>, [<<"memories">>, Id, <<"forget">>], O, Req) ->
    {case muse_agent_service:forget_memory(O, Id) of
         ok -> {200, #{<<"ok">> => true}};
         E -> E
     end, Req};
route(<<"POST">>, [<<"identity">>], O, Req) ->
    raw_body(Req, fun(Raw) -> ok_200(muse_agent_service:set_identity(O, Raw)) end);
route(<<"GET">>, [<<"notifications">>], O, Req) ->
    {{200, muse_agent_service:notifications(O)}, Req};
route(<<"POST">>, [<<"notifications">>, Id, <<"read">>], O, Req) ->
    {ok_200(muse_agent_service:read_notification(O, Id)), Req};
route(<<"POST">>, [<<"sample-page">>], O, Req) ->
    case muse_config:get(mode) of
        sample ->
            body(Req, {object, [{<<"text">>, {string, #{max => 100000}}}]},
                 fun(#{<<"text">> := Text}) ->
                         ok = muse_agent_service:set_sample_page(O, Text),
                         {200, #{<<"ok">> => true}}
                 end);
        live ->
            {{error, {404, <<"Not found">>}}, Req}
    end;
route(_, _, _, _) ->
    next.

body(Req0, Schema, Fun) ->
    case muse_http:body(Req0, Schema) of
        {ok, V, Req} -> {Fun(V), Req};
        {error, E, Req} -> {{error, E}, Req}
    end.

%% Services that validate their own input get the decoded JSON as is.
raw_body(Req0, Fun) ->
    case muse_http:json_body(Req0) of
        {ok, V, Req} -> {Fun(V), Req};
        {error, E, Req} -> {{error, E}, Req}
    end.

ok_200({ok, V}) -> {200, V};
ok_200({error, E}) -> {error, E}.

created({ok, V}) -> {201, V};
created({error, E}) -> {error, E}.
