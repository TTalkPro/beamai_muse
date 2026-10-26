# M4 muse_agent：模型、工具、聊天与任务 Agent、线程、搜索、Jev

> 设计：[03-agent.md](../designs/03-agent.md)
> 规格：E§7–§11，ref digest §2–§6
> 状态：✅ 完成（2026-10-22）。M4-3（电脑工具、MCP 客户端与搜索）和 M4-8（Jev）由并行子 agent 实现，其余由主线实现并整合。M4-6（agui 代理后端）挪到 M5 实现：它是一个 HTTP 端点，放在 muse_web 里更自然。

## M4-1 模型与测试 provider
- [x] `muse_model`：MODEL 解析（错误文案见 E§9.1）、provider 映射表（03-agent §1）、`configured/0`、HTTP 池调优、重试次数。
- [x] `muse_script_llm`：`{custom, Mod}` 脚本化 provider，供测试使用（参照远程 `/tmp/muse_scratch/script_llm.erl`）。支持按轮次返回文本或工具调用，并能流式输出 token。
- [x] 确认 Gemini 的处理方式。如果需要，按 feedback 约定给 beamai 提 provider 需求。

验收：eunit 覆盖模型字符串解析的全部分支，包括 `OPENAI_BASE_URL` 提示。

## M4-2 工具框架
- [x] `muse_schema`：DSL 生成 beamai 参数并做校验和规范化；把 JSON Schema 转成参数 DSL（供 MCP 使用）。
- [x] `muse_tool:define/5`：统一包装（异常转 `{error,...}`、保证返回形状、结果截断、serial、`link(RunPid)` 选项）。
- [x] `muse_halt_filter`：`around_step` 停止过滤器（ref digest §4 方案 2）。

验收：eunit；用脚本化 LLM 验证"工具写 halt 后循环结束、历史合法"。

## M4-3 电脑工具与搜索
- [x] `muse_computer_tools`：E§8.1 全部工具，描述和提示词逐字移植，scope 规则一致，返回 `{error: Msg}` 而不抛异常；`use_desktop` 留到 M7。
- [x] `muse_mcp_http`：基于 gun 的 streamable-HTTP MCP 客户端，支持 initialize、initialized、tools/list、tools/call，处理 SSE 和 JSON 两种响应以及 mcp-session-id。（M8-4 已删除，改用 beamai_mcp_client。）
- [x] `muse_search`：I§8 的会话缓存、超时、响应大小上限、结果映射；`search_web` 工具的描述逐字移植（E§8.2）。
- [x] 给 beamai_extra 提交 feedback：MCP 客户端的 recv(0) 取消请求和 tls_opts 缺失问题（按其 `feedbacks/` 约定）。

验收：
- ct 用假 MCP 服务器（cowboy）测试 SSE 和 JSON 两种响应；
- 设置 `PARALLEL_API_KEY` 时做一次真实搜索冒烟测试；
- 用 deepwiki 测试 list tools。

## M4-4 任务模型 Agent
- [x] `muse_task_model`（`muse_task_runner`）：E§7 的第 1–11 步，全部任务工具，`cached/3`，outcome 用 halt 控制，每次调用前 guard 并写 step 事件，5 分钟超时，系统提示词逐字移植，无历史，统计 usage。
- [x] 在 `muse_agent_app` 启动时注入 task_runner。

验收（ct，脚本化 LLM）：
- set_plan → finish_task 成功；
- ask_user 后进入 waiting_input，回答后续跑；
- prepare_email 后进入 waiting_approval，批准后续跑且不重复准备；
- 中断后重放时，cached 结果不重复执行；
- 超时后任务 failed。

## M4-5 聊天 Agent（sample / model）
- [x] `muse_chat_agent:factory/2`：
  - 从 initial_state 读取 owner；
  - 三种 backend 分支；
  - 聊天工具集（E§9.5，描述逐字移植）；
  - 系统提示词按原样拼接，包括缺空格的那个细节（E§13 有记录）；
  - 步数 6 或 16；
  - 只放行前端工具 `open_workspace`；
  - 幂等键（E§9.3）。
- [x] `muse_sample_llm`：E§9.4 的正则顺序和文案（弯引号逐字）。
- [x] `muse_agui_plugin`：event_transform 实现 textOnlyToolResult 和步数超限说明；input_transform 实现 owner 覆盖和 Jev 前缀。
- [x] 注册到 `beamai_agui_registry`，id 为 `default`。memory 使用 `muse_chat_log`。

验收（ct）：
- sample 的四个分支事件序列；
- model 模式在脚本化 LLM 下的事件序列；
- 同一 user message 重放时不会重复建任务；
- 步数超限时出现说明文本；
- stop 后长工具也被终止。

## M4-6 agui 代理后端
- [ ] `muse_agui_proxy`：用 gun 转发 RunAgentInput 到 AGENT_URL（Bearer），解析 SSE 并转发事件；支持取消；同时向 UI 中继暴露事件订阅接口。→ **移到 M5-3**

验收：用 beamai_agui 自己起一个上游 AG-UI 服务，经代理跑通一轮对话。（随 M5-3 验收）

## M4-7 线程
- [x] `muse_threads`：main_thread、list、create_side、rename、archive、restore、messages、search（BM25）、pending 队列（05-web-ui §4）。

验收：ct 覆盖线程生命周期，以及 409 busy 后消息重新入队。

## M4-8 Jev（sample）
- [x] `muse_jev`：记录、`present_choices` 工具、createPanel 算法（E§10.4）、select、expire_if_unchanged、sample 排序适配器；在 input_transform 中处理 choice 前缀，错误事件的序列与原项目一致（不发 RUN_STARTED）。

验收：移植原 `jev*.test.ts` 中 sample 模式的用例。

## 验收记录（2026-10-22）

- 门禁：xref 0、dialyzer 0；eunit 共 864 个用例，0 失败；ct 45 个通过，另有 14 个需环境变量开启（Docker、真实浏览器、在线搜索）。
- `muse_task_model_SUITE`（10 个用例）：计划后完成、提问与回答（用户消息里拼接 `Additional answer`）、准备邮件 → 审批 → 恢复且不重复准备、`cached` 操作重放不产生第二份文件、产生 outcome 后拒绝后续工具、工具错误作为数据返回并写 `<name> failed` 事件、模型请求失败、5 分钟超时（测试中配置成 300 ms）、无模型时等待、系统提示词的结构（含记忆的 JSON 上下文）。
- `muse_chat_SUITE`（10 个用例），通过真实的 beamai_agui 会话：
  - sample 模式：权限单（回复文本在 `delegate_task` 之前，任务 id 为 `sha256("task:"+requestKey)`）、同一条消息重放幂等、hello 和日历分支、历史写入 bitcask 并可用 BM25 搜到；
  - model 模式（脚本化 provider）：读邮件、6 步上限后输出原项目的说明文字、前端工具只放行 `open_workspace`、停止回复（RUN_FINISHED 的 status 为 cancelled）、同一线程一次只跑一轮（第二轮返回 busy）；
  - 线程：主会话与旁支会话、重命名、归档和恢复、主会话不可归档、待发送队列。
- 子 agent 交付：电脑工具 19 个用例（说明文字与 TS 对照 sha256）；MCP 客户端与搜索 17 个用例，并对 deepwiki 和 Parallel 做了在线冒烟（不带 key 的真实搜索返回 10 条结果）；Jev 30 个用例（含 Node 对照向量）。
- 已向 beamai_extra 提交 feedback：`/home/david/workspace/beamai_extra/feedbacks/2026-10-22-mcp-http-client-remote-servers.md`，并在 README 索引中加了一行（未提交 git）。

## 实现中的发现与偏差

1. **聊天的 factory 是闭包**：owner 来自服务端认证，放在闭包里，不经过客户端可控的 RunAgentInput。M5 的 HTTP 端点也照此处理。
2. **步数上限**：用 `around_step` 过滤器在第 6 步时把循环结束掉，合成的最终答案就是原项目的提示文案，再由 event_transform 在 RUN_FINISHED 之前补发 TEXT_MESSAGE 事件。
3. **sample 模式用脚本化 provider 实现**：回复文本和 `delegate_task` 调用放在同一次响应里，事件顺序与原项目一致（先文本、后工具调用）；它和 model 模式走同一条 AG-UI 管线。
4. **Jev 的前置处理放在 `muse_chat:prepare_input/2`**：选项消息转成续写提示，普通的用户轮次让旧面板失效。失败时返回 `{error, Msg}`，由调用方（UI 或 HTTP 端点）决定怎么呈现；原项目是发一个不带 RUN_STARTED 的 RUN_ERROR。Jev 的 live 适配器暂时是存根，留到 M7。
5. **任务模型的运行时状态**（task、outcome、operations、text）放在执行进程持有的 ETS 表里。工具在 beamai 的独立进程中运行，也能读写这张表；这些进程 link 到 agent 子进程，任务被中止时会一起结束。
6. **搜索端点与原项目一致**：`search.parallel.ai/mcp`，无需 key。设计文档里原先写的 `search-mcp.parallel.ai` 是错的，已修正。
7. **Gemini 不支持**：beamai_llm 没有对应的 provider，配置 `google/*` 会报 unknown provider，错误信息里列出了实际支持的 provider。
8. **参数校验先于 `before()`**：muse_tool 先校验参数再调用处理函数，所以参数非法时直接返回校验错误。原项目是先执行 before 再解析参数，两者只有报错的先后不同。
