%% @doc Shared pieces of the aihtml UI (designs/05-web-ui.md §3).
%%
%% Sessions: the UI uses the same session tokens as the JSON API, carried in
%% an HttpOnly cookie. Pages without a session redirect to /login; aihtml's
%% endpoints ask `authorize/1` first, and actions get the owner from the
%% cookie (`with_owner/2`).
%%
%% Push topics are `{muse, Owner, Epoch, Name}`. Logging out rotates the
%% owner's epoch, so pages rendered before the logout subscribe to topics
%% nobody publishes to any more.
-module(muse_ui).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([cookie/0, owner/1, authorize/1, with_owner/2, page/5, reply_page/6, redirect/2,
         topic/2, epoch/1, rotate_epoch/1, publish/3, lang/0]).

-define(COOKIE, <<"muse_session">>).

-spec cookie() -> binary().
cookie() -> ?COOKIE.

%% @doc The signed-in owner of a request, from the session cookie.
-spec owner(cowboy_req:req()) -> {ok, binary()} | error.
owner(Req) ->
    case lists:keyfind(?COOKIE, 1, cowboy_req:parse_cookies(Req)) of
        {_, Token} ->
            case muse_auth:owner_from_token(Token) of
                {ok, Owner} -> {ok, Owner};
                _ -> error
            end;
        false ->
            error
    end.

%% @doc The aihtml endpoints' authorization hook: a valid session cookie.
-spec authorize(cowboy_req:req()) -> ok | {deny, 401}.
authorize(Req) ->
    case owner(Req) of
        {ok, _} -> ok;
        error -> {deny, 401}
    end.

%% @doc Run an action body for the signed-in owner; without a session the
%% page is sent to /login.
-spec with_owner(aihtml_action:ctx(), fun((binary()) -> term())) -> term().
with_owner(Ctx, Fun) ->
    #{req := Req} = aihtml_action:meta(Ctx),
    case owner(Req) of
        {ok, Owner} -> Fun(Owner);
        error -> aihtml_action:redirect(Ctx, <<"/login">>)
    end.

%% @doc Reply with a full page in the app shell. `Body` is a fun of the owner
%% (it runs in the page language). `Active` is the sidenav key.
-spec page(cowboy_req:req(), binary(), atom(), fun((binary()) -> aihtml:html()), map()) -> cowboy_req:req().
page(Req, Title, Active, Body, Opts) ->
    case owner(Req) of
        error -> redirect(Req, <<"/login">>);
        {ok, Owner} -> reply_page(Req, Owner, Title, Active, Body(Owner), Opts)
    end.

-spec reply_page(cowboy_req:req(), binary(), binary(), atom(), aihtml:html(), map()) -> cowboy_req:req().
reply_page(Req, Owner, Title, Active, Html, Opts) ->
    ok = muse_ui_bridge:ensure(Owner),
    aihtml_cowboy:reply(Req, muse_ui_layout:shell(Owner, Active, Html, Req), maps:merge(page_opts(Title), Opts)).

page_opts(Title) ->
    #{title => <<Title/binary, " · OpenMuse"/utf8>>,
      lang => lang(),
      css => [muse_ui_assets:css()],
      js => [muse_ui_assets:js()],
      %% one fixed light look (OpenMuse has no theme choice)
      theme => #{appearance => light},
      persist => false}.

-spec lang() -> binary().
lang() ->
    aihtml_i18n:locale().

-spec redirect(cowboy_req:req(), binary()) -> cowboy_req:req().
redirect(Req, Location) ->
    cowboy_req:reply(302, #{<<"location">> => Location}, <<>>, Req).

%% Topics

-spec topic(binary(), term()) -> tuple().
topic(Owner, Name) ->
    {muse, Owner, epoch(Owner), Name}.

%% @doc The owner's current push epoch (created on first use).
-spec epoch(binary()) -> binary().
epoch(Owner) ->
    case muse_store:get(Owner, <<"settings">>, <<"ui-epoch">>) of
        #{<<"value">> := E} -> E;
        undefined ->
            New = #{<<"id">> => <<"ui-epoch">>, <<"value">> => muse_ids:uuid()},
            _ = muse_store:insert_if_absent(Owner, <<"settings">>, New),
            #{<<"value">> := E} = muse_store:get(Owner, <<"settings">>, <<"ui-epoch">>),
            E
    end.

-spec rotate_epoch(binary()) -> ok.
rotate_epoch(Owner) ->
    _ = muse_store:put(Owner, <<"settings">>, #{<<"id">> => <<"ui-epoch">>, <<"value">> => muse_ids:uuid()}),
    ok.

%% @doc Publish DOM operations to everyone watching `Name` for the owner.
-spec publish(binary(), term(), fun((aihtml_action:ctx()) -> term())) -> ok.
publish(Owner, Name, Fun) ->
    try aihtml_push:publish(topic(Owner, Name), Fun) of
        _ -> ok
    catch
        Class:Reason:St ->
            logger:warning("ui publish ~p failed: ~p:~p ~p", [Name, Class, Reason, St]),
            ok
    end.
