# 02 任务引擎（muse_engine）

对应原 `apps/server/src/engine/{worker,service,finance,page-diff,routes}.ts` 和 `actions.ts`。行为以 E§2–§6、E§12 为准，本文只写 Erlang 侧的结构和映射方式。

## 1. 模块划分

| 模块 | 职责 | 原文件 / 规格 |
|---|---|---|
| `muse_task` | 任务记录构造、`createTaskSchema` 校验、状态常量、转换表 | domain/agent.ts，E§2.1、E§3 |
| `muse_task_worker` | gen_server：tick、认领、并发上限、心跳状态记录 | worker.ts，E§4.1 |
| `muse_task_run` | 每个 run 一个进程：租约、心跳、上下文（guard/checkpoint/event）、结束处理 | worker.ts，E§4.2 |
| `muse_agent_service` | createTask / control / answer / detail / snapshot / execute 分发 / publishOutcome / artifact | service.ts，E§5 |
| `muse_goals` | 目标、里程碑（含 publishOutcome 的里程碑追加，重试 8 次） | E§5.4、E§5.9 |
| `muse_monitors` | createMonitor / activate / control / observe / 失败退避与自动暂停 | E§5.5 |
| `muse_page_diff` | 页面行提取与差异（纯函数） | page-diff.ts，E§5.6 |
| `muse_finance` | CSV 解析、分类、汇总产物（纯函数） | finance.ts，E§5.7 |
| `muse_document_flow` | 权限单流程：附件 → 填表 → 准备回复 → 等待审批 → 回执 | E§5.10、E§5.11 |
| `muse_ideas` | refreshIdeas / decideIdea | E§5.12 |
| `muse_actions` | propose / decide / claim / 过期 / outcome_unknown / activity 记录 | actions.ts，E§6 |
| `muse_notifications`、`muse_memories`、`muse_identity` | 通知、记忆、身份设置 | E§2.8、E§2.10、E§2.11 |
| `muse_maintainer` | 每 60 秒执行 maintain()，单飞 | E§5.13 |
| `muse_events` | 引擎对外的变更广播（见 §4） | 新增 |

## 2. Worker 与 Run 的进程模型

```
muse_task_worker (gen_server)
  state: #{in_flight => #{TaskId => {Pid, MRef}}, ticking => bool, stopping => bool}
  handle_info(tick):
     put system/worker-status {lastTickAt}
     Due = 按 E§4.1 第 5–6 步筛选（scan 已按 updated_at 升序排列）
     对每个合格任务: {ok,Pid} = muse_task_run_sup:start(Owner, Task)，并 monitor
  handle_info({'DOWN', MRef, ...}) → 从 in_flight 移除
  abort(TaskId) → 向 run 进程发 {abort, Reason}
```

`muse_task_run` 用 gen_server（`trap_exit`）实现：
- 认领时按 E§4.2 第 2 步做 CAS；失败就正常退出。
- 业务执行放在 run 进程**内部再 spawn_link 的执行进程**（Exec）里。run 进程本身负责：
  - 每 20 秒发心跳 CAS，失败时把 Exec 杀掉（`exit(Exec, lost_lease)`）；
  - 收到 `{abort, R}` 时设置 aborted 标志并杀掉 Exec；
  - 收到 `{'EXIT', Exec, Reason}` 后按结果走成功、失去租约或失败三条路径（E§4.2 第 8–9 步），最后调用 settle → publishOutcome。
- 上下文 `Ctx`（map）传给 Exec：

  ```erlang
  #{owner, task_id, lease_id, run_pid,
    guard      => fun() -> ok end,          %% 失败时 throw({lost_lease, Why})
    checkpoint => fun(Patch) -> Task end,
    event      => fun(Kind, Title, Detail) -> ok end,
    aborted    => fun() -> boolean() end}
  ```

  `aborted` 读 ETS 标志（`muse_task_flags`，由 worker 持有，键是 lease_id），这样不用向 run 进程发同步消息。
  中止时 run 进程直接 `exit(Exec, kill)`；Exec 的结果通过 `{exec_result, R}` 消息先于 `'EXIT'` 到达 run 进程。
- 失去租约用 `throw({lost_lease, _})`，Exec 捕获后以 `{shutdown, lost_lease}` 退出。其他异常以 `{failed, Detail}` 退出，`Detail` 只取对用户安全的消息文本。

"超时 5 分钟"（模型任务）由 Exec 自己的计时器负责，超时后以 `{failed, <<"Model run timed out after five minutes">>}` 退出。

## 3. Service 层

- 所有函数都接受 `Owner`，返回 `{ok, V} | {error, {Status, Message}}`。HTTP 层把 `{error, {Status, Msg}}` 映射成状态码（对应原 AppError）。
- 校验错误统一返回 `{error, {422, Msg}}`，多条消息用 `"; "` 连接，由 `muse_validate` 生成（参照 zod 文案，不追求逐字一致）。
- `execute(Owner, Task, Ctx)` 的分发顺序按 E§5.8：先处理审批（actionId），再按 kind 分发到 document、monitor、finance，其余交给 `muse_task_runner:run/3`。这是一个 behaviour，由 `muse_agent` 在启动时用 `application:set_env(muse_engine, task_runner, muse_task_model)` 注入。没有注入时返回 E§7 第 1 步的 waiting_input 文案。
- 幂等键规则（任务 id = `sha256hex("task:" ++ Key)` 等）逐字对齐 E§5.1 和 E§9.3，都在 `muse_ids` 中实现。

## 4. 变更广播（为 UI 新增）

原项目前端靠轮询。aihtml UI 需要推送，所以引擎在关键写入点发出领域事件：

```erlang
muse_events:emit(Owner, {task, TaskId})        %% 任务状态、计划、进度变更（checkpoint 与 control 之后）
muse_events:emit(Owner, {run_event, TaskId, Ev})
muse_events:emit(Owner, {action, ActionId})
muse_events:emit(Owner, {notification, Id})
muse_events:emit(Owner, {monitor | goal | idea | memory, Id})
```

- 实现方式：`pg` 组 `{muse_events, Owner}`，消息是 `{muse_event, Owner, Event}`。
- 引擎不依赖 aihtml。`muse_web` 里的 `muse_ui_bridge` 进程订阅这个组，把事件转成 `aihtml_push:publish/2`（见 05-web-ui）。
- 广播失败不影响业务，统一 `catch`。

## 5. 审批（muse_actions）

- `propose`：
  - 先按 kind 校验（emailDraft / eventDraft，I§2.5）；
  - 计算 `hash = sha256hex(JSON({input, connection, target, targetVersion}))`，键顺序见 E§6.1；Erlang 用 `muse_validate:ordered/2` 生成按 schema 顺序排列的 `{obj, Pairs}`，再交给 `muse_json:encode/1`（M3 实现，已与 Node 逐字节对照）；
  - 绑定 connectionId 和 targetVersion，30 分钟后过期，并写一条 activity 记录。
- `decide(Owner, Id, Hash, approve|deny)` 的检查顺序逐条对齐 E§6.2。批准时：
  1. 用 CAS 把状态改成 `executing`；
  2. 调用 `muse_workspace:execute/4`（Gmail 发信或 Calendar 写入）；
  3. 结果写成 `succeeded`、`failed` 或 `outcome_unknown`；
  4. 唤醒关联任务（E§6.4）。
- 启动时由 `muse_store:recover_interrupted_actions/0` 把残留的 `executing` 改成 `outcome_unknown`。

## 6. 维护任务

`muse_maintainer` 每 60 秒执行一次（启动时也执行一次）。如果上一轮还没跑完，就跳过本轮。内容见 E§5.13：
- 补发遗漏的 publishOutcome；
- 重新激活 monitor；
- 恢复已采纳但还没有建出任务的 Idea；
- 每 15 分钟刷新一次 Ideas；
- 新增：清理过期的 sessions、oauth state 和老旧的 run-events（见 01-store §2.2）。

## 7. 测试要点（ct：`muse_engine_SUITE`）

- 任务生命周期：queued → running → succeeded，同时校验 runs 和 run-events 记录。
- 租约接管：手动把 leaseUntil 设成过去的时间，确认第二个 worker 能接手；原 run 的 checkpoint 失败，并走 lost_lease 路径。
- 控制：pause、resume、cancel、retry 的规则表（E§5.2），取消时自动拒绝挂起的审批。
- 审批：hash 不一致时拒绝；过期后 tick 把审批标成 expired 并唤醒任务；重启后 executing 变成 outcome_unknown，此时 retry 被拒。
- monitor：退避为 `2^n` 分钟，上限 60；失败 5 次后自动暂停；首次 change 不告警；告警去重。
- finance 和 page-diff：移植原测试用例做 eunit。
