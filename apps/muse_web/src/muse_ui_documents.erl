%% @doc Files page `/documents[/:id]` (designs/05-web-ui.md §5,
%% tasks/M9-workspace.md M9-6): a file manager after sigil's (the aihtml
%% example `aihtml_example_file_manager`) over muse_files, in the app's
%% shell and table style.
%%
%% `/documents[?folder=<id>]` is the root or one folder:
%% - a header with 新建文件夹 (a window with a name form) and 上传文件 (a
%%   window with `ah_upload`, several files at once, each POSTed to
%%   `/upload` with the folder as an extra field, muse_ui_b_upload);
%% - breadcrumbs from 全部文件 down to the folder;
%% - a toolbar card: search (debounced 250 ms, filtered on the server),
%%   type and time selects, an 已加星标 quick filter and the grid/list
%%   toggle;
%% - a collapsible 文件夹 section (cards with name, file count and size,
%%   counting subfolders; rename, delete with contents after a danger
%%   confirm) and a collapsible 文件 section: cards in the grid view, a
%%   `muse-table` in the list view; every file can be opened, downloaded,
%%   renamed, moved to another folder, deleted (confirmed) and starred.
%% A search, or the starred filter, covers every folder and shows each
%% result's folder.
%%
%% The toolbar state lives in the page: the search box, the two selects and
%% two hidden inputs (view, starred) that `modes/2` re-renders. Every action
%% includes them (`includes/0`), so after any change the page re-renders
%% the sections the way this tab shows them.
%%
%% `/documents/<id>` is one file: breadcrumbs, its details and actions
%% (download, rename, move, delete, star) and a preview by kind: the PDF
%% iframe and its form-field fill (muse_files:fill/3, a filled copy), an
%% `<img>`, an `<audio>`/`<video>` player, text up to 1 MB in a `<pre>`, or
%% just the file's details. Media come from a signed content URL; downloads
%% are an action that sends the browser to a fresh signed URL with
%% `download=1` (signed URLs last 15 minutes).
%%
%% Both pages carry a `doc-sync` element subscribed to the owner's
%% `documents` topic. A change made here publishes a `docs-changed` event
%% to the owner's other tabs; their `doc-sync` element turns it (and a
%% reconnect's refresh) into a `refresh` action with that tab's own state.
-module(muse_ui_documents).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, action/4]).
%% for the chat's reply products (muse_ui_products)
-export([kind_icon/2, kind_label/1]).

-define(C, muse_ui_b_common).
-define(LIST, <<"doc-list">>).
-define(MODES, <<"doc-modes">>).
-define(SYNC, <<"doc-sync">>).
-define(NOTICE, <<"doc-notice">>).
-define(DETAIL, <<"doc-detail">>).
-define(UPLOAD_WIN, <<"doc-upload-win">>).
-define(FOLDER_WIN, <<"doc-folder-win">>).
-define(RENAME_WIN, <<"doc-rename-win">>).
-define(MOVE_WIN, <<"doc-move-win">>).
-define(DIALOG_ERR, <<"doc-dialog-error">>).
-define(TEXT_MAX, 1048576).
-define(CHANGED, <<"docs-changed">>).

-type folder_id() :: binary() | null.
-type state() :: #{q := binary(), type := binary(), time := binary(), view := grid | list,
                   starred := boolean()}.
%% where an action was started: a folder listing, or a file's page
-type origin() :: {list, folder_id()} | {detail, binary()}.

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    case ?C:path_id(Req) of
        undefined ->
            case folder_param(Req) of
                null -> {<<>>, list_page(Owner, null)};
                F -> case muse_files:folder(Owner, F) of
                         {ok, #{<<"id">> := Id, <<"name">> := Name}} -> {Name, list_page(Owner, Id)};
                         {error, _} -> {<<>>, missing_page(<<"找不到该文件夹"/utf8>>,
                                                           <<"文件夹不存在，或已被删除。"/utf8>>)}
                     end
            end;
        Id ->
            case muse_files:get(Owner, Id) of
                {ok, #{<<"name">> := Name} = File} -> {Name, detail_page(Owner, File)};
                {error, _} -> {<<>>, missing_page(<<"找不到该文件"/utf8>>,
                                                  <<"文件不存在，或不属于当前账户。"/utf8>>)}
            end
    end.

folder_param(Req) ->
    case lists:keyfind(<<"folder">>, 1, cowboy_req:parse_qs(Req)) of
        {_, F} when is_binary(F), F =/= <<>>, F =/= <<"root">> -> F;
        _ -> null
    end.

missing_page(Title, Description) ->
    ah_div([ah_a(<<"← 全部文件"/utf8>>, [<<"text-sm text-muted hover:text-primary">>], [{href, <<"/documents">>}]),
            ah_card(ah_empty([], [], [{title, Title}, {description, Description}]), [], [{id, ?DETAIL}])],
           [<<"muse-page">>], []).

%%%===================================================================
%%% The folder listing
%%%===================================================================

list_page(Owner, Folder) ->
    State = default_state(),
    ah_div([header(),
            breadcrumbs(Owner, Folder, []),
            ?C:slot(?NOTICE),
            toolbar(Folder, State),
            ah_div(list_body(Owner, Folder, State), [<<"flex flex-col gap-5">>], [{id, ?LIST}]),
            sync(Owner, #{folder => Folder}),
            upload_window(Folder), folder_window(Folder), rename_window(), move_window()],
           [<<"muse-page">>, <<"muse-files">>], []).

header() ->
    ah_div([?C:page_header(<<"文件"/utf8>>,
                           <<"存放任意类型的文件，用文件夹整理；PDF 可以预览和填写表单。"/utf8>>),
            ah_div([ah_button([muse_ui_icons:icon(folder_plus, 16), <<"新建文件夹"/utf8>>], undefined,
                              [outlined, sm, <<"muse-btn-icon">>],
                              [{id, <<"doc-new-folder">>}, {type, button}, opens({id, ?FOLDER_WIN})]),
                    ah_button([muse_ui_icons:icon(upload, 16), <<"上传文件"/utf8>>], undefined,
                              [primary, sm, <<"muse-btn-icon">>],
                              [{id, <<"doc-upload-open">>}, {type, button}, opens({id, ?UPLOAD_WIN})])],
                   [<<"flex flex-wrap gap-2">>], [])],
           [<<"flex flex-wrap items-end justify-between gap-4">>], []).

%% 全部文件 / folder / ... / (Extra, e.g. a file name)
breadcrumbs(Owner, Folder, Extra) ->
    Path = [{N, folder_href(I)} || #{<<"id">> := I, <<"name">> := N} <- muse_files:folder_path(Owner, Folder)],
    ah_breadcrumbs([{<<"全部文件"/utf8>>, <<"/documents">>} | Path] ++ Extra, [<<"muse-crumbs">>],
                   [{id, <<"doc-crumbs">>}]).

folder_href(null) -> <<"/documents">>;
folder_href(Id) -> <<"/documents?folder=", Id/binary>>.

toolbar(Folder, #{q := Q, type := Type, time := Time} = State) ->
    Filter = {?MODULE, filter, #{folder => Folder}},
    ah_card(ah_div([ah_input(Q, [sm, <<"muse-file-search">>],
                             [{id, <<"doc-q">>}, {name, q}, {placeholder, <<"搜索全部文件…"/utf8>>},
                              {autocomplete, off}, {aria_label, <<"搜索文件"/utf8>>},
                              on(input, Filter, #{debounce => 250, include => includes()})]),
                    ah_select(type_items(), Type, [],
                              [{id, <<"doc-type">>}, {name, type}, {aria_label, <<"文件类型"/utf8>>},
                               on(change, Filter, #{include => includes()})]),
                    ah_select(time_items(), Time, [],
                              [{id, <<"doc-time">>}, {name, time}, {aria_label, <<"修改时间"/utf8>>},
                               on(change, Filter, #{include => includes()})]),
                    ah_div(modes(Folder, State), [<<"muse-file-modes">>], [{id, ?MODES}])],
                   [<<"flex flex-wrap items-center gap-3">>], []),
            [<<"muse-file-toolbar">>], [{id, <<"doc-toolbar">>}]).

type_items() ->
    [{<<"all">>, <<"全部类型"/utf8>>}, {<<"pdf">>, <<"PDF">>}, {<<"image">>, <<"图片"/utf8>>},
     {<<"audio">>, <<"音频"/utf8>>}, {<<"video">>, <<"视频"/utf8>>}, {<<"text">>, <<"文本"/utf8>>},
     {<<"other">>, <<"其他"/utf8>>}].

time_items() ->
    [{<<"all">>, <<"全部时间"/utf8>>}, {<<"today">>, <<"今天"/utf8>>}, {<<"week">>, <<"最近 7 天"/utf8>>},
     {<<"month">>, <<"本月"/utf8>>}].

%% The starred filter, the grid/list toggle and the hidden inputs that keep
%% both for the actions.
modes(Folder, #{view := View, starred := Starred}) ->
    Opts = #{include => includes()},
    [ah_button([<<"★ "/utf8>>, <<"已加星标"/utf8>>], undefined,
               [outlined, sm, <<"muse-star-filter">>, [<<"muse-on">> || Starred]],
               [{id, <<"doc-starred-filter">>}, {type, button}, {aria_pressed, atom_to_binary(Starred)},
                on(click, {?MODULE, filter, #{folder => Folder, set => #{starred => not Starred}}}, Opts)]),
     ah_div([view_button(Folder, V, Label, View) || {V, Label} <- [{grid, <<"网格"/utf8>>}, {list, <<"列表"/utf8>>}]],
            [<<"muse-view-toggle">>], [{role, group}, {aria_label, <<"视图"/utf8>>}]),
     aihtml:ah_void(input, [], [{type, hidden}, {id, <<"doc-view">>}, {value, atom_to_binary(View)}]),
     aihtml:ah_void(input, [], [{type, hidden}, {id, <<"doc-starred">>},
                                {value, case Starred of true -> <<"1">>; false -> <<"0">> end}])].

view_button(Folder, V, Label, View) ->
    ah_button(Label, undefined, [sm, borderless, [<<"muse-on">> || V =:= View]],
              [{id, <<"doc-view-", (atom_to_binary(V))/binary>>}, {type, button},
               {aria_pressed, atom_to_binary(V =:= View)},
               on(click, {?MODULE, filter, #{folder => Folder, set => #{view => V}}}, #{include => includes()})]).

includes() ->
    [{id, <<"doc-q">>}, {id, <<"doc-type">>}, {id, <<"doc-time">>}, {id, <<"doc-view">>}, {id, <<"doc-starred">>}].

-spec default_state() -> state().
default_state() ->
    #{q => <<>>, type => <<"all">>, time => <<"all">>, view => grid, starred => false}.

%% The tab's state from an action's included values, then `Set`.
-spec state(map(), map()) -> state().
state(Event, Set) ->
    Values = case Event of
                 #{values := V} when is_map(V) -> V;
                 _ -> #{}
             end,
    Get = fun(K) -> case maps:get(K, Values, <<>>) of B when is_binary(B) -> B; _ -> <<>> end end,
    State = #{q => string:trim(Get(<<"doc-q">>)),
              type => one_of(Get(<<"doc-type">>), [K || {K, _} <- type_items()]),
              time => one_of(Get(<<"doc-time">>), [K || {K, _} <- time_items()]),
              view => case Get(<<"doc-view">>) of <<"list">> -> list; _ -> grid end,
              starred => Get(<<"doc-starred">>) =:= <<"1">>},
    maps:merge(State, maps:with([view, starred], Set)).

one_of(V, Allowed) ->
    case lists:member(V, Allowed) of
        true -> V;
        false -> <<"all">>
    end.

%% A search or the starred filter covers every folder.
global(#{q := Q, starred := S}) -> Q =/= <<>> orelse S.

list_body(Owner, Folder, State) ->
    Files = muse_files:list(Owner, unsigned),
    Folders = muse_files:folders(Owner),
    Global = global(State),
    Candidates = case Global of
                     true -> Files;
                     false -> [F || F <- Files, muse_files:folder_of(F) =:= Folder]
                 end,
    Shown = lists:sort(fun(A, B) -> modified(A) >= modified(B) end,
                       [F || F <- Candidates, matches(F, State)]),
    [case Global of
         true -> [];
         false -> folders_section(Folder, Folders, Files)
     end,
     files_section(Folder, Shown, State, Folders)].

%% Folders

folders_section(Folder, Folders, Files) ->
    case [F || F = #{<<"parentId">> := P} <- Folders, P =:= Folder] of
        [] -> [];
        Children ->
            ah_expander(ah_div([folder_card(Folder, F, Folders, Files) || F <- Children],
                               [<<"muse-folder-grid">>], []),
                        [<<"muse-file-section">>],
                        [{header, section_header(<<"文件夹"/utf8>>, length(Children))},
                         {expanded, true}, {animation, none}, {id, <<"doc-folders">>}])
    end.

folder_card(Current, #{<<"id">> := Id, <<"name">> := Name}, Folders, Files) ->
    Inside = [Id | descendants(Folders, Id)],
    Contained = [F || F <- Files, lists:member(muse_files:folder_of(F), Inside)],
    Count = length(Contained),
    Size = lists:sum([S || #{<<"size">> := S} <- Contained, is_integer(S)]),
    Href = folder_href(Id),
    Subfolders = length(Inside) - 1,
    Confirm = case Count + Subfolders of
                  0 -> <<"删除空文件夹「"/utf8, Name/binary, "」？"/utf8>>;
                  _ -> iolist_to_binary([<<"「"/utf8>>, Name, <<"」里的 "/utf8>>, integer_to_binary(Count),
                                         <<" 个文件"/utf8>>,
                                         [[<<"和 "/utf8>>, integer_to_binary(Subfolders), <<" 个子文件夹"/utf8>>]
                                          || Subfolders > 0],
                                         <<"会一起删除，无法恢复。"/utf8>>])
              end,
    From = {list, Current},
    ah_div([ah_div([ah_a(muse_ui_icons:icon(folder, 26), [<<"muse-folder-icon">>],
                         [{href, Href}, {tabindex, -1}, {aria_hidden, <<"true">>}]),
                    ah_div([tool(<<"重命名"/utf8>>, {?MODULE, ask_rename, #{type => folder, id => Id, from => From}}, #{}),
                            tool(<<"删除"/utf8>>, {?MODULE, delete_folder, #{id => Id, from => From}},
                                 #{confirm => confirm(<<"删除文件夹"/utf8>>, Confirm)})],
                           [<<"muse-card-tools">>], [])],
                   [<<"flex items-start justify-between gap-2">>], []),
            ah_a(Name, [<<"muse-card-name">>], [{href, Href}, {title, Name}]),
            ah_p([integer_to_binary(Count), <<" 个文件 · "/utf8>>, ?C:size_label(Size)],
                 [<<"text-xs text-muted">>], [])],
           [<<"muse-folder-card">>], [{id, <<"doc-folder-", Id/binary>>}]).

descendants(Folders, Id) ->
    Children = [C || #{<<"id">> := C, <<"parentId">> := P} <- Folders, P =:= Id],
    Children ++ lists:append([descendants(Folders, C) || C <- Children]).

%% Files

files_section(Folder, Files, #{view := View, q := Q, starred := Starred} = State, Folders) ->
    Global = global(State),
    Title = if
                Q =/= <<>> -> <<"搜索结果"/utf8>>;
                Starred -> <<"已加星标"/utf8>>;
                true -> <<"文件"/utf8>>
            end,
    From = {list, Folder},
    Where = case Global of
                true -> maps:from_list([{I, location(I, Folders)} || #{<<"id">> := I} <- Folders]);
                false -> none
            end,
    Body = case {Files, View} of
               {[], _} when Global ->
                   ah_empty([], [compact], [{title, <<"没有匹配的文件"/utf8>>},
                                            {description, <<"换个关键词或筛选条件试试。"/utf8>>}]);
               {[], _} ->
                   ah_empty([], [compact], [{title, <<"这里还没有文件"/utf8>>},
                                            {description, <<"点击「上传文件」添加任意类型的文件。"/utf8>>}]);
               {_, list} ->
                   ?C:table([{<<"名称"/utf8>>, []}, {<<"类型"/utf8>>, [<<"nowrap">>]},
                             {<<"大小"/utf8>>, [<<"num">>]}, {<<"修改时间"/utf8>>, [<<"muted nowrap">>]},
                             {<<"星标"/utf8>>, [<<"nowrap">>]}, {<<"操作"/utf8>>, [<<"actions">>]}],
                            [file_row(F, From, Where) || F <- Files], [{id, <<"doc-table">>}]);
               {_, grid} ->
                   ah_div([file_card(F, From, Where) || F <- Files], [<<"muse-file-grid">>], [{id, <<"doc-grid">>}])
           end,
    ah_expander(Body, [<<"muse-file-section">>],
                [{header, section_header(Title, length(Files))},
                 {expanded, true}, {animation, none}, {id, <<"doc-files">>}]).

section_header(Title, Count) ->
    ah_h2([Title, ah_span(integer_to_binary(Count), [<<"muse-count">>], [])], [<<"muse-section-title">>], []).

file_card(#{<<"id">> := Id, <<"name">> := Name} = F, From, Where) ->
    Href = <<"/documents/", Id/binary>>,
    ah_div([ah_div([kind_chip(F), star_button(F, From)], [<<"flex items-center justify-between gap-2">>], []),
            ah_a([kind_icon(F, 18), ah_span(Name, [<<"truncate">>], [])], [<<"muse-card-name">>],
                 [{href, Href}, {title, Name}]),
            ah_p([?C:size_label(maps:get(<<"size">>, F, undefined)), <<" · "/utf8>>, ?C:time_label(modified_iso(F))],
                 [<<"text-xs text-muted">>], []),
            location_line(F, Where),
            ah_div(file_tools(F, From), [<<"muse-card-tools">>], [])],
           [<<"muse-file-card">>], [{id, <<"doc-", Id/binary>>}]).

file_row(#{<<"id">> := Id, <<"name">> := Name} = F, From, Where) ->
    Href = <<"/documents/", Id/binary>>,
    {[{id, <<"doc-", Id/binary>>}],
     [[ah_a([kind_icon(F, 18), ah_span(Name, [], [])], [<<"muse-table-name">>], [{href, Href}]),
       location_line(F, Where)],
      kind_chip(F),
      ?C:size_label(maps:get(<<"size">>, F, undefined)),
      ?C:time_label(modified_iso(F)),
      star_button(F, From),
      ah_div(file_tools(F, From), [<<"muse-row-tools">>], [])]}.

location_line(_F, none) -> [];
location_line(F, Where) ->
    Label = case muse_files:folder_of(F) of
                null -> <<"全部文件"/utf8>>;
                Id -> maps:get(Id, Where, <<"全部文件"/utf8>>)
            end,
    ah_p([muse_ui_icons:icon(folder, 12), ah_span(Label, [], [])], [<<"muse-file-where">>], []).

%% `A / B / C` for a folder.
location(Id, Folders) ->
    Names = path_names(Id, maps:from_list([{I, F} || F = #{<<"id">> := I} <- Folders]), []),
    iolist_to_binary(lists:join(<<" / ">>, Names)).

path_names(Id, ById, Acc) when is_binary(Id), length(Acc) < 64 ->
    case maps:find(Id, ById) of
        {ok, #{<<"name">> := N, <<"parentId">> := P}} -> path_names(P, ById, [N | Acc]);
        error -> Acc
    end;
path_names(_, _, Acc) ->
    Acc.

file_tools(#{<<"id">> := Id, <<"name">> := Name}, From) ->
    A = #{id => Id, from => From},
    [case From of
         {list, _} -> ah_a(<<"打开"/utf8>>, [<<"muse-tool">>], [{href, <<"/documents/", Id/binary>>}]);
         _ -> []
     end,
     tool(<<"下载"/utf8>>, {?MODULE, download, #{id => Id}}, #{}),
     tool(<<"重命名"/utf8>>, {?MODULE, ask_rename, A#{type => file}}, #{}),
     tool(<<"移动"/utf8>>, {?MODULE, ask_move, A}, #{}),
     tool(<<"删除"/utf8>>, {?MODULE, delete, A},
          #{confirm => confirm(<<"删除文件"/utf8>>,
                               <<"删除「"/utf8, Name/binary, "」？删除后无法恢复。"/utf8>>)})].

tool(Label, Ref, Opts) ->
    ah_button(Label, undefined, [borderless, sm, <<"muse-tool">>],
              [{type, button}, on(click, Ref, Opts#{include => includes()})]).

confirm(Title, Body) ->
    #{title => Title, body => Body, ok => <<"删除"/utf8>>, cancel => <<"取消"/utf8>>, variant => danger}.

star_button(#{<<"id">> := Id} = F, From) ->
    Starred = maps:get(<<"starred">>, F, false) =:= true,
    Label = case Starred of
                true -> <<"取消星标"/utf8>>;
                false -> <<"加星标"/utf8>>
            end,
    ah_button(case Starred of true -> <<"★"/utf8>>; false -> <<"☆"/utf8>> end, undefined,
              [borderless, sm, <<"muse-star">>, [<<"muse-on">> || Starred]],
              [{id, <<"doc-star-", Id/binary>>}, {type, button}, {aria_label, Label}, {title, Label},
               {aria_pressed, atom_to_binary(Starred)},
               on(click, {?MODULE, star, #{id => Id, starred => not Starred, from => From}},
                  #{include => includes()})]).

kind_chip(F) ->
    Kind = muse_files:kind(F),
    ?C:chip(kind_label(Kind), case Kind of
                                  pdf -> error;
                                  image -> info;
                                  audio -> success;
                                  video -> warning;
                                  _ -> default
                              end).

-spec kind_label(muse_files:kind()) -> binary().
kind_label(pdf) -> <<"PDF">>;
kind_label(image) -> <<"图片"/utf8>>;
kind_label(audio) -> <<"音频"/utf8>>;
kind_label(video) -> <<"视频"/utf8>>;
kind_label(text) -> <<"文本"/utf8>>;
kind_label(archive) -> <<"压缩包"/utf8>>;
kind_label(other) -> <<"其他"/utf8>>.

-spec kind_icon(map(), pos_integer()) -> {safe, iodata()}.
kind_icon(F, Size) ->
    muse_ui_icons:icon(case muse_files:kind(F) of
                           image -> image;
                           audio -> music;
                           video -> video;
                           text -> file_text;
                           archive -> archive;
                           _ -> file
                       end, Size).

matches(F, #{q := Q, type := Type, time := Time, starred := Starred}) ->
    (Q =:= <<>> orelse string:find(string:casefold(maps:get(<<"name">>, F, <<>>)), string:casefold(Q)) =/= nomatch)
        andalso type_matches(muse_files:kind(F), Type)
        andalso time_matches(modified(F), Time)
        andalso (not Starred orelse maps:get(<<"starred">>, F, false) =:= true).

type_matches(_, <<"all">>) -> true;
type_matches(Kind, <<"other">>) -> Kind =:= other orelse Kind =:= archive;
type_matches(Kind, Type) -> atom_to_binary(Kind) =:= Type.

time_matches(_, <<"all">>) -> true;
time_matches(Ms, Time) ->
    Now = muse_time:now_ms(),
    {Date, _} = calendar:system_time_to_local_time(Ms, millisecond),
    {Today, _} = calendar:system_time_to_local_time(Now, millisecond),
    case Time of
        <<"today">> -> Date =:= Today;
        <<"week">> -> Now - Ms =< 7 * 86400000;
        <<"month">> -> element(1, Date) =:= element(1, Today) andalso element(2, Date) =:= element(2, Today)
    end.

modified_iso(F) ->
    maps:get(<<"updatedAt">>, F, maps:get(<<"createdAt">>, F, <<>>)).

modified(F) ->
    case muse_time:parse(modified_iso(F)) of
        Ms when is_integer(Ms) -> Ms;
        _ -> 0
    end.

%% Windows

upload_window(Folder) ->
    Max = muse_files:max_bytes(),
    MaxMb = integer_to_binary(Max div 1048576),
    #ah_window{id = ?UPLOAD_WIN, title = <<"上传文件"/utf8>>,
               body = ah_upload([], [],
                                [{id, <<"doc-upload">>}, {url, <<"/upload">>}, {field_name, file},
                                 {multiple, true}, {max_size, Max},
                                 [{extra_data, #{folder => Folder}} || Folder =/= null],
                                 {drag_text, <<"拖拽文件到此处，或"/utf8>>}, {browse_text, <<"点击选择"/utf8>>},
                                 {hint, <<"任意类型，可以多选；单个不超过 "/utf8, MaxMb/binary,
                                          " MB（PDF 不超过 10 MB）"/utf8>>},
                                 {labels, #{too_large => <<"超过 "/utf8, MaxMb/binary, " MB"/utf8>>,
                                            type_mismatch => <<"类型不支持"/utf8>>,
                                            upload_failed => <<"上传失败"/utf8>>, remove => <<"移除"/utf8>>,
                                            network_error => <<"网络错误"/utf8>>}},
                                 on(change, {?MODULE, uploaded, #{folder => Folder}}, #{include => includes()})]),
               footer = ah_button(<<"完成"/utf8>>, undefined, [primary, sm],
                                  [{type, button}, closes({id, ?UPLOAD_WIN})]),
               modal = true, draggable = false, resizable = false, width = 560}.

folder_window(Folder) ->
    #ah_window{id = ?FOLDER_WIN, title = <<"新建文件夹"/utf8>>,
               body = ah_div(folder_form(Folder), [], [{id, <<"doc-folder-body">>}]),
               modal = true, draggable = false, resizable = false, width = 420}.

folder_form(Folder) ->
    name_form(<<"doc-folder-form">>, <<>>, ?FOLDER_WIN, {?MODULE, create_folder, #{parent => Folder}},
              <<"新建"/utf8>>).

rename_window() ->
    #ah_window{id = ?RENAME_WIN, title = <<"重命名"/utf8>>,
               body = ah_div([], [], [{id, <<"doc-rename-body">>}]),
               modal = true, draggable = false, resizable = false, width = 420}.

move_window() ->
    #ah_window{id = ?MOVE_WIN, title = <<"移动到文件夹"/utf8>>,
               body = ah_div([], [], [{id, <<"doc-move-body">>}]),
               modal = true, draggable = false, resizable = false, width = 420}.

name_form(Id, Value, Win, Ref, Ok) ->
    ah_form([ah_field(<<"名称"/utf8>>, ah_input(Value, [], [{name, name}, {id, <<Id/binary, "-name">>},
                                                          {autocomplete, off}, {maxlength, 180}]), [], []),
             ?C:slot(?DIALOG_ERR),
             dialog_buttons(Win, Ok)],
            [<<"flex flex-col gap-4">>], [{id, Id}, on(submit, Ref, #{include => includes()})]).

dialog_buttons(Win, Ok) ->
    ah_div([ah_button(<<"取消"/utf8>>, undefined, [outlined, sm], [{type, button}, closes({id, Win})]),
            ah_button(Ok, undefined, [primary, sm], [{type, submit}])],
           [<<"flex justify-end gap-2">>], []).

move_form(Owner, #{<<"id">> := Id} = File, From) ->
    Folders = muse_files:folders(Owner),
    Items = [{<<"root">>, <<"全部文件（根目录）"/utf8>>} |
             lists:sort(fun({_, A}, {_, B}) -> A =< B end,
                        [{I, <<"全部文件 / "/utf8, (location(I, Folders))/binary>>} || #{<<"id">> := I} <- Folders])],
    Current = case muse_files:folder_of(File) of
                  null -> <<"root">>;
                  F -> F
              end,
    ah_form([ah_p(maps:get(<<"name">>, File), [<<"text-sm font-semibold truncate">>], []),
             ah_field(<<"目标文件夹"/utf8>>, ah_select(Items, Current, [], [{name, folder}, {id, <<"doc-move-folder">>}]),
                      [], []),
             ?C:slot(?DIALOG_ERR),
             dialog_buttons(?MOVE_WIN, <<"移动"/utf8>>)],
            [<<"flex flex-col gap-4">>],
            [{id, <<"doc-move-form">>}, on(submit, {?MODULE, move, #{id => Id, from => From}}, #{include => includes()})]).

%% The owner's other tabs: `docs-changed` (pushed) and the reconnect
%% refresh both run `refresh` with the tab's state.
sync(Owner, Args) ->
    Ref = {?MODULE, refresh, Args},
    ah_div([], [<<"hidden">>], [{id, ?SYNC},
                                subscribe(muse_ui:topic(Owner, documents), #{refresh => Ref}),
                                on(?CHANGED, Ref, #{include => includes()})]).

%%%===================================================================
%%% One file
%%%===================================================================

detail_page(Owner, #{<<"id">> := Id} = File) ->
    ah_div([?C:slot(?NOTICE),
            ah_div(detail(Owner, File), [<<"flex flex-col gap-4">>], [{id, ?DETAIL}]),
            sync(Owner, #{id => Id}),
            rename_window(), move_window()],
           [<<"muse-page">>, <<"muse-files">>], []).

detail(Owner, #{<<"id">> := Id, <<"name">> := Name} = File) ->
    From = {detail, Id},
    Src = muse_signing:signed_path(Owner, <<"/api/files/", Id/binary, "/content">>),
    Meta = [kind_label(muse_files:kind(File)), <<" · "/utf8>>, ?C:size_label(maps:get(<<"size">>, File, undefined)),
            <<" · 修改于 "/utf8>>, ?C:time_label(modified_iso(File)), <<" · "/utf8>>, source(File)],
    [breadcrumbs(Owner, muse_files:folder_of(File), [Name]),
     ah_card(preview(Owner, File, Src), [<<"muse-file-detail">>],
             [{title, Name}, {subtitle, Meta},
              {extra, ah_div([star_button(File, From) | file_tools(File, From)], [<<"muse-card-tools">>], [])}]),
     case muse_files:kind(File) of
         pdf -> ah_card(fields_form(Id, maps:get(<<"fields">>, File, [])), [], [{title, <<"表单字段"/utf8>>}]);
         _ -> []
     end].

preview(Owner, #{<<"id">> := Id, <<"name">> := Name} = File, Src) ->
    case muse_files:kind(File) of
        pdf ->
            [aihtml:ah_el(iframe, [], [<<"w-full h-[70vh] rounded border border-line bg-white">>],
                          [{id, <<"doc-frame">>}, {src, Src}, {title, Name}, preserve()]),
             ah_a(<<"新窗口打开"/utf8>>, [<<"text-sm text-primary">>],
                  [{href, Src}, {target, <<"_blank">>}, {rel, <<"noopener">>}])];
        image ->
            case muse_files:serve(File, false) of
                {_, inline} -> ah_div(ah_img([<<"muse-file-image">>], [{id, <<"doc-image">>}, {src, Src}, {alt, Name},
                                                                       preserve()]),
                                      [<<"muse-file-stage">>], []);
                _ -> no_preview(Id, File)
            end;
        audio ->
            aihtml:ah_el(audio, [], [<<"w-full">>],
                         [{id, <<"doc-audio">>}, {src, Src}, {controls, true}, {preload, metadata}, preserve()]);
        video ->
            ah_div(aihtml:ah_el(video, [], [<<"muse-file-video">>],
                                [{id, <<"doc-video">>}, {src, Src}, {controls, true}, {preload, metadata},
                                 {playsinline, true}, preserve()]),
                   [<<"muse-file-stage">>], []);
        text ->
            case text_of(Owner, File) of
                {ok, Text} -> ah_pre(Text, [<<"muse-file-text">>], [{id, <<"doc-text">>}]);
                error -> no_preview(Id, File)
            end;
        _ ->
            no_preview(Id, File)
    end.

%% Text up to 1 MB that is UTF-8.
text_of(Owner, #{<<"id">> := Id} = File) ->
    case maps:get(<<"size">>, File, 0) of
        Size when is_integer(Size), Size =< ?TEXT_MAX ->
            case muse_files:bytes(Owner, Id) of
                {ok, Bin} ->
                    case unicode:characters_to_binary(Bin) of
                        Text when is_binary(Text) -> {ok, Text};
                        _ -> error
                    end;
                {error, _} -> error
            end;
        _ ->
            error
    end.

no_preview(Id, File) ->
    ah_empty(ah_button([muse_ui_icons:icon(download, 16), <<"下载"/utf8>>], undefined,
                       [primary, sm, <<"muse-btn-icon">>],
                       [{id, <<"doc-download">>}, {type, button}, on(click, {?MODULE, download, #{id => Id}})]),
             [],
             [{title, <<"这种文件无法在这里预览"/utf8>>},
              {description, [maps:get(<<"mimeType">>, File, <<>>), <<" · "/utf8>>,
                             ?C:size_label(maps:get(<<"size">>, File, undefined)),
                             <<"。下载后用合适的应用打开。"/utf8>>]}]).

%% The stored source is OpenMuse's English text.
source(F) ->
    case maps:get(<<"source">>, F, <<>>) of
        <<"Uploaded by you">> -> <<"你上传的"/utf8>>;
        S -> S
    end.

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

%%%===================================================================
%%% Actions
%%%===================================================================

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(filter, Args, Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) ->
                                    show_list(Ctx, Owner, maps:get(folder, Args, null),
                                              state(Event, maps:get(set, Args, #{})))
                            end);
action(refresh, #{id := Id}, Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> show(Ctx, Owner, {detail, Id}, Event) end);
action(refresh, Args, Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> show(Ctx, Owner, {list, maps:get(folder, Args, null)}, Event) end);
action(uploaded, Args, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   show(Ctx, Owner, {list, maps:get(folder, Args, null)}, Event),
                   case [N || #{<<"name">> := N, <<"id">> := _} <- uploaded(Event)] of
                       [] -> ok;
                       Names -> ?C:notice(Ctx, ?NOTICE, {success, [<<"已上传："/utf8>>, lists:join(<<"、"/utf8>>, Names)]})
                   end,
                   changed(Owner, Ctx)
           end);
action(star, #{id := Id, starred := Starred, from := From}, Event, Ctx) ->
    with_result(Ctx, fun(Owner) -> muse_files:update(Owner, Id, #{<<"starred">> => Starred =:= true}) end,
                From, Event, none);
action(download, #{id := Id}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_files:get(Owner, Id) of
                       {ok, #{<<"id">> := FileId}} ->
                           Path = muse_signing:signed_path(Owner, <<"/api/files/", FileId/binary, "/content">>),
                           aihtml_action:redirect(Ctx, <<Path/binary, "&download=1">>);
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end);
action(ask_rename, #{type := Type, id := Id, from := From}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Current = case Type of
                                 file -> muse_files:get(Owner, Id);
                                 folder -> muse_files:folder(Owner, Id)
                             end,
                   case Current of
                       {ok, #{<<"name">> := Name}} ->
                           Form = name_form(<<"doc-rename-form">>, Name, ?RENAME_WIN,
                                            {?MODULE, rename, #{type => Type, id => Id, from => From}},
                                            <<"保存"/utf8>>),
                           aihtml_action:html(Ctx, {id, <<"doc-rename-body">>}, Form),
                           aihtml_lib_overlay:open(Ctx, {id, ?RENAME_WIN});
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end);
action(rename, #{type := Type, id := Id, from := From}, Event, Ctx) ->
    Name = form_value(Event, <<"name">>),
    dialog_result(Ctx, ?RENAME_WIN,
                  fun(Owner) ->
                          case Type of
                              file -> muse_files:update(Owner, Id, #{<<"name">> => Name});
                              folder -> muse_files:rename_folder(Owner, Id, Name)
                          end
                  end, From, Event, <<"已重命名"/utf8>>);
action(ask_move, #{id := Id, from := From}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_files:get(Owner, Id) of
                       {ok, File} ->
                           aihtml_action:html(Ctx, {id, <<"doc-move-body">>}, move_form(Owner, File, From)),
                           aihtml_lib_overlay:open(Ctx, {id, ?MOVE_WIN});
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end);
action(move, #{id := Id, from := From}, Event, Ctx) ->
    Target = case form_value(Event, <<"folder">>) of
                 F when F =:= <<"root">>; F =:= <<>> -> null;
                 F -> F
             end,
    dialog_result(Ctx, ?MOVE_WIN, fun(Owner) -> muse_files:update(Owner, Id, #{<<"folderId">> => Target}) end,
                  From, Event, <<"已移动"/utf8>>);
action(create_folder, #{parent := Parent}, Event, Ctx) ->
    Name = form_value(Event, <<"name">>),
    dialog_result(Ctx, ?FOLDER_WIN,
                  fun(Owner) ->
                          case muse_files:create_folder(Owner, Name, Parent) of
                              {ok, _} = Ok ->
                                  aihtml_action:html(Ctx, {id, <<"doc-folder-body">>}, folder_form(Parent)),
                                  Ok;
                              Error ->
                                  Error
                          end
                  end, {list, Parent}, Event, <<"已新建文件夹"/utf8>>);
action(delete, #{id := Id, from := From}, Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Folder = case muse_files:get(Owner, Id) of
                                {ok, F} -> muse_files:folder_of(F);
                                _ -> null
                            end,
                   case {muse_files:delete(Owner, Id), From} of
                       {ok, {detail, _}} ->
                           changed(Owner, Ctx),
                           aihtml_action:redirect(Ctx, folder_href(Folder));
                       {ok, _} ->
                           ?C:notice(Ctx, ?NOTICE, {success, <<"已删除"/utf8>>}),
                           show(Ctx, Owner, From, Event),
                           changed(Owner, Ctx);
                       {Error, _} ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end);
action(delete_folder, #{id := Id, from := From}, Event, Ctx) ->
    with_result(Ctx, fun(Owner) -> muse_files:delete_folder(Owner, Id, true) end, From, Event,
                <<"已删除文件夹"/utf8>>);
action(fill, #{id := Id}, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Result = maybe
                                {ok, #{<<"fields">> := Fields}} ?= muse_files:get_pdf(Owner, Id),
                                Values = maps:from_list(lists:filtermap(fun({I, F}) -> fill_value(I, F, Form) end,
                                                                        indexed(Fields))),
                                muse_files:fill(Owner, Id, Values)
                            end,
                   case Result of
                       {ok, #{<<"id">> := NewId, <<"name">> := NewName}} ->
                           ?C:notice(Ctx, ?NOTICE, {success, [<<"已保存填写后的副本："/utf8>>,
                                                              ah_a(NewName, [<<"underline">>],
                                                                   [{href, <<"/documents/", NewId/binary>>}])]}),
                           changed(Owner, Ctx);
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end).

%% Run `Fun(Owner)`; on success re-render where the action came from and
%% tell the other tabs, with an optional notice.
with_result(Ctx, Fun, From, Event, Done) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case Fun(Owner) of
                       {ok, _} ->
                           case Done of
                               none -> ok;
                               _ -> ?C:notice(Ctx, ?NOTICE, {success, Done})
                           end,
                           show(Ctx, Owner, From, Event),
                           changed(Owner, Ctx);
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                   end
           end).

%% A dialog's submit: on success close the window; an error stays in it.
dialog_result(Ctx, Win, Fun, From, Event, Done) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case Fun(Owner) of
                       {ok, _} ->
                           aihtml_lib_overlay:close(Ctx, {id, Win}),
                           ?C:notice(Ctx, ?NOTICE, {success, Done}),
                           show(Ctx, Owner, From, Event),
                           changed(Owner, Ctx);
                       Error ->
                           ?C:notice(Ctx, ?DIALOG_ERR, {error, ?C:error_text(Error)})
                   end
           end).

%% Re-render a listing (with the tab's state) or a file's page.
-spec show(aihtml_action:ctx(), binary(), origin(), map()) -> ok.
show(Ctx, Owner, {list, Folder}, Event) ->
    show_list(Ctx, Owner, Folder, state(Event, #{}));
show(Ctx, Owner, {detail, Id}, _Event) ->
    case muse_files:get(Owner, Id) of
        {ok, File} -> aihtml_action:html(Ctx, {id, ?DETAIL}, detail(Owner, File));
        {error, _} -> aihtml_action:html(Ctx, {id, ?DETAIL},
                                         ah_card(ah_empty([], [], [{title, <<"找不到该文件"/utf8>>},
                                                                   {description, <<"它可能已被删除。"/utf8>>}]),
                                                 [], []))
    end.

show_list(Ctx, Owner, Folder, State) ->
    Exists = Folder =:= null orelse element(1, muse_files:folder(Owner, Folder)) =:= ok,
    aihtml_action:html(Ctx, {id, ?MODES}, modes(Folder, State)),
    aihtml_action:html(Ctx, {id, ?LIST},
                       case Exists of
                           true -> list_body(Owner, Folder, State);
                           false -> ah_empty([], [compact], [{title, <<"这个文件夹已被删除"/utf8>>},
                                                             {description, ah_a(<<"回到全部文件"/utf8>>,
                                                                                [<<"text-primary">>],
                                                                                [{href, <<"/documents">>}])}])
                       end).

form_value(Event, Key) ->
    case Event of
        #{form := #{Key := V}} when is_binary(V) -> V;
        _ -> <<>>
    end.

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

%% The owner's other tabs refresh themselves (each with its own folder,
%% filters and view).
changed(Owner, Ctx) ->
    _ = (catch aihtml_push:publish(muse_ui:topic(Owner, documents),
                                   fun(C) -> aihtml_action:trigger(C, {id, ?SYNC}, ?CHANGED, #{}) end,
                                   #{except => Ctx})),
    ok.
