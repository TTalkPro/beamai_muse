# M1 muse_core：配置、存储、安全原语

> 设计：[01-store.md](../designs/01-store.md)、[04-integrations.md](../designs/04-integrations.md) §1
> 规格：I§0–§3、I§10、E§1
> 状态：✅ 完成（2026-10-22）

## M1-1 基础工具
- [x] `muse_time`：`now_iso/0`（毫秒 + `Z`，与 JS `toISOString` 一致）、`to_ms/1`、`from_ms/1`、`add_ms/2`；解析 ISO 失败时返回 `nan`（对应 JS 的 NaN 语义，"永不到期"依赖这一点，见 E§4.1）。
- [x] `muse_json`：`encode/1`，以及保持键插入顺序的 `encode_ordered/1`（输入 proplist，用于 hash 计算，必须和 JS `JSON.stringify` 逐字节一致：转义规则、不带空格、数字格式）。另有 `decode/1`（JSON null → `null`）。
- [x] `muse_ids`：`uuid_v4/0`、`sha256hex/1`、`deterministic_file_id/2`（I§5.2 的位运算），以及幂等键派生：任务、监控、目标、记忆（E§5.1、E§9.3）。
- [x] `muse_validate`：zod 风格的校验 DSL，支持 trim、min/max、enum、email、url、record，默认值，unknown 键剥离；错误消息用 `"; "` 拼接。另外提供常用 schema：emailDraft、eventDraft、proposal、calendarRange（I§2.5）。

验收：eunit 覆盖以下内容：
- JSON 和 JS 的一致性，至少 30 条用例，包括 unicode、控制字符、浮点；
- 时间解析；
- 确定性 id 的向量用 Node 生成，作为对照。

## M1-2 配置
- [x] `muse_config:load/0`：
  - `.env` 加载规则与提示文案（I§1.1）；
  - 所有变量的默认值和校验，**校验顺序和错误文案逐字一致**（I§1.2），并按 00-overview §5 的差异处理；
  - 结果写入 `persistent_term`。
- [x] `muse_config:get/1`、`agent_configured/0`、`browser_configured/0`、`allowed_origins/0`（allowed_origins 不 trim，与原项目一致）。
- [x] 启动失败时打印错误消息并以非零码退出，不要输出 crash dump 噪音。

验收：移植 `tests/config.test.ts` 和 `auth-startup.test.ts` 中的可移植用例。

## M1-3 Mnesia 存储
- [x] `muse_store`：完整实现 01-store §1.1 中的全部函数，包括 `contains/2` 和 `cas/5` 的语义。
- [x] schema 初始化：disc_copies、三个索引、`muse_meta` 版本表；`nonode@nohost` 时拒绝启动。
- [x] `recover_interrupted_actions/0`。
- [x] 严格递增的 `updated_at`。

验收：
- eunit 的 contains 表驱动用例不少于 25 条；
- 50 进程并发 CAS 时只有一个成功；
- `list` 的排序、`scan` 的排序、`take` 的一次性语义；
- 重启节点后数据仍然存在（ct）。

## M1-4 bitcask cask
- [x] `muse_cask`：gen_server，每个目录一个，作为单写者；句柄放进 `persistent_term`；每小时检查 `needs_merge` 并在后台 merge；关闭时 `sync` 后 `close`。
- [x] `muse_events_log`：append、list、delete_task（01-store §2.3），key 前缀用前缀的下一个字节作为上界。
- [x] `muse_chat_log`：append（`txn_commit` 写 raw 项和索引项）、messages、search（BM25，按 owner 用 meta filter 过滤），并实现 `beamai_chat_memory` behaviour（`mem_get/2`、`mem_add/3`、`mem_clear/2`）。
- [x] `muse_blob`：put、get、delete，以及孤儿清理接口 `fold_prefix/3`。
- [x] 确认 chat cask 的 analyzer 选项，中文分词按 bitcask 文档选择（cppjieba），并在设计文档中记下所选值。

验收：eunit 和 ct 覆盖：
- 事件顺序，以及相邻 TaskId 之间不串扰；
- BM25 能搜到中英文消息，跨 owner 不泄露；
- 重启后序号计数器从 range 末尾恢复；
- beamai_agent 使用 `{store, muse_chat_log 句柄}` 时多轮对话历史正确（脚本化 LLM）。

## M1-5 认证、签名、vault、限流
- [x] `muse_auth`：`session/1`（sample/live 两种模式、常数时间比较、token 哈希存储、24 小时过期）、`owner/1`、`revoke/1`、过期清理。
- [x] `muse_signing`：签名 key 文件（0600，先写 tmp 再 link 原子发布，44 字符 base64 原文作为 key）；`sign/2`、`verify/2`（I§3.2–§3.3，参数名和消息格式逐字一致）。
- [x] `muse_vault`：`encrypt/2`、`decrypt/2`、`check_key/1`（I§10 的全部校验和文案）。
- [x] `muse_rate_limit`：API 固定窗口限流（每分钟 120 次，最多 10000 个 key），按 IP 的登录限流（每分钟 30 次），客户端 key 的解析规则（TRUST_PROXY）。

验收：移植 `vault.test.ts`、`rate-limit.test.ts`、`resource-ids.test.ts` 和 auth 相关用例。vault 用 Node 生成的密文做互通测试（能解开原项目的密文）。

## 验收记录（2026-10-22）

- 门禁：`scripts/check.sh` 全部通过。compile 无 warning，xref 0，dialyzer 0，eunit 164 tests / 0 failures，ct 3 tests / 0 failures。
- JS 兼容性：数字、字符串、确定性文件 id、vault 密文、HMAC（以文本作 key）、encodeURIComponent、ISO 时间解析，这些向量都由 Node 24 按 OpenMuse 的算法生成，Erlang 的结果逐字节一致（`muse_json_tests`、`muse_ids_tests`、`muse_security_tests`）。
- `muse_core_SUITE`：
  - `app_boot_and_durability`：在 peer 节点上启动应用，向 Mnesia 和四个 cask 写入数据，**杀掉节点**后用同一节点名重启，数据全部还在；执行中的审批被恢复为 outcome_unknown；签名 key 文件不被覆盖。
  - `config_error_stops_boot`：配置错误时应用启动失败，并返回原文案。
  - `agent_memory_on_bitcask`：beamai_agent 以 `{store, muse_chat_log}` 作 memory，换一个新的 agent 值后历史依然可见（脚本化 LLM `muse_test_llm`）。

## 实现中的发现与偏差

1. **Mnesia 默认不防崩溃**：disk_log 有缓冲，即使用 `sync_transaction`，被杀掉的节点也会丢失最近的提交。现在每次写事务后调用 `mnesia:sync_log/0` 把日志 fsync 到磁盘（仅 disc 模式），ct 已验证。
2. **Mnesia 的 schema 绑定节点名**：数据目录不能换节点名复用。release 固定为 `muse@127.0.0.1`，M8 文档里要写明。
3. **bitcask 索引模式会给所有二进制值分词**，并且 `get` 返回 `#{text, meta}`。所以聊天拆成 `chat`（KV 原文）和 `chat_index`（jieba 检索）两个 cask。jieba 不处理查询的大小写，查询要先转小写。
4. 聊天原文用 `term_to_binary` 保存 beamai 消息（原子键、原子 role），这样回放不失真。设计里原写的是 JSON，已修正。
5. `muse_time:parse` 对非法日期（例如 `2026-02-30`）返回 `nan`。V8 的 `Date.parse` 会把它进位成 3 月 2 日，这里有意更严格。
6. 新增配置项 `MUSE_UI_SECRET`（live 模式必填）。`DATA_DIR` 默认改为 `.muse`。
7. 测试用的脚本化 provider 暂时放在 `apps/muse_core/test/muse_test_llm.erl`，M4-1 时并入 `muse_script_llm`。
