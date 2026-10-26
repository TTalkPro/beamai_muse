%% @doc Small shared pieces of the task and notification pages: status
%% chips and labels in words, local times, form values, error toasts and
%% pushes that skip topics nobody follows.
-module(muse_ui_a_kit).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([status_chip/1, status_color/1, status_label/1, kind_label/1, time/1, show/1, publish/3, done/3,
         error_text/1, toast_error/2, toast_ok/2, form_value/2, form_text/2,
         page_head/2, section/2, label/1, live/4]).

%% @doc A soft chip for a domain status, in words (`data-status` keeps the value).
-spec status_chip(binary()) -> aihtml:html().
status_chip(Status) ->
    ah_chip(status_label(Status), [soft, small, status_color(Status)], [{data_status, Status}]).

%% @doc A task, step, action or session status in words.
-spec status_label(binary()) -> binary().
status_label(<<"queued">>) -> <<"排队中"/utf8>>;
status_label(<<"scheduled">>) -> <<"已安排"/utf8>>;
status_label(<<"running">>) -> <<"进行中"/utf8>>;
status_label(<<"executing">>) -> <<"执行中"/utf8>>;
status_label(<<"waiting">>) -> <<"等待中"/utf8>>;
status_label(<<"waiting_input">>) -> <<"等你补充"/utf8>>;
status_label(<<"waiting_approval">>) -> <<"等你审批"/utf8>>;
status_label(<<"awaiting_review">>) -> <<"待审批"/utf8>>;
status_label(<<"paused">>) -> <<"已暂停"/utf8>>;
status_label(<<"succeeded">>) -> <<"已完成"/utf8>>;
status_label(<<"completed">>) -> <<"已完成"/utf8>>;
status_label(<<"failed">>) -> <<"失败"/utf8>>;
status_label(<<"cancelled">>) -> <<"已取消"/utf8>>;
status_label(<<"denied">>) -> <<"已拒绝"/utf8>>;
status_label(<<"approved">>) -> <<"已批准"/utf8>>;
status_label(<<"expired">>) -> <<"已过期"/utf8>>;
status_label(<<"outcome_unknown">>) -> <<"结果未知"/utf8>>;
status_label(<<"pending">>) -> <<"未开始"/utf8>>;
status_label(<<"skipped">>) -> <<"已跳过"/utf8>>;
status_label(<<"active">>) -> <<"打开中"/utf8>>;
status_label(<<"closed">>) -> <<"已关闭"/utf8>>;
status_label(<<"error">>) -> <<"出错"/utf8>>;
status_label(<<"connected">>) -> <<"已连接"/utf8>>;
status_label(S) -> S.

%% @doc A task kind or an action kind in words.
-spec kind_label(binary()) -> binary().
kind_label(<<"document">>) -> <<"文档任务"/utf8>>;
kind_label(<<"finance">>) -> <<"财务任务"/utf8>>;
kind_label(<<"plan">>) -> <<"计划"/utf8>>;
kind_label(<<"agent">>) -> <<"通用任务"/utf8>>;
kind_label(<<"calendar.event">>) -> <<"日程"/utf8>>;
kind_label(<<"mail.send">>) -> <<"邮件"/utf8>>;
kind_label(K) -> K.

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

%% @doc An ISO time in the server's local time: `今天 14:05`, `昨天 09:30`,
%% `10月24日 18:00`, or with the year when it is not this year; empty for
%% anything that is not a time.
-spec time(term()) -> binary().
time(B) when is_binary(B) ->
    case muse_time:parse(B) of
        Ms when is_integer(Ms) ->
            {{Y, M, D} = Date, {H, Mi, _}} = calendar:system_time_to_local_time(Ms, millisecond),
            {Today, _} = calendar:local_time(),
            Clock = io_lib:format("~2..0B:~2..0B", [H, Mi]),
            Day = calendar:date_to_gregorian_days(Date) - calendar:date_to_gregorian_days(Today),
            {TY, _, _} = Today,
            unicode:characters_to_binary(
              case Day of
                  0 -> ["今天 ", Clock];
                  -1 -> ["昨天 ", Clock];
                  1 -> ["明天 ", Clock];
                  _ when Y =:= TY -> io_lib:format("~B月~B日 ~s", [M, D, Clock]);
                  _ -> io_lib:format("~B年~B月~B日 ~s", [Y, M, D, Clock])
              end);
        nan -> B
    end;
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
    ah_div([ah_h1(Title, [<<"muse-page-title">>], []), ah_div(Extra, [<<"flex gap-2">>], [])],
           [<<"flex items-center justify-between gap-4">>], []).

-spec section(binary(), aihtml:html()) -> aihtml:element().
section(Title, Body) ->
    ah_section([ah_h2(Title, [<<"muse-section-title">>], []), Body],
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
