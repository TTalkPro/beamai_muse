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

## 5. Google（`muse_google_auth`、`muse_gmail`、`muse_gcal`）

- OAuth 按 I§9.1–§9.4 实现：
  - PKCE S256；state 10 分钟过期，用 `take` 一次性读取；
  - 按需申请 scope，包括 `calendar.calendarlist.readonly`；
  - generation 和 connectionId 机制；
  - token 用 vault 加密存储；
  - 刷新 token 时用 `muse_store:update/4` 对 connectionId 做条件写，对应原 `updateCredential`。
- API 调用按 I§9.5–§9.8 实现：
  - Gmail 搜索、线程、消息解析（`mapMessage`）、附件、草稿，以及 MIME 构造（`sendEmail`）；
  - Calendar 的列表、事件 CRUD；
  - `GoogleApiError` 映射为 502。
- 测试：移植 `google.test.ts` 和 `oauth.test.ts` 中可离线运行的用例，HTTP 用 meck 打桩。

## 6. 工作区（`muse_workspace`）

- 统一 sample 和 live 两种模式下的邮件、日历、文件、连接、快照（I§4）。
- sample 夹具（邮件、日程）放在 `muse_workspace_seed`，内容从原 `workspace.ts::seed` 逐字移植。每次登录时调用 `ensure_sample/1`。
- `execute_action/2` 负责审批通过后的外部写入：sample 模式写本地 mail 和 events；live 模式调用 Gmail 或 Calendar。

## 7. 安全检查清单（每个模块的验收都要对照）

2026-10-23 做了一次独立只读审查（M8-2），问题已修复：

- [x] 所有秘密比较都用 `crypto:hash_equals`：访问 key、签名 URL、worker token、审批 hash（`muse_actions:decide/4`，原来是 `=/=`，已修）。会话 token 和 OAuth state 是按哈希或随机 id 查表，不做比较。
- [x] 错误响应不包含堆栈或上游响应体，日志只记录错误类别：
  - `muse_api`、`muse_agui_handler`、`muse_ui_b_upload` 原来记录完整 reason 和堆栈（可能带上含 cookie/Authorization 的 Req），已改为 `muse_http:class/1`；
  - 模型失败、工具失败、聊天启动失败原来会把任意 reason 用 `~p` 格式化后返回给用户，已改为固定文案，日志只记类别。
  - **有意保留的例外**（与 OpenMuse 一致）：Google API 错误带上 Google 的 `error.message`（最多 500 字符）；搜索 MCP 的 HTTP 错误带上响应体（最多 500 字符）。两者都不含我们的凭据。
- [x] docker、sidecar 调用一律用参数数组，环境变量用白名单：
  - docker 本来就是这样；桌面版的动作也一样：固定脚本 + 位置参数，键入的文字只作为一个 argv 元素；桌面版容器同样无网络、只读根、无 capability、不发布端口（X 只监听本地 socket）；
  - PDF sidecar 原来继承整个 BEAM 环境（含各类 API key 和加密 key），已改为只保留 PATH、HOME、LANG、LC_ALL、TZ；
  - 杀进程原来经过 `os:cmd`，已改为直接执行 `kill`。
- [x] 文件 id 必须通过 UUID 正则校验，路径要在根目录内，拒绝符号链接（files.py 用 `O_NOFOLLOW`，并配合 lstat 检查）。
- [x] 签名 URL 绑定路径，15 分钟过期。签名不区分 HTTP 方法，所以签名的 `/console` URL 也允许 POST 输入，这与 OpenMuse 的控制台设计一致。
- [x] 外部写操作只能通过审批路径执行：Gmail 发送和 Calendar 写入只能经由 `muse_actions` 到达；agent 只能拒绝，不能批准。
- 其他：UI 动作都通过 `with_owner` 校验归属；表单 POST 依赖 Origin 校验加 SameSite=Lax cookie；`/upload` 没有单独限流，只有体积上限。
