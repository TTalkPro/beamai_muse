# M2 muse_integ：工作区、文件/PDF、电脑、浏览器、Google

> 设计：[04-integrations.md](../designs/04-integrations.md)
> 规格：I§4–§9
> 状态：✅ 完成（2026-10-22）。M2-3、M2-4、M2-6 由并行子 agent 在隔离副本中实现，主线负责整合与验收。

## M2-1 工作区与 sample 夹具
- [x] `muse_workspace_seed`：把原 `workspace.ts::seed` 的邮件、日程和设置逐字移植（I§4.3）。permission slip 邮件的附件引用 sample PDF。
- [x] `muse_workspace`：
  - `ensure_sample/1`；
  - `snapshot/2`，含 `q` 过滤，规则见 I§4.4；
  - `section_snapshot/2`；
  - `thread/2`（I§4.5，Google 断开时返回 409，线程不存在返回 404）；
  - `calendars/1`、`events/2`；
  - `import_attachment/2`（I§4.6，sample 模式下返回 400）；
  - `connections/1`。
- [x] `execute_action/2`（I§4.7）：sample 模式写本地 mail 和 events；live 模式委托给 Google（M2-6）。
- [x] 草稿（drafts）的存取。

验收：移植 `api.test.ts` 中工作区相关用例；sample 模式的快照与原项目的 JSON 字段一致。

## M2-2 文件存储
- [x] `muse_files`：
  - `import/4,6`（确定性 id；keyed 幂等改为 `global:trans` 按 id 串行化，见 01-store §3）；
  - `list/1`、`get/2`、`bytes/2`、`fill/3,4`；
  - `sanitize_file_name/1`；
  - 签名 URL 装饰；
  - 大小和页数限制，文案对齐 I§5.1–§5.4。
- [x] 文件 id 用 UUID 正则校验，不匹配时返回 404 `File not found`。

验收：ct 测试导入 → 读取 → 幂等重放 → 填表命名（` — filled.pdf`），以及并发 keyed 导入时只落一份。

## M2-3 PDF sidecar
- [x] `sidecars/pdf/index.mjs`：把原 `packages/integrations/src/pdf.ts` 的 load、inspect、fill（含剥离 JS 动作、Helvetica 外观）和 createSamplePdf 移植成 JS，按 `{packet,4}` 帧收发 JSON。
- [x] `muse_pdf`：端口池（2 个），单次调用 20 秒超时，超时后重启端口进程；`inspect/1`、`fill/2`；PdfError 映射为 `{error, {422, Msg}}`；Erlang 侧先检查大小和 `%PDF-` 头。
- [x] 生成 `apps/muse_integ/priv/sample-permission-slip.pdf`，检查结果为 6 个字段、2 页。

验收：移植 `pdf.test.ts`，包括加密、XFA、未知字段、类型错误、超长值、填表后 JS 动作被移除。

## M2-4 Docker 电脑
- [x] `computer/` 镜像构建：`make computer-image`，产出 `openmuse-computer:local`。
- [x] `muse_docker`：用 erlexec 调用 docker，参数数组严格按 I§6.4；环境变量白名单；分别采集 stdout 和 stderr；超时后杀掉。
- [x] `muse_computer_provider` behaviour，以及 `muse_computer_docker` 实现：
  - status、start、stop、exec；
  - files：list、read、write、mkdir、read_pdf、write_pdf，通过 files.py 的 stdin JSON 调用，超时 8 秒。
- [x] `muse_computer`（对应 computer.ts）：
  - lease 记录（180 秒）；
  - 执行前写 receipt，执行后更新；
  - 幂等键重放；
  - 输出截断；
  - 中断语义：电脑已停止时标记为 interrupted；调用方取消时停止容器；
  - snapshot（I§6.1–§6.8）。
- [x] `import_pdf/3`、`export_pdf/2`：在 Documents 和 `/workspace` 之间传 PDF。

验收（ct，加 `computer` 标签，设置 `MUSE_TEST_DOCKER=1` 时启用）：
- 隔离检查：无网络、只读根文件系统、非 root、pids 上限，对照原 `apps/computer/smoke.test.ts`；
- 命令超时；
- 同一个 operation id 只执行一次；
- 符号链接和路径穿越被拒绝。

## M2-5 浏览器 worker 客户端
- [x] 远程安装 chromium：`cd sidecars/browser-worker && npm ci && npx playwright install chromium`。提供 `make sidecars` 和 `scripts/run-browser-worker.sh`，脚本里生成 WORKER_TOKEN（至少 32 字符）。远程 Node 是 v20，不支持 `--experimental-strip-types`，改用 `npx tsx src/index.ts` 启动，或者安装 Node 22。
- [x] `muse_browser`：
  - reachable 缓存；
  - 请求超时 45 秒；
  - 错误映射（非 2xx 报 502，连不上报 503）；
  - 每个会话串行化（`muse_browser_serial`）；
  - create、reopen、navigate、read、close、preview、input、imports、observe、observe_for_thread；
  - 归属记录在调用 worker 之前写入（I§7.2–§7.3）。
- [x] 签名控制台 HTML：逐字节复刻 I§7.5，带 CSP 头。

验收：
- ct 中用 cowboy 起一个假 worker，测试错误映射、串行化、归属；
- 设置 `MUSE_TEST_BROWSER=1` 时连接真实 sidecar，读取一个公共页面；
- 访问内网地址时报 BLOCKED_URL。

## M2-6 Google
- [x] `muse_google_auth`：
  - connect（PKCE S256，state 10 分钟，按需申请 scope，包括 `calendar.calendarlist.readonly`）；
  - callback（generation 校验，生成新 connectionId，用 vault 加密存储）；
  - access_token（刷新时用 `muse_store:update` 对 connectionId 做条件写）；
  - disconnect，并让绑定在旧连接上的待执行工作失效（I§9.1–§9.4）。
- [x] `muse_gmail`：搜索、线程、`map_message`（I§9.7）、附件下载、`send_email` 的 MIME 构造（I§9.8）、草稿。
- [x] `muse_gcal`：日历列表、事件列表（calendarRange 校验）、创建、更新、删除（含 RecurringEventError）。
- [x] `GoogleApiError` 映射为 502，文案为 `Google API (<status>): <detail>`。

验收：移植 `google.test.ts` 和 `oauth.test.ts` 的离线用例，HTTP 用 meck 打桩 `beamai_http`。MIME 输出与原实现逐字节一致（取 3 组用例）。

## 验收记录（2026-10-22）

- 门禁：xref 0、dialyzer 0；eunit 共 441 个用例，0 失败（muse_integ 部分：workspace、files、browser、pdf、docker、computer、google 各套件）。
- 真实环境 ct：
  - `muse_computer_SUITE`（`MUSE_TEST_DOCKER=1`，10 个用例）：隔离（uid 1000、只读根、无网络、pids 128、无 capability）、超时、幂等、符号链接和 `..` 拒绝、PDF 导入导出、停止中断、调用方死亡即停容器、重启后 /workspace 保留。
  - `muse_browser_SUITE`（`MUSE_TEST_BROWSER=1`，真实 worker + chromium）：打开、读取、截图、滚动、关闭，以及访问 127.0.0.1 和 192.168.x 被拦截。
- 与 Node 的逐字节对照：
  - Google：MIME 4 组、日期 6 组、邮件解析 21 组（在 Node 24 中直接运行原 TS 代码生成）；
  - 时区：`muse_tz` 与 `Intl.DateTimeFormat` 的 72 组对照；
  - 浏览器控制台 HTML：由原 `browserConsole()` 渲染成模板。

## 实现中的发现与偏差

1. **新增 `muse_tz`**（muse_core）：读取系统 `/usr/share/zoneinfo` 的 TZif v2 文件，并支持 POSIX 尾部规则，替代 JS 的 `Intl`。用于时区校验、`localDateTime` 和服务器时区。
2. **新增 `muse_google_ws`**：工作区 live 模式的适配层，与 workspace 期望的签名一一对应。
3. **Google 错误形状**：除 `{Status, Msg}` 外，还有 `{outcome_unknown, Msg}`（写操作可能已到达 Google，不得重试）和 `{internal, Msg}`。`muse_google_api:http_error/1` 负责映射。M3 的审批和 M5 的 HTTP 层都要处理这两种。
4. **Google 的 HTML 转文本**用了一个小型 tokenizer（原项目用 parse5），12 组 HTML 向量一致；字符集支持 UTF-8、windows-1252、UTF-16，其他字符集降级处理。
5. **PDF sidecar** 在第一次使用时才启动端口；没有 node 时返回 502 `PDF helper is unavailable`，不影响应用启动。
6. **docker exec 偶发 runc 启动失败**（`OCI runtime exec failed ... read init-p`，退出码 126）：命令根本没有运行，所以 `muse_computer_docker` 遇到这种错误会自动重试 2 次。
7. **浏览器 worker**：远程 Node 是 v20，`scripts/run-browser-worker.sh` 会自动改用 `npx tsx` 启动。chromium 已通过 `npx playwright install chromium` 安装，没有安装额外的系统依赖也能运行。
8. **浏览器会话串行化**改用 `global:trans` 按会话 id 加锁。和原来的 Promise 队列不同，这里不严格保证 FIFO，但同一会话上的操作仍然互斥。
9. **工作区 seed** 需要提交提案，而提案属于 muse_engine（M3）。为了避免依赖倒置，`ensure_sample/2` 改为接收一个 propose 回调。
10. **容器创建时加 `--init`（原项目没有，属于修复）**：原镜像的 PID 1 是 `sleep infinity`，它不回收孤儿进程。被杀掉或超时的命令留下的子进程会变成僵尸，持续占用 128 的 pids 上限，最终任何 exec 都无法 fork（M3 期间的全量 ct 偶发失败就是这个原因，已用实验复现）。现在由 docker-init（tini）作为 PID 1 回收僵尸。隔离测试断言 `HostConfig.Init = true`。修复后全量 ct（含 Docker 与真实浏览器）连续两次 37/37 通过。注意：修复之前已经创建的容器不会自动带上 `--init`，需要删除后重建。
