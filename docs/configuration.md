# 配置

全部通过环境变量配置（也可以写在 `.env` 里），名称与原项目相同，校验失败时节点不会启动。
部署模板见 [`deploy/.env.example`](../deploy/.env.example)。

## 基础

| 变量 | 说明 |
|---|---|
| `WORKSPACE_MODE` | `sample`（默认）或 `live` |
| `OPENMUSE_ACCESS_KEY` | live 模式必填：登录密钥（≥ 24 字符） |
| `TOKEN_ENCRYPTION_KEY` | live 模式必填：令牌加密密钥（32 字节 base64）；也用于加密内置邮件的邮箱密码 |
| `MUSE_UI_SECRET` | live 模式必填：界面签名密钥（≥ 32 字符） |
| `PORT`、`HOST` | 监听端口和地址（默认 8787、0.0.0.0） |
| `PUBLIC_API_URL` | 对外 URL，也用作 Docker 电脑容器命名的一部分 |
| `ALLOWED_ORIGINS` | 允许的 Origin（逗号分隔，`*` 表示全部放行） |
| `TRUST_PROXY` | 是否信任代理头 |
| `DATA_DIR` | 数据目录（Mnesia、bitcask、截图、UI secret、浏览器 profile） |

## 智能体与模型

| 变量 | 说明 |
|---|---|
| `AGENT_BACKEND` | `sample`、`model` 或 `agui` |
| `MODEL` | 例如 `anthropic/claude-sonnet-4.5`；OpenAI 兼容网关用 `openai/<id>` |
| `<PROVIDER>_API_KEY` | 如 `ANTHROPIC_API_KEY`、`OPENAI_API_KEY` |
| `OPENAI_BASE_URL`、`ANTHROPIC_BASE_URL` | 覆盖端点 |
| `OPENAI_CHAT_COMPLETIONS` | OpenAI 兼容网关设为 `true` |
| `CHAT_MAX_STEPS` | 一轮回复最多的模型步数（默认 200） |
| `TASK_MAX_STEPS`、`TASK_RUN_MINUTES`、`TASK_AUTO_RUNS` | 后台任务：每轮最多的工具步数（默认 50）和时长（默认 10 分钟）；一轮没做完自动开新一轮，最多连续 `TASK_AUTO_RUNS` 轮（默认 10） |
| `WEB_SEARCH_ENABLED`、`PARALLEL_API_KEY` | 网页搜索 |
| `JEV_MODE`、`JEV_MODEL`、`TYPESAFE_API_KEY`、`TYPESAFE_BASE_URL` | Jev：`off`、`sample` 或 `live` |
| `TASK_WORKER_ENABLED` | 是否在本节点运行任务 worker |

## 浏览器

| 变量 | 说明 |
|---|---|
| `BROWSER_ENABLED` | `true` 时启用每用户一个浏览器（Firefox ESR）容器（默认 `false`） |
| `BROWSER_IMAGE` | 镜像 tag（默认 `muse-browser:local`，`make browser-image` 构建） |
| `BROWSER_IDLE_MINUTES` | 用户多少分钟没有浏览器活动就停止其容器（默认 30） |
| `BROWSER_NETWORK` | 容器的 Docker 网络（默认 `bridge`，不能是 `host` 或 `none`） |

详见 [docs/browser.md](browser.md)。

## Docker 电脑

| 变量 | 说明 |
|---|---|
| `COMPUTER_ENABLED` | 是否启用 Docker 电脑 |
| `COMPUTER_PROVIDER` | 只接受 `docker` |
| `COMPUTER_IMAGE` | 轻量版镜像（默认 `openmuse-computer:local`） |
| `COMPUTER_DESKTOP` | 设为 `true` 时使用桌面版 |
| `COMPUTER_DESKTOP_IMAGE` | 桌面版镜像（默认 `openmuse-computer-desktop:local`） |
| `COMPUTER_NETWORK` | 电脑容器的网络：`bridge`（默认）或 `none` |
| `COMPUTER_MAX_RUNNING` | 同时运行的电脑上限（默认 4） |
| `COMPUTER_IDLE_MINUTES` | 空闲多少分钟后自动停止（默认 15） |
| `COMPUTER_RETENTION_DAYS` | 停止且多少天未用的电脑连同卷一起删除（默认 7） |
| `COMPUTER_DEPLOYMENT_ID` | 部署 id，用于给容器命名（默认取 `PUBLIC_API_URL`） |

详见 [docs/computer.md](computer.md)。

## Sidecar 与文件

| 变量 | 说明 |
|---|---|
| `PDF_SIDECAR` | PDF sidecar 启动命令 |
| `MAIL_SIDECAR` | 邮件 sidecar 启动命令（默认 `node sidecars/mail/index.mjs`） |
| `MAIL_SYNC_DAYS` | 每个文件夹本地保留最近多少天（默认 30） |
| `MAIL_SYNC_MAX` | 每个文件夹最多多少封（默认 500） |
| `MAIL_POLL_MINUTES` | 轮询间隔（分钟，默认 5；收件箱另有 IMAP IDLE 实时唤醒） |
| `FILES_MAX_MB` | "文件"里单个文件的大小上限（MB，默认 25，最大 1024）；PDF 仍限 10 MB |
