# beamai_muse 总体设计

> 目标：用 Erlang/OTP 全量重写 [OpenMuse](../../openmuse)（TypeScript，`1ac68f3`），
> 依赖 beamai（core / llm / agent）和 beamai_extra（agui / tools / mcp），前端用 aihtml。
> 原项目的行为规格见 `designs/ref/`：
>
> | 文件 | 内容 |
> |---|---|
> | [ref/openmuse-engine-spec.md](ref/openmuse-engine-spec.md) | 领域记录、任务引擎、审批、聊天 Agent、全部工具与系统提示词（原文） |
> | [ref/openmuse-integrations-spec.md](ref/openmuse-integrations-spec.md) | 配置、HTTP 路由、认证签名、文件/PDF、Docker 电脑、浏览器 worker、搜索、Google、vault |
> | [ref/beamai-api-digest.md](ref/beamai-api-digest.md) | beamai / beamai_extra 的实际 API（经远程运行验证）与坑 |
> | [ref/aihtml-digest.md](ref/aihtml-digest.md) | aihtml 的实际 API、推送机制、组件清单与缺口 |
>
> 本目录下的设计文档只写**Erlang 侧的决策与结构**；行为细节（字段、常量、文案、状态机）以 ref 规格为准，
> 文档中以 `E§x.y`（engine spec）/ `I§x.y`（integrations spec）引用。

## 1. 范围

全量对齐原项目的服务端能力，界面换成 aihtml 服务端渲染：

| 原模块 | beamai_muse 对应 | 说明 |
|---|---|---|
| `apps/server` Hono API | `muse_web`（cowboy）JSON API `/api/*` | 路由、状态码、错误映射对齐 I§2 |
| CopilotKit Runtime + `ConversationAgent` | `muse_agent` + beamai_agui | AG-UI SSE 端点保留在 `/api/agui/*`；内置 UI 走服务端中继 |
| CopilotKit Intelligence（Rich Threads） | `muse_threads`（自建） | 主会话、旁支会话、重命名、归档、恢复、回放，存 Mnesia |
| TanStack AI（OpenAI/Anthropic/Gemini） | beamai_llm | `MODEL=provider/model`；provider 集合扩展为 beamai 支持的全部（Gemini 无 provider，见 §6） |
| 任务引擎 `engine/*` | `muse_engine` | 租约、心跳、CAS、检查点、操作缓存、维护任务 |
| 审批 `actions.ts` | `muse_actions` | hash 绑定、30 分钟过期、outcome_unknown 不重试 |
| PGlite/Postgres `records` 表 | Mnesia `muse_record` 表 + bitcask | Mnesia 放需要 CAS 的记录（语义对齐 jsonb 的 `@>` 和 `||`）；bitcask 放运行事件、聊天历史（BM25）和大对象 |
| Docker Linux 电脑 | `muse_computer` | 直接复用原 `apps/computer`（Dockerfile + files.py），Erlang 用 `open_port` 参数数组调用 docker |
| E2B Desktop | 不实现 | 用户决定不支持（2026-10-23），只保留 Docker 电脑 |
| 浏览器 worker（Playwright） | **保留原 Node 服务**（拷贝到 `sidecars/browser-worker`） | Erlang 无 Playwright；`muse_browser` 通过 HTTP 调用 |
| pdf-lib 表单填写 | Node sidecar `sidecars/pdf`（端口协议） | 读字段 / 填表 / 清除 JS 动作 / 生成示例 PDF |
| Parallel 搜索 MCP | `beamai_mcp_client`（beamai_extra 2.1.0，streamable HTTP） | 2.0.1 修好连通性，2.1.0 修好错误透出（见 ref digest §6） |
| Google OAuth + Gmail/Calendar | 已删除（M9-4） | 用户决定（2026-10-26）去掉 Google 和现有邮件、日历功能，以后内置日程和邮件收发；审批机制保留，操作类型可插拔（02-engine §5） |
| Jev 选项面板（TypeSafe AI） | `muse_jev` | sample 模式原生实现；live 模式调用 TypeSafe HTTP API（M7） |
| OpenBot 适配器 | 不实现 | 原项目默认关闭；保留为非目标 |
| Expo 前端 | aihtml 页面（`muse_ui_*`） | 见 [05-web-ui.md](05-web-ui.md) |
| 遥测（PostHog） | 不实现 | 非目标 |

非目标：OpenBot、PostHog 遥测、CopilotKit 协议兼容（原 Expo 客户端不能直接接入；`/api/*` JSON 与 AG-UI SSE 尽量对齐，便于以后适配）。

## 2. 仓库结构（rebar3 umbrella）

```
beamai_muse/
  rebar.config / rebar.lock          依赖全部是 https 的 git/hex 依赖，rebar.lock 锁定 commit
  config/sys.config.src vm.args.src  release 配置（环境变量 → app env）
  apps/
    muse_core/      配置、Mnesia 存储与 CAS、bitcask cask（events/chat/blobs）、时间/JSON/ID 工具、认证会话、URL 签名、vault、校验
    muse_engine/    任务 worker、AgentService、审批、目标/里程碑、监控、Ideas、财务、页面对比、通知、记忆、身份
    muse_agent/     LLM 配置、工具框架（参数 DSL 转换）、聊天 Agent、任务模型 Agent、sample Agent、agui 代理、线程、Jev、搜索
    muse_integ/     文件/PDF、Docker 电脑、浏览器客户端、工作区（sample 模式预置的 PDF）
    muse_web/       cowboy 监听、中间件、/api/* JSON 路由、AG-UI 挂载、aihtml 页面与动作、推送中继
  sidecars/
    browser-worker/ 原 apps/worker 拷贝（Node + Playwright），接口不变
    pdf/            pdf-lib 端口程序（stdin/stdout 帧协议）
  computer/         原 apps/computer（Dockerfile + files.py）
  assets/muse.css   Tailwind v4 入口（引入 aihtml.css）；构建产物 apps/muse_web/priv/static/css
  designs/ tasks/ TASK.md
```

依赖方向：`muse_web → muse_agent → muse_engine → muse_integ → muse_core`。引擎需要调用 Agent（模型任务）时，
通过 `muse_engine` 定义的回调 behaviour（`muse_task_runner`）在启动时注入，避免环依赖。

## 3. 进程树

```
muse_core_sup
  muse_store          Mnesia 表的建立/迁移（启动时一次）；CAS 在事务中执行，不经单进程
  muse_cask_sup       每个 bitcask 目录一个 muse_cask（单写者，持有句柄；读走 persistent_term 共享句柄）
  muse_rate_limit     ETS 固定窗口计数（I§2.4），定时清理
  muse_signing        启动时加载/生成 session-signing-key（I§3.2）
muse_integ_sup
  muse_pdf_port       pdf sidecar 端口池（poolboy 式的简单池，2 个）
  muse_mail_client    邮件 sidecar（IMAP/SMTP）的端口，一个进程多路复用请求（M9-8）
  muse_computer_sup   每 owner 一个 muse_computer_owner（串行化电脑操作，持有租约）
  muse_browser        浏览器 worker 客户端（无状态函数 + 可达性缓存）
muse_engine_sup
  muse_task_worker    gen_server：每秒 tick，至多 3 个并发 run；run 为受监控的独立进程
  muse_task_run_sup   simple_one_for_one：每个 run 一个进程（含心跳定时器）
  muse_maintainer     gen_server：每 60 秒 maintain()
  muse_mail_sup       simple_one_for_one：每个邮箱账号一个 muse_mail_sync（同步、IDLE、退避，M9-8）
muse_agent_sup
  muse_threads        线程元数据（Rich Threads）
  muse_chat_relay_sup 每个活跃 UI 聊天 run 一个中继进程：订阅 beamai_agui 会话 → aihtml_push
  muse_search         MCP 会话缓存（每 conversation 一个 sessionId，I§8）
muse_web_sup
  cowboy listener muse_http
```

## 4. 关键决策

1. **数据形态 = JSON 形态**：所有记录都是二进制键的 map（`#{<<"id">> => ..}`），与原 jsonb 文档一致，API 直接 `json:encode`。
   时间戳用 ISO-8601 毫秒 `Z` 字符串（`muse_time:now_iso/0`），与原项目一致；内部比较用 `muse_time:to_ms/1`。
2. **存储由 Mnesia 和 bitcask 组成**，见 [01-store.md](01-store.md)。
   - Mnesia（disc_copies，单表 `muse_record`，主键 `{Owner, Kind, Id}`）：放需要 CAS 和事务的记录。CAS 在 `mnesia:transaction` 内实现 Postgres 的 `@>` / `||` 语义。
   - bitcask（`/home/david/workspace/bitcask`）：放只追加、体积大或需要检索的数据，包括 run-events、聊天历史（BM25 搜索）、PDF 和截图等 blob。bitcask 不提供 CAS 和隔离，所以只用于不需要条件写的数据。
   - 不引入 Postgres。worker 并发由同一 BEAM 节点内的多个 run 进程承担；扩展到多节点时，租约机制在 Mnesia 复制下照样成立，但 bitcask 是单写者，需要按节点分目录。
3. **单用户**：owner 固定 `<<"local-user">>`（I§3），保留 owner 维度以便将来多租户。
4. **Agent 内核统一**：聊天与后台任务都用 `beamai_agent`，差别只在工具集、提示词、步数上限（6/16）和停止条件。
   - 停止循环：工具写 state 标志 `halt`，`around_step` 过滤器把 status 改为 `final`（ref digest §4 方案 2，已验证）。
   - 取消：beamai 无 cancel API，run 进程 `exit(kill)`；长工具（电脑命令、浏览、搜索）在开始时 `link` 到 run 进程（通过 `initial_state` 传 pid），保证取消时一起结束。
   - 工具串行化：任务模型的工具都设 `serial => true`（E§7 要求按序 checkpoint）。
5. **聊天传输**：AG-UI 会话用 beamai_agui（每 threadId 一个 session 进程，run 不随 HTTP 断开而结束）。
   - 外部 AG-UI 客户端：`/api/agui/agent/default/run`（Bearer 认证在前置中间件里校验，并把 owner 注入 RuntimeCfg）。
   - 内置 aihtml UI：动作里 `beamai_agui_session:start_run/4` 启动，再起一个中继进程 `subscribe` 事件，批量（每 80ms）转成 `aihtml_push` DOM 操作，推给 `{thread, Owner, ThreadId}` 主题。
6. **外部能力用 sidecar**：Playwright、pdf-lib 没有 Erlang 等价物；sidecar 只做无状态的薄适配，安全约束（SSRF、路径、大小限制）仍在 Erlang 侧再校验一次。
7. **安全对齐**（ref I§3、08-auth-and-security）：常数时间比较（`crypto:hash_equals/2`）、token 只存 SHA-256、HMAC 签名 URL 15 分钟、
   origin 白名单、12 MiB 请求体、限流、错误不外泄、docker 参数数组不经 shell、审批 hash 绑定。

## 5. 配置

环境变量名与默认值沿用原项目（I§1.2），由 `muse_config:load/0` 在 `muse_core` 启动时读取并校验，错误文案逐字对齐，
校验顺序对齐。差异：

| 变量 | 处理 |
|---|---|
| `CPK_INTELLIGENCE_API_KEY` | 不再需要（线程自建持久化）。 |
| `DATABASE_URL` | 忽略；改为 `DATA_DIR/mnesia` 和 `DATA_DIR/bitcask/*`。 |
| `MODEL` | `provider/model`；provider 增加 beamai 支持的 `zhipu`、`deepseek`、`moonshot`、`openrouter`、`ollama` 等，对应 `<PROVIDER>_API_KEY`。 |
| 新增 `MUSE_UI_SECRET` | aihtml 的 `secret`（≥32 字节）；live 模式必填，sample 模式缺省时随机生成并写入 `DATA_DIR`。 |
| 新增 `PDF_SIDECAR` | PDF sidecar 启动命令（默认 `node sidecars/pdf/index.mjs`）。 |
| 新增 `MAIL_SIDECAR`、`MAIL_SYNC_DAYS`、`MAIL_SYNC_MAX`、`MAIL_POLL_MINUTES` | 内置邮件（M9-8）：邮件 sidecar 启动命令（默认 `node sidecars/mail/index.mjs`）；每个文件夹保留的天数（30）和封数（500）；轮询分钟数（5）。邮箱密码用 `TOKEN_ENCRYPTION_KEY` 加密。 |
| `COMPUTER_PROVIDER` | 只接受 `docker`；不支持 E2B 桌面，`E2B_API_KEY`、`COMPUTER_E2B_TEMPLATE` 不读取（`COMPUTER_DEPLOYMENT_ID` 仍用于给 Docker 容器命名）。 |

## 6. 与原项目的已知差异

- 没有 Gemini provider（beamai_llm 不支持）：`google/*` 模型报 "Unknown provider"。是否给 beamai_llm 提 feedback，到 M4 再定。
- Rich Threads 自建：原来依赖 CopilotKit Intelligence 的线程锁（`agent_thread_locked`），在这里由 beamai_agui 的 `on_concurrent => reject`（409）承担。
- 原 CAS 对数组按"包含"判断，这里沿用同样的语义（01-store §2），并在 publishOutcome 追加里程碑处加注释。
- 前端交互不同：没有离线草稿队列等移动端特性；Activity、审批等改成服务端推送实时更新。
- 没有 Google、邮件和日历（M9-4）：相关路由、工具、sample 夹具都删掉了；document 任务从“文件”里的 PDF 开始。详见 [docs/DIFFERENCES.md](../docs/DIFFERENCES.md)。

## 7. 测试策略

- **eunit**：纯函数（CAS 语义、页面对比、财务 CSV、vault、签名、校验、JSON Schema → 参数 DSL、模型字符串解析）。原项目 `tests/*.test.ts` 中可移植的用例逐条移植（ref I 开头列出了清单）。
- **common_test**：
  - 引擎套件：用脚本化 LLM（`muse_script_llm`，`{custom, Mod}` provider，参照远程 `/tmp/muse_scratch/script_llm.erl`）跑完整的任务生命周期，包括租约过期接管、暂停/恢复/取消/重试、审批唤醒和操作缓存重放。
  - HTTP 套件：用 gun 调 `/api/*`，验证状态码与 JSON 形态。
  - 电脑套件：需要 docker 和镜像，加 `computer` 标签，按环境变量开启。
  - 浏览器套件：需要 sidecar 和 chromium，按环境变量开启。
- **UI 冒烟**：渲染每个页面，HTTP 200，并检查关键 id 存在；动作端点用 aihtml 的签名 token 调用。
- 门禁：`rebar3 compile`（warnings_as_errors）、`xref`、`dialyzer`、`eunit`、`ct`。
