# M12 浏览器跑在对话的桌面电脑里

用户决定（2026-10-27）：只有一个公共浏览器镜像不够；会话已经关联了桌面版电脑时，直接在这台电脑里运行浏览器，让任务集中在一个容器里。选择：电脑自己的登录状态（profile 在 /workspace，不复制）；桌面保持 1280×800，页面区域缩小；对话后来才有电脑时，下次使用时迁过去。同一轮里用户还要求：page-to-markdown 不要一启动就注入，等页面展示完成再注入。设计见 designs/04 §4.2、docs/browser.md“浏览器跑在哪个容器里”“抓取流程”。

## M12-1 桌面镜像带浏览器
- [x] `computer/Dockerfile.desktop`：BuildKit 命名上下文 `browser`，装 chromium、chromium-l10n、python3-cryptography、xclip、locales、tzdata、字体；打包扩展、托管策略（下载到 /workspace/Downloads）、原生消息宿主；openbox 规则（Chromium 无边框、左上角）；标签 `dev.openmuse.browser=1`。`make computer-desktop-image` 带 `--build-context browser=browser`。
- [x] `init.sh --embedded`、`ctl.py --embedded`（锁 + setsid 按需启动）、`ctl.py --if-running`。
- [x] browserd：`MUSE_BROWSER_LAYOUT`（viewport/screen）、`MUSE_SCREEN`、`MUSE_DOWNLOADS_DIR`；输入按会话实际页面区域校验。扩展 `ensure`/`geometry` 带 layout。
- [x] 电脑容器：桌面版加浏览器 seccomp、512 MiB shm，内存 2560m、pids 1024；附着检查接受新旧两种；`muse_computer_docker:browser_container/1`。

## M12-2 路由与迁移
- [x] `muse_browser_docker:call/3` 按会话选容器（`host/2`），`browser-placement` 记录 scope 和 host，host 变化时关旧窗口，revive 在新容器重开；电脑计为使用；`vnc_args/3`、`touch_session/2`。
- [x] `muse_browser:create/3`、`observe/4`、`scope_of/2`；对话会话记 `thread:<id>`，任务会话记 `muse_task_model:computer_scope/2`。

## M12-3 页面展示完成后再注入
- [x] 扩展：页面是否展示完成在页面外判断（标签页 `status=complete` + `chrome.webRequest` 观察到网络安静 800 毫秒，长连接不算，最多 10 秒），导航后和每次 `read` 前都等；PDF 判断改看响应头；去掉加载时注入的 settle 和 PDF 检测脚本。manifest 加 `webRequest`（只观察）。

## M12-4 测试与文档
- [x] 单元测试：桌面 create 参数、附着检查（新 seccomp 接受、其他配置拒绝）、`vnc_args/3`。
- [x] 真实 Docker：`muse_computer_desktop_SUITE:browser_in_desktop`。
- [x] 文档：docs/browser.md、docs/computer.md、designs/04 §4.2、browser/README.md、computer/SOURCE.md。
- [x] 验证（2026-10-27）：`muse_computer_desktop_SUITE`（真实 Docker）11/11、`muse_browser_SUITE`（真实浏览器）11/11、`scripts/check.sh` eunit 1006/0 失败、ct 174 通过（41 个环境门控跳过）、`make acceptance` 32/32（第一次运行打开 example.com 失败一次，随后连续两次 32/32）。
- [x] 部署到 `~/apps/muse`（2026-10-27），停掉运行中的共享浏览器容器和桌面电脑容器（下次启动时按新镜像和设置重建，卷保留）。

## M12-5 导航页提取不全（实测发现）
用对话实测时，维基百科门户页 `www.wikipedia.org` 只提取到徽标和标题：语言链接全在三个 `<nav>` 里，提取器按“导航不是正文”整块丢掉。
- [x] `page-markdown.js`“导航页第二遍”：第一遍不到 600 字符而页面可见文字（innerText）多于其 3 倍加 300 时，以整页为根、保留 `<nav>`、`navigation/menu/menubar` 角色和 nav/menu 类特征词再抽一遍，更长才采用（`stats.root` 带 `+nav`）。
- [x] 对比（真实页面，旧/新）：维基门户 114 → 706 字符（十种主要语言及条目数链接）；Erlang 词条 52024 字符、example.com 958 字符不变。
- [x] `muse_browser_SUITE:open_read` 断言门户页有 en/zh 语言链接。
