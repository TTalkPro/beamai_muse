# Docker 电脑

"电脑"不是托管服务，而是由本机 Docker daemon 启动的普通容器。每个对话或后台任务
第一次需要电脑时，`muse_computer_pool` 用 `docker container create` 创建容器，并给它
一个独立的 `/workspace` volume。

## 镜像变体

| 变体 | 构建命令 | Dockerfile | 默认镜像 |
|---|---|---|---|
| 轻量版：命令行、Python 和文件桥 | `make computer-image` | [`computer/Dockerfile`](../computer/Dockerfile) | `openmuse-computer:local` |
| 桌面版：轻量版 + X 桌面 | `make computer-desktop-image` | [`computer/Dockerfile.desktop`](../computer/Dockerfile.desktop) | `openmuse-computer-desktop:local` |

## 镜像生成流程

1. 以 `node:22.22.0-bookworm-slim` 为基础，安装 bash、Python 3、git、coreutils、CA 证书
   和 curl。桌面版另装 Xvfb、openbox、xterm、xdotool、scrot、mupdf、CJK 字体和
   LibreOffice Writer/Calc。
2. 把 [`computer/files.py`](../computer/files.py) 复制到 `/opt/openmuse/files.py`。
   这个脚本按 stdin/stdout 交换 JSON，是 Erlang 与容器之间的文件桥：
   读/写文件（≤ 10 MB）、导出 PDF、以及扫描回复产物用的 `changed_since`。
   桌面版还会复制 `desktop-init`、`gui`、`Xresources` 和 openbox 菜单。
3. 创建 `/workspace` 并声明为 Docker volume，工作目录设为 `/workspace`，
   容器进程使用 `1000:1000`。
4. 轻量版入口点是 `sleep infinity`，只保持容器运行；桌面版入口点是
   `/opt/openmuse/desktop-init`，后台启动 Xvfb 和 openbox，然后等待 Xvfb；
   Xvfb 退出时容器退出。

## 配置镜像

构建后把镜像 tag 填到 `.env`：

```bash
COMPUTER_IMAGE=openmuse-computer:local
COMPUTER_DESKTOP_IMAGE=openmuse-computer-desktop:local   # COMPUTER_DESKTOP=true 时生效
```

两个值默认就是上表的本地 tag。镜像名会做格式校验（`^[a-zA-Z0-9][a-zA-Z0-9._/:@-]{0,250}$`），
非法值返回 503。

镜像必须对 Muse 调用的 Docker daemon 可见；`DOCKER_HOST` 或 `DOCKER_CONTEXT` 选择默认 daemon，
这两个环境变量会传给 Docker CLI。

## 镜像更新

启动一台停着的电脑时，Muse 用 `docker image inspect` 取当前镜像的 id，与容器 inspect 里的
`Image` id 比较；不同（比如 `make computer-image` 之后）就只删容器、在同一个 `/workspace`
卷上按新镜像重建再启动。运行中的电脑不受影响，下次停后再启动时更新。
任一 id 取不到就照旧启动旧容器。

来源与改动记录见 [`computer/SOURCE.md`](../computer/SOURCE.md)。
