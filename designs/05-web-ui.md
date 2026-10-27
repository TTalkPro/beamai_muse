# 05 Web 层与界面（muse_web）

包括两部分：一是 JSON API，与原 `/api/*` 对齐；二是 aihtml 服务端渲染的界面，用来替代原 Expo 前端，对应原 `apps/mobile` 的功能（参见 `openmuse/docs/analysis/07-frontend.md`）。
aihtml 的用法与缺口见 [ref/aihtml-digest.md](ref/aihtml-digest.md)。

## 1. 路由总表

```
/                         UI：已登录时跳转 /chat，未登录跳转 /login
/login /logout            原生表单 POST，设置/清除 cookie（aihtml 动作不能设 cookie，见 G3）
/chat[/:thread]           聊天页
/activity[/:task]         任务列表与任务详情
/calendar[?date=&view=]   日程（M9-7）；date 是 YYYY-MM-DD，view 是 month|week|day|list
/mail[?account=&folder=&q=&draft=]  邮件（M9-8）；folder 是角色（inbox|starred|drafts|sent|archive|junk|trash）或文件夹 id，
                          draft 打开那封草稿；/mail/<messageId> 打开一封邮件；/mail/accounts[?edit=<id>] 邮箱账号
/mail-content/:id/body[?images=1]          邮件 HTML 的沙箱 iframe 文档（自己的 CSP，见 §5 邮件）
/mail-content/:id/attachment?part=[&download=1]   附件（从服务器取，规则同文件内容路由）
/mail-content/:draft/upload                写邮件窗口的附件上传（ah_upload，≤FILES_MAX_MB）
/goals  /monitors  /ideas  /documents[/:id]  /computer  /browser/:id  /settings  /notifications
                          （/browser 不带 id 只是一句说明，见 §5 浏览器）
/aihtml/action  /aihtml/events  /aihtml/[...]       aihtml_cowboy:routes/1 生成（外面包一层认证，见 §3）
/static/[...]             自建 Tailwind 产物、muse.js（自定义 Stimulus 控制器）
/upload                   multipart 上传 PDF（ah_upload）
/vnc/browser/:id          浏览器会话窗口的实时画面（WebSocket，M10，§5.1）
/vnc/computer/:id[?control=1]  桌面电脑的实时画面（WebSocket，默认只看）
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
- 路由清单：I§2.6 中 #1–#46（`/api/copilotkit/*` 替换为 `/api/agui/*`），以及 E§12.1 的 `/api/agent/*`。新增线程接口：`GET/POST /api/threads`、`POST /api/threads/:id`（重命名、归档、恢复）、`GET /api/threads/:id/messages`；回答产物（M9-11）：`GET /api/threads/:id/products`（产生过文件的回复列表）和 `GET /api/threads/:id/products/:runId/zip`（"全部下载"，`application/zip` 附件、`nosniff`，也可走签名 URL）。
- 内置邮件（`muse_api_mail`，M9-8；OpenMuse 的 Gmail 路由已删）：`GET /api/mail/accounts`（账号和同步状态，从不带密码）、`GET /api/mail/folders?account=`、`GET /api/mail/messages?account=&folder=&q=&unread=&limit=&offset=`（新的在前，带 total）、`GET /api/mail/messages/:id`（含 text、html、references），以及用户自己的 `POST /api/mail/send`（`{accountId?, to, cc?, bcc?, subject, body, inReplyTo?, attachments?: [文件 id], idempotencyKey?}`，不经审批，同一个 key 只发一次）。
- 内置日程（`muse_api_calendar`，M9-7；OpenMuse 同名的 Google 日历路由已删）：`GET /api/calendars`、`GET /api/calendar/events?from=&to=`（本地日期，to 不含，最多 400 天；返回展开后的每一次，带 `eventId`、`calendar`、`color`、`recurring`、`repeat` 和 `timeZone`），以及用户自己的写入 `POST /api/calendar/events`、`POST /api/calendar/events/:id`（补丁）、`DELETE /api/calendar/events/:id`，不经审批。
- 错误统一走 `muse_http:error_reply/2`。返回体为 `{"error": Msg}`；502 兜底时日志只记录错误类别。
- `/api/main-thread` 改为调用 `muse_threads:main_thread/1`。

## 3. aihtml 的接入与认证

- 依赖：rebar3 git_subdir 依赖 `aihtml`、`aihtml_cowboy`（DavidAlphaFox/aihtml）。`{aihtml, [{secret, MUSE_UI_SECRET}, {default_locale, <<"zh">>}]}`。
- `/aihtml/action` 和 `/aihtml/events` 用 `aihtml_cowboy:routes(#{static => false, authorize => fun muse_ui:authorize/1})` 挂载（aihtml `624f3bf` 起提供该钩子）：无有效会话 cookie 返回 401；SSE 流在每次心跳时重新校验，登出后旧连接会被断开。
  - 推送主题统一为 `{muse, Owner, Epoch, Name}`，登出时轮换 epoch，作为第二道保险。
- 每个动作的第一行都是 `muse_ui:with_owner(Ctx, fun(Owner) -> ... end)`。会话失效时调用 `redirect(Ctx, <<"/login">>)`。
- 样式：`assets/muse.css` 用 Tailwind v4 CLI 构建，输出到 `apps/muse_web/priv/static/css/muse.css`；`muse_ui_assets:css/0` 在运行时给 URL 加内容 hash（`?v=`），不需要 manifest。构建脚本是 `scripts/build-css.sh`，需要 node，只在构建时用到。
- 流式文本用 `aihtml_action:text/4`。浏览器控制台和桌面原来的截图点击（`pointer`）、逐键转发（`keydown` + `sync => fifo`）和 `poll/2` 截图刷新已被实时画面（§5.1）取代。
- 自定义脚本 `priv/static/js/muse.js`，通过 `page(..., #{js => [...]})` 加载，包含以下控制器：
  - `muse-composer`：Enter 发送，Shift+Enter 换行（G13）；
  - `muse-scroll`：新消息到达时自动滚到底部；
  - `muse-vnc`：实时画面（§5.1）。

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
| `browse_web` | 一行步骤：已浏览的网站，展开后是页面标题链接和"打开这个浏览器 ›"（新标签页打开 /browser/:id） |
| `request_takeover` | 求助卡片（不折叠进步骤组，橙色强调）：按 kind 显示"需要你登录 / 需要你完成验证 / 需要你确认 / 需要你来处理"、原因、网站；"打开浏览器处理"（新标签页打开 /browser/:id）和"处理好了，继续"（发送"我已经处理好了，请继续。"，走输入框同一路径，回复中则排队；点过或之后已有用户消息时显示为已完成） |
| `search_web` | 来源列表（URL 和摘录） |
| `delegate_task` / `agent_status` | 任务卡片：状态 chip、进度、计划步骤，订阅 `{task,...}` 实时更新 |
| `create_goal` / `watch_page` | 目标卡片、监控卡片 |
| 电脑工具 | 命令回执：命令、退出码、stdout 和 stderr 折叠显示 |
| `present_choices` | Jev 选项面板，点选后发送续写消息 |
| `read_calendar` | 一行步骤“查看了日程 · 范围 · N 项”，展开是每一项的时间和标题 |
| `propose_calendar_change` | 审批卡片（不折叠进步骤组）：`muse_ui_activity:approval_card/3`（scope `chat`），渲染时从存储读提案，所以重开的对话显示当前状态；外层 `tc-<CallId>` 订阅 owner 的 `approvals` 主题，在这里或审批页的决定都原地更新（`{action, Id}` 事件推 `approval-<Id>`）；执行成功后有“在日程中查看 ›”。准备失败是一行失败步骤 |
| `search_mail` / `read_mail` / `draft_mail` | 一行步骤：“搜索了邮件 · N 封”（展开是主题和发件人）、“读了邮件 · 主题”（带“在邮件中打开 ›”）、“存了草稿 · 主题”（带“打开草稿 ›”，`/mail?folder=drafts&draft=<id>`） |
| `propose_mail_send` | 与日程提议相同的审批卡片（不折叠，订阅 `approvals`，scope `chat`）：“发送邮件：主题”，发件人、收件人、抄送、密送、主题、回复、正文（前 600 字）、附件；执行成功后有“在“已发送”中查看 ›” |
| 产物（finance/plan/report） | finance 用 `ah_statistic` 加分类表加"设储蓄目标"按钮；plan 用 `ah_steps`；report 用 markdown |

## 5. 页面

目标、追踪和 Ideas 三个页面已在 2026-10-26 的简化改版中去掉，智能体也不再有 `create_goal`、`watch_page` 工具，维护任务不再刷新 Ideas；引擎和 JSON API 里的相应能力保留，便于兼容。

| 页面 | 内容与机制 |
|---|---|
| 布局 `muse_ui_layout` | 按 Agentic Noosh 设计稿：左侧栏（品牌 BeamAI Muse、"新会话"、工作区入口：任务（等你回复的数量，否则运行中的数量）、审批（`approval` 图标，等待审批的数量，橙色，M9-10）、日程（`calendar` 图标，M9-7）、邮件（`mail` 图标，收件箱未读数 `muse-mail-count`，`{mail, _}` 事件推送更新，M9-8）、文件、电脑（没有浏览器入口，M9-5）；会话搜索；置顶/会话两个可折叠分组，每条会话带状态点和"⋯"菜单：置顶、重命名、删除；底部账户菜单：设置、通知、退出）。宽屏侧栏常驻、可折叠（记住状态），窄屏由按钮滑出（`muse.js`）。顶栏：侧栏开关、页面或会话标题（会话带下拉菜单）、通知铃铛。外壳内置重命名对话框（aihtml 模态窗口）；确认框用 aihtml 自带的页面内确认框。当前会话的高亮在浏览器端按地址计算，服务端只渲染一份列表 |
| 聊天 | 所有会话平等，可同时回复，回复在服务端一直跑到完成或用户停止（`CHAT_MAX_STEPS`，默认 200 步）。`/chat` 是新会话：问候语、居中的输入卡片、示例标签；页面渲染时就生成会话 id 并订阅其推送，第一条消息创建会话（以消息开头命名）、开始回复，并把地址换成 `/chat/<id>`。会话页：用户消息为右侧灰色气泡，助手回复为 Markdown；一轮里连续的工具调用折叠成"执行了 N 个步骤"（运行时展开显示"正在执行 · 第 N 步"），每步一行可展开；委派任务、Jev 选项和浏览器求助（`request_takeover`）为完整卡片，求助卡片单独显示在步骤组之外。回复结束时整段日志按记录重绘一次，中途打开的页面也完整。回答产物（M9-11，`muse_ui_products`）：这一轮做出了文件的回复，在最后一段文字之后、消息工具之前有一张圆角卡片（文件夹图、"全部文件"、"预览或者下载文件 · N 个文件"、"预览"按钮），没有文件就没有卡片；卡片在回复结束的那次重绘里出现，刷新后照样在。"预览"打开 1000 px、85vh 的模态窗口：标题栏有文件数和"全部下载"（zip，`GET /api/threads/:id/products/:runId/zip`，签名 URL，超过 4 × `FILES_MAX_MB` 时提示逐个下载），左边是文件列表（按类型的图标、名称、大小），右边预览选中的文件（PDF iframe、位图、音视频播放器、文本/代码 `<pre>` 与 Markdown 渲染，超过 200 KB 截断并提示，其他显示信息；HTML/SVG 从不 inline），每个文件有"下载"和"在文件中打开"（`/documents/<id>`）。会话状态：正在回复/有新回复/需要处理（上次出错）/空闲 |
| 任务（`/activity`） | 只有任务：有等待审批的事项时顶部一行提示链接到“审批”（M9-10）。任务表格订阅 `{activity, Owner}`。任务详情包括：计划（`ah_steps`）、时间线（`ah_timeline`，订阅 `{task,...}`）、产物、文件、浏览器（"打开这个浏览器 ›"到控制台），暂停/恢复/取消/重试按钮（危险操作带确认），等待输入时显示表单，等待审批时显示审批卡片 |
| 审批（`/approvals`，M9-10） | `muse_ui_approvals`：所有等你决定的事项，不管来自对话（日程、邮件提议，没有任务）还是任务。上面“等待你决定”是审批卡片（`muse_ui_activity:approval_card/3`，scope `approvals`，批准/拒绝后整页重绘），下面“已处理”是最近 50 条已决定的（成功、拒绝、失败、过期、结果未知），每条一行，展开是同一张卡片。订阅 `approvals_page`，任何 `{action, _}` 事件都会重绘。对话里和任务详情里的审批卡片不变 |
| 日程（`/calendar`，M9-7） | 照 sigil 日历应用的 aihtml 移植（`aihtml_example_calendar_app`）。标题行“新建日程”；左栏“我的日历”（勾选显示/隐藏并持久化、色点、铅笔打开日历窗口：名称、颜色、删除——有日程时选“移到”某日历或“一并删除”，danger 确认；“+”添加日历）和“接下来 30 天”（每个日程只列下一次，点开编辑），订阅 owner 的 `calendar` 主题。右侧 `ah_calendar`：月/周/日/列表，`editable`、`selectable`，`first_day` 1，`day_max_events` 3，`agenda_days` 30，24 小时制，中文 `labels`（今天、月、周、日、列表、全天……），`href` 模板 `/calendar?date={date}&view={view}`，只显示勾选的日历，颜色取日历色，重复用 `FREQ=…`。首屏带所给日期前后 6 周的日程，之后 `change` 按 `data-start/end` 懒加载（`set_events`）。“新建日程”和选区（`ah:select`）打开日程窗口（标题、日历、开始/结束 `ah_datetime_input`、全天、地点、重复、备注；全天的结束日期含当天），点日程（`ah:event-click`）打开编辑，带删除（danger 确认，重复日程整串删除）；拖动和拉伸（`ah:event-drop`/`ah:event-resize`）直接改期，失败时提示并重新加载。用户自己的改动都直接写入；每次改动后重绘左栏并对日历触发 `change`，让它重新加载自己的范围（aihtml 没有 reload 方法，见 feedback `2026-10-26-calendar-no-reload-range.md`）；`{calendar, Id}` 事件对所有打开的日程页做同样的事 |
| 邮件（`/mail`，M9-8） | 照 sigil 邮件应用的 aihtml 移植（`aihtml_example_mail_app`）的三栏，用本应用的外壳和样式。标题行“立即同步”“邮箱账号”“写邮件”。左栏：账号切换（多个账号时）、同步状态（正在同步／已同步 · 时间／同步出错和原因、下次重试时间；IDLE 时显示“实时”）、文件夹：收件箱、已加星标、草稿、已发送、归档、垃圾箱（有的话还有垃圾邮件）和账号的其他 IMAP 文件夹（嵌套路径显示成“上级 / 下级”），带未读数。中栏：搜索（防抖 300 ms，服务端过滤主题、发件人、收件人、摘要）、邮件行（星标按钮、发件人——已发送里是“致：收件人”、时间、主题、摘要、附件标记，未读加粗带蓝点），“加载更多”每次 50 封；草稿里列本地草稿（智能体起草的带标记）。右栏阅读区：主题、发件人/收件人/抄送/时间，回复、全部回复、转发、归档、删除（danger 确认）、星标、标为未读；正文默认是纯文本（不渲染 HTML）；只有 HTML 的邮件或点“显示网页版式”时，用 `sandbox="allow-popups allow-popups-to-escape-sandbox"` 的 iframe 加载 `/mail-content/<id>/body`：文档自带 CSP `sandbox …; default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'; frame-ancestors 'self'`，没有脚本、不同源，远程图片默认屏蔽，“显示图片”加上 `https: http:`；`cid:` 内嵌图从服务器取回改成 data: URL；`<base target=_blank>` 和 no-referrer。附件列表：下载（`/mail-content/<id>/attachment`，规则同文件内容路由：PDF/图片/音视频可 inline，HTML/SVG/XML 永不 inline，`nosniff`）和“保存到文件”。写邮件窗口（`ah_window`）：发件人、收件人、抄送、密送、主题、正文、附件（从“文件”选，或 `ah_upload` 上传到 `/mail-content/<draft>/upload`），保存草稿、发送（用户自己发，不审批）、删除草稿；每次写邮件一开始就是一封本地草稿。文件夹切换、打开邮件是动作，原地重绘并 push 地址。页面状态（账号、文件夹、当前邮件、条数、搜索词）放在隐藏输入里，每个动作都带上；`{mail, AccountId}` 事件触发各页的 `mail-changed`，按各自状态刷新左栏和列表。`/mail/accounts`：账号卡片（服务器、用户名、同步状态，编辑、立即同步、删除——连同本地同步的邮件和草稿）和表单：邮箱类型预设（QQ、163、126、Gmail、Outlook/Office 365、iCloud、其他，切换时填服务器并给出授权码说明）、显示名称、邮箱、用户名、密码或授权码（编辑时留空不改，页面从不回显）、IMAP/SMTP 服务器、端口、加密（SSL/TLS 或 STARTTLS）、“发送后存一份到已发送”、“允许自签名证书”；“测试连接”和“测试并保存”（两个服务器都登录成功才保存）。没有账号时 `/mail` 是空状态，引导去添加 |
| 审批卡片 | 显示提案内容和 hash，批准或拒绝。内容由操作类型的 `display/1` 给出（标题加 `{标签, 值}` 字段，`muse_actions:display/1`），类型未注册的旧记录显示存下的标题和标量字段。批准动作带上 hash，与原项目一致。对话里提议的日程更改没有任务，也列在“等待你的审批”里，并以同一张卡片出现在对话中（§4） |
| 文件（`/documents`） | 仿 sigil 文件管理器（aihtml 示例 `aihtml_example_file_manager`），M9-6：页头“新建文件夹”（窗口 + 名称表单）和“上传文件”（`ah_window` + `ah_upload`，可多选，逐个 POST 到 `/upload`，带当前文件夹）；面包屑（全部文件 / 文件夹…，`/documents?folder=<id>`）；工具栏卡片：搜索（防抖 250 ms，服务端过滤，有关键词时搜全部文件夹并显示每个结果所在文件夹）、类型（全部类型/PDF/图片/音频/视频/文本/其他）、时间（全部时间/今天/最近 7 天/本月）、“已加星标”快速筛选（也跨文件夹）、网格/列表切换；可折叠的“文件夹”分区（卡片：名称、文件数、大小，重命名、删除——非空时连同内容删除，危险确认）和“文件”分区（网格卡片：类型标签、名称、大小、时间、星标；列表为 `muse-table`：名称、类型、大小、修改时间、星标、操作）。每个文件可打开、下载、重命名、移动到文件夹、删除（确认）、加星。工具栏状态放在页面里（搜索框、两个 select、视图和星标两个隐藏输入），每个动作都带上它们，改完按本标签页的状态重绘。订阅 `documents` 主题：改动向本人其他标签页推送 `docs-changed` 事件，它们各自按自己的状态刷新。`/documents/<id>`：面包屑、详情和操作（下载、重命名、移动、删除、星标），按类型预览：PDF 的 iframe 和表单字段填写（fill），图片 `<img>`，音频/视频播放器，1 MB 以内的 UTF-8 文本只读 `<pre>`，其他只显示信息和下载按钮。下载是一个动作，跳到新签发的 `download=1` 签名地址（签名 15 分钟过期） |
| 电脑 | `/computer` 电脑表格；`/computer/<id>` 只读和管理：状态、网络、CPU/内存、启停/删除，所属对话链接；桌面版的实时画面（§5.1，默认只看，“操作桌面”后可用鼠标键盘操作，“只看”退回）；文件：`ah_tree` 懒加载，选中文件可下载，PDF 可“存到「文件」”，`ah_upload` 上传到 /workspace（≤10 MB）；智能体最近 20 条命令及输出。没有终端、编辑器、新建文件夹和桌面输入：在沙箱里人需要亲手做的只有拿走和放进文件，其余交给智能体 |
| 浏览器 | 没有独立页面和会话列表（M9-5）：浏览器属于会话和任务，需要人时智能体在对话里求助。`/browser` 不带 id 显示一句空状态（"浏览器在对话里打开"，链接到 /chat）。控制台 `/browser/:id`：标题"处理浏览器 · 网站"，一行提示"直接在下面的画面里完成登录或验证（可以点击、拖动、滚动和键入），完成后回到对话点「处理好了，继续」。"，会话的浏览器带"← 回到对话"（`muse_browser:thread_of/2`）；地址栏和关闭（关闭后回到对话）；实时画面（§5.1，会话的 Chrome 窗口，含工具栏）；文本框“发送文字”（中文等输入法文字）；读取正文；导入下载 |
| 设置 | 身份（名字、语气、头像、showChatUpdates）、记忆增删改、电脑入口（开启电脑时）、登出。原来的应用连接页（`/apps`）随 Google 删掉了（M9-4） |
| 通知 | 列表、标记已读，订阅后实时更新；带 `href` 的通知（新邮件，M9-8）有“查看”，跳到那封邮件 |

### 5.1 实时画面（VNC，M10）

浏览器控制台和桌面电脑页共用（容器内部分见 designs/04 §4.1）：

- **页面**：一个 `.muse-vnc` 盒子，`data-ah="muse-vnc"`、`data-ah-url`（WebSocket 路径）、`data-ah-view-only`，带 `aihtml:preserve()`，页面局部重绘时连接不断。宽高比按画面（浏览器 1280/890，桌面 1280/800），画面在盒子里等比缩放。
- **muse.js `muse-vnc`**：动态 `import("/static/novnc/core/rfb.js")`（noVNC 1.7.0，`scripts/vendor-novnc.sh` 原样放进 `priv/static/novnc`，MPL-2.0，不打包），`scaleViewport`、`viewOnly`。断线自动重连 4 次（1/2/4/8 秒），之后显示“重新连接”按钮。`url` 或 `viewOnly` 属性变化时重连（桌面的“操作桌面/只看”由服务端动作改这两个属性）。
- **`muse_vnc_handler`**（cowboy_websocket，`/vnc/:kind/:id`）：握手前校验会话 cookie（401）、同站（跨站 403，`muse_mw` 也会拒绝外来 Origin）、会话或电脑属于该用户（404）、电脑在运行（409）；之后 `muse_docker:stream/1` 起 exec，两边字节原样转发。每 30 秒 ping 一次（不让代理断掉静止的画面），同时记一次使用（designs/04 §4.1）；每分钟重查 cookie，失效则以 4401 关闭；x11vnc 退出时以 1000 关闭；连接关闭时停掉 exec。
- **键盘**：VNC 发的是 keysym，输入法组好的中文传不过去，所以浏览器控制台保留“发送文字”（browserd 粘贴）。

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
