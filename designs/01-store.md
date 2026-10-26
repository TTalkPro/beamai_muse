# 01 存储：Mnesia（事务记录 + CAS）+ bitcask（日志、历史、大对象、全文检索）

对应原 `apps/server/src/db.ts`（E§1、I§0）。原项目把所有业务数据都放在一张 jsonb 表里，并发安全只靠 `compareAndSwap` 这一个原语。
Erlang 侧按数据的访问特征拆成两个存储：

| 存储 | 放什么 | 原因 |
|---|---|---|
| **Mnesia** `muse_record` | 所有需要 CAS、事务或条件写的记录：tasks、runs、actions、activity、monitors、goals、ideas、notifications、memories、agent-settings、sessions、settings、files（元数据）、browsers、chat-browsers、browser-downloads、search-sessions、computer-state、computer-*-commands（receipt）、threads、conversation-settings、jev_*、worker-status、sample-pages（原来的 oauth、credentials、imports、drafts、mail、events 随 Google 和邮件、日历删掉了，M9-4）；内置日程的 calendars、calendar-events（M9-7）；内置邮件的 mail-accounts、mail-sync、mail-folders、每个文件夹一个 `mail-msg:<folderId>`、mail-bodies、mail-drafts、mail-sends（发送回执，M9-8，见 02-engine §9） | 引擎的正确性建立在 CAS 之上（租约、状态流转、审批、幂等插入），bitcask 明确**不提供隔离和 CAS**（api-zh「原子批与多键事务」） |
| **bitcask** | ① `events`：任务运行事件（run-events），只追加，按任务做范围读取<br>② `chat` + `chat_index`：聊天消息原文（KV，每线程有序）与 BM25 检索索引（jieba）<br>③ `blobs`：PDF 字节、浏览器截图、桌面截图、监控页面快照（最多 2000 行 × 300 字符） | 只追加或写一次、体积大、需要有序范围读取或全文检索；不需要条件写 |

bitcask 来源：https://github.com/DavidAlphaFox/bitcask（develop 分支，6.7.3，C++23 NIF，构建需要 cmake、C++23 编译器和 ICU 开发包），作为 rebar3 git 依赖引入。

## 1. Mnesia 表

```erlang
-record(muse_record, {
    key        :: {Owner :: binary(), Kind :: binary(), Id :: binary()},   %% 主键
    ok         :: {Owner :: binary(), Kind :: binary()},                   %% 索引：list/scan
    status     :: binary() | undefined,   %% 索引：data.status 投影（listByStatus）
    goal_id    :: binary() | undefined,   %% 索引：data.goalId 投影（listByGoalId）
    data       :: map(),                  %% JSON 文档，二进制键，data.id == Id
    updated_at :: integer()               %% 严格递增的微秒戳（见 §4）
}).
```

- 表类型为 `disc_copies`，目录 `DATA_DIR/mnesia`；建立 `ok`、`status`、`goal_id` 三个索引。`kind` 的取值与原项目一致。
- 投影字段在每次写入时由 data 重新计算。
- schema 版本记在 `muse_meta` 表里。`muse_store:init/0` 按需建表，并拒绝在 `nonode@nohost` 上写盘。

### 1.1 API（`muse_store`）

| 函数 | 语义 |
|---|---|
| `get(O,K,I) -> map() \| undefined` | |
| `list(O,K) -> [map()]` | `updated_at` 降序，相同时按 `id` 升序 |
| `list_by_goal(O,K,GoalId)`、`list_by_status(O,K,Status)` | 走索引，排序同上 |
| `put(O,K,Map) -> Map` | 整体替换并刷新 `updated_at` |
| `remove(O,K,I)` | |
| `take(O,K,I) -> map() \| undefined` | 事务内读出并删除 |
| `insert_if_absent(O,K,Map) -> Map \| undefined` | 已存在时返回 `undefined` |
| `cas(O,K,I,Expected,Patch) -> map() \| undefined` | 见 §1.2 |
| `scan(K) -> [{Owner, map()}]` | 跨 owner，`updated_at` 升序（worker 公平性依赖这个顺序） |
| `update(O,K,I,Fun) -> map() \| undefined` | 事务内执行 `Fun(Data) -> {ok, New} \| abort`，替代 `claim`、`setMilestoneDone`、`updateCredential` |
| `recover_interrupted_actions()` | 启动时调用，E§1.2 原文 |

### 1.2 CAS 语义（与 Postgres jsonb 一致）

```
cas(O,K,I,Expected,Patch):
  transaction:
    读 key；不存在 → undefined
    contains(Data, Expected)；不满足 → undefined
    New = maps:merge(Data, Patch)        %% 浅合并；值为 null 时存 null，不删键
    写回，刷新 updated_at 和投影 → New
```

`contains(Data, Expected)` 对齐 `@>`：
- map 对 map：Expected 的每个键都要在 Data 中存在，并且递归满足 contains；
- list 对 list：Expected 的每个元素都要被 Data 中的**某个**元素 contains（子集语义，与 Postgres 相同）；
- 数字按数值比较；其他标量用 `=:=`；
- `null` 只匹配 `null`，键缺失不算匹配，所以任务创建时必须显式写 `leaseId => null`。

JSON `null` 统一用原子 `null` 表示（与 OTP `json` 模块一致）。

### 1.3 持久性

Mnesia 的 disc_copies 默认把事务日志缓冲在 disk_log 里，节点被杀掉时最近的提交会丢失（M1 实测，`sync_transaction` 也一样）。所以 `muse_store` 每个写事务提交后都调用 `mnesia:sync_log/0`，把日志 fsync 到磁盘后再返回。

disc schema 绑定节点名，数据目录只能由同名节点打开，release 固定为 `muse@127.0.0.1`。

## 2. bitcask cask

```
DATA_DIR/bitcask/events   KV 模式
DATA_DIR/bitcask/chat        KV 模式（消息原文）
DATA_DIR/bitcask/chat_index  索引模式 {analyzer, jieba}（BM25 检索）
DATA_DIR/bitcask/blobs    KV 模式
```

**单写者**：每个目录只允许一个写者（文件锁）。每个 cask 由一个 gen_server `muse_cask` 持有句柄并串行处理所有写入。
读和搜索直接用共享句柄（无锁并发，见 api-zh「并发约束」），句柄放在 `persistent_term`。

### 2.1 键设计（可以按前缀做范围读取）

| cask | key | value |
|---|---|---|
| events | `ev/<Owner>/<TaskId>/<Seq:20 位零填充十进制>` | `json:encode(RunEvent)`（`{id, taskId, date, kind, title, detail}`，与 E§2.3 一致） |
| events | `evidx/<Owner>/<EventId>` → 主键 | 按事件 id 回查（可选） |
| chat | `raw/<ThreadId>/<Seq>` | `term_to_binary(beamai 消息)`（原子键、原子 role，用于精确回放） |
| chat_index | `doc/<ThreadId>/<Seq>`（与 chat 中的 Seq 相同） | doc map：`#{text => 纯文本, meta => encode_meta(#{owner, thread, role})}` |
| blobs | `pdf/<FileId>`、`shot/<Owner>/<BrowserId>`、`desk/<Owner>`、`page/<Owner>/<MonitorId>`、`mailbody/<MessageId>`（超过 64 KB 的邮件正文，JSON `{text, html}`）、`mailup/<UploadId>`（写邮件时上传的附件，发出或删掉草稿时删除） | 二进制 |

- `Seq` 由 `muse_cask` 进程内的单调计数器生成（启动时从 range 的末尾恢复）。也可以用 `muse_store` 的严格递增时间戳。按任务读事件时用 `range(H, {<<"ev/O/T/">>, <<"ev/O/T0">>})`，即上界取前缀的下一个字节。
- 删除一个任务的事件时，先做 range，再用 `put_batch_atomic` 批量 `{remove, K}`。
- 聊天消息拆成两个 cask，原因是 M1 实测发现：索引模式的 cask 会把**所有**二进制值都分词入索引（包括 `term_to_binary` 的原文），并且 `get` 返回的是 `#{text, meta}`。写入时先写 `chat` 原文，再写 `chat_index`。两步之间崩溃时，只会丢失这一条消息的可检索性。
- jieba 分析器会把索引中的拉丁字母转成小写，但不会处理查询，所以查询前要先 `string:lowercase/1`（M1 实测）。

### 2.2 一致性约定

- bitcask 写入**不参与** Mnesia 事务。约定：先写 bitcask，后写 Mnesia 元数据。元数据指向的 blob 一定已经存在；崩溃后可能留下孤儿 blob，由 maintain() 清理。
- run-events 只追加，没有并发冲突；`event()` 调用前已经执行过 `guard()`（E§4.2），语义不变。
- 合并（merge）：`muse_cask` 每小时调用一次 `needs_merge/1`，需要时用 `bitcask:merge/1` 在后台执行。

### 2.3 API

```erlang
muse_events_log:append(Owner, TaskId, EventMap) -> ok
muse_events_log:list(Owner, TaskId) -> [EventMap]          %% 按时间升序
muse_events_log:delete_task(Owner, TaskId) -> ok
muse_chat_log:append(Owner, Tid, Message) -> Seq
muse_chat_log:messages(Owner, Tid) -> [Message]
muse_chat_log:search(Owner, Query, K) -> [{Tid, Seq, Score}]   %% BM25 + meta filter owner
muse_blob:put(Key, Bin) / get(Key) / delete(Key)
```

`muse_chat_log` 同时是 beamai 的持久化 memory 后端（`beamai_chat_memory` behaviour，见 03-agent §3）。

## 3. 文件布局

```
DATA_DIR/
  mnesia/                 Mnesia
  bitcask/{events,chat,blobs}
  session-signing-key     I§3.2
  ui-secret               sample 模式下自动生成的 aihtml secret
```

原项目把 PDF 放在 `DATA_DIR/files/<id>.pdf`，这里改为放进 `blobs` cask 的 `pdf/<id>` 下，写入顺序是"先 blob，后 Mnesia 记录"。
带操作键的幂等导入（id 由 owner 和操作键确定）原来靠"先写 tmp 再 link"防并发，这里改为用 `global:trans({{muse_files, Id}, self()}, ...)` 把同一个 id 的导入串行化（M2 实现）：持锁后若记录已存在，直接返回；否则检查文件、写 blob、写记录。

## 4. updated_at

`erlang:system_time(microsecond)` 和一个 `atomics` 单调计数器取较大值，保证严格递增，排序结果确定。业务层的 `updatedAt` ISO 字段由业务代码自己写，与这个字段无关。

## 5. 测试

- eunit：
  - `contains/2` 表驱动测试：嵌套 map、数组子集、null 与缺键、数字比较；
  - CAS 并发：50 个进程同时 CAS 同一个 lease，只有一个成功；
  - `muse_events_log`：顺序、范围边界（前缀相邻的 TaskId 不串）、删除；
  - `muse_chat_log`：BM25 检索结果按 owner 过滤，重启后计数器能恢复；
  - blob：读写和孤儿清理。
- 移植原 `tests/db*.test.ts` 中 CAS、insertIfAbsent、take 的用例。
