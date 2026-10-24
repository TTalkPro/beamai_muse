# M5 muse_web：HTTP 中间件、JSON API、AG-UI 挂载

> 设计：[05-web-ui.md](../designs/05-web-ui.md) §1–§2
> 规格：I§2、E§12
> 状态：✅ 完成（2026-10-23）。框架、核心/agent/线程路由由主线实现；集成路由（文件、Google、浏览器、电脑）和 AG-UI 端点（含 agui 代理）由并行子 agent 实现。

## M5-1 cowboy 与中间件
- [x] `muse_web_sup` 启动监听 `muse_http`（HOST/PORT）。
- [x] `muse_mw_*` 中间件按顺序实现：origin、CORS 与 preflight、请求体上限 12 MiB、限流、免认证路由、认证（Bearer、签名 URL、cookie），状态码和文案对齐 I§2.2。
- [x] 安全响应头。
- [x] `muse_http`：JSON 回复、错误映射（I§2.3），502 兜底时只记录错误类别。

验收：移植 `api.test.ts` 中中间件相关用例（origin 403、preflight 204、413、429、401）。

## M5-2 业务路由
- [x] I§2.6 #1–#31：health、session（含登录限流）、google callback、workspace、calendars、events、mail thread、actions、decide、drafts、main-thread、conversation、files（multipart 上传、content、fill）、import-attachment、google connect/disconnect、browsers 系列（含签名 preview 和 console）。
- [x] `/api/computer/*`（I§6.9）。
- [x] `/api/agent/*`（E§12.1）。
- [x] 新增：`/api/threads*`。

验收：ct 中每条路由至少有一个成功用例和一个错误用例，状态码和 JSON 形态与规格一致。

## M5-3 AG-UI 端点（含从 M4-6 移来的 agui 代理后端）
- [x] `muse_agui_handler`：校验身份后把 owner 注入 state，再委托给 `beamai_agui_cowboy_handler`；挂载 `/api/agui/agent/:agent/run`、`/api/agui/threads/...`、info；未配置模型时返回 503（文案见 I§2.6 #32）；agui backend 时转到代理。
- [x] `on_concurrent => reject` 时返回 409。
- [x] `muse_agui_proxy`（原 M4-6）：`AGENT_BACKEND=agui` 时用 gun 把 RunAgentInput 转发到 AGENT_URL（Bearer AGENT_TOKEN），解析 SSE 并转发事件，支持取消；同时向 UI 中继暴露事件订阅接口。验收：用 beamai_agui 起一个上游 AG-UI 服务，经代理跑通一轮对话。
- [x] 用 `muse_chat:start_turn/4` 和 `muse_chat_agent:factory/1` 启动 run（owner 走闭包）；Jev 的 `prepare_input` 失败时，按原项目只发 RUN_ERROR，不发 RUN_STARTED。

验收：用 gun 作为 SSE 客户端跑一轮 sample 对话，事件序列完整；断线后能用 Last-Event-ID 续传。

## 验收记录（2026-10-23）

- 结构：`muse_mw` 是 cowboy 中间件，作用于所有路径（origin、安全头、CORS 预检、请求体上限、`/api/*` 限流）。`muse_api` 负责 `/api/[...]` 的认证（Bearer，或可签名路径上的签名），然后依次交给五个路由模块：`muse_api_core`、`muse_api_agent`、`muse_api_threads`、`muse_api_integ`、`muse_api_computer`。`/api/agui/[...]` 由 `muse_agui_handler` 处理。
- 套件：
  - `muse_api_SUITE`（8 个用例）：中间件（403、204 预检、413、400、安全头）、认证与 404、工作区路由、审批与草稿、会话与线程、agent 路由全集、登录限流（按 IP 每分钟 30 次）、live 模式访问密钥；
  - `muse_api_integ_SUITE`（7 个用例）：multipart 上传、Bearer 和签名两种方式读文件（过期 401、篡改 403、跨文件 403）、填表、Google 连接与断开、浏览器全部路由（对接假 worker）、电脑路由（meck，校验取消 pid 就是请求进程）；
  - `muse_agui_SUITE`（13 个用例）：SSE 流、401/503/400/409、停止、`Last-Event-ID` 续传、跨 owner 访问 404、Jev 错误只发 RUN_ERROR、agui 代理的转发（CRLF 和分片帧）、上游 500、上游不可达、客户端断开时取消上游请求。

- 门禁：xref 0、dialyzer 0；eunit 864 个用例，0 失败；ct 73 个通过，14 个需环境变量开启。
- release 冒烟（daemon，PORT=18787）：`/api/health` → `POST /api/session` → `POST /api/agui/run` 的事件序列为 RUN_STARTED … TEXT_MESSAGE_* → TOOL_CALL_*（delegate_task）→ TOOL_CALL_RESULT → RUN_FINISHED；随后 `/api/agent` 显示任务由 queued 变为 waiting_input，并给出 PDF 字段提问（worker 与 PDF sidecar 都在 release 中正常工作）。

## 实现中的发现与偏差

1. **应用停不下来（两处）**：
   - 用 `cowboy:start_clear/3` 启动的监听器挂在 ranch_sup 下面，会忽略我们监督者的 shutdown，于是 `application:stop(muse_web)` 永远挂住。现在改为 `ranch:child_spec/5`，把监听器嵌进 `muse_web_sup`；
   - `muse_core_app:stop/1` 在应用控制器的 stop 流程里又去 `application:stop(mnesia)`，造成死锁。现在 stop/1 不再停 mnesia，release 随节点一起停，测试环境在停完各应用后再单独停 mnesia。
2. **测试数据目录要带 OS pid**：`erlang:unique_integer` 在每个 VM 里都从小数字开始，并行跑的 VM 会抢同一个 bitcask 写锁。
3. **线程归属（AG-UI）**：外部客户端自建的 threadId 在第一次 run 时以全局 CAS 登记到 `system/agui-threads`；别的 owner 访问时一律返回 404。
4. **Jev 前置处理失败时**，`/run` 返回 200 SSE，只带一个 RUN_ERROR 帧，与原项目一致。线程被占用时返回 409 `{"error":"agent_thread_locked"}`，对应原项目 CopilotKit 客户端识别的锁错误。
5. **未实现**：`GET /api/agui/info` 和线程列表（目前 UI 走 `/api/threads`），如果需要兼容 CopilotKit 风格的客户端再补。
6. **E2B 桌面路由**：不支持 E2B（2026-10-23 决定），`/api/computer/desktop*` 不存在，返回 404。
7. **原项目的登录限流是全局计数**，这里按客户端 IP 计数（与 04-integrations §1 一致）。
