# 浏览器 worker（WebChat/CDP Docker）

浏览器 worker 用 Docker 容器里的 headless Chromium 代替 Playwright。每个会话启动一个独立
Chromium 进程和 user-data-dir；页面内容由 WebChat 插件的 [`page-markdown.js`](../sidecars/webchat-browser/vendor/page-markdown.js)
提取为 Markdown。

## Docker 镜像生成

```sh
make browser-image
```

等价于：

```sh
docker build -t beamai-muse-browser-worker:local sidecars/webchat-browser
```

镜像内容（[`Dockerfile`](../sidecars/webchat-browser/Dockerfile)）：

| 步骤 | 说明 |
|---|---|
| 基础镜像 | `node:22-bookworm-slim`；运行时由镜像内 Node 22 直接执行 TypeScript |
| 系统依赖 | Debian `chromium`、CA 证书、Liberation/Noto/CJK 字体、emoji 字体 |
| npm 依赖 | `chrome-remote-interface@0.34.0`（`npm ci --omit=dev --ignore-scripts`，锁定版本） |
| 复制文件 | `src/`（worker 逻辑）和 `vendor/`（WebChat 提取器 + 许可证） |
| 运行用户 | `node`（非 root） |
| 数据卷 | `/data`（存放每个会话的 Chromium profile） |
| 端口 | 8790 |
| 健康检查 | `GET /health`，30 秒间隔 |

## 运行时配置

镜像本身不需要配置；worker 的运行参数在 `.env`：

| 变量 | 说明 |
|---|---|
| `BROWSER_WORKER_URL` | Erlang 应用连接 worker 的地址，如 `http://127.0.0.1:8790`；设置后 `bin/muse start` 会同时启动 worker 容器 |
| `WORKER_TOKEN` | Bearer 认证 token（≥ 32 字符），首次部署时自动生成 |
| `DATA_DIR` | 会话 profile 存放位置：`DATA_DIR/browser-profiles/<session-id>/profile` |
| `WORKER_MAX_SESSIONS` | 同时活跃的浏览器会话上限（默认 3） |
| `WORKER_IDLE_MINUTES` | 空闲多少分钟后自动关闭会话（默认 30） |
| `BROWSER_WORKER_IMAGE` | 覆盖镜像 tag（默认 `beamai-muse-browser-worker:local`，`run-browser-worker.sh` 读取） |

容器运行参数由 `scripts/run-browser-worker.sh` 固定：只读 rootfs、`--cap-drop=ALL`、
`no-new-privileges`、内存 2 GB、PID 上限 1024、端口只绑定 loopback。

## 使用

```sh
# 修改 worker 代码后重建镜像并重启
make browser-image
~/apps/muse/bin/muse restart

# 验证 worker 健康
curl http://127.0.0.1:8790/health
```

HTTP API 与 OpenMuse 兼容（详见 [`sidecars/webchat-browser/README.md`](../sidecars/webchat-browser/README.md)）：

| 端点 | 方法 | 说明 |
|---|---|---|
| `/sessions` | POST | 创建会话并导航到 `url` |
| `/sessions/:id/read` | GET | 注入 WebChat 提取器，返回 Markdown |
| `/sessions/:id/screenshot` | GET | PNG 截图 |
| `/sessions/:id/input` | POST | 点击、输入、按键、滚动 |
| `/sessions/:id/navigate` | POST | 导航到新 URL |
| `/sessions/:id/close` | POST | 关闭 Chromium，保留 profile |

## WebChat 注入与抓取流程

### 注入时机

WebChat 提取器**不是**在导航时注入的。它没有用 `Page.addScriptToEvaluateOnNewDocument`
做持久化注入，而是每次调用 `GET /sessions/:id/read` 时通过 CDP 的 `Runtime.evaluate`
临时注入到当前页面：

1. worker 启动时把 `vendor/page-markdown.js` 读为字符串，缓存。
2. 每次 `read` 时，第一次 `Runtime.evaluate` 把整份源码注入页面**主世界**，
   定义 `window.__webchatMarkdown`。
3. 第二次 `Runtime.evaluate` 调用 `window.__webchatMarkdown.extract({ maxChars: 100000 })`，
   返回 `{ url, title, markdown, truncated }`。

导航到新页面后，前一次注入的脚本随页面销毁；下次 `read` 时重新注入。

### 抓取流程

1. 读取 `location.href`，非 `about:blank` 时做 SSRF 校验（DNS 解析后必须是公网 IP）。
2. 注入 extractor。
3. 执行 `extract()`。
4. 对 extractor 返回的 `url` 再次做 SSRF 校验（防止页面重定向到内网）。
5. Markdown 超过 100,000 字符则截断，`truncated: true`。
6. 返回 `{ id, url, title, text, truncated }`。

## 输入能力与拖拽验证

`POST /sessions/:id/input` 支持的输入类型：

| 类型 | CDP 调用 | 说明 |
|---|---|---|
| `click` | `Input.dispatchMouseEvent`（mousePressed + mouseReleased） | 点击坐标；headless 下补充 `elementFromPoint().click()` |
| `text` | `Input.insertText` | 输入文本（≤ 10,000 字符） |
| `key` | `Input.dispatchKeyEvent` | Enter、Tab、Escape、方向键、Ctrl+a 等；单字符 |
| `scroll` | `Input.dispatchMouseEvent`（mouseWheel） | 纵向滚动（deltaY ≤ 5000） |

**不支持 `mouseMoved`**。拖拽验证（滑块验证码）需要 mousePressed → 连续 mouseMoved
轨迹 → mouseReleased 三步，当前 worker 和浏览器控制台页面（`/browser/<id>`）都没有实现
这个输入类型。智能体和人工接管界面都无法完成拖拽验证。

遇到滑块验证码时的现状：

- 智能体调用 `request_takeover`，在对话里显示求助卡片，指向 `/browser/<id>`。
- 用户打开控制台后同样只能点击/输入/按键/滚动，无法拖拽。
- 实际可行的做法是用户在自己的本机浏览器里打开同一个 URL，手动完成验证后，
  回到对话点"处理好了，继续"，智能体用 `read_current_page` 读取结果。

如果将来需要支持拖拽验证，可以在 worker 的 input handler 里增加 `drag` 类型，
用 CDP 的 `Input.dispatchMouseEvent`（`mousePressed` → 多次 `mouseMoved` 插值 →
`mouseReleased`）模拟轨迹，同时在 UI 控制台的截图上增加 pointerdown/move/up 事件转发。

## 安全边界

- worker 只绑定 loopback；Bearer token 用常数时间比较。
- Chromium 通过 worker 内的 SSRF egress proxy 访问公网，目标是 DNS 解析后的公网 IP；
  私网、loopback、非 80/443 目标被拒绝。
- 每个会话是独立 Chromium 进程和 user-data-dir。
- 输入使用 CDP；页面内容由 WebChat extractor 在主世界执行，不接受调用方注入脚本。
- 浏览器求助走 `request_takeover` 工具，对话里出现卡片指向 `/browser/<id>` 控制台。
