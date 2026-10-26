# 04 集成（muse_core 安全部分 + muse_integ）

规格见 I§3–§10。本文只记录 Erlang 实现上的决定。

## 1. 认证与签名（muse_core）

| 模块 | 内容 |
|---|---|
| `muse_auth` | `session(AccessKey)`：sample 模式不校验，live 模式先对两边做 SHA-256，再用 `crypto:hash_equals` 比较。生成 32 字节随机 token，存储时只存 `sha256hex(token)`，kind 为 `system/sessions`，24 小时过期。`owner(BearerOrCookieToken)` 从 token 查出 owner。`revoke(Token)` 用于登出 |
| `muse_signing` | 签名 key 文件见 I§3.2：44 字符的 base64 文本**原样**作为 HMAC key，文件权限 0600，先写 tmp 再 `file:make_link` 原子发布。`sign(Owner, Path) -> Url` 生成 `?owner=&expires=&signature=`，15 分钟过期。`verify(Req)` 用常数时间比较，签名绑定路径 |
| `muse_vault` | AES-256-GCM（`crypto:crypto_one_time_aead/7`），nonce 12 字节，AAD 为 `openmuse:credential:v1`，密文串为 `v1.<nonce>.<tag>.<ciphertext>`，三段都是无填充的 base64url。key 必须是标准 base64（带填充）且恰好 32 字节。规范化往返校验和各项错误文案逐条对齐 I§10 |
| `muse_rate_limit` | 固定窗口：每个 key 60 秒内最多 120 次，ETS 最多 10000 个 key；key 规则见 I§2.4。登录限流**改为按 IP**（每分钟 30 次），修正原项目的全局计数缺陷（08 分析里提到），这是有意的差异 |
| `muse_config` | 读取环境变量和可选的 `.env` 文件（不覆盖已有的环境变量，提示文案对齐 I§1.1），按原顺序校验，错误文案逐字对齐 |

UI 登录使用 HttpOnly cookie `muse_session`（值为同一种 token，`SameSite=Lax`，配置了 https 的 PUBLIC_API_URL 时加 `Secure`）。JSON API 使用 Bearer。两种方式共用 sessions 记录。

## 2. 文件与 PDF（`muse_files` + `muse_pdf`）

- `muse_files` 按 I§5.1–§5.4 实现（PDF 字节放在 bitcask `blobs` 的 `pdf/<id>` 下，幂等写入流程见 01-store §3）：
  - 存储布局、确定性 id（`deterministicFileId` 的位运算）、`sanitizeFileName`、keyed 写入时先写 tmp 再 link 的幂等逻辑；
  - 填表后的命名规则：去掉 `.pdf`，加上 ` — filled.pdf`；
  - `key'` 的 JSON 规则。
- `muse_pdf` 是端口客户端，背后是 `sidecars/pdf/index.mjs`（Node + pdf-lib，把原 `packages/integrations/src/pdf.ts` 移植成 JS，或用 tsx 直接运行）：
  - 协议：`{packet,4}` 帧，内容为 JSON：`{"op":"inspect"|"fill"|"sample","pdf":base64,"values":{...}}`，返回 `{"ok":...}` 或 `{"error":"PdfError","message":...}`；
  - 端口池大小为 2，单次调用超时 20 秒，超时后杀掉端口进程并重启；
  - 大小上限（10 MiB）和 `%PDF-` 头检查在 Erlang 侧先做一遍；
  - 示例 PDF 用 sidecar 生成一次，写入 `apps/muse_integ/priv/sample-permission-slip.pdf`，运行时不依赖 sidecar 生成。
- PdfError 统一映射为 HTTP 422。

### 2.1 任意文件与文件夹（M9-6，OpenMuse 只存 PDF）

- **两条写入路径**：`import/4,6` 仍是 PDF 专用（智能体工具、电脑导出、浏览器下载、填表、sample），不是 PDF 就 422，行为与 OpenMuse 一致；`upload/4` 收任意文件（`POST /api/files`、界面 `/upload`），单个不超过 `FILES_MAX_MB`（默认 25，最大 1024）。PDF 走原来的检查（≤10 MiB、≤500 页、sidecar 检查字段）。
- **类型判断**（`detect_mime/3`）：先看文件头（PDF、PNG、JPEG、GIF、WebP、BMP、WAV、MP3、FLAC、Ogg、MP4/M4A/MOV/AVIF、WebM、zip、gzip、7z、rar），扩展名只在媒体容器和 zip 系格式（`.m4a`、`.mkv`、`.docx`…）上细化文件头的结果；没有文件头再看扩展名，再看上传方声明的类型，都没有时按前 8 KB 是否为 UTF-8 文本定 `text/plain` 或 `application/octet-stream`。名字或声明是 PDF、内容却不是的，422 “This file is not a valid PDF”。
- **记录**：仍是 `files` 种类、Artifact 形状，新增 `kind`（`pdf | image | audio | video | text | archive | other`，由 MIME 推出）、`folderId`（`null` 为根目录）、`starred`、`updatedAt`（重命名、移动时更新，加星不算）。PDF 保留 `pageCount`、`fields`、填表副本的 `parentId`（副本放在源文件所在的文件夹）；其他文件没有 fields。M9-6 之前的记录没有这些键，`normalize/1` 读成根目录、`pdf`、未加星，不做迁移。
- **字节**：PDF 仍在 `blobs` 的 `pdf/<id>`，其他文件在 `file/<id>`。这样旧记录和旧 blob 不用动，维护时也能按前缀分开。删除文件时先删记录再删 blob（中途崩溃只会留下孤儿 blob）。
- **需要 PDF 的地方**用 `get_pdf/2`、`pdf_bytes/2`：`fill`、任务模型的 `inspect_pdf`/`fill_pdf`、document 任务的起点、电脑的 `import_pdf`（`POST /api/computer/files/import`）。对非 PDF 返回 422 ““名字” is not a PDF. Only PDFs can be inspected, filled or copied to a computer.”。电脑的 `export_pdf` 和浏览器下载导入仍走 `import`，只收 PDF。浏览器下载对应的文件被删除后再导入，会重新下载而不是报 404。
- **文件夹**：`file-folders` 种类，`{id, name, parentId, createdAt}`，可任意嵌套（没有移动文件夹，所以不会成环）。名字去首尾空白，1–80 字符，不能含 `/`、`\` 和控制字符，同一父目录下不区分大小写不能重名（409）。删除默认要求为空（409 “The folder is not empty”），`recursive` 时连同子文件夹和其中的文件一起删除。`folder_path/2` 给面包屑用。
- **内容路由**（`GET /api/files/:id/content[?download=1]`，`serve/2`）：`content-type` 用文件自己的类型；PDF、常见位图（PNG、JPEG、GIF、WebP、AVIF、BMP、ICO）、音频、视频默认 `inline`，其余和 `download=1` 一律 `attachment`；`text/html`、XHTML、SVG、XML、JavaScript 从不 inline，一律以 `application/octet-stream` 附件发送；始终带 `x-content-type-options: nosniff`。
- **请求大小**：`muse_mw` 对 `POST /upload` 和 `POST /api/files` 放宽到 `max(FILES_MAX_MB + 1 MiB, 12 MiB)`，multipart 读取上限为 `FILES_MAX_MB + 64 KiB`，精确上限由 `muse_files` 检查（413 “Files must be N MB or smaller”）；其他路由仍是 12 MiB。
- **JSON API**（按原有风格，尽量小）：`GET /api/files[?folder=<id>|root]` 返回 `{"files": [...]}`（签名 URL，带 `folderId`）；`POST /api/files` 收任意类型，文件夹用 multipart 字段 `folder` 或 `?folder=`；`PATCH /api/files/:id` `{name?, folderId?, starred?}`；`DELETE /api/files/:id`；`GET|POST /api/file-folders`（`{name, parentId?}`）、`PATCH /api/file-folders/:id`（`{name}`）、`DELETE /api/file-folders/:id[?recursive=true]`（返回删除的文件数和文件夹数）。`GET /api/workspace` 的 `files` 也带上新字段，PDF 的形状不变。

## 3. Docker 电脑（`muse_computer*`）

- 镜像直接复用原 `apps/computer`（拷贝到 `computer/`）：`docker build -t openmuse-computer:local computer`。
- `muse_docker`：
  - 通过 `open_port({spawn_executable, Docker}, [{args, Argv}, {env, 白名单环境}, exit_status, binary, stderr_to_stdout?])` 调用 docker，**不经过 shell**；
  - stdout 和 stderr 要分开采集。docker exec 本身无法分离这两路，这里用 `/bin/sh -c 'exec 2>&3'` 之类的技巧**不可取**。正确做法是把 stderr 重定向到端口程序 `muse_run`：一个极小的 C 或 Python 包装器，或者用 `erlexec`。决定用 **erlexec**（hex `erlexec`），它支持分离 stdout/stderr、杀进程组和超时；
  - argv 逐字对齐 I§6.4（create、start、exec、stop、文件操作）。
- `muse_computer`（对应 computer.ts）：
  - lease 记录 `computer-state/lease`（180 秒，原项目不续租，这里照搬）；
  - 执行前先写一条 `running` 状态的 receipt，执行后更新；
  - 幂等键（operation id 重放时返回原结果）；
  - 输出截断上限见 I§6.1；
  - 宿主侧 35 秒兜底超时；
  - docker 客户端断开时直接 stop 容器。
- `muse_computer_files`：`docker exec -i ... python3 -I /opt/openmuse/files.py`，请求通过 stdin 传 JSON，超时 8 秒。
- `muse_computer_tools`：工具定义按 E§8.1 逐字实现，scope 区分 chat 和 task。
- E2B 桌面：不支持（用户决定，2026-10-23）。`muse_computer_provider` behaviour 保留，目前只有 Docker 一个实现。
- Docker 桌面版（`COMPUTER_DESKTOP=true`，新增）：镜像 `computer/Dockerfile.desktop`（Xvfb + openbox + xterm/LibreOffice/mupdf）。`muse_docker:create_args/3` 的 `desktop` 变体保持同样的隔离，放宽限额（1536m、512 pids、2 CPU、256 MiB /tmp），入口改为 `/opt/openmuse/desktop-init`，加 `DISPLAY=:0` 和标签 `dev.openmuse.variant=desktop`；`light` 变体的 argv 与原来逐字相同。附着时按配置的变体核对，另一变体的容器拒绝附着。
- `muse_computer_desktop`：桌面动作（截图、点击、键入、按键、滚动、等待），schema 与文案照搬 OpenMuse 的 E2B 桌面；通过 `docker exec` 运行固定脚本，xdotool 参数作为位置参数传入（不拼接 shell 字符串）；先释放修饰键，输入失败 exit 3，截图失败 exit 4；receipt、截图存储和幂等重放同 OpenMuse。

### 3.1 电脑池（新增，2026-10-25；OpenMuse 每个用户只有一台电脑）

- **一个 scope 一台电脑**：对话 `thread:<threadId>`、后台任务 `task:<taskId>`。对话委派的任务记下对话（任务的 `threadId`，`muse_agent_service:create_task/5`）并用对话的电脑，所以一个对话和它的任务只有一台电脑；API 和目标计划建的任务、或对话已删除的任务用自己的 `task:<taskId>`（`muse_task_model:computer_scope/2`）。没有默认电脑（2026-10-26 去掉）：旧版本按用户建的那台（scope `user`）作为“旧的默认电脑”保留，不再新建。电脑 id = `sha256hex("computer:" ++ owner ++ 0 ++ scope)` 的前 16 位，同一 scope 永远找到同一台电脑，智能体不用记 id。
  - 聊天在 `muse_chat_agent` 里传 `thread:<threadId>` 作电脑 scope、`chat:<requestKey>` 作 operationId 前缀（幂等键与 OpenMuse 相同）；任务传上面选出的电脑 scope 和 `task:<taskId>`（operationId 前缀）。对话和任务会同时用一台电脑，所以智能体工具（命令、文件、use_desktop）遇到 409 Computer is busy 时每秒重试，最多 `computer_busy_wait_ms`（muse_agent 环境，默认 180 秒，等于 lease 时长）；被拒时什么都没执行，命令的幂等键不变，所以重试安全。`/api/computer/*` 仍立即返回 409。`muse_computer_tools:tools/3` 仍可用，从 `chat:<threadId>:<msgId>` 推出 thread。
- **ref**：`muse_computer` 的所有函数接受 `ref()` = `{Owner, Id}`，不再接受只给 owner。旧的默认电脑（`is_legacy/1`）保留 OpenMuse 的名字（容器 `openmuse-<dep>-<ownerhash>-computer`、卷 `...-workspace`、lease `computer-state/lease`、receipt 不带 `computerId`）；其他电脑：容器/卷名加 `-<id>`，标签加 `dev.openmuse.computer=<id>`（创建时再加 `dev.openmuse.scope=<scope>`），lease `computer-state/lease:<id>`，receipt（命令和桌面动作）带 `computerId`，最新截图 `computer-desktop-screens/latest:<id>`，文件 `<sha256hex(owner)>-<id>.jpg`，签名截图 URL 一律加 `&computer=<id>`（旧的默认电脑也加）。附着时的隔离核对（标签、挂载、网络、用户、环境变量白名单、限额）按容器逐个进行。
- **注册表** `muse_computers`：记录 `computers/<id>`（每个 owner）：`id, scope, title, container, volume, variant, status (running|stopped|error), createdAt, lastUsedAt, startedAt`。命令、文件操作、桌面动作、启动都会刷新 `lastUsedAt`。列表时标题实时取对话/任务的 `title`，取不到用存的标题。
- **自动启动**：工具第一次执行命令（`execute/3` 的 `auto_start`）、文件操作（`ensure_running/1`）或桌面动作（`desktop_action/3` 的 `auto_start`）时，电脑没运行就先启动；`start_computer` 仍保留但可选。`/api/computer/*` 不自动启动（OpenMuse 的 409 不变），且必须指定电脑：`?computer=<id>`（当前用户的电脑，否则 404）或 `?thread=<threadId>`（该对话的电脑，没有就建记录；对话不存在 404）；都不给是 400。
- **`muse_computer_pool`**（muse_integ 下的 gen_server，60 秒一次）：
  - 准入：启动一台停止的电脑时，若本部署（按 `dev.openmuse.deployment` 标签 `docker container ls`）已有 `COMPUTER_MAX_RUNNING`（默认 4）台在运行，先停最久未用的空闲电脑（`stop_if_idle/1`：拿得到 lease 才停，正在执行命令的不停）；都在忙则返回 503 `All N running computers are busy (COMPUTER_MAX_RUNNING). ...`。准入用 `global:trans` 按部署串行，避免并发启动挤爆上限。
  - 空闲停止：运行中且 `COMPUTER_IDLE_MINUTES`（默认 15）分钟未用的电脑停止，卷保留。
  - 保留期：停止且 `COMPUTER_RETENTION_DAYS`（默认 7）天未用的对话/任务电脑整台删除（容器 + 卷 + receipt + lease + 截图 + 记录）。旧的默认电脑不自动删：卷里可能有池之前留下的唯一一份文件，用户下载后自己删。
  - 对账：每次巡检按 Docker 修正记录的 `status`（记录说 running 但容器没了或停了 → stopped）。启动时还处理无记录的容器（`docker ps -a` 按部署标签）：能从标签恢复 owner（在 store 里已知的 owner 中按 owner 哈希匹配）和 scope（`dev.openmuse.scope`，默认电脑没有电脑标签即 `user`）且 id 一致的，收编为已停止的电脑；恢复不了的停止并保留，写警告日志。**不自动删除**：卷里可能有唯一一份文件。
  - `overview/0`：运行中的容器名、上限、空闲分钟和 `docker stats --no-stream`（缓存 5 秒），供管理页使用。
  - 测试环境设 `muse_integ` 的 `computer_pool_timer = false` 关掉定时巡检。
- **删除** `muse_computer:delete/1`：正在执行命令则先 Stop，然后按名字 `docker container rm --force` 和 `docker volume rm`（不做附着核对，所以配置变更后被拒绝附着的容器也能删掉重建）。
- **网络** `COMPUTER_NETWORK`：`bridge`（默认，能上网，也能访问宿主机所在局域网）或 `none`（OpenMuse）。`muse_docker:create_args/4` 只改 `--network` 的值；附着时要求容器恰好在所配置的网络上（`NetworkMode` 和 `Networks` 的唯一键），另一设置下创建的容器以专门文案拒绝。快照 `network` 为 `enabled`/`disabled`；智能体说明 `none` 用 OpenMuse 原文，`bridge` 用联网版本（没有浏览器、没有凭据；镜像无 curl、无系统 CA 证书）。
- **界面**：`/computer` 是电脑列表（名称、状态、类型、最近使用、CPU/内存、打开/启停/删除），`/computer/<id>` 是单台电脑页，只用来查看和管理（见 05-web-ui.md）。动作带 `#{id => Id}`，每次都核对电脑属于当前用户。
- **文件传输**（新增）：`files.py` 增加 `read_file`/`write_file`（任意普通文件 ≤10 MB，base64，拒绝符号链接），`muse_computer:download/2`、`upload/3`；`GET /computer-files/<id>/download?path=` 以附件下载，`POST /computer-files/<id>/upload?dir=` 收 multipart 的 `file` 部分写进该目录（同名覆盖）。两者走会话 cookie（muse_ui_computer_files），不是 JSON API。

## 4. 浏览器（`muse_browser`）

- Worker 服务原样复用：把原 `apps/worker` 拷到 `sidecars/browser-worker`，`npm i && npx playwright install chromium`。远程机器目前没有 chromium，需要安装（M2 任务）。
- `muse_browser` 按 I§7.2 实现：
  - 每个会话串行化：`muse_browser_serial`，以会话 id 为键，每个 id 一个 FIFO 进程，空闲后退出；
  - 可达性缓存 15 秒；
  - 请求超时 45 秒；
  - 错误映射：worker 返回非 2xx 时报 502，连不上 worker 时报 503；
  - 先写 `browsers` 归属记录，再调用 worker；
  - 实现 observe 和 observeForThread，以及 downloads 导入。
- HTTP 调用用 `beamai_http:request_meta/5`。截图 PNG 是二进制，确认 `beamai_http` 对非 JSON 响应原样返回二进制（ref digest §8 已验证）。
- 签名控制台页 `/api/browsers/:id/console`：按 I§7.5 逐字节复刻原 HTML，供外部客户端使用。内置 UI 另外做一个 aihtml 版本（05-web-ui）。

## 5. Google（已删除）

M9-4（2026-10-26）按用户决定删掉了 Google OAuth、Gmail 和 Calendar（原 `muse_google_auth`、`muse_google_api`、`muse_google_ws`、`muse_gmail`、`muse_gcal`、`muse_mail_text`），连同 `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` 配置、`/api/google/*` 路由和 `/apps` 页面。以后会内置日程和邮件收发，作为新的工作重新设计；它们的外部写入通过审批的操作类型接入（02-engine §5）。`muse_vault` 和 `TOKEN_ENCRYPTION_KEY` 保留（live 模式仍然必填，与原项目配置兼容），内置邮件（§7）用它加密邮箱密码。

## 6. 工作区（`muse_workspace`）

- 快照（I§4.4）：mode、profile、files、browsers、actions、activity、connections（只剩 browser 和 openbot）、runtime；没有 `mail` 和 `events`，`?q=` 不再使用。
- `section_snapshot/2` 给任务模型的 `read_workspace`：只有 files（不带 URL）。
- sample 模式在第一次登录时（`ensure_sample/1`）把郊游同意书（`muse_pdf:sample/0`）放进“文件”，来源“Sample · Lincoln Middle School”。原来的示例邮件、日程和那条待审批的日程提案（`muse_workspace_seed`）都删掉了。
- 外部写入不再经过工作区：由注册的操作类型自己执行（02-engine §5）。

## 7. 邮件收发（`muse_mail_client` + `sidecars/mail`，M9-8）

内置邮件读写用户现有的邮箱：IMAP 收信，SMTP 发信。协议层是一个 Node 端口程序，引擎侧的账号、同步、发送和审批类型见 02-engine §9。

**为什么用 Node sidecar 而不是 Erlang**：邮件的难处在 MIME 和字符集（中文邮件大量是 GBK/GB2312、Big5，RFC 2047 编码的头，quoted-printable，嵌套的 multipart，只有 HTML 的邮件要转出文本）和 IMAP 客户端本身（literal、IDLE、CONDSTORE、各家服务器的怪癖）。imapflow、mailparser、nodemailer 是这几件事维护最积极的参考实现（同一作者，mailparser 用 iconv-lite 处理全部常见字符集）；OTP 只有 UTF-8/Latin-1，gen_smtp 只解决发信，IMAP 和字符集都得自己写。代价是多一个 Node 进程，而 PDF 辅助程序已经需要 Node。依赖钉死在 `sidecars/mail/package.json`（`--save-exact`）和 `package-lock.json`：imapflow 2.9.1、mailparser 3.12.4、nodemailer 10.2.1（共 46 个包，约 14 MB）；`make sidecars`、`scripts/deploy.sh`、`scripts/check.sh` 用 `npm ci` 安装（check.sh 只在缺 `node_modules` 时装，并跑 `npm test`）。

**协议**（`sidecars/mail/README.md`）：`{packet,4}` JSON 帧，请求带 `id`，回复可以乱序（慢的服务器不挡别的账号）。操作：`verify`（IMAP 和 SMTP 各登录一次）、`folders`（LIST + STATUS）、`scan`（某文件夹 UIDVALIDITY 之后的新 UID，首次或 UIDVALIDITY 变了时是最近 N 天；以及已存 UID 范围的 flags）、`fetch`（一批 UID：头、flags、BODYSTRUCTURE 里的附件列表、源码前 2 MB 交给 mailparser 解出 text/html）、`attachment`（按 part 取一个附件，上限 FILES_MAX_MB）、`flags`、`move`（UIDPLUS 的新 UID）、`expunge`、`send`（nodemailer 的 MailComposer 只生成一次报文：SMTP 发出，按需原样 APPEND 到已发送）、`watch`/`unwatch`（单独连接上的 IDLE，事件 `exists | expunge | flags | closed`）、`close`。错误是 `{code, message, definite?}`，code 为 `auth | tls | timeout | connect | notfound | toolarge | uidvalidity | send_failed | error`；发信时连接在 DATA 期间断开为 `definite: false`（服务器可能已经收下）。

**TLS 与超时**：每个账号的 IMAP、SMTP 各自选 `tls`（993/465 隐式 TLS）或 `starttls`（143/587，升级是强制的，服务器不支持就失败，不会明文发送密码）；没有明文选项。证书默认校验（`rejectUnauthorized`，TLS ≥ 1.2，SNI 用主机名），账号可以显式勾“允许自签名证书”。连接 20 s、问候 16 s、socket 空闲 120 s；Erlang 侧每个请求还有自己的期限（verify/folders 60 s，scan 120 s，fetch 180 s，send 180 s），超时就回 `timeout`（发信为结果未知）并让 sidecar 丢掉这个账号的连接。每个账号缓存一个 IMAP 连接，两分钟不用就关；同一账号的操作串行。

**不阻塞 BEAM**：`muse_mail_client` 是一个持有端口的 gen_server，请求多路复用：调用方自己编码请求帧（带唯一 id），服务器只写端口、记下 `{From, Timer}`；回复帧只读开头的 `{"id":N` 就原样交回调用方，由调用方解码（一批邮件可能几 MB）。端口第一次用到时才启动（没有 node 也能开机，请求返回 `unavailable`）；端口挂了，所有在途请求得到 `unavailable`、所有 watch 得到 `closed`，下次请求重启。启动方式与 PDF 辅助程序相同（`muse_pdf:sidecar_port/2`）：无 shell、参数数组、环境变量白名单（PATH、HOME、LANG、LC_ALL、TZ，加上 CA 相关的 NODE_EXTRA_CA_CERTS、SSL_CERT_FILE、SSL_CERT_DIR）。

**密码**：账号密码（授权码 / 应用专用密码）用 muse_vault（AES-256-GCM，`TOKEN_ENCRYPTION_KEY`）加密后存为 `secret`；只在请求帧里以明文出现。imapflow、nodemailer 都关掉了 logger，sidecar 不打日志，错误信息只有服务器的回复文字。页面、API、智能体只拿到 `muse_mail_accounts:public/1`（没有 `secret`，只有 `hasPassword`）。

**测试**：`sidecars/mail/tests/lib.test.mjs`（`npm test`：附件识别、文件夹角色、摘要、错误分类、MailComposer 生成的回复经 mailparser 解析回来的线程头和附件、只有 HTML 的邮件转文本）；Erlang 侧在 `sidecars/mail/tests/fake-sidecar.mjs` 上测：同样的帧和操作，“服务器”是测试写的 JSON 状态文件（`muse_mail_fake`），不联网。

## 8. 安全检查清单（每个模块的验收都要对照）

2026-10-23 做了一次独立只读审查（M8-2），问题已修复：

- [x] 所有秘密比较都用 `crypto:hash_equals`：访问 key、签名 URL、worker token、审批 hash（`muse_actions:decide/4`，原来是 `=/=`，已修）。会话 token 和 OAuth state 是按哈希或随机 id 查表，不做比较。
- [x] 错误响应不包含堆栈或上游响应体，日志只记录错误类别：
  - `muse_api`、`muse_agui_handler`、`muse_ui_b_upload` 原来记录完整 reason 和堆栈（可能带上含 cookie/Authorization 的 Req），已改为 `muse_http:class/1`；
  - 模型失败、工具失败、聊天启动失败原来会把任意 reason 用 `~p` 格式化后返回给用户，已改为固定文案，日志只记类别。
  - **有意保留的例外**（与 OpenMuse 一致）：搜索 MCP 的 HTTP 错误带上响应体（最多 500 字符），不含我们的凭据。（原来 Google API 错误也带 `error.message`，已随 Google 删除。）
- [x] docker、sidecar 调用一律用参数数组，环境变量用白名单：
  - docker 本来就是这样；桌面版的动作也一样：固定脚本 + 位置参数，键入的文字只作为一个 argv 元素；桌面版容器同样无网络、只读根、无 capability、不发布端口（X 只监听本地 socket）；
  - PDF sidecar 原来继承整个 BEAM 环境（含各类 API key 和加密 key），已改为只保留 PATH、HOME、LANG、LC_ALL、TZ；
  - 杀进程原来经过 `os:cmd`，已改为直接执行 `kill`。
- [x] 文件 id 必须通过 UUID 正则校验，路径要在根目录内，拒绝符号链接（files.py 用 `O_NOFOLLOW`，并配合 lstat 检查）。
- [x] 签名 URL 绑定路径，15 分钟过期。签名不区分 HTTP 方法，所以签名的 `/console` URL 也允许 POST 输入，这与 OpenMuse 的控制台设计一致。
- [x] 外部写操作只能通过审批路径执行：操作类型的 `execute/3` 只由 `muse_actions` 在批准后调用；agent 只能拒绝，不能批准。
- 其他：UI 动作都通过 `with_owner` 校验归属；表单 POST 依赖 Origin 校验加 SameSite=Lax cookie；`/upload` 没有单独限流，只有体积上限。
- [x] 内置邮件（M9-8）：邮箱密码只加密存放、从不返回；邮件 HTML 只在沙箱 iframe 里显示，`/mail-content/<id>/body` 自带 CSP（`sandbox`、`default-src 'none'`、默认只允许 data: 图片），从不在应用的源里渲染；附件下载沿用文件内容路由的规则（HTML/SVG 永不 inline，`nosniff`）；邮件内容交给智能体时标明不可信；智能体的每次发信都要审批，发送回执保证同一封不会发两次。
