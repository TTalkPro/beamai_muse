%% @doc `/api/computer/*` (OpenMuse computer-routes.ts; integrations spec
%% §6.9) over muse_computer.
%%
%% The `/desktop*` routes serve the desktop variant of the Docker computer
%% (COMPUTER_DESKTOP=true, muse_computer_desktop); without it they are plain
%% 404s. OpenMuse's E2B desktop is not supported, so there is no stream URL:
%% `GET /desktop` returns the status, screen size and latest screenshot. The
%% screenshot is also reachable through a signed URL (for `<img>` tags);
%% `?receipt=` names the action whose screenshot the client expects, and
%% `?live=1` takes a fresh frame for the page's live view.
%%
%% `POST /commands` runs in the cowboy request process, which is passed as
%% the cancel process: a client that disconnects kills it and so stops the
%% command (OpenMuse's request abort signal).
%%
%% Computer pool (not in OpenMuse, whose routes serve the owner's single
%% computer): every route needs `?computer=<id>` or `?thread=<threadId>`
%% (400 without, 404 for another owner's computer or thread). The signed
%% screenshot URLs carry the computer parameter.
-module(muse_api_computer).

-export([handle/3]).

-spec handle(binary(), [binary()], cowboy_req:req()) -> next | {term(), cowboy_req:req()}.
handle(M, [<<"api">>, <<"computer">> | Rest], Req) ->
    case Rest of
        [<<"desktop">> | _] ->
            case muse_computer_desktop:enabled() of
                true -> with_ref(M, Rest, Req);
                false -> next
            end;
        _ ->
            with_ref(M, Rest, Req)
    end;
handle(_, _, _) ->
    next.

%% The computer is named by `?computer=<id>` (one of the owner's computers)
%% or `?thread=<threadId>` (that conversation's computer, created when
%% missing). There is no default computer.
with_ref(M, Rest, Req) ->
    Owner = muse_http:owner(Req),
    case {muse_http:query(<<"computer">>, Req), muse_http:query(<<"thread">>, Req)} of
        {undefined, undefined} ->
            {{error, {400, <<"Choose a computer: ?computer=<id> or ?thread=<threadId>">>}}, Req};
        {undefined, Tid} ->
            case muse_threads:get(Owner, Tid) of
                {ok, _} -> route(M, Rest, muse_computer:ensure(Owner, <<"thread:", Tid/binary>>), Req);
                {error, _} -> {{error, {404, <<"Thread not found">>}}, Req}
            end;
        {Id, _} ->
            case muse_computers:get(Owner, Id) of
                undefined -> {{error, {404, <<"Computer not found">>}}, Req};
                _ -> route(M, Rest, muse_computer:ref_of(Owner, Id), Req)
            end
    end.

route(<<"GET">>, [], O, Req) ->
    {{200, muse_computer:snapshot(O)}, Req};
route(<<"POST">>, [<<"start">>], O, Req) ->
    {ok_200(muse_computer:start(O)), Req};
route(<<"POST">>, [<<"stop">>], O, Req) ->
    {ok_200(muse_computer:stop(O)), Req};
route(<<"POST">>, [<<"commands">>], O, Req) ->
    body(Req, muse_computer:command_schema(),
         fun(Args) -> ok_200(muse_computer:execute(O, Args, #{cancel => self()})) end);
route(<<"GET">>, [<<"desktop">>], O, Req) ->
    {ok_200(muse_computer_desktop:status(O)), Req};
route(<<"POST">>, [<<"desktop">>, <<"actions">>], O, Req0) ->
    %% The body is parsed before the desktop checks, as in OpenMuse. The
    %% response omits the image.
    case muse_http:json_body(Req0) of
        {ok, Body, Req} ->
            {case muse_computer_desktop:desktop_action(O, Body) of
                 {ok, #{receipt := R, width := W, height := H, warning := Warning}} ->
                     Base = #{<<"receipt">> => R, <<"width">> => W, <<"height">> => H},
                     {200, case Warning of
                               undefined -> Base;
                               _ -> Base#{<<"warning">> => Warning}
                           end};
                 Error ->
                     Error
             end, Req};
        {error, E, Req} -> {{error, E}, Req}
    end;
route(<<"GET">>, [<<"desktop">>, <<"screenshot">>], O, Req) ->
    Shot = case muse_http:query(<<"live">>, Req) of
               <<"1">> -> muse_computer_desktop:frame(O);
               _ -> muse_computer_desktop:latest_screenshot(O, muse_http:query(<<"receipt">>, Req))
           end,
    {case Shot of
         {ok, #{mime_type := Mime, bytes := Bytes}} ->
             {raw, 200, #{<<"content-type">> => Mime, <<"cache-control">> => <<"no-store">>}, Bytes};
         Error ->
             Error
     end, Req};
route(<<"GET">>, [<<"files">>], O, Req) ->
    {ok_200(case muse_http:query(<<"path">>, Req) of
                undefined -> muse_computer:list(O);
                Path -> muse_computer:list(O, Path)
            end), Req};
route(<<"POST">>, [<<"files">>, <<"read">>], O, Req) ->
    body(Req, muse_computer:path_schema(),
         fun(#{<<"path">> := P}) -> ok_200(muse_computer:read(O, P)) end);
route(<<"POST">>, [<<"files">>, <<"write">>], O, Req) ->
    body(Req, muse_computer:write_schema(),
         fun(#{<<"path">> := P, <<"text">> := T}) -> ok_200(muse_computer:write(O, P, T)) end);
route(<<"POST">>, [<<"files">>, <<"mkdir">>], O, Req) ->
    body(Req, muse_computer:path_schema(),
         fun(#{<<"path">> := P}) -> ok_200(muse_computer:mkdir(O, P)) end);
route(<<"POST">>, [<<"files">>, <<"import">>], O, Req) ->
    body(Req, muse_computer:import_schema(),
         fun(#{<<"path">> := P, <<"fileId">> := F}) -> ok_200(muse_computer:import_pdf(O, P, F)) end);
route(<<"POST">>, [<<"files">>, <<"export">>], O, Req) ->
    body(Req, muse_computer:path_schema(),
         fun(#{<<"path">> := P}) -> created(muse_computer:export_pdf(O, P)) end);
route(_, _, _, _) ->
    next.

body(Req0, Schema, Fun) ->
    case muse_http:body(Req0, Schema) of
        {ok, V, Req} -> {Fun(V), Req};
        {error, E, Req} -> {{error, E}, Req}
    end.

ok_200({ok, V}) -> {200, V};
ok_200({error, E}) -> {error, E}.

created({ok, V}) -> {201, V};
created({error, E}) -> {error, E}.
