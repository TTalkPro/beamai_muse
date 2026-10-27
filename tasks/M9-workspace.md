# M9 多会话工作台与电脑池

2026-10-26 起。目标：像 Agentic Noosh 设计稿那样以会话为中心，多个会话可以同时进行，用户不停止就一直跑；电脑（Docker 容器）按会话/任务自动分配和管理。

## M9-1 电脑池（Docker 管理）
- [x] 每个会话、每个后台任务各一台电脑（scope `thread:<id>` / `task:<id>`），由会话委派的任务沿用会话的电脑（2026-10-26 补上：之前任务各起一台，一个会话会跑出多台桌面；任务记 `threadId`，工具遇忙等待）；第一次用到时自动启动。
- [x] 每台电脑独立的 `/workspace` 卷，删除电脑时一并删除。
- [x] 生命周期：空闲 `COMPUTER_IDLE_MINUTES`（15）自动停止；同时运行上限 `COMPUTER_MAX_RUNNING`（4），超出时停掉最久未用的空闲电脑；停止超过 `COMPUTER_RETENTION_DAYS`（7）天自动删除；启动时与 `docker ps` 对账。
- [x] 联网：`COMPUTER_NETWORK=bridge`（默认）或 `none`。
- [x] 管理界面 `/computer`：电脑表格（名称、状态、类型、最近使用、资源、操作）。
- [x] 去掉默认电脑（2026-10-26，用户：“彻底去掉”）：`/api/computer/*` 必须带 `?computer=` 或 `?thread=`；`muse_computer` 只接受 `{Owner, Id}`；旧版本的默认电脑保留为“旧的默认电脑”，不自动删除；“文件”页去掉“复制到电脑”；acceptance 先建对话再用它的电脑。
- [x] `/computer/<id>` 只读和管理（2026-10-26，用户选择）：状态/资源、启停/删除、所属对话、只读实时桌面、命令记录（含输出）、文件下载和上传（≤10 MB，`files.py` 的 `read_file`/`write_file`，`/computer-files/<id>/download|upload`）、PDF 存到「文件」；去掉终端、桌面点击/键入/按键、在线编辑和新建文件夹。

## M9-2 多会话
- [x] 取消主会话/旁支会话：所有会话平等，`/chat` 是新会话落地页（问候语、居中输入框、示例），第一条消息创建会话并以消息开头命名。
- [x] 置顶、重命名（对话框）、删除（连同对话记录）；归档只留给 JSON API。
- [x] 侧栏会话状态：正在回复（蓝色脉冲）、有新回复（蓝点）、需要处理（橙色警告，上次回复出错）、空闲（灰点）。
- [x] 回复在服务端持续运行，关掉页面也不中断；单轮步数上限 `CHAT_MAX_STEPS`（默认 200）。
- [x] 一轮回复里连续的工具步骤折叠成"执行了 N 个步骤"，运行时展开。

## M9-3 界面
- [x] 侧栏按设计稿：品牌、新会话、工作区入口、置顶/会话分组、会话"⋯"菜单、底部账户菜单；宽屏可折叠，窄屏滑出。
- [x] 顶栏：侧栏开关、会话标题和菜单（置顶/重命名/删除）、通知。
- [x] 确认框改用 aihtml 自带的页面内确认框（aihtml `4f49549`），危险操作红色按钮。

## M9-4 去掉 Google、邮件和日历
用户决定（2026-10-26）：“全都删掉，我们将内置日程，邮件收发的能力”。内置的日程和邮件以后另行设计。
- [x] 删除 Google 集成：`muse_google_auth`、`muse_google_api`、`muse_google_ws`、`muse_gmail`、`muse_gcal`、`muse_mail_text` 及其测试；`/api/google/*` 路由；`GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` 配置；`/apps` 页面、标题和设置里的“应用连接”卡片；只为 Google 存在的连接概念（工作区连接、任务 state 的 `connectionId`、提案的 `account`/`connectionId`、维护任务清理 OAuth state）。
- [x] 删除邮件和日历：sample 邮箱和日程（`muse_workspace_seed`）、工作区里的邮件/日历部分、邮件/线程/草稿/日历/事件的 JSON API；聊天工具 `search_mail`、`read_mail_thread`、`read_calendar` 和提示词里的邮件、日历、Google 句子；任务模型的 `read_mail_thread`、`import_pdf`、`prepare_email`、`prepare_event`；sample 脚本的日历回复；对应的聊天卡片；Jev 的邮件证据和 `mailThreadId`；Ideas 的邮件建议。
- [x] 新会话页的示例换成不需要邮件的（Hacker News、copilotkit.ai、Python 词频脚本、填 PDF 表单），问候语不再提邮件和日程。
- [x] 审批机制保留，操作类型可插拔：`muse_action_kind` behaviour（schema、display、execute，可选 prepare、tool）和 `muse_actions:register_kind/2` 注册表，生产环境为空，留给内置邮件和日历；审批卡片用类型的 display；任务模型为每个带 `tool/0` 的类型生成 prepare 工具；测试用 `muse_test_action_kind`（`test.note`）。
- [x] document 任务从“文件”里的 PDF（`input.fileId`）开始，填好后保存副本并完成；sample 模式在“文件”预置郊游同意书，演示 “Complete the permission slip” 端到端可用。
- [x] 文档：README、README_EN、`deploy/.env.example`、designs（00、01、02、03、04、05）、docs/DIFFERENCES.md。
- [x] `./scripts/check.sh` 通过。

## M9-5 浏览器接管改为对话内求助
用户决定：单独的浏览器页面没有用；智能体需要人时在对话里求助，用户在这个会话的浏览器里处理完，再告诉智能体继续。
- [x] 聊天工具 `request_takeover`（配置浏览器 worker 时注册）：`reason`（≤300 字符）、`kind`（login / verification / confirm / other）、可选 `url`；立即返回，确保会话的浏览器会话已打开（`muse_browser:open_for_thread/3`），结果 `{sessionId, kind, reason, url, consoleUrl}`。
- [x] 系统提示词追加求助说明（登录、验证码、最终确认时调用，回复结尾说明要做什么，不破解验证码、不要密码）；`browse_web` 描述加一句。
- [x] 聊天工具 `read_current_page`（无参数）：读会话浏览器此刻的页面，不导航、不重新加载（`muse_browser:read_for_thread/2`）；提示词要求用户处理完后先用它，不要拿原来的网址再调 `browse_web`。聊天步骤“读取了当前页面 · 网站”。测试核对它只向 worker 发 `GET /sessions/<id>/read`。
- [x] 聊天求助卡片（`tc-<CallId>`，橙色强调，不折叠进步骤组）：按 kind 的标题、原因、网站，“打开浏览器处理”（新标签页）和“处理好了，继续”（muse_ui_chat `continue`，发送“我已经处理好了，请继续。”，之后按钮显示为已完成）。
- [x] 控制台 `/browser/<id>`：标题“处理浏览器 · 网站”、一行提示、会话浏览器的“回到对话”（`muse_browser:thread_of/2`），去掉“全部会话”，关闭后回到对话。
- [x] 删除 `/browser` 列表页、新建表单和侧栏入口；`/browser` 不带 id 显示空状态说明（链接到 /chat）。`/api/browsers/*` 不变；任务页的浏览器卡片链接到控制台；browse_web 步骤保留“打开这个浏览器 ›”。
- [x] 测试：工具结果、卡片渲染、继续动作开始新一轮、`/browser` 空状态、控制台的回到对话链接。
- [x] 文档：designs/03、designs/05、docs/DIFFERENCES.md。
- [x] `./scripts/check.sh` 通过。

## M9-6 文件管理（任意文件与文件夹）
用户决定：“文件”页按 sigil 的文件管理器重做（aihtml 示例 `aihtml_example_file_manager`），文件库能放任意类型的文件，并用文件夹整理。
- [x] 存储（`muse_files`）：`upload/4` 收任意文件，单个不超过新配置 `FILES_MAX_MB`（默认 25，最大 1024；README、README_EN、`deploy/.env.example`），类型由文件头、扩展名、上传声明依次判断；记录保持 Artifact 形状，新增 `mimeType`（已有）、`kind`、`folderId`（`null` 为根）、`starred`、`updatedAt`。PDF 原样保留页数、字段、填表、预览，仍 ≤10 MB；非 PDF 没有 fields。旧记录读成根目录的 PDF（`normalize/1`），PDF 字节仍在 `pdf/<id>`，其他文件在 `file/<id>`（不迁移，按前缀可区分）。
- [x] 需要 PDF 的地方（`fill`、`inspect_pdf`/`fill_pdf`、document 任务、电脑 `import_pdf`）改用 `get_pdf/2`/`pdf_bytes/2`，非 PDF 返回 422 并说明原因；`import/4,6`（电脑导出、浏览器下载、sample）仍只收 PDF。浏览器下载对应的文件被删后再导入会重新下载。
- [x] 内容路由按类型返回 `content-type`：PDF、位图、音频、视频 inline，其余 attachment，`?download=1` 强制 attachment；HTML、SVG、XML、JS 从不 inline（`application/octet-stream` 附件）；始终 `x-content-type-options: nosniff`。`muse_mw` 对两个上传路由放宽请求大小。
- [x] 文件夹：`file-folders` 种类 `{id, name, parentId, createdAt}`，可嵌套；新建、重命名（同级不重名）、删除（默认要求为空；界面确认后连同内容删除，`variant => danger`）、把文件移到别的文件夹；面包屑，`/documents?folder=<id>`。
- [x] 页面 `/documents`：页头“上传文件”（`ah_window` + `ah_upload`，多选，`/upload` 增加 `folder` 字段）和“新建文件夹”；工具栏：搜索（服务端、防抖）、类型、时间、已加星标、网格/列表；文件夹分区（名称、文件数、大小）；文件分区（网格卡片或 `muse-table` 表格）；打开、下载、重命名、移动、删除（确认）、加星；有关键词时搜全部文件夹并显示所在文件夹。订阅 `documents` 主题，其他标签页按自己的状态刷新（`docs-changed` 事件 + refresh）。
- [x] 详情 `/documents/<id>`：PDF 照旧（iframe、字段填写，没有“复制到电脑”）；图片 `<img>`；音频/视频播放器；≤1 MB 的文本只读 `<pre>`；其他显示信息和下载按钮；始终有下载、重命名、移动、删除。
- [x] JSON API：`/api/files` 对 PDF 保持 OpenMuse 兼容；上传收任意类型；`GET /api/files[?folder=<id>|root]`；`PATCH`/`DELETE /api/files/:id`（`name`、`folderId`、`starred`）；`GET|POST /api/file-folders`、`PATCH|DELETE /api/file-folders/:id[?recursive=true]`。没有新增 cowboy 路由（都在 `/api/[...]` 和已有的 `/upload` 下）。
- [x] 测试：`muse_files_tests`（任意类型、类型判断、大小上限、serve 规则、文件夹增删改与移动、递归删除、星标、旧记录）、`muse_api_integ_SUITE`（`files_any_type`、`file_folders`、`files_size_limit`，原 `files_flow` 不变）、`muse_ui_pages_b_SUITE`（`documents_page` 更新，新增 `documents_manager`、`documents_previews`：筛选、搜索、网格/列表切换、星标、对话框、下载、删除、各类预览、旧 PDF 记录）、`muse_config_tests`（`FILES_MAX_MB`）。
- [x] 文档：designs/04 §2.1、designs/05 文件一行、docs/DIFFERENCES.md、README。
- [x] `./scripts/check.sh` 通过。

## M9-7 日程
内置日程，替代 M9-4 删掉的 Google 日历（用户：“我们将内置日程，邮件收发的能力”）。界面照 sigil 日历应用的 aihtml 移植（`aihtml_example_calendar_app`）；智能体能读，智能体的新建、修改、删除要用户批准。
- [x] 数据（`muse_calendar`，放在 muse_engine：日程是 owner 的领域记录，和审批注册表在同一个应用，muse_agent 与 muse_web 都依赖它）：`calendars` `{id, name, color, visible, order}`，第一次使用时建默认的个人、工作、家庭、出行（颜色取自示例），`settings/calendar-seeded` 标记只建一次；可添加、改名、改色、删除，删除有日程的日历要选“移到其他日历”或“一并删除”，至少保留一个。`calendar-events` `{id, calendarId, title, start, end, allDay, location, notes, rrule?, status, createdAt, updatedAt, createdBy (user|agent)}`。
- [x] 时间：部署时区的本地墙上时间，不带时区（`YYYY-MM-DDTHH:MM`，全天 `YYYY-MM-DD`），`end` 不含；带 `Z`/偏移的输入拒绝。重复只有不重复/每天/每周/每月/每年（31 号跳过短月，2-29 跳过平年）。`updatedAt` 是版本，每次写入严格前移，写入可带 `expect` 在事务里核对。变更发 `{calendar, Id}` 事件。
- [x] 页面 `/calendar`（侧栏“日程”，`calendar` 图标）：左栏日历（显示开关持久化、色点、铅笔编辑）和接下来 30 天（每个日程只列下一次）；`ah_calendar` 月/周/日/列表、可拖、可选、周一开头、中文标签、24 小时制；`change` 按可见范围懒加载（`set_events`），`/calendar?date=&view=` 来自 `href` 模板。“新建日程”和选区打开表单（标题、日历、开始/结束、全天、地点、重复、备注；全天的结束日期含当天），点日程打开编辑（删除走 danger 确认），拖动和拉伸直接改期（用户自己的改动不审批）。改动后重绘左栏并对日历触发 `change` 重新加载；别处的改动（批准的智能体操作、API、别的标签页）经 `calendar` 主题推送同样处理。
- [x] 智能体读：聊天和任务模型都有 `read_calendar`（from/to 本地日期、含两端，默认今天起 7 天，最多 366 天，可选 query），返回 today、weekday、timeZone、展开后的日程（带日历名和 eventId）、日历列表、最近一天里日程提议的结果（`recentChanges`）。提示词在 OpenMuse 原文之后加日程一段（今天日期、时区、写入要审批）。
- [x] 智能体写：操作类型 `calendar.event`（`muse_calendar_action`，muse_engine 启动时注册）。`prepare/2` 校验归属，新建时补全默认值，修改/删除时把当前日程作为 target、`updatedAt` 作为 targetVersion，并把改后的完整日程和 `previous` 放进 data；`display/1` 给“新建日程：…/修改日程：…/删除日程：…”和时间、原时间、日历、地点、重复、状态、备注；`execute/3` 以 targetVersion 为前提写入，日程在审批期间变过就 409 拒绝；`tool/0` 给任务模型 `prepare_calendar_change`。
- [x] 聊天提议：`propose_calendar_change` 准备操作后立即返回 `awaiting_review`（幂等键按请求），结果里说明还没生效；审批卡片出现在对话里（`tc-<CallId>`，不折叠进步骤组，跟随 `approvals` 主题原地更新）和任务与审批页，两处都能批准/拒绝；侧栏“任务与审批”的待处理数算上对话里的提议。决定不推给对话：下一轮用 `read_calendar` 的 `recentChanges` 看到结果。
- [x] JSON API（Bearer）：`GET /api/calendars`、`GET /api/calendar/events?from=&to=`（展开后的日程），以及用户自己的 `POST /api/calendar/events`、`POST|DELETE /api/calendar/events/:id`。
- [x] sample 模式：“我明天有什么安排”/“show my calendar” 直接从日程回答（今天、明天或接下来 7 天）。
- [x] aihtml feedback：`2026-10-26-calendar-no-reload-range.md`（日历没有按当前范围重新加载的方法，用触发 `change` 绕过）、`2026-10-26-window-title-not-settable.md`（窗口标题只能按内部 id 改）。
- [x] 测试：`muse_calendar_tests`（存储、时间规则、重复、版本、读工具、操作类型的 prepare/display/execute/过期拒绝/归属）、`muse_chat_SUITE`（读、提议、sample）、`muse_ui_calendar_SUITE`（页面、表单新建、懒加载、拖动/拉伸、编辑删除、选区、日历开关和管理、对话审批卡片、API）。
- [x] 文档：designs/02、03、05，docs/DIFFERENCES.md。
- [x] `./scripts/check.sh` 通过。

## M9-8 邮件
内置邮件收发，替代 M9-4 删掉的 Gmail（用户：“我们将内置日程，邮件收发的能力”）。读写用户现有的邮箱：IMAP 收信、SMTP 发信。界面照 sigil 邮件应用的 aihtml 移植（`aihtml_example_mail_app`）；智能体能读、能起草，它每次发信都要用户批准。
- [x] 协议层：Node 端口程序 `sidecars/mail`（imapflow 2.9.1、mailparser 3.12.4、nodemailer 10.2.1，`package.json` 钉死版本加 `package-lock.json`，`make sidecars`/`scripts/deploy.sh`/`scripts/check.sh` 用 `npm ci` 安装）和 `muse_mail_client`（muse_integ：一个端口多路复用请求，调用方解码回复，每个请求有期限，端口挂了所有在途请求失败、下次重启；IDLE watch 推事件）。选 Node 而不是 Erlang 的理由（字符集、MIME、IMAP 客户端）、TLS（隐式 TLS 或强制 STARTTLS，默认校验证书，可显式允许自签名）、超时、环境变量白名单见 designs/04 §7。新配置 `MAIL_SIDECAR`。
- [x] 账号（`muse_mail_accounts`）：显示名称、邮箱、用户名、IMAP/SMTP 主机/端口/加密、允许自签名证书、发送后存到已发送；QQ、163、126、Gmail、Outlook/Office 365、iCloud 预设；测试连接（IMAP 和 SMTP 都登录），保存时先测；多个账号；密码用 muse_vault 加密（没有 `TOKEN_ENCRYPTION_KEY` 时 503），从不返回、不进日志，编辑时留空保留原密码。
- [x] 同步（`muse_mail_sync`，每个账号一个进程，`muse_mail_sup`，只在任务 worker 节点）：LIST/STATUS 同步文件夹；按 UIDVALIDITY/UID 增量取新邮件（头、flags、摘要、mailparser 解出的 text/HTML，附件清单），flags 和服务器上的删除同步回来；正文 ≤64 KB 存 Mnesia（`mail-bodies`），更大的进 blobs（`mailbody/<id>`）；附件不落地，打开时按 part 取。每个文件夹保留最近 `MAIL_SYNC_DAYS`（30）天、最多 `MAIL_SYNC_MAX`（500）封。收件箱 IDLE，另每 `MAIL_POLL_MINUTES`（5）分钟一次；失败按 1/2/5/10/30/60 分钟退避，`mail-sync` 记状态、错误和下次重试时间，页面显示。已读、星标、归档、移动、删除（到垃圾箱，或从垃圾箱彻底删除）先写服务器。变更发 `{mail, AccountId}`；新邮件（第一次同步之后）发通知，通知新增 `href`（`muse_agent_service:notify/6`，通知页有“查看”）。
- [x] 发送（`muse_mail_send`）：纯文本、cc、bcc、附件（“文件”、上传、转发的原附件，合计 ≤`FILES_MAX_MB`）、回复的 In-Reply-To/References；按账号 `saveSent` 把同一份报文 APPEND 到已发送（Gmail、Outlook 预设关闭）。草稿只在本地（没有同步到 IMAP 的 Drafts）。发送回执 `mail-sends` 在 SMTP 前后各写一次，同一个 key 永不重发，两次写之间崩溃或 DATA 期间断线是 `outcome_unknown`；页面的发送先把草稿 CAS 成 `sending`，双击只发一次。
- [x] 安全：正文默认显示纯文本；只有 HTML 的邮件（或“显示网页版式”）在 `sandbox="allow-popups allow-popups-to-escape-sandbox"` 的 iframe 里加载 `/mail-content/<id>/body`，文档自带 CSP（`sandbox`、`default-src 'none'`、`img-src data:`，“显示图片”才加 `https: http:`，`form-action`/`base-uri 'none'`、`frame-ancestors 'self'`），`cid:` 图片内联成 data:；附件按文件内容路由的规则下载（HTML/SVG 永不 inline，`nosniff`）；给智能体的邮件内容标明不可信。
- [x] 页面 `/mail`（侧栏“邮件”，`mail` 图标，放在日程后面，带收件箱未读数）：三栏——左栏账号切换、同步状态、收件箱/已加星标/草稿/已发送/归档/垃圾箱（有垃圾邮件文件夹时也列出）和其他文件夹，带未读数；中栏搜索和邮件行（星标、发件人或收件人、时间、主题、摘要、附件、未读）、加载更多；右栏阅读区（回复、全部回复、转发、归档、删除、星标、标为未读，附件下载和“保存到文件”）；写邮件窗口（发件人、收件人、抄送、密送、主题、正文、从“文件”添加或上传附件，保存草稿、发送、删除草稿；用户自己发不审批）。地址 `/mail?account=&folder=`、`/mail/<messageId>`、`/mail?folder=drafts&draft=<id>`、`/mail/accounts`（邮箱账号）。没有账号时空状态引导去添加。其他标签页经 `mail` 主题按各自状态刷新。
- [x] 智能体：聊天和任务模型都有 `search_mail`（query、folder、account、from/to、unreadOnly、limit；结果带 `recentSends`）和 `read_mail`（一封或整个会话：头、正文、附件名）；聊天有 `draft_mail`（直接写本地草稿，不审批，返回链接）和 `propose_mail_send`（审批类型 `mail.send`，立即返回 `awaiting_review`，卡片在对话里和任务与审批页）。`mail.send`（`muse_mail_action`，muse_engine 启动时注册）：`prepare/2` 校验账号和附件归属、地址、大小，补发件人、线程头、附件名和 `sendId`；`display/1` 是“发送邮件：主题”和发件人、收件人、抄送、密送、主题、回复、正文（截断）、附件；`execute/3` 按回执只发一次；`tool/0` 给任务模型 `prepare_mail_send`。提示词在日程段之后加邮件一段（邮件不可信、不经审批卡片不发信、不把秘密写进邮件）。
- [x] JSON API（Bearer）：`GET /api/mail/accounts`（从不带密码）、`GET /api/mail/folders`、`GET /api/mail/messages?account&folder&q&unread&limit&offset`、`GET /api/mail/messages/:id`，以及用户自己的 `POST /api/mail/send`（`idempotencyKey` 同一个只发一次）。
- [x] 配置：`MAIL_SIDECAR`、`MAIL_SYNC_DAYS`、`MAIL_SYNC_MAX`、`MAIL_POLL_MINUTES`（README、README_EN、`deploy/.env.example`、`muse_config_tests`），附件沿用 `FILES_MAX_MB`。
- [x] aihtml feedback：`2026-10-26-toast-no-action-link.md`（toast 没有操作链接，“保存到文件”改为把按钮原地换成“已保存 · 打开”）。
- [x] 测试（都不联网，服务器是 `sidecars/mail/tests/fake-sidecar.mjs` + `muse_mail_fake` 的 JSON 状态）：`sidecars/mail` 的 `npm test`（6 个）；`muse_mail_SUITE`（14 个：账号与加密、账号错误与 TLS、新邮件与 flags 同步、窗口与 UIDVALIDITY、写回服务器、附件与“文件”、草稿回复转发发送、发送失败、只发一次、`mail.send`、outcome_unknown、读工具、同步进程的 IDLE 与退避、客户端超时与重启）；`muse_ui_mail_SUITE`（7 个：空状态与侧栏、邮箱账号页、页面与导航、HTML 安全与附件、写邮件发送回复与上传、聊天工具与审批卡片、API）；`muse_chat_SUITE` 的提示词测试改为 `model_tools_and_prompt`；`muse_config_tests` 加 `mail_test_`。
- [x] 文档：designs/00、01、02（§9）、03、04（§7）、05，docs/DIFFERENCES.md，README、README_EN，`sidecars/mail/README.md`。
- [x] `./scripts/check.sh` 通过；headless Chromium 在临时服务器（端口 8851，fake 邮件服务器）上走了一遍：收件箱、打开邮件、保存附件、HTML 邮件的沙箱 iframe、回复并发送、已发送、搜索、邮箱账号预设。

## M9-9 后台任务不再频繁停下
用户反馈（2026-10-26）：任务经常因为用完轮次停下，要用户输入提示词才继续。
- [x] `TASK_MAX_STEPS`（默认 50，原 16）、`TASK_RUN_MINUTES`（默认 10，原 5 分钟超时即失败）、`TASK_AUTO_RUNS`（默认 10）。
- [x] 一轮用完步数或时间自动续跑；模型停下没给结果先提醒一次；连续 `TASK_AUTO_RUNS` 轮才等用户。续跑的提示带当前计划（计划不在 priorState 里）。
- [x] 测试：超时续跑、步数续跑、续跑上限、提醒后等用户（`muse_task_model_SUITE`）。

## M9-10 任务与审批分开
用户同意（2026-10-26）：审批已经不只来自任务（对话里的日程、邮件提议没有任务），侧栏分成两个入口。
- [x] `/approvals`（`muse_ui_approvals`，侧栏“审批”，`approval` 图标，`muse-approval-count` 待审批数）：等待你决定的审批卡片（scope `approvals`，决定后整页重绘）和最近 50 条已处理的（一行，展开为卡片）；订阅 `approvals_page`，`{action, _}` 时重绘。
- [x] `/activity` 改名“任务”：去掉审批区，有待审批时顶部一行提示链接到审批；侧栏“任务”只数等你回复的任务（否则数运行中的）。
- [x] 文案：提示词、卡片说明、设计文档里的“任务与审批”改为“审批”。
- [x] 测试：`muse_ui_pages_a_SUITE`、`muse_ui_calendar_SUITE`、`muse_ui_mail_SUITE` 改到审批页，覆盖待审批、在审批页拒绝后重绘、已处理列表和侧栏计数。

## M9-11 回答产物
用户：“我希望docker或者llm生成的产物放在回答的最后，并且点击后可以提供预览以及下载”。参考图 `reference.png`：回答的最后一段文字下面一张圆角卡片（文件夹图、“全部文件”、“预览或者下载文件”、右侧“预览”），再下面是消息操作图标。
- [x] 什么算产物（`muse_chat_products`，muse_agent）：只算这次回复新建或改过的文件。① 对话电脑（scope `thread:<threadId>`）`/workspace` 里 mtime ≥ 回复开始 − 2 秒的普通文件；只有这次回复用过会改文件的电脑工具（`run_computer_command`、`write_computer_file`、`use_desktop`、`import_computer_pdf`）才去看，且不会为此启动电脑。② `write_computer_file` 写过的路径（扫描也会找到，去重）。③ `export_computer_pdf` 这次导出到「文件」的 PDF 原样算进来，电脑里同一路径不再另存。`import_computer_pdf` 拷进来、字节没变的 PDF 是输入，不算。
- [x] 扫描：`files.py` 新操作 `changed_since`（`muse_computer:changed_since/3`，文件操作，不产生命令 receipt）：不跟随也不列出符号链接；跳过以 `.` 开头的文件和目录（`.venv`、`.cache`、`.openmuse-*` 临时文件）、`node_modules`、`__pycache__`、`venv`、`site-packages`、`*.pyc`/`*.pyo`；最多 50 个文件、8 层、走过 20000 个目录项就停；单个超过 min(10 MB, `FILES_MAX_MB`) 的列进 `skipped` 不收；一次回复合计最多 4 × `FILES_MAX_MB`。电脑忙（对话委派的任务在用）时每 0.5 秒重试，最多 30 秒。
- [x] 什么时候收：聊天 run 的 AG-UI `event_transform`（在 run 自己的进程里）从 RUN_STARTED 起把开始时间、工具名、写过的路径、导出的文件 id 记在进程字典里；RUN_FINISHED（或 RUN_ERROR；停止的回复是 cancelled 的 RUN_FINISHED）发出之前收集、存好，并在它前面插一个 `CUSTOM` 事件 `muse.products`（这一轮的记录）。中继在 run 结束时重绘日志，所以卡片当场出现。
- [x] 存储：每个产物复制进「文件」（`muse_files:upload/4`，任意类型），放在「对话产物」/<对话标题>（按需创建；对话的文件夹按 `threadId` 找回，改名移动都不影响；两个同名对话是“名字 (2)”）。文件记录带出处：`threadId`、`runId`、`computerPath`、`computerId`、`sha256`。同一路径在以后的回复里字节变了就**存成新版本**（新文件，`version` + 1、`previousId`），每张卡片永远是那一次回复的文件；字节没变就复用原文件。电脑停了、删了，预览和下载照常。`muse_files:upload/4` 新增 `meta`、新增 `create_folder/4`（额外字段，不覆盖原有键）。
- [x] 记录：新种类 `chat-products`，每个对话一条（id = 线程 id）：`{id, threadId, turns: [{runId, anchor, files: [{id, name, size, kind, mimeType, path}], createdAt}]}`。`anchor` 是回复结束时聊天记录的条数，卡片放在它之前、这一轮最后一段文字的气泡里；这一轮没有文字就单独放在它后面。删除对话时删掉这条记录（文件留在「文件」）。
- [x] 卡片（`muse_ui_products:card/3`，`muse_ui_chat:log/2` 放置）：文件夹图、“全部文件”、“预览或者下载文件 · N 个文件”、“预览”；N 只数还在「文件」里的，一个都不剩就没有卡片；没有产物的回复没有卡片。样式在 `assets/muse.css` 末尾的注释块里（`scripts/build-css.sh`）。
- [x] 预览（“预览”打开聊天页的模态 `ah_window`，1000 px 宽、85vh 高）：标题栏有文件数和“全部下载”；左边文件列表（按类型的图标、名称、大小），右边预览选中的文件，打开时是第一个：位图 `<img>`（SVG 只显示信息）、PDF iframe、音频/视频播放器、文本和代码只读 `<pre>`、Markdown 渲染，超过 200 KB 截断并说明，其他显示类型和大小。每个文件有“下载”（动作跳到新签发的 `download=1` 签名地址，窗口开着很久也不会拿到过期链接）和“在文件中打开”（`/documents/<id>`）。规则同文件页和内容路由（`muse_files:serve/2`、`nosniff`、HTML/SVG 从不 inline）。
- [x] 全部下载（必做）：`GET /api/threads/:id/products/:runId/zip`（Bearer 或签名 URL，签名路径加进 `muse_signing:is_signable_path/1`；只看当前 owner 的对话，别人的是 404），`zip:create/3` 在内存里打包，合计超过 4 × `FILES_MAX_MB` 返回 413，界面上直接提示逐个下载；条目名是文件的基本名，去掉目录、`..` 和绝对路径，不分大小写去重（`a.txt`、`a (2).txt`）；`content-type: application/zip`、`attachment; filename="files.zip"; filename*=UTF-8''<对话标题>-文件.zip`、`nosniff`。另有 `GET /api/threads/:id/products`（产生过文件的回复列表）。
- [x] 提示词：在 OpenMuse 原文和日程、邮件两段之后加一句（`muse_chat_products:prompt/0`）：智能体在 /workspace 新建或修改的文件会作为可预览、可下载的产物显示在回复末尾，不必把整个文件内容贴进对话。
- [x] 后台任务：不加卡片（任务页本来就有产物和文件）。
- [x] 测试：`computer/tests/test_files.py`（Python，`changed_since` 的走法：只要改过的、跳过噪声、不跟随符号链接、数量/大小/深度上限；eunit 的 `muse_files_py_tests` 调它，主机没有 python3 时跳过）；`muse_computer_SUITE` Docker 组新增 `changed_since`（`MUSE_TEST_COMPUTER_IMAGE` 可指定测试镜像，在 `:art-test` 镜像上通过）；`muse_chat_products_SUITE`（15 个：改过的文件、上限、只在用过电脑时看、导出的 PDF、导入的输入、新版本、每个对话一个文件夹、run 的 `muse.products` 事件和 anchor、没有文件的回复、zip 往返、条目名、zip 大小上限、owner 检查、删除对话、提示词）；`muse_ui_products_SUITE`（6 个：卡片在 run 结束时出现且刷新后在气泡里文字之后、工具之前，没有文件没有卡片，各类预览，单个下载和 zip 的响应头，zip 超限，zip 路由的认证与 owner 检查）；`muse_chat_SUITE` 的提示词测试改为产物一句在最后。
- [x] 文档：designs/04 §3.1、designs/05（聊天一行、路由清单）、docs/DIFFERENCES.md、computer/SOURCE.md。
- [x] 镜像：`files.py` 改了，`make computer-image computer-desktop-image` 后要重建已有的电脑容器才有 `changed_since`（旧容器里扫描失败，只是收集不到产物）。
- [x] `./scripts/check.sh` 通过（eunit 971、ct 173 通过 + 31 个按环境跳过）；headless Chromium 在临时服务器（端口 8861，脚本模型，`openmuse-computer:art-test` 的真实 Docker 电脑）上走了一遍：回复末尾的卡片、打开预览、切到图片和代码、全部下载的 zip（`Pregel BSP 执行流程图-文件.zip`，4 个文件，`node_modules` 和 `.cache` 被跳过）。

## M9-12 跟随 aihtml 61cb232
aihtml 实现了我们提的三条反馈（日历按范围刷新、窗口标题设置、toast 操作链接）。
- [x] `rebar.lock` 升到 `61cb232`。
- [x] 日程：改用 `aihtml_calendar:reload/2`，页面监听 `ah:range`（与 `change` 同一个 `range` 处理），不再借 `change` 触发重载；本地函数改名 `refresh/2`（与 aihtml 新导入的 `reload/2` 同名冲突）。
- [x] 日程两个窗口和写邮件窗口的标题改用 `aihtml_window:set_title/3`，不再写 `<id>-title` 元素。
- [x] 邮件“保存到文件”的 toast 带“打开”链接（按钮原地变成“已保存 · 打开”保留）。

## M9-13 镜像更新后自动重建电脑容器
用户同意（2026-10-26）：以后更新电脑镜像不用再手动删容器。
- [x] `muse_docker:image_id_args/1`；容器 inspect 增加可选的 `Image`（镜像 id）。
- [x] 启动停着的电脑：镜像 id 不同则删容器、同卷重建；运行中的不动；id 未知照旧启动。
- [x] 测试：`muse_computer_pool_tests` 的 `image_update`（运行中不重建、停后启动重建且卷保留、同版本不重建）。

## M9-14 会话里不再出现无关任务
用户反馈（2026-10-26）：会话里出现别的会话的任务卡片（旅行方案、贷款清单）。原因是 agent_status 的卡片列出全部最近任务。
- [x] agent_status 卡片只显示本会话委派的任务（`threadId`），没有就一行摘要；2026-10-26 之前建的任务没有 `threadId`，不再出现在 agent_status 卡片里（delegate_task 自己的卡片不受影响）。
- [x] 工具结果加 `thisConversation`，描述里要求只在被问到时提别的任务。
- [x] 测试：`muse_ui_cards_tests:agent_status_scoped_test`、`muse_chat_SUITE`。

## M9-15 会话卡在 `{http_error,400}`
用户反馈（2026-10-26）：对话框里显示 `{http_error,400}`，之后每条消息都失败。原因：一次回复在工具执行中被服务重启打断，历史里留下没有结果的工具调用（`call_01a1777b4eb474ceb656fbd1`），模型接口拒绝这样的历史。
- [x] `muse_chat_log:repair/1`：交给模型时补“已中断”的工具结果、去掉孤立的工具结果；存储不改，旧会话自动恢复。
- [x] `muse_chat_relay:error_text/1`：HTTP 400/401/403/404/413/429/5xx 与超时给中文说明，原始项作为详情；运行错误写入服务器日志（原来没有记录）。
- [x] 测试：`muse_chat_log_tests`、`muse_ui_cards_tests:run_error_text_test`。

## M9-16 浏览器换成 Chrome + 扩展（不用 CDP）
用户决定（2026-10-26/27）：Playwright 经常被反制；原型对比（原型目录已删除）里 Playwright 和 WebChat/CDP worker 在检测页和知乎、CSDN、Medium、小红书上都被识别，真实 Chrome + 扩展能读到。改为每个用户一个浏览器容器（登录态在会话之间共享）；WebChat 改为 MIT，提取器直接复用。
- [x] 镜像 `browser/`（`make browser-image`）：Chrome stable + Xvfb + openbox + xdotool + 中日韩字体；企业策略强制安装扩展；`browserd`、`ctl.py`、原生消息宿主、`egress.py` 出口代理。
- [x] `muse_browser_docker`（容器、通道、加固、镜像更新重建）、`muse_browser_pool`（空闲停止、控制台按下点）；`muse_browser` 换通道，接口不变。
- [x] 拖拽输入：browserd 的 `drag`；控制台按下-松开为点击、拖动 6 像素以上为拖拽，滑块验证可在控制台完成。
- [x] 去掉 WebChat/CDP worker：`sidecars/webchat-browser`、`scripts/run-browser-worker.sh`、`bin/muse` 的 worker 启停（保留一次性的旧 worker 清理）、`deploy.sh` 的 worker 安装、`muse-browser-worker.service`、`BROWSER_WORKER_URL`/`WORKER_TOKEN`/`BROWSER_WORKER_IMAGE`。
- [x] 配置 `BROWSER_ENABLED`、`BROWSER_IMAGE`、`BROWSER_IDLE_MINUTES`、`BROWSER_NETWORK`；`deploy.sh` 在启用了浏览器但镜像缺失时提醒。
- [x] 测试：`muse_fake_browser` 替换 `muse_fake_worker`；控制台拖拽测试；真实 Chrome 的 `muse_browser_SUITE`（`MUSE_TEST_BROWSER=1`）；验收脚本改用 Chrome 容器并检查出口拦截。
- [x] 文档：docs/browser.md（构建、更新、验证、排错）、browser/README.md、docs/configuration.md、docs/deployment.md、designs/00、designs/04 §4、docs/DIFFERENCES.md、README。
- [x] 线上验证（2026-10-27）：部署到 `~/apps/muse`，验收 28/28；用线上浏览器打开小红书发现页，正常加载（读到 11423 字，只有未登录的登录弹窗，没有 IP 风险拦截或滑块）。
