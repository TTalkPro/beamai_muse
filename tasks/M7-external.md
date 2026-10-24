# M7 外部 SDK 依赖项：Jev live

> 设计：[03-agent.md](../designs/03-agent.md) §9
> 规格：E§10.7

## M7-1 E2B 桌面：取消 ❌ 2026-10-23
用户决定不支持 E2B。已实现的 sidecar、provider、桌面动作、UI 和测试已全部删除，并做了以下调整：
- `COMPUTER_PROVIDER` 只接受 `docker`；
- 删除了 `/api/computer/desktop*` 路由，现在返回 404；
- 删除了 `use_desktop` 工具和卡片；
- 电脑工具说明只保留 Docker 版本，聊天步数上限固定为 6。

## M7-2 Jev live ✅ 2026-10-23
- [x] 用 `npm pack @typesafe-ai/sdk`（0.7.0）取得源码，确认 HTTP 接口：
  - 请求：`POST {TYPESAFE_BASE_URL}/v1/systemone`，默认 `https://api.typesafe.ai`；`Authorization: Bearer KEY`；body 为 `{model, state, questions}`；
  - 题目形如 `{type: choice|score, instructions, criteria}`，choice 的 criteria 是"标签 → 描述"的 map，score 的 criteria 是按分值排列的列表；
  - 重试：传输错误和 408/429/5xx 会重试，退避从 500ms 开始翻倍、加 25% 抖动，遵守 `Retry-After`（不超过 60s），重试时带 `X-TypeSafe-Retry-Count`。
- [x] `muse_jev_typesafe`（实现 `muse_jev_adapter` behaviour）：
  - 超时 5 秒，重试 1 次；confidence 低于 0.5 时沿用 agent 预备的 control；选项按位置引用（标签不进题目）；
  - 校验错误和 provider 错误的文案与 OpenMuse 逐字一致；`JEV_MODE=live` 时 `for_mode(live)` 指向它；
  - 新增配置项 `TYPESAFE_BASE_URL`。
- [x] `muse_jev_typesafe_tests`：请求形状、低置信回退、分数小数保留、各类无效回答、503 重试一次后报可重试、超时重试后成功、401 不重试、429 可重试、无可用 control。
- 验收 ✅ 2026-10-23：用户提供的兼容端点 `http://192.168.3.13:4000/v1/systemone`（模型 `decision-model-preview`）。
  - curl 直接调用：返回的形状与 SDK 协议一致，延迟约 60 ms；
  - `live_smoke_test_` 通过：传入 `TYPESAFE_API_KEY`、`TYPESAFE_BASE_URL`、`JEV_MODEL` 环境变量运行，key 不写进仓库；
  - 端到端：在 `JEV_MODE=live` 下真实调用 `present_choices` 工具，得到 `mode: live` 的面板。对"Something hands-on for my 10 year old"的打分为 touch 2.26、kelp 1.55、film 0.92；按 OpenMuse 的规则（四舍五入到档位再排序，同档保持原顺序），前两个同为 2 档，保持 agent 给出的顺序。
- 修正：smoke 测试原来没有启动 `beamai_core`（`beamai_http` 的连接池在其中），会报 `pool_not_started`；正式运行时 beamai_core 总是已启动，不受影响。

## M7-3 Docker 桌面变体 ✅ 2026-10-23

> 2026-10-23 补充：beamai 升级到 `4d6181c`（2.0.2）后，`use_desktop` 把截图作为图片交给模型。`muse_chat_SUITE:desktop_screenshot_reaches_model` 验证三点：模型下一次请求里带有图片部件，AG-UI 事件只有文本，历史只有文本。

用户决定：分成两个 Dockerfile。轻量镜像（`computer/Dockerfile`，362 MB）保持现状；重量镜像（`computer/Dockerfile.desktop`，1.26 GB）用轻量窗口管理器 openbox 提供图形桌面，不支持 E2B。
- [x] 镜像 `openmuse-computer-desktop:local`：
  - 包含 Xvfb（1280×800）、openbox、xdotool、scrot、DejaVu 和 Noto CJK 字体、xterm、mupdf、LibreOffice Writer/Calc；
  - `computer/desktop-init` 在只读根目录下启动 Xvfb `:0` 和 openbox；
  - 构建命令 `make computer-desktop-image`。
- [x] 配置：`COMPUTER_DESKTOP=true` 开启（取值不是 true/false 时报 "COMPUTER_DESKTOP must be true or false"），`COMPUTER_DESKTOP_IMAGE` 指定镜像；`COMPUTER_PROVIDER` 仍然只接受 `docker`。
- [x] 容器：
  - 与轻量版相同的加固（无网络、只读根目录、cap-drop ALL、no-new-privileges、`--init`、不映射端口）；
  - 资源为内存 1536m（swap 同值）、进程 512、CPU 2、/tmp 256 MiB；容器环境带 `DISPLAY=:0`；
  - 用标签 `dev.openmuse.variant=desktop` 区分，挂载时校验所选变体的限制、入口和环境，遇到另一种变体的容器就拒绝，并提示删除容器（/workspace 卷会保留）；
  - 轻量版的 argv 逐字节不变。
- [x] 桌面动作（`muse_computer_desktop`）：
  - 通过 `docker exec` 执行固定的 bash 脚本，用户输入只作为位置参数传入；先用 xdotool 释放修饰键、等待 0.5 s 后执行动作，再用 scrot 截图；
  - schema 和文案沿用 OpenMuse；receipt 为 `computer-desktop-actions`；截图存储方式同规格；重复的 operationId 不会再次发送输入；
  - 动作在电脑租约内执行，执行期间运行命令会得到 409 busy。
- [x] **安全加固（OpenMuse 没有）**：xdotool 会把参数里的命令名（不区分大小写）当作链式命令执行，例如 `key -- shift exec touch x` 会真的执行 `touch`。现在拒绝等于或作为前缀匹配 xdotool 命令名的按键名，沿用原有文案，唯一受影响的真实按键是 `Help`。`type` 的文本作为单个参数传入，不受影响。
- [x] `use_desktop` 工具：只在桌面变体下提供，位于 import 和 export 之间。
  - 结果与 OpenMuse 一致：文本部件加截图图片部件（beamai 2.0.2 的 `{parts, _}`），模型在当前这一步看到截图，历史和 AG-UI 事件只保留文本；文本中额外带 `screenshotUrl` 供聊天卡片显示。（最初 beamai 的工具结果只能是文本，那时只返回签名 URL；反馈后 beamai `4d6181c` 支持了图片，已升级。）
  - 为桌面变体单独编写了模型说明，以 OpenMuse 的 E2B 说明为蓝本（去掉联网、浏览器和公开端口）：动作前先看截图，每次动作后检查返回的截图，只描述截图里确实有的内容，优先用快捷键，不需要界面时用 headless LibreOffice。轻量版仍用 OpenMuse 的原文。
  - 开启桌面时聊天步数上限为 16，否则为 6。
- [x] API `/api/computer/desktop*`：状态、动作、截图（截图路径可签名，`no-store`）；变体关闭时返回 404。
  - 额外提供 `?live=1`：取一帧新画面，不占租约、不写 receipt、不落盘，供页面轮询；这样从终端打开的程序也能显示出来。
- [x] UI：电脑页的桌面卡片，截图每 2 秒轮询，可点击截图（读 `pointer`）、输入、按键、滚动、手动截图；聊天里有 `use_desktop` 卡片。
- [x] 测试：
  - eunit：`muse_computer_desktop_tests`，以及 config、docker、tools 测试中的扩展；
  - `muse_ui_desktop_SUITE`：用 meck 模拟 Docker；
  - **真实 Docker** `muse_computer_desktop_SUITE`（8 个，`MUSE_TEST_DOCKER=1`）：在 192.168.3.13 上通过，覆盖隔离参数、屏幕尺寸 1280×800、窗口管理器、JPEG 截图、在 xterm 中输入（`$(id)` 按字面写入文件）、幂等重放、中文字体、LibreOffice 转 PDF、拒绝另一种变体、停止后重启；轻量版 `muse_computer_SUITE` 10/10 仍然通过。
