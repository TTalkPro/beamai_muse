# M3 muse_engine：任务引擎、审批、目标、监控、Ideas

> 设计：[02-engine.md](../designs/02-engine.md)
> 规格：E§2–§6、E§12
> 状态：✅ 完成（2026-10-22）。M3-2（财务、页面对比）和 M3-5（审批）由并行子 agent 实现，其余由主线实现并整合。

## M3-1 领域记录与校验
- [x] `muse_task`：createTaskSchema（E§5.1）、状态常量、转换表（E§3）、记录构造（必须包含 `leaseId => null` 和 `leaseUntil => null`）。
- [x] goal、monitor、idea、memory、artifact、notification、identity 的 schema 与构造（E§2.4–§2.11）。

验收：eunit 覆盖每个 schema 的边界值，并与 E§2 的字段清单逐项核对。

## M3-2 纯函数模块
- [x] `muse_finance:analyze/1`：CSV 解析、分类、汇总产物（E§5.7），限制为 500000 字符、5000 行、cents 上限。
- [x] `muse_page_diff`：行提取（最多 2000 行，每行 300 字符）、差异计算、可用性文本匹配、USD 价格阈值（E§5.6）。

验收：移植原 `finance*.test.ts` 和 `page-diff*.test.ts` 的全部用例。

## M3-3 Worker 与 Run
- [x] `muse_task_worker`：tick 按 E§4.1 逐步实现，包括心跳状态记录、过期审批的 expire 处理、并发上限 3、stop 时等待 in-flight 任务结束。
- [x] `muse_task_run`：
  - 认领 CAS；
  - Exec 子进程；
  - 每 20 秒心跳，失败时杀掉 Exec；
  - abort；
  - guard、checkpoint、event 上下文，event 写入 `muse_events_log`；
  - 成功、失去租约、失败三条路径（E§4.2）；
  - runs 记录；
  - settle 时调用 publishOutcome。
- [x] `muse_task_runner` behaviour 与注入点；未注入时返回 waiting_input 文案。

验收（ct）：
- 生命周期；
- 租约过期后由新 run 接管，旧 run 的 checkpoint 抛出 lost_lease；
- 心跳失败时 Exec 被杀；
- abort 后任务回到 queued；
- 并发上限。

## M3-4 AgentService
- [x] `create_task/4`：幂等、100 个未结束任务的上限、goal 暂停时以 paused 状态创建、里程碑校验。
- [x] `control/3`：pause、resume、cancel、retry 的完整规则（E§5.2），包括取消时拒绝挂起的审批、调用 worker abort、document 任务 retry 的特殊规则。
- [x] `answer/4`、`detail/2`、`snapshot/1`（E§2.16，worker 存活判断窗口为 15 秒）、`artifact/7`。
- [x] `execute/3` 的分发（E§5.8）：先审批，再按 kind 分发。
- [x] `publish_outcome/2`：通知去重键、里程碑追加（重试 8 次）、goal 联动（E§5.9）。

验收：ct 覆盖 E§5.2 的规则表（每格一个用例），以及 publishOutcome 的幂等性。

## M3-5 审批
- [x] `muse_actions`：
  - propose（规范化 JSON 后计算 hash，绑定 connectionId 和 targetVersion，30 分钟过期，写 activity）；
  - decide（检查顺序见 E§6.2，CAS 改为 executing，调用 `muse_workspace:execute_action`，结果为 succeeded、failed 或 outcome_unknown）；
  - 唤醒任务（E§6.4）；
  - 启动恢复。

验收：
- hash 不一致时拒绝；
- 重复批准时幂等；
- 过期后无法批准；
- 重启后 outcome_unknown 状态拒绝 retry；
- 用 Node 跑原代码对同一份提案计算 hash 作为对照，结果一致。

## M3-6 文档流程、监控、目标、Ideas
- [x] `muse_document_flow`：E§5.10–§5.11 的全部步骤和状态键。
- [x] `muse_monitors`：create、activate、control（pause、resume、stop、check，重试 2 次）、observe（抓取页面通过 `muse_browser` 或 sample-pages，页面快照写入 blob）、失败退避（`2^n` 分钟，上限 60，第 5 次失败时自动暂停并告警）、首次 change 不告警、告警去重。
- [x] `muse_goals`：创建、更新、里程碑勾选。
- [x] `muse_ideas`：refresh（E§5.12 的来源和排除规则）、decide（accept 时创建 goal 和任务；dismiss 在竞态下可能返回 null，与原项目一致）。
- [x] `muse_memories`、`muse_identity`、`muse_notifications`。

验收：
- document 流程端到端走 sample PDF：填表 → 准备回复 → 批准 → 完成；
- monitor 退避时序（用模拟时钟 `muse_time` 注入）；
- ideas 刷新的去重规则。

## M3-7 维护与事件广播
- [x] `muse_maintainer`：E§5.13 的全部维护任务，加上新增的清理项（过期 sessions、oauth state、旧 run-events、孤儿 blob）。
- [x] `muse_events`：基于 pg 的领域事件广播（02-engine §4），在所有写入点调用。

验收：在任意写入点后，订阅者都能收到对应事件（ct）。

## 验收记录（2026-10-22）

- 门禁：xref 0、dialyzer 0；eunit 共 798 个用例，0 失败。其中 engine 新增：muse_finance、muse_page_diff，以及 305 组 Node 对照向量（`rebar3 eunit --module muse_engine_ref_tests`），muse_actions 19 个。
- `muse_engine_SUITE`（22 个用例，全部通过），在 sample 工作区上用可编程的 `muse_test_runner` 代替模型，覆盖：
  - 校验、幂等创建、100 个未结束任务的上限；
  - 无模型时进入 waiting_input；runner 成功、失败、崩溃，以及 retry；
  - 控制规则表、暂停正在运行的任务（run 被中止并标为 interrupted）；
  - checkpoint 时发现租约被抢走、心跳续约失败后 2 秒内中止、租约过期后被接管；
  - 权限单全流程：等待输入 → 填表 → 等待审批 → 批准 → 完成，执行时 worker 不碰处于 pending 的审批；
  - 取消时拒绝审批，以及审批不是 succeeded 时禁止 retry；
  - 监控的 contains 与 change 两种条件：只有相对时间变化时保持安静，真正变化时生成带 diff 的通知；
  - 失败退避（2 分钟起），第 5 次失败后暂停，恢复后清零；
  - Ideas：刷新、去重、接受时建目标和任务、忽略；
  - 目标与里程碑，包括任务完成后自动追加里程碑、暂停目标时连带暂停任务；
  - 记忆、身份、通知去重；维护任务；snapshot 和 detail 的结构；
  - 财务任务端到端（UI 的示例 CSV → "4 transactions · 110.99 spent"）；
  - 领域事件广播。

## 实现中的发现与偏差

1. **执行模型**：每次 run 是一个 gen_server，业务代码跑在它 spawn_link 出的执行进程里。中止就是杀掉执行进程，相当于 AbortSignal。任务内部的失败通过 `throw({task_failed, Msg})` 表达，租约丢失通过 `throw({lost_lease, _})` 表达。
2. **muse_task_runner**：模型任务通过 behaviour 注入（`application:set_env(muse_engine, task_runner, Mod)`），没有注入时返回原项目"需要模型"的文案。这样 engine 不依赖 muse_agent。
3. **新增 `muse_js`**（muse_core）：`slice/2`（按 UTF-16 截断）、`number/1`、`collapse_ws/1`。监控的 contains 和价格判断改用 `muse_page_diff` 中更精确的 JS 兼容实现（它能处理空值，以及 `Number()` 的各种写法）。
4. **原项目 `createTask` 先做 schema 校验，再查已有记录**：带幂等键重放时，非法输入仍然返回 422。spec 里"在任何校验之前返回"指的是 goal、里程碑和容量这几项检查。
5. **接受 idea 时会给它建一个没有里程碑的目标**，下一次刷新时这个目标会再生成一条 plan idea。这是原项目的行为，这里照搬。
6. **run-events 写在 bitcask**，按任务做范围读取，所以 `detail` 不需要扫描全部事件。
7. **心跳间隔为 lease/3**，租约时长可以用 app env `lease_ms` 配置（测试用 300 ms）；轮询间隔用 `poll_ms` 配置。
