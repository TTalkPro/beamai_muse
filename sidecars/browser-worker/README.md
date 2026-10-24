# OpenMuse browser worker

An independent Node/Playwright service for the OpenMuse server. There is no OpenBot dependency. The server owns app authentication and user ownership; this worker accepts requests only from a trusted server holding `WORKER_TOKEN`.

## Run

Set the same random `WORKER_TOKEN` (at least 32 characters) in the server and the shell running Compose, then start from the repository root:

```sh
docker compose -f infra/compose.yaml up --build -d
```

Set the server's worker URL to `http://127.0.0.1:8790`. The host port binds only to loopback. If the server is later containerized on the same Compose network, use `http://browser-worker:8790`. Never send the worker token to a browser or mobile client.

The image includes matching Playwright and Chromium versions. The Docker build uses the worker’s own npm lockfile. Local development uses the root pnpm workspace: run `pnpm install --frozen-lockfile`, then follow the local development commands below.

## API

All endpoints except `GET /health` require `Authorization: Bearer <WORKER_TOKEN>`. JSON writes require `Content-Type: application/json`.

| Method | Path | Input / response |
| --- | --- | --- |
| GET | `/health` | `{ "status": "ok" }` (process health only) |
| GET | `/sessions` | `Session[]` |
| POST | `/sessions` | `{ id: UUID, url }` → `Session`, HTTP 201; reopens a saved profile |
| POST | `/sessions/:id/navigate` | `{ url }` → `Session` |
| POST | `/sessions/:id/close` | `Session`; retains profile and PDFs |
| GET | `/sessions/:id/screenshot` | 1280 × 800 PNG |
| GET | `/sessions/:id/read` | `{ url, title, text, truncated }`; visible page text capped at 100,000 characters |
| POST | `/sessions/:id/input` | One input below → `Session` |
| GET | `/sessions/:id/downloads` | `{ downloads: { id, name, size, mimeType: "application/pdf" }[], failures: { id, name, code, message, createdAt }[] }` |
| GET | `/sessions/:id/downloads/:downloadId` | PDF bytes, attachment disposition |

`Session` is `{ id, title, url, status: "active" | "closed" | "error", updatedAt }`. UUIDs use versions 1–8 and RFC variant bits. Screenshot clicks must use native image coordinates, even when the displayed image is scaled.

Inputs:

```json
{ "type": "click", "x": 320, "y": 240 }
{ "type": "text", "text": "Example" }
{ "type": "key", "key": "Enter" }
{ "type": "scroll", "deltaY": 600 }
```

Supported keys: Enter, Tab, Escape, Backspace, Delete, arrow keys, Home, End, PageUp, PageDown, Control+a, Meta+a, Shift+Tab. Text input is limited to 10,000 characters; scrolling to ±5,000 pixels per request. Popups and dialogs are dismissed; service workers and WebSockets are disabled. Sites requiring those features may not work yet.

Errors return `{ error: { code, message } }`. Codes include `UNAUTHORIZED` (401), `BLOCKED_URL` (400), `DNS_UNAVAILABLE`/`NAVIGATION_FAILED` (502), `BROWSER_UNAVAILABLE` (503), `SESSION_CLOSED`/`SESSION_LIMIT` (409), and `DOWNLOAD_TOO_LARGE` (413). The server should separately report a connection failure as “browser worker unavailable”; `/health` does not claim that Chromium can launch.

## Persistence and limits

- Docker volume `browser-profiles` stores a Chromium profile per session, cookies saved at graceful close, session metadata and accepted PDFs. Closing or restarting the worker retains these files. Reopening uses the same UUID.
- Failed first navigation removes its unclaimed worker profile. The server records the UUID before calling the worker and retains an error record so the app can retry that same session. Existing profiles survive a failed reopen.
- Three active sessions, 20 saved profiles, 30-minute idle close, 20-second navigation timeout, 64-KiB API request limit.
- Up to 20 PDFs per session, each at most 10 MiB. The worker checks the `%PDF-` signature and actual byte count before publishing metadata. It checks the cap again before serving. The app should additionally parse/validate the PDF before import.
- In-progress downloads are monitored and canceled on exceeding the cap. Chromium may buffer bytes before cancellation; the container's temporary filesystem is limited to 256 MiB. The completed-file limit is exact.
- The latest 100 rejected download outcomes survive restart, including unsupported files, oversized files, download limits and interrupted transfers. Transfers still pending at restart become interrupted outcomes. The app import endpoint returns `{ files, failures }` so rejected files are visible even when no PDF was accepted.
- Reads return the actual final URL and visible text from Chromium. The read endpoint accepts no script, selector or evaluation input; the public-destination checks apply before and after the read. Empty visible pages return empty text, and unreadable/closed sessions return an error.
- Deleting the Docker volume deletes saved logins and downloads. The persistent volume contains sensitive browser state and should have the same access controls as the app's document store.

## Network boundary

Only public HTTP(S) destinations on ports 80/443 are allowed. Navigation and subrequests are checked, including DNS results; any private or reserved answer rejects the request. An internal loopback proxy validates each destination and connects to that exact IP address, preventing a second DNS resolution from rebinding the socket to a private address. HTTPS tunnels allow port 443 only. Chromium uses that proxy with its implicit loopback bypass removed; QUIC and non-proxied WebRTC UDP are disabled. There is no development switch allowing private destinations.

This is application-enforced egress policy, not a kernel firewall or a guarantee against a Chromium exploit. Playwright's default Chromium launch disables Chromium's internal sandbox. The container runs as `pwuser`, with no Docker socket, no app/provider secrets, no Linux capabilities, read-only root filesystem, and memory/process limits. Review [Playwright's container guidance](https://playwright.dev/docs/docker) when hardening a multi-tenant deployment.

## Verify

```sh
# Repository security and API tests, without starting Chromium:
pnpm exec tsx --test tests/browser.test.ts

# Worker types after npm ci in apps/worker:
npm --prefix apps/worker run typecheck

# Real Chromium, disposable container, random ephemeral token, automatic cleanup:
node apps/worker/tests/run-docker.mjs

# Real Chromium lifecycle with locally installed matching Playwright browsers:
node --experimental-strip-types --test apps/worker/tests/lifecycle.test.ts
```

The local lifecycle test serves controlled HTTP pages on loopback. Its injected HTTP transport maps a public-IP URL to those pages after the real worker and proxy destination checks; it does not need external DNS or websites. It checks exact page reads, truncation boundaries, private redirect rejection, failed profile cleanup, and profile/localStorage restoration through real Chromium.

The Docker test uses the same HTTP fixture and worker API assertions as the local process-restart test. It checks authentication, exact page reads, PNG dimensions, console input, private redirects, byte-identical PDF downloads, rejected downloads, container restart, and actual localStorage recovery without reseeding. The runner builds the normal image, mounts the tests read-only, and publishes both the worker API and fixture diagnostics on random loopback host ports. Fixtures run inside the disposable container; image builds still require registry access.

The fixture entrypoint is test-only and is not copied into the production image. It injects the existing browser manager and proxy transport, without adding a production evaluation endpoint or private-network allowance. These fixtures cover HTTP; the default proxy's HTTP/CONNECT private-destination rejection remains covered by the repository tests, but successful HTTPS navigation is not covered by these fixture suites.

## Local development

From the repository root, configure `.env` with matching `WORKER_TOKEN` and `BROWSER_WORKER_URL`, then run:

```sh
pnpm --dir apps/worker exec playwright install chromium
pnpm dev:browser
```

The local worker binds to `127.0.0.1:8790` and stores profiles in `.openmuse/browser-profiles` by default. Docker sets `WORKER_HOST=0.0.0.0` inside its container; Compose publishes only the loopback host port. `WORKER_DATA_DIR` selects another private profile directory.
