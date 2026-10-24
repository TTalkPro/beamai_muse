# 在 beamai 中发现、尚未上报的问题

已按用户要求写入 `beamai/feedbacks/2026-10-23-assistant-text-dropped-with-tool-calls.md`。**beamai `805b0ac`（2.0.1）已修复**，muse 已把 beamai_core、beamai_llm、beamai_agent 升级到该版本；`muse_chat_SUITE` 和 `muse_ui_chat_SUITE` 断言这句文本会保留在历史里。下面保留摘要。

## 1. 同一回合"文本 + 工具调用"的文本没有写进历史

- **症状**：sample 模式下发送"Complete the permission slip"，实时流里能看到"I found the permission slip. …"，刷新页面后这句话不见了，只剩下任务卡片。
- **位置**：`beamai_core/apps/beamai_core/src/llm/beamai_message.erl` 中的 `base_from_response/1`。响应带 tool_calls 时只调用 `tool_calls/1`，生成 `#{role => assistant, content => null, tool_calls => ...}`，`beamai_chat_response:content/1` 被丢掉了。
- **影响**：
  - 所有"先说一句话再调工具"的回复（Anthropic、OpenAI 都很常见）在历史里都会丢掉那句话，UI 重绘和下一轮回放给模型时都缺这段；
  - 不报错。
- **建议**：带 tool_calls 时保留文本，即 `#{role => assistant, content => Content | null, tool_calls => TCs}`。各 provider 的适配器在序列化时已经能处理 content 与 tool_calls 并存。
- **muse 侧现状**：已随 beamai 2.0.1 修复，不需要绕过。
- **回放侧**：`beamai_llm_message_adapter:to_anthropic_message/1` 的 tool_calls 分支也不发 text 块，所以即使 `from_response` 修好了，Anthropic 回放时仍会丢掉这段文本。OpenAI 的 chat 和 Responses 两种格式已经能同时带上文本和 tool_calls。
