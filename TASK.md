# beamai_muse - Task List

> 目标：用 Erlang/OTP 全量重写 OpenMuse（TypeScript，`1ac68f3`）。
> 依赖：beamai（core/llm/agent）、beamai_extra（agui/tools/mcp）、aihtml（界面）、bitcask（存储）。
> 设计见 [designs/](designs/)，详细任务见 [tasks/](tasks/)，原项目行为规格见 [designs/ref/](designs/ref/)。

## 设计文档

| 文档 | 内容 |
|---|---|
| [designs/00-overview.md](designs/00-overview.md) | 范围对照、仓库结构、进程树、关键决策、配置差异、测试策略 |
| [designs/01-store.md](designs/01-store.md) | Mnesia（记录 + CAS）+ bitcask（事件、聊天历史、大对象） |
| [designs/02-engine.md](designs/02-engine.md) | 任务 worker/run、service、审批、维护、变更广播 |
| [designs/03-agent.md](designs/03-agent.md) | 模型、工具框架、聊天/任务 Agent、agui 代理、线程、搜索、Jev |
| [designs/04-integrations.md](designs/04-integrations.md) | 认证签名 vault、文件/PDF、Docker 电脑、浏览器、工作区（Google 已在 M9-4 删除） |
| [designs/05-web-ui.md](designs/05-web-ui.md) | JSON API、AG-UI 端点、aihtml 页面、推送中继、aihtml feedback |

## 里程碑

依赖顺序：M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8（M5 的 JSON API 和 M6 的 UI 可在 M4 完成后并行）。

| # | 里程碑 | 任务文件 | 状态 |
|---|---|---|---|
| M0 | 项目骨架与依赖（rebar git 依赖、5 个 app、门禁、sidecar 搬运） | [tasks/M0-bootstrap.md](tasks/M0-bootstrap.md) | ✅ 完成 |
| M1 | muse_core：工具函数、配置、Mnesia 存储、bitcask cask、认证/签名/vault/限流 | [tasks/M1-core.md](tasks/M1-core.md) | ✅ 完成 |
| M2 | muse_integ：工作区、文件、PDF sidecar、Docker 电脑、浏览器客户端、Google | [tasks/M2-integ.md](tasks/M2-integ.md) | ✅ 完成 |
| M3 | muse_engine：worker/run、AgentService、审批、文档流程、监控、目标、Ideas、维护 | [tasks/M3-engine.md](tasks/M3-engine.md) | ✅ 完成 |
| M4 | muse_agent：模型、工具框架、电脑工具与搜索、任务/聊天 Agent、agui 代理、线程、Jev | [tasks/M4-agent.md](tasks/M4-agent.md) | ✅ 完成（agui 代理移至 M5） |
| M5 | muse_web：中间件、JSON API、AG-UI 端点 | [tasks/M5-api.md](tasks/M5-api.md) | ✅ 完成 |
| M6 | aihtml 界面（含 aihtml feedback） | [tasks/M6-ui.md](tasks/M6-ui.md) | ✅ 完成（两项真实环境验收已由 `make acceptance` 覆盖） |
| M7 | 外部 SDK：Jev live（E2B 桌面已取消）、Docker 桌面变体 | [tasks/M7-external.md](tasks/M7-external.md) | ✅ 完成（Jev live 已在 `decision-model-preview` 上验收；Docker 桌面变体在真实 Docker 上通过） |
| M8 | 端到端验收、门禁、文档、回收临时方案 | [tasks/M8-acceptance.md](tasks/M8-acceptance.md) | 🔄 进行中（M8-2、M8-3 完成；M8-4 完成；M8-1 只差真实模型 key 那项） |
| M9 | 多会话工作台与电脑池（Docker 管理、联网、会话并发与状态、设计稿侧栏）；去掉 Google、邮件和日历（M9-4） | [tasks/M9-workspace.md](tasks/M9-workspace.md) | ✅ 完成（M9-12 到 M9-15 收尾完成） |
| M10 | 实时画面：浏览器控制台和桌面电脑改用 VNC（容器内 x11vnc inetd + WebSocket 中转 + noVNC） | [tasks/M10-live-view.md](tasks/M10-live-view.md) | ✅ 完成（已部署） |
| M11 | 浏览器镜像改用 Debian 的 Chromium（apt），扩展适配 | [tasks/M11-chromium.md](tasks/M11-chromium.md) | ✅ 完成（已部署） |
| M12 | 浏览器跑在对话的桌面电脑里；页面展示完成后再注入提取器 | [tasks/M12-browser-in-desktop.md](tasks/M12-browser-in-desktop.md) | ✅ 完成（已部署） |

## 外部 feedback

| 目标仓库 | 内容 | 状态 |
|---|---|---|
| aihtml | 事件坐标/修饰键（🔴）、keydown 丢键（🔴）、端点认证钩子与 token 过期（🟡）、text op（🟡）、动作设置 cookie（🟢）、poll 属性（🟢）（M6-0） | ✅ aihtml `ccb8bcf` 已全部实现，muse 已改用 |
| beamai_extra | MCP HTTP 客户端 recv(0) 取消请求崩溃、adapter 的 schema 和返回值、tls_opts 不可配置（M4-3） | ✅ 2.0.1 已修 |
| beamai_extra | MCP 客户端吞错误、不回复在途调用；gun owner 在 recv 等待中看不见调用方退出；`http_error` 丢响应体（M8-4） | ✅ beamai_extra `799383e`（2.1.0）已修复，muse 已升级并改用 `beamai_mcp_client` |
| beamai | 同一回合"文本 + 工具调用"的文本没有写进历史；Anthropic 适配器在回放时同样丢掉文本（M6-2） | ✅ beamai `805b0ac`（2.0.1）已修复，muse 已升级依赖并补了测试 |
| beamai | 工具结果只能是文本，带不了图片（M7-1 发现） | ✅ beamai `4d6181c`（2.0.2）已支持多模态工具结果，muse 已升级依赖，`use_desktop` 把截图作为图片交给模型 |

## 门禁基线

| 范围 | 当前结果 |
|---|---|
| compile / xref / dialyzer | 通过 / 0 / 0（M7、M8-2 之后，`scripts/check.sh`） |
| eunit / ct | 978 tests / 173 passed + 31 env-gated（Docker、真实浏览器、在线搜索）；`MUSE_TEST_DOCKER=1` 时真实 Docker 18/18 通过（桌面 8 个，轻量 10 个）；TypeSafe 冒烟测试已在兼容端点上通过；`make acceptance`（真实浏览器 worker 加 Docker 桌面）20/20 通过 |
| release 冒烟 | sample 模式：登录 → `/api/agui/run`（SSE）→ 后台 worker 把权限单任务推进到 waiting_input；表单登录后 11 个页面均返回 200，muse.css 和 aihtml 运行时可访问（M6） |
