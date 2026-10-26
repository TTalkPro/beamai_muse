%% @doc Linux computer page `/computer` (designs/05-web-ui.md §5,
%% tasks/M6-ui.md M6-5) over muse_computer: status with start/stop, a
%% terminal whose command runs in a long action that streams into a `<pre>`
%% (`aihtml_action:text/4` + `flush/1`), the /workspace file tree (ah_tree,
%% directories loaded lazily), a text editor with save, mkdir, and PDF copies
%% between Documents and the workspace.
%%
%% Without COMPUTER_ENABLED (sample installs, no Docker) the page shows the
%% "not configured" state from the computer snapshot.
%%
%% With the desktop variant (COMPUTER_DESKTOP=true) a running computer also
%% gets a desktop card over muse_computer_desktop: a live screenshot
%% refreshed every 2 s (`poll`; each refresh loads a signed `?live=1` frame),
%% a click on it is a left_click at the event `pointer` scaled to 1280x800
%% (as on the browser console), type and key forms, scroll and a screenshot
%% button. Each action leaves a `computer-desktop-actions` receipt like the
%% agent's use_desktop.
-module(muse_ui_computer).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, action/4]).

-define(C, muse_ui_b_common).
-define(MAIN, <<"comp-main">>).
-define(NOTICE, <<"comp-notice">>).
-define(TERM, <<"comp-term">>).
-define(FILES, <<"comp-files">>).
-define(EDITOR, <<"comp-editor">>).
-define(HISTORY, <<"comp-history">>).
-define(CHUNK, 4096).
-define(SHOT, <<"comp-desktop-shot">>).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, _Req) ->
    {<<>>, ah_div([?C:page_header(<<"Linux 电脑"/utf8>>,
                                  <<"在隔离的电脑里运行命令、浏览和编辑 /workspace 里的文件。"/utf8>>),
                   ?C:slot(?NOTICE),
                   ah_div(main(Owner), [<<"flex flex-col gap-6">>], [{id, ?MAIN}])],
                  [<<"muse-page">>], [])}.

main(Owner) ->
    Snapshot = muse_computer:snapshot(Owner),
    case Snapshot of
        #{<<"enabled">> := false} ->
            ah_card(ah_empty([], [], [{title, <<"电脑未配置"/utf8>>},
                                      {description, [maps:get(<<"message">>, Snapshot, <<>>), <<" "/utf8>>,
                                                     <<"（服务器需设置 COMPUTER_ENABLED=true 并构建本地电脑镜像。）"/utf8>>]}]),
                    [], [{id, <<"comp-unconfigured">>}]);
        #{<<"status">> := Status} ->
            [status_card(Snapshot),
             case Status =:= <<"running">> andalso muse_computer_desktop:enabled() of
                 true -> desktop_card(Owner);
                 false -> []
             end,
             terminal_card(Snapshot),
             case Status of
                 <<"running">> -> files_card(Owner);
                 _ -> ah_card(ah_p(<<"启动电脑后即可浏览和编辑 /workspace 中的文件。"/utf8>>,
                                   [<<"text-sm text-muted">>], []),
                              [], [{title, <<"文件"/utf8>>}])
             end]
    end.

status_card(#{<<"status">> := Status} = S) ->
    {Label, Color} = case Status of
                         <<"running">> -> {<<"运行中"/utf8>>, success};
                         <<"stopped">> -> {<<"已停止"/utf8>>, default};
                         <<"error">> -> {<<"出错"/utf8>>, error};
                         _ -> {Status, default}
                     end,
    Running = Status =:= <<"running">>,
    ah_card([ah_div([?C:chip(Label, Color),
                     ah_span([case maps:get(<<"provider">>, S, <<>>) of
                                  <<"docker">> -> <<"Docker 容器"/utf8>>;
                                  P -> P
                              end,
                              <<" · "/utf8>>,
                              case maps:get(<<"network">>, S, <<>>) of
                                  <<"disabled">> -> <<"不联网"/utf8>>;
                                  N -> [<<"网络 "/utf8>>, N]
                              end,
                              <<" · 文件保存在 /workspace"/utf8>>],
                             [<<"text-sm text-muted">>], [])],
                    [<<"flex items-center gap-3 flex-wrap">>], [{id, <<"comp-status">>}]),
             case maps:get(<<"message">>, S, undefined) of
                 Msg when is_binary(Msg), Status =:= <<"error">> -> ?C:notice_html(error, Msg);
                 _ -> []
             end],
            [], [{title, <<"状态"/utf8>>},
                 %% one button that follows the state
                 {extra, case Running of
                             false -> ah_button(<<"启动电脑"/utf8>>, start, [primary],
                                                [on(click, {?MODULE, start, #{}}, #{indicator => this})]);
                             true -> ah_button(<<"停止电脑"/utf8>>, stop, [outlined],
                                               [on(click, {?MODULE, stop, #{}},
                                                   #{confirm => <<"停止电脑会中断正在运行的命令，确定吗？"/utf8>>,
                                                     indicator => this})])
                         end}]).

desktop_card(Owner) ->
    Act = fun(Label, Name, Style, Action) ->
                  ah_button(Label, Name, [Style, sm],
                            [on(click, {?MODULE, desktop_act, #{action => Action}}, #{indicator => this})])
          end,
    %% the screen first; typing, keys and the other actions under it
    ah_card(ah_div([ah_div(ah_img([<<"muse-shot block w-full h-auto cursor-crosshair">>],
                           [{id, ?SHOT}, {src, muse_computer_desktop:frame_url(Owner)}, {draggable, false},
                            {alt, <<"桌面画面，点击在对应位置单击"/utf8>>},
                            aihtml:poll(2000, {?MODULE, desktop_frame, #{}}),
                            on(click, {?MODULE, desktop_click, #{}}, #{indicator => this})]),
                    [<<"rounded-2xl border border-line overflow-hidden bg-black">>],
                    [{id, <<"comp-desktop-stage">>}]),
             ah_div([ah_form([ah_input(<<>>, [<<"flex-1">>],
                               [{name, text}, {id, <<"comp-desktop-text">>}, {autocomplete, off},
                                {placeholder, <<"键入到桌面的文字"/utf8>>}]),
                      ah_button(<<"键入"/utf8>>, type, [outlined, sm], [{type, submit}])],
                     [<<"flex gap-2 items-center">>],
                     [{id, <<"comp-desktop-type">>}, on(submit, {?MODULE, desktop_type, #{}}, #{indicator => this})]),
             ah_form([ah_input(<<>>, [<<"flex-1 font-mono">>],
                               [{name, keys}, {id, <<"comp-desktop-keys">>}, {autocomplete, off},
                                {spellcheck, false}, {placeholder, <<"Return、ctrl+s、alt+F4"/utf8>>}]),
                      ah_button(<<"按键"/utf8>>, key, [outlined, sm], [{type, submit}])],
                     [<<"flex gap-2 items-center">>],
                     [{id, <<"comp-desktop-key">>}, on(submit, {?MODULE, desktop_key, #{}}, #{indicator => this})])],
                    [<<"grid gap-2 sm:grid-cols-2">>], []),
             ah_div([Act(<<"截图"/utf8>>, shot, primary, screenshot),
                     Act(<<"向上滚动"/utf8>>, up, outlined, scroll_up),
                     Act(<<"向下滚动"/utf8>>, down, outlined, scroll_down)],
                    [<<"flex gap-2 flex-wrap">>], [{id, <<"comp-desktop-actions">>}]),
             ah_p(<<"画面每 2 秒刷新；点击画面即在对应位置单击。可用 xterm、LibreOffice 和 mupdf（右键桌面，或在终端里用 gui 启动）。电脑不联网、没有浏览器，上网请用“浏览器”页面。"/utf8>>,
                  [<<"text-xs text-muted">>], [])],
                   [<<"flex flex-col gap-3">>], []),
            [], [{title, <<"桌面"/utf8>>},
                 {subtitle, <<"图形桌面（1280×800）。动作和智能体的 use_desktop 一样会留下记录。"/utf8>>}]).

terminal_card(#{<<"workspacePath">> := Ws} = S) ->
    ah_card([ah_form([ah_input(<<>>, [<<"flex-1 font-mono">>],
                               [{name, command}, {id, <<"comp-command">>}, {placeholder, <<"ls -la /workspace">>},
                                {autocomplete, off}, {spellcheck, false}]),
                      ah_input(Ws, [<<"w-48 font-mono">>], [{name, cwd}, {aria_label, <<"工作目录"/utf8>>}]),
                      ah_button(<<"运行"/utf8>>, run, [primary], [{type, submit}])],
                     [<<"flex gap-2 items-center flex-wrap">>],
                     [{id, <<"comp-run">>}, on(submit, {?MODULE, run, #{}}, #{indicator => this})]),
             case muse_computer_desktop:enabled() of
                 true -> ah_p([<<"图形程序请用 "/utf8>>, ah_code(<<"gui 程序名"/utf8>>, [], []),
                               <<" 启动（如 "/utf8>>, ah_code(<<"gui xterm">>, [], []), <<"），"/utf8>>,
                               <<"它会在桌面上打开，命令立即返回；直接运行会一直占着终端，30 秒后被超时结束。"/utf8>>],
                              [<<"text-xs text-muted mt-2 mb-1">>], [{id, <<"comp-gui-hint">>}]);
                 false -> []
             end,
             ah_pre([], [<<"muse-terminal bg-surface border border-line rounded p-3 min-h-[8rem] max-h-[60vh] overflow-auto">>],
                    [{id, ?TERM}, {data_ah, <<"muse-scroll">>}, {aria_live, polite}]),
             ah_div(history(maps:get(<<"commands">>, S, [])), [], [{id, ?HISTORY}])],
            [], [{title, <<"终端"/utf8>>}, {subtitle, <<"命令在工作目录中运行，输出逐段显示。"/utf8>>}]).

history([]) -> [];
history(Commands) ->
    aihtml:ah_el(details,
                 [aihtml:ah_el(summary, <<"最近的命令"/utf8>>, [<<"cursor-pointer text-sm text-muted">>], []),
                  ah_ul([ah_li([ah_code(C, [<<"break-all">>], []), <<" "/utf8>>,
                              ?C:chip(status_label(St), status_color(St)),
                              ah_span(?C:time_label(maps:get(<<"startedAt">>, R, <<>>)),
                                      [<<"text-xs text-muted">>], [])],
                             [<<"flex items-center gap-2 flex-wrap">>], [])
                       || R = #{<<"command">> := C, <<"status">> := St} <- lists:sublist(Commands, 10)],
                        [<<"flex flex-col gap-1 text-sm mt-2">>], [])],
                 [], []).

status_label(<<"succeeded">>) -> <<"成功"/utf8>>;
status_label(<<"failed">>) -> <<"失败"/utf8>>;
status_label(<<"running">>) -> <<"运行中"/utf8>>;
status_label(<<"timed_out">>) -> <<"超时"/utf8>>;
status_label(<<"interrupted">>) -> <<"已中断"/utf8>>;
status_label(S) -> S.

status_color(<<"succeeded">>) -> success;
status_color(<<"running">>) -> info;
status_color(_) -> error.

files_card(Owner) ->
    ah_card(ah_div(files_body(Owner), [<<"flex flex-col gap-4">>], [{id, ?FILES}]),
            [], [{title, <<"文件"/utf8>>},
                 {extra, ah_button(<<"刷新"/utf8>>, refresh_files, [borderless, sm],
                                   [on(click, {?MODULE, refresh_files, #{}})])}]).

files_body(Owner) ->
    Tree = case muse_computer:list(Owner) of
               {ok, #{<<"entries">> := Entries}} ->
                   case Entries of
                       [] -> ah_p(<<"/workspace 是空的。"/utf8>>, [<<"text-sm text-muted">>], []);
                       _ -> ah_tree(tree_items(Entries), undefined, [<<"font-mono text-sm">>],
                                    [{id, <<"comp-tree">>}, {load, {?MODULE, load_dir, #{}}},
                                     on(change, {?MODULE, open, #{}})])
                   end;
               Error ->
                   ?C:notice_html(error, ?C:error_text(Error))
           end,
    [ah_div([ah_div(Tree, [<<"md:w-1/3 min-w-0 max-h-[60vh] overflow-auto">>], []),
             ah_div(ah_p(<<"在左侧选择一个文件进行编辑。"/utf8>>, [<<"text-sm text-muted">>], []),
                    [<<"flex-1 min-w-0">>], [{id, ?EDITOR}])],
            [<<"flex flex-col md:flex-row gap-4">>], []),
     ah_div([mkdir_form(), import_form(Owner)], [<<"grid md:grid-cols-2 gap-4">>], [])].

tree_items(Entries) ->
    [case Type of
         <<"directory">> -> #{value => <<"d:", P/binary>>, label => Name, lazy => true};
         _ -> #{value => <<"f:", P/binary>>, label => Name}
     end || #{<<"name">> := Name, <<"path">> := P, <<"type">> := Type} <- Entries].

mkdir_form() ->
    ah_form([ah_field(<<"新建文件夹"/utf8>>, ah_input(<<"/workspace/">>, [sm, <<"font-mono">>], [{name, path}]), [], []),
             ah_div(ah_button(<<"创建"/utf8>>, mkdir, [outlined, sm], [{type, submit}]), [], [])],
            [<<"flex flex-col gap-2">>], [{id, <<"comp-mkdir">>}, on(submit, {?MODULE, mkdir, #{}})]).

import_form(Owner) ->
    case muse_files:list(Owner, unsigned) of
        [] ->
            ah_p(<<"文档中还没有 PDF，可在“文档”页上传后复制到这里。"/utf8>>, [<<"text-sm text-muted">>], []);
        [#{<<"name">> := First} | _] = Files ->
            ah_form([ah_field(<<"从文档导入 PDF"/utf8>>,
                              ah_select([{Id, Name} || #{<<"id">> := Id, <<"name">> := Name} <- Files],
                                        undefined, [sm], [{name, fileId}]), [], []),
                     ah_field(<<"保存到"/utf8>>, ah_input(<<"/workspace/", First/binary>>, [sm, <<"font-mono">>],
                                                       [{name, path}]), [], []),
                     ah_div(ah_button(<<"导入"/utf8>>, import, [outlined, sm], [{type, submit}]), [], [])],
                    [<<"flex flex-col gap-2">>], [{id, <<"comp-import">>}, on(submit, {?MODULE, import, #{}})])
    end.

editor(Path, Text) ->
    ah_form([ah_div([ah_code(Path, [<<"text-sm break-all">>], []),
                     ah_div([[ah_button(<<"导出到文档"/utf8>>, export, [outlined, sm],
                                        [on(click, {?MODULE, export, #{path => Path}})]) || is_pdf(Path)],
                             ah_button(<<"保存"/utf8>>, save, [primary, sm], [{type, submit}])],
                            [<<"flex gap-2">>], [])],
                    [<<"flex items-center justify-between gap-2">>], []),
             ah_textarea(Text, [<<"font-mono text-sm w-full">>], [{name, text}, {rows, 20}, {spellcheck, false},
                                                                  {id, <<"comp-text">>}])],
            [<<"flex flex-col gap-2">>], [{id, <<"comp-edit">>}, on(submit, {?MODULE, save, #{path => Path}})]).

pdf_panel(Path) ->
    ah_div([ah_code(Path, [<<"text-sm break-all">>], []),
            ah_p(<<"PDF 文件不能在这里编辑，可以导出到“文档”后预览或填写。"/utf8>>, [<<"text-sm text-muted">>], []),
            ah_div(ah_button(<<"导出到文档"/utf8>>, export, [outlined, sm],
                             [on(click, {?MODULE, export, #{path => Path}})]), [], [])],
           [<<"flex flex-col gap-2">>], []).

is_pdf(Path) ->
    string:lowercase(filename:extension(Path)) =:= <<".pdf">>.

%% Actions

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(start, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> after_op(Ctx, Owner, muse_computer:start(Owner), <<"电脑已启动。"/utf8>>) end);
action(stop, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> after_op(Ctx, Owner, muse_computer:stop(Owner), <<"电脑已停止。"/utf8>>) end);
action(run, _Args, #{form := Form}, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> run(Ctx, Owner, Form) end);
action(refresh_files, _Args, _Event, Ctx) ->
    muse_ui:with_owner(Ctx, fun(Owner) -> aihtml_action:html(Ctx, {id, ?FILES}, files_body(Owner)) end);
action(load_dir, _Args, #{data := Data} = Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Items = case maps:get(<<"value">>, Data, <<>>) of
                               <<"d:", Path/binary>> ->
                                   case muse_computer:list(Owner, Path) of
                                       {ok, #{<<"entries">> := Entries}} -> tree_items(Entries);
                                       Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)}), []
                                   end;
                               _ -> []
                           end,
                   aihtml:set_children(Ctx, Event, Items)
           end);
action(open, _Args, #{value := Value}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case Value of
                       <<"f:", Path/binary>> ->
                           case is_pdf(Path) of
                               true -> aihtml_action:html(Ctx, {id, ?EDITOR}, pdf_panel(Path));
                               false ->
                                   case muse_computer:read(Owner, Path) of
                                       {ok, #{<<"text">> := Text}} ->
                                           ?C:notice(Ctx, ?NOTICE, clear),
                                           aihtml_action:html(Ctx, {id, ?EDITOR}, editor(Path, Text));
                                       Error ->
                                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                                   end
                           end;
                       _ ->
                           ok
                   end
           end);
action(save, #{path := Path}, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Text = maps:get(<<"text">>, Form, <<>>),
                   Notice = case muse_computer:write(Owner, Path, Text) of
                                {ok, _} -> {success, [<<"已保存 "/utf8>>, ah_code(Path, [], [])]};
                                Error -> {error, ?C:error_text(Error)}
                            end,
                   ?C:notice(Ctx, ?NOTICE, Notice)
           end);
action(mkdir, _Args, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Path = string:trim(maps:get(<<"path">>, Form, <<>>)),
                   files_op(Ctx, Owner, muse_computer:mkdir(Owner, Path), [<<"已创建 "/utf8>>, ah_code(Path, [], [])])
           end);
action(import, _Args, #{form := Form}, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Path = string:trim(maps:get(<<"path">>, Form, <<>>)),
                   FileId = maps:get(<<"fileId">>, Form, <<>>),
                   files_op(Ctx, Owner, muse_computer:import_pdf(Owner, Path, FileId),
                            [<<"已导入到 "/utf8>>, ah_code(Path, [], [])])
           end);
action(export, #{path := Path}, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   Notice = case muse_computer:export_pdf(Owner, Path) of
                                {ok, #{<<"id">> := Id, <<"name">> := Name}} ->
                                    {success, [<<"已导出到文档："/utf8>>,
                                               ah_a(Name, [<<"underline">>], [{href, <<"/documents/", Id/binary>>}])]};
                                Error ->
                                    {error, ?C:error_text(Error)}
                            end,
                   ?C:notice(Ctx, ?NOTICE, Notice)
           end);
action(desktop_frame, _Args, _Event, Ctx) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) -> aihtml_action:attr(Ctx, {id, ?SHOT}, src, muse_computer_desktop:frame_url(Owner)) end);
action(desktop_act, #{action := Action}, _Event, Ctx) ->
    desktop_act(Ctx, case Action of
                         screenshot -> #{<<"action">> => <<"screenshot">>};
                         scroll_up -> #{<<"action">> => <<"scroll">>, <<"scroll_direction">> => <<"up">>};
                         scroll_down -> #{<<"action">> => <<"scroll">>, <<"scroll_direction">> => <<"down">>}
                     end);
action(desktop_click, _Args, Event, Ctx) ->
    case muse_ui_browser:scale(maps:get(pointer, Event, null)) of
        {X, Y} -> desktop_act(Ctx, #{<<"action">> => <<"left_click">>, <<"coordinate">> => [X, Y]});
        undefined -> ok
    end;
action(desktop_type, _Args, #{form := Form}, Ctx) ->
    case maps:get(<<"text">>, Form, <<>>) of
        <<>> -> ok;
        Text ->
            case desktop_act(Ctx, #{<<"action">> => <<"type">>, <<"text">> => Text}) of
                ok -> aihtml_action:set_value(Ctx, {id, <<"comp-desktop-text">>}, <<>>);
                error -> ok
            end
    end;
action(desktop_key, _Args, #{form := Form}, Ctx) ->
    case string:trim(maps:get(<<"keys">>, Form, <<>>)) of
        <<>> -> ok;
        Keys -> desktop_act(Ctx, #{<<"action">> => <<"key">>, <<"text">> => Keys})
    end.

%% One desktop action; the screenshot it took replaces the picture until
%% the next refresh.
desktop_act(Ctx, Action) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case muse_computer_desktop:desktop_action(Owner, Action) of
                       {ok, #{receipt := #{<<"id">> := Id} = R, data := Data, warning := Warning}} ->
                           case Data of
                               <<>> -> ok;
                               _ -> aihtml_action:attr(Ctx, {id, ?SHOT}, src,
                                                       muse_computer_desktop:screenshot_url(Owner, Id))
                           end,
                           ?C:notice(Ctx, ?NOTICE,
                                     case Warning of
                                         undefined -> {success, maps:get(<<"command">>, R, <<>>)};
                                         _ -> {warning, Warning}
                                     end),
                           ok;
                       Error ->
                           ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)}),
                           error
                   end
           end).

after_op(Ctx, Owner, Result, Done) ->
    case Result of
        {ok, _} -> ?C:notice(Ctx, ?NOTICE, {success, Done});
        Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
    end,
    aihtml_action:html(Ctx, {id, ?MAIN}, main(Owner)).

files_op(Ctx, Owner, Result, Done) ->
    case Result of
        {ok, _} ->
            ?C:notice(Ctx, ?NOTICE, {success, Done}),
            aihtml_action:html(Ctx, {id, ?FILES}, files_body(Owner));
        Error ->
            ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
    end.

%% The command runs in this request process (it is the cancel process: a
%% client that goes away interrupts it). The echo goes out first, then the
%% receipt's output in chunks, each flushed as it is written.
run(Ctx, Owner, Form) ->
    Command = maps:get(<<"command">>, Form, <<>>),
    Cwd = case string:trim(maps:get(<<"cwd">>, Form, <<>>)) of
              <<>> -> <<"/workspace">>;
              C -> C
          end,
    aihtml_action:text(Ctx, {id, ?TERM}, [<<"$ ">>, Command, <<"\n">>], append),
    aihtml_action:flush(Ctx),
    case muse_computer:execute(Owner, #{<<"command">> => Command, <<"cwd">> => Cwd}, #{cancel => self()}) of
        {ok, Receipt} ->
            stream(Ctx, maps:get(<<"stdout">>, Receipt, <<>>)),
            stream(Ctx, maps:get(<<"stderr">>, Receipt, <<>>)),
            Status = maps:get(<<"status">>, Receipt, <<>>),
            Exit = case maps:get(<<"exitCode">>, Receipt, undefined) of
                       N when is_integer(N) -> [<<"退出码 "/utf8>>, integer_to_binary(N), <<" · "/utf8>>];
                       _ -> []
                   end,
            Trunc = case maps:get(<<"truncated">>, Receipt, false) of
                        true -> <<" · 输出已截断"/utf8>>;
                        _ -> <<>>
                    end,
            aihtml_action:text(Ctx, {id, ?TERM}, [<<"[">>, Exit, status_label(Status), Trunc, <<"]\n\n">>], append),
            aihtml_action:html(Ctx, {id, ?HISTORY}, history(maps:get(<<"commands">>, muse_computer:snapshot(Owner), [])));
        Error ->
            aihtml_action:text(Ctx, {id, ?TERM}, [<<"[错误] "/utf8>>, ?C:error_text(Error), <<"\n\n">>], append)
    end.

stream(_Ctx, <<>>) ->
    ok;
stream(Ctx, Out) ->
    {Chunk, Rest} = split(Out),
    aihtml_action:text(Ctx, {id, ?TERM}, Chunk, append),
    aihtml_action:flush(Ctx),
    case Rest of
        <<>> ->
            case binary:last(Chunk) of
                $\n -> ok;
                _ -> aihtml_action:text(Ctx, {id, ?TERM}, <<"\n">>, append)
            end;
        _ ->
            stream(Ctx, Rest)
    end.

%% A chunk of about 4 KB, cut at a UTF-8 character boundary.
split(Bin) when byte_size(Bin) =< ?CHUNK ->
    {Bin, <<>>};
split(Bin) ->
    Cut = boundary(Bin, ?CHUNK),
    <<Chunk:Cut/binary, Rest/binary>> = Bin,
    {Chunk, Rest}.

boundary(Bin, N) when N > 0 ->
    case binary:at(Bin, N) band 16#C0 of
        16#80 -> boundary(Bin, N - 1);
        _ -> N
    end;
boundary(_Bin, _) ->
    ?CHUNK.
