%% @doc The "全部文件" card under a chat reply and its preview window
%% (M9-11, not in OpenMuse; designs/05-web-ui.md §4).
%%
%% A reply that made files (muse_chat_products) ends, after its last text
%% and before the message tools, with one rounded card: a folder picture,
%% "全部文件", "预览或者下载文件 · N 个文件" and a "预览" button. N counts the
%% files still in Files; with none left there is no card. muse_ui_chat
%% places the card (`card/3`) when it renders the log, so it appears when
%% muse_chat_relay re-renders the log at the run's end and on every reload.
%%
%% "预览" fills and opens the chat page's modal window (`window/0`, 1000 px
%% wide, 85vh high): the header has the count and "全部下载" (a zip of all
%% the files, `GET /api/threads/:id/products/:runId/zip` through a fresh
%% signed URL; over 4 × FILES_MAX_MB it says so instead); the left column
%% lists the files (icon by kind, name, size), the right one previews the
%% selected file, the first at the start, with "下载" and "在文件中打开"
%% (`/documents/<id>`). Previews follow the Files page (muse_ui_documents)
%% and the content route's rules (muse_files:serve/2, nosniff, signed
%% URLs): a PDF in an iframe, an image inline only when it is a raster type
%% (never SVG), audio and video players, text and code read-only in a
%% `<pre>` (Markdown rendered) cut at 200 KB with a note, anything else its
%% details. Downloads are actions that send the browser to a fresh signed
%% URL, so an open window never holds an expired link.
%%
%% Every action resolves the signed-in owner and looks the reply up among
%% that owner's records, and a file only through that reply's list.
-module(muse_ui_products).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([card/3, window/0, action/4, zip_path/2]).

-define(C, muse_ui_b_common).
-define(D, muse_ui_documents).
-define(WIN, <<"products-win">>).
-define(BODY, <<"products-body">>).
-define(NOTICE, <<"products-notice">>).
-define(TEXT_MAX, 204800).

%%%===================================================================
%%% The card
%%%===================================================================

%% @doc The card of reply `Run` of conversation `Tid`, or nothing when its
%% files are all gone.
-spec card(binary(), binary(), binary()) -> aihtml:html().
card(Owner, Tid, Run) ->
    case muse_chat_products:files(Owner, Tid, Run) of
        {ok, [_ | _] = Files} ->
            N = integer_to_binary(length(Files)),
            ah_div([folder_art(),
                    ah_div([ah_div(<<"全部文件"/utf8>>, [<<"muse-products-title">>], []),
                            ah_div(<<"预览或者下载文件 · "/utf8, N/binary, " 个文件"/utf8>>,
                                   [<<"muse-products-sub">>], [])],
                           [<<"muse-products-text">>], []),
                    ah_button(<<"预览"/utf8>>, preview, [<<"muse-products-btn">>],
                              [{type, button}, {id, <<"products-open-", Run/binary>>},
                               on(click, {?MODULE, open, #{thread => Tid, run => Run}})])],
                   [<<"muse-products">>], [{id, <<"products-", Run/binary>>}, {data_run, Run}]);
        _ ->
            []
    end.

%% A grey folder like the reference's.
folder_art() ->
    {safe, <<"<svg class=\"muse-products-art\" width=\"52\" height=\"44\" viewBox=\"0 0 52 44\" fill=\"none\" "
             "aria-hidden=\"true\"><path d=\"M4.5 7A4.5 4.5 0 0 1 9 2.5h10.6a4.5 4.5 0 0 1 3.4 1.6L25.6 7H43a4.5 4.5 0 "
             "0 1 4.5 4.5V37A4.5 4.5 0 0 1 43 41.5H9A4.5 4.5 0 0 1 4.5 37Z\" fill=\"#E6E8EB\" stroke=\"#D2D5DA\"/>"
             "<path d=\"M1.5 17A4.5 4.5 0 0 1 6 12.5h40a4.5 4.5 0 0 1 4.5 4.5v20a4.5 4.5 0 0 1-4.5 4.5H6A4.5 4.5 0 0 1 "
             "1.5 37Z\" fill=\"#F5F6F7\" stroke=\"#D2D5DA\"/></svg>">>}.

%%%===================================================================
%%% The window
%%%===================================================================

%% @doc The chat page's (empty) preview window.
-spec window() -> #ah_window{}.
window() ->
    #ah_window{id = ?WIN, title = <<"全部文件"/utf8>>,
               body = ah_div([], [<<"muse-pv-body">>], [{id, ?BODY}]),
               modal = true, draggable = false, resizable = false, width = 1000, height = <<"85vh">>,
               close_on_overlay = true}.

header(Tid, Run, Files) ->
    ah_div([ah_span(<<"全部文件"/utf8>>, [<<"muse-pv-title">>], []),
            ah_span(<<(integer_to_binary(length(Files)))/binary, " 个文件"/utf8>>, [<<"muse-pv-count">>], []),
            ah_button([muse_ui_icons:icon(download, 15), <<"全部下载"/utf8>>], zip, [outlined, sm, <<"muse-btn-icon muse-pv-zip">>],
                      [{type, button}, {id, <<"products-zip">>},
                       on(click, {?MODULE, zip, #{thread => Tid, run => Run}})])],
           [<<"muse-pv-head">>], []).

body(Owner, Tid, Run, Files, Selected) ->
    [?C:slot(?NOTICE),
     ah_div([ah_div([item(Tid, Run, F, Selected) || F <- Files], [<<"muse-pv-list">>], [{id, <<"products-list">>}]),
             ah_div(view(Owner, Tid, Run, Selected), [<<"muse-pv-view">>], [{id, <<"products-view">>}])],
            [<<"muse-pv">>], [])].

%% A plain row button (not ah_button: a list row, left aligned, flat).
item(Tid, Run, #{<<"id">> := Id, <<"name">> := Name} = F, #{<<"id">> := Sel}) ->
    aihtml:ah_el(button,
                 [?D:kind_icon(F, 18),
                  ah_span([ah_span(Name, [<<"muse-pv-name">>], []),
                           ah_span(?C:size_label(maps:get(<<"size">>, F, undefined)), [<<"muse-pv-size">>], [])],
                          [<<"muse-pv-item-text">>], [])],
                 [<<"muse-pv-item">>, case Id of Sel -> <<"muse-pv-active">>; _ -> <<>> end],
                 [{type, button}, {id, <<"pv-item-", Id/binary>>}, {title, Name},
                  on(click, {?MODULE, select, #{thread => Tid, run => Run, file => Id}})]).

view(Owner, _Tid, _Run, #{<<"id">> := Id, <<"name">> := Name} = File) ->
    Kind = muse_files:kind(File),
    Meta = [?D:kind_label(Kind), <<" · "/utf8>>, ?C:size_label(maps:get(<<"size">>, File, undefined)),
            case maps:get(<<"computerPath">>, File, undefined) of
                P when is_binary(P) -> [<<" · "/utf8>>, P];
                _ -> []
            end],
    [ah_div([ah_div([ah_div(Name, [<<"muse-pv-file">>], [{id, <<"products-file-name">>}]),
                     ah_div(Meta, [<<"muse-pv-meta">>], [])], [<<"muse-pv-file-text">>], []),
             ah_div([ah_button([muse_ui_icons:icon(download, 15), <<"下载"/utf8>>], download,
                               [outlined, sm, <<"muse-btn-icon">>],
                               [{type, button}, {id, <<"products-download">>},
                                on(click, {?MODULE, download, #{file => Id}})]),
                     ah_a(<<"在文件中打开"/utf8>>, [<<"muse-pv-open">>],
                          [{href, <<"/documents/", Id/binary>>}, {id, <<"products-in-files">>}])],
                    [<<"muse-pv-actions">>], [])],
            [<<"muse-pv-bar">>], []),
     ah_div(preview(Owner, File, Kind), [<<"muse-pv-stage">>], [{id, <<"products-preview">>}])].

preview(Owner, #{<<"id">> := Id, <<"name">> := Name} = File, Kind) ->
    Src = muse_signing:signed_path(Owner, <<"/api/files/", Id/binary, "/content">>),
    Inline = element(2, muse_files:serve(File, false)) =:= inline,
    case Kind of
        pdf when Inline ->
            aihtml:ah_el(iframe, [], [<<"muse-pv-frame">>], [{id, <<"pv-frame">>}, {src, Src}, {title, Name}]);
        image when Inline ->
            ah_img([<<"muse-pv-image">>], [{id, <<"pv-image">>}, {src, Src}, {alt, Name}]);
        audio when Inline ->
            aihtml:ah_el(audio, [], [<<"muse-pv-audio">>],
                         [{id, <<"pv-audio">>}, {src, Src}, {controls, true}, {preload, metadata}]);
        video when Inline ->
            aihtml:ah_el(video, [], [<<"muse-pv-video">>],
                         [{id, <<"pv-video">>}, {src, Src}, {controls, true}, {preload, metadata}, {playsinline, true}]);
        text ->
            case text_of(Owner, File) of
                {ok, Text, Cut} ->
                    [case Cut of
                         true -> ah_p(<<"文件较大，这里只显示前 200 KB；完整内容请下载。"/utf8>>,
                                      [<<"muse-pv-note">>], [{id, <<"pv-cut">>}]);
                         false -> []
                     end,
                     case maps:get(<<"mimeType">>, File, <<>>) of
                         <<"text/markdown">> ->
                             ah_div(ah_markdown_view(Text, [<<"max-w-none">>], []), [<<"muse-pv-md">>],
                                    [{id, <<"pv-markdown">>}]);
                         _ ->
                             ah_pre(Text, [<<"muse-pv-text">>], [{id, <<"pv-text">>}])
                     end];
                error ->
                    info(File)
            end;
        _ ->
            info(File)
    end.

%% UTF-8 text, at most 200 KB of it (cut at a character boundary).
text_of(Owner, #{<<"id">> := Id}) ->
    case muse_files:bytes(Owner, Id) of
        {ok, Bin} ->
            Cut = byte_size(Bin) > ?TEXT_MAX,
            Head = case Cut of
                       true -> binary:part(Bin, 0, ?TEXT_MAX);
                       false -> Bin
                   end,
            case unicode:characters_to_binary(Head) of
                Text when is_binary(Text) -> {ok, Text, Cut};
                {incomplete, Text, _} when Cut -> {ok, Text, Cut};
                _ -> error
            end;
        _ ->
            error
    end.

info(File) ->
    ah_empty([], [],
             [{title, <<"这种文件无法在这里预览"/utf8>>},
              {description, [maps:get(<<"mimeType">>, File, <<>>), <<" · "/utf8>>,
                             ?C:size_label(maps:get(<<"size">>, File, undefined)),
                             <<"。下载后用合适的应用打开。"/utf8>>]}]).

%% @doc The zip route's path (sign it before use).
-spec zip_path(binary(), binary()) -> binary().
zip_path(Tid, Run) ->
    <<"/api/threads/", Tid/binary, "/products/", Run/binary, "/zip">>.

%%%===================================================================
%%% Actions
%%%===================================================================

-spec action(atom(), map(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(Name, Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> act(Name, Args, Ctx, Owner) end).

act(open, #{thread := Tid, run := Run}, Ctx, Owner) ->
    case muse_chat_products:files(Owner, Tid, Run) of
        {ok, [First | _] = Files} ->
            aihtml_action:html(Ctx, {id, <<?WIN/binary, "-title">>}, header(Tid, Run, Files), inner),
            aihtml_action:html(Ctx, {id, ?BODY}, body(Owner, Tid, Run, Files, First), inner),
            aihtml_lib_overlay:open(Ctx, {id, ?WIN});
        _ ->
            ah_toast(Ctx, <<"这些文件已经不在了"/utf8>>, #{variant => error})
    end;
act(select, #{thread := Tid, run := Run, file := Id}, Ctx, Owner) ->
    case muse_chat_products:files(Owner, Tid, Run) of
        {ok, Files} ->
            case [F || F = #{<<"id">> := I} <- Files, I =:= Id] of
                [File] -> aihtml_action:html(Ctx, {id, ?BODY}, body(Owner, Tid, Run, Files, File), inner);
                [] -> ?C:notice(Ctx, ?NOTICE, {error, <<"这个文件已经不在了"/utf8>>})
            end;
        Error ->
            ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
    end;
act(download, #{file := Id}, Ctx, Owner) ->
    case muse_files:get(Owner, Id) of
        {ok, #{<<"id">> := FileId}} ->
            Path = muse_signing:signed_path(Owner, <<"/api/files/", FileId/binary, "/content">>),
            aihtml_action:redirect(Ctx, <<Path/binary, "&download=1">>);
        Error ->
            ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
    end;
act(zip, #{thread := Tid, run := Run}, Ctx, Owner) ->
    case muse_chat_products:files(Owner, Tid, Run) of
        {ok, [_ | _] = Files} ->
            Limit = muse_chat_products:zip_limit(),
            case lists:sum([maps:get(<<"size">>, F, 0) || F <- Files]) > Limit of
                true ->
                    ?C:notice(Ctx, ?NOTICE,
                              {error, <<"这些文件一共超过 "/utf8, (integer_to_binary(Limit div 1048576))/binary,
                                        " MB，无法打包下载，请逐个下载。"/utf8>>});
                false ->
                    aihtml_action:redirect(Ctx, muse_signing:signed_path(Owner, zip_path(Tid, Run)))
            end;
        _ ->
            ?C:notice(Ctx, ?NOTICE, {error, <<"这些文件已经不在了"/utf8>>})
    end.
