%% @doc The browser sessions (OpenMuse browser.ts, integrations spec
%% §7.2–§7.5) over the per-user Chrome container (muse_browser_docker; the
%% Playwright worker is gone, see docs/DIFFERENCES.md).
%%
%% Ownership records (`browsers`, `chat-browsers`, `browser-downloads`) are
%% written before the browser is contacted, so a lost response never
%% orphans a session. Operations on one session are serialised with a
%% `global` lock per session id. A browser error becomes 502 with its
%% message; a browser that cannot be reached or started is 503.
%%
%% Each session is one Chrome window with one tab in its owner's container;
%% the owner's sessions share one Chrome profile (cookies, sign-ins).
%% A chat thread has one session (`chat-browsers`: thread id -> session
%% id), shared by `browse_web` and `request_takeover`; `thread_of/2` maps a
%% session back to its thread for the console's "回到对话" link.
%%
%% The transport is a module with `call/3` (app env `browser_transport`,
%% default muse_browser_docker; tests use a fake): one request map
%% (`op`, `session`, ...) to the container's browserd, `{ok, Result}` or
%% `{error, {Status, Message}}`.
%%
%% Cancellation is process-based: a caller that is killed mid-request takes
%% its `docker exec` with it.
-module(muse_browser).

-export([reachable/0, get/2, decorate/2,
         create/2, create/3, reopen/3, navigate/3, read/2, observe/3, observe/4, observe_for_thread/3,
         open_for_thread/3, read_for_thread/2, thread_of/2, close/2, preview/2, input/3, input/4,
         imports/2, console/2, vnc/2, scope_of/2]).

-callback call(Owner :: binary(), Request :: map(), TimeoutMs :: pos_integer()) ->
    {ok, term()} | {error, {pos_integer(), binary()}}.

-define(TIMEOUT, 45000).
-define(OPEN_TIMEOUT, 60000).
%% browserd's SESSION_CLOSED message (kept from the worker): the session has
%% no window, e.g. after the container or Chrome restarted.
-define(SESSION_CLOSED, <<"Open this browser session before using its console.">>).
-define(HEALTH_TTL, 15000).
-define(HEALTH_KEY, {?MODULE, health}).
-define(NOT_CONFIGURED, <<"The browser is not configured. Set BROWSER_ENABLED=true and build the "
                          "browser image (make browser-image).">>).

-type owner() :: binary().
-type error() :: {error, {pos_integer(), binary()}}.

%% @doc Whether the browser can be used: BROWSER_ENABLED and the browser
%% image present in Docker (cached 15 s). Containers start on first use.
-spec reachable() -> boolean().
reachable() ->
    case muse_config:browser_configured() of
        false -> false;
        true ->
            Now = muse_time:now_ms(),
            case persistent_term:get(?HEALTH_KEY, undefined) of
                {At, Up} when Now - At < ?HEALTH_TTL -> Up;
                _ ->
                    Up = case transport() of
                             muse_browser_docker ->
                                 Image = muse_browser_docker:image(),
                                 case muse_docker:run(muse_docker:image_id_args(Image), #{timeout => 5000}) of
                                     #{exit_code := 0} -> true;
                                     _ -> false
                                 end;
                             _ -> true
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
    create(Owner, Url, undefined).

%% @doc `create/2` for a computer scope (`task:<id>` or `thread:<id>`,
%% muse_task_model:computer_scope/2): while that scope has a desktop
%% computer the session runs there (muse_browser_docker, Placement).
-spec create(owner(), binary(), binary() | undefined) -> {ok, map()} | error().
create(Owner, Url, Scope) ->
    Id = muse_ids:uuid(),
    _ = muse_store:put(Owner, <<"browsers">>, new_session(Id, Url)),
    place(Owner, Id, Scope),
    reopen(Owner, Id, Url).

%% @doc The computer scope of the session: the one it was created for, else
%% its conversation's (`thread:<id>`), else undefined (API and monitor
%% sessions, which stay in the owner's browser container).
-spec scope_of(owner(), binary()) -> binary() | undefined.
scope_of(Owner, Id) ->
    case muse_store:get(Owner, <<"browser-placement">>, Id) of
        #{<<"scope">> := Scope} when is_binary(Scope) -> Scope;
        _ ->
            case thread_of(Owner, Id) of
                {ok, ThreadId} -> <<"thread:", ThreadId/binary>>;
                undefined -> undefined
            end
    end.

place(_Owner, _Id, undefined) ->
    ok;
place(Owner, Id, Scope) ->
    Place = case muse_store:get(Owner, <<"browser-placement">>, Id) of
                P when is_map(P) -> P;
                _ -> #{<<"id">> => Id}
            end,
    _ = Place =:= Place#{<<"scope">> => Scope}
        orelse muse_store:put(Owner, <<"browser-placement">>, Place#{<<"scope">> => Scope}),
    ok.

%% @doc Open (or re-open) the session at `Url` (default: its last URL).
-spec reopen(owner(), binary(), binary() | undefined) -> {ok, map()} | error().
reopen(Owner, Id, Url) ->
    serial(Id, fun() -> open_owned(Owner, Id, Url) end).

-spec navigate(owner(), binary(), binary()) -> {ok, map()} | error().
navigate(Owner, Id, Url) ->
    reopen(Owner, Id, Url).

%% @doc The page as Markdown (WebChat's extractor): `#{url, title, text,
%% truncated}`, text at most 100000 characters.
-spec read(owner(), binary()) -> {ok, map()} | error().
read(Owner, Id) ->
    serial(Id, fun() -> read_owned(Owner, Id) end).

%% @doc The task tool `read_web`: open `Url` in the task's browser (a new
%% one unless `ExistingId`) and read it.
-spec observe(owner(), binary(), binary() | undefined) -> {ok, map()} | error().
observe(Owner, Url, ExistingId) ->
    observe(Owner, Url, ExistingId, undefined).

%% @doc `observe/3` for a task's computer scope (see create/3).
-spec observe(owner(), binary(), binary() | undefined, binary() | undefined) -> {ok, map()} | error().
observe(Owner, Url, ExistingId, Scope) ->
    maybe
        {ok, Id} ?= case ExistingId of
                        undefined ->
                            maybe
                                {ok, #{<<"id">> := NewId}} ?= create(Owner, Url, Scope),
                                {ok, NewId}
                            end;
                        _ -> place(Owner, ExistingId, Scope), {ok, ExistingId}
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

%% @doc The chat tool `browse_web`: one browser session per chat thread,
%% reserved before the browser is called; text (the page as Markdown)
%% capped at 30000 characters.
-spec observe_for_thread(owner(), binary(), binary()) -> {ok, map()} | error().
observe_for_thread(Owner, ThreadId, Url) ->
    maybe
        {ok, Id} ?= thread_session(Owner, ThreadId, Url),
        serial(Id, fun() ->
                       maybe
                           {ok, _} ?= open_owned(Owner, Id, Url),
                           chat_page(Owner, Id)
                       end
                   end)
    end.

%% @doc The chat tool `read_current_page` (not in OpenMuse): read the page
%% the thread's browser shows now, without opening or reloading anything,
%% e.g. the result of what the user did after `request_takeover`. Only a
%% session whose window is gone is re-opened, at its last URL.
-spec read_for_thread(owner(), binary()) -> {ok, map()} | error().
read_for_thread(Owner, ThreadId) ->
    case muse_store:get(Owner, <<"chat-browsers">>, ThreadId) of
        #{<<"sessionId">> := Id} -> serial(Id, fun() -> chat_page(Owner, Id) end);
        _ -> {error, {422, <<"This conversation has no browser page yet; use browse_web with a url.">>}}
    end.

%% The session's page for the chat: text capped at 30000 characters.
chat_page(Owner, Id) ->
    maybe
        {ok, #{<<"text">> := Text, <<"truncated">> := Trunc} = Page} ?= read_owned(Owner, Id),
        Long = string:length(Text) > 30000,
        {ok, Page#{<<"sessionId">> => Id,
                   <<"text">> => case Long of
                                     true -> string:slice(Text, 0, 30000);
                                     false -> Text
                                 end,
                   <<"truncated">> => Trunc orelse Long}}
    end.

%% @doc The chat tool `request_takeover` (not in OpenMuse): make sure the
%% thread's browser session exists and has its window, so the user can act
%% in it. With `Url` the session goes there; without one it stays on its
%% current page (re-opened at its last URL only if its window is gone), and
%% a thread that never browsed needs a `Url`. Returns the session.
-spec open_for_thread(owner(), binary(), binary() | undefined) -> {ok, map()} | error().
open_for_thread(Owner, ThreadId, undefined) ->
    case muse_store:get(Owner, <<"chat-browsers">>, ThreadId) of
        #{<<"sessionId">> := Id} ->
            maybe
                {ok, _} ?= get(Owner, Id),
                {ok, _} ?= serial(Id, fun() -> preview(Owner, Id) end),
                {ok, Session} ?= get(Owner, Id),
                {ok, decorate(Owner, Session)}
            end;
        _ ->
            {error, {422, <<"This conversation has no browser page yet; pass the url to open.">>}}
    end;
open_for_thread(Owner, ThreadId, Url) ->
    maybe
        {ok, Id} ?= thread_session(Owner, ThreadId, Url),
        serial(Id, fun() -> open_owned(Owner, Id, Url) end)
    end.

%% @doc The chat thread whose browser session `Id` is, if any.
-spec thread_of(owner(), binary()) -> {ok, binary()} | undefined.
thread_of(Owner, Id) ->
    case [T || #{<<"id">> := T, <<"sessionId">> := S} <- muse_store:list(Owner, <<"chat-browsers">>), S =:= Id] of
        [ThreadId | _] -> {ok, ThreadId};
        [] -> undefined
    end.

%% @doc Close the session's window; the record stays, `closed`, at its
%% last URL (a later open re-opens it there).
-spec close(owner(), binary()) -> {ok, map()} | error().
close(Owner, Id) ->
    serial(Id, fun() ->
                   maybe
                       {ok, Session} ?= get(Owner, Id),
                       {ok, _} ?= request(Owner, #{<<"op">> => <<"close">>, <<"session">> => Id}, ?TIMEOUT),
                       save(Owner, Session#{<<"status">> => <<"closed">>, <<"updatedAt">> => muse_time:now_iso()}, Id)
                   end
               end).

%% @doc PNG screenshot bytes (not serialised).
-spec preview(owner(), binary()) -> {ok, binary()} | error().
preview(Owner, Id) ->
    maybe
        {ok, _} ?= get(Owner, Id),
        {ok, #{<<"png">> := B64}} ?=
            check_shot(revive(Owner, Id, fun() ->
                                                request(Owner, #{<<"op">> => <<"screenshot">>, <<"session">> => Id},
                                                        ?TIMEOUT)
                                        end)),
        Png = try base64:decode(B64) catch _:_ -> <<>> end,
        true ?= is_png(Png) orelse invalid_payload(),
        {ok, Png}
    end.

check_shot({ok, #{<<"png">> := B64}} = R) when is_binary(B64) -> R;
check_shot({ok, _}) -> invalid_payload();
check_shot(Error) -> Error.

is_png(<<137, "PNG", _/binary>>) -> true;
is_png(_) -> false.

%% @doc Forward one whitelisted input (click/text/key/scroll) as a person
%% at the console does it: direct xdotool input (`input/4` with `direct`).
-spec input(owner(), binary(), term()) -> {ok, map()} | error().
input(Owner, Id, Value) ->
    input(Owner, Id, Value, direct).

%% @doc Forward one input to the session's window through xdotool:
%% `human` moves the mouse on an eased, jittered path and types with
%% human-like delays (agent input); `direct` clicks and types at once (the
%% person at the console). browserd validates the shape and coordinates
%% (the 1280x800 viewport).
-spec input(owner(), binary(), term(), human | direct) -> {ok, map()} | error().
input(Owner, Id, Value, Mode) when is_map(Value), (Mode =:= human orelse Mode =:= direct) ->
    serial(Id, fun() ->
                   maybe
                       {ok, Session} ?= get(Owner, Id),
                       {ok, Page} ?= check_page(revive(Owner, Id,
                                                       fun() ->
                                                               request(Owner, #{<<"op">> => <<"input">>,
                                                                                <<"session">> => Id,
                                                                                <<"input">> => Value,
                                                                                <<"mode">> => atom_to_binary(Mode)},
                                                                       ?TIMEOUT)
                                                       end)),
                       save_page(Owner, Session, Page)
                   end
               end);
input(_Owner, _Id, _Value, _Mode) ->
    {error, {422, <<"A JSON object is required for browser input">>}}.

%% @doc The `docker exec` argv of a live view of the session's window (not
%% in OpenMuse; muse_vnc_handler streams it to the console's noVNC):
%% browserd raises the window and reports its rectangle on the screen, and
%% x11vnc shows that rectangle with the viewer's input, the person at the
%% console (muse_browser_docker:vnc_args/3), in the container the session
%% runs in (its desktop computer or the owner's browser container). A session without a window is
%% re-opened at its last URL first, as for every console request.
-spec vnc(owner(), binary()) -> {ok, [binary()]} | error().
vnc(Owner, Id) ->
    serial(Id, fun() ->
                   maybe
                       {ok, _} ?= get(Owner, Id),
                       {ok, Rect} ?= check_rect(revive(Owner, Id,
                                                       fun() ->
                                                               request(Owner, #{<<"op">> => <<"show">>,
                                                                                <<"session">> => Id},
                                                                       ?TIMEOUT)
                                                       end)),
                       {ok, muse_browser_docker:vnc_args(Owner, Id, Rect)}
                   end
               end).

check_rect({ok, #{<<"left">> := L, <<"top">> := T, <<"width">> := W, <<"height">> := H} = R})
  when is_integer(L), is_integer(T), is_integer(W), is_integer(H), L >= 0, T >= 0, W > 0, H > 0 ->
    {ok, R};
check_rect({ok, _}) -> invalid_payload();
check_rect(Error) -> Error.

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

%% The thread's session id, reserved (association and session record)
%% before the browser is called.
thread_session(Owner, ThreadId, Url) ->
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
            place(Owner, Id, <<"thread:", ThreadId/binary>>),
            {ok, Id};
        _ ->
            {error, {500, <<"Could not reserve the chat browser session">>}}
    end.

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
        case check_page(request(Owner, #{<<"op">> => <<"open">>, <<"session">> => Id, <<"url">> => Target},
                                ?OPEN_TIMEOUT)) of
            {ok, Page} ->
                save_page(Owner, Session, Page);
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
            check_read(revive(Owner, Id, fun() ->
                                                 request(Owner, #{<<"op">> => <<"read">>, <<"session">> => Id},
                                                         ?TIMEOUT)
                                         end)),
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
            check_downloads(request(Owner, #{<<"op">> => <<"downloads">>, <<"session">> => Id}, ?TIMEOUT)),
        {ok, Files} ?= import_downloads(Owner, Id, Downloads, []),
        {ok, #{<<"files">> => Files, <<"failures">> => Failures}}
    end.

check_downloads({ok, #{<<"downloads">> := D, <<"failures">> := F}} = R) when is_list(D), is_list(F) -> R;
check_downloads({ok, _}) -> invalid_payload();
check_downloads(Error) -> Error.

import_downloads(_Owner, _Id, [], Acc) ->
    {ok, lists:reverse(Acc)};
import_downloads(Owner, Id, [#{<<"id">> := Did, <<"name">> := Name} | Rest], Acc) ->
    %% a download imported before is returned again, unless its file has
    %% since been deleted from Files: then it is imported anew
    Known = case muse_store:get(Owner, <<"browser-downloads">>, Did) of
                #{<<"fileId">> := FileId} -> muse_files:get(Owner, FileId);
                undefined -> undefined
            end,
    Result = case Known of
                 {ok, File0} ->
                     {ok, muse_files:signed(Owner, File0)};
                 _ ->
                     maybe
                         {ok, #{<<"data">> := B64}} ?=
                             check_download(request(Owner, #{<<"op">> => <<"download">>, <<"session">> => Id,
                                                             <<"download">> => Did}, ?TIMEOUT)),
                         Bytes = try base64:decode(B64) catch _:_ -> <<>> end,
                         true ?= Bytes =/= <<>> orelse invalid_payload(),
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

check_download({ok, #{<<"data">> := B64}} = R) when is_binary(B64) -> R;
check_download({ok, _}) -> invalid_payload();
check_download(Error) -> Error.

%% browserd's page: `{url, title}`.
check_page({ok, #{<<"url">> := U, <<"title">> := T} = P}) when is_binary(U), is_binary(T) -> {ok, P};
check_page({ok, _}) -> invalid_payload();
check_page(Error) -> Error.

%% The session record after a successful open or input: active at the page.
save_page(Owner, Session, #{<<"url">> := U, <<"title">> := T}) ->
    save(Owner, Session#{<<"url">> => U, <<"title">> => string:slice(T, 0, 300), <<"status">> => <<"active">>,
                         <<"updatedAt">> => muse_time:now_iso()}, maps:get(<<"id">>, Session)).

save(Owner, #{<<"id">> := Id, <<"title">> := T, <<"url">> := U, <<"status">> := S,
              <<"updatedAt">> := At}, Expected)
  when is_binary(Id), is_binary(T), is_binary(U), is_binary(At), Id =:= Expected ->
    case lists:member(S, [<<"idle">>, <<"active">>, <<"closed">>, <<"error">>]) of
        false -> invalid_payload();
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

request(Owner, Request, Timeout) ->
    case muse_config:browser_configured() of
        false -> {error, {503, ?NOT_CONFIGURED}};
        true -> (transport()):call(Owner, Request, Timeout)
    end.

transport() ->
    application:get_env(muse_integ, browser_transport, muse_browser_docker).

%% Not in OpenMuse: a session's window lives only as long as its Chrome, so
%% after the container (or Chrome) restarted a session the store still
%% lists has no window and every request fails with SESSION_CLOSED.
%% Re-open it at its last URL (the owner's Chrome profile, cookies and
%% sign-ins included, is on the volume) and try once more.
revive(Owner, Id, Request) ->
    case Request() of
        {error, {_, ?SESSION_CLOSED}} ->
            case reopen(Owner, Id, undefined) of
                {ok, _} -> Request();
                {error, _} = Error -> Error
            end;
        Result ->
            Result
    end.

%% One operation at a time per session (OpenMuse's per-id promise queue).
serial(Id, Fun) ->
    global:trans({{?MODULE, Id}, self()}, Fun, [node()], infinity).
