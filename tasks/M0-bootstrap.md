# M0 项目骨架与依赖

> 设计：[designs/00-overview.md](../designs/00-overview.md) §2–§3
> 目标：空的 umbrella 能编译、启动所有依赖 app，门禁脚本可以运行。
> 状态：✅ 完成（2026-10-22）。

## M0-1 仓库与 rebar 配置
- [x] `rebar.config`：`minimum_otp_vsn 27`，erl_opts 包含 `warnings_as_errors`、`warn_export_vars`、`warn_shadow_vars`、`warn_obsolete_guard`；`project_app_dirs ["apps/*"]`；配置 xref 检查集；dialyzer 的 `plt_extra_apps`。
- [x] rebar3 git 依赖（https，`rebar.lock` 锁 commit）：beamai_core/llm/agent 用 `git_subdir` 指向 TTalkPro/beamai 的 main 分支，beamai_tools/mcp/agui 用 `git_subdir` 指向 TTalkPro/beamai_extra 的 main 分支，aihtml/aihtml_cowboy 用 `git_subdir` 指向 DavidAlphaFox/aihtml 的 master 分支，bitcask 用 `git` 指向 DavidAlphaFox/bitcask 的 develop 分支。（最初的 `_checkouts` 符号链接方案按用户要求废弃。）
- [x] hex 依赖：gun 2.7.0、cowboy 2.13.0（与 aihtml_cowboy 一致；beamai_agui 在 2.13 下编译和启动正常）、ranch 2.2.0、cowlib 2.21.0（gun 2.7 要求 ≥2.21）、erlexec 2.5.0（2.2.0 已被撤回）、meck 1.2.0（test）。
- [x] `rebar.lock`：rebar3 3.24 自动解析 gun 的 cowlib 约束会失败，所以 hex 包的版本是手写的；git 依赖的 commit 由 `rebar3 lock` 写入（当前为 beamai `08aa844`、beamai_extra `bcd77ac`、aihtml `327668d`、bitcask `208618d`）。
- [x] `.gitignore`：`_build`、`DATA_DIR`、`node_modules`、`erl_crash.dump`。

验收：从空的 `_build` 执行 `rebar3 compile` 通过，bitcask NIF 加载成功（`bitcask:open/2` 能在临时目录打开）。

## M0-2 五个 app 的空壳
- [x] 在 `apps/` 下建立 `muse_core`、`muse_integ`、`muse_engine`、`muse_agent`、`muse_web`：`.app.src`、`*_app.erl`、`*_sup.erl`。applications 依赖按 00-overview §2 的依赖方向填写。
- [x] `config/sys.config.src` 和 `vm.args.src`：节点名 `muse@127.0.0.1`（Mnesia 写盘需要节点名），cookie 从环境变量读取。
- [x] `config/shell.config`：开发用的 `rebar3 shell` 配置。
- [x] `relx` release：`beamai_muse`。mnesia 只 load 不 start，由 `muse_store` 负责建 schema。

验收：`rebar3 shell` 启动后，`application:which_applications()` 包含全部 5 个 app 和依赖 app；`rebar3 release` 成功。

## M0-3 门禁脚本
- [x] `scripts/check.sh`：依次执行 compile、xref、dialyzer、eunit、ct。
- [x] `Makefile` 目标：`check`、`css`、`sidecars`、`computer-image`、`run`。
- [x] `README.md`（中文）和 `README_EN.md` 的骨架：简介、依赖、快速开始。完整内容在 M8 补齐。

验收：在空壳上运行 `scripts/check.sh`，结果为 0 告警、0 失败。

## M0-4 sidecar 与外部资源搬运
- [x] 把 openmuse 的 `apps/computer/{Dockerfile,files.py}` 拷到 `computer/`，在头部注释写明来源 commit `1ac68f3`。
- [x] 把 openmuse 的 `apps/worker` 拷到 `sidecars/browser-worker`，内容原样不改，加 README 说明启动方式。
- [x] 建立 `sidecars/pdf` 骨架（`package.json` 依赖 pdf-lib），实现留到 M2-3。

验收：目录结构与 00-overview §2 一致。

## 验收记录（2026-10-22）

- `rebar3 compile`：通过（warnings_as_errors）。bitcask NIF 在 checkout 目录中构建，没有弄脏 bitcask 工作树。
- `application:ensure_all_started(muse_web)` 拉起 23 个 app；`bitcask:open/put/get` 正常。
- `rebar3 release` 后以 daemon 启动，节点为 `muse@127.0.0.1`，5 个 muse app 都在运行，mnesia 已加载但未启动。
- `scripts/check.sh`：xref 0、dialyzer 0、eunit 0 tests、ct 0 tests。
- 发现：远程 Node 是 v20.19，浏览器 worker 的 `--experimental-strip-types` 需要 22.6+，已记入 M2-5。
