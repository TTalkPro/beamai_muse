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

## M13-3 任务失败分析（大连 7 日行程任务）
线上唯一的任务 6 次运行后以 `Request timeout` 失败，计划步骤一个都没完成：
- [x] **搜索卡住**：80 次 `search_web` 里 32 次等满 45 s。端点本身 1–3 s 返回（curl、Python）；在 muse 自己的代码里复现 3/10。跟踪发现 `beamai_mcp_client` 每 100 ms 以 `recv(0, _)` 轮询，传输层在一次轮询里收到部分响应体后返回 `{error, timeout}` 且不带 state，已收到的分块随之丢失；约 40 KB 的搜索结果分多块到达时，最后只剩尾巴，不是合法 JSON，`tools/call` 永远等不到回复。已写 beamai_extra feedback `feedbacks/2026-10-27-mcp-http-recv-poll-drops-body-chunks.md`。
- [x] **一次模型超时就判死**：`muse_task_model:loop/6` 把任何模型错误（包括 beamai 标为可重试的 `Request timeout`）直接 `muse_agent_service:fail/1`，不重试。
- [x] **重启打断**：同一天 5 次 `Resumed work`，对应部署时的 muse 重启；每次续跑都从计划和搜索重新开始。
- [ ] 修复（等用户确认方案）。
