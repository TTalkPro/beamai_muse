%% @doc `GET /`: the UI entry. Signed-in visitors go to the chat, others to
%% the sign-in page. (OpenMuse answers `/` with service JSON because its UI
%% is a separate app; here the UI is served by the API itself.)
-module(muse_root).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req, State) ->
    Location = case muse_ui:owner(Req) of
                   {ok, _} -> <<"/chat">>;
                   error -> <<"/login">>
               end,
    {ok, muse_ui:redirect(Req, Location), State}.
