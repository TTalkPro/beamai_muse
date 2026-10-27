# 浏览器（每用户一个 Firefox 容器，不用远程调试协议）

浏览器是每个用户一个 Docker 容器，里面跑有界面的 Firefox ESR（Debian 软件源里的 `firefox-esr` 包，
跑在虚拟显示器上），只通过扩展和 xdotool 控制，完全不用远程调试协议（没有 Marionette、WebDriver BiDi、CDP）。登录状态存在用户自己的卷里，
所有会话共享；每个浏览器会话（对话的、任务的）是一个浏览器窗口。页面内容由 WebChat 的
[`page-markdown.js`](../browser/extension/page-markdown.js)（MIT）提取为 Markdown。

为什么不用 CDP：Playwright 和 CDP 控制的无头 Chromium 在检测页上都会暴露
（`navigator.webdriver`、`HeadlessChrome` 标识、SwiftShader 渲染器、CDP 痕迹），
知乎、CSDN、Medium、搜狗/微信、小红书会直接拦截（2026-10-26/27 的原型对比结论，原型目录已删除）。

为什么是 Firefox（M13，2026-10-27）：同一台机器、同一网络、同一虚拟显示器上，全新 profile 的 Google Chrome、
Chromium（不管有没有我们的代理、启动参数，显卡标识改成和宿主机一致也一样）打开微信公众号文章都会被转到
“环境异常 / 去验证”页，全新 profile 的 Firefox ESR 直接显示正文。之前是 Chrome（M9-16）、Chromium（M11）。

## 构建浏览器镜像

在服务器上的源码目录里（`deploy.sh` 不会构建镜像）：

```sh
cd ~/workspace/beamai_muse
make browser-image                 # 等价于 docker build -t muse-browser:local browser
```

构建只需要能访问 Debian 软件源（`apt-get install firefox-esr firefox-esr-l10n-zh-cn`，trixie-security
跟着上游 ESR 更新），大约几分钟，镜像约 1 GB。构建完核对一下：

```sh
docker image inspect muse-browser:local --format '{{.Created}} {{.Size}}'
docker run --rm --entrypoint firefox-esr muse-browser:local --version   # 例如 Mozilla Firefox 153.5.1esr
```

[`browser/Dockerfile`](../browser/Dockerfile) 做的事：

| 步骤 | 说明 |
|---|---|
| 基础镜像 | `debian:trixie-slim`（和宿主机一样是 Debian 13：同一版 Mesa 25.0.7；加 `libpci3`，浏览器能从 /sys 读到显卡（宿主机的 VMware SVGA II，15ad:0405）的 PCI 标识，WebGL 与宿主机上的浏览器一致（Mesa llvmpipe，LLVM 19.1.7）） |
| 系统依赖 | Xvfb、openbox、xdotool、xclip、scrot、x11vnc、Python 3、中日韩与 emoji 字体；生成 `zh_CN.UTF-8`，时区 `Asia/Shanghai` |
| Firefox | `apt-get install firefox-esr firefox-esr-l10n-zh-cn`：**每次构建拿到的是 Debian 当时的 ESR**。`firefox-esr-l10n-zh-cn` 提供中文界面（网站看到的 Accept-Language 也跟着是中文）。托管策略写到 `/usr/lib/firefox-esr/distribution/policies.json`，默认首选项写到 `defaults/pref/muse.js`（[`browser/prefs.js`](../browser/prefs.js)） |
| 扩展 | [`xpipack.py`](../browser/xpipack.py) 把 `browser/extension/`（MV2，固定 id `bridge@beamai-muse.invalid`）打成 XPI，放进 Firefox 的**系统作用域** `/usr/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/`：Debian 的构建在这里接受未签名扩展（和 Debian 的 `webext-*` 包一样；放进 profile 的未签名扩展会被 `ERROR_SIGNEDSTATE_REQUIRED` 拒绝）。`extensions.autoDisableScopes=0` 让它首次启动就启用，策略 `Extensions.Locked` 让它不能被移除。原生消息宿主清单在 `/usr/lib/mozilla/native-messaging-hosts/`（`allowed_extensions` 是这个 id） |
| 程序 | `init.sh`（入口）、`browserd.py`、`ctl.py`、`egress.py`、`native-host` 放在 `/opt/muse-browser/`，只读 |
| 运行身份 | 用户 1000；`/data` 是卷（`HOME`、浏览器 profile、下载） |

镜像里没有 Node，宿主机也不需要 Node、Playwright 或浏览器。

## 更新浏览器镜像

改了 `browser/` 下的任何文件，或者想把 Firefox 升到 Debian 的最新 ESR，重新构建即可：

```sh
cd ~/workspace/beamai_muse && make browser-image
```

不需要重新部署，也不需要重启 muse。已有的浏览器容器这样换新（`muse_browser_docker`）：

- **停着的容器**：下次用到时，muse 发现容器的镜像 id 和 `muse-browser:local` 不一样，就删掉容器、在同一个卷上用新镜像重建。登录状态和下载都在卷里，不受影响。
- **运行中的容器**：不会被打断，空闲 `BROWSER_IDLE_MINUTES`（默认 30 分钟）自动停止后，下次用到时按上一条重建。
- **想立刻换新**：确认没人在用浏览器后，手动停掉运行中的浏览器容器，下次用到时就会重建：

```sh
docker ps --filter label=dev.openmuse.managed=browser-v1 --format '{{.Names}} {{.Image}} {{.Status}}'
docker stop $(docker ps -q --filter label=dev.openmuse.managed=browser-v1)
```

不要 `docker volume rm` 浏览器卷：那会清掉该用户所有网站的登录状态。

改了 `apps/` 下的 Erlang 代码（比如 `muse_browser*`）才需要按 [deployment.md](deployment.md) 重新部署。

## 验证

```sh
make browser-image
MUSE_TEST_BROWSER=1 MUSE_TEST_BROWSER_IMAGE=muse-browser:local \
  rebar3 ct --suite=apps/muse_integ/test/muse_browser_SUITE      # 真实 Firefox：11 项
rebar3 release && ./scripts/acceptance.sh                        # 端到端：浏览器 + 电脑
```

两者都用自己的部署 id，结束时只删自己建的容器和卷，不碰线上实例。

## 构建失败时

- Debian 源连不上：检查服务器出口网络或代理；Docker 构建走的是 Docker daemon 的网络设置。
- `docker run --rm --entrypoint firefox-esr muse-browser:local --version` 报错：说明 Firefox 没装好，看构建日志里 `apt-get install` 那一步。
- 容器起来了但扩展没连上（一直“The browser is still starting”）：看容器里的 `/tmp/muse/browserd.log`（应有 `extension connected`）和 `/tmp/muse/browser.log`；在浏览器里打开 `about:policies`（“错误”一栏）和 `about:addons` 看扩展有没有装上、有没有被禁用。

## 运行时配置

| 变量 | 说明 |
|---|---|
| `BROWSER_ENABLED` | `true` 时启用（默认 `false`） |
| `BROWSER_IMAGE` | 镜像 tag（默认 `muse-browser:local`） |
| `BROWSER_IDLE_MINUTES` | 用户多少分钟没有浏览器活动就停止其容器（默认 30，卷保留） |
| `BROWSER_NETWORK` | 容器的 Docker 网络（默认 `bridge`，不能是 `host` 或 `none`） |

容器由 muse 在第一次用到时启动（`muse_browser_docker`），`bin/muse` 不需要单独启动任何浏览器进程。
镜像更新或设置变化后，停着的容器下次启动时自动删掉重建（卷保留）。
浏览器容器带标签 `dev.openmuse.managed=browser-v1`，不算进电脑池的 `COMPUTER_MAX_RUNNING`。

## 使用

```sh
~/apps/muse/bin/muse restart  # 只有改了 .env 才需要
docker ps --filter label=dev.openmuse.managed=browser-v1   # 正在运行的浏览器容器
```

`muse_browser` 的接口和 `/api/browsers/*` 与 OpenMuse 兼容（会话、读取、截图、输入、导航、
关闭、PDF 下载导入“文件”、签名预览和控制台），只是底层换成了浏览器容器。

## 浏览器跑在哪个容器里

- 对话（或任务）**已经有桌面版电脑**时，它的浏览器会话就跑在这台电脑里：桌面镜像
  `openmuse-computer-desktop:local` 也装了同一套浏览器（Firefox ESR、扩展、browserd、出口代理），
  这样一个对话的命令、图形程序和网页都在同一个容器里，电脑页的桌面画面里也能看到浏览器。
  任务委派自对话时用那个对话的电脑，否则用任务自己的电脑（`muse_task_model:computer_scope/2`）。
- 没有电脑、电脑是轻量版、没开 `COMPUTER_DESKTOP` 或 `COMPUTER_NETWORK=none` 时，用每个用户
  一个的共享浏览器容器（`muse-browser:local`）。API 和网页追踪打开的会话也在共享容器里。
- 每次请求都重新判断：对话后来才有了电脑，下一次使用时会话就搬过去，在电脑里按最后的网址重新打开，
  共享容器里的旧窗口会被关掉；电脑被删除后再搬回共享容器。电脑停着会先被启动。
- **登录状态不随会话搬家**：电脑里的浏览器用这台电脑自己的 profile（`/workspace/.muse-browser`），
  和共享容器、其他电脑互不相通，在这个对话里需要重新登录一次。
- 电脑里的浏览器在第一次用到时才启动（`ctl.py --embedded` 启动 `init.sh --embedded`，约几秒），
  窗口占满 1280×800 的桌面，页面区域约 1271×707（截图和点击坐标都按这个大小）；下载放在
  `/workspace/Downloads`，智能体在终端里也能用。
- 电脑容器因此加了浏览器的 seccomp 配置（浏览器沙箱需要用户命名空间）、512 MiB `/dev/shm`，内存上限
  2560 MiB、pids 1024。旧的桌面电脑容器在镜像重建后、下次启动时自动按新设置重建（卷保留）；
  还没重建的运行中电脑继续用共享浏览器容器。
- 归属记录 `browser-placement/<会话>`：`scope`（创建时的电脑范围）和 `host`（现在在哪：`own`
  或 `computer:<id>`）。

## 通道

`muse_browser_docker:call/3` 每个请求一次
`docker exec -i <容器> python3 -I /opt/muse-browser/ctl.py`（stdin 一个 JSON，stdout 一行 JSON）
→ browserd 的 unix socket `/tmp/muse/ctl.sock`；扩展经原生消息连到 `/tmp/muse/host.sock`。
两个 socket 在 0700 的 tmpfs 里，页面够不到；容器不发布端口、不挂宿主目录。

## 抓取流程

1. 导航前用出口规则校验网址；扩展用 `tabs` API 打开。
2. 等页面**展示完成**再读：标签页加载完（`status` 为 `complete`，load 事件已触发），并且网络安静
   800 毫秒（没有请求开始或结束；开了 5 秒以上的长连接、流不算），最多等 10 秒。这些都在页面外面判断
   （`tabs` 和只观察的 `webRequest`），加载过程中不往页面里注入任何脚本；是不是 PDF
   也看响应头的 `Content-Type`，不注入脚本。
3. 然后才用 `scripting` 在**内容脚本沙箱**（隔离世界）注入并运行 `page-markdown.js` 的 `extract()`，页面脚本看不到它。
   提取器按“导航不是正文”丢掉 `<nav>`、导航角色和 class；如果这样剩下的不到 600 字符、而页面上看得见的
   文字多得多（门户页、导航站，比如维基百科门户页的语言链接全在 `<nav>` 里），就以整页为根、保留导航再抽一遍
   （广告、页脚、侧栏、隐藏内容照旧丢），结果更长才采用；正常文章页不受影响。
   人在控制台操作后读页面（`read_current_page`）也一样先等页面展示完成。
4. 对最终地址再做一次出口校验（防止页面重定向到内网）。
5. 返回 `{ url, title, text, truncated }`，正文最多 30000 字符。

## 输入、拖拽与接管

| 类型 | 实现 | 说明 |
|---|---|---|
| `click` | xdotool 移动并点击 | 先把该会话的窗口提到前台，页面坐标换算成屏幕坐标 |
| `drag` | xdotool 按下 → 连续移动 → 松开 | 滑块验证码等拖动控件 |
| `text` | 剪贴板粘贴或逐字键入 | ≤ 10000 字符 |
| `key` | xdotool 按键 | 白名单内的按键 |
| `scroll` | xdotool 滚轮 | 纵向 |

智能体的输入带缓动和抖动的鼠标轨迹、逐键延迟；人在控制台的输入直接转发。

遇到登录、验证码或付款确认时，智能体调用 `request_takeover`，对话里出现求助卡片，指向控制台
`/browser/<id>`。控制台是该会话浏览器窗口（含工具栏）的实时画面（VNC，见下节）：点击、拖动
（滑块验证按真实轨迹）、hover、滚轮、右键和键盘都直接到达页面。中文等需要输入法的文字用画面上方的
“发送文字”（粘贴）。处理好后点“处理好了，继续”，智能体用 `read_current_page` 读取当前页面（不重新加载）。

## 实时画面（VNC）

- 浏览器镜像装了 `x11vnc`，但不常驻、不监听端口：每打开一个控制台，muse 执行一次
  `docker exec -i <容器> x11vnc -inetd -display :0 -clip <窗口矩形> …`，RFB 走 exec 的 stdin/stdout，
  由 `/vnc/browser/<id>`（`muse_vnc_handler`）转成 WebSocket 给页面里的 noVNC。关掉页面，exec 和 x11vnc 一起结束。
- 打开时 browserd 的 `show` 把该会话窗口提到最前并报告窗口矩形；同一用户的其他会话窗口被智能体
  操作时可能盖上来，刷新控制台即可。
- 打开着的控制台算浏览器在用（每 30 秒记一次），不会因 `BROWSER_IDLE_MINUTES` 被停掉。
- 旧镜像没有 `x11vnc`：控制台会显示“画面连接已断开”。重新 `make browser-image`，停着的容器下次启动时自动重建。
- 排错：容器内日志在 `/tmp/x11vnc.log`（`docker exec <容器> cat /tmp/x11vnc.log`）。

## 浏览器本身不加限制

浏览器按普通浏览器的默认行为运行（2026-10-27 用户决定）。托管策略 `browser/policies.json` 只有三项，
都是 muse 自己的功能需要的：

| 策略（`policies.json`） | 用途 |
|---|---|
| `Extensions.Locked` | 桥接扩展不能被移除（没有它就没法控制浏览器） |
| `Proxy` | 所有 HTTP(S)/WebSocket 走容器内的出口代理（见下节） |
| `DownloadDirectory`、`PromptForDownloadLocation` | 下载固定到 `/data/downloads`（桌面电脑里是 `/workspace/Downloads`）、不弹保存框，“导入下载”从这里取 PDF |
| `RequestedLocales` | 中文界面 |

默认首选项（`prefs.js`，普通默认值，不锁定）只有：首次启动直接启用系统作用域里的桥接扩展、不出现欢迎页/隐私说明/默认浏览器提示、
崩溃后不自动恢复窗口（muse 自己按最后网址重开会话）、localhost 也走代理。开发者工具、其他扩展、密码管理器、翻译、
`about:` 页面、WebRTC、DNS 都是 Firefox 的默认状态；启动参数只有 `--profile` 和 `--no-remote`。

## 安全边界

- 出口：浏览器的 HTTP(S) 和 WebSocket 都经过出口代理，只允许 http/https、80/443 端口；解析后每个地址都必须是公网单播，私有、回环、链路本地、
  元数据地址和 `localhost`/`.local`/`.internal` 等名字都被拒绝，所以页面访问不了局域网和本机（包括 muse 自己）；我们发起的导航先过同一套校验。
- WebRTC 按浏览器默认行为直接走 UDP（STUN/DTLS），不经过代理：它不会暴露内网地址，也发不出 HTTP 请求，但 UDP 包本身能到达任何地址（包括局域网）。这是为了让 WebRTC 像普通浏览器一样（用户选择保留隔离、放开 WebRTC）。
- 容器：用户 1000、只读根文件系统、tmpfs `/tmp`、`--cap-drop ALL` 且不加回能力、no-new-privileges、
  内存/CPU/pids 限制、`--init`、私有 IPC、不发布端口、不挂宿主目录。
- 浏览器沙箱保持开启（Firefox 的内容进程在自己的用户和网络命名空间里）；seccomp 用 `apps/muse_integ/priv/browser-seccomp.json`
  （Docker 默认规则加上浏览器用户命名空间沙箱需要的 clone/unshare/chroot）。
- 页面内容由提取器在隔离世界执行，不接受调用方注入脚本。
