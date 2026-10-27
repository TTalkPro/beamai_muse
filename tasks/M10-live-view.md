# M10 实时画面（VNC）

用户提出（2026-10-27）：浏览器控制台无法做拖拽交互，问能否用 xvnc + websocket 提升交互能力；同意方案“容器内 x11vnc（inetd）+ muse 转发 WebSocket + 页面嵌 noVNC”，并要求桌面电脑一起覆盖。设计见 designs/04 §4.1、designs/05 §5.1。

## M10-1 容器内的 x11vnc
- [x] `browser/Dockerfile`、`computer/Dockerfile.desktop` 加装 `x11vnc`；不常驻、不监听端口。
- [x] `muse_docker:vnc_args/2`：`docker exec -i … python3 -c <socketpair 中继> x11vnc -inetd -display :0 -nopw -q -o /tmp/x11vnc.log -xkb -nosel -noxrecord -nonap -wait 10 -defer 10`，`view_only` 加 `-viewonly`，`clip` 加 `-clip`。
- [x] `muse_docker:stream/1`：erlexec 流式 exec，链接到调用者，stdout 作为消息，stderr 丢弃。
- [x] browserd `show`：提起会话窗口，返回裁到 1440×900 的窗口矩形；`muse_browser:vnc/2`（revive）、`muse_browser_docker:vnc_args/2`。
- [x] `muse_computer_desktop:vnc/2`：桌面开启、电脑运行中（409），`control` 决定只看与否。

## M10-2 WebSocket 中转
- [x] `muse_vnc_handler`（`/vnc/browser/:id`、`/vnc/computer/:id[?control=1]`）：cookie（401）、同站（403）、归属（404）、运行（409）；字节原样转发；30 秒 ping + 记使用；每分钟重查 cookie（4401）；x11vnc 退出关闭（1000）；连接关闭停 exec。
- [x] 空闲：浏览器画面打开即算在用（`muse_browser_docker:touch/1`）；桌面只在操作时（`muse_computers:touch/2`）。

## M10-3 页面
- [x] noVNC 1.7.0 原样放进 `apps/muse_web/priv/static/novnc`（`scripts/vendor-novnc.sh`，MPL-2.0）。
- [x] muse.js `muse-vnc`：动态加载 noVNC、缩放、只看、断线重连 4 次后给“重新连接”按钮；`url`/`viewOnly` 属性变化即重连。
- [x] 浏览器控制台：实时画面替换截图、逐键转发、特殊键和滚动按钮；保留地址栏、“发送文字”（中文等）、读取正文、导入下载。去掉 `muse_ui_browser:scale/1`、`key_input/2` 和 `muse_browser_pool:press/3`、`release/2`。
- [x] 电脑页桌面卡片：实时画面，默认只看，“操作桌面”/“只看”切换（`desktop_control` 动作改 `data-ah-url`、`data-ah-view-only`）。

## M10-4 测试与文档
- [x] eunit：`muse_docker_tests:vnc_args_test_`、`muse_browser_docker_tests` 的 `vnc_args`。
- [x] CT：`muse_ui_pages_b_SUITE:browser_live_view`、`muse_ui_desktop_SUITE:desktop_live_view`/`desktop_control`（gun WebSocket，`muse_docker:stream/1` 换成回显 shell，`muse_vnc_test`）。
- [x] 文档：designs/04 §4.1、designs/05 §1/§3/§5/§5.1、docs/browser.md、docs/computer.md、docs/DIFFERENCES.md、browser/README.md、README。
- [x] 真实容器（2026-10-27）：两个镜像重建后 `make acceptance` 32/32，新增的 4 项经 WebSocket 完成 RFB 3.8 握手（浏览器窗口 1288×892，桌面 1280×800，含 control）。发现 x11vnc `-inetd` 不能用管道（libvncserver 对 stdin 做 `recv()` 探测），改为 socketpair 中继。
- [x] 无头 Chrome 打开真实页面（临时脚本，不入库）：控制台和桌面的 noVNC 都连上；在画面上拖动、点 example.com 的 “Learn more” 后会话跳到 iana.org；桌面“操作桌面”后右键弹出 openbox 菜单。发现控制器方法名 `connect` 与 Stimulus 生命周期冲突，已改名。
- [x] 全量门禁（`scripts/check.sh`）：eunit 1006/0 失败，ct 174 通过、40 个环境门控跳过；`MUSE_TEST_DOCKER=1` 的 `muse_computer_desktop_SUITE` 10/10。
- [x] 部署到 `~/apps/muse`（2026-10-27）：`scripts/deploy.sh`，停掉运行中的浏览器容器；健康检查、noVNC 静态文件、`/vnc` 未登录 401 正常。
