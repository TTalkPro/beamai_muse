# BeamAI Muse

[English](README_EN.md) | 中文

用 Erlang/OTP 重写 [OpenMuse](https://github.com/CopilotKit/OpenMuse)：一个带浏览器、Linux 电脑和文件的个人 AI 助手。
你说出想要的结果，它会拆成持久化的计划，在后台逐步执行；外部写操作必须经过你的审批。

> 设计见 [designs/](designs/)，任务进度见 [TASK.md](TASK.md)，与原项目的差异见 [docs/DIFFERENCES.md](docs/DIFFERENCES.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [浏览器 worker](docs/browser.md) | WebChat/CDP Docker worker 的镜像生成、配置、WebChat 注入与抓取流程、输入能力和安全边界 |
| [Docker 电脑](docs/computer.md) | 轻量版与桌面版镜像的构建、配置和更新策略 |
| [部署](docs/deployment.md) | `deploy.sh` 步骤、目录结构、systemd、OpenAI 兼容网关 |
| [配置](docs/configuration.md) | 全部环境变量说明 |
| [差异](docs/DIFFERENCES.md) | 与 OpenMuse 的有意差异 |

## 功能

| 功能 | 说明 |
|---|---|
| 聊天 | 多会话，回复实时流式显示，工具结果以卡片展示，可停止，BM25 搜索历史 |
| 后台任务 | 持久化计划，租约 + 心跳，崩溃后由其他 worker 接管 |
| 审批 | 外部写操作必须带 hash 审批；操作类型可插拔（内置日程 `calendar.event`、内置邮件 `mail.send`） |
| 日程 | 内置日历（`/calendar`）：月/周/日/列表、重复、拖动改期 |
| 邮件 | 收发你现有的邮箱（IMAP/SMTP，密码加密保存），文件夹、搜索、阅读、回复/转发、附件、IDLE 实时收信 |
| 文档 | PDF 上传、预览、表单字段填写 |
| 电脑 | Docker Linux 电脑，每个对话一台（命令行和桌面） |
| 浏览器 | WebChat/CDP Docker worker：截图控制台、点击、输入、读取正文 |
| Jev | 选项面板，sample 规则排序或 TypeSafe live 排序 |
| AG-UI | `/api/agui/*` 端点，可接任意 AG-UI 客户端 |

## 架构

```
浏览器 ──HTTP/SSE──▶ muse_web ── cowboy
                       ├─ aihtml 页面 / 动作 / 推送（muse_ui_*）
                       ├─ JSON API（muse_api_*）
                       └─ AG-UI 端点（muse_agui_handler）
                     muse_agent ── beamai agent + 工具、聊天会话（beamai_agui）、线程、Jev
                     muse_engine ── 任务引擎（租约）、审批、监控、目标、Ideas、领域事件（pg）
                     muse_integ ── 工作区、文件/PDF、Docker 电脑、浏览器
                     muse_core ── 配置、Mnesia（记录 + CAS）、bitcask（事件/聊天/blob）、签名、加密
sidecar：sidecars/pdf（pdf-lib）、sidecars/mail（imapflow、mailparser、nodemailer）、sidecars/webchat-browser（Chromium + CDP + WebChat extractor）
```

## 依赖

- OTP 27+、rebar3
- cmake、支持 C++23 的编译器、ICU 开发包、zlib 开发包（bitcask NIF）
- Node 22.6+、npm（构建 CSS；PDF/邮件 sidecar；浏览器镜像构建前 typecheck）
- rsync、GNU make、openssl
- Docker CLI 与 Docker Engine（浏览器 worker 和 Docker 电脑）

Erlang 依赖以 rebar3 git 依赖的形式通过 https 从 GitHub 获取，具体 commit 由 `rebar.lock` 锁定。

## 快速开始

```sh
make compile      # 拉取依赖并编译
make css          # 生成界面样式（需要 Node，仅构建期）
make shell        # 开发 shell（节点名 muse@127.0.0.1）
make check        # compile + xref + dialyzer + eunit + ct
```

**sample 模式**（默认，不需要任何 key）："文件"里预置一份郊游同意书 PDF，模型是脚本化的：

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
make sidecars        # PDF、邮件辅助程序与浏览器镜像
make browser-image   # 浏览器 worker 镜像（WebChat/CDP Docker）
make computer-image  # Docker Linux 电脑镜像（轻量版）
make computer-desktop-image  # Docker Linux 电脑镜像（桌面版）
```

## 部署

```sh
./scripts/deploy.sh ~/apps/muse
vi ~/apps/muse/.env            # 填模型、PUBLIC_API_URL 等
~/apps/muse/bin/muse start     # 配置了 BROWSER_WORKER_URL 时同时启动浏览器容器
```

详见 [docs/deployment.md](deployment.md)。
