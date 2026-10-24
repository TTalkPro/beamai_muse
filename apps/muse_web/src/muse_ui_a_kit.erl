%% @doc Small shared pieces of the M6-3/M6-4 pages (activity, goals,
%% monitors, ideas, notifications): status chips, times, form values,
%% error toasts and pushes that skip topics nobody follows.
-module(muse_ui_a_kit).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([status_chip/1, status_color/1, time/1, show/1, publish/3, done/3,
         error_text/1, toast_error/2, toast_ok/2, form_value/2, form_text/2,
         page_head/2, section/2, label/1, live/4]).

%% @doc A soft chip for a domain status (the value as is).
-spec status_chip(binary()) -> aihtml:html().
status_chip(Status) ->
    ah_chip(Status, [soft, small, status_color(Status)], [{data_status, Status}]).

-spec status_color(binary()) -> atom().
status_color(S) when S =:= <<"succeeded">>; S =:= <<"completed">>; S =:= <<"accepted">>;
                     S =:= <<"active">>; S =:= <<"connected">> ->
    success;
status_color(S) when S =:= <<"failed">>; S =:= <<"denied">>; S =:= <<"expired">>;
                     S =:= <<"outcome_unknown">> ->
    error;
status_color(S) when S =:= <<"waiting_input">>; S =:= <<"waiting_approval">>;
                     S =:= <<"awaiting_review">>; S =:= <<"paused">> ->
    warning;
status_color(S) when S =:= <<"running">>; S =:= <<"executing">>; S =:= <<"queued">>;
                     S =:= <<"scheduled">> ->
    info;
status_color(<<"new">>) ->
    primary;
status_color(_) ->
    default.

%% @doc An ISO time as `YYYY-MM-DD HH:MM` (UTC); empty for anything else.
-spec time(term()) -> binary().
time(<<Date:10/binary, "T", Hm:5/binary, _/binary>>) -> <<Date/binary, " ", Hm/binary>>;
time(B) when is_binary(B) -> B;
time(_) -> <<>>.

%% @doc Any JSON value as display text (receipts may be text or objects).
-spec show(term()) -> binary().
show(B) when is_binary(B) -> B;
show(null) -> <<>>;
show(undefined) -> <<>>;
show(N) when is_integer(N) -> integer_to_binary(N);
show(true) -> <<"true">>;
show(false) -> <<"false">>;
show(V) ->
    try muse_json:encode(V)
    catch _:_ -> iolist_to_binary(io_lib:format("~0p", [V]))
    end.

%% @doc Publish to the owner's topic `Name`, but only when some page
%% follows it (publishing renders first).
-spec publish(binary(), term(), fun((aihtml_action:ctx()) -> term())) -> ok.
publish(Owner, Name, Fun) ->
    Followed = try aihtml_push:subscribers(muse_ui:topic(Owner, Name)) > 0
               catch _:_ -> false
               end,
    case Followed of
        true -> muse_ui:publish(Owner, Name, Fun);
        false -> ok
    end.

%% @doc Continue with `Then(Value)` on success; on an error show a toast.
-spec done(aihtml_action:ctx(), ok | {ok, term()} | {error, term()}, fun((term()) -> term())) -> term().
done(_Ctx, ok, Then) -> Then(ok);
done(_Ctx, {ok, V}, Then) -> Then(V);
done(Ctx, {error, E}, _Then) -> toast_error(Ctx, error_text(E)).

-spec error_text(term()) -> binary().
error_text({_Status, Msg}) when is_binary(Msg) -> Msg;
error_text(Msg) when is_binary(Msg) -> Msg;
error_text(_) -> <<"操作失败"/utf8>>.

-spec toast_error(aihtml_action:ctx(), binary()) -> ok.
toast_error(Ctx, Msg) ->
    ah_toast(Ctx, <<"操作失败"/utf8>>, #{description => Msg, variant => error}).

-spec toast_ok(aihtml_action:ctx(), binary()) -> ok.
toast_ok(Ctx, Msg) ->
    ah_toast(Ctx, Msg, #{variant => success}).

%% @doc A raw form value (`undefined` when absent).
-spec form_value(aihtml_action:event(), binary()) -> binary() | undefined.
form_value(Event, Name) ->
    case maps:get(Name, maps:get(form, Event, #{}), undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

%% @doc A trimmed form text with browser line ends (`\r\n`) normalised.
-spec form_text(aihtml_action:event(), binary()) -> binary().
form_text(Event, Name) ->
    case form_value(Event, Name) of
        undefined -> <<>>;
        V -> string:trim(binary:replace(V, <<"\r\n">>, <<"\n">>, [global]))
    end.

-spec page_head(binary(), aihtml:html()) -> aihtml:element().
page_head(Title, Extra) ->
    ah_div([ah_h1(Title, [<<"text-xl font-semibold">>], []), ah_div(Extra, [<<"flex gap-2">>], [])],
           [<<"flex items-center justify-between gap-4">>], []).

-spec section(binary(), aihtml:html()) -> aihtml:element().
section(Title, Body) ->
    ah_section([ah_h2(Title, [<<"text-sm font-semibold text-muted mb-2">>], []), Body],
               [<<"flex flex-col gap-2">>], []).

%% @doc `field_name` as `field name`.
-spec label(binary()) -> binary().
label(Name) ->
    binary:replace(Name, <<"_">>, <<" ">>, [global]).

%% @doc A live region: `Id` subscribed to the owner's topic `Name`, with
%% `Refresh` run after a reconnect.
-spec live(binary(), term(), aihtml_action:ref(), aihtml:html()) -> aihtml:element().
live(Owner, Name, Refresh, Body) ->
    ah_div(Body, [], [subscribe(muse_ui:topic(Owner, Name), #{refresh => Refresh})]).
