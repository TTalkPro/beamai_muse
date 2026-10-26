# beamai_muse

[English](README_EN.md) | 中文

用 Erlang/OTP 重写 [OpenMuse](https://github.com/CopilotKit/OpenMuse)：一个带浏览器、Linux 终端和文件的个人 AI 助手。
你说出想要的结果，它会拆成持久化的计划，在后台逐步执行；外部写操作必须经过你的审批。

> 设计见 [designs/](designs/)，任务进度见 [TASK.md](TASK.md)，与原项目的差异见 [docs/DIFFERENCES.md](docs/DIFFERENCES.md)。

## 功能

| 功能 | 说明 |
|---|---|
| 聊天 | 主会话和旁支会话，回复实时流式显示，工具结果以卡片展示，可停止，回复期间新消息自动排队，BM25 搜索历史 |
| 后台任务 | 持久化计划，租约 + 心跳，崩溃后由其他 worker 接管；document / finance / plan / agent 四类 |
| 审批 | 发邮件、建日程等外部写操作必须带 hash 审批；执行中断时标记为 `outcome_unknown`，不会重试 |
| 目标、追踪、Ideas、通知 | 里程碑、页面变化/可用性/价格监控（带 diff）、基于证据的建议、实时 toast |
| 文档 | PDF 上传、预览（签名 URL）、表单字段填写 |
| 电脑 | Docker Linux 电脑（终端、文件、PDF 导入导出） |
| 浏览器 | Playwright worker：截图控制台、点击、输入、读取正文、导入下载 |
| Google | Gmail 和 Calendar（只读或读写，令牌加密存储） |
| Jev | 选项面板，sample 规则排序或 TypeSafe live 排序 |
| AG-UI | `/api/agui/*` 端点，可接任意 AG-UI 客户端；也可通过 `AGENT_BACKEND=agui` 代理到外部运行时 |

## 架构

```
浏览器 ──HTTP/SSE──▶ muse_web ── cowboy
                       ├─ aihtml 页面 / 动作 / 推送（muse_ui_*）
                       ├─ JSON API（muse_api_*）
                       └─ AG-UI 端点（muse_agui_handler）
                     muse_agent ── beamai agent + 工具、聊天会话（beamai_agui）、线程、Jev
                     muse_engine ── 任务引擎（租约）、审批、监控、目标、Ideas、领域事件（pg）
                     muse_integ ── 工作区、文件/PDF、Docker 电脑、浏览器、Google
                     muse_core ── 配置、Mnesia（记录 + CAS）、bitcask（事件/聊天/blob）、签名、加密
sidecar：sidecars/pdf（pdf-lib）、sidecars/browser-worker（Playwright）
```

## 依赖

| 依赖 | 用途 |
|---|---|
| [beamai](https://github.com/TTalkPro/beamai)（core / llm / agent） | LLM 客户端与 ReAct Agent |
| [beamai_extra](https://github.com/TTalkPro/beamai_extra)（agui / tools / mcp） | AG-UI SSE 运行时 |
| [aihtml](https://github.com/DavidAlphaFox/aihtml) | 服务端渲染界面 |
| [bitcask](https://github.com/DavidAlphaFox/bitcask) | 事件日志、聊天历史（BM25）、大对象存储 |
| Mnesia（OTP 自带） | 事务记录与 CAS |

依赖以 rebar3 git 依赖的形式通过 https 从 GitHub 获取，具体 commit 由 `rebar.lock` 锁定。
运行环境需要 OTP 27+、rebar3，bitcask 的 NIF 构建需要 cmake、C++23 编译器和 ICU 开发包。

## 快速开始

```sh
make compile      # 拉取依赖并编译
make css          # 生成界面样式（需要 Node，仅构建期）
make shell        # 开发 shell（节点名 muse@127.0.0.1）
make check        # compile + xref + dialyzer + eunit + ct
make acceptance   # 端到端：真实浏览器 worker + Docker 桌面电脑（需先 make sidecars、make computer-desktop-image）
```

**sample 模式**（默认，不需要任何 key）：使用内置的邮件、日历和示例数据，模型也是脚本化的。

```sh
make run          # 打开 http://localhost:8787 ，直接登录
```

**live 模式**：

```sh
export WORKSPACE_MODE=live
export OPENMUSE_ACCESS_KEY=...          # 至少 24 字符
export TOKEN_ENCRYPTION_KEY=$(openssl rand -base64 32)
export MUSE_UI_SECRET=...               # 至少 32 字符
export AGENT_BACKEND=model MODEL=anthropic/claude-sonnet-4.5 ANTHROPIC_API_KEY=...
export PUBLIC_API_URL=https://muse.example.com
make run
```

可选组件：

```sh
make sidecars        # PDF 辅助程序与浏览器 worker（Node + Playwright）
make computer-image  # Docker Linux 电脑镜像
```

## 部署

`scripts/deploy.sh [APP_DIR]`（默认 `~/app/muse`）打一个自带 ERTS 的 prod release，装到 `APP_DIR`：`rel/` 是 release，`bin/muse` 是启停脚本，`sidecars/` 是 PDF 辅助程序和浏览器 worker，`data/` 是数据目录。首次安装时按 `deploy/.env.example` 生成 `APP_DIR/.env`，并填入随机生成的密钥；之后重新部署不会覆盖 `.env` 和 `data/`。如果实例正在运行，脚本会先停掉，装好后再启动。

```sh
./scripts/deploy.sh ~/app/muse
vi ~/app/muse/.env            # 填模型、PUBLIC_API_URL 等
~/app/muse/bin/muse start     # 启动 release，配置了 BROWSER_WORKER_URL 时同时启动浏览器 worker
~/app/muse/bin/muse status    # 也有 stop、restart、logs、remote
```

OpenAI 兼容网关的写法：`MODEL=openai/<模型 id>`，配合 `OPENAI_BASE_URL=http://host:port/v1`、`OPENAI_API_KEY` 和 `OPENAI_CHAT_COMPLETIONS=true`。release 的工作目录是 `APP_DIR/rel`，所以 `.env` 里的路径都要写绝对路径。Mnesia 数据和 `MUSE_NODE_NAME` 绑定，首次启动后不要再改节点名。

## 配置

全部通过环境变量配置（也可以写在 `.env` 里），名称与原项目相同，校验失败时节点不会启动。

| 变量 | 说明 |
|---|---|
| `WORKSPACE_MODE` | `sample`（默认）或 `live` |
| `OPENMUSE_ACCESS_KEY`、`TOKEN_ENCRYPTION_KEY`、`MUSE_UI_SECRET` | live 模式必填：登录密钥、令牌加密密钥、界面签名密钥 |
| `PORT`、`HOST`、`PUBLIC_API_URL`、`ALLOWED_ORIGINS`、`TRUST_PROXY` | 监听地址与对外 URL、允许的 Origin（逗号分隔，`*` 表示全部放行）、是否信任代理头 |
| `DATA_DIR` | 数据目录（Mnesia、bitcask、截图、UI secret） |
| `AGENT_BACKEND` | `sample`、`model` 或 `agui`（`AGENT_URL`、`AGENT_TOKEN`） |
| `MODEL`、`<PROVIDER>_API_KEY` | 例如 `anthropic/claude-sonnet-4.5` 配 `ANTHROPIC_API_KEY`；`OPENAI_BASE_URL`、`ANTHROPIC_BASE_URL` 可改端点 |
| `WEB_SEARCH_ENABLED`、`PARALLEL_API_KEY` | 网页搜索 |
| `BROWSER_WORKER_URL`、`WORKER_TOKEN` | 浏览器 worker |
| `COMPUTER_ENABLED`、`COMPUTER_PROVIDER`、`COMPUTER_IMAGE`、`COMPUTER_DEPLOYMENT_ID` | Docker 电脑；`COMPUTER_PROVIDER` 只接受 `docker`（不支持 E2B 桌面）；部署 id 用于给容器命名，默认取 `PUBLIC_API_URL` |
| `COMPUTER_DESKTOP`、`COMPUTER_DESKTOP_IMAGE` | 设为 `true` 时使用桌面版（Xvfb + openbox，xterm、LibreOffice、mupdf；提供 `use_desktop`）；镜像默认 `openmuse-computer-desktop:local`（`make computer-desktop-image`） |
| `GOOGLE_CLIENT_ID`、`GOOGLE_CLIENT_SECRET` | Gmail 和 Calendar |
| `JEV_MODE`、`JEV_MODEL`、`TYPESAFE_API_KEY`、`TYPESAFE_BASE_URL` | Jev：`off`、`sample` 或 `live` |
| `TASK_WORKER_ENABLED` | 是否在本节点运行任务 worker |
| `PDF_SIDECAR` | PDF sidecar 启动命令 |

## 目录

| 路径 | 内容 |
|---|---|
| `apps/muse_core` | 配置、存储（Mnesia + bitcask）、安全原语 |
| `apps/muse_integ` | 工作区、文件/PDF、电脑、浏览器、Google |
| `apps/muse_engine` | 持久化任务引擎、审批、监控、目标、Ideas |
| `apps/muse_agent` | 模型、工具、聊天与任务 Agent、线程、搜索 |
| `apps/muse_web` | JSON API、AG-UI 端点、aihtml 界面 |
| `sidecars/` | 浏览器 worker（原样复用）、PDF |
| `computer/` | Docker 电脑镜像（原样复用） |
