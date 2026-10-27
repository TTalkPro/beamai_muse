# browser/：浏览器镜像

每个用户一个容器的浏览器镜像（`BROWSER_ENABLED=true` 时由 muse 按需启动）：有界面的 Firefox ESR（Debian 的 `firefox-esr` 包）
跑在虚拟显示器上，只通过扩展和 xdotool 控制，不用 CDP。

```sh
make browser-image      # docker build -t muse-browser:local browser
```

桌面版电脑的镜像（`make computer-desktop-image`）也装了这里的全部文件，对话的浏览器会话在那台电脑里运行
（见 [docs/browser.md](../docs/browser.md)“浏览器跑在哪个容器里”）。

| 文件 | 作用 |
|---|---|
| `Dockerfile` | Debian 13 + Firefox ESR（apt，含 `firefox-esr-l10n-zh-cn`）+ Xvfb/openbox/xdotool + 字体；扩展打包进 Firefox 的系统作用域，写入策略、默认首选项和原生消息宿主清单 |
| `init.sh` | 入口：虚拟显示器、openbox、出口代理、browserd、Firefox（退出后自动重启）；`--embedded` 是桌面电脑里的浏览器（用桌面的显示器，数据在 /workspace） |
| `browserd.py` | 容器内守护进程：会话窗口、xdotool 输入（点击、拖拽、键入、按键、滚动）、下载、`show`（控制台实时画面前把窗口提到最前） |
| `ctl.py` | muse 经 `docker exec` 调用的入口，转发到 browserd 的 unix socket；`--embedded` 在桌面电脑里按需启动浏览器，`--if-running` 不启动也不等待 |
| `native-host`、`native-host.json` | 原生消息宿主：扩展 ↔ browserd |
| `extension/` | MV3 扩展：打开页面、提取正文（`page-markdown.js`，来自 WebChat，MIT）、截图 |
| `xpipack.py`、`policies.json`、`prefs.js` | 打包 XPI、Firefox 策略（代理、下载、语言、锁定扩展）、默认首选项 |
| `egress.py` | 出口代理：只允许公网 http/https |
| `openbox.xml` | 窗口管理器配置 |
| `tests/` | 出口规则的单元测试 |

构建、更新、验证和排错见 [docs/browser.md](../docs/browser.md)。
