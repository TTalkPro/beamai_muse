# 05 Web 层与界面（muse_web）

包括两部分：一是 JSON API，与原 `/api/*` 对齐；二是 aihtml 服务端渲染的界面，用来替代原 Expo 前端，对应原 `apps/mobile` 的功能（参见 `openmuse/docs/analysis/07-frontend.md`）。
aihtml 的用法与缺口见 [ref/aihtml-digest.md](ref/aihtml-digest.md)。

## 1. 路由总表

```
/                         UI：已登录时跳转 /chat，未登录跳转 /login
/login /logout            原生表单 POST，设置/清除 cookie（aihtml 动作不能设 cookie，见 G3）
/chat[/:thread]           聊天页
/activity[/:task]         任务列表与任务详情
/goals  /monitors  /ideas  /documents[/:id]  /computer  /browser[/:id]  /settings  /notifications  /apps
/aihtml/action  /aihtml/events  /aihtml/[...]       aihtml_cowboy:routes/1 生成（外面包一层认证，见 §3）
/static/[...]             自建 Tailwind 产物、muse.js（自定义 Stimulus 控制器）
/upload                   multipart 上传 PDF（ah_upload）
/api/...                  JSON API，见 §2
/api/agui/...             AG-UI SSE（外部客户端使用）
```

## 2. JSON API（`muse_api_*` handler）

- 中间件顺序（`muse_mw` 写成一个 cowboy middleware 链，依次执行）：
  1. origin 校验；
  2. CORS 与 preflight；
  3. 请求体上限 12 MiB；
  4. 限流（仅 `/api/*`）；
  5. 免认证路由；
  6. 认证：Bearer、签名 URL 或 UI cookie 三选一，得到 owner 并放进 `Req` 的 meta；
  7. 业务路由。

  每一步的状态码和文案对齐 I§2.2–§2.3。
- 路由清单：I§2.6 中 #1–#46（`/api/copilotkit/*` 替换为 `/api/agui/*`），以及 E§12.1 的 `/api/agent/*`。新增线程接口：`GET/POST /api/threads`、`POST /api/threads/:id`（重命名、归档、恢复）、`GET /api/threads/:id/messages`。
- 错误统一走 `muse_http:error_reply/2`。返回体为 `{"error": Msg}`；502 兜底时日志只记录错误类别。
- `/api/main-thread` 改为调用 `muse_threads:main_thread/1`。

## 3. aihtml 的接入与认证

- 依赖：rebar3 git_subdir 依赖 `aihtml`、`aihtml_cowboy`（DavidAlphaFox/aihtml）。`{aihtml, [{secret, MUSE_UI_SECRET}, {default_locale, <<"zh">>}]}`。
- `/aihtml/action` 和 `/aihtml/events` 用 `aihtml_cowboy:routes(#{static => false, authorize => fun muse_ui:authorize/1})` 挂载（aihtml `624f3bf` 起提供该钩子）：无有效会话 cookie 返回 401；SSE 流在每次心跳时重新校验，登出后旧连接会被断开。
  - 推送主题统一为 `{muse, Owner, Epoch, Name}`，登出时轮换 epoch，作为第二道保险。
- 每个动作的第一行都是 `muse_ui:with_owner(Ctx, fun(Owner) -> ... end)`。会话失效时调用 `redirect(Ctx, <<"/login">>)`。
- 样式：`assets/muse.css` 用 Tailwind v4 CLI 构建，输出到 `apps/muse_web/priv/static/css/muse.css`；`muse_ui_assets:css/0` 在运行时给 URL 加内容 hash（`?v=`），不需要 manifest。构建脚本是 `scripts/build-css.sh`，需要 node，只在构建时用到。
- 截图点击直接读事件载荷里的 `pointer`（含 `natural_w/natural_h`）；控制台逐键转发用 `on(keydown, …, #{sync => fifo, prevent_default => [...]})`；截图刷新用 `poll/2`；流式文本用 `aihtml_action:text/4`。
- 自定义脚本 `priv/static/js/muse.js`，通过 `page(..., #{js => [...]})` 加载，包含以下控制器：
  - `muse-composer`：Enter 发送，Shift+Enter 换行（G13）；
  - `muse-scroll`：新消息到达时自动滚到底部。

## 4. 聊天的推送中继

```
用户提交 → 动作 muse_ui_chat:send
   ├─ 把用户消息乐观渲染进列表（html append）
   ├─ muse_chat:start_run(Owner, Tid, Text)
   │    ├─ model/sample：beamai_agui_sessions:ensure(Tid)
   │    │                beamai_agui_session:start_run(S, RunInput, Factory, #{})
   │    │                {busy,_} → 回到 UI 显示"排队中"，放进队列（见下）
   │    └─ agui：起 muse_agui_proxy 进程
   └─ muse_chat_relay:start(Owner, Tid, RunId)
        subscribe 会话事件，每 80ms 合并一次：
          TEXT_MESSAGE_START   → 新建气泡 <div id=m-ID><span id=m-ID-txt class="whitespace-pre-wrap">
          TEXT_MESSAGE_CONTENT → html(append, Delta)            （G1：没有 text op，用 append 代替）
          TEXT_MESSAGE_END     → morph 成 ah_markdown_view
          TOOL_CALL_START/ARGS → 工具卡片的占位（加载状态）
          TOOL_CALL_RESULT     → muse_ui_cards:render(ToolName, Result) 替换占位
          RUN_FINISHED/ERROR   → 发送按钮恢复为"发送"，然后发出队列里的下一条
        publish 到主题 {thread, Owner, Tid}
```

- 待发送队列存在 `muse_threads` 的 `pending` 字段里（服务端持久化），对应原 conversation-queue：一次只跑一轮，回复期间输入的消息进入可见队列，`busy` 时重新排队。
- 断线重连时调用 refresh 动作，从 `muse_chat_log` 重新渲染整个线程，弥补推送的 at-most-once 语义。
- 停止按钮调用 `beamai_agui_session:stop_run(Tid)`，草稿保留在输入框里（原行为）。

工具卡片（`muse_ui_cards`），逐一对应原 `useRenderTool`：

| 工具 | 卡片 |
|---|---|
| `search_mail` / `read_mail_thread` | 邮件列表卡片：发件人、主题、日期、摘要，点击后在抽屉里打开线程 |
| `read_calendar` | 事件列表 |
| `browse_web` | 页面标题、URL、摘要，加一个"接管"按钮（跳到 /browser/:id） |
| `search_web` | 来源列表（URL 和摘录） |
| `delegate_task` / `agent_status` | 任务卡片：状态 chip、进度、计划步骤，订阅 `{task,...}` 实时更新 |
| `create_goal` / `watch_page` | 目标卡片、监控卡片 |
| 电脑工具 | 命令回执：命令、退出码、stdout 和 stderr 折叠显示 |
| `present_choices` | Jev 选项面板，点选后发送续写消息 |
| 产物（finance/plan/report） | finance 用 `ah_statistic` 加分类表加"设储蓄目标"按钮；plan 用 `ah_steps`；report 用 markdown |

## 5. 页面

| 页面 | 内容与机制 |
|---|---|
| 布局 `muse_ui_layout` | `ah_sidenav`（聊天、Activity、目标、追踪、Ideas、文档、电脑、浏览器、应用、设置），顶部显示通知铃铛和未读数。根元素订阅 `{user, Owner, Epoch}`，用来接收 toast 和通知 |
| 聊天 | 左侧是线程列表（主会话、旁支会话；支持新建、重命名、归档、恢复），右侧是消息流加输入框。"委派任务"菜单可直接创建 document、finance、agent 任务；finance 提供"试用示例交易" |
| Activity | 任务表格订阅 `{activity, Owner}`。任务详情包括：计划（`ah_steps`）、时间线（`ah_timeline`，订阅 `{task,...}`）、产物、文件、浏览器，暂停/恢复/取消/重试按钮（危险操作带确认），等待输入时显示表单，等待审批时显示审批卡片 |
| 审批卡片 | 显示提案内容（邮件草稿、事件）和 hash，批准或拒绝。批准动作带上 hash，与原项目一致 |
| 目标 | 目标列表、里程碑勾选、暂停/完成 |
| 追踪（monitors） | 新建监控（变化、可用性文本、价格阈值）、暂停/恢复/停止/立即检查、最近的变化 diff（`ah_diff`）。sample 模式下有"测试页面"编辑框（`/api/agent/sample-page`） |
| Ideas | 卡片列表：来源证据，可编辑 prompt 后采纳，也可忽略 |
| 文档 | PDF 列表（数据表）、上传、iframe 预览（签名 URL）、字段表单填写（调用 fill）、导入到电脑 |
| 电脑 | 状态和启停；终端：提交命令后用长动作加 `flush` 流式输出到 `<pre>`；文件：`ah_tree` 懒加载，`ah_textarea` 编辑后保存，支持 mkdir、导入/导出 PDF |
| 浏览器 | 会话列表、新建（URL），控制台页：截图 `<img>`，有订阅者时服务端每 2 秒推一次新的 src；点击时带坐标；文本框加"输入"；特殊键按钮；滚动；读取正文；导入下载 |
| 应用 | Gmail 和 Google Calendar 的连接状态，连接只读或读写，断开 |
| 设置 | 身份（名字、语气、头像、showChatUpdates）、记忆增删改、主题切换（`ah_theme_switcher`）、登出 |
| 通知 | 列表、标记已读，订阅后实时更新 |

## 6. aihtml feedback（已全部实现）

2026-10-23 报到 `aihtml/feedbacks/` 的 6 条，aihtml 在 `8696f54`/`624f3bf` 中全部实现，muse 已改用新能力，不再有临时方案：

| # | 标题 | 严重度 | aihtml 提供的能力 | muse 的用法 |
|---|---|---|---|---|
| 1 | 事件载荷缺少坐标、修饰键和 detail | 🔴 | `detail`、`mods`、`pointer` | 浏览器截图点击读 `pointer` |
| 2 | keydown 丢键，且不能 preventDefault | 🔴 | `sync => fifo`、`prevent_default` | 控制台逐键转发 |
| 3 | action/events 端点没有认证钩子，token 不过期 | 🟡 | `routes(#{authorize})`、`max_age` | `muse_ui:authorize/1` |
| 4 | 缺少追加文本的 text op | 🟡 | `aihtml_action:text/3,4` | 聊天流式输出 |
| 5 | 动作无法设置响应头和 cookie | 🟢 | `set_resp_cookie/3`、`set_resp_headers/1` | 暂不需要（登录仍用原生表单） |
| 6 | 没有自动刷新（poll）属性 | 🟢 | `poll/2` | 截图每 2 秒刷新 |
