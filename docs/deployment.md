# 部署

## 依赖

目标机器需要：OTP 27+、rebar3、GNU make、cmake、C++23 编译器、ICU 开发包、zlib 开发包、
Node 22.6+ / npm、rsync、openssl。启用 Docker 电脑或浏览器 worker 时还需要 Docker CLI 与
Docker Engine（以生产用户确认 `docker info` 可用）。

## 首次部署

```sh
./scripts/deploy.sh ~/apps/muse
vi ~/apps/muse/.env            # 填模型、PUBLIC_API_URL 等
~/apps/muse/bin/muse start     # 浏览器容器由 muse 按需启动
~/apps/muse/bin/muse status
```

`scripts/deploy.sh [APP_DIR]`（默认 `~/apps/muse`）执行的动作：

1. 必要时执行 `make sidecars`（PDF 与邮件辅助程序）。浏览器镜像要单独 `make browser-image`；启用了浏览器而镜像缺失时脚本会提醒。
2. `rebar3 compile`；生成 CSS；`rebar3 as prod tar`。
3. 停掉正在运行的旧实例。
4. 解包新 release 到 `APP_DIR/rel`。
5. 同步 sidecar（`sidecars/pdf`、`sidecars/mail`）和控制脚本到 `APP_DIR`；删掉旧版本留下的浏览器 worker 文件。
6. 生成适配当前用户和路径的 systemd unit 到 `APP_DIR/systemd/`。
7. 首次安装时按 `deploy/.env.example` 生成 `APP_DIR/.env`，填入随机生成的密钥。

后续重新部署不会覆盖 `.env` 和 `data/`。脚本不会构建 Docker 电脑镜像，
也不会把服务注册进 systemd。

## 目录结构

| 路径 | 内容 |
|---|---|
| `rel/` | 自带 ERTS 的 release |
| `bin/muse` | 启停脚本（start、stop、restart、status、logs、remote、foreground、worker-foreground） |
| `sidecars/` | PDF 辅助程序、邮件辅助程序、浏览器 worker 源码 |
| `data/` | 数据目录（Mnesia、bitcask、浏览器 profile） |
| `.env` | 配置（首次生成，之后保留） |
| `systemd/` | 生成的 systemd unit 文件 |
| `logs/` | 浏览器 worker 日志 |
| `run/` | PID 文件 |

## systemd

```sh
sudo cp ~/apps/muse/systemd/*.service /etc/systemd/system/
~/apps/muse/bin/muse stop    # 如果刚才用 bin/muse 启动过
sudo systemctl daemon-reload
sudo systemctl enable --now muse.service
```

启用 systemd 后只通过 systemctl 控制服务，不要混用 `bin/muse start`。

## 浏览器镜像

`deploy.sh` 不会构建浏览器镜像。`.env` 里 `BROWSER_ENABLED=true` 时，在生产服务器的源码目录里手动构建：

```sh
(cd /path/to/beamai_muse && make browser-image)   # muse-browser:local
```

以后改了 `browser/` 或要升级 Chrome，重新执行这一条即可，不用重新部署；已有的浏览器容器会在下次启动时自动换成新镜像。
详见 [docs/browser.md](browser.md) 的“构建浏览器镜像”和“更新浏览器镜像”。

## Docker 电脑镜像

`deploy.sh` 不会构建电脑镜像。在生产服务器的源码目录里手动构建：

```sh
(cd /path/to/beamai_muse && make computer-image)           # 轻量版
(cd /path/to/beamai_muse && make computer-desktop-image)   # 桌面版
```

详见 [docs/computer.md](computer.md)。

## OpenAI 兼容网关

```bash
MODEL=openai/<模型 id>
OPENAI_BASE_URL=http://host:port/v1
OPENAI_API_KEY=...
OPENAI_CHAT_COMPLETIONS=true
```

release 的工作目录是 `APP_DIR/rel`，所以 `.env` 里的路径都要写绝对路径。
Mnesia 数据和 `MUSE_NODE_NAME` 绑定，首次启动后不要再改节点名。
