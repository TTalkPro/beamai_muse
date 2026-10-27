# browser/：浏览器镜像

每个用户一个容器的浏览器镜像（`BROWSER_ENABLED=true` 时由 muse 按需启动）：真实的 Google Chrome
跑在虚拟显示器上，只通过扩展和 xdotool 控制，不用 CDP。

```sh
make browser-image      # docker build -t muse-browser:local browser
```

| 文件 | 作用 |
|---|---|
| `Dockerfile` | Debian + Chrome stable + Xvfb/openbox/xdotool + 字体；打包扩展并写入企业策略和原生消息宿主清单 |
| `init.sh` | 入口：虚拟显示器、openbox、出口代理、browserd、Chrome（退出后自动重启） |
| `browserd.py` | 容器内守护进程：会话窗口、xdotool 输入（点击、拖拽、键入、按键、滚动）、下载 |
| `ctl.py` | muse 经 `docker exec` 调用的入口，转发到 browserd 的 unix socket |
| `native-host`、`native-host.json` | Chrome 原生消息宿主：扩展 ↔ browserd |
| `extension/` | MV3 扩展：打开页面、提取正文（`page-markdown.js`，来自 WebChat，MIT）、截图 |
| `crxpack.py`、`policies.json` | 打包扩展、企业策略强制安装 |
| `egress.py` | 出口代理：只允许公网 http/https |
| `openbox.xml` | 窗口管理器配置 |
| `tests/` | 出口规则的单元测试 |

构建、更新、验证和排错见 [docs/browser.md](../docs/browser.md)。
