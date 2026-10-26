# BeamAI Muse

English | [中文](README.md)

An Erlang/OTP reimplementation of [OpenMuse](https://github.com/CopilotKit/OpenMuse): a personal AI agent with a
browser, a Linux computer and files. Ask for an outcome; it becomes a durable plan that runs in the background,
and every external write needs your approval.

> Design: [designs/](designs/) (Chinese). Progress: [TASK.md](TASK.md). Differences from OpenMuse:
> [docs/DIFFERENCES.md](docs/DIFFERENCES.md) (Chinese).

## Features

| Feature | What it does |
|---|---|
| Chat | Main and side threads; streamed replies with tool cards; stop; messages typed during a reply are queued; BM25 history search |
| Background tasks | Durable plans with leases and heartbeats; another worker takes over after a crash; document / finance / plan / agent kinds |
| Approvals | External writes need an approval bound to a hash; an interrupted write becomes `outcome_unknown` and is never retried. Action kinds are pluggable (`muse_action_kind`): the built-in calendar's `calendar.event` and the built-in mail's `mail.send` |
| Calendar | A built-in calendar (`/calendar`): month/week/day/list, repeats, drag to reschedule; the agent reads it, and its creates, changes and deletes need your approval |
| Mail | Your existing mailboxes (`/mail`, IMAP in, SMTP out; presets for QQ, 163, 126, Gmail, Outlook and iCloud; several accounts; passwords encrypted at rest): folders with unread counts, search, reading (HTML mail in a sandbox, remote images blocked by default), reply and forward, attachments downloaded or saved to Files, drafts, IDLE push and new-mail notifications. The agent searches, reads and drafts; every message it sends needs your approval on a review card |
| Notifications | Live toasts and an unread dot (the goals, monitors and ideas pages were dropped in the simplified UI) |
| Documents | PDF upload, signed-URL preview, form field filling; document tasks start from a PDF in Files |
| Computer | A Docker Linux computer per conversation (the agent uses its shell and desktop; the page shows the screen and command history, downloads and uploads files) |
| Browser | Playwright worker: screenshot console, clicks, typing, page text, download import |
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
                      muse_integ ── workspace, files/PDF, Docker computer, browser
                      muse_core ── config, Mnesia (records + CAS), bitcask (events/chat/blobs), signing, crypto
sidecars: sidecars/pdf (pdf-lib), sidecars/mail (imapflow, mailparser, nodemailer), sidecars/browser-worker (Playwright)
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
make sidecars        # optional: PDF helper, mail helper and browser worker (Node + Playwright; npm ci installs the locked versions)
make computer-image  # optional: Docker computer image
```

**Sample mode** (default, no keys): a field-trip permission slip PDF in Files and a scripted model (say "Complete the permission slip" for the form-filling demo).

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
- `sidecars/`: the PDF helper, the mail helper and the browser worker;
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
| `CHAT_MAX_STEPS` | Model steps per chat reply (default 200); a reply runs on the server until it is done or stopped, also with no page open |
| `TASK_MAX_STEPS`, `TASK_RUN_MINUTES`, `TASK_AUTO_RUNS` | Background tasks: tool steps (default 50) and minutes (default 10) per run; an unfinished run continues by itself in a new run, up to `TASK_AUTO_RUNS` runs in a row (default 10) before the task asks you |
| `MODEL`, `<PROVIDER>_API_KEY` | e.g. `anthropic/claude-sonnet-4.5` with `ANTHROPIC_API_KEY`; `OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL` override endpoints |
| `WEB_SEARCH_ENABLED`, `PARALLEL_API_KEY` | Web search |
| `BROWSER_WORKER_URL`, `WORKER_TOKEN` | Browser worker |
| `COMPUTER_ENABLED`, `COMPUTER_PROVIDER`, `COMPUTER_IMAGE`, `COMPUTER_DEPLOYMENT_ID` | Docker computer; `COMPUTER_PROVIDER` accepts only `docker` (no E2B desktop); the deployment id names the containers (defaults to `PUBLIC_API_URL`) |
| `COMPUTER_DESKTOP`, `COMPUTER_DESKTOP_IMAGE` | `true` switches to the desktop variant (Xvfb + openbox, xterm, LibreOffice, mupdf; `use_desktop`); image defaults to `openmuse-computer-desktop:local` (`make computer-desktop-image`) |
| `COMPUTER_NETWORK` | Network of the computer containers: `bridge` (default; Docker's default bridge, internet access, and the host's LAN is reachable too) or `none` (no network, as in OpenMuse). After a change, containers created with the old setting are refused; delete the computer to recreate it |
| `COMPUTER_MAX_RUNNING`, `COMPUTER_IDLE_MINUTES`, `COMPUTER_RETENTION_DAYS` | Computer pool (one computer per conversation and per background task): running computers per deployment (default 4; starting another stops the least recently used idle one, or fails when all are busy); idle minutes before a computer is stopped (default 15, /workspace kept); days after which a stopped, unused conversation/task computer is deleted with its volume (default 7; an older version's default computer is kept) |
| `JEV_MODE`, `JEV_MODEL`, `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` | Jev: `off`, `sample` or `live` |
| `TASK_WORKER_ENABLED` | Run the task worker on this node |
| `PDF_SIDECAR` | PDF sidecar command |
| `MAIL_SIDECAR` | Mail sidecar command (default `node sidecars/mail/index.mjs`: imapflow, mailparser, nodemailer) |
| `MAIL_SYNC_DAYS`, `MAIL_SYNC_MAX`, `MAIL_POLL_MINUTES` | Built-in mail: the days (default 30) and the number of messages (default 500) kept per folder, and the polling interval in minutes (default 5; IMAP IDLE wakes the inbox sooner). Attachments follow `FILES_MAX_MB`; mailbox passwords are encrypted with `TOKEN_ENCRYPTION_KEY`, without which no mailbox can be added |
| `FILES_MAX_MB` | Size limit of one file in Files, in MB (default 25, at most 1024); any file type is accepted, PDFs stay at 10 MB |
