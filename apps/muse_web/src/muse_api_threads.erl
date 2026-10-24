%% @doc Conversation threads (new; replaces CopilotKit Intelligence's thread
%% API, designs/05-web-ui.md §2): list/create side chats, rename, archive,
%% restore, read messages, search.
-module(muse_api_threads).

-export([handle/3]).

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(<<"GET">>, [<<"api">>, <<"threads">>], Req) ->
    Owner = muse_http:owner(Req),
    {{200, case muse_http:query(<<"q">>, Req) of
               Q when is_binary(Q), Q =/= <<>> -> muse_threads:search(Owner, Q, 20);
               _ -> muse_threads:list(Owner)
           end}, Req};
handle(<<"POST">>, [<<"api">>, <<"threads">>], Req0) ->
    case muse_http:json_body(Req0, allow_empty) of
        {ok, Body, Req} when is_map(Body) ->
            {created(muse_threads:create_side(muse_http:owner(Req), maps:get(<<"title">>, Body, undefined))), Req};
        {ok, _, Req} -> {{error, {422, <<"Invalid input: expected object">>}}, Req};
        {error, E, Req} -> {{error, E}, Req}
    end;
handle(<<"POST">>, [<<"api">>, <<"threads">>, Id], Req0) ->
    Schema = {object, [{<<"title">>, {optional, {string, #{}}}},
                       {<<"archived">>, {optional, boolean}}]},
    case muse_http:body(Req0, Schema) of
        {ok, Patch, Req} -> {ok_200(update(muse_http:owner(Req), Id, Patch)), Req};
        {error, E, Req} -> {{error, E}, Req}
    end;
handle(<<"GET">>, [<<"api">>, <<"threads">>, Id, <<"messages">>], Req) ->
    {ok_200(muse_threads:messages(muse_http:owner(Req), Id)), Req};
handle(_, _, _) ->
    next.

update(Owner, Id, Patch) ->
    Steps = [fun(_) -> case maps:find(<<"title">>, Patch) of
                           {ok, T} -> muse_threads:rename(Owner, Id, T);
                           error -> muse_threads:get(Owner, Id)
                       end end,
             fun(_) -> case maps:find(<<"archived">>, Patch) of
                           {ok, true} -> muse_threads:archive(Owner, Id);
                           {ok, false} -> muse_threads:restore(Owner, Id);
                           error -> muse_threads:get(Owner, Id)
                       end end],
    lists:foldl(fun(Step, {ok, _} = Acc) -> Step(Acc); (_, Error) -> Error end, {ok, undefined}, Steps).

ok_200({ok, V}) -> {200, V};
ok_200({error, E}) -> {error, E}.

created({ok, V}) -> {201, V};
created({error, E}) -> {error, E}.
