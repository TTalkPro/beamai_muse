# beamai_muse

English | [中文](README.md)

An Erlang/OTP reimplementation of [OpenMuse](https://github.com/CopilotKit/OpenMuse): a personal AI agent with a
browser, a Linux terminal and files. Ask for an outcome; it becomes a durable plan that runs in the background,
and every external write needs your approval.

> Design: [designs/](designs/) (Chinese). Progress: [TASK.md](TASK.md). Differences from OpenMuse:
> [docs/DIFFERENCES.md](docs/DIFFERENCES.md) (Chinese).

## Features

| Feature | What it does |
|---|---|
| Chat | Main and side threads; streamed replies with tool cards; stop; messages typed during a reply are queued; BM25 history search |
| Background tasks | Durable plans with leases and heartbeats; another worker takes over after a crash; document / finance / plan / agent kinds |
| Approvals | Sending mail or creating events needs an approval bound to a hash; an interrupted write becomes `outcome_unknown` and is never retried |
| Goals, monitors, ideas, notifications | Milestones; page change / availability / price monitors with diffs; evidence-based suggestions; live toasts |
| Documents | PDF upload, signed-URL preview, form field filling |
| Computer | Docker Linux computer (terminal, files, PDF import/export) |
| Browser | Playwright worker: screenshot console, clicks, typing, page text, download import |
| Google | Gmail and Calendar, read-only or read-write, tokens encrypted at rest |
| Jev | Choice panels, ranked by sample rules or by TypeSafe live |
| AG-UI | `/api/agui/*` for any AG-UI client, or proxy to an external runtime with `AGENT_BACKEND=agui` |

## Architecture

```
browser ──HTTP/SSE──▶ muse_web ── cowboy
                        ├─ aihtml pages / actions / push (muse_ui_*)
                        ├─ JSON API (muse_api_*)
                        └─ AG-UI endpoint (muse_agui_handler)
                      muse_agent ── beamai agent + tools, chat sessions (beamai_agui), threads, Jev
                      muse_engine ── task engine (leases), approvals, monitors, goals, ideas, domain events (pg)
                      muse_integ ── workspace, files/PDF, Docker computer, browser, Google
                      muse_core ── config, Mnesia (records + CAS), bitcask (events/chat/blobs), signing, crypto
sidecars: sidecars/pdf (pdf-lib), sidecars/browser-worker (Playwright)
```

## Dependencies

beamai (core/llm/agent), beamai_extra (agui/tools/mcp), aihtml (server-rendered UI), bitcask (event log, chat
history with BM25, blobs) and Mnesia (transactional records with compare-and-swap). They are rebar3 git dependencies fetched over
https from GitHub, pinned by `rebar.lock`. Requires OTP 27+, rebar3, and cmake + a C++23 compiler + ICU
headers for the bitcask NIF.

## Quick start

```sh
make compile      # fetch deps and compile
make shell        # dev shell (node muse@127.0.0.1)
make check        # compile + xref + dialyzer + eunit + ct
make acceptance   # end to end: real browser worker + Docker desktop computer (needs make sidecars, make computer-desktop-image)
make css          # build the UI stylesheet (Node at build time only)
make sidecars        # optional: PDF helper and browser worker (Node + Playwright)
make computer-image  # optional: Docker computer image
```

**Sample mode** (default, no keys): built-in mail, calendar and sample data, and a scripted model.

```sh
make run          # open http://localhost:8787 and sign in
```

**Live mode**:

```sh
export WORKSPACE_MODE=live
export OPENMUSE_ACCESS_KEY=...          # 24+ characters
export TOKEN_ENCRYPTION_KEY=$(openssl rand -base64 32)
export MUSE_UI_SECRET=...               # 32+ characters
export AGENT_BACKEND=model MODEL=anthropic/claude-sonnet-4.5 ANTHROPIC_API_KEY=...
export PUBLIC_API_URL=https://muse.example.com
make run
```

## Deployment

`scripts/deploy.sh [APP_DIR]` (default `~/app/muse`) builds a prod release with ERTS included and installs it into `APP_DIR`. The layout:
- `rel/`: the release;
- `bin/muse`: the start/stop script;
- `sidecars/`: the PDF helper and the browser worker;
- `data/`: the data directory.

The first install writes `APP_DIR/.env` from `deploy/.env.example` with fresh secrets. Later deploys keep `.env` and `data/`. A running instance is stopped for the swap and started again afterwards.

```sh
./scripts/deploy.sh ~/app/muse
vi ~/app/muse/.env            # model, PUBLIC_API_URL, ...
~/app/muse/bin/muse start     # the release, plus the browser worker when BROWSER_WORKER_URL is set
~/app/muse/bin/muse status    # also stop, restart, logs, remote
```

For an OpenAI-compatible gateway, use these settings:
- `MODEL=openai/<model id>`;
- `OPENAI_BASE_URL=http://host:port/v1`;
- `OPENAI_API_KEY`;
- `OPENAI_CHAT_COMPLETIONS=true`.

The release runs in `APP_DIR/rel`, so paths in `.env` must be absolute. Mnesia data is tied to `MUSE_NODE_NAME`, so do not change the node name after the first start.

## Configuration

Environment variables (or a `.env` file), named as in OpenMuse; the node refuses to boot on invalid settings.

| Variable | Meaning |
|---|---|
| `WORKSPACE_MODE` | `sample` (default) or `live` |
| `OPENMUSE_ACCESS_KEY`, `TOKEN_ENCRYPTION_KEY`, `MUSE_UI_SECRET` | Required in live mode: sign-in key, token encryption key, UI signing secret |
| `PORT`, `HOST`, `PUBLIC_API_URL`, `ALLOWED_ORIGINS`, `TRUST_PROXY` | Listener and public URL, allowed origins (comma-separated; `*` admits any), proxy headers |
| `DATA_DIR` | Data directory (Mnesia, bitcask, screenshots, UI secret) |
| `AGENT_BACKEND` | `sample`, `model` or `agui` (`AGENT_URL`, `AGENT_TOKEN`) |
| `MODEL`, `<PROVIDER>_API_KEY` | e.g. `anthropic/claude-sonnet-4.5` with `ANTHROPIC_API_KEY`; `OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL` override endpoints |
| `WEB_SEARCH_ENABLED`, `PARALLEL_API_KEY` | Web search |
| `BROWSER_WORKER_URL`, `WORKER_TOKEN` | Browser worker |
| `COMPUTER_ENABLED`, `COMPUTER_PROVIDER`, `COMPUTER_IMAGE`, `COMPUTER_DEPLOYMENT_ID` | Docker computer; `COMPUTER_PROVIDER` accepts only `docker` (no E2B desktop); the deployment id names the containers (defaults to `PUBLIC_API_URL`) |
| `COMPUTER_DESKTOP`, `COMPUTER_DESKTOP_IMAGE` | `true` switches to the desktop variant (Xvfb + openbox, xterm, LibreOffice, mupdf; `use_desktop`); image defaults to `openmuse-computer-desktop:local` (`make computer-desktop-image`) |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Gmail and Calendar |
| `JEV_MODE`, `JEV_MODEL`, `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` | Jev: `off`, `sample` or `live` |
| `TASK_WORKER_ENABLED` | Run the task worker on this node |
| `PDF_SIDECAR` | PDF sidecar command |
