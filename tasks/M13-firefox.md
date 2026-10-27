# M13 浏览器换成 Firefox ESR；任务失败分析

用户决定（2026-10-27）：浏览器换成 Firefox，配合 page-markdown.js；同时分析任务为什么总是失败。设计见 designs/04 §4.3。

## M13-1 为什么换
- [x] 排查微信公众号文章 `环境异常`：同一台机器、同一网络、同一虚拟显示器上，全新 profile 的 Chromium（原样 / 去掉代理 / 去掉剩余启动参数）、Google Chrome（原样 / 去掉代理）、宿主机自己的 Google Chrome 151 都被转到验证页；显卡标识改成和宿主机一致（M12-6）也一样。全新 profile 的 Firefox ESR 140 直接显示正文。用户在宿主机桌面上用 Firefox 也能正常打开。

## M13-2 Firefox ESR
- [x] `browser/Dockerfile`、`computer/Dockerfile.desktop`：`firefox-esr firefox-esr-l10n-zh-cn`，去掉 chromium、`/etc/chromium.d` 处理、`python3-cryptography`；策略 `distribution/policies.json`、首选项 `defaults/pref/muse.js`、原生消息宿主 `/usr/lib/mozilla/native-messaging-hosts/`；桌面镜像 openbox 规则改为 `firefox-esr` 窗口类。
- [x] 扩展：MV2 持久后台页、固定 id、`B = browser || chrome`；`xpipack.py` 打 XPI，放进系统作用域（profile 里的未签名扩展被 `ERROR_SIGNEDSTATE_REQUIRED` 拒绝）；`extensions.autoDisableScopes=0`、`Extensions.Locked`。删掉 `crxpack.py`。
- [x] 导航：Firefox 把上一页未完成的加载以主框架 `NS_BINDING_ABORTED`（"Error code 2152398850"）报出来，原来会被当成新导航失败（example.com 交替失败）；现在“中止”只用来识别下载，否则继续等新页面。
- [x] `init.sh`：`firefox-esr --profile $DATA/firefox --no-remote`，清理残留的 `lock`/`.parentlock`，`MOZ_CRASHREPORTER_DISABLE=1`；browserd 按窗口类 `firefox` 找窗口。
- [x] 测试：`muse_browser_SUITE:hardening` 改查 `firefox-esr --profile /data/firefox`、无 `-marionette`/`--remote-debugging`/`-headless`，内容进程在自己的用户和网络命名空间；`muse_computer_desktop_SUITE:browser_in_desktop` 改查 Firefox 进程。
- [x] 冒烟（临时容器）：扩展 2 秒内连上；example.com、example.org、维基百科、iana.org 连续导航都成功；截图 1280×800；点击、`show` 正常；微信公众号文章直接读到正文。

- [x] 测试（2026-10-27）：`muse_browser_SUITE`（真实 Firefox）11/11；`muse_computer_desktop_SUITE`（真实 Docker）11/11；`scripts/check.sh` eunit 1006/0 失败、ct 174 通过（41 个环境门控跳过）；`make acceptance` 32/32。修了两处 Firefox 差异：下载目录改用 `DownloadDirectory` 策略（`DefaultDownloadDirectory` 被下载管理器的默认文件夹覆盖，文件落到 ~/下载）；`egress_blocked` 改为检查“被代理拒绝或浏览器自己拒绝（混合内容）”，不再要求每个目标都出现在代理日志里。
- [ ] 部署（等用户确认）。

## M13-3 任务失败分析（大连 7 日行程任务）
线上唯一的任务 6 次运行后以 `Request timeout` 失败，计划步骤一个都没完成：
- [x] **搜索卡住**：80 次 `search_web` 里 32 次等满 45 s。端点本身 1–3 s 返回（curl、Python）；在 muse 自己的代码里复现 3/10。跟踪发现 `beamai_mcp_client` 每 100 ms 以 `recv(0, _)` 轮询，传输层在一次轮询里收到部分响应体后返回 `{error, timeout}` 且不带 state，已收到的分块随之丢失；约 40 KB 的搜索结果分多块到达时，最后只剩尾巴，不是合法 JSON，`tools/call` 永远等不到回复。已写 beamai_extra feedback `feedbacks/2026-10-27-mcp-http-recv-poll-drops-body-chunks.md`。
- [x] **一次模型超时就判死**：`muse_task_model:loop/6` 把任何模型错误（包括 beamai 标为可重试的 `Request timeout`）直接 `muse_agent_service:fail/1`，不重试。
- [x] **重启打断**：同一天 5 次 `Resumed work`，对应部署时的 muse 重启；每次续跑都从计划和搜索重新开始。
- [x] 修复 1（搜索）：beamai_extra 已在 `4369404`（v2.1.1）修复（`recv/2` 新增 `{wait, State}`、按 `stream_ref` 过滤迟到事件），muse 升级 beamai_tools/beamai_mcp/beamai_agui 到该版本（同时升级 aihtml/aihtml_cowboy 到 `b4d3439`）。在 muse 的代码路径里 15 次搜索都在 1–2 秒内返回，不再有 45 秒的悬挂；当时的返回是 Parallel 免费额度用尽（`retry-after` 约 44 分钟，今天的排查用掉了额度），建议配置 `PARALLEL_API_KEY`。已部署。
- [x] 修复 2（模型故障）：`muse_task_model` 对可重试的模型失败（`beamai_llm_error:retryable/1`）退避后开新一轮从保存的进度继续（Retry-After，或 30/60/90 秒），连续 3 次才失败（`model_retries` 应用环境可调，测试用）；不可重试的（401 等）照旧立即失败。新配置 `MODEL_TIMEOUT_SECONDS`（默认 180 秒）作为每次模型请求的超时（beamai 默认 60 秒）。
- [x] 修复 3（续跑）：第二次及以后的拾起（重启后恢复、再次拾起）如果已有进度，第一轮带“[Resumed]”说明和带编号的计划；新增 `update_plan` 工具；`set_plan` 同名步骤保留状态；系统提示要求用 update_plan 记录进度、续跑时从第一个未完成的步骤接着做。计划行改为 `- [id] 标题 (状态)`。
- [x] 部署（2026-10-27）：三个修复与依赖升级都已上线（beamai_mcp 2.1.1）。
- [x] 测试：`muse_task_model_SUITE` 新增 `model_error_retried`、`model_error_not_retryable`、`model_error_gives_up`、`resumed_task_continues`（16/16）；脚本模型支持 `{error, Reason}`。

## M13-4 重跑后的修复（2026-10-27）
- [x] **桌面电脑里的代理连不上**：桌面镜像的全局策略强制所有 Firefox 走 `127.0.0.1:8118`，智能体自己另开的 Firefox 也被套上，但出口代理只为 muse 的会话启动。桌面镜像去掉策略里的 `Proxy`，`init.sh --embedded` 把代理写进 muse 自己 profile 的 `user.js`；原生消息宿主只在 `MUSE_BROWSER_INSTANCE=1` 的实例里工作。5 台桌面电脑按新镜像重建（卷保留）。
- [x] **首次导航失败**：新开窗口的第一次导航偶尔以代理 502 结束。出口代理日志显示是连上游时一次连接一直没有回应（等满 20 秒），随后一个新连接立刻成功。`egress.py` 的 `connect_upstream` 每次连接最多等 7 秒，超时、拒绝、不可达都换新连接再试，共 3 次并记日志；`browserd.py` 的 `op_open` 在新窗口里导航失败时再试一次，失败和被拦截的终点都记日志。`test_egress` 新增 3 个用例（16/16）；用新镜像起 10 个全新容器各做两次打开，20/20 成功。
- [x] **写文件时参数丢失**：智能体多次调用 `write_computer_file` 都缺 `text`。原因是 beamai 的 chat-completions 默认 `max_tokens` 4096，推理模型的思考加一章长内容超出后，回复被截在工具调用参数里。新增 `muse_model_info`：启动时和每天从 models.dev（`MODELS_DEV_URL`）同步模型目录、缓存到 `DATA_DIR/models-dev.json`，按模型 id 取输出上限（优先厂商自己的条目），回复上限取它、最多 32768，查不到时 16384；`MODEL_MAX_TOKENS` 可覆盖。`muse_model_info_tests` 5 个用例。
- [x] **模型请求超时**：回复变长后 180 秒不够（qwen3.8-flash 经网关约 51 token/s）。超时默认按回复上限推算（每秒 30 token 加 2 分钟，至少 180 秒；32768 时约 20 分钟），`MODEL_TIMEOUT_SECONDS` 可覆盖。
- [x] **连接被关掉就判失败**：`{gun_error, closed}` 被 beamai 归为未知错误、不重试。`muse_task_model` 把连接断开（closed、reset、refused、gun 错误）按可重试处理；新增用例 `model_connection_closed_retried`（17/17）。断开的根源是 litegate 的 `upstream_timeout_ms` 默认 5 分钟，已在 `~/workspace/litegate/deploy/litegate.env` 设 `LITEGATE_UPSTREAM_TIMEOUT_MS=1200000` 并重建 litegate 容器。
- [x] **PDF 导出超时**：`export_computer_pdf` 总是 `PDF helper timed out`。线上 `.env` 是按旧安装目录生成的，`PDF_SIDECAR` 指向不存在的 `/home/david/app/muse/sidecars/pdf/index.mjs`，Node 一启动就退出（小文件报 exited unexpectedly，大文件报超时）。已改成 `~/apps/muse` 下的路径并重启；`scripts/deploy.sh` 现在会检查 `.env` 里 `PDF_SIDECAR`/`MAIL_SIDECAR` 指向的文件是否存在并警告。
- [x] 重跑结果：大连 7 日行程任务成功，6 个计划步骤全部完成，产出 Markdown、HTML 和 39 页 PDF；PDF 已导入“文件”。

