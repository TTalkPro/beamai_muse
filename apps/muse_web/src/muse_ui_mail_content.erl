%% @doc Mail content for the `/mail' page (M9-8; not in OpenMuse), behind
%% the session cookie like `/upload':
%%
%% - `GET /mail-content/<messageId>/body[?images=1]': the message's HTML as
%%   its own document for the reader's sandboxed iframe. Mail HTML is never
%%   rendered in the app's origin: the iframe has `sandbox="allow-popups
%%   allow-popups-to-escape-sandbox"' (no scripts, no same origin, links open
%%   in new tabs through `<base target=_blank>'), and the response carries a
%%   CSP that holds even when the URL is opened directly: `sandbox' with the
%%   same flags, `default-src 'none'', inline styles only, images only as
%%   `data:' unless `images=1' (显示图片) adds `https:' and `http:' (remote
%%   images are tracking pixels as often as not), no forms, no frames, no
%%   base URI, `frame-ancestors 'self''; plus `nosniff' and `no-referrer'.
%%   Images the HTML embeds by Content-ID (`cid:') are fetched from the
%%   server and inlined as `data:' URLs (images up to 2 MB each, 8 MB in
%%   all).
%% - `GET /mail-content/<messageId>/attachment?part=<p>[&download=1]': an
%%   attachment fetched from the server, sent by the Files content route's
%%   rules (muse_files:serve/2): PDFs, raster images, audio and video inline
%%   unless downloading, everything else as an attachment, HTML/SVG/XML
%%   never inline (`application/octet-stream'), always `nosniff'.
%% - `POST /mail-content/<draftId>/upload': the compose window's
%%   `ah_upload' (multipart `file', at most FILES_MAX_MB), attached to the
%%   draft (muse_mail_send:add_upload/5); answers the upload as JSON (201)
%%   or `{"error": Msg}'.
-module(muse_ui_mail_content).
-behaviour(cowboy_handler).

-export([init/2, csp/1, document/2]).

-define(CID_MAX, 2097152).
-define(CID_TOTAL, 8388608).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Op = {cowboy_req:method(Req0), cowboy_req:binding(op, Req0)},
    Id = cowboy_req:binding(id, Req0),
    Req = case muse_ui:owner(Req0) of
              error -> muse_http:error_reply(401, <<"Sign in again">>, Req0);
              {ok, Owner} ->
                  try handle(Op, Owner, Id, Req0)
                  catch C:R ->
                          logger:error("mail content ~p ~0p", [C, muse_http:class(R)]),
                          muse_http:error_reply(502, muse_http:generic_error(), Req0)
                  end
          end,
    {ok, Req, State}.

handle({<<"GET">>, <<"body">>}, Owner, Id, Req) ->
    Images = lists:member(muse_http:query(<<"images">>, Req), [<<"1">>, <<"true">>]),
    case muse_mail:get_message(Owner, Id) of
        {ok, M} ->
            #{html := Html, text := Text} = muse_mail:body(Owner, M),
            Inner = case Html of
                        <<>> -> [<<"<pre style=\"white-space:pre-wrap\">">>, escape(Text), <<"</pre>">>];
                        _ -> inline_cids(Owner, M, Html)
                    end,
            cowboy_req:reply(200, #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                                    <<"content-security-policy">> => csp(Images),
                                    <<"x-content-type-options">> => <<"nosniff">>,
                                    <<"referrer-policy">> => <<"no-referrer">>,
                                    <<"cache-control">> => <<"no-store">>},
                             document(Inner, Images), Req);
        {error, {S, Msg}} ->
            muse_http:error_reply(S, Msg, Req)
    end;
handle({<<"GET">>, <<"attachment">>}, Owner, Id, Req) ->
    Download = lists:member(muse_http:query(<<"download">>, Req), [<<"1">>, <<"true">>]),
    Part = case muse_http:query(<<"part">>, Req) of undefined -> <<>>; P -> P end,
    case muse_mail:attachment(Owner, Id, Part) of
        {ok, #{name := Name, type := Type, bytes := Bytes}} ->
            {CT, Disposition} = muse_files:serve(#{<<"mimeType">> => Type}, Download),
            cowboy_req:reply(200, #{<<"content-type">> => CT,
                                    <<"x-content-type-options">> => <<"nosniff">>,
                                    <<"content-disposition">> =>
                                        <<(atom_to_binary(Disposition))/binary, "; filename*=UTF-8''",
                                          (muse_signing:encode_uri_component(Name))/binary>>,
                                    <<"cache-control">> => <<"private, no-store">>},
                             Bytes, Req);
        {error, {S, Msg}} when is_integer(S) ->
            muse_http:error_reply(S, Msg, Req);
        {error, {_, Msg}} ->
            muse_http:error_reply(502, Msg, Req)
    end;
handle({<<"POST">>, <<"upload">>}, Owner, Id, Req0) ->
    case same_origin(Req0) of
        false ->
            muse_http:error_reply(403, <<"Origin is not allowed">>, Req0);
        true ->
            case muse_api_integ:read_upload(Req0, muse_files:max_bytes() + 65536) of
                {ok, {Filename, Bytes, Type}, Req} ->
                    case muse_mail_send:add_upload(Owner, Id, Filename, Bytes, Type) of
                        {ok, Upload} -> muse_http:reply({201, Upload}, Req);
                        {error, {S, Msg}} -> muse_http:error_reply(S, Msg, Req)
                    end;
                {ok, undefined, Req} ->
                    muse_http:error_reply(400, <<"请选择文件"/utf8>>, Req);
                {error, {S, Msg}, Req} ->
                    muse_http:error_reply(S, Msg, Req)
            end
    end;
handle(_, _Owner, _Id, Req) ->
    cowboy_req:reply(405, #{}, <<>>, Req).

%% @doc The body frame's Content-Security-Policy.
-spec csp(boolean()) -> binary().
csp(Images) ->
    <<"sandbox allow-popups allow-popups-to-escape-sandbox; default-src 'none'; img-src data:",
      (case Images of true -> <<" https: http:">>; false -> <<>> end)/binary,
      "; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'; "
      "frame-ancestors 'self'">>.

%% @doc The frame document around the mail's HTML: links open in new tabs
%% without a referrer; images fit the frame.
-spec document(iodata(), boolean()) -> iodata().
document(Inner, _Images) ->
    [<<"<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\">"
       "<base target=\"_blank\"><style>html,body{margin:0;padding:0}body{padding:16px;font:14px/1.6 ui-sans-serif,"
       "system-ui,-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;color:#11191C;word-wrap:break-word}"
       "img{max-width:100%;height:auto}table{max-width:100%}</style></head><body>">>,
     Inner, <<"</body></html>">>].

escape(T) ->
    binary:replace(binary:replace(binary:replace(T, <<"&">>, <<"&amp;">>, [global]), <<"<">>, <<"&lt;">>, [global]),
                   <<">">>, <<"&gt;">>, [global]).

%% `cid:' references to the message's own image parts become data: URLs.
inline_cids(Owner, #{<<"id">> := Id} = M, Html) ->
    Images = [A || A = #{<<"cid">> := C, <<"contentType">> := <<"image/", _/binary>>}
                       <- maps:get(<<"attachments">>, M, []), is_binary(C), C =/= <<>>,
                   maps:get(<<"size">>, A, 0) =< ?CID_MAX],
    case Images =/= [] andalso binary:match(string:lowercase(Html), <<"cid:">>) =/= nomatch of
        false -> Html;
        true ->
            {Map, _} = lists:foldl(
                         fun(#{<<"cid">> := C, <<"part">> := P}, {Acc, Used}) when Used < ?CID_TOTAL ->
                                 case muse_mail:attachment(Owner, Id, P) of
                                     {ok, #{type := T, bytes := B}} when byte_size(B) =< ?CID_MAX ->
                                         {Acc#{string:lowercase(C) => <<"data:", T/binary, ";base64,",
                                                                        (base64:encode(B))/binary>>},
                                          Used + byte_size(B)};
                                     _ -> {Acc, Used}
                                 end;
                            (_, Acc) -> Acc
                         end, {#{}, 0}, Images),
            re:replace(Html, <<"cid:([^\"'\\s)>]+)">>,
                       fun(Whole, [Cid]) ->
                               maps:get(string:lowercase(Cid), Map, Whole)
                       end, [global, caseless, {return, binary}])
    end.

same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> cowboy_req:header(<<"sec-fetch-site">>, Req) =/= <<"cross-site">>;
        _ -> true
    end.
