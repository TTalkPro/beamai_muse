%% @doc Client of the Playwright browser worker (OpenMuse browser.ts,
%% integrations spec §7.2–§7.5). The worker itself is the unchanged Node
%% service in `sidecars/browser-worker`.
%%
%% Ownership records (`browsers`, `chat-browsers`, `browser-downloads`) are
%% written before the worker is contacted, so a lost response never orphans a
%% profile. Operations on one session are serialised with a `global` lock per
%% session id. Any worker non-2xx becomes 502 with the worker's message; an
%% unreachable worker is 503.
%%
%% Cancellation is process-based: a caller that is killed mid-request takes
%% its HTTP request with it.
-module(muse_browser).

-export([reachable/0, get/2, decorate/2,
         create/2, reopen/3, navigate/3, read/2, observe/3, observe_for_thread/3,
         close/2, preview/2, input/3, imports/2, console/2]).

-define(TIMEOUT, 45000).
-define(HEALTH_TTL, 15000).
-define(HEALTH_KEY, {?MODULE, health}).

-type owner() :: binary().
-type error() :: {error, {pos_integer(), binary()}}.

%% @doc Whether the configured worker answers `/health` (cached 15 s).
-spec reachable() -> boolean().
reachable() ->
    case muse_config:browser_configured() of
        false -> false;
        true ->
            Now = muse_time:now_ms(),
            case persistent_term:get(?HEALTH_KEY, undefined) of
                {At, Up} when Now - At < ?HEALTH_TTL -> Up;
                _ ->
                    Up = case beamai_http:request(get, <<(worker_url())/binary, "/health">>, [], <<>>,
                                                  #{timeout => 2000, connect_timeout => 2000}) of
                             {ok, _} -> true;
                             {error, _} -> false
                         end,
                    persistent_term:put(?HEALTH_KEY, {Now, Up}),
                    Up
            end
    end.

%% @doc The owned session record (ownership check).
-spec get(owner(), term()) -> {ok, map()} | error().
get(Owner, Id) ->
    case muse_ids:is_uuid(Id) andalso muse_store:get(Owner, <<"browsers">>, Id) of
        Session when is_map(Session) -> {ok, Session};
        _ -> {error, {404, <<"Browser session not found">>}}
    end.

%% @doc Add signed `consoleUrl` / `previewUrl`.
-spec decorate(owner(), map()) -> map().
decorate(Owner, #{<<"id">> := Id} = Session) ->
    Session#{<<"consoleUrl">> => muse_signing:sign(Owner, <<"/api/browsers/", Id/binary, "/console">>),
             <<"previewUrl">> => muse_signing:sign(Owner, <<"/api/browsers/", Id/binary, "/preview">>)}.

-spec create(owner(), binary()) -> {ok, map()} | error().
create(Owner, Url) ->
    Id = muse_ids:uuid(),
    _ = muse_store:put(Owner, <<"browsers">>, new_session(Id, Url)),
    reopen(Owner, Id, Url).

%% @doc Open (or re-open) the session at `Url` (default: its last URL).
-spec reopen(owner(), binary(), binary() | undefined) -> {ok, map()} | error().
reopen(Owner, Id, Url) ->
    serial(Id, fun() -> open_owned(Owner, Id, Url) end).

-spec navigate(owner(), binary(), binary()) -> {ok, map()} | error().
navigate(Owner, Id, Url) ->
    reopen(Owner, Id, Url).

%% @doc Page text: `#{url, title, text, truncated}`.
-spec read(owner(), binary()) -> {ok, map()} | error().
read(Owner, Id) ->
    serial(Id, fun() -> read_owned(Owner, Id) end).

%% @doc The task tool `read_web`: open `Url` in the task's browser (a new
%% one unless `ExistingId`) and read it.
-spec observe(owner(), binary(), binary() | undefined) -> {ok, map()} | error().
observe(Owner, Url, ExistingId) ->
    maybe
        {ok, Id} ?= case ExistingId of
                        undefined ->
                            maybe
                                {ok, #{<<"id">> := NewId}} ?= create(Owner, Url),
                                {ok, NewId}
                            end;
                        _ -> {ok, ExistingId}
                    end,
        serial(Id, fun() ->
                       maybe
                           ok ?= case ExistingId of
                                     undefined -> ok;
                                     _ -> ok_of(open_owned(Owner, Id, Url))
                                 end,
                           {ok, Page} ?= read_owned(Owner, Id),
                           {ok, Page#{<<"sessionId">> => Id}}
                       end
                   end)
    end.

%% @doc The chat tool `browse_web`: one browser profile per chat thread,
%% reserved before the worker is called; text capped at 30000 characters.
-spec observe_for_thread(owner(), binary(), binary()) -> {ok, map()} | error().
observe_for_thread(Owner, ThreadId, Url) ->
    Assoc = case muse_store:get(Owner, <<"chat-browsers">>, ThreadId) of
                undefined ->
                    case muse_store:insert_if_absent(Owner, <<"chat-browsers">>,
                                                     #{<<"id">> => ThreadId,
                                                       <<"sessionId">> => muse_ids:uuid()}) of
                        undefined -> muse_store:get(Owner, <<"chat-browsers">>, ThreadId);
                        Inserted -> Inserted
                    end;
                Existing ->
                    Existing
            end,
    case Assoc of
        #{<<"sessionId">> := Id} ->
            _ = muse_store:insert_if_absent(Owner, <<"browsers">>, new_session(Id, Url)),
            serial(Id, fun() ->
                           maybe
                               {ok, _} ?= open_owned(Owner, Id, Url),
                               {ok, #{<<"text">> := Text, <<"truncated">> := Trunc} = Page} ?= read_owned(Owner, Id),
                               Long = string:length(Text) > 30000,
                               {ok, Page#{<<"sessionId">> => Id,
                                          <<"text">> => case Long of
                                                            true -> string:slice(Text, 0, 30000);
                                                            false -> Text
                                                        end,
                                          <<"truncated">> => Trunc orelse Long}}
                           end
                       end);
        _ ->
            {error, {500, <<"Could not reserve the chat browser session">>}}
    end.

-spec close(owner(), binary()) -> {ok, map()} | error().
close(Owner, Id) ->
    serial(Id, fun() ->
                   maybe
                       {ok, _} ?= get(Owner, Id),
                       {ok, Payload} ?= request(post, session_path(Id, <<"/close">>), #{}),
                       save(Owner, Payload, Id)
                   end
               end).

%% @doc PNG screenshot bytes (not serialised).
-spec preview(owner(), binary()) -> {ok, binary()} | error().
preview(Owner, Id) ->
    maybe
        {ok, _} ?= get(Owner, Id),
        {ok, Png} ?= request(get, session_path(Id, <<"/screenshot">>), undefined),
        true ?= is_binary(Png) orelse {error, {502, <<"Browser request failed">>}},
        {ok, Png}
    end.

%% @doc Forward one whitelisted input (click/text/key/scroll); the worker
%% validates the shape.
-spec input(owner(), binary(), term()) -> {ok, map()} | error().
input(Owner, Id, Value) when is_map(Value) ->
    serial(Id, fun() ->
                   maybe
                       {ok, _} ?= get(Owner, Id),
                       {ok, Payload} ?= request(post, session_path(Id, <<"/input">>), Value),
                       save(Owner, Payload, Id)
                   end
               end);
input(_Owner, _Id, _Value) ->
    {error, {422, <<"A JSON object is required for browser input">>}}.

%% @doc Import the session's PDF downloads into Documents (once each).
-spec imports(owner(), binary()) -> {ok, #{binary() => list()}} | error().
imports(Owner, Id) ->
    serial(Id, fun() -> imports_owned(Owner, Id) end).

%% @doc The take-control console page (byte-identical to OpenMuse).
-spec console(owner(), binary()) -> {ok, binary()} | error().
console(Owner, Id) ->
    maybe
        {ok, _} ?= get(Owner, Id),
        Preview = muse_signing:sign(Owner, <<"/api/browsers/", Id/binary, "/preview">>),
        {ok, Template} = file:read_file(filename:join(code:priv_dir(muse_integ), "browser-console.html")),
        Literal = binary:replace(muse_json:encode(Preview), <<"<">>, <<"\\u003c">>, [global]),
        {ok, binary:replace(Template, <<"\"__PREVIEW_URL__\"">>, Literal)}
    end.

%% Internal

new_session(Id, Url) ->
    #{<<"id">> => Id, <<"url">> => Url, <<"title">> => <<"New browser session">>,
      <<"status">> => <<"idle">>, <<"updatedAt">> => muse_time:now_iso()}.

open_owned(Owner, Id, Url) ->
    maybe
        {ok, Session} ?= get(Owner, Id),
        Target = case Url of
                     undefined -> maps:get(<<"url">>, Session);
                     _ -> Url
                 end,
        case request(post, <<"/sessions">>, #{<<"id">> => Id, <<"url">> => Target}) of
            {ok, Payload} ->
                save(Owner, Payload, Id);
            {error, _} = Error ->
                _ = save(Owner, Session#{<<"url">> => Target, <<"status">> => <<"error">>,
                                         <<"updatedAt">> => muse_time:now_iso()}, Id),
                Error
        end
    end.

read_owned(Owner, Id) ->
    maybe
        {ok, Session} ?= get(Owner, Id),
        {ok, #{<<"url">> := U, <<"title">> := T, <<"text">> := Text, <<"truncated">> := Tr}} ?=
            check_read(request(get, session_path(Id, <<"/read">>), undefined)),
        {ok, _} ?= save(Owner, Session#{<<"url">> => U, <<"title">> => T, <<"status">> => <<"active">>,
                                        <<"updatedAt">> => muse_time:now_iso()}, Id),
        {ok, #{<<"url">> => U, <<"title">> => T, <<"text">> => Text, <<"truncated">> => Tr}}
    end.

check_read({ok, #{<<"url">> := U, <<"title">> := T, <<"text">> := Text, <<"truncated">> := Tr} = R})
  when is_binary(U), is_binary(T), is_binary(Text), is_boolean(Tr) ->
    case string:length(T) =< 300 andalso string:length(Text) =< 100000 of
        true -> {ok, R};
        false -> invalid_payload()
    end;
check_read({ok, _}) -> invalid_payload();
check_read(Error) -> Error.

imports_owned(Owner, Id) ->
    maybe
        {ok, _} ?= get(Owner, Id),
        {ok, #{<<"downloads">> := Downloads, <<"failures">> := Failures}} ?=
            check_downloads(request(get, session_path(Id, <<"/downloads">>), undefined)),
        {ok, Files} ?= import_downloads(Owner, Id, Downloads, []),
        {ok, #{<<"files">> => Files, <<"failures">> => Failures}}
    end.

check_downloads({ok, #{<<"downloads">> := D, <<"failures">> := F}} = R) when is_list(D), is_list(F) -> R;
check_downloads({ok, _}) -> invalid_payload();
check_downloads(Error) -> Error.

import_downloads(_Owner, _Id, [], Acc) ->
    {ok, lists:reverse(Acc)};
import_downloads(Owner, Id, [#{<<"id">> := Did, <<"name">> := Name} | Rest], Acc) ->
    Result = case muse_store:get(Owner, <<"browser-downloads">>, Did) of
                 #{<<"fileId">> := FileId} ->
                     maybe
                         {ok, Known} ?= muse_files:get(Owner, FileId),
                         {ok, muse_files:signed(Owner, Known)}
                     end;
                 undefined ->
                     maybe
                         {ok, Bytes} ?= request(get, session_path(Id, <<"/downloads/",
                                                                     (muse_signing:encode_uri_component(Did))/binary>>),
                                                undefined),
                         true ?= is_binary(Bytes) orelse invalid_payload(),
                         {ok, #{<<"id">> := NewId} = Imported} ?=
                             muse_files:import(Owner, Name, Bytes, <<"Browser · "/utf8, Id/binary>>),
                         _ = muse_store:put(Owner, <<"browser-downloads">>,
                                            #{<<"id">> => Did, <<"fileId">> => NewId}),
                         {ok, Imported}
                     end
             end,
    case Result of
        {ok, File} -> import_downloads(Owner, Id, Rest, [File | Acc]);
        Error -> Error
    end;
import_downloads(_, _, _, _) ->
    invalid_payload().

save(Owner, #{<<"id">> := Id, <<"title">> := T, <<"url">> := U, <<"status">> := S,
              <<"updatedAt">> := At}, Expected)
  when is_binary(Id), is_binary(T), is_binary(U), is_binary(At) ->
    case lists:member(S, [<<"idle">>, <<"active">>, <<"closed">>, <<"error">>]) of
        false -> invalid_payload();
        true when Id =/= Expected ->
            {error, {502, <<"Browser worker returned a different session">>}};
        true ->
            Session = #{<<"id">> => Id, <<"title">> => T, <<"url">> => U, <<"status">> => S,
                        <<"updatedAt">> => At},
            _ = muse_store:put(Owner, <<"browsers">>, Session),
            {ok, decorate(Owner, Session)}
    end;
save(_, _, _) ->
    invalid_payload().

invalid_payload() ->
    {error, {502, <<"Browser request failed">>}}.

ok_of({ok, _}) -> ok;
ok_of(Error) -> Error.

session_path(Id, Suffix) ->
    <<"/sessions/", (muse_signing:encode_uri_component(Id))/binary, Suffix/binary>>.

request(Method, Path, Body) ->
    case muse_config:browser_configured() of
        false ->
            {error, {503, <<"Browser worker is not configured. Start it using the setup guide.">>}};
        true ->
            Headers = [{<<"authorization">>, <<"Bearer ", (muse_config:get(worker_token))/binary>>},
                       {<<"content-type">>, <<"application/json">>}],
            Payload = case Body of
                          undefined -> <<>>;
                          _ -> muse_json:encode(Body)
                      end,
            case beamai_http:request(Method, <<(worker_url())/binary, Path/binary>>, Headers, Payload,
                                     #{timeout => ?TIMEOUT}) of
                {ok, Response} ->
                    {ok, Response};
                {error, {http_error, _Status, ErrBody}} ->
                    {error, {502, worker_message(ErrBody)}};
                {error, {http_error, _Status, ErrBody, _Headers}} ->
                    {error, {502, worker_message(ErrBody)}};
                {error, _} ->
                    {error, {503, <<"Browser worker is unavailable. Check that its container is running.">>}}
            end
    end.

worker_message(#{<<"error">> := #{<<"message">> := Msg}}) when is_binary(Msg) -> Msg;
worker_message(Bin) when is_binary(Bin) ->
    case muse_json:decode(Bin) of
        {ok, #{<<"error">> := #{<<"message">> := Msg}}} when is_binary(Msg) -> Msg;
        _ -> <<"Browser request failed">>
    end;
worker_message(_) ->
    <<"Browser request failed">>.

worker_url() ->
    muse_config:get(worker_url).

%% One operation at a time per session (OpenMuse's per-id promise queue).
serial(Id, Fun) ->
    global:trans({{?MODULE, Id}, self()}, Fun, [node()], infinity).
