# 03 Agent（muse_agent）

对应原 `engine/{conversation,model,tanstack-agent}.ts`、`agent.ts`、`computer-tools.ts`、`search.ts`、`jev/*` 和 `demo/*`。行为规格见 E§7–§11。

## 1. 模型配置（`muse_model`）

- 解析 `MODEL`：支持 `provider/model` 和 `provider:model` 两种写法，错误文案对齐 E§9.1。provider 的映射如下：

  | MODEL provider | beamai provider | key 环境变量 | 备注 |
  |---|---|---|---|
  | `openai` | `openai_responses`；`OPENAI_CHAT_COMPLETIONS=true` 时用 `openai` | `OPENAI_API_KEY` | 走 `OPENAI_BASE_URL`；用 chat completions 时去掉默认的 temperature 和 max_tokens（ref digest §2 的坑） |
  | `anthropic` | `anthropic` | `ANTHROPIC_API_KEY` | `ANTHROPIC_BASE_URL` 末尾的 `/v1` 要去掉 |
  | `zhipu` `deepseek` `moonshot` `openrouter` `siliconflow` `dashscope` `xai` `ollama` | 同名 | `<P>_API_KEY` | 新增 |
  | `google` `gemini` | 不支持 | | 报 Unknown provider，见 00-overview §6 |

- `muse_model:configured/0` 判断模型是否可用，规则同原项目的 `agentConfigured`（I§1.2），只是 key 的集合按上表扩展。
- 重试：`max_retries => 2`（对应原 MODEL_MAX_RETRIES）。
- HTTP 池：`http_pool_stream` 的 `max_connections_per_host` 调到 50。

## 2. 工具框架（`muse_tool`）

原工具用 zod schema 定义，这里用 beamai 的参数 DSL。为了让工具定义更接近原代码，并在 handler 之前做严格校验，封装一层：

```erlang
muse_tool:define(Name, Description, Schema, Fun, Opts) -> beamai tool_spec()
%% Schema: muse_schema DSL，例如
%%   #{steps => {array, {string, #{min => 1}}, #{min => 1, max => 12}}}
%% 它同时生成两样东西：
%%   - beamai 参数 DSL（发给模型）
%%   - 校验/规范化函数（trim、默认值、上下限，失败时返回 {error, Msg}）
%% Fun(Args :: map(), Ctx) -> {ok, Result} | {ok, Result, Writes} | {error, Msg}
```

- `muse_schema` 还要支持 JSON Schema 到参数 DSL 的转换，用于 MCP 工具的 `inputSchema`（ref digest §3 的坑）。
- 每个工具的统一包装：
  - 捕获异常并转成 `{error, Msg}`；
  - 返回值确保是 `{ok, _}` 形状（裸值会让 executor 崩溃）；
  - 结果超过限制时截断。
- 任务侧的工具一律 `serial => true`。聊天侧的读类工具允许并行，写入和委派类工具设成 serial。
- 取消联动：长工具（电脑命令、浏览、搜索）第一步执行 `link(RunPid)`，`RunPid` 从 `beamai_context:state_get(Ctx, <<"run_pid">>)` 读取。

## 3. 聊天 Agent（`muse_chat_agent`）

作为 beamai_agui 的 factory 注册，id 为 `<<"default">>`：

```erlang
beamai_agui_registry:register(<<"default">>, fun muse_chat_agent:factory/2).
factory(Input, RuntimeCfg) ->
    Owner = 从 RuntimeCfg 的 initial_state <<"owner">> 取（由 muse_web 前置中间件注入，见 §6）
    按 AGENT_BACKEND 分三种：
      sample → muse_sample_llm（{custom, Mod} 脚本化 provider），工具只有 delegate_task
      model  → 真实 LLM + 聊天工具集（E§9.5）+ 系统提示词（E§9.5 原文拼接）
      agui   → 不走 beamai_agent，见 §5
```

- 工具：
  - 读类：`search_mail`、`read_mail_thread`、`read_calendar`；配置后还有 `search_web` 和 `browse_web`。
  - 委派类：`delegate_task`、`agent_status`、`create_goal`、`watch_page`。
  - 记忆：`remember_fact`。
  - 电脑工具集（`muse_computer_tools`），scope 是 `chat:<requestKey>`。
  - Jev 开启时再加 `present_choices`。

  名称、描述、参数和返回值全部按 E§9.5 逐字实现。
- 前端工具：`RunAgentInput.tools` 里只保留 `open_workspace`。beamai_agui 会把它挂成 interrupt_tools。
- 步数上限：6，即 `max_tool_iterations`（OpenMuse 在 e2b-desktop 下为 16，本项目不支持 E2B）。
  - 超限时，`{error, {max_tool_iterations, _}}` 由 `event_transform` 插件改写成一条 stepLimitNote 文本消息，再接 RUN_FINISHED，对应原 `reportStepLimit`。
- 事件后处理（`muse_agui_plugin`，挂在 `event_transform` 上）：
  1. `textOnlyToolResult`：TOOL_CALL_RESULT 里的多模态数组只保留文本部分；
  2. 步数超限说明，即上一条；
  3. 工具调用之后的文本使用新的 messageId。beamai_agui 本身已经按消息分段，这里只需确认行为，不需要额外实现。
- 幂等键：`requestKey = <threadId>:<latest user msg id | runId>`，派生规则见 E§9.3，在 `muse_ids` 中实现。
- 历史：beamai_agui 每次只取最后一条用户消息，历史来自 memory，所以用持久化 memory。由 `muse_chat_log`（bitcask `chat` cask，01-store §2）实现 `beamai_chat_memory` behaviour，按 threadId 读取。线程回放和会话的 BM25 搜索也走它。
- 停止：调用 `beamai_agui_session:stop_run/1`。浏览、搜索、电脑这类长工具因为已经 link 到 run 进程，会随之结束（ref digest §4）。
- 选项面板（Jev）的续写前缀 `"[OpenMuse choice] "` 由 `input_transform` 插件识别并替换，对应 E§9.2 第 3 步。

### 3.1 Sample 模式

`muse_sample_llm` 实现 beamai 的 custom provider。它按 E§9.4 的正则顺序决定回复：
- 匹配到需要建任务的分支时，第一轮返回一个 `delegate_task` 工具调用（工具真的会执行，建任务时使用 requestKey）；
- 第二轮返回固定文案（弯引号逐字）。

这样 sample 和 model 走同一条事件管线。事件序列和原项目的差别是：原项目先发文本，再发工具调用；这里先发工具调用，再发文本。UI 不依赖这个顺序，在 06 验收文档中注明即可。

## 4. 任务模型 Agent（`muse_task_model`，实现 `muse_task_runner`）

按 E§7 第 1–11 步实现：
- 工具：`set_plan`、`read_workspace`、`read_mail_thread`、`import_pdf`、`inspect_pdf`、`fill_pdf`、`search_web`、`read_web`、`save_artifact`、`prepare_email`、`prepare_event`、`ask_user`、`finish_task`，再加电脑工具，scope 是 `task:<id>`。
- 停止条件 `outcome`：写到 state 的 `<<"halt">>` 槽，由 `around_step` 过滤器读到后结束循环。之后工具再被调用时直接返回 `{paused:true,...}`，与原项目相同。
- `cached/3`：用 `sha256hex(Name ++ ":" ++ JSON(Args))` 作为键，读写 `task.state.operations`，写入后 checkpoint。
- 每次工具调用前先执行 `guard()`，再写一条 `step` 事件，标题是工具描述。
- 无会话历史：`memory => false`，每次 run 只发一条用户消息（原项目如此）。
- 每次调用 LLM 时累计 usage，写进 runs 记录（新增）。

## 5. agui 后端（`muse_agui_proxy`）

`AGENT_BACKEND=agui` 时，把请求转发到 `AGENT_URL` 的 AG-UI 端点（`Authorization: Bearer AGENT_TOKEN`）。实现方式：
- 用 gun POST RunAgentInput，`accept: text/event-stream`；
- 逐帧解析 SSE，原样转发给 beamai_agui 的 emitter。

beamai_agui 的 factory 只能返回 beamai_agent。这里有两个办法：
- 用 `loop_filter` 替换 ReAct 循环，在里面消费上游 SSE；
- 不走 registry，在 `muse_web` 的 `/api/agui` 路由直接起一个代理 handler。

选第二种，更简单，也不受 agent 语义约束。这样一来，内置 UI 在 agui 模式下也要走代理流，所以中继进程（05-web-ui §4）要同时支持两种来源：beamai_agui 会话订阅，和代理 handler 进程的事件。

## 6. 身份注入

beamai_agui 的 cowboy handler 不会把认证身份传给 factory（ref digest §5）。处理方式：
- `muse_web` 自己写 `muse_agui_handler`，在前面校验 Bearer（或 UI cookie）得到 owner；
- 把 owner 写进 `RunAgentInput.state.owner`，同时用 `input_transform` 防止客户端伪造这个字段（总是覆盖）；
- 再委托给 `beamai_agui_cowboy_handler`。

factory 从 `initial_state` 里读出 owner。

## 7. 线程（`muse_threads`，替代 CopilotKit Intelligence）

记录 kind 是 `threads`，字段：`{id, title, kind: "main"|"side", archived, createdAt, updatedAt, lastMessageAt}`。

函数：`main_thread/1`（不存在则 insert_if_absent 创建）、`list/1`、`create_side/2`、`rename/3`、`archive/2`、`restore/2`、`messages/2`（从 `muse_chat_log` 读出并转成 UI 消息）、`search/3`（BM25 搜索历史会话，新增）。

同一线程上的并发 run 由 beamai_agui 的 `on_concurrent => reject` 处理，返回 409。UI 收到后把消息放回待发送队列，对应原 `agent_thread_locked` 的行为。

## 8. 网页搜索（`muse_search` + `muse_mcp_http`）

- `muse_mcp_http`：直接基于 gun 写的 streamable-HTTP MCP 客户端，约 150 行，提供 initialize、initialized、tools/list、tools/call，支持 SSE 和 JSON 两种响应。
- `muse_search:search(Owner, ConvKey, Args, RunPid)` 按 I§8 实现：
  - 每个 conversation 缓存一个 sessionId，记录 kind 是 `search-sessions`；
  - 超时 45 秒，响应体上限 1 MiB；
  - 结果映射为 `{results:[{url,title,excerpts}]}`。
- 端点与原项目一致：`https://search.parallel.ai/mcp`，无需 key（M4 实测可用，返回 10 条结果）。`search-mcp.parallel.ai` 是另一个需要 key 的端点，无 key 时返回 401。设置了 `PARALLEL_API_KEY` 时才带 Bearer。
- 已给 beamai_extra 提 feedback（`feedbacks/2026-10-22-mcp-http-client-remote-servers.md`）：recv(0) 立即取消请求导致崩溃（🔴），adapter 传原始 JSON Schema 和裸返回值，以及 tls_opts 不可配置（🟢）。注意 gun 2.7 本身会做证书校验，所以这不是安全漏洞。

## 9. Jev 选项面板（`muse_jev`）

规格见 E§10。
- 记录：`jev_threads`、`jev_panels`、`jev_evidence`、`jev_mail_evidence`。
- 工具：`present_choices`。
- 函数：`select/3`、`expire_if_unchanged/4`。
- 排序适配器：
  - `JEV_MODE=sample` 用规则排序，对应原 sample adapter；
  - `live` 调用 TypeSafe API（`TYPESAFE_API_KEY`、`JEV_MODEL`）。具体接口在 M7 阶段从 `@typesafe-ai/sdk` 的源码确认，超时 5 秒，重试 1 次。
- UI：面板渲染成 aihtml 卡片。点选后发送带 `"[OpenMuse choice] "` 前缀的消息，与原项目相同。
