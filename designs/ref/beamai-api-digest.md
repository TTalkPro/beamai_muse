# BeamAI / beamai_extra API digest (for building beamai_muse)

Sources, read on 2026-10-22 on 192.168.3.13:
- `/home/david/workspace/beamai` @ `08aa844` (v2.0.0 + deepseek update). Apps: beamai_core, beamai_llm, beamai_agent.
- `/home/david/workspace/beamai_extra` @ `bcd77ac` (2.0.0). Apps: beamai_tools, beamai_mcp, beamai_a2a, beamai_agui, beamai_rag.

OTP 27+ is required, because the libraries use the stdlib `json` module. The remote host runs OTP 28 with rebar3 3.24.0.
**[V]** marks a claim I checked by running code on the remote host. The probes are in `/tmp/muse_scratch/*.erl` there. Everything else comes from reading the source.

Treat the docs as partly stale. Where docs and source disagree, this digest follows the source. Known stale points:
- `beamai_llm/README*` uses `llm_client:*`, which no longer exists. Use `beamai_chat_model:*`.
- The top README shows `{role, user, content, ...}` tuples as messages. Messages must be maps.
- The mcp README uses `base_url`. The real key is `url`.
- `beamai_mcp_adapter` docs mention `beamai_agent:start_link`, which does not exist.

---

## 1. Depending on the libs from `/home/david/workspace/beamai_muse`

Use `_checkouts` symlinks. Each umbrella app dir is a standalone OTP app with its own `rebar.config` and no hex deps. beamai_llm has `{path,"../beamai_core"}`, which the checkout satisfies. Do not use beamai_extra's git_subdir deps: they would fetch beamai v2.0.0 from GitHub instead of your local tree. **[V]** I compiled and booted this layout in `/tmp/muse_scratch`.

```sh
mkdir -p /home/david/workspace/beamai_muse/_checkouts && cd $_
for a in beamai_core beamai_llm beamai_agent; do ln -s /home/david/workspace/beamai/apps/$a $a; done
for a in beamai_tools beamai_mcp beamai_agui; do ln -s /home/david/workspace/beamai_extra/apps/$a $a; done
# optional: beamai_a2a beamai_rag
```

`rebar.config`:
```erlang
{minimum_otp_vsn, "27"}.
{erl_opts, [debug_info]}.
{deps, [
    beamai_core, beamai_llm, beamai_agent,          %% resolved from _checkouts
    beamai_tools, beamai_mcp, beamai_agui,
    {gun, "2.7.0"},
    {cowboy, "2.12.0"}
    %% uuid (uuid_erl) is declared by beamai_extra but no module calls uuid: -> not needed
]}.
```

**Gotcha: hex resolution fails without a lock file. [V]** With rebar3 3.24, a fresh resolve dies with `Dep cowlib has invalid version >= 2.21.0 and < 3.0.0`. That requirement comes from gun 2.7.0. Adding `{cowlib,"2.21.0"}` at the top level does not help. The fix is to copy beamai_extra's `rebar.lock` and delete the three `beamai_*` git_subdir entries, keeping cowboy 2.12.0, cowlib 2.21.0, gun 2.7.0 and ranch 1.8.0. With that lock in place it compiles. rebar3 prints "App X is a checkout dependency and cannot be locked", which is harmless. Upgrading rebar3 may also fix it.

In your `.app.src`, list `applications` as `[kernel, stdlib, gun, cowboy, beamai_core, beamai_llm, beamai_agent, beamai_tools, beamai_mcp, beamai_agui]`. **[V]** `application:ensure_all_started` of these returns ok.
- beamai_agent starts its supervisor and the default in-memory chat store.
- beamai_agui starts the registry, sessions, pause store and the auth/rate-limit workers. Auth and rate limiting are off by default.
- beamai_core does **not** declare beamai_llm, because that would be a dependency cycle, so start beamai_llm explicitly.

Checkout apps compile into `_build/default/checkouts/*`. Edits in the beamai repos are picked up on the next `rebar3 compile`.

---

## 2. beamai_llm: chat models

### Config
```erlang
LLM = beamai_chat_model:create(Provider, Opts).   %% create/2 -> config() map (merge of provider defaults + Opts)
```
- Providers: `openai | openai_responses | anthropic | deepseek | zhipu | dashscope | ollama | xai | moonshot | kimi | openrouter | siliconflow | mock | {custom, Module}`.
- Every provider requires `api_key` as a binary, except ollama and mock. `validate_config` returns `{error, missing_api_key}` otherwise.

| provider | default base_url / endpoint | default model | notes |
|---|---|---|---|
| openai | `https://api.openai.com` + `/v1/chat/completions` | `gpt-4` | defaults also send `max_tokens 4096`, `temperature 0.7`; `max_completion_tokens` used if set |
| anthropic | `https://api.anthropic.com` + `/v1/messages` | `claude-sonnet-4-5-20250929` | `max_tokens` default 8192; `model`/`max_tokens` read **from Config only** |
| zhipu | `https://open.bigmodel.cn` + `/api/paas/v4/chat/completions` | `glm-4.7` | `api_mode => openai|anthropic`, `use_coding_api => true` |
| deepseek | `https://api.deepseek.com` + `/chat/completions` | `deepseek-flash` | `thinking => #{type=>enabled|disabled}`, `reasoning_effort` |
| openai_responses | `/v1/responses` | — | `reasoning_effort`, `max_output_tokens`, `previous_response_id` |

Common keys:
- Endpoint overrides: `base_url`, `endpoint`. The URL is built as `<<BaseUrl/binary, Endpoint/binary>>`, which suits one-api-style gateways.
- Generation: `model`, `max_tokens`, `temperature`, `top_p`.
- Transport and retry: `timeout` (ms), `pool` (http pool atom), `max_retries` (default 3; 0 disables retry), `retry_delay`, `on_retry`.

Anthropic-only keys:
- `thinking => #{type=>enabled, budget_tokens=>N} | #{type=>adaptive} | N`
- `cache_control => none|system_only|tools_only|system_and_tools|conversation|full`, or `#{strategy=>..., ttl=><<"1h">>}`
- `web_search => true | #{max_uses=>N,...}`
- `top_k`, `metadata`, `service_tier`

```erlang
Claude = beamai_chat_model:create(anthropic, #{api_key => K, model => <<"claude-sonnet-4-5-20250929">>,
                                               max_tokens => 8192, cache_control => full}),
GLM    = beamai_chat_model:create(zhipu, #{api_key => ZK, model => <<"glm-4.7">>}),
GLMant = beamai_chat_model:create(anthropic, #{api_key => ZK, model => <<"glm-4.7">>,
                                               base_url => <<"https://open.bigmodel.cn/api/anthropic">>}),
DS     = beamai_chat_model:create(deepseek, #{api_key => DK, model => <<"deepseek-flash">>}),
OAIgw  = beamai_chat_model:create(openai, #{api_key => GK, model => <<"x">>, base_url => <<"https://gw.example">>}).
```

Gotcha: openai sends `temperature 0.7` and `max_tokens` by default, and reasoning models reject both. Use `openai_responses` for o-series and gpt-5 models, or override the keys.

Gotcha: per-host pool cap. Each of the three gun pools allows `max_connections_per_host` = 10. Past that you get `{error, pool_exhausted}`. With many concurrent background tasks hitting one LLM host, raise the cap in `{beamai_core, [{http_pools, #{http_pool_short => #{max_connections_per_host => 50}, http_pool_stream => #{...}}}]}`. Streaming uses `http_pool_stream`.

### Chat / stream
```erlang
{ok, Resp} = beamai_chat_model:chat(LLM, Messages),
{ok, Resp} = beamai_chat_model:chat(LLM, Messages, #{tools => ToolSpecs, tool_choice => auto, max_retries => 0}),
%% stream_chat/3,4: Callback gets the provider's RAW decoded SSE chunk (binary-keyed, provider-specific);
%% return value is the aggregated unified response.
{ok, Resp} = beamai_chat_model:stream_chat(LLM, Messages, fun(_RawChunk) -> ok end,
               #{on_llm_new_token => fun(TokenBin, _Meta) -> io:format("~ts", [TokenBin]) end}).
```
- `on_llm_new_token` delivers normalized text tokens only (callback_meta → Meta).
- Streaming is **never retried**. `chat/3` is retried with backoff and honors Retry-After.
- Errors come back as `{error, {http_error, Status, Body[, Headers]}}`, `{error, timeout}` and so on. Normalize them with `beamai_llm_error:from_reason(Reason, Provider)`, then read `type/1` (`rate_limit|server_error|client_error|auth|timeout|network|...`), `retryable/1` and `retry_after_ms/1`.

### Response (`beamai_chat_response`, a map with accessors)
- Content: `content/1` (binary or null), `tool_calls/1`, `has_tool_calls/1`.
- Status and cost: `finish_reason/1` (`complete|tool_use|length_limit|content_filtered|stop_sequence|pause_turn|refusal|...`), `usage/1` (`#{input_tokens, output_tokens, total_tokens, details}`).
- Reasoning: `reasoning_content/1`, `thinking/1`, `content_blocks/1`.
- Provider extras: `raw/1`, and `metadata/1`, which holds `rate_limit`, `citations` and `web_search_results`.
- Response tool_call shape: `#{id := Bin, name := Bin, arguments := map(), raw_arguments := Bin}`.

### Messages (always maps; roles are atoms)
```erlang
#{role => system | user | assistant | tool, content => binary() | null | [content_part()]}
beamai_message:system/1, user/1, assistant/1, tool_calls(TCs), tool_result(Id, Name, Content),
beamai_message:from_response(Resp)       %% assistant msg incl. tool_calls + content_blocks (thinking) for replay
```
- An assistant message with tools looks like `#{role=>assistant, content=>null, tool_calls=>[TC]}`. TC can be either the response shape `#{id,name,arguments}` or the OpenAI shape `#{id, type=>function, function=>#{name,arguments}}`; both adapters accept both.
- A tool result is `#{role=>tool, tool_call_id=>Id, name=>Name, content=>Bin}`.
- For Anthropic, the first system message becomes `system`. Each tool result becomes its own `user` message with a `tool_result` block, so consecutive results are not merged into one message. Text sitting next to tool_calls in an assistant message is dropped on replay.
- Write non-ASCII literals as `<<"中文"/utf8>>`. Without `/utf8`, characters are truncated to bytes; agui saw this bite in a real run.

### Multimodal (`content` as a list of parts)
```erlang
{ok, Img} = beamai_llm_content:image_path(<<"/tmp/a.png">>),          %% read+base64+MIME sniff
Msg = #{role => user, content => [beamai_llm_content:text(<<"what is this?">>), Img,
                                   beamai_llm_content:image_url(<<"https://x/y.jpg">>, <<"high">>)]}.
```
- Builders: `beamai_llm_content` has `text/1`, `image*/1,2`, `audio*`, `video*`, `document*` and `cache_breakpoint/1`. Sources come from `beamai_llm_media:base64/2`, `url/1` and `file_id/1`.
- Raw part shapes are `#{type=>text,text=>..}`, `#{type=>image, source=>#{type=>base64, media_type, data}|#{type=>url,url}}` and `#{type=>document, source, filename, title, citations}`.
- Anthropic silently drops audio and video parts.

---

## 3. beamai_core: tools, ChatClient, filters, context

### Tool spec (a plain map; `beamai_tool:new/2,3` and `beamai:tool/2,3` are sugar)
```erlang
#{name        := <<"web_fetch">>,                       %% non-empty binary
  handler     := fun((Args) -> R) | fun((Args, Ctx) -> R) | {M,F} | {M,F,ExtraArgs},  %% {M,F} => M:F(Args,Ctx)
  description => <<"...">>,
  parameters  => #{url => #{type => string, required => true, description => <<"...">>},
                   max => #{type => integer},
                   tags => #{type => array, items => #{type => string}},
                   opts => #{type => object, properties => #{...}},
                   mode => #{type => string, enum => [<<"a">>, <<"b">>]}},
  timeout => Ms | infinity,          %% DEFAULT infinity (no timeout!)
  retry => true | #{max_retries, initial_delay_ms},  %% transient errors only
  serial => true,                    %% any serial tool in a batch => whole batch sequential
  sensitive => true,                 %% used by beamai_filters:approval_filter/1
  strict_args => true,               %% validate args against generated JSON schema
  return_direct => true,             %% result becomes the final answer (see 4)
  max_result_bytes => N, result_redaction => [{Regex, Repl}], tag => ..., metadata => #{}}
```
Handler return values:
- `{ok, Value}`: Value is encoded by `beamai_tool:encode_result/1`. Binaries pass through as-is; maps and lists are JSON-encoded.
- `{ok, Value, Writes}`: Writes is a map folded into the shared **state** slots at the batch barrier.
- `{error, Reason}`.

**Gotcha [V]:** a bare return value such as `<<"x">>` crashes `beamai_tool_executor` with `case_clause`.

**Gotcha: arguments arrive as maps with binary keys** (`#{<<"url">> := U}`), because they are JSON-decoded from the LLM. Unparseable JSON arrives as `#{<<"raw">> => Bin}`.

**Gotcha: the handler runs in a separate `spawn_monitor` process.** Do not use `self()`, the process dictionary or messages to the caller from inside a tool.

**Gotcha [V]: `parameters` only accepts this param-spec DSL**, with atom keys `type`, `description`, `required`, `enum`, `items` and `properties`. Nested objects do not emit `required`, and there is no `anyOf`, `minimum` and so on. Passing a raw JSON Schema crashes `beamai_tool:to_tool_spec/1` with `function_clause`. That includes an MCP `inputSchema`, so `beamai_mcp_adapter:mcp_tool_to_beamai_tool/1` is broken for this reason too. Write a small converter from JSON Schema to the param DSL. Unknown `type` values pass through untouched, so `type => <<"string">>` also works.

Tool modules implement `beamai_tool_behaviour`: `tools/0 -> [tool_spec()]`, plus optional `tool_info/0 -> #{description, tags}` and `filters/0`. Load one with `beamai_chat_client:add_tool_module(C, Mod)` or with the agent's `plugins => [Mod]`.

### ChatClient (an immutable map)
```erlang
C0 = beamai_chat_client:new(#{}, Filters),              %% new/0,1,2 ; filters fixed at build time (list order = outer→inner)
C1 = beamai_chat_client:add_chat_model(C0, LLM),
C2 = beamai_chat_client:add_tools(C1, [T1, T2]),        %% add_tool/2, add_tools/2, add_tool_module/2
{ok, Res, _Ctx} = beamai_tool_executor:invoke(C2, <<"web_fetch">>, #{<<"url">> => U}, beamai_context:new()),
%% single LLM call (no tool loop). NOTE: registered tools are NOT auto-sent here:
{ok, Resp, _Ctx} = beamai_chat_client:invoke_chat(C2, Msgs, #{tools => beamai:tools(C2),
                                                   system_prompts => [#{role=>system, content=>P}]}),
{ok, Resp, _} = beamai_chat_client:invoke_chat_stream(C2, Msgs, #{on_raw_event => fun(E) -> ok end},
                                                      fun(Token, _Meta) -> ok end).
```
`beamai:tools(C)` returns the OpenAI-shaped specs; `beamai:tools(C, anthropic)` is the other form.

### Filters (`beamai_filter:new(Name, Hooks)` or `beamai:filter/2`)
The hooks are `around_turn`, `around_step`, `around_chat`, `around_tool` and `token_transform`. Each `around_*` hook has the shape `fun(Req, FCtx, Next) -> Resp | {Resp, NewFCtx}`. Skipping `Next` short-circuits the call.
- `around_tool` Req is `#{tool, args, context}` and Resp is `#{result, context}`.
- `around_chat` Req is `#{messages, context, opts}` and Resp is `#{response, context}`.
- `around_step` Req is `#{messages, context, iteration, tool_calls_made}`. Resp is `#{status := continue|final|interrupt|error, messages, context, tool_calls_made, response?, type?, interrupt_context?, reason?}`. This is the hook to use for "stop the loop" (section 4).
- `around_turn` gets the loop-result tuple. Hard rule: `{interrupt,_,_}` and `{error,_}` must pass through unchanged.

Built-in filters in `beamai_filters`:
- `logging_filter/0`, `timeout_filter(Ms)` and `approval_filter(fun(Name,Args)->boolean())`. The approval filter is non-interactive and only applies to `sensitive` tools.
- `safeguard_filter/1,2`.
- `validation_turn_filter/2` and `schema_validation_turn_filter/2,3`.
- `token_redact_filter/2` and `hold_release_filter/1`.

### Context (`beamai_context`)
There are three partitions:
- **env** is read-only: `conversation_id/1`, `get_chat_client/1`, and vars from `new(Vars)` read with `get/2,3`.
- **state** holds slots that tools read with `state_get(Ctx, Key[, Default])` and write via `{ok, V, Writes}`. Keys are normalized to binaries. Declared slots go through reducers set in `chat_client_settings.state_slots` or the agent's `state_slots`; undeclared slots are last-writer-wins.
- **filter-private** state is handled by the framework.

The agent creates a fresh context every turn, seeded from `initial_state`. **That is how to hand per-task data to tools**: put `#{<<"task_id">> => Id, <<"user_id">> => U}` into `initial_state` and read it with `beamai_context:state_get(Ctx, <<"task_id">>)`. **[V]** Closures in handlers work as well.

### Plain HTTP (`beamai_http`; gun backend, pooled, TLS verify_peer with system CAs)
```erlang
{ok, Map} = beamai_http:get(Url, #{q => <<"x">>}, #{headers => [{<<"authorization">>, <<"Bearer ", T/binary>>}],
                                                    timeout => 30000}),            %% get/1,2,3
{ok, Map} = beamai_http:post_json(Url, #{a => 1}, #{headers => H}),               %% post_json/2,3
{ok, Body} = beamai_http:post(Url, <<"application/x-www-form-urlencoded">>, FormBin, Opts),
{ok, Body, #{status := 200, headers := RespHeaders}} = beamai_http:request_meta(Method, Url, Headers, Body, Opts),
{ok, Acc} = beamai_http:stream_request(post, Url, Headers, Body, Opts, fun(Chunk, Acc) -> {continue, Acc} end),
```
Behavior **[V]**:
- Response bodies are auto-decoded with `json:decode`, so you get binary-keyed maps. Bodies that are not JSON come back as binaries.
- Errors are `{error, {http_error, Status, Body}}`. `request_meta` adds the response headers as a fourth element.
- `request/5` and `request_meta/5` take the HTTP method as an atom.

Gotchas:
- A body passed as a list is treated as a term and JSON-encoded. Pass a map, or a binary from `iolist_to_binary(json:encode(...))`. Passing `json:encode/1` output directly crashes.
- Every request carries `Accept: application/json` and `User-Agent: BeamAI/2.0`. Your own headers are added after these but cannot replace them. Servers that check Accept strictly, such as MCP streamable HTTP, reject the request (406).
- Retries are opt-in via `retry => N`.
- This is fine for the browser-worker API and the Google REST APIs. **[V]** I made live GET and POST calls.

---

## 4. beamai_agent: the ReAct agent

The agent is a **pure map value**. `run`, `stream` and `resume` execute **synchronously in the calling process**. There is no gen_server and no start_link.

```erlang
{ok, Agent} = beamai_agent:new(#{
    chat_client => C,                      %% or llm => {anthropic, Opts} | LLMConfig, plugins => [ToolMod]
                                           %% NOTE: there is NO `tools` key — tools live on the ChatClient
    system_prompt => <<"...">>,
    max_tool_iterations => 10,             %% default 10; exhaustion => {error, {max_tool_iterations, Calls}}  [V]
    max_tool_calls => infinity,
    parallel_tools => true,
    memory => default | false | {window, N} | {store, Handle} | {Mod, Ref},
    conversation_id => <<"conv-or-task-id">>,
    initial_state => #{<<"task_id">> => TaskId},
    callbacks => #{...},                   %% see below
    interrupt_tools => [...],              %% HITL tool descriptors (never executed)
    on_env_error => proceed,               %% set explicitly! (see gotcha)
    pause_store => beamai_pause_store_dets:handle(Name),
    event_consumers => [fun(Event) -> ok end],
    loop_filter => fun(LoopOpts) -> Filter end,   %% replace ReAct loop entirely
    tool_calling_manager => {Mod, Ref}}),
{ok, #{content := Text, usage := U, iterations := N, tool_calls_made := Calls, finish_reason := FR}, Agent1}
    = beamai_agent:run(Agent, <<"user text">>),        %% run/2,3 ; also {interrupt, Info, Agent1} | {error, R}
beamai_agent:stream(Agent, Text),                       %% stream/2,3: same result; tokens via on_token callback [V]
beamai_agent:messages(Agent), last_response/1, turn_count/1, add_message/2, clear_messages/1, set_system_prompt/2.
```
- The token stream is the `on_token` callback with signature `fun(TokenBin, Meta)`; `Meta` contains `message_id`. You can also pass `#{stream_token_handler => fun(Tok, Info) -> ok end}` in the run opts.
- `usage` covers **only the last LLM call**. To get total cost, sum the per-call responses from `on_llm_result(Resp, Meta)`.
- **Gotcha:** if you set `on_tool_call`, or `interrupt_tools` is non-empty, `on_env_error` silently defaults to `pause`. Any "environment"-class tool failure then interrupts the run. For background tasks, set `on_env_error => proceed`.

### Callbacks (all optional; exceptions inside them are swallowed)
| callback | signature |
|---|---|
| `on_turn_start`, `on_turn_end` | `fun(Meta)` |
| `on_turn_error` | `fun(Reason, Meta)` |
| `on_llm_call` | `fun(Msgs, Meta)` |
| `on_llm_result` | `fun(Resp, Meta)` |
| `on_llm_event` | `fun(RawChunk, Meta)`; stream only |
| `on_tool_call` | `fun(Name, Args[, Info])`, returns `ok \| {interrupt, Reason}`; Info has `tool_call_id` |
| `on_tool_result` | `fun(Name, EncodedResultBin[, Info])`; Info has `tool_call_id`, `args` and `error` |
| `on_state_change` | `fun(FullState, Meta)` |
| `on_message_start` | `fun(MsgId, Meta)` |
| `on_message_end` | `fun(MsgOrUndefined, Meta)` |
| `on_token` | `fun(Tok, Meta)` |
| `on_interrupt`, `on_resume` | `fun(IntState, Meta)` |

### Stopping the loop from a tool (all **[V]** with a scripted provider)
1. **`return_direct => true` on the tool spec.** The tool's encoded result becomes the final `content` and the LLM is not called again. This only applies when *every* call in the batch is return_direct and none of them failed.
2. **Flag in state plus an `around_step` filter.** This is the right fit for "task now waiting_approval":
```erlang
%% tool: {ok, #{status => waiting_approval}, #{<<"halt">> => #{reason => waiting_approval, task => T}}}
Halt = beamai:filter(<<"halt_on_flag">>, #{around_step => fun(Req, _F, Next) ->
    case Next(Req) of
        #{status := continue, context := Ctx} = R ->
            case beamai_context:state_get(Ctx, <<"halt">>) of
                undefined -> R;
                H -> R#{status => final,
                        response => beamai_chat_response:new(#{content => fmt(H), finish_reason => complete})}
            end;
        Other -> Other
    end end}),
C = beamai_chat_client:new(#{}, [Halt]), ...
```
   The run returns `{ok, #{content := ...}, Agent}`. The synthetic final answer is **not** persisted to memory, so the history ends `[user, assistant(tool_calls), tool]`. That is still valid for the next turn.
3. **`on_tool_call` returns `{interrupt, Reason}`.** This is a pre-execution gate: the tool is *not* run, and you get `{interrupt, #{reason, interrupt_type => callback, interrupted_tool_call, ...}, Agent1}`. Later, call `beamai_agent:resume(Agent1, <<"approved">>)` to execute the tool (`#{args => NewArgs}` can override its arguments), `resume(A, <<"rejected">>, #{message => Why})`, or `resume(A, <<"reply">>, #{message => Answer})`. `stream_resume/2,3` streams the continuation. **[V]**
4. **`interrupt_tools`**: descriptors the LLM can call, for example `beamai_tool_human:interrupt_tools()` (`ask_human`, `confirm_action`). Calling one produces `{interrupt, #{interrupt_type => tool_request, reason => ArgsMap}}`. Resume with `<<"reply">>` or `<<"rejected">>`.
- The interrupt doc mentions a third trigger, "tool returns `{interrupt, ...}`". It is **not implemented**: the executor would crash on that shape.
- Durable HITL across restarts needs two things. First, `pause_store => beamai_pause_store_dets:handle(Name)` after `beamai_pause_store_dets:start_link(Name, #{file => Path})`. Second, a persistent memory store. Then rebuild an identical agent with the same `conversation_id` and call `resume/3`; it falls back to the pause store transparently. `beamai_agent:run/2` on a thread with a pending pause "heals" it by inserting cancelled tool results.

### Abort / cancel
There is no cancel API. Run the agent in its own process and `exit(Pid, kill)`; `beamai_agui` does the same.

**Gotcha [V]: tool handlers and batch workers are `spawn_monitor`ed, not linked.** Killing the agent process leaves in-flight tools **running to completion**; I watched a tool write its file after the agent had been killed. For real cancellation:
- Have long tools check a cancel flag, for example an ETS row keyed by the `task_id` held in state.
- Or have the tool `link` itself to the agent pid: pass the pid via `initial_state` and call `link(AgentPid)` first thing in the handler.
- Or supply your own `tool_calling_manager`.

### Memory
- Default memory is an unbounded ETS store under the beamai_agent supervisor, keyed by `conversation_id`. It is **lost on restart**.
- For durability: `{ok,_} = beamai_chat_memory_dets:start_link(Name, #{file => Path})`, then `memory => {store, beamai_chat_memory_dets:handle(Name)}`.
- For a DB store, implement `beamai_chat_memory` (`mem_get/2`, `mem_add/3`, `mem_clear/2`) and pass `{store, {Mod, Ref}}`.
- To control what the LLM sees (summaries, windows), implement `beamai_memory_provider` (`history/2`, `append/3`, `prepare/3`, `clear/2`) and pass `memory => {Mod, Ref}`.
- To get a window over your own store: `beamai_memory_provider_default:new(StoreHandle, N)`.

### Sub-agents
- `beamai_agent_delegate:tool/1`, `fanout_tool/1` and `management_tools/1` turn sub-agents into tools. Config is `#{name, description, subagent => fun(Args, Ctx) -> AgentConfig end}`.
- `beamai_subagent_manager` handles async spawn, await and kill.

---

## 5. beamai_agui: AG-UI over SSE

### Mount
```erlang
{ok,_} = application:ensure_all_started(beamai_agui),
ok = beamai_agui_registry:register(<<"muse">>, fun(Input, RuntimeCfg) ->
    %% RuntimeCfg = #{callbacks, conversation_id (= threadId), initial_state, pause_store?, subagent_observer?}
    %% MUST be merged into beamai_agent:new/1. If you have your own callbacks, merge the callbacks maps:
    CB = maps:merge(MyCallbacks, maps:get(callbacks, RuntimeCfg)),   %% agui doesn't use on_tool_call/on_turn_*
    beamai_agent:new(maps:merge(#{chat_client => C, system_prompt => P, memory => Mem,
                                  on_env_error => proceed}, RuntimeCfg#{callbacks => CB}))
end),
Dispatch = cowboy_router:compile([{'_', [                        %% host must be the atom '_'
    {"/agui/agent/:agent/run",     beamai_agui_cowboy_handler, #{}},   %% what standard clients call
    {"/agui/run",                  beamai_agui_cowboy_handler, #{agent => <<"muse">>}},
    {"/agui/info",                 beamai_agui_cowboy_handler, #{mode => info}},
    {"/agui/threads",              beamai_agui_cowboy_handler, #{mode => threads}},
    {"/agui/threads/:thread",      beamai_agui_cowboy_handler, #{mode => thread}},
    {"/agui/threads/:thread/:sub", beamai_agui_cowboy_handler, #{mode => thread}},  %% events|messages|state|stop|stream
    {"/agui/[...]",                beamai_agui_cowboy_handler, #{mode => fallback}} %% CORS-ful 404, keep last
]}]),
{ok,_} = cowboy:start_clear(muse_http, [{port, 8080}], #{env => #{dispatch => Dispatch}}).
```
**[V]** I ran an end-to-end POST to `/agui/agent/muse/run` with a scripted LLM and a tool. The SSE frames came back in this order, each with an `id:` line: RUN_STARTED, STATE_SNAPSHOT, STEP_STARTED, TOOL_CALL_START/ARGS/END, STEP_FINISHED, TOOL_CALL_RESULT, STATE_DELTA (JSON Patch from the tool's writes), STEP_STARTED, TEXT_MESSAGE_START/CONTENT/END, STEP_FINISHED, RUN_FINISHED (with `result.content` and `usage`).

Per-route config keys:
- Routing and CORS: `agent`, `cors_origins => any | [Origin]`.
- Plugins: `event_transform` (`fun(Event) -> Event | [Event] | drop`), `input_transform` (`fun(RunInput) -> RunInput`), `inject_state => true`.
- `/info` capability flags: `a2ui`, `open_generative_ui`, `suggestions`, `multimodal`, `descriptions`.

App env `{beamai_agui, [...]}`:
- Sessions: `buffer_size` (512), `idle_ttl` (30 min), `on_concurrent` (`reject` returns 409, or `supersede`), `supersede_wait`.
- Pause store: `pause_store_file` (DETS, survives restart), or `pause_store => {Mod, Ref}`.
- `cors_origins`, `distributed_sessions` (global owner), `subagent_events`.
- `beamai_agui_auth` and `beamai_agui_rate_limit` initial configs.

How runs work:
- **Sessions:** there is one gen_server per threadId, and the run process lives under the session, not the HTTP request. Disconnecting does not stop the run.
- **Reconnect:** `GET /agui/threads/:id/stream` with `Last-Event-ID`.
- **Stop:** `POST /agui/threads/:id/stop`, or `beamai_agui_session:stop_run(ThreadIdOrPid[, RunId])`. Stop kills the run process and the session emits `RUN_FINISHED` with `result.status = "cancelled"`. The orphan-tool gotcha from section 4 applies here.
- **Programmatic API:** `beamai_agui_sessions:ensure(ThreadId)`, `beamai_agui_session:start_run(Session, Input, Factory, #{run_opts => ...})` (returns `{started, RunId, Since} | {busy, RunId}`), `subscribe/2`, `status/1`, `events/1`, `state/1`.
- **Inputs:**
  - A fresh run uses **only the last user message** from `RunAgentInput.messages`. History comes from the agent's memory keyed by threadId, so memory must be persistent across requests and restarts.
  - Multimodal content parts are flattened to text; non-text parts are dropped.
  - `RunAgentInput.tools` (frontend tools) is mounted as `interrupt_tools`.
  - `context` is appended to the system prompt.
  - `state` becomes `initial_state`, so tools see it through `state_get`.
- **HITL:** an interrupt ends the run with `RUN_FINISHED` plus `outcome:{type:"interrupt", interrupts:[{id = toolCallId, ...}]}`. The next POST on the same thread carries `resume:[{interruptId, payload:{decision:"approved"|"rejected", message?, result?}}]`, or `forwardedProps.resume`, or a `role=tool` message, or a plain user message. That request is routed to `beamai_agent:stream_resume/3`. **The factory must be replayable**: the same tools and prompt for the same thread.
- **Auth:** off by default. Turn it on with `beamai_agui_auth:set_config(#{enabled => true})` and `beamai_agui_auth:add_key(Key, #{name => ...})`; the header is `Authorization: Bearer` or `X-API-Key`. Rate limiting uses `beamai_agui_rate_limit:set_config/1` and `set_rule/2`. **Gotcha:** the authenticated identity is **not passed to the factory or agent**, because the cowboy handler discards it. For per-user identity, put your own cowboy middleware or handler in front, or wrap the handler.
- **Custom events from tools:** there is no emitter handle inside tools; they run in another process and the emitter's ETS table is private. Use state writes (which become STATE_DELTA) or an `event_transform` plugin. `beamai_agui_plugin:tool_watcher(#{tools => [Names], on_args => Fun, on_partial => Fun})` turns a tool's arguments into ACTIVITY events, and `compose/1` chains plugins.
- **Event constructors** (for your own SSE endpoints, e.g. task-progress streams): `beamai_agui_event:custom(Name, Value)`, `state_delta/1`, `to_sse(Event[, Seq])` and the rest.
- **Optional plugins:** `beamai_agui_a2ui` (`with_tool/1,2`, `event_transform/0`, `input_transform/0`), `beamai_agui_mcp_apps`, and `beamai_agui_subagent` (lanes; off by default because @ag-ui/client ≤0.0.57 rejects SUBAGENT_* events).
- **Not yet covered:** it has not been validated against the real CopilotKit frontend. With multiple instances only the owner is routed; the event buffer is in memory.

`feedbacks/` holds four reports from the "happy" client, dated 2026-09-04: the per-agent run URL with the CORS-404 fallback, the resume decision being ignored with a frontend-tool result fabricated, the thread read-surface shape, and a STEP_FINISHED ordering / duplicate-interrupt / multimodal-flag report. **All four are marked fixed.**

---

## 6. beamai_mcp client vs. remote streamable-HTTP servers. **Do not use it as-is. [V]**

```erlang
{ok, C} = beamai_mcp_client:start_link(#{transport => http, url => <<"https://.../mcp">>,   %% key is `url`
                                          headers => [{<<"authorization">>, <<"Bearer ...">>}],
                                          client_info => #{name => <<"muse">>, version => <<"0.1">>}}).
%% auto-connects; poll get_state/1 until {ok, connected}; then list_tools/1,2, call_tool/3,4
```
**[V]** Against both `https://mcp.deepwiki.com/mcp` (public) and `https://search-mcp.parallel.ai/mcp`, the client **crashes during connect** with `function_clause` on `{gun_error, _, _, {badstate, "The stream cannot be found."}}`.

Root cause: the gen_statem polls `transport:recv(0, ...)`. The HTTP transport's `receive ... after 0 -> gun:cancel(...)` cancels the in-flight POST almost immediately, and the late `gun_error` is unhandled. Other problems:
- The transport opens gun with no `tls_opts`.
- `beamai_mcp_adapter` emits raw JSON Schema plus bare-return handlers, which beamai_core rejects (section 3).
- `beamai_http` cannot be used either, because of its forced `Accept: application/json` header (the server answers 406). **[V]**

Parallel's endpoint returns **401 without an API key**. Send `Authorization: Bearer <PARALLEL_API_KEY>`; this env var is not set on the remote.

**Recommendation:** write a ~100-line MCP client directly on gun. **[V]** This flow worked against deepwiki: initialize, then `notifications/initialized` (202), then `tools/list`, which listed 3 tools.
```erlang
{ok, C} = gun:open("mcp.deepwiki.com", 443, #{transport => tls, protocols => [http2, http],
           tls_opts => [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
                        {server_name_indication, "mcp.deepwiki.com"},
                        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}),
{ok, _} = gun:await_up(C, 10000),
H = [{<<"content-type">>, <<"application/json">>}, {<<"accept">>, <<"application/json, text/event-stream">>}]
    ++ [{<<"mcp-session-id">>, Sid} || Sid =/= undefined] ++ AuthHeaders,
S = gun:post(C, <<"/mcp">>, H, iolist_to_binary(json:encode(#{jsonrpc => <<"2.0">>, id => 1,
        method => <<"initialize">>, params => #{protocolVersion => <<"2025-06-18">>, capabilities => #{},
        clientInfo => #{name => <<"muse">>, version => <<"0.1">>}}}))),
{response, nofin, 200, RespH} = gun:await(C, S, 60000), {ok, B} = gun:await_body(C, S, 60000),
%% content-type text/event-stream -> take each "data: " line and json:decode; else json:decode(B)
%% session id: proplists:get_value(<<"mcp-session-id">>, RespH) (deepwiki returns none)
%% then: notifications/initialized (no id), tools/list, tools/call #{name, arguments}
```
To expose MCP tools to the agent, map each tool to a beamai tool spec:
- **parameters**: convert `inputSchema` to the param DSL.
- **handler**: `fun(Args, _Ctx) -> {ok, TextOfContents} | {error, ...} end`.

`beamai_mcp_adapter:extract_text_from_contents/1` is reusable for the text extraction.

The MCP *server* side (`beamai_mcp_server` plus `beamai_mcp_cowboy_handler`) is a separate component and was not tested.

---

## 7. beamai_tools: built-ins

- `beamai_tool_file` provides `file_read`, `file_write`, `file_glob`, `file_grep`, `file_list` and `file_mkdir`. **Gotcha:** path checking uses `beamai_tool_security:default_config()`. That config only blocks `.git`, `node_modules` and `.env` and has **no root sandbox**; `allowed_paths` is not configurable from the tool. Wrap the handlers with your own root check, or copy the module.
- `beamai_tool_shell` provides `shell_execute`. It has no default timeout (the LLM may pass `timeout`) and only a tiny substring blocklist (`rm -rf /`, a fork bomb, mkfs, dd). Treat it as unsafe.
- `beamai_tool_todo` provides `write_todos` and `read_todos`. They keep data in context **state** (key `todos`), so it reaches AG-UI as STATE_DELTA.
- `beamai_tool_human:interrupt_tools()` provides the `ask_human` and `confirm_action` descriptors for `interrupt_tools`. Resume with `<<"reply">>` and `#{message => ...}`, or with `<<"rejected">>`.
- Loading: `beamai_tools:load(C, Mod)`, `load_all/2`, `available/0` (returns the file, shell and todo modules), and `define_tool/3,4,5`.
- Middleware: `beamai_tools:with_middleware(C, Specs)` appends filters, and `beamai_tools:presets(default|minimal|production|development|human_in_loop)` returns preset specs. The modules are `middleware_call_limit`, `middleware_tool_retry`, `middleware_model_retry`, `middleware_model_fallback` and `middleware_human_approval`. I did not exercise them; for a lean stack, prefer beamai_core filters.

---

## 8. HTTP summary for browser-worker and Google APIs
- `beamai_http` (section 3) covers JSON REST calls. **[V]** GET with query params, POST JSON with custom headers, and `request_meta` for status and headers all worked. It is pooled over gun with verified TLS by default. A 404 comes back as `{error,{http_error,404,Body}}`.
- Google OAuth token refresh is a form POST: `beamai_http:post(TokenUrl, <<"application/x-www-form-urlencoded">>, uri_string:compose_query([{"grant_type","refresh_token"},...]), #{})`. Pass the query string as a binary, because a list body would be JSON-encoded.
- Large or binary downloads arrive whole in memory, and non-JSON bodies come back as binaries. For streaming use `stream_request/6`, or gun directly.
- Use gun directly whenever you must control the `Accept` header (MCP, some SSE endpoints) or need long-lived SSE consumption.

## Reference examples
- In `beamai_extra/examples/src/`:
  - `example_agui_server.erl` and `example_agui_full.erl`: an offline walkthrough of 9 scenarios via `example_agui_scripted`.
  - `example_agui_durable.erl`: DETS pause store and history across BEAM restarts.
  - `example_agui_live.erl`, `example_agent.erl`, `example_llm_config.erl`.
- Probes I wrote on the remote, all under `/tmp/muse_scratch`:
  - `agent_probe.erl` with `script_llm.erl`, a `{custom, Mod}` scripted provider that is handy for tests.
  - `agui_probe.erl`, `gun_mcp.erl`, `http_probe.erl` and `mcp_probe.erl`.
