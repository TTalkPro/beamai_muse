%% @doc Full-page handler for the UI routes. Each page is a module with
%% `render(Owner, Req) -> {Title, Html}` (Html built inside the app shell);
%% modules may also export `on_event(Owner, Event)` to turn domain events
%% into pushes (called by muse_ui_bridge).
-module(muse_ui_page).
-behaviour(cowboy_handler).

-export([init/2, modules/0]).

-callback render(Owner :: binary(), Req :: cowboy_req:req()) -> {binary(), aihtml:html()}.
-callback on_event(Owner :: binary(), Event :: term()) -> term().
-optional_callbacks([on_event/2]).

%% @doc Page key -> module.
-spec modules() -> [{atom(), module()}].
modules() ->
    [{chat, muse_ui_chat}, {activity, muse_ui_activity}, {documents, muse_ui_documents},
     {computer, muse_ui_computer}, {browser, muse_ui_browser}, {apps, muse_ui_apps},
     {notifications, muse_ui_notifications}, {settings, muse_ui_settings}].

-spec init(cowboy_req:req(), atom()) -> {ok, cowboy_req:req(), atom()}.
init(Req, Key) ->
    Module = proplists:get_value(Key, modules()),
    Reply = case muse_ui:owner(Req) of
                error ->
                    muse_ui:redirect(Req, <<"/login">>);
                {ok, Owner} ->
                    {Title, Html} = Module:render(Owner, Req),
                    muse_ui:reply_page(Req, Owner, case Title of <<>> -> title(Key); _ -> Title end, Key, Html, #{})
            end,
    {ok, Reply, Key}.

title(Key) ->
    muse_ui_layout:title(Key).
