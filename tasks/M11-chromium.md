# M11 浏览器换成 Chromium（apt）

用户决定（2026-10-27）：浏览器镜像改用 Debian 软件源里的 Chromium（直接 apt 安装，不再从 dl.google.com 下载 Google Chrome），并让容器里的扩展（WebChat 提取器 + 桥接扩展 `browser/extension/`）在 Chromium 上正常工作。设计见 designs/04 §4“Chromium 的差异”。

## M11-1 镜像
- [x] `browser/Dockerfile`：`apt-get install chromium chromium-l10n`，去掉 curl 和 Chrome 安装包；策略和原生消息宿主清单改到 `/etc/chromium/policies/managed/`、`/etc/chromium/native-messaging-hosts/`。
- [x] 删 `/etc/chromium.d/extensions`；`init.sh` 用 `chromium --enable-remote-extensions`（没有它 Debian 包装脚本会关后台网络并只允许 `--load-extension` 的扩展，强制安装下载不了）。
- [x] `chromium-l10n`：Debian 的 chromium 只有 en-US 界面语言，`--lang=zh-CN` 回落到英文，网站看到的 `navigator.languages` 是 `en-US,en`（`not_automated` 发现）。
- [x] browserd 按 X 窗口类 `chromium` 找窗口。

## M11-2 扩展
- [x] 核对：扩展用到的 tabs、windows、scripting、webNavigation、downloads、nativeMessaging、captureVisibleTab 在 Chromium 156 上与 Chrome 一致，强制安装、原生消息连接、提取、截图、输入都通过真实浏览器测试，扩展代码不用改。

## M11-3 测试与文档
- [x] `muse_browser_SUITE` 进程检查改为 `/usr/lib/chromium/chromium`。
- [x] 文档：docs/browser.md、browser/README.md、designs/00、designs/04 §4、docs/DIFFERENCES.md、README、Makefile、deploy/.env.example。
- [x] 验证（2026-10-27）：真实浏览器 `muse_browser_SUITE`（`MUSE_TEST_BROWSER_IMAGE=muse-browser:local`）11/11；`scripts/check.sh` eunit 1006/0 失败、ct 174 通过（40 个环境门控跳过）；`make acceptance` 32/32；线上卷的副本上启动 Chromium：扩展连上、profile 无报错、Cookies 保留。
- [x] 部署到 `~/apps/muse`，停掉线上旧的 Chrome 浏览器容器（下次使用时在同一个卷上按 Chromium 镜像重建）。

## M11-4 浏览器不加额外限制
用户决定（2026-10-27）：不要对浏览器做额外限制，让它像正常浏览器；网络隔离保留（出口代理），放开 WebRTC。
- [x] 指纹对比（临时探针，不入库）：Chromium 与原 Chrome 相同的有 webdriver=false、5 个插件、PDF 阅读器、zh-CN、H.264/AAC、通知权限一致；不同的只有 Widevine（Chromium 没有）和品牌提示（没有 Google Chrome）。我们自己的限制造成 WebRTC 没有任何候选、QUIC 关闭、开发者工具禁用等。
- [x] `browser/policies.json` 只留 `ExtensionInstallForcelist`、`ProxySettings`、`DownloadDirectory`；`init.sh` 去掉 `--disable-quic`、`--force-webrtc-ip-handling-policy`、`--host-resolver-rules`。
- [x] 复测：WebRTC 有 mDNS 主机候选和公网 srflx 候选；页面请求 `http://192.168.3.13:8787` 仍被代理拦截（`blocked ... BLOCKED_URL`）。
- [x] 文档：docs/browser.md（新增“浏览器本身不加限制”、安全边界）、designs/04 §4、egress.py 和 native-host 的说明。
