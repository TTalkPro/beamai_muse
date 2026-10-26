# M8 验收、文档与回收

## M8-1 端到端验收（对照原 README「Try it」与 docs/VERIFICATION.md）
- [x] sample 模式：permission slip 全流程，在 UI 动作上跑通（`muse_ui_pages_a_SUITE`）；聊天入口和流式卡片在 `muse_ui_chat_SUITE` 中覆盖。
- [x] 追踪告警：README"Try it"第 2 步在 UI 中复现（`muse_ui_pages_a_SUITE`）。
- [x] finance 示例：从聊天的委派表单用示例交易创建任务（`muse_ui_chat_SUITE`），引擎侧执行见 `muse_finance_tests` 和 `muse_engine_SUITE`。
- [ ] model 模式（真实 key）：读取 Hacker News、总结 copilotkit.ai，并接管浏览器。还需要模型 key；浏览器 worker 和接管控制台已在 `make acceptance` 中用真实 worker 验证。
- [x] 真实 sidecar 端到端：`scripts/acceptance.sh`（`make acceptance`），在 sample 模式下用真实浏览器 worker 和 Docker 桌面电脑通过 HTTP 跑 20 项检查，结束后清理容器和卷。
- [x] live 模式启动校验：访问 key、加密 key、UI secret（`muse_config_tests`，`muse_core_SUITE:config_error_stops_boot`）。
- [x] 重启恢复：执行中的审批在重启后变为 outcome_unknown（`muse_core_SUITE:app_boot_and_durability`）；运行中的任务通过租约过期被接管（`muse_engine_SUITE:lease_takeover`）。

## M8-2 门禁与质量
- [x] `scripts/check.sh`：compile 0 warning、xref 0、dialyzer 0、eunit 和 ct 全部通过（2026-10-23：eunit 888，ct 103 通过，14 个依赖外部环境的用例跳过）。
- [x] 对照 04-integrations §7 的安全检查清单逐项自查（独立只读审查后修复了 5 类问题，结论见 04-integrations §7）。

## M8-3 文档
- [x] README（中英文）：功能表、架构图、快速开始（sample 模式和 live 模式）、sidecar 说明、配置表。
- [x] `docs/DIFFERENCES.md`：与 OpenMuse 的差异，包括 00-overview §6 和实现过程中新发现的差异（同源界面与 cookie 会话、终端非实时、MCP 客户端、Jev 直接调 HTTP、不支持 E2B 等）。

## M8-4 回收临时方案
- [x] aihtml 修复 feedback 中的问题后，删除 muse.js 里对应的临时方案（muse-shot、muse-keys、muse_ui_gate）。2026-10-23 aihtml `ccb8bcf` 后已完成。
- [x] beamai_extra 修复 MCP 客户端后，切回 beamai_mcp。2026-10-26：`muse_search` 改用 `beamai_mcp_client`，删除 `muse_mcp_http` 及其测试，live suite 也走 `beamai_mcp_client`。中途 2.0.1 的客户端会吞错误，写了 feedback `2026-10-26-mcp-client-swallows-errors.md`，beamai_extra 2.1.0（`799383e`）已全部修复，报错文案（含 HTTP 响应体）与调用方退出即关连接都恢复到原来的严格测试。
