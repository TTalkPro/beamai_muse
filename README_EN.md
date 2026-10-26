# BeamAI Muse

English | [中文](README.md)

An Erlang/OTP reimplementation of [OpenMuse](https://github.com/CopilotKit/OpenMuse): a personal AI agent with a
browser, a Linux computer and files. Ask for an outcome; it becomes a durable plan that runs in the background,
and every external write needs your approval.

> Design: [designs/](designs/) (Chinese). Progress: [TASK.md](TASK.md). Differences from OpenMuse:
> [docs/DIFFERENCES.md](docs/DIFFERENCES.md) (Chinese).

## Documentation

| Document | Contents |
|---|---|
| [Browser worker](docs/browser.md) | WebChat/CDP Docker worker: image build, configuration, WebChat injection and scraping flow, input capabilities, security boundaries |
| [Docker computer](docs/computer.md) | Light and desktop image builds, configuration, and image update strategy |
| [Deployment](docs/deployment.md) | `deploy.sh` steps, directory layout, systemd, OpenAI-compatible gateway |
| [Configuration](docs/configuration.md) | All environment variables |
| [Differences](docs/DIFFERENCES.md) | Intentional differences from OpenMuse (Chinese) |

## Features

| Feature | What it does |
|---|---|
| Chat | Multiple sessions; streamed replies with tool cards; stop; BM25 history search |
| Background tasks | Durable plans with leases and heartbeats; another worker takes over after a crash |
| Approvals | External writes need an approval bound to a hash; action kinds are pluggable (`calendar.event`, `mail.send`) |
| Calendar | A built-in calendar (`/calendar`): month/week/day/list, repeats, drag to reschedule |
| Mail | Your existing mailboxes (IMAP/SMTP, passwords encrypted at rest): folders, search, reading, reply/forward, attachments, IDLE push |
| Documents | PDF upload, signed-URL preview, form field filling |
| Computer | A Docker Linux computer per conversation (shell and desktop) |
| Browser | WebChat/CDP Docker worker: screenshot console, clicks, typing, page text |
| Jev | Choice panels, ranked by sample rules or by TypeSafe live |
| AG-UI | `/api/agui/*` for any AG-UI client |

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
sidecars: sidecars/pdf (pdf-lib), sidecars/mail (imapflow, mailparser, nodemailer), sidecars/webchat-browser (Chromium + CDP + WebChat extractor)
```

## Dependencies

- OTP 27+, rebar3
- cmake, a C++23 compiler, ICU headers, zlib headers (bitcask NIF)
- Node 22.6+, npm (CSS build; PDF/mail sidecars; browser image typecheck)
- rsync, GNU make, openssl
- Docker CLI and Docker Engine (browser worker and Docker computer)

Erlang dependencies are rebar3 git dependencies fetched over https from GitHub and pinned by `rebar.lock`.

## Quick start

```sh
make compile      # fetch deps and compile
make css          # build the UI stylesheet (Node at build time only)
make shell        # dev shell (node muse@127.0.0.1)
make check        # compile + xref + dialyzer + eunit + ct
```

**Sample mode** (default, no keys): a field-trip permission slip PDF in Files and a scripted model.

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

Optional components:

```sh
make sidecars        # PDF helper, mail helper and browser image
make browser-image   # browser worker image (WebChat/CDP Docker)
make computer-image  # Docker computer image (light)
make computer-desktop-image  # Docker computer image (desktop)
```

## Deployment

```sh
./scripts/deploy.sh ~/apps/muse
vi ~/apps/muse/.env            # model, PUBLIC_API_URL, ...
~/apps/muse/bin/muse start     # plus the browser worker when BROWSER_WORKER_URL is set
```

See [docs/deployment.md](deployment.md) for details.
