# 浏览器（每用户一个 Chrome 容器，不用 CDP）

浏览器是每个用户一个 Docker 容器，里面跑真实的 Google Chrome（有界面，跑在虚拟显示器上），
只通过扩展和 xdotool 控制，完全不用调试协议（CDP）。登录状态存在用户自己的卷里，所有会话共享；
每个浏览器会话（对话的、任务的）是一个 Chrome 窗口。页面内容由 WebChat 的
[`page-markdown.js`](../browser/extension/page-markdown.js)（MIT）提取为 Markdown。

为什么不用 CDP：Playwright 和 CDP 控制的无头 Chromium 在检测页上都会暴露
（`navigator.webdriver`、`HeadlessChrome` 标识、SwiftShader 渲染器、CDP 痕迹），
知乎、CSDN、Medium、搜狗/微信、小红书会直接拦截（2026-10-26/27 的原型对比结论，原型目录已删除）。

## 构建浏览器镜像

在服务器上的源码目录里（`deploy.sh` 不会构建镜像）：

```sh
cd ~/workspace/beamai_muse
make browser-image                 # 等价于 docker build -t muse-browser:local browser
```

构建需要能访问 Debian 软件源和 `dl.google.com`（下载当时最新的 Chrome stable 安装包），
大约几分钟，镜像约 1.1 GB。构建完核对一下：

```sh
docker image inspect muse-browser:local --format '{{.Created}} {{.Size}}'
docker run --rm --entrypoint google-chrome muse-browser:local --version   # 例如 Google Chrome 156.0.8078.47
```

[`browser/Dockerfile`](../browser/Dockerfile) 做的事：

| 步骤 | 说明 |
|---|---|
| 基础镜像 | `debian:bookworm-slim` |
| 系统依赖 | Xvfb、openbox、xdotool、xclip、scrot、Python 3（含 cryptography）、中日韩与 emoji 字体；生成 `zh_CN.UTF-8`，时区 `Asia/Shanghai` |
| Chrome | 从 `dl.google.com` 下载 `google-chrome-stable_current_amd64.deb` 安装，所以**每次构建拿到的是当时最新的稳定版** |
| 扩展打包 | `crxpack.py` 用一次性 key 把 `browser/extension/` 打成 CRX（key 在同一层里丢弃）；扩展 id 由 key 决定，同时写进企业策略 `/etc/opt/chrome/policies/managed/muse.json`（强制安装）和原生消息宿主清单。每次构建扩展 id 都会变，策略和宿主清单跟着变，Chrome 会自动换成新扩展 |
| 程序 | `init.sh`（入口）、`browserd.py`、`ctl.py`、`egress.py`、`native-host` 放在 `/opt/muse-browser/`，只读 |
| 运行身份 | 用户 1000；`/data` 是卷（`HOME`、Chrome profile、下载） |

镜像里没有 Node，宿主机也不需要 Node、Playwright 或 Chromium。

## 更新浏览器镜像

改了 `browser/` 下的任何文件，或者想把 Chrome 升到最新稳定版，重新构建即可：

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
  rebar3 ct --suite=apps/muse_integ/test/muse_browser_SUITE      # 真实 Chrome：11 项
rebar3 release && ./scripts/acceptance.sh                        # 端到端：浏览器 + 电脑
```

两者都用自己的部署 id，结束时只删自己建的容器和卷，不碰线上实例。

## 构建失败时

- `dl.google.com` 或 Debian 源连不上：检查服务器出口网络或代理；Docker 构建走的是 Docker daemon 的网络设置。
- `docker run --rm --entrypoint google-chrome muse-browser:local --version` 报错：说明 Chrome 没装好，看构建日志里 `apt-get install /tmp/chrome.deb` 那一步。
- 容器起来了但扩展没连上（请求一直超时）：`docker logs <浏览器容器名>` 看 `init.sh` 和 browserd 的输出；企业策略在镜像里的 `/etc/opt/chrome/policies/managed/muse.json`。

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
关闭、PDF 下载导入“文件”、签名预览和控制台），只是底层换成了 Chrome 容器。

## 通道

`muse_browser_docker:call/3` 每个请求一次
`docker exec -i <容器> python3 -I /opt/muse-browser/ctl.py`（stdin 一个 JSON，stdout 一行 JSON）
→ browserd 的 unix socket `/tmp/muse/ctl.sock`；扩展经原生消息连到 `/tmp/muse/host.sock`。
两个 socket 在 0700 的 tmpfs 里，页面够不到；容器不发布端口、不挂宿主目录。

## 抓取流程

1. 导航前用出口规则校验网址；扩展用 `chrome.tabs` 打开，等页面加载并稳定（短时间内没有新资源和 DOM 变化）。
2. 扩展用 `chrome.scripting` 在**隔离世界**运行 `page-markdown.js` 的 `extract()`，页面脚本看不到它。
3. 对最终地址再做一次出口校验（防止页面重定向到内网）。
4. 返回 `{ url, title, text, truncated }`，正文最多 30000 字符。

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
`/browser/<id>`。控制台显示该会话窗口的画面（2 秒刷新）：在画面上按下再松开是点击，按住拖动
（移动 6 像素以上）是拖拽，所以滑块验证可以直接在控制台里完成。处理好后点“处理好了，继续”，
智能体用 `read_current_page` 读取当前页面（不重新加载）。

## 安全边界

- 出口：只允许 http/https、80/443 端口；解析后每个地址都必须是公网单播，私有、回环、链路本地、
  元数据地址和 `localhost`/`.local`/`.internal` 等名字都被拒绝；我们发起的导航先过同一套校验。
- 容器：用户 1000、只读根文件系统、tmpfs `/tmp`、`--cap-drop ALL` 且不加回能力、no-new-privileges、
  内存/CPU/pids 限制、`--init`、私有 IPC、不发布端口、不挂宿主目录。
- Chrome 沙箱保持开启（不用 `--no-sandbox`）；seccomp 用 `apps/muse_integ/priv/browser-seccomp.json`
  （Docker 默认规则加上 Chrome 用户命名空间沙箱需要的 clone/unshare/chroot）。
- 页面内容由提取器在隔离世界执行，不接受调用方注入脚本。
