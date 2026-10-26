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
- **ALLOWED_ORIGINS=\***：额外支持 `*`，放行任意 Origin。CORS 响应仍回显请求的 Origin，因为带凭据时不能用字面量 `*`。OpenMuse 只接受逐个列出的 Origin。
- **MCP 客户端**：搜索（parallel.ai）用 beamai_extra 2.1.0 的 `beamai_mcp_client`（streamable HTTP），每次搜索起一个客户端，报错文案映射成 OpenMuse 的写法。

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

## 电脑与 sidecar

- **Docker 电脑**：用 erlexec 调用 docker（参数数组，环境变量白名单），argv 与原项目逐字对齐。
- **终端输出**：UI 的终端在命令结束后才分块推出输出，而不是边执行边显示，因为 `muse_computer:execute/3` 要等命令结束才返回。
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
