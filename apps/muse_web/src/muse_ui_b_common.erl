%% @doc Small helpers shared by the documents, computer, browser, apps and
%% settings pages (tasks/M6-ui.md M6-5, M6-6): error texts, inline notices,
%% status chips, sizes and times.
-module(muse_ui_b_common).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([error_text/1, notice/3, notice_html/2, path_id/1, size_label/1, time_label/1,
         chip/2, page_header/2, slot/1]).

%% @doc The message of a domain error (`{error, {Status, Msg}}`).
-spec error_text(term()) -> binary().
error_text({error, {_, Msg}}) when is_binary(Msg) -> Msg;
error_text({error, Msg}) when is_binary(Msg) -> Msg;
error_text(_) -> <<"操作失败，请稍后再试。"/utf8>>.

%% @doc An inline alert (`success | error | info | warning`), or nothing.
-spec notice_html(success | error | info | warning, aihtml:html()) -> aihtml:html().
notice_html(_Kind, <<>>) -> [];
notice_html(Kind, Msg) -> ah_alert(Msg, [Kind, dismissible], []).

%% @doc Put a notice into the slot `Id` (see `slot/1`).
-spec notice(aihtml_action:ctx(), binary(), {success | error | info | warning, aihtml:html()} | clear) -> ok.
notice(Ctx, Id, clear) ->
    aihtml_action:html(Ctx, {id, Id}, []);
notice(Ctx, Id, {Kind, Msg}) ->
    aihtml_action:html(Ctx, {id, Id}, notice_html(Kind, Msg)).

%% @doc An empty element that notices go into.
-spec slot(binary()) -> aihtml:element().
slot(Id) ->
    ah_div([], [<<"empty:hidden">>], [{id, Id}, {role, status}]).

%% @doc The first path segment after the page key (`/browser/<id>`).
-spec path_id(cowboy_req:req()) -> binary() | undefined.
path_id(Req) ->
    case cowboy_req:path_info(Req) of
        [Id | _] when Id =/= <<>> -> Id;
        _ -> undefined
    end.

-spec size_label(term()) -> binary().
size_label(N) when is_integer(N), N >= 1048576 ->
    iolist_to_binary(io_lib:format("~.1f MB", [N / 1048576]));
size_label(N) when is_integer(N), N >= 1024 ->
    iolist_to_binary(io_lib:format("~.1f KB", [N / 1024]));
size_label(N) when is_integer(N) ->
    <<(integer_to_binary(N))/binary, " B">>;
size_label(_) ->
    <<>>.

%% @doc `2026-10-22T08:15:00.000Z` -> `2026-10-22 08:15`.
-spec time_label(term()) -> binary().
time_label(<<Date:10/binary, "T", Time:5/binary, _/binary>>) -> <<Date/binary, " ", Time/binary>>;
time_label(B) when is_binary(B) -> B;
time_label(_) -> <<>>.

-spec chip(binary(), success | warning | error | info | default) -> aihtml:html().
chip(Label, success) -> ah_chip(Label, [soft, small, success], []);
chip(Label, warning) -> ah_chip(Label, [soft, small, warning], []);
chip(Label, error) -> ah_chip(Label, [soft, small, error], []);
chip(Label, info) -> ah_chip(Label, [soft, small, info], []);
chip(Label, default) -> ah_chip(Label, [soft, small], []).

-spec page_header(aihtml:html(), aihtml:html()) -> aihtml:element().
page_header(Title, Sub) ->
    ah_div([ah_h1(Title, [<<"text-xl font-semibold">>], []),
            case Sub of
                <<>> -> [];
                _ -> ah_p(Sub, [<<"text-sm text-muted">>], [])
            end],
           [<<"flex flex-col gap-1">>], []).
