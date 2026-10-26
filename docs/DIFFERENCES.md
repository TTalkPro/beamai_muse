# 与 OpenMuse 的差异

beamai_muse 以 OpenMuse 的行为为准：错误文案、校验顺序、记录形状、幂等键和 receipt 都逐字对齐（规格见 `designs/ref/`）。下面只列**有意或无法避免**的差异。

## 架构与存储

| 方面 | OpenMuse | beamai_muse |
|---|---|---|
| 运行时 | Node（Hono API + 独立 worker 进程） | 一个 OTP release：API、任务 worker、监控调度都在同一节点里，按 supervisor 分组 |
| 数据库 | Postgres（jsonb + `@>`） | Mnesia `muse_record` 表。CAS 语义沿用 jsonb：数组按"包含"判断，浅合并 |
| 事件、聊天、大对象 | Postgres 表 | bitcask：`events`、`chat`（原始消息）、`chat_index`（jieba 分词的 BM25）、`blobs` |
| `DATABASE_URL` | 必填 | 忽略，数据放在 `DATA_DIR/mnesia` 和 `DATA_DIR/bitcask/*` |

## 聊天与线程

- **线程自建**：原项目依赖 CopilotKit Intelligence 的 Rich Threads（需要 `CPK_INTELLIGENCE_API_KEY`），这里由 `muse_threads` 加 beamai_agui 会话实现，不再需要这个 key。线程锁 `agent_thread_locked` 由会话的 `on_concurrent => reject` 承担（409）。
- **历史搜索**：聊天历史用 bitcask 的 BM25 索引（jieba 分词），查询前转成小写。
- **名称**：项目名为 BeamAI Muse，智能体默认名也是 BeamAI Muse（系统提示 "You are BeamAI Muse…"，API 未登录报错 "Sign in to BeamAI Muse"）；仍叫默认名 "OpenMuse" 的已有身份会自动改名。与 OpenMuse 协议相关的字符串不变（`[OpenMuse choice]` 前缀、Parallel 请求的 `openmuse/0.1.0` user-agent、浏览器 worker 的页面）。
- **多会话**：没有主会话和旁支会话，所有会话平等、可同时回复；`/chat` 是新会话，第一条消息创建会话并以消息开头命名；会话可置顶、重命名、删除（连同对话记录），侧栏显示每个会话的状态（正在回复、有新回复、需要处理）。一轮回复的步数上限是 `CHAT_MAX_STEPS`（默认 200），OpenMuse 是 6（E2B 桌面 16）。主会话和归档只保留在 JSON API（`/api/main-thread`、`/api/threads`）里。
- **界面简化**：以对话为中心（左侧栏按 Agentic Noosh 设计稿）；去掉了目标、追踪、Ideas 三个页面和智能体的 `create_goal`、`watch_page` 工具，维护任务不再定时刷新 Ideas，sample 模式登录时也不再生成 Ideas。OpenMuse 底部有 Chat、Activity、Ideas、Goals、Apps 五个标签。引擎和 JSON API 中的目标、监控、Ideas 能力仍保留。
- **ALLOWED_ORIGINS=\***：额外支持 `*`，放行任意 Origin。CORS 响应仍回显请求的 Origin，因为带凭据时不能用字面量 `*`。OpenMuse 只接受逐个列出的 Origin。
- **MCP 客户端**：搜索（parallel.ai）用 beamai_extra 2.1.0 的 `beamai_mcp_client`（streamable HTTP），每次搜索起一个客户端，报错文案映射成 OpenMuse 的写法。

- **浏览器求助在对话里（新增，M9-5）**：OpenMuse 有独立的浏览器会话页和“接管”。这里没有浏览器页面、会话列表和侧栏入口，`/browser` 不带 id 只显示一句说明；需要人时（登录、验证码或人工验证、付款预订之类的最终确认）聊天智能体调用新工具 `request_takeover`（`reason`、`kind`、可选 `url`），对话里出现求助卡片：“打开浏览器处理”到该会话浏览器的控制台 `/browser/<id>`（带“回到对话”），“处理好了，继续”发送“我已经处理好了，请继续。”，智能体在同一个浏览器会话（同一份 profile，登录状态保留）里继续。系统提示词和 `browse_web` 描述各追加一段说明。`/api/browsers/*` 不变。 用户处理完后，智能体用新工具 `read_current_page` 读浏览器此刻的页面（不导航、不重新加载），而不是用原来的网址再调 `browse_web`，所以付款结果这类只在用户操作后才出现的页面不会丢。

## Google、邮件与日历（已删除）

按用户决定（2026-10-26，“全都删掉，我们将内置日程，邮件收发的能力”），Google 集成和现有的邮件、日历功能全部删掉；内置的日程和邮件收发以后作为新功能设计。

- **没有 Google**：OAuth、Gmail、Calendar 都没有了，`GOOGLE_CLIENT_ID`、`GOOGLE_CLIENT_SECRET` 不再读取，“应用连接”页（`/apps`）和设置里的入口也去掉了。`TOKEN_ENCRYPTION_KEY` 在 live 模式仍然必填（与原项目配置兼容），现在用来加密内置邮件的邮箱密码（M9-8）。
- **删掉的 JSON API**（现在都是 404，回调也不再是免登录路由）：`GET /api/google/callback`、`POST /api/google/connect`、`POST /api/google/disconnect`、`GET /api/calendars`、`GET /api/calendar/events`（这两个路径现在是内置日程的，见下）、`GET /api/mail/threads/:id`、`POST /api/mail/import-attachment`、`GET /api/drafts`、`POST /api/drafts`。
- **`GET /api/workspace`**：没有 `mail` 和 `events`，`?q=` 不再使用；`connections` 里没有 google（只剩 browser、openbot）；`profile.email` 是空字符串。任务的 `state` 不再带 `connectionId`，提案不再带 `account`、`connectionId`。
- **sample 模式**：不再有示例邮箱、日程和那条待审批的日程提案；只在“文件”里预置郊游同意书 PDF。
- **智能体**：聊天没有 `search_mail`、`read_mail_thread`、`read_calendar`，系统提示去掉了邮件、日历两段（“Health/finance connectors beyond Google” 改成 “The built-in mail and calendar described below work; health and finance connectors are unavailable”，内置日程和邮件见下）。任务模型没有 `read_mail_thread`、`import_pdf`、`prepare_email`、`prepare_event`，`read_workspace` 只读文件（section 为 `files` 或 `all`）。Jev 的 `present_choices` 去掉了 `mailThreadId` 参数和邮件证据。sample 脚本没有日历回复。Ideas 不再从邮件生成文档和约见建议（只剩目标的计划建议），旧的邮件建议在刷新时作废。
- **审批的操作类型可插拔**：审批机制（prepare → hash → awaiting_review → 批准/拒绝 → 执行 → 回执/outcome_unknown、过期、任务的 `waiting_approval`、审批卡片、`/api/actions`、`/api/agent/actions`）原样保留，但 `email.send`、`calendar.create/update/delete` 和它们的 Google 执行器删掉了。操作类型由 `muse_actions:register_kind/2` 注册（`muse_action_kind` behaviour：schema、display、execute，可选 prepare 和任务工具），生产环境起初一个都没有，现在有内置日程的 `calendar.event` 和内置邮件的 `mail.send`（见下），其他 kind 仍返回 422。hash 改成 `sha256hex(JSON({input, target, targetVersion}))`（没有 connection）。类型已不存在的旧提案只能拒绝或等过期，批准时报 409 “This kind of action is not available on this server. Prepare a new action.”。
- **内置日程（新增，M9-7）**：替代 Google 日历，数据在本机（`muse_calendar`：`calendars` 默认个人/工作/家庭/出行，`calendar-events`），时间是部署时区的本地墙上时间、不带时区，重复只有每天/每周/每月/每年。页面 `/calendar`（侧栏“日程”）照 sigil 日历应用做：月/周/日/列表、拖动改期、选区新建、日历显示开关。智能体有 `read_calendar`（聊天和任务都有，名字与 OpenMuse 的 Google 版相同，但参数是本地日期 `from`/`to`、结果带日历名和最近提议的结果），写入只能提议：聊天的 `propose_calendar_change`、任务的 `prepare_calendar_change`，都是审批类型 `calendar.event`（create/update/delete，修改和删除绑定日程的 `updatedAt`，审批期间日程变了就拒绝执行），卡片在对话里和审批页都能批准；OpenMuse 的 `calendar.create/update/delete` 写的是 Google，这里写本地，也没有 `prepare_event` 的 Google 账户参数。系统提示在原文之后加一段日程说明（原文 “Mail, calendar … unavailable” 不改）。用户自己的改动（页面、`POST/DELETE /api/calendar/events…`）不审批。sample 模式“我明天有什么安排”直接从日程回答。
- **内置邮件（新增，M9-8）**：替代 Gmail，读写用户自己现有的邮箱：IMAP 收信、SMTP 发信，经 Node sidecar（imapflow、mailparser、nodemailer，`MAIL_SIDECAR`），不用 OAuth，账号用密码或授权码（QQ、163、126、Gmail、Outlook/Office 365、iCloud 预设，可多个账号，密码用 `TOKEN_ENCRYPTION_KEY` 加密，没有这个密钥就不能添加邮箱；只支持 TLS 和强制 STARTTLS）。本地保留每个文件夹最近 `MAIL_SYNC_DAYS`（30）天、最多 `MAIL_SYNC_MAX`（500）封，IDLE 加 `MAIL_POLL_MINUTES`（5）分钟轮询；附件不落地，打开时从服务器取。页面 `/mail`（侧栏“邮件”）照 sigil 邮件应用做三栏；HTML 邮件只在沙箱 iframe 里显示，远程图片默认屏蔽。OpenMuse 的 `search_mail`/`read_mail_thread` 读的是 Gmail，这里是聊天和任务都有的 `search_mail`、`read_mail`（参数不同：query、folder、account、from/to 日期、unreadOnly、limit；结果标明不可信），新增 `draft_mail`（直接存本地草稿，不审批），发信只能提议：聊天的 `propose_mail_send`、任务的 `prepare_mail_send`，审批类型 `mail.send`（OpenMuse 的是 `email.send`，经 Gmail 发送并要求 Google 连接；这里没有 connection，发送回执保证不会发两次，结果不明时是 `outcome_unknown`）。系统提示在日程段之后再加一段邮件说明（原文 “Mail, calendar … unavailable” 仍不改）。用户自己在页面和 `POST /api/mail/send` 上的发送不审批；`GET /api/mail/accounts|folders|messages[/:id]` 是新路由，与 OpenMuse 的 `/api/mail/threads/:id` 不同。草稿只在本地，不同步到 IMAP 的 Drafts 文件夹。
- **document 任务从“文件”开始**：原项目从邮件附件（`input.messageId`）开始，填好后准备回复邮件并等审批；现在从“文件”里的 PDF（`input.fileId`）开始，填表后把填好的副本存进“文件”，任务直接完成（计划 3 步：Find the source document、Fill a new copy、Record the outcome）。sample 演示 “Complete the permission slip” 照样能从头走到尾。

## 模型

- **没有 Gemini**：beamai_llm 不支持，`google/*` 模型报 "Unknown provider"。
- **多出的 provider**：beamai 支持的 `zhipu`、`deepseek`、`moonshot`、`openrouter`、`dashscope`、`siliconflow`、`xai`、`ollama` 等，对应 `<PROVIDER>_API_KEY`。

## 界面

- **同源服务端渲染**：原项目是独立的 Expo/React 应用加 CopilotKit；这里由 API 进程用 aihtml 直接渲染界面。
  - `GET /` 不再返回服务 JSON，而是跳转到 `/chat`（已登录）或 `/login`。
  - 登录是原生表单 POST，会话放在 HttpOnly cookie（`muse_session`），与 JSON API 的 Bearer token 是同一个会话。
  - `/aihtml/action` 和 `/aihtml/events` 通过 aihtml 的 `authorize` 钩子校验会话。推送主题带"纪元"，登出时轮换。
- **实时更新**：Activity、审批、通知、聊天回复都由服务端推送，不再轮询。推送是 at-most-once，断线重连后调用 refresh 动作重绘。
- **没有移动端特性**：比如离线草稿队列。
- **新增 `MUSE_UI_SECRET`**：aihtml 的签名密钥，live 模式必填（至少 32 字符）；sample 模式缺省时随机生成，保存在 `DATA_DIR/ui-secret`。
- **样式**：Tailwind v4 在构建期生成 `muse.css`，运行时不需要 Node。
- **文件库存任意文件，有文件夹（新增，M9-6）**：OpenMuse 的 Artifacts 只有 PDF（≤10 MB）。这里“文件”能存任意类型，单个不超过 `FILES_MAX_MB`（默认 25 MB，PDF 仍 ≤10 MB），可建多级文件夹、重命名、移动、删除（非空文件夹确认后连同内容删除）、加星，页面仿 sigil 文件管理器（搜索、类型和时间筛选、已加星标、网格/列表）。文件记录多了 `kind`、`folderId`、`starred`、`updatedAt`，旧记录按根目录的 PDF 读取；非 PDF 的字节在 `file/<id>`，PDF 仍在 `pdf/<id>`。内容路由按文件类型返回 `content-type`，只有 PDF、位图、音频、视频 inline，HTML/SVG/XML 一律以 `application/octet-stream` 附件下载，并带 `nosniff`。JSON API 多了 `GET /api/files[?folder=]`、`PATCH`/`DELETE /api/files/:id` 和 `/api/file-folders`；`POST /api/files` 收任意类型，报错文案由 “Choose a PDF file” 改为 “Choose a file”。智能体工具（`inspect_pdf`、`fill_pdf`、document 任务）和电脑的导入导出仍只收 PDF，遇到别的文件返回 422 说明原因。

## 电脑与 sidecar

- **Docker 电脑**：用 erlexec 调用 docker（参数数组，环境变量白名单），argv 与原项目逐字对齐（`COMPUTER_NETWORK=none` 时；见下面的网络一条）。
- **电脑池（新增，OpenMuse 每个用户只有一台电脑）**：每个对话（`thread:<threadId>`）和每个后台任务（`task:<taskId>`）各有一台电脑，各自的容器和 `/workspace` 卷（名字里带电脑 id，标签加 `dev.openmuse.computer` 和 `dev.openmuse.scope`）。对话委派的任务记下对话（任务多一个 `threadId` 字段）并用对话的电脑，一个对话和它的任务共用一台；其他任务用自己的。共用时智能体工具遇到电脑忙会等（最多 180 秒），而不是像 OpenMuse 那样立即报 409；`/api/computer/*` 不变。记录在 `computers/<id>`（id 是 owner+scope 的哈希）。
  - 智能体工具第一次执行命令、文件操作或桌面动作时自动启动电脑，`start_computer` 变成可选；工具结果带 `computerId`。说明文本在 OpenMuse 原文后追加一段电脑池说明。
  - 没有默认电脑：`/api/computer/*` 必须带 `?computer=<id>` 或 `?thread=<threadId>`（不带是 400），`muse_computer` 只接受 `{Owner, Id}`。旧版本按用户建的那台电脑（scope `user`，OpenMuse 的容器、卷、lease、receipt 名字）作为“旧的默认电脑”保留，可以查看、下载文件、删除，但不再新建。
  - 生命周期：空闲 `COMPUTER_IDLE_MINUTES`（默认 15）分钟自动停止；同时运行超过 `COMPUTER_MAX_RUNNING`（默认 4）时先停最久未用的空闲电脑，全都在忙则启动失败（503）；停止后 `COMPUTER_RETENTION_DAYS`（默认 7）天未用的对话/任务电脑连同卷删除，旧的默认电脑不自动删。启动时按部署标签核对 `docker ps -a`：无记录的容器能从标签恢复 owner 和 scope 的就收编为已停止的电脑，否则停止并保留（不删卷），记日志。
  - `/computer` 变成电脑列表（名称、状态、类型、最近使用、CPU/内存、打开/启停/删除），`/computer/<id>` 是单台电脑页。删除电脑会删除容器和卷。
- **电脑页只读（新增）**：OpenMuse 的电脑页有终端、文件编辑、新建文件夹，桌面版还能点击和键入。这里电脑是智能体的执行环境，页面只用来查看和管理：状态和资源、启停删除、只读的实时桌面、智能体的命令记录（含输出）、文件下载和上传（任意文件 ≤10 MB，`files.py` 新增 `read_file`/`write_file`）、PDF 存到「文件」。“文件”页不再有“复制到电脑”，把文件交给电脑用上传或让智能体去做。JSON API 和智能体工具不变。
- **电脑联网（新增）**：`COMPUTER_NETWORK` 默认 `bridge`（Docker 默认网桥，能上网，也能访问宿主机所在局域网）；`none` 与 OpenMuse 相同。附着时要求容器恰好在所配置的网络上，否则拒绝（删除电脑即可按新设置重建）。快照里的 `network` 随之为 `enabled`/`disabled`；`bridge` 时智能体说明换成联网版本（仍没有浏览器、没有凭据），`none` 时保持 OpenMuse 原文。镜像里没有 curl，也没有系统 CA 证书（node 自带证书，可以访问 HTTPS）。
- **PDF**：pdf-lib 通过 Node 端口程序调用（`PDF_SIDECAR`）。
- **不支持 E2B 桌面**（按用户决定）：只有 Docker 电脑。`COMPUTER_PROVIDER` 只接受 `docker`，设为 `e2b-desktop` 时启动失败。`E2B_API_KEY`、`COMPUTER_E2B_TEMPLATE` 不再读取（`COMPUTER_DEPLOYMENT_ID` 仍用于给 Docker 容器命名）。
- **Docker 桌面版（新增，OpenMuse 没有）**：`COMPUTER_DESKTOP=true` 时 Docker 电脑改用 `computer/Dockerfile.desktop` 构建的镜像（`COMPUTER_DESKTOP_IMAGE`，默认 `openmuse-computer-desktop:local`，`make computer-desktop-image`）：Xvfb 1280x800 虚拟显示 + openbox 窗口管理器，离线应用 xterm、LibreOffice Writer/Calc、mupdf，字体含 Noto CJK。轻量镜像 `computer/Dockerfile` 和它的 argv 不变。
  - 容器隔离与轻量版相同（`--network none`、只读根、`--cap-drop ALL`、no-new-privileges、`--init`、不发布端口），限额放宽为内存 1536m（swap 相同）、pids 512、2 CPU、`/tmp` 256 MiB；入口是 `/opt/openmuse/desktop-init`，容器环境带 `DISPLAY=:0`，并打标签 `dev.openmuse.variant=desktop`。附着时按当前变体核对隔离参数，遇到另一变体的容器会拒绝并提示删除容器（/workspace 卷保留）。
  - 桌面动作走 `docker exec`（参数数组，固定脚本，用户文本只作为 argv 元素）：动作、提示文案、receipt（`computer-desktop-actions`）、截图存储（`DATA_DIR/desktop-screens/<sha256hex(owner)>.jpg`）和幂等重放都与 OpenMuse 的 E2B 桌面一致。
  - 比 OpenMuse 多一条 `key` 校验：xdotool 会把参数里的命令名（不分大小写，如 `exec`、`windowkill`）当作串联的下一条命令，`key -- shift exec rm x` 会执行程序。这类名字（以及 `window*`、`get*`、`set_*`、`mouse*`、`key*`、`behave*` 前缀）按原文案 `Use xdotool key names, e.g. ctrl+l` 拒绝；唯一受影响的真实按键名是 `Help`。
  - 有 `use_desktop` 工具（位于 import_computer_pdf 与 export_computer_pdf 之间）和单独的说明文本；聊天步数上限为 16（关闭时仍是 6）。与 OpenMuse 一样，截图作为图片部件交给模型（beamai 2.0.2 的 `{parts, _}`），只在当前这一步有效，历史和 AG-UI 事件里只保留文本。文本中额外带一个同源签名 `screenshotUrl`（OpenMuse 没有），供聊天卡片显示图片。
  - `/api/computer/desktop`（GET 状态）、`POST /api/computer/desktop/actions`、`GET /api/computer/desktop/screenshot`（可签名，`no-store`，`?receipt=` 指定截图，`?live=1` 取实时画面）。没有实时流 URL。关闭桌面版时这些路由仍是 404。
  - 电脑页面在桌面版运行时显示“桌面”卡片：截图每 2 秒刷新（`poll`），点击画面即单击，另有键入、按键、滚动和截图按钮。
- **浏览器 worker**：原样复用原项目的 Node + Playwright worker，因为宿主的 Node 是 v20，用 tsx 运行。

## Jev

- **live 适配器**直接调用 TypeSafe 的 HTTP 接口（`POST /v1/systemone`），没有用 `@typesafe-ai/sdk`。协议、超时（5 秒）、重试（1 次，退避策略与 SDK 相同）和错误文案都与原项目一致。
- 新增 `TYPESAFE_BASE_URL`，对应 SDK 自己读取的同名环境变量。
- **后台任务自动续跑（新增）**：OpenMuse 的模型任务一轮最多 16 个工具步、5 分钟，超时就失败，一轮没调用 finish_task 就停下等用户输入。这里每轮 `TASK_MAX_STEPS`（默认 50）步、`TASK_RUN_MINUTES`（默认 10）分钟；用完步数或时间自动开新一轮接着做（带上计划和“自动继续”说明，已做的操作有缓存不重做），模型停下却没给结果时先提醒一次，连续 `TASK_AUTO_RUNS`（默认 10）轮都没结果才问用户。
- **审批单独成页（新增，M9-10）**：OpenMuse 的审批挂在任务上。这里对话也会直接提议（日程、邮件），这些审批没有任务，所以侧栏分成“任务”（`/activity`）和“审批”（`/approvals`，带待审批数）：审批页列出所有等待决定的事项和最近 50 条已处理的；任务页只剩任务，有待审批时顶部提示。对话里和任务详情里的审批卡片照旧。
