%% @doc Documents page `/documents[/:id]` (designs/05-web-ui.md §5,
%% tasks/M6-ui.md M6-5): the PDF list, upload (ah_upload posting to
%% `/upload`, muse_ui_b_upload), an iframe preview over a signed content
%% URL, the form-field fill (muse_files:fill/3, a filled copy) and the copy
%% into the computer's workspace (muse_computer:import_pdf/3).
%%
%% The list is subscribed to the owner's `documents` topic; changes made
%% here are published to the owner's other tabs.
-module(muse_ui_documents).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, action/4]).

-define(C, muse_ui_b_common).
-define(LIST, <<"doc-list">>).
-define(NOTICE, <<"doc-notice">>).
-define(MAX_BYTES, 10485760).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    Selected = case ?C:path_id(Req) of
                   undefined -> undefined;
                   Id -> case muse_files:get(Owner, Id) of
                             {ok, File} -> File;
                             {error, _} -> not_found
                         end
               end,
    Title = case Selected of
                #{<<"name">> := Name} -> Name;
                _ -> <<>>
            end,
    {Title,
     ah_div([?C:page_header(<<"文档"/utf8>>, <<"上传 PDF、预览、填写表单字段，或复制到电脑的工作区。"/utf8>>),
             ?C:slot(?NOTICE),
             ah_div([ah_div([upload_card(), list_card(Owner)], [<<"flex flex-col gap-4 lg:w-2/5 min-w-0">>], []),
                     ah_div(detail(Owner, Selected), [<<"flex flex-col gap-4 flex-1 min-w-0">>],
                            [{id, <<"doc-detail">>}])],
                    [<<"flex flex-col lg:flex-row gap-6">>], [])],
            [<<"p-6 flex flex-col gap-6">>], [])}.

upload_card() ->
    ah_card(ah_upload([], [],
                      [{id, <<"doc-upload">>}, {url, <<"/upload">>}, {field_name, file},
                       {accept, <<"application/pdf,.pdf">>}, {max_size, ?MAX_BYTES},
                       {drag_text, <<"拖拽 PDF 到此处，或"/utf8>>}, {browse_text, <<"点击选择"/utf8>>},
                       {hint, <<"仅限 PDF，单个不超过 10 MB"/utf8>>},
                       {labels, #{too_large => <<"超过 10 MB"/utf8>>, type_mismatch => <<"不是 PDF"/utf8>>,
                                  upload_failed => <<"上传失败"/utf8>>, remove => <<"移除"/utf8>>,
                                  network_error => <<"网络错误"/utf8>>}},
                       on(change, {?MODULE, uploaded, #{}})]),
            [], [{title, <<"上传"/utf8>>}]).

list_card(Owner) ->
    ah_card(ah_div(list_body(Owner), [], [{id, ?LIST},
                                          subscribe(muse_ui:topic(Owner, documents),
                                                    #{refresh => {?MODULE, refresh, #{}}})]),
            [], [{title, <<"全部文档"/utf8>>}]).

list_body(Owner) ->
    case muse_files:list(Owner, unsigned) of
        [] ->
            ah_empty([], [compact], [{title, <<"还没有文档"/utf8>>},
                                     {description, <<"上传一个 PDF 开始使用。"/utf8>>}]);
        Files ->
            ah_ul([file_row(F) || F <- Files], [<<"flex flex-col divide-y divide-line">>], [])
    end.

file_row(#{<<"id">> := Id, <<"name">> := Name} = F) ->
    Meta = lists:join(<<" · "/utf8>>,
                      [M || M <- [pages(F), ?C:size_label(maps:get(<<"size">>, F, undefined)),
                                  maps:get(<<"source">>, F, <<>>),
                                  ?C:time_label(maps:get(<<"createdAt">>, F, <<>>))], M =/= <<>>]),
    ah_li([ah_a(Name, [<<"font-medium text-primary hover:underline break-all">>],
                [{href, <<"/documents/", Id/binary>>}]),
           ah_div(Meta, [<<"text-xs text-muted">>], [])],
          [<<"py-2 flex flex-col gap-0.5">>], [{id, <<"doc-", Id/binary>>}]).

pages(#{<<"pageCount">> := N}) when is_integer(N) -> <<(integer_to_binary(N))/binary, " 页"/utf8>>;
pages(_) -> <<>>.

detail(_Owner, undefined) ->
    ah_card(ah_empty([], [], [{title, <<"选择一个文档"/utf8>>},
                              {description, <<"在左侧列表中点击文档，即可预览、填写字段或复制到电脑。"/utf8>>}]),
            [], []);
detail(_Owner, not_found) ->
    ah_card(ah_empty([], [], [{title, <<"找不到该文档"/utf8>>},
                              {description, <<"文档不存在，或不属于当前账户。"/utf8>>}]),
            [], []);
detail(Owner, #{<<"id">> := Id, <<"name">> := Name} = File) ->
    Src = muse_signing:signed_path(Owner, <<"/api/files/", Id/binary, "/content">>),
    Fields = maps:get(<<"fields">>, File, []),
    [ah_card(aihtml:ah_el(iframe, [], [<<"w-full h-[70vh] rounded border border-line bg-white">>],
                          [{id, <<"doc-frame">>}, {src, Src}, {title, Name}, preserve()]),
             [], [{title, Name},
                  {subtitle, maps:get(<<"source">>, File, <<>>)},
                  {extra, ah_a(<<"新窗口打开"/utf8>>, [<<"text-sm text-primary">>],
                               [{href, Src}, {target, <<"_blank">>}, {rel, <<"noopener">>}])}]),
     ah_card(fields_form(Id, Fields), [], [{title, <<"表单字段"/utf8>>}]),
     ah_card(import_form(Id, Name), [], [{title, <<"复制到电脑"/utf8>>}])].

fields_form(_Id, []) ->
    ah_p(<<"这个 PDF 没有可填写的表单字段。"/utf8>>, [<<"text-sm text-muted">>], []);
fields_form(Id, Fields) ->
    ah_form([[field_input(I, F) || {I, F} <- indexed(Fields)],
             ah_div(ah_button(<<"保存填写后的副本"/utf8>>, fill, [primary, sm], [{type, submit}]), [], [])],
            [<<"flex flex-col gap-3">>], [{id, <<"doc-fill">>}, on(submit, {?MODULE, fill, #{id => Id}})]).

field_input(I, #{<<"name">> := N, <<"type">> := <<"text">>} = F) ->
    ah_field(N, ah_input(maps:get(<<"value">>, F, <<>>), [sm], [{name, field_name(I)}]), [], []);
field_input(I, #{<<"name">> := N, <<"type">> := <<"checkbox">>} = F) ->
    ah_checkbox(N, <<"true">>, [], [{name, field_name(I)}, {checked, maps:get(<<"value">>, F, <<>>) =:= <<"true">>}]);
field_input(_I, #{<<"name">> := N}) ->
    ah_p([N, <<" · 不支持填写的字段类型"/utf8>>], [<<"text-sm text-muted">>], []).

field_name(I) -> <<"f", (integer_to_binary(I))/binary>>.

indexed(Fields) -> lists:zip(lists:seq(0, length(Fields) - 1), Fields).

import_form(Id, Name) ->
    ah_form([ah_field(<<"工作区路径"/utf8>>,
                      ah_input(<<"/workspace/", Name/binary>>, [sm], [{name, path}]), [], []),
             ah_div(ah_button(<<"复制到电脑"/utf8>>, import, [outlined, sm], [{type, submit}]), [], [])],
            [<<"flex flex-col gap-3">>], [{id, <<"doc-import">>}, on(submit, {?MODULE, import, #{id => Id}})]).

%% Actions

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(refresh, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> aihtml_action:html(Ctx, {id, ?LIST}, list_body(Owner)) end);
action(uploaded, _Args, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   aihtml_action:html(Ctx, {id, ?LIST}, list_body(Owner)),
                   case [N || #{<<"name">> := N, <<"id">> := _} <- uploaded(Event)] of
                       [] -> ok;
                       Names -> ?C:notice(Ctx, ?NOTICE, {success, [<<"已上传："/utf8>>, lists:join(<<"、"/utf8>>, Names)]})
                   end,
                   changed(Owner, Ctx)
           end);
action(fill, #{id := Id}, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = maybe
                                {ok, #{<<"fields">> := Fields}} ?= muse_files:get(Owner, Id),
                                Values = maps:from_list(lists:filtermap(fun({I, F}) -> fill_value(I, F, Form) end,
                                                                        indexed(Fields))),
                                muse_files:fill(Owner, Id, Values)
                            end,
                   case Result of
                       {ok, #{<<"id">> := NewId, <<"name">> := NewName}} ->
                           aihtml_action:html(Ctx, {id, ?LIST}, list_body(Owner)),
                           ?C:notice(Ctx, ?NOTICE, {success, [<<"已保存填写后的副本："/utf8>>,
                                                              ah_a(NewName, [<<"underline">>],
                                                                   [{href, <<"/documents/", NewId/binary>>}])]}),
                           changed(Owner, Ctx);
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end);
action(import, #{id := Id}, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Path = string:trim(maps:get(<<"path">>, Form, <<>>)),
                   case muse_computer:import_pdf(Owner, Path, Id) of
                       {ok, _} ->
                           ?C:notice(Ctx, ?NOTICE, {success, [<<"已复制到电脑："/utf8>>, ah_code(Path, [], [])]});
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end).

uploaded(Event) ->
    try [F || F <- aihtml:uploaded_files(Event), is_map(F)]
    catch _:_ -> []
    end.

fill_value(I, #{<<"name">> := N, <<"type">> := <<"text">>}, Form) ->
    {true, {N, maps:get(field_name(I), Form, <<>>)}};
fill_value(I, #{<<"name">> := N, <<"type">> := <<"checkbox">>}, Form) ->
    {true, {N, maps:is_key(field_name(I), Form)}};
fill_value(_, _, _) ->
    false.

%% The owner's other tabs reload the list.
changed(Owner, Ctx) ->
    _ = (catch aihtml_push:publish(muse_ui:topic(Owner, documents),
                                   fun(C) -> aihtml_action:html(C, {id, ?LIST}, list_body(Owner)) end,
                                   #{except => Ctx})),
    ok.
