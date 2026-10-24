# M6 aihtml 界面

> 设计：[05-web-ui.md](../designs/05-web-ui.md) §3–§6，ref [aihtml-digest.md](../designs/ref/aihtml-digest.md)
> 参照原前端：openmuse `apps/mobile` 与 `docs/analysis/07-frontend.md`

## M6-0 aihtml feedback（先做）✅ 2026-10-23
- [x] 在 aihtml 源码（`327668d`）中核实 05-web-ui §6 的 6 个缺口，记录文件和行号；6 条全部复现。
- [x] 在 aihtml 仓库建立 `feedbacks/README.md` 索引（按 beamai_extra/feedbacks 的约定，附"做得好的几处"），每个缺口一个文件 `feedbacks/2026-10-23-<slug>.md`，报告人 `beamai_muse`。
- [x] 文件放在 aihtml 工作区，**不做 git 提交**（用户要求）。
- [x] aihtml 已在 `8696f54`/`624f3bf`（锁定 `ccb8bcf`）中实现全部 6 条，muse 已同步依赖并改用新能力。

## M6-1 接入与外壳 ✅ 2026-10-23
- [x] Tailwind 构建：`assets/muse.css`、`scripts/build-css.sh`（npx @tailwindcss/cli，仅构建期需要 Node）。不生成 manifest，`muse_ui_assets:css/0,js/0` 在运行时按内容 hash 生成 `?v=` 参数。
- [x] aihtml 端点鉴权：起初用 `muse_ui_gate` 包装；aihtml 升级（`ccb8bcf`）后改为 `routes(#{authorize => fun muse_ui:authorize/1})`，删掉了 gate。路由排在 `/aihtml/[...]` 静态路由之前。
- [x] 主题 epoch：topic 为 `{muse, Owner, Epoch, Name}`，epoch 存在 `settings/ui-epoch`，登出时轮换。
- [x] `muse_ui`：`owner/1`、`with_owner/2`、`page/5`、`reply_page/6`、`topic/2`、`publish/3`。
- [x] `muse_ui_layout`：sidenav（三组 11 页）、顶部栏（通知未读数、退出）、根节点订阅 `{user}`，`on_event/2` 收到通知时推送 toast 并刷新未读数。
- [x] `/login`、`/logout`（`muse_ui_login`）：原生表单、origin 校验、限流、HttpOnly cookie（PUBLIC_API_URL 为 https 时加 Secure）、302 跳转；`/` 根据是否登录跳到 `/chat` 或 `/login`。
- [x] `priv/static/js/muse.js`：muse-composer、muse-scroll。muse-shot 和 muse-keys 不再需要：aihtml 已提供 `pointer`、`sync => fifo` 和 `prevent_default`。
- [x] `muse_ui_bridge`：每个 owner 一个进程（global 注册，simple_one_for_one），订阅 `muse_events`，把事件分发给导出了 `on_event/2` 的页面模块。
- [x] aihtml 签名 secret：取 `MUSE_UI_SECRET`；示例模式随机生成并保存在 `DATA_DIR/ui-secret`。
- [x] 11 个页面模块先放占位实现（`muse_ui_page` behaviour：`render/2`，可选 `on_event/2`）。
- [x] `muse_ui_SUITE`（6 个用例）：登录页与跳转、登录后 11 页均返回 200 且包含外壳、aihtml 端点 401 与放行、登出轮换 epoch 并使旧会话失效、live 模式访问密钥、静态资源、bridge 启动。

验收：登录、登出、未登录跳转正常；登出后旧标签页收不到推送；每个页面返回 200。

## M6-2 聊天页 ✅ 2026-10-23
- [x] 线程侧栏（`muse_ui_chat`）：主会话、旁支会话、新建、重命名、归档（主会话不可归档）、恢复，BM25 搜索历史（查询转小写）。侧栏订阅 `threads` 主题，`{thread, Id}` 事件到达时 morph 刷新。
- [x] 消息流：从 `muse_chat_log` 渲染历史（用户气泡、markdown_view、工具卡片按 tool_call_id 配对结果）；订阅 `{thread, Tid}`，断线重连时由 refresh 动作重绘 log、队列和按钮。
- [x] 输入框：muse-composer 控制器（Enter 发送，Shift+Enter 换行）；回复期间显示"停止"按钮，发送按钮变成"排队"；停止不清空草稿；待发送队列可见（`pending`）。
- [x] `muse_chat_relay`：每个线程一个进程（global 注册，`running/1`），80ms 合并事件；用 `aihtml_action:text/4` 追加文本，结束时 outer 替换为 markdown；工具先显示占位卡片，有结果后替换；RUN_FINISHED/RUN_ERROR 后恢复按钮并出队下一条。
- [x] `muse_ui_cards`：邮件搜索、邮件线程、日历、browse_web（带接管链接）、search_web、delegate_task/agent_status（优先用 `muse_ui_activity:task_card/2`）、目标、追踪、记忆、Jev 面板、use_desktop、电脑命令回执，其他工具显示 JSON。结果解析失败时不会崩溃。
- [x] 委派任务表单：plan / document（选择带 PDF 的邮件）/ finance（sample 模式下有"试用示例交易"）/ agent；创建后跳到 `/activity/<id>`，校验错误显示在原位。
- [x] Jev 选项面板：点选后发送 `[OpenMuse choice] {...}`，由 `muse_chat:prepare_input` 解析成续写。
- [x] 测试：`muse_ui_chat_SUITE`（5 个：页面与线程、权限单流式推送与重绘、finance 委派、排队自动续发、停止）和 `muse_ui_cards_tests`（8 个）。
- beamai 曾丢弃与工具调用同一回合的文本，导致刷新后这句话消失。已反馈，beamai `805b0ac` 修复后依赖已升级，测试断言这句文本保留在历史中。

验收（手动加 ct 冒烟）：sample 模式下发送"Complete the permission slip"后，出现任务卡片，并且实时更新到等待输入。实时更新到等待输入需要 M6-3 的 `task_card`。

## M6-3 Activity 与审批 ✅ 2026-10-23
- [x] `/activity`：上方是待审批卡片，下方是任务表格（状态 chip），实时更新。`/activity/<id>` 详情包括 prompt、控制按钮、错误和结果、计划（ah_steps）、文件（签名 PDF 链接）、产物、浏览器、运行时间线（ah_timeline，最新在前）。
- [x] 控制按钮：暂停、恢复、重试、取消（取消带确认）。
- [x] 等待输入的表单：按请求字段逐个生成控件（布尔字段用复选框），加一个回答框；没有字段列表的文档任务用 JSON 输入框；按 `muse_task:answer_schema/0` 校验。
- [x] 审批卡片：显示邮件草稿（收件人、主题、正文、附件链接）或事件内容，以及 hash 和过期时间；批准和拒绝都带 hash 调用 `muse_actions:decide/4`，拒绝带确认；决定后显示回执或失败原因，`outcome_unknown` 显示"结果未知"。
- [x] `task_card/2` 供聊天使用，根元素 id 为 `task-card-<Id>`，通过 `{task_card, Id}` 主题实时替换。
- [x] 测试：`muse_ui_pages_a_SUITE`（9 个）。权限单全流程在 UI 动作上跑通：填写字段 → 审批卡片显示草稿、PDF 链接（签名 URL 下载到的是真实 PDF）和 hash → 带 hash 批准 → 回执 → 任务成功。

## M6-4 目标、追踪、Ideas、通知 ✅ 2026-10-23
- [x] 目标页：新建（每行一个里程碑）、里程碑勾选，暂停、完成、恢复、重新打开。
- [x] 追踪页：新建 change / contains / price_below 三种监控；暂停、恢复、立即检查、停止（停止带确认）；最近一次变化用 ah_diff 做词级对比；sample 模式有"测试页面"框，可以保存，也可以保存并检查。
- [x] Ideas 页：证据展示、编辑 prompt 后采纳、忽略、重新查找、已处理列表。
- [x] 通知页：列表、单条已读、全部已读、查看任务；toast 和未读数由 `muse_ui_layout` 负责。
- [x] README"Try it"第 2 步在 UI 中复现：`sample://availability` 监控 → 编辑测试页面 → 保存并检查 → 收到"Dinner"通知，并显示 diff。

## M6-5 文档与电脑 ✅ 2026-10-23
- [x] 文档页：列表（实时）、上传（`POST /upload`：`muse_ui_b_upload` 校验 cookie 和 origin 后复用 `/api/files` 的逻辑）、iframe 预览、字段填写（保存为填好的副本）、导入到电脑。
- [x] 电脑页：状态和启停、终端、懒加载文件树、编辑保存、mkdir、PDF 导入导出；未启用时显示"电脑未配置"。
- 局限：终端输出不是边执行边显示。`muse_computer:execute/3` 在命令结束后才返回，所以动作先显示 `$ cmd`，结束后再用 `text/4` 加 `flush/1` 分块推出输出。要做到实时，需要给 `muse_computer` 加流式钩子（M8 再看）。
- [x] 真实环境验收（`make acceptance`，2026-10-23）：在真实 Docker（桌面变体）上启动电脑，运行 `ls /workspace`，写入并读回含中文的文件，桌面截图，拒绝 xdotool 注入，电脑页正常渲染，停止。

## M6-6 浏览器、应用、设置 ✅ 2026-10-23
- [x] 浏览器页：会话列表、新建；控制台截图用 `poll(2000, …)` 刷新，点击读 `pointer` 并缩放到 1280×800，逐键转发用 `sync => fifo` 加 `prevent_default`，另有文本输入、特殊键、滚动、读取正文、导入下载；worker 未配置时有提示。
- [x] 应用页：Gmail 和 Calendar 的状态，只读或读写连接（live 模式跳转到 Google 授权），断开；sample 模式显示示例连接。
- [x] 设置页：身份、记忆增删改（聊天中保存的记忆会实时推送过来）、主题切换、登出。
- [x] 测试：`muse_ui_pages_b_SUITE`（10 个，浏览器和电脑用假 worker 或 meck）。
- [x] 真实环境验收（`make acceptance`，2026-10-23）：真实 Playwright worker 打开 example.com，读取正文，签名截图是 PNG，控制台按 Tab 加 Enter 跟随链接到 iana.org，截图随之更新，点击、控制台页渲染、关闭会话都正常。连续 3 次 20/20 通过。
