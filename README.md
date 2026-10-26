# BeamAI Muse

[English](README_EN.md) | 中文

用 Erlang/OTP 重写 [OpenMuse](https://github.com/CopilotKit/OpenMuse)：一个带浏览器、Linux 电脑和文件的个人 AI 助手。
你说出想要的结果，它会拆成持久化的计划，在后台逐步执行；外部写操作必须经过你的审批。

> 设计见 [designs/](designs/)，任务进度见 [TASK.md](TASK.md)，与原项目的差异见 [docs/DIFFERENCES.md](docs/DIFFERENCES.md)。

## 功能

| 功能 | 说明 |
|---|---|
| 聊天 | 主会话和旁支会话，回复实时流式显示，工具结果以卡片展示，可停止，回复期间新消息自动排队，BM25 搜索历史 |
| 后台任务 | 持久化计划，租约 + 心跳，崩溃后由其他 worker 接管；document / finance / plan / agent 四类 |
| 审批 | 外部写操作必须带 hash 审批；执行中断时标记为 `outcome_unknown`，不会重试。操作类型可插拔（`muse_action_kind`）：内置日程的 `calendar.event` 和内置邮件的 `mail.send` |
| 日程 | 内置日历（`/calendar`）：月/周/日/列表、重复、拖动改期；智能体能读，它的新建、修改、删除要你批准 |
| 邮件 | 收发你现有的邮箱（`/mail`，IMAP 收信、SMTP 发信；QQ、163、126、Gmail、Outlook、iCloud 预设，可加多个账号，密码加密保存）：文件夹和未读数、搜索、阅读（HTML 邮件在沙箱里显示，远程图片默认屏蔽）、回复/转发、附件下载和存进“文件”、草稿、IDLE 实时收信和新邮件通知。智能体能搜索、阅读和起草，它每次替你发信都要你在审批卡片上批准 |
| 通知 | 实时 toast 和未读提醒（目标、追踪、Ideas 页面已在简化改版中去掉） |
| 文档 | PDF 上传、预览（签名 URL）、表单字段填写；document 任务从“文件”里的 PDF 开始 |
| 电脑 | Docker Linux 电脑，每个对话一台（智能体用命令行和桌面；页面可查看画面、命令记录，下载和上传文件） |
| 浏览器 | Playwright worker：截图控制台、点击、输入、读取正文、导入下载 |
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
                     muse_integ ── 工作区、文件/PDF、Docker 电脑、浏览器
                     muse_core ── 配置、Mnesia（记录 + CAS）、bitcask（事件/聊天/blob）、签名、加密
sidecar：sidecars/pdf（pdf-lib）、sidecars/mail（imapflow、mailparser、nodemailer）、sidecars/browser-worker（Playwright）
```

## 依赖

| 依赖 | 用途 |
|---|---|
| [beamai](https://github.com/TTalkPro/beamai)（core / llm / agent） | LLM 客户端与 ReAct Agent |
| [beamai_extra](https://github.com/TTalkPro/beamai_extra)（agui / tools / mcp） | AG-UI SSE 运行时 |
| [aihtml](https://github.com/DavidAlphaFox/aihtml) | 服务端渲染界面 |
| [bitcask](https://github.com/DavidAlphaFox/bitcask) | 事件日志、聊天历史（BM25）、大对象存储 |
| Mnesia（OTP 自带） | 事务记录与 CAS |

Erlang 依赖以 rebar3 git 依赖的形式通过 https 从 GitHub 获取，具体 commit 由 `rebar.lock` 锁定。

### 构建依赖

| 依赖 | 用途 |
|---|---|
| OTP 27+、rebar3 | 编译 Erlang/OTP 应用和 release |
| GNU make | 运行 `Makefile` 里的编译、测试和镜像目标 |
| cmake、C++23 编译器、ICU 开发包、zlib 开发包 | 构建 bitcask 的 C++ NIF |
| Node 22.6+、npm | 构建界面 CSS；安装和运行 PDF、邮件、浏览器 sidecar（旧版 Node 会被浏览器 worker 自动改用 `npx tsx`） |
| rsync | `scripts/deploy.sh` 安装 sidecar |
| Docker CLI 与 Docker Engine | 构建电脑镜像；`COMPUTER_ENABLED=true` 时由服务进程创建和管理电脑容器 |

浏览器 sidecar 首次安装还会通过 `npx playwright install chromium` 下载 Chromium；生产主机的操作系统需要提供 Playwright 要求的运行库。部署 `scripts/deploy.sh` 还会用 `openssl` 生成首次配置里的随机密钥。

## 快速开始

```sh
make compile      # 拉取依赖并编译
make css          # 生成界面样式（需要 Node，仅构建期）
make shell        # 开发 shell（节点名 muse@127.0.0.1）
make check        # compile + xref + dialyzer + eunit + ct
make acceptance   # 端到端：真实浏览器 worker + Docker 桌面电脑（需先 make sidecars、make computer-desktop-image）
```

**sample 模式**（默认，不需要任何 key）：“文件”里预置一份郊游同意书 PDF，模型是脚本化的（说“Complete the permission slip”即可走完填表演示）。

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
make sidecars        # PDF、邮件辅助程序与浏览器 worker（Node + Playwright；npm ci 按 package-lock 装固定版本）
make computer-image  # Docker Linux 电脑镜像
```

## 电脑 Docker 镜像

“电脑”不是托管服务，而是由本机 Docker daemon 启动的普通容器。镜像源码在 [`computer/`](computer/)，有两套本地构建目标：

| 变体 | 命令 | Dockerfile | 默认镜像 |
|---|---|---|---|
| 轻量版：命令行、Python 和文件桥 | `make computer-image` | [`computer/Dockerfile`](computer/Dockerfile) | `openmuse-computer:local` |
| 桌面版：轻量版 + X 桌面 | `make computer-desktop-image` | [`computer/Dockerfile.desktop`](computer/Dockerfile.desktop) | `openmuse-computer-desktop:local` |

镜像生成方式：

1. 以 `node:22.22.0-bookworm-slim` 为基础，安装 bash、Python 3、git、coreutils、CA 证书和 curl；桌面版另装 Xvfb、openbox、xterm、xdotool、scrot、mupdf、CJK 字体和 LibreOffice Writer/Calc。
2. 把 [`computer/files.py`](computer/files.py) 复制到 `/opt/openmuse/files.py`。这个脚本按 stdin/stdout 交换 JSON，是 Erlang 与容器之间的文件桥：读/写文件（≤10 MB）、导出 PDF、以及扫描回复产物用的 `changed_since`。桌面版还会复制 `desktop-init`、`gui`、`Xresources` 和 openbox 菜单。
3. 创建 `/workspace` 并声明为 Docker volume，工作目录设为 `/workspace`，容器进程使用 `1000:1000`。
4. 轻量版入口点是 `sleep infinity`，只保持容器运行；桌面版入口点是 `/opt/openmuse/desktop-init`，后台启动 Xvfb 和 openbox，然后等待 Xvfb；Xvfb 退出时容器退出。

构建后把镜像 tag 填到 `COMPUTER_IMAGE` 或 `COMPUTER_DESKTOP_IMAGE`；这两个值默认就是上表的本地 tag。镜像必须对 Muse 调用的 Docker daemon 可见；默认 daemon 由 `DOCKER_HOST` 或 `DOCKER_CONTEXT` 决定，这两个环境变量会传给 Docker CLI。每个对话或后台任务第一次需要电脑时，`muse_computer_pool` 会用 `docker container create` 创建容器，并给它一个独立的 `/workspace` volume。启动已停止容器时，如果 inspect 到镜像 id 与当前配置镜像的 id 不同，会删除旧容器并保留 volume 重建，因此升级镜像后不需要手工删除旧容器。容器生命周期和联网由 `COMPUTER_*` 配置控制。来源与改动记录见 [`computer/SOURCE.md`](computer/SOURCE.md)。

## 部署

生产部署推荐用 `scripts/deploy.sh`；目标机器要有构建依赖表中的 OTP、rebar3、make、C++ 构建工具、Node/npm、rsync、openssl。要在服务器上启用 Docker 电脑，先以生产用户构建电脑镜像并确认 `docker info` 可用；要启用浏览器，部署脚本会安装 sidecar，但 Chromium 的系统运行库仍需发行版预先安装。

`scripts/deploy.sh [APP_DIR]`（默认 `~/app/muse`）打一个自带 ERTS 的 prod release，装到 `APP_DIR`：`rel/` 是 release，`bin/muse` 是启停脚本，`sidecars/` 是 PDF 辅助程序、邮件辅助程序和浏览器 worker，`data/` 是数据目录。首次安装时按 `deploy/.env.example` 生成 `APP_DIR/.env`，并填入随机生成的密钥；之后重新部署不会覆盖 `.env` 和 `data/`。如果实例正在运行，脚本会先停掉，装好后再启动。

脚本执行的动作是：必要时执行 `make sidecars`；`rebar3 compile`；生成 CSS；`rebar3 as prod tar`；停掉正在运行的旧实例；解包新 release 到 `APP_DIR/rel`；同步 sidecar 和控制脚本；生成适配当前用户和路径的 systemd unit 到 `APP_DIR/systemd/`；首次安装时生成 `.env`。它不会构建 Docker 电脑镜像，也不会把服务注册进 systemd——这一步需要按下面手动执行。

```sh
./scripts/deploy.sh ~/app/muse
vi ~/app/muse/.env            # 填模型、PUBLIC_API_URL 等
~/app/muse/bin/muse start     # 启动 release，配置了 BROWSER_WORKER_URL 时同时启动浏览器 worker
~/app/muse/bin/muse status    # 也有 stop、restart、logs、remote

# 在生产服务器的源码目录里构建可选的 Docker 电脑镜像
(cd /path/to/beamai_muse && make computer-image)           # 轻量版
(cd /path/to/beamai_muse && make computer-desktop-image)   # 桌面版
```

如果用 systemd 托管，把部署脚本生成的 unit 复制到系统目录，然后只使用 systemd 控制：

```sh
sudo cp ~/app/muse/systemd/*.service /etc/systemd/system/
~/app/muse/bin/muse stop    # 如果刚才用 bin/muse 启动过
sudo systemctl daemon-reload
sudo systemctl enable --now muse.service

# 只有 `.env` 配置了 BROWSER_WORKER_URL 时才启用浏览器 worker
sudo systemctl enable --now muse-browser-worker.service
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
| `CHAT_MAX_STEPS` | 一轮回复最多的模型步数（默认 200）；回复在服务端一直跑到完成或用户停止，关掉页面也不中断 |
| `TASK_MAX_STEPS`、`TASK_RUN_MINUTES`、`TASK_AUTO_RUNS` | 后台任务：每轮最多的工具步数（默认 50）和时长（默认 10 分钟）；一轮没做完会自动开新一轮接着做，最多连续 `TASK_AUTO_RUNS` 轮（默认 10）才停下来问你 |
| `MODEL`、`<PROVIDER>_API_KEY` | 例如 `anthropic/claude-sonnet-4.5` 配 `ANTHROPIC_API_KEY`；`OPENAI_BASE_URL`、`ANTHROPIC_BASE_URL` 可改端点 |
| `WEB_SEARCH_ENABLED`、`PARALLEL_API_KEY` | 网页搜索 |
| `BROWSER_WORKER_URL`、`WORKER_TOKEN` | 浏览器 worker |
| `COMPUTER_ENABLED`、`COMPUTER_PROVIDER`、`COMPUTER_IMAGE`、`COMPUTER_DEPLOYMENT_ID` | Docker 电脑；`COMPUTER_PROVIDER` 只接受 `docker`（不支持 E2B 桌面）；部署 id 用于给容器命名，默认取 `PUBLIC_API_URL` |
| `COMPUTER_DESKTOP`、`COMPUTER_DESKTOP_IMAGE` | 设为 `true` 时使用桌面版（Xvfb + openbox，xterm、LibreOffice、mupdf；提供 `use_desktop`）；镜像默认 `openmuse-computer-desktop:local`（`make computer-desktop-image`） |
| `COMPUTER_NETWORK` | 电脑容器的网络：`bridge`（默认，Docker 默认网桥，可访问互联网，也能访问宿主机所在局域网）或 `none`（不联网，与 OpenMuse 相同）。改设置后，按旧设置创建的容器会被拒绝附着，删除该电脑即可重建 |
| `COMPUTER_MAX_RUNNING`、`COMPUTER_IDLE_MINUTES`、`COMPUTER_RETENTION_DAYS` | 电脑池（每个对话、每个后台任务各一台电脑）：每个部署同时运行的电脑上限（默认 4，满了先停最久未用的空闲电脑，全都在忙则报错）；空闲多少分钟后自动停止（默认 15，保留 /workspace）；停止且多少天未用的对话/任务电脑连同卷一起删除（默认 7，旧版本的默认电脑不删） |
| `JEV_MODE`、`JEV_MODEL`、`TYPESAFE_API_KEY`、`TYPESAFE_BASE_URL` | Jev：`off`、`sample` 或 `live` |
| `TASK_WORKER_ENABLED` | 是否在本节点运行任务 worker |
| `PDF_SIDECAR` | PDF sidecar 启动命令 |
| `MAIL_SIDECAR` | 邮件 sidecar 启动命令（默认 `node sidecars/mail/index.mjs`，imapflow + mailparser + nodemailer） |
| `MAIL_SYNC_DAYS`、`MAIL_SYNC_MAX`、`MAIL_POLL_MINUTES` | 内置邮件：每个文件夹本地保留最近多少天（默认 30）、最多多少封（默认 500）；轮询间隔（分钟，默认 5，收件箱另有 IMAP IDLE 实时唤醒）。附件大小沿用 `FILES_MAX_MB`；邮箱密码用 `TOKEN_ENCRYPTION_KEY` 加密，没有这个密钥就不能添加邮箱 |
| `FILES_MAX_MB` | “文件”里单个文件的大小上限（MB，默认 25，最大 1024）；可以存任意类型的文件，PDF 仍限 10 MB |

## 目录

| 路径 | 内容 |
|---|---|
| `apps/muse_core` | 配置、存储（Mnesia + bitcask）、安全原语 |
| `apps/muse_integ` | 工作区、文件/PDF、电脑、浏览器 |
| `apps/muse_engine` | 持久化任务引擎、审批、监控、目标、Ideas |
| `apps/muse_agent` | 模型、工具、聊天与任务 Agent、线程、搜索 |
| `apps/muse_web` | JSON API、AG-UI 端点、aihtml 界面 |
| `sidecars/` | 浏览器 worker（原样复用）、PDF、邮件（IMAP/SMTP） |
| `computer/` | Docker 电脑镜像（原样复用） |
