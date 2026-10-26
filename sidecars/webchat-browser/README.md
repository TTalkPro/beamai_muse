# WebChat/CDP 浏览器 worker

这个 sidecar 保留 OpenMuse browser worker 的 HTTP API，但不再使用 Playwright。它在一个 worker 容器里为每个会话启动独立的 headless Chromium，通过 CDP 控制页面，并用 WebChat 插件的 `page-markdown.js` 提取 Markdown。

## Docker 镜像怎么生成

`make browser-image` 等价于：

```sh
docker build -t beamai-muse-browser-worker:local sidecars/webchat-browser
```

[`Dockerfile`](Dockerfile) 的流程是：

1. 基础镜像 `node:22-bookworm-slim`；运行时由镜像内 Node 22 直接执行 TypeScript。
2. 安装 Debian 的 `chromium`、CA 证书和 Noto/Liberation/CJK 字体。Debian 官方源在当前网络不可达时，Dockerfile 会把 apt 源切到 USTC 镜像。
3. `npm ci --omit=dev --ignore-scripts` 安装锁定的 `chrome-remote-interface`。
4. 复制 `src/` 和 `vendor/`；`vendor/page-markdown.js` 来自 `~/workspace/WebChat/extension/content/page-markdown.js`，许可证见 [`vendor/LICENSE`](vendor/LICENSE)。
5. 创建 `/data` volume，以 `node` 用户运行，暴露 `8790`，带 health check。

运行容器时使用只读 rootfs、`--cap-drop=ALL`、`no-new-privileges`、内存/PID 限额、独立 `/tmp` 和 256 MiB shm；这些参数在 `scripts/run-browser-worker.sh` 固定。

## 部署

构建机/服务器先构建镜像：

```sh
make browser-image
```

`BROWSER_WORKER_URL=http://127.0.0.1:8790` 和 32 字符以上的 `WORKER_TOKEN` 配好后，`scripts/deploy.sh` 会构建缺失镜像、同步脚本，并把 worker 装到应用目录；`bin/muse start` 启动它，`bin/muse worker-foreground` 供 systemd 前台运行。会话 profile 在 `DATA_DIR/browser-profiles/<session-id>/profile`，部署时保留 `DATA_DIR`。

## 依赖

- Docker Engine/CLI（生产运行方式）。
- 镜像内：Node 22、Debian Chromium、`chrome-remote-interface`、WebChat extractor；宿主机不需要 npm、Chromium 或 Playwright。
- 本地开发/测试：npm 可安装锁定依赖并执行 `npm run typecheck`；真实运行仍推荐容器，避免宿主 Chromium 差异。

## 安全与边界

- worker 只绑定 loopback，Bearer token 使用常数时间比较。
- Chromium 通过 worker 内的 SSRF egress proxy 访问公网，目标是 DNS 解析后的公网 IP；私网、loopback、非 80/443 目标会被拒绝。
- 每个会话是独立 Chromium 进程和 user-data-dir；不存在多个用户共享同一 Chrome 会话，也不使用 xdotool。
- 输入使用 CDP；页面内容使用 WebChat extractor 在页面主世界执行，不接受调用方注入脚本。
