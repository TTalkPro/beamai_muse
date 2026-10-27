%% @doc Linux computer pages (designs/05-web-ui.md §5, tasks/M6-ui.md M6-5)
%% over the computer pool (muse_computers, muse_computer_pool) and
%% muse_computer.
%%
%% `/computer` manages the owner's computers (one per conversation and per
%% background task; there is no default computer): a summary
%% line (running computers of the deployment / COMPUTER_MAX_RUNNING, idle
%% stop minutes) and a table with name (conversation or task title), state,
%% variant, last use, CPU and memory of running ones (`docker stats`, cached
%% a few seconds) and open / start·stop / delete.
%%
%% `/computer/<id>` is one computer, for watching and managing only (the
%% agent is the one who works in it): status and resources with
%% start/stop/delete, a link to its conversation, the /workspace file tree
%% (ah_tree, directories loaded lazily) where a file can be downloaded and a
%% PDF copied into Files, an upload into /workspace (both over
%% muse_ui_computer_files), and the agent's recent commands with their
%% output. There is no terminal or editor: what a person needs to do by
%% hand in a sandbox is fetch or hand over files, and, on the desktop
%% variant, step in on the desktop (below). Actions
%% carry the computer id (`#{id => Id}`) and re-check that the computer
%% belongs to the signed-in owner.
%%
%% Without COMPUTER_ENABLED (sample installs, no Docker) the pages show the
%% "not configured" state from the computer snapshot.
%%
%% With the desktop variant (COMPUTER_DESKTOP=true) a running computer also
%% shows its desktop live (M10): noVNC (muse.js `muse-vnc`) over
%% `/vnc/computer/<id>` (muse_vnc_handler, muse_computer_desktop:vnc/2),
%% watching only by default; 「操作桌面」 reconnects with `?control=1`, so
%% the person's mouse and keys reach the desktop, and 「只看」 goes back.
-module(muse_ui_computer).
-behaviour(muse_ui_page).
-behaviour(aihtml_action).

-include_lib("aihtml/include/aihtml.hrl").
%% the header imports every builder; most pages use a few
-compile(nowarn_unused_import).

-export([render/2, on_event/2, action/4]).

-define(C, muse_ui_b_common).
-define(MAIN, <<"comp-main">>).
-define(LIST, <<"comp-list">>).
-define(NOTICE, <<"comp-notice">>).
-define(FILES, <<"comp-files">>).
-define(PANEL, <<"comp-file-panel">>).
-define(MAX_BYTES, 10485760).
-define(SCREEN, <<"comp-desktop-screen">>).
-define(MODE, <<"comp-desktop-mode">>).

-spec render(binary(), cowboy_req:req()) -> {binary(), aihtml:html()}.
render(Owner, Req) ->
    case ?C:path_id(Req) of
        undefined ->
            {<<>>, list_page(Owner)};
        Id ->
            case lookup(Owner, Id) of
                {ok, Ref, Computer} ->
                    Title = muse_computers:title(Owner, Computer),
                    {Title, detail_page(Ref, Computer, Title)};
                error ->
                    {<<>>, missing()}
            end
    end.

%% The owner's computer `Id`.
lookup(Owner, Id) ->
    case muse_computers:get(Owner, Id) of
        undefined -> error;
        Computer -> {ok, muse_computer:ref_of(Owner, Id), Computer}
    end.

%% Action arguments: `#{id => Id}`.
args(Ref) ->
    #{id => muse_computer:computer_id(Ref)}.

enabled() ->
    muse_config:get(computer_enabled, false) =:= true.

unconfigured(Message) ->
    ah_card(ah_empty([], [], [{title, <<"电脑未配置"/utf8>>},
                              {description, [Message, <<" "/utf8>>,
                                             <<"（服务器需设置 COMPUTER_ENABLED=true 并构建本地电脑镜像。）"/utf8>>]}]),
            [], [{id, <<"comp-unconfigured">>}]).

%% Computer list

list_page(Owner) ->
    ah_div([?C:page_header(<<"Linux 电脑"/utf8>>,
                           <<"每个对话和后台任务都有自己的隔离电脑和 /workspace，智能体第一次使用时自动启动。"/utf8>>),
            ?C:slot(?NOTICE),
            case enabled() of
                true -> [];
                false -> unconfigured(<<"Enable the Docker computer on the server to use its terminal and "
                                        "workspace files.">>)
            end,
            ah_div(list_body(Owner), [<<"flex flex-col gap-3">>],
                   [{id, ?LIST}, subscribe(muse_ui:topic(Owner, computers))])],
           [<<"muse-page">>], []).

list_body(Owner) ->
    #{running := Running, max := Max, idle_minutes := Idle, stats := Stats} = muse_computer_pool:overview(),
    Computers = muse_computers:list(Owner),
    Summary = ah_p([<<"运行中 "/utf8>>, integer_to_binary(length(Running)), <<" / 上限 "/utf8>>,
                    integer_to_binary(Max), <<" · 空闲 "/utf8>>, integer_to_binary(Idle),
                    <<" 分钟后自动停止 · 停止后 "/utf8>>,
                    integer_to_binary(muse_computer_pool:retention_days()),
                    <<" 天未使用的对话和任务电脑会被删除"/utf8>>],
                   [<<"text-sm text-muted">>], [{id, <<"comp-summary">>}]),
    [Summary,
     case Computers of
         [] ->
             ah_empty([], [compact], [{title, <<"还没有电脑"/utf8>>},
                                  {description, <<"智能体在对话或任务里第一次使用电脑时会自动创建。"/utf8>>}]);
         _ ->
             ?C:table([{<<"名称"/utf8>>, []}, {<<"状态"/utf8>>, [<<"nowrap">>]}, {<<"类型"/utf8>>, [<<"nowrap">>]},
                       {<<"最近使用"/utf8>>, [<<"muted nowrap">>]}, {<<"资源"/utf8>>, [<<"muted nowrap">>]},
                       {<<"操作"/utf8>>, [<<"actions">>]}],
                      [row(Owner, C, Running, Stats) || C <- Computers], [{id, <<"comp-table">>}])
     end].

row(Owner, #{<<"id">> := Id} = C, Running, Stats) ->
    Container = maps:get(<<"container">>, C, <<>>),
    IsRunning = lists:member(Container, Running),
    Status = case {IsRunning, maps:get(<<"status">>, C, <<>>)} of
                 {true, _} -> <<"running">>;
                 {false, <<"error">>} -> <<"error">>;
                 _ -> <<"stopped">>
             end,
    Variant = maps:get(<<"variant">>, C, <<"light">>),
    Href = <<"/computer/", Id/binary>>,
    A = #{id => Id},
    {[{id, <<"comp-row-", Id/binary>>}, {data_variant, Variant}, {data_status, Status}],
     [ah_a([muse_ui_icons:icon(terminal, 18),
            ah_span(muse_computers:title(Owner, C), [], []),
            ah_span(scope_label(maps:get(<<"scope">>, C, <<>>)), [<<"text-xs text-muted">>], [])],
           [<<"muse-table-name">>], [{href, Href}]),
      state_chip(Status),
      case Variant of
          <<"desktop">> -> <<"桌面"/utf8>>;
          _ -> <<"轻量"/utf8>>
      end,
      ?C:time_label(maps:get(<<"lastUsedAt">>, C, <<>>)),
      case IsRunning andalso maps:get(Container, Stats, undefined) of
          #{cpu := Cpu, memory := Mem} -> [<<"CPU "/utf8>>, Cpu, <<" · 内存 "/utf8>>, Mem];
          _ -> <<"—"/utf8>>
      end,
      ah_div([ah_a(<<"打开"/utf8>>, [<<"text-sm">>], [{href, Href}]),
              case IsRunning of
                  true -> ah_button(<<"停止"/utf8>>, stop, [borderless, sm],
                                    [on(click, {?MODULE, list_stop, A},
                                        #{confirm => confirm(<<"停止电脑？"/utf8>>,
                                                             <<"正在运行的命令会被中断，/workspace 的文件会保留。"/utf8>>,
                                                             <<"停止"/utf8>>),
                                          indicator => this})]);
                  false -> ah_button(<<"启动"/utf8>>, start, [borderless, sm],
                                     [on(click, {?MODULE, list_start, A}, #{indicator => this})])
              end,
              ah_button(<<"删除"/utf8>>, delete, [borderless, sm],
                        [on(click, {?MODULE, list_delete, A},
                            #{confirm => confirm(<<"删除电脑？"/utf8>>, <<"它的 /workspace 文件会一起删除，无法恢复。"/utf8>>,
                                                 <<"删除"/utf8>>),
                              indicator => this})])],
             [<<"flex items-center gap-2 justify-end">>], [])]}.

scope_label(Scope) ->
    case muse_computers:scope_kind(Scope) of
        thread -> <<"对话"/utf8>>;
        task -> <<"任务"/utf8>>;
        user -> <<"旧版默认"/utf8>>
    end.

state_chip(<<"running">>) -> ?C:chip(<<"运行中"/utf8>>, success);
state_chip(<<"error">>) -> ?C:chip(<<"出错"/utf8>>, error);
state_chip(_) -> ?C:chip(<<"已停止"/utf8>>, default).

missing() ->
    ah_div(ah_card(ah_empty(ah_a(<<"返回电脑列表"/utf8>>, [<<"text-primary">>], [{href, <<"/computer">>}]), [],
                            [{title, <<"找不到该电脑"/utf8>>},
                             {description, <<"电脑不存在、已被删除，或不属于当前账户。"/utf8>>}]), [], []),
           [<<"muse-page">>], [{id, <<"comp-missing">>}]).

%% One computer

detail_page(Ref, Computer, Title) ->
    ah_div([ah_div([ah_a(<<"← 全部电脑"/utf8>>, [<<"text-sm text-muted hover:text-primary">>], [{href, <<"/computer">>}]),
                    ?C:page_header(Title, [scope_label(maps:get(<<"scope">>, Computer, <<>>)),
                                           case muse_computer_desktop:enabled() of
                                               true -> <<"的电脑。智能体在这里运行命令和图形程序；这个页面用来查看和管理，需要时也可以亲手操作桌面。"/utf8>>;
                                               false -> <<"的电脑。智能体在这里运行命令和图形程序；这个页面只用来查看和管理。"/utf8>>
                                           end]),
                    origin_link(Computer)],
                   [<<"flex flex-col gap-2">>], []),
            ?C:slot(?NOTICE),
            ah_div(main(Ref), [<<"flex flex-col gap-6">>], [{id, ?MAIN}])],
           [<<"muse-page">>], [{data_computer, muse_computer:computer_id(Ref)}]).

%% The conversation the computer belongs to.
origin_link(#{<<"scope">> := <<"thread:", Tid/binary>>}) ->
    ah_a(<<"打开所属对话 ›"/utf8>>, [<<"text-sm text-primary">>],
         [{href, <<"/chat/", Tid/binary>>}, {id, <<"comp-origin">>}]);
origin_link(#{<<"scope">> := <<"task:", _/binary>>}) ->
    ah_a(<<"查看任务 ›"/utf8>>, [<<"text-sm text-primary">>], [{href, <<"/activity">>}, {id, <<"comp-origin">>}]);
origin_link(_) ->
    ah_p(<<"这是旧版本的默认电脑，不会被自动删除；把需要的文件下载下来后可以删除它。"/utf8>>,
         [<<"text-sm text-muted">>], [{id, <<"comp-origin">>}]).

main(Ref) ->
    Snapshot = muse_computer:snapshot(Ref),
    case Snapshot of
        #{<<"enabled">> := false} ->
            unconfigured(maps:get(<<"message">>, Snapshot, <<>>));
        #{<<"status">> := Status} ->
            [status_card(Ref, Snapshot),
             case Status =:= <<"running">> andalso muse_computer_desktop:enabled() of
                 true -> desktop_card(Ref);
                 false -> []
             end,
             case Status of
                 <<"running">> -> files_card(Ref);
                 _ -> ah_card(ah_p(<<"启动电脑后可以查看、下载和上传 /workspace 里的文件。"/utf8>>,
                                   [<<"text-sm text-muted">>], []),
                              [], [{title, <<"文件"/utf8>>}])
             end,
             history_card(maps:get(<<"commands">>, Snapshot, []))]
    end.

status_card(Ref, #{<<"status">> := Status} = S) ->
    A = args(Ref),
    {Label, Color} = case Status of
                         <<"running">> -> {<<"运行中"/utf8>>, success};
                         <<"stopped">> -> {<<"已停止"/utf8>>, default};
                         <<"error">> -> {<<"出错"/utf8>>, error};
                         _ -> {Status, default}
                     end,
    Running = Status =:= <<"running">>,
    Stats = case Running of
                true ->
                    #{stats := All} = muse_computer_pool:overview(),
                    case maps:get(maps:get(container, muse_computer:identity(Ref)), All, undefined) of
                        #{cpu := Cpu, memory := Mem} -> [<<" · CPU "/utf8>>, Cpu, <<" · 内存 "/utf8>>, Mem];
                        _ -> []
                    end;
                false -> []
            end,
    ah_card([ah_div([?C:chip(Label, Color),
                     ah_span([case maps:get(<<"provider">>, S, <<>>) of
                                  <<"docker">> -> <<"Docker 容器"/utf8>>;
                                  P -> P
                              end,
                              <<" · "/utf8>>,
                              case maps:get(<<"network">>, S, <<>>) of
                                  <<"disabled">> -> <<"不联网"/utf8>>;
                                  <<"enabled">> -> <<"可联网"/utf8>>;
                                  N -> [<<"网络 "/utf8>>, N]
                              end,
                              Stats,
                              <<" · 文件保存在 /workspace"/utf8>>],
                             [<<"text-sm text-muted">>], [])],
                    [<<"flex items-center gap-3 flex-wrap">>], [{id, <<"comp-status">>}]),
             case maps:get(<<"message">>, S, undefined) of
                 Msg when is_binary(Msg), Status =:= <<"error">> -> ?C:notice_html(error, Msg);
                 _ -> []
             end],
            [], [{title, <<"状态"/utf8>>},
                 %% one button that follows the state
                 {extra, ah_div([case Running of
                                     false -> ah_button(<<"启动电脑"/utf8>>, start, [primary],
                                                        [on(click, {?MODULE, start, A}, #{indicator => this})]);
                                     true -> ah_button(<<"停止电脑"/utf8>>, stop, [outlined],
                                                       [on(click, {?MODULE, stop, A},
                                                           #{confirm => confirm(<<"停止电脑？"/utf8>>,
                                                                                <<"正在运行的命令会被中断，/workspace 的文件会保留。"/utf8>>,
                                                                                <<"停止"/utf8>>),
                                                             indicator => this})])
                                 end,
                                 ah_button(<<"删除"/utf8>>, delete, [borderless],
                                           [on(click, {?MODULE, delete, A},
                                               #{confirm => confirm(<<"删除电脑？"/utf8>>,
                                                                    <<"它的 /workspace 文件会一起删除，无法恢复。"/utf8>>,
                                                                    <<"删除"/utf8>>),
                                                 indicator => this})])],
                                [<<"flex gap-2">>], [])}]).

confirm(Title, Body, Ok) ->
    #{title => Title, body => Body, ok => Ok, cancel => <<"取消"/utf8>>, variant => danger}.

%% The desktop live, watching only until the person takes control. The
%% screen box is preserved, so re-renders of the page keep the connection.
desktop_card(Ref) ->
    Id = muse_computer:computer_id(Ref),
    ah_card([ah_div(desktop_mode(Ref, false), [<<"flex items-center justify-between gap-3 flex-wrap mb-3">>],
                    [{id, ?MODE}]),
             ah_div([], [<<"muse-vnc">>],
                    [{id, ?SCREEN}, {data_ah, <<"muse-vnc">>},
                     {data_ah_url, muse_vnc_handler:computer_path(Id, false)}, {data_ah_view_only, true},
                     {style, <<"aspect-ratio: 1280 / 800">>},
                     {aria_label, <<"电脑桌面的实时画面"/utf8>>}
                     | aihtml:preserve()])],
            [], [{title, <<"桌面"/utf8>>}, {subtitle, <<"实时画面（1280×800）"/utf8>>}]).

desktop_mode(Ref, false) ->
    [ah_p(<<"正在看智能体操作 xterm、LibreOffice 等图形程序。需要时可以自己操作桌面。"/utf8>>,
          [<<"text-xs text-muted">>], [{id, <<"comp-desktop-hint">>}]),
     ah_button(<<"操作桌面"/utf8>>, control, [outlined, sm],
               [{id, <<"comp-desktop-control">>},
                on(click, {?MODULE, desktop_control, (args(Ref))#{control => true}})])];
desktop_mode(Ref, true) ->
    [ah_p(<<"你的鼠标和键盘正在操作这台电脑的桌面；智能体同时操作时会互相干扰。"/utf8>>,
          [<<"text-xs text-muted">>], [{id, <<"comp-desktop-hint">>}]),
     ah_button(<<"只看"/utf8>>, watch, [outlined, sm],
               [{id, <<"comp-desktop-control">>},
                on(click, {?MODULE, desktop_control, (args(Ref))#{control => false}})])].

%% The agent's recent commands with their output.
history_card(Commands) ->
    ah_card(case Commands of
                [] -> ah_p(<<"还没有运行过命令。"/utf8>>, [<<"text-sm text-muted">>], []);
                _ -> ah_div([command(R) || R <- lists:sublist(Commands, 20)], [<<"flex flex-col gap-2">>], [])
            end,
            [], [{title, <<"命令记录"/utf8>>}, {subtitle, <<"智能体最近运行的命令"/utf8>>}]
            ++ [{extra, ah_span([integer_to_binary(length(Commands)), <<" 条"/utf8>>],
                                [<<"text-xs text-muted">>], [])} || Commands =/= []]).

command(#{<<"command">> := C, <<"status">> := St} = R) ->
    Out = iolist_to_binary([maps:get(<<"stdout">>, R, <<>>), maps:get(<<"stderr">>, R, <<>>)]),
    aihtml:ah_el(details,
                 [aihtml:ah_el(summary,
                               [ah_code(C, [<<"break-all">>], []),
                                ?C:chip(status_label(St), status_color(St)),
                                case maps:get(<<"exitCode">>, R, undefined) of
                                    N when is_integer(N) -> ah_span([<<"退出码 "/utf8>>, integer_to_binary(N)],
                                                                    [<<"text-xs text-muted">>], []);
                                    _ -> []
                                end,
                                ah_span(?C:time_label(maps:get(<<"startedAt">>, R, <<>>)), [<<"text-xs text-muted">>], [])],
                               [<<"cursor-pointer flex items-center gap-2 flex-wrap text-sm">>], []),
                  ah_pre(case Out of
                             <<>> -> <<"（没有输出）"/utf8>>;
                             _ -> muse_js:slice(Out, 20000)
                         end,
                         [<<"muse-terminal bg-surface border border-line rounded p-3 mt-2 max-h-[40vh] overflow-auto text-xs">>],
                         [])],
                 [<<"comp-command">>], []).

status_label(<<"succeeded">>) -> <<"成功"/utf8>>;
status_label(<<"failed">>) -> <<"失败"/utf8>>;
status_label(<<"running">>) -> <<"运行中"/utf8>>;
status_label(<<"timed_out">>) -> <<"超时"/utf8>>;
status_label(<<"interrupted">>) -> <<"已中断"/utf8>>;
status_label(S) -> S.

status_color(<<"succeeded">>) -> success;
status_color(<<"running">>) -> info;
status_color(_) -> error.

files_card(Ref) ->
    ah_card(ah_div(files_body(Ref), [<<"flex flex-col gap-4">>], [{id, ?FILES}]),
            [], [{title, <<"文件"/utf8>>},
                 {subtitle, <<"选择文件可以下载；PDF 还可以存到「文件」页。"/utf8>>},
                 {extra, ah_button(<<"刷新"/utf8>>, refresh_files, [borderless, sm],
                                   [on(click, {?MODULE, refresh_files, args(Ref)})])}]).

files_body(Ref) ->
    A = args(Ref),
    Tree = case muse_computer:list(Ref) of
               {ok, #{<<"entries">> := Entries}} ->
                   case Entries of
                       [] -> ah_p(<<"/workspace 是空的。"/utf8>>, [<<"text-sm text-muted">>], []);
                       _ -> ah_tree(tree_items(Entries), undefined, [<<"font-mono text-sm">>],
                                    [{id, <<"comp-tree">>}, {load, {?MODULE, load_dir, A}},
                                     on(change, {?MODULE, open, A})])
                   end;
               Error ->
                   ?C:notice_html(error, ?C:error_text(Error))
           end,
    [ah_div([ah_div(Tree, [<<"md:w-1/2 min-w-0 max-h-[60vh] overflow-auto">>], []),
             ah_div(ah_p(<<"在左侧选择一个文件。"/utf8>>, [<<"text-sm text-muted">>], []),
                    [<<"flex-1 min-w-0">>], [{id, ?PANEL}])],
            [<<"flex flex-col md:flex-row gap-4">>], []),
     upload(Ref)].

upload(Ref) ->
    ah_upload([], [],
              [{id, <<"comp-upload">>},
               {url, muse_ui_computer_files:upload_url(muse_computer:computer_id(Ref), <<"/workspace">>)},
               {field_name, file}, {max_size, ?MAX_BYTES}, {multiple, true},
               {drag_text, <<"拖拽文件到此处上传到 /workspace，或"/utf8>>}, {browse_text, <<"点击选择"/utf8>>},
               {hint, <<"单个文件不超过 10 MB，同名文件会被覆盖"/utf8>>},
               {labels, #{too_large => <<"超过 10 MB"/utf8>>, upload_failed => <<"上传失败"/utf8>>,
                          remove => <<"移除"/utf8>>, network_error => <<"网络错误"/utf8>>}},
               on(change, {?MODULE, uploaded, args(Ref)})]).

tree_items(Entries) ->
    [case Type of
         <<"directory">> -> #{value => <<"d:", P/binary>>, label => Name, lazy => true};
         _ -> #{value => <<"f:", P/binary>>, label => Name}
     end || #{<<"name">> := Name, <<"path">> := P, <<"type">> := Type} <- Entries].

%% A file chosen in the tree: download, and for PDFs the copy into Files.
file_panel(Ref, Path) ->
    A = args(Ref),
    ah_div([ah_code(Path, [<<"text-sm break-all">>], []),
            ah_div([ah_a([muse_ui_icons:icon(download, 16), <<"下载"/utf8>>],
                         [<<"ah-btn ah-btn-outlined ah-btn-sm">>],
                         [{href, muse_ui_computer_files:download_url(muse_computer:computer_id(Ref), Path)},
                          {download, filename:basename(Path)}, {id, <<"comp-download">>}]),
                    [ah_button(<<"存到「文件」"/utf8>>, export, [outlined, sm],
                               [on(click, {?MODULE, export, A#{path => Path}}, #{indicator => this})])
                     || is_pdf(Path)]],
                   [<<"flex gap-2 flex-wrap">>], [])],
           [<<"flex flex-col gap-2">>], [{id, <<"comp-file">>}]).

is_pdf(Path) ->
    string:lowercase(filename:extension(Path)) =:= <<".pdf">>.

%% Actions

-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(list_start, Args, _Event, Ctx) ->
    with_ref(Ctx, Args, fun(Owner, Ref) -> list_op(Ctx, Owner, muse_computer:start(Ref), <<"电脑已启动。"/utf8>>) end);
action(list_stop, Args, _Event, Ctx) ->
    with_ref(Ctx, Args, fun(Owner, Ref) -> list_op(Ctx, Owner, muse_computer:stop(Ref), <<"电脑已停止。"/utf8>>) end);
action(list_delete, Args, _Event, Ctx) ->
    with_ref(Ctx, Args, fun(Owner, Ref) -> list_op(Ctx, Owner, muse_computer:delete(Ref), <<"电脑已删除。"/utf8>>) end);
action(start, Args, _Event, Ctx) ->
    with_ref(Ctx, Args, fun(_, Ref) -> after_op(Ctx, Ref, muse_computer:start(Ref), <<"电脑已启动。"/utf8>>) end);
action(stop, Args, _Event, Ctx) ->
    with_ref(Ctx, Args, fun(_, Ref) -> after_op(Ctx, Ref, muse_computer:stop(Ref), <<"电脑已停止。"/utf8>>) end);
action(delete, Args, _Event, Ctx) ->
    with_ref(Ctx, Args,
             fun(_, Ref) ->
                     case muse_computer:delete(Ref) of
                         ok -> aihtml_action:redirect(Ctx, <<"/computer">>);
                         Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
                     end
             end);
action(refresh_files, Args, _Event, Ctx) ->
    with_ref(Ctx, Args, fun(_, Ref) -> aihtml_action:html(Ctx, {id, ?FILES}, files_body(Ref)) end);
action(load_dir, Args, #{data := Data} = Event, Ctx) ->
    with_ref(
      Ctx, Args, fun(_, Ref) ->
                   Items = case maps:get(<<"value">>, Data, <<>>) of
                               <<"d:", Path/binary>> ->
                                   case muse_computer:list(Ref, Path) of
                                       {ok, #{<<"entries">> := Entries}} -> tree_items(Entries);
                                       Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)}), []
                                   end;
                               _ -> []
                           end,
                   aihtml:set_children(Ctx, Event, Items)
           end);
action(open, Args, #{value := Value}, Ctx) ->
    with_ref(Ctx, Args, fun(_, Ref) ->
                                case Value of
                                    <<"f:", Path/binary>> -> aihtml_action:html(Ctx, {id, ?PANEL}, file_panel(Ref, Path));
                                    _ -> ok
                                end
                        end);
action(uploaded, Args, Event, Ctx) ->
    with_ref(Ctx, Args,
             fun(_, Ref) ->
                     case [N || #{<<"name">> := N, <<"path">> := _} <- uploaded(Event)] of
                         [] -> ok;
                         Names ->
                             ?C:notice(Ctx, ?NOTICE, {success, [<<"已上传到 /workspace："/utf8>>,
                                                               lists:join(<<"、"/utf8>>, Names)]}),
                             aihtml_action:html(Ctx, {id, ?FILES}, files_body(Ref))
                     end
             end);
action(export, #{path := Path} = Args, _Event, Ctx) ->
    with_ref(
      Ctx, Args, fun(_, Ref) ->
                   Notice = case muse_computer:export_pdf(Ref, Path) of
                                {ok, #{<<"id">> := Id, <<"name">> := Name}} ->
                                    {success, [<<"已存到「文件」："/utf8>>,
                                               ah_a(Name, [<<"underline">>], [{href, <<"/documents/", Id/binary>>}])]};
                                Error ->
                                    {error, ?C:error_text(Error)}
                            end,
                   ?C:notice(Ctx, ?NOTICE, Notice)
           end);
action(desktop_control, #{control := Control} = Args, _Event, Ctx) when is_boolean(Control) ->
    with_ref(Ctx, Args, fun(_, Ref) ->
                                Id = muse_computer:computer_id(Ref),
                                aihtml_action:attr(Ctx, {id, ?SCREEN}, <<"data-ah-view-only">>, not Control),
                                aihtml_action:attr(Ctx, {id, ?SCREEN}, <<"data-ah-url">>,
                                                   muse_vnc_handler:computer_path(Id, Control)),
                                aihtml_action:html(Ctx, {id, ?MODE}, desktop_mode(Ref, Control), inner)
                        end).

uploaded(Event) ->
    try [F || F <- aihtml:uploaded_files(Event), is_map(F)]
    catch _:_ -> []
    end.

%% The signed-in owner's computer named by the action (`id`); a computer of
%% someone else, or a deleted one, is a notice.
with_ref(Ctx, Args, Fun) ->
    muse_ui:with_owner(
      Ctx, fun(Owner) ->
                   case lookup(Owner, maps:get(id, Args, undefined)) of
                       {ok, Ref, _} -> Fun(Owner, Ref);
                       error -> ?C:notice(Ctx, ?NOTICE, {error, <<"找不到该电脑，它可能已被删除。"/utf8>>})
                   end
           end).

%% @doc A fresh overview (states, CPU and memory): the open management
%% pages re-render their table.
-spec on_event(binary(), term()) -> ok.
on_event(Owner, {computers, _}) ->
    muse_ui_a_kit:publish(Owner, computers,
                          fun(C) -> aihtml_action:html(C, {id, ?LIST}, list_body(Owner), inner) end);
on_event(_Owner, _Event) ->
    ok.

list_op(Ctx, Owner, Result, Done) ->
    ok = muse_computer_pool:invalidate(),
    case Result of
        Ok when Ok =:= ok; element(1, Ok) =:= ok -> ?C:notice(Ctx, ?NOTICE, {success, Done});
        Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
    end,
    aihtml_action:html(Ctx, {id, ?LIST}, list_body(Owner)).

after_op(Ctx, Ref, Result, Done) ->
    case Result of
        {ok, _} -> ?C:notice(Ctx, ?NOTICE, {success, Done});
        Error -> ?C:notice(Ctx, ?NOTICE, {error, ?C:error_text(Error)})
    end,
    aihtml_action:html(Ctx, {id, ?MAIN}, main(Ref)).
