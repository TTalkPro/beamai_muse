%% @doc HTTP helpers shared by the JSON API handlers (integrations spec §2.2–§2.3).
%%
%% Route functions return one of:
%% - `{Status, Json}`                      JSON response
%% - `{raw, Status, Headers, Body}`        any other response
%% - `{error, {Status, Message}}`          `{"error": Message}`
%% - `{error, {outcome_unknown | internal, Message}}` (Google) and any other
%%   `{error, _}`: 502 with the generic text, logging only the error class.
-module(muse_http).

-export([reply/2, error_reply/3, json_body/1, json_body/2, read_body/1, query/2, owner/1,
         generic_error/0, max_body/0, body/2, body/3, class/1]).

-define(MAX_BODY, 12582912).
-define(GENERIC, <<"Request failed. Check the server setup and try again.">>).

-spec max_body() -> pos_integer().
max_body() -> ?MAX_BODY.

-spec generic_error() -> binary().
generic_error() -> ?GENERIC.

%% @doc Send a route result.
-spec reply(term(), cowboy_req:req()) -> cowboy_req:req().
reply({raw, Status, Headers, Body}, Req) ->
    cowboy_req:reply(Status, Headers, Body, Req);
reply({error, {Status, Msg}}, Req) when is_integer(Status), is_binary(Msg) ->
    error_reply(Status, Msg, Req);
reply({error, {outcome_unknown, _}}, Req) ->
    generic(outcome_unknown, Req);
reply({error, {internal, _}}, Req) ->
    generic(internal, Req);
reply({error, Reason}, Req) ->
    generic(Reason, Req);
reply({Status, Json}, Req) when is_integer(Status) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, muse_json:encode(Json), Req).

-spec error_reply(pos_integer(), binary(), cowboy_req:req()) -> cowboy_req:req().
error_reply(Status, Msg, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>},
                     muse_json:encode(#{<<"error">> => Msg}), Req).

%% Raw stack traces and token-bearing upstream responses never reach clients.
generic(Reason, Req) ->
    logger:error("[OpenMuse] ~0p", [class(Reason)]),
    error_reply(502, ?GENERIC, Req).

%% @doc The category of an error reason, safe to log: reasons and stack
%% arguments can hold the request (cookies, Authorization) or bodies.
-spec class(term()) -> term().
class(T) when is_tuple(T), tuple_size(T) > 0 -> element(1, T);
class(A) -> A.

%% @doc Read and decode a JSON body. Invalid JSON is 400 "Invalid request
%% data"; an empty body decodes to `undefined` (the schema then reports it).
-spec json_body(cowboy_req:req()) -> {ok, term(), cowboy_req:req()} | {error, {400 | 413, binary()}, cowboy_req:req()}.
json_body(Req) ->
    json_body(Req, strict).

%% @doc `allow_empty` treats an empty body as `#{}` (POST /browsers/:id/reopen).
-spec json_body(cowboy_req:req(), strict | allow_empty) ->
    {ok, term(), cowboy_req:req()} | {error, {400 | 413, binary()}, cowboy_req:req()}.
json_body(Req0, Mode) ->
    case read_body(Req0) of
        {ok, <<>>, Req} when Mode =:= allow_empty -> {ok, #{}, Req};
        {ok, <<>>, Req} -> {error, {400, <<"Invalid request data">>}, Req};
        {ok, Body, Req} ->
            case muse_json:decode(Body) of
                {ok, Json} -> {ok, Json, Req};
                {error, _} -> {error, {400, <<"Invalid request data">>}, Req}
            end;
        Error -> Error
    end.

%% @doc The whole body, at most 12 MiB.
-spec read_body(cowboy_req:req()) -> {ok, binary(), cowboy_req:req()} | {error, {413, binary()}, cowboy_req:req()}.
read_body(Req) ->
    read_body(Req, <<>>).

read_body(Req0, Acc) ->
    {More, Data, Req} = cowboy_req:read_body(Req0, #{length => 1048576, period => 30000}),
    Body = <<Acc/binary, Data/binary>>,
    case byte_size(Body) > ?MAX_BODY of
        true -> {error, {413, <<"Request is too large; PDFs must be 10 MB or smaller">>}, Req};
        false ->
            case More of
                ok -> {ok, Body, Req};
                more -> read_body(Req, Body)
            end
    end.

-spec query(binary(), cowboy_req:req()) -> binary() | undefined.
query(Name, Req) ->
    case lists:keyfind(Name, 1, cowboy_req:parse_qs(Req)) of
        {_, true} -> <<>>;
        {_, V} -> V;
        false -> undefined
    end.

%% @doc The authenticated owner stored by muse_api.
-spec owner(cowboy_req:req()) -> binary().
owner(Req) ->
    maps:get(muse_owner, Req).

%% @doc Read a JSON body and validate it (zod errors become 422).
-spec body(cowboy_req:req(), muse_validate:schema()) ->
    {ok, term(), cowboy_req:req()} | {error, {pos_integer(), binary()}, cowboy_req:req()}.
body(Req, Schema) ->
    body(Req, Schema, strict).

-spec body(cowboy_req:req(), muse_validate:schema(), strict | allow_empty) ->
    {ok, term(), cowboy_req:req()} | {error, {pos_integer(), binary()}, cowboy_req:req()}.
body(Req0, Schema, Mode) ->
    case json_body(Req0, Mode) of
        {ok, Json, Req} ->
            case muse_validate:parse(Schema, Json) of
                {ok, V} -> {ok, V, Req};
                {error, E} -> {error, E, Req}
            end;
        Error ->
            Error
    end.
