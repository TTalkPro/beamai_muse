%% @doc `GET/POST /login` and `POST /logout` (designs/05-web-ui.md §3).
%%
%% Native form posts, because aihtml actions cannot set cookies. Sign-in
%% follows `POST /api/session`: access key check (sample mode accepts any),
%% per-client limiter, sample data and identity prepared, then an HttpOnly
%% session cookie and a redirect to the chat.
-module(muse_ui_login).
-behaviour(cowboy_handler).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([init/2]).

-spec init(cowboy_req:req(), login | logout) -> {ok, cowboy_req:req(), login | logout}.
init(Req0, Mode) ->
    Req = case {Mode, cowboy_req:method(Req0)} of
              {login, <<"GET">>} -> form(Req0, undefined);
              {login, <<"POST">>} -> sign_in(Req0);
              {logout, <<"POST">>} -> sign_out(Req0);
              _ -> cowboy_req:reply(405, #{}, <<>>, Req0)
          end,
    {ok, Req, Mode}.

sign_in(Req0) ->
    case same_origin(Req0) of
        false ->
            cowboy_req:reply(403, #{}, <<"Origin is not allowed">>, Req0);
        true ->
            {ok, Form, Req} = cowboy_req:read_urlencoded_body(Req0, #{length => 8192}),
            Key = maps:get(muse_client_key, Req, client_key(Req)),
            case muse_rate_limit:take(login, Key) of
                false ->
                    form(Req, <<"Too many sign-in attempts. Try again in a minute.">>);
                true ->
                    AccessKey = proplists:get_value(<<"accessKey">>, Form),
                    case muse_auth:session(AccessKey) of
                        {ok, #{token := Token}} ->
                            ok = muse_api_core:prepare_owner(muse_auth:owner()),
                            Secure = case uri_string:parse(muse_config:get(public_url)) of
                                         #{scheme := <<"https">>} -> true;
                                         _ -> false
                                     end,
                            Req1 = cowboy_req:set_resp_cookie(muse_ui:cookie(), Token, Req,
                                                              #{path => <<"/">>, http_only => true,
                                                                same_site => lax, secure => Secure,
                                                                max_age => 86400}),
                            muse_ui:redirect(Req1, <<"/chat">>);
                        {error, {_, Msg}} ->
                            form(Req, Msg)
                    end
            end
    end.

sign_out(Req0) ->
    case same_origin(Req0) of
        false ->
            cowboy_req:reply(403, #{}, <<"Origin is not allowed">>, Req0);
        true ->
            case lists:keyfind(muse_ui:cookie(), 1, cowboy_req:parse_cookies(Req0)) of
                {_, Token} ->
                    case muse_auth:owner_from_token(Token) of
                        {ok, Owner} -> ok = muse_ui:rotate_epoch(Owner);
                        _ -> ok
                    end,
                    ok = muse_auth:revoke(Token);
                false ->
                    ok
            end,
            Req = cowboy_req:set_resp_cookie(muse_ui:cookie(), <<>>, Req0,
                                             #{path => <<"/">>, max_age => 0, http_only => true}),
            muse_ui:redirect(Req, <<"/login">>)
    end.

%% A form post must come from our own pages: the Origin gate in muse_mw
%% rejects foreign origins. Browsers send Origin on every form POST;
%% without it (non-browser clients) only an explicit cross-site fetch is
%% refused. The session cookie is SameSite=Lax as well.
same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> cowboy_req:header(<<"sec-fetch-site">>, Req) =/= <<"cross-site">>;
        _ -> true
    end.

client_key(Req) ->
    {Peer, _} = cowboy_req:peer(Req),
    muse_rate_limit:client_key(muse_config:get(trust_proxy), cowboy_req:headers(Req), Peer).

form(Req, Error) ->
    Sample = muse_config:get(mode) =:= sample,
    Body = ah_div(
             ah_card([ah_form([case Error of
                                   undefined -> [];
                                   _ -> ah_alert(Error, [error], [{id, <<"login-error">>}])
                               end,
                               case Sample of
                                   true -> ah_p(<<"示例模式：直接登录即可，无需访问密钥。"/utf8>>, [<<"text-sm text-muted">>], []);
                                   false -> ah_field(<<"访问密钥"/utf8>>,
                                                     ah_password_input(<<>>, [], [{name, accessKey}, {id, access_key},
                                                                                  {autocomplete, <<"current-password">>}]),
                                                     [], [])
                               end,
                               ah_button(<<"登录"/utf8>>, login, [primary], [{type, submit}])],
                              [<<"flex flex-col gap-4">>], [{action, <<"/login">>}, {method, post}])],
                     [<<"w-full max-w-sm">>], [{title, <<"登录 Muse"/utf8>>}]),
             [<<"min-h-screen flex items-center justify-center p-6">>], []),
    aihtml_cowboy:reply(Req, Body, #{title => <<"登录 · Muse"/utf8>>, css => [muse_ui_assets:css()],
                                     lang => muse_ui:lang()}).
