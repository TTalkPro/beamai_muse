# OpenMuse → Erlang: HTTP app, auth, config & integrations spec

Source of truth: `/home/david/workspace/openmuse` (TS). This spec covers `apps/server/src/{app,config,auth,rate-limit,files,workspace,browser,browser-console,computer,computer-backend,computer-tools,computer-routes,search,google-auth,log,index,worker-entry}.ts`, `packages/integrations/src/{google,pdf,vault}.ts`, `packages/domain/src/{index,computer,date-time}.ts` (shapes), `apps/computer/{Dockerfile,files.py}`, `apps/worker/src/*.ts`.
Out of scope (separate spec): `/api/agent/*` (engine/routes.ts), `/api/copilotkit/*` runtime, ActionService internals (actions.ts), agent tools other than the data shapes noted here.

Conformance tests worth porting: `tests/api.test.ts`, `auth-startup.test.ts`, `config.test.ts`, `oauth.test.ts`, `google.test.ts`, `pdf.test.ts`, `vault.test.ts`, `rate-limit.test.ts`, `resource-ids.test.ts`, `computer*.test.ts`, `browser*.test.ts`, `search*.test.ts`, `log.test.ts`.

Conventions: "ms" = Unix epoch milliseconds (integer). "ISO" = `Date.prototype.toISOString()` format `YYYY-MM-DDTHH:MM:SS.sssZ` (always UTC, millisecond precision). `sha256hex(x)` = lowercase hex of SHA-256 over UTF-8 bytes. `uuid()` = random v4 UUID, lowercase.

---------------------------------------------------------------------------------------------------

## 0. Persistence substrate (needed by every section)

All state lives in one table (Postgres via `DATABASE_URL`, else embedded PGlite at `${DATA_DIR}/postgres`):

```sql
CREATE TABLE IF NOT EXISTS records(
  owner text NOT NULL, kind text NOT NULL, id text NOT NULL,
  data jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(owner,kind,id));
```

`data` always contains the `id` field too. Operations used by these modules (semantics must be preserved, especially atomicity):

| op | semantics |
|---|---|
| `get(owner,kind,id)` | data or null |
| `list(owner,kind)` | all data, `ORDER BY updated_at DESC, id` |
| `put(owner,kind,value)` | upsert by `value.id`; replaces whole `data`; bumps `updated_at` |
| `insertIfAbsent(owner,kind,value)` | `INSERT … ON CONFLICT DO NOTHING RETURNING data` → value if inserted, null if existed |
| `compareAndSwap(owner,kind,id,expected,patch)` | atomic: `UPDATE … SET data = data \|\| patch WHERE … AND data @> expected RETURNING data` → new data or null. `@>` = JSON containment (every key in `expected` equals); `\|\|` = shallow merge |
| `take(owner,kind,id)` | atomic `DELETE … RETURNING data` (one-shot read) |
| `remove(owner,kind,id)` | delete |
| `updateCredential(owner,connId,secret)` | `UPDATE records SET data=jsonb_set(data,'{secret}',secret) WHERE owner AND kind='credentials' AND id='google' AND data->>'connectionId'=connId` → bool (row updated) |
| `recoverInterruptedActions()` | at API start: every `kind='actions'` with `status='executing'` gets merged `{"status":"outcome_unknown","error":"Server restarted during execution. Check the provider before creating another action."}` |

In Erlang: Postgres via epgsql/pgo is the natural fit (keep jsonb + CAS SQL verbatim). If you replace with Mnesia/ETS, CAS must be a transaction doing containment-check + shallow merge.

Record kinds touched by this spec (owner is `"local-user"` unless noted):

| owner | kind | id | data |
|---|---|---|---|
| `system` | `sessions` | sha256hex(token) | `{id, owner:"local-user", expiresAt: ms}` |
| `system` | `oauth` | state | `{id, owner, expiresAt, verifier, scopes[], generation}` |
| owner | `credentials` | `google` | `{id:"google", generation, connectionId\|null, secret\|null}` (secret = vault envelope of Tokens JSON) |
| owner | `settings` | `google` | sample mode: `{id:"google", enabled:bool, connectionId?}` |
| owner | `settings` | `seeded` | `{id:"seeded", value:true}` |
| owner | `mail` | message id | Mail (+ `connectionId` in live) |
| owner | `events` | event id | CalendarEvent |
| owner | `imports` | attachment reference | `{id:ref, artifactId, connectionId}` |
| owner | `files` | file uuid | Artifact (with `url:""`) |
| owner | `drafts` | uuid | EmailDraft + `{id, createdAt}` |
| owner | `conversations` | `default` | `{id:"default", messages:[...]}` |
| owner | `conversation-settings` | `main` | `{id:"main", threadId, existing:false}` |
| owner | `browsers` | browser session uuid | BrowserSession |
| owner | `chat-browsers` | chat threadId | `{id:threadId, sessionId}` |
| owner | `browser-downloads` | worker download uuid | `{id, fileId}` |
| owner | `search-sessions` | conversation key (`chat:<threadId>`/`task:<taskId>`) | `{id, sessionId}` |
| owner | `computer-state` | `lease` | Lease |
| owner | `computer-commands` | receipt id | ComputerCommand (docker provider) |
| owner | `computer-desktop-commands` | receipt id | ComputerCommand (e2b provider) |
| owner | `computer-desktop-actions` | receipt id | ComputerCommand (desktop GUI actions) |
| owner | `computer-desktop-screens` | `latest` | Screen |
| owner | `actions`, `activity` | … | owned by ActionService (other spec) |

Single-user: the owner string is always `"local-user"` (hard-coded in `Auth.session`).

---------------------------------------------------------------------------------------------------

## 1. Configuration

### 1.1 `.env` loading (config.ts, runs at import time)
- If `./.env` exists (relative to CWD): parse it; values **do not override** variables already set in the process environment. For every key whose env value is set and differs from the file value, print one warning:
  `[OpenMuse] Using K1, K2 from the environment instead of .env. ` + (`Unset it to use the .env value.` if 1 key, else `Unset them to use the .env values.`).
- Then `COPILOTKIT_TELEMETRY_SAMPLE_RATE` defaults to `"1"` if unset (CopilotKit-specific; irrelevant for Erlang unless you proxy CopilotKit).

### 1.2 Variables (readConfig)

Validation order matters for which error is reported first; reproduce it: WORKSPACE_MODE → AGENT_BACKEND → live+sample check → JEV_MODE → TYPESAFE_API_KEY → COMPUTER_PROVIDER → E2B checks → (build config; CPK_INTELLIGENCE_API_KEY required inside) → live secrets → sample loopback.

| Env | Config field | Default | Validation / notes |
|---|---|---|---|
| `WORKSPACE_MODE` | mode | `sample` | must be `sample`\|`live`, else `WORKSPACE_MODE must be sample or live` |
| `AGENT_BACKEND` | agentBackend | `sample` if mode=sample else `model` | `sample`\|`model`\|`agui` else `AGENT_BACKEND must be sample, model or agui`. live+sample → `Live workspaces cannot use the sample agent` |
| `JEV_MODE` | jevMode | `off` | `off`\|`sample`\|`live` else `JEV_MODE must be off, sample or live` |
| `TYPESAFE_API_KEY` | typesafeApiKey (trimmed) | — | required nonblank if JEV_MODE=live: `JEV_MODE=live requires a nonblank TYPESAFE_API_KEY` |
| `JEV_MODEL` | jevModel | `jev-1.13.0` | trimmed; blank → default |
| `COMPUTER_PROVIDER` | computerProvider | `docker` | trimmed; blank → docker; `docker`\|`e2b-desktop` else `COMPUTER_PROVIDER must be docker or e2b-desktop` |
| `E2B_API_KEY` | e2bApiKey (trimmed) | — | only if `COMPUTER_ENABLED==="true"` AND provider e2b-desktop: required (`COMPUTER_PROVIDER=e2b-desktop requires a nonblank E2B_API_KEY`), and `COMPUTER_DEPLOYMENT_ID` trimmed nonblank required (`COMPUTER_PROVIDER=e2b-desktop requires a unique COMPUTER_DEPLOYMENT_ID, e.g. from \`openssl rand -hex 12\``) |
| `PORT` | port | `8787` | `Number(...)` – no further validation (NaN possible) |
| `PUBLIC_API_URL` | publicUrl | `http://localhost:${port}` | used for signed URLs, OAuth redirect, origin allow-list, computer deployment hash. Must have no path prefix (see §3.3) |
| `HOST` | host | `127.0.0.1` | sample mode: must be one of `127.0.0.1`,`localhost`,`::1` else `Sample workspace is local-only. HOST must be a loopback address.` |
| `DATA_DIR` | dataDir | `.openmuse` | resolved to absolute path against CWD |
| `DATABASE_URL` | databaseUrl | — | Postgres URL; if absent, embedded DB at `${dataDir}/postgres` |
| `OPENMUSE_ACCESS_KEY` | accessKey | — | live: required, length ≥ 24 (JS length = UTF-16 units) |
| `TOKEN_ENCRYPTION_KEY` | encryptionKey | — | live: required (presence only here; format validated by vault on use: canonical base64 of exactly 32 bytes) |
| live-mode failure message | | | `Live mode requires OPENMUSE_ACCESS_KEY (24+ characters) and TOKEN_ENCRYPTION_KEY (32-byte base64)` |
| `MODEL` | model | — | e.g. `openai/<id>` |
| `AGENT_URL`, `AGENT_TOKEN` | agentUrl, agentToken | — | for agui backend |
| `CPK_INTELLIGENCE_API_KEY` | intelligenceApiKey | — | **required in every mode** (trimmed nonblank) else error: `OpenMuse requires CPK_INTELLIGENCE_API_KEY. Run \`npx copilotkit@latest login\` and \`npx copilotkit@latest project select\`, then set the generated server-only key. See https://docs.copilotkit.ai/intelligence/connect-your-runtime`. Asserted again in createApp |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | googleClientId/Secret | — | optional; OAuth needs both + encryption key |
| (derived) | googleRedirectUri | `${publicUrl}/api/google/callback` | |
| `BROWSER_WORKER_URL` | workerUrl | — | trimmed; blank → unset; if no `://` prefix `http://` (accepts `host:port`) |
| `WORKER_TOKEN` | workerToken | — | browser enabled iff workerUrl && workerToken |
| `TASK_WORKER_ENABLED` | taskWorkerEnabled | true | false only if exactly `"false"` |
| `WEB_SEARCH_ENABLED` | webSearchEnabled | true | false only if exactly `"false"` |
| `COMPUTER_ENABLED` | computerEnabled | false | true only if exactly `"true"` |
| `COMPUTER_IMAGE` | computerImage | `openmuse-computer:local` | validated at use: `^[a-zA-Z0-9][a-zA-Z0-9._/:@-]{0,250}$` else AppError 503 `COMPUTER_IMAGE is invalid` |
| `COMPUTER_DEPLOYMENT_ID` | computerDeploymentId | — (falls back to publicUrl for hashing) | |
| `COMPUTER_E2B_TEMPLATE` | computerE2bTemplate | `desktop` | trimmed; blank → default |
| `ALLOWED_ORIGINS` | allowedOrigins | `http://localhost:8081,http://127.0.0.1:8081` | split on `,` (no trim!) |
| `TRUST_PROXY` | trustProxy | false | true only if exactly `"true"` |
| `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/`GOOGLE_API_KEY` | (read directly) | — | `agentConfigured` (below) |
| `OPENAI_BASE_URL`, `ANTHROPIC_BASE_URL`, `GOOGLE_GENERATIVE_AI_BASE_URL`, `OPENAI_CHAT_COMPLETIONS` | model provider (other spec) | | |
| Docker client env passthrough | | | `PATH, HOME, DOCKER_HOST, DOCKER_CONTEXT, DOCKER_CONFIG, DOCKER_TLS_VERIFY, DOCKER_CERT_PATH` (only these are passed to the `docker` child) |
| `E2B_DOMAIN` | (E2B SDK) | | only non-default E2B clusters |
| Browser worker (separate Node process) | | | `WORKER_TOKEN` (≥32 chars), `WORKER_DATA_DIR` (default `.openmuse/browser-profiles`; `/data` in its image), `WORKER_HOST` (default `127.0.0.1`; `0.0.0.0` in image). Port fixed 8790 |

Constant `MODEL_MAX_RETRIES = 2` (provider SDK retries; other spec).

`agentConfigured(config)` = `agentBackend=="sample"` OR (`agui` AND agentUrl set) OR (`model` AND MODEL set AND any of OPENAI/ANTHROPIC/GOOGLE_API_KEY set (non-empty)).

### 1.3 Processes
- `index.ts` (API): readConfig → store (`dataDir/postgres` or DATABASE_URL) → `recoverInterruptedActions` → createApp → if taskWorkerEnabled start agent loop → listen `host:port`; log `OpenMuse ${mode} API ready at ${publicUrl}`. SIGINT/SIGTERM: stop accepting → agent.stop → db.close → exit 0.
- `worker-entry.ts` (separate task worker): requires DATABASE_URL (`A separate task worker requires DATABASE_URL. Embedded PGlite runs inside the API process.`), createApp (no HTTP listen), agent.start; log `OpenMuse task worker running`; signals stop idempotently, exit 1 on stop error. Shares `DATA_DIR` with API (PDF blobs, signing key, screenshots).

---------------------------------------------------------------------------------------------------

## 2. HTTP application (app.ts)

### 2.1 Startup wiring
`assertApiDeploymentConfig` (CPK key) → `createAuth` (creates dataDir 0700 + signing key) → Files, GoogleAuth, WorkspaceService, ActionService, BrowserService, ComputerService, AgentService, CopilotKit runtime.
Allowed origin set = `allowedOrigins ∪ {origin(publicUrl)}` (origin = `scheme://host[:port]`, default ports dropped).

### 2.2 Middleware pipeline (exact order)
1. **Origin gate** (all paths): if request has `Origin` header and it is not in the set → `403 {"error":"Origin is not allowed"}` immediately (no security headers, no CORS headers). Otherwise set response headers `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, continue.
2. **CORS** (Hono `cors`, all paths): `Access-Control-Allow-Origin: <request origin>` only when origin in set (no header when Origin absent); `Access-Control-Allow-Credentials: true`; `Vary: Origin`. Preflight (`OPTIONS` with Access-Control-Request-Method): respond `204` with `Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,OPTIONS`, `Access-Control-Allow-Headers: Content-Type,Authorization`, and the above; **preflight terminates here** (never reaches body limit/rate limit/auth).
3. **Body limit** (all paths): 12 MiB = `12 * 1024 * 1024` = 12582912 bytes (checked by Content-Length, and while streaming). Over → `413 {"error":"Request is too large; PDFs must be 10 MB or smaller"}`.
4. **Rate limit** (`/api/*` only) – §2.4. Over → `429 {"error":"Too many requests. Try again in a minute."}`.
5. Unauthenticated routes registered here (they respond before step 6): `GET /api/health`, `POST /api/session`, `GET /api/google/callback`.
6. **Auth** (`/api/*`): signed-or-bearer, sets `owner` – §3.
7. Authenticated routes.
`GET /` is outside `/api` (no rate limit, no auth).
Unknown route: unauthenticated `/api/...` → 401 from auth; authenticated unknown → Hono default `404` text `404 Not Found`.

### 2.3 Error mapping (global onError)
All error bodies are `{"error": "<message>"}` JSON.
| Error | Status | Message |
|---|---|---|
| Validation (zod) | 422 | all issue messages joined with `"; "` |
| AppError(msg, status) | status (400 default; any of 400,401,403,404,409,413,422,429,500,502,503) | msg |
| `PdfError` or `RecurringEventError` | 422 | error.message |
| JSON SyntaxError (bad request JSON) | 400 | `Invalid request data` |
| `GoogleApiError` | 502 | `Google API (<status>): <detail>` |
| anything else (incl. OutcomeUnknownError, generic Error from Google client/search) | 502 | `Request failed. Check the server setup and try again.` |
For the 502 fallthrough log only `[OpenMuse] <error.name>` to stderr (never message/stack).
Zod default messages appear to clients (e.g. `Invalid input: expected string, received undefined`); exact wording is zod-v4-specific — Erlang just needs human-readable messages joined by `"; "`, status 422.

### 2.4 Rate limiter (rate-limit.ts)
Fixed-window per key, in-memory per process. `windowMs=60000`, `maxRequests=120`, `maxEntries=10000`.
```
take(key, now):
  e = map[key]; if e && e.expiresAt <= now: e = nil
  if !e:
     if size(map) >= 10000: delete all expired; if still >= 10000: return false   (reject new keys when full)
     e = {count:0, expiresAt: now+60000}; map[key]=e
  e.count += 1          (rejected requests still count)
  return e.count <= 120
```
Key: if TRUST_PROXY: first comma-separated element of `X-Forwarded-For` trimmed → `proxy:<ip>`; else if `X-Real-IP` → `proxy:<value>`; fallback (and when not trusting proxy) `conn:<socket remote address>` or `conn:unknown`. Never key on Authorization.

Separate **login limiter** (POST /api/session only, global, not per-IP): window start + counter; if `now - windowStart > 60000` reset (windowStart=now, attempts=0); `attempts += 1`; if `> 30` → AppError 429 `Too many sign-in attempts. Try again in a minute.` Note: counts successes too; applies before the access-key check.

### 2.5 Domain shapes (JSON)
```
Mail = {id, threadId, from, sender, to:[string], subject, body, date:ISO|"" , unread:bool, label, attachments:[string]}
CalendarEvent = {id, calendarId, title, start, end, allDay:bool, timeZone, location, description, attendees:[email]}
   start/end: all-day → "YYYY-MM-DD"; timed → RFC3339 with offset
Artifact = {id, name, mimeType:"application/pdf", size, pageCount, url, createdAt:ISO, source, parentId?, fields?:[{name,value,type:"text"|"checkbox"|"unsupported"}]}
BrowserSession = {id, title, url, status:"idle"|"active"|"closed"|"error", updatedAt:ISO, previewUrl?, consoleUrl?}
Connection = {id, name, status:"connected"|"disconnected"|"sample"|"unconfigured"|"unavailable", account?, capabilities:[string]}
Workspace = {mode, profile:{name,email}, mail:[Mail], events:[CalendarEvent], files:[Artifact], browsers:[BrowserSession],
             actions:[ActionProposal], activity:[ActivityEntry], connections:[Connection],
             runtime:{provider:"sample"|"model", configured:bool, openbotConfigured:false, richThreads:true}}
ActionProposal = {id, title, kind, data, status, hash, createdAt, expiresAt, result?, error?, target?, targetVersion?, taskId?, account?, connectionId?}
ActivityEntry = {id, title, detail, date, status, actionId?}
ComputerCommand = {id, command, actionHash?, cwd, status:"running"|"succeeded"|"failed"|"timed_out"|"interrupted", exitCode?, stdout, stderr, truncated, startedAt, completedAt?}
ComputerSnapshot = {enabled, provider:"docker"|"e2b-desktop", status:"unconfigured"|"stopped"|"running"|"error", workspacePath:"/workspace", network:"disabled"|"enabled", message?, commands:[ComputerCommand]}
ComputerDirectory = {path, entries:[{name, path, type:"file"|"directory"|"symlink", size}]}
```
Optional fields are omitted (not null) when absent.

Validation schemas:
- **emailDraft**: `to` 1..50 emails; `cc`,`bcc` 0..50 emails default `[]`; `subject` trimmed, 1..998 chars, no CR/LF (`Subject must be a single line`); `body` 1..100000; `attachmentIds` ≤10 strings default `[]`; `threadId?`, `replyToMessageId?` strings.
- **eventDraft**: `calendarId` default `primary`; `title` trimmed 1..500; `start`,`end` nonempty; `allDay` default false; `timeZone` default `America/Los_Angeles` (must be valid IANA zone → `Invalid time zone`); `location` ≤2000 default ""; `description` ≤10000 default ""; `attendees` ≤50 emails default []. Refinements: both parse as dates and end > start (`End must be after a valid start`); all-day → both `YYYY-MM-DD` valid dates (`All-day events need valid date-only values`); timed → match `^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$` and first 10 chars a valid date (`Timed events need valid date-times with an explicit offset`).
- **proposal** (discriminated on `kind`): `email.send`→emailDraft; `calendar.create`→eventDraft; `calendar.update`→eventDraft + `eventId` (≥1); `calendar.delete`→`{calendarId:string, eventId:≥1, title:string}`.
- **calendarRange**: `timeMin`,`timeMax` ISO datetimes **with** offset (`Z` or `±HH:MM`); `0 < timeMax-timeMin ≤ 366*86400000` ms else `Calendar range must end after it starts and span at most 366 days`.

### 2.6 Route catalogue

Auth column: **none**, **bearer** (`Authorization: Bearer <token>`), **bearer|signed** (signed URL accepted when `signature` query param present).
Status 200 unless noted. JSON bodies parsed strictly as JSON (invalid → 400). For zod objects unknown keys are stripped (not rejected).

| # | Method & path | Auth | Request | Response |
|---|---|---|---|---|
| 1 | `GET /` | none | — | `{"name":"OpenMuse","app":"http://localhost:8081","health":"/api/health"}` |
| 2 | `GET /api/health` | none | — | `{ok:true, mode, agentConfigured:bool, browserConfigured: workerUrl&&workerToken}` |
| 3 | `POST /api/session` | none | `{accessKey?: string}` (body must be JSON object; empty body → 400) | `{token, mode}` |
| 4 | `GET /api/google/callback` | none | query `state`,`code`,`error` | HTML |
| 5 | `GET /api/workspace?q=` | bearer | — | Workspace |
| 6 | `GET /api/calendars` | bearer | — | `[{id,name,timeZone,accessRole}]` |
| 7 | `GET /api/calendar/events` | bearer | query `calendarId?`(1..1024), `timeMin?`,`timeMax?` (ISO with offset) | `[CalendarEvent]` |
| 8 | `GET /api/mail/threads/:id` | bearer | — | `[Mail]` sorted by date asc |
| 9 | `POST /api/actions` | bearer | proposal | **201** ActionProposal |
| 10 | `POST /api/actions/:id/decide` | bearer | `{hash:string, decision:"approve"\|"deny"}` | ActionProposal (other spec) |
| 11 | `GET /api/drafts` | bearer | — | `[draft]` |
| 12 | `POST /api/drafts` | bearer | emailDraft + `id?` (uuid) | **201** draft |
| 13 | `GET /api/main-thread` | bearer | — | `{threadId, existing:true}` |
| 14 | `GET /api/conversation` | bearer | — | `{id:"default", messages}` or `{messages:[]}` |
| 15 | `PUT /api/conversation` | bearer | `{messages:[AG-UI Message] (≤1000)}` | `{ok:true}` |
| 16 | `POST /api/files` | bearer | multipart/form-data field `file` | **201** Artifact |
| 17 | `GET /api/files/:id/content` | bearer\|signed | — | PDF bytes |
| 18 | `POST /api/files/:id/fill` | bearer | `{fields:{name: string\|bool}}` | **201** Artifact |
| 19 | `POST /api/mail/import-attachment` | bearer | `{reference:string}` | **201** Artifact |
| 20 | `POST /api/google/connect` | bearer | `{capability:"read"\|"write"}` | `{url}` or `{url:null, connected:true}` |
| 21 | `POST /api/google/disconnect` | bearer | (body ignored) | `{ok:true}` |
| 22 | `POST /api/browsers` | bearer | `{url}` (valid URL, ≤4096) | **201** BrowserSession (decorated) |
| 23 | `GET /api/browsers/:id` | bearer | — | BrowserSession (decorated) |
| 24 | `POST /api/browsers/:id/navigate` | bearer | `{url}` | BrowserSession (decorated) |
| 25 | `POST /api/browsers/:id/close` | bearer | — | BrowserSession (decorated) |
| 26 | `GET /api/browsers/:id/read` | bearer | — | `{url,title,text,truncated}` |
| 27 | `POST /api/browsers/:id/reopen` | bearer | optional body `{url?}` (empty body allowed) | BrowserSession (decorated) |
| 28 | `POST /api/browsers/:id/import-downloads` | bearer | — | `{files:[Artifact], failures:[DownloadFailure]}` |
| 29 | `GET /api/browsers/:id/preview` | bearer\|signed | — | `image/png` |
| 30 | `GET /api/browsers/:id/console` | bearer\|signed | — | HTML (+CSP) |
| 31 | `POST /api/browsers/:id/console` | bearer\|signed | any JSON object (browser input) | `{ok:true}` |
| 32 | `ALL /api/copilotkit/*` | bearer (runtime) | CopilotKit | proxied SSE; 503 if !agentConfigured: `Configure a model and provider API key, or a valid AG-UI endpoint, to start chat` |
| 33 | `/api/agent/*` | bearer | — | other spec (engine/routes.ts: GET `/`, POST `/tasks`, GET `/tasks/:id`, POST `/tasks/:id/control`, `/tasks/:id/input`, `/goals`, `/goals/:id`, `/goals/:id/milestones/:milestoneId`, `/monitors`, `/monitors/:id/control`, `/ideas/refresh`, `/ideas/:id`, `/memories`, `/memories/:id`, `/memories/:id/forget`, `/identity`, GET `/notifications`, POST `/notifications/:id/read`, `/sample-page`) |
| 34–46 | `/api/computer/*` | bearer | see §6.9 | |

Route details:

**#3 POST /api/session** — login limiter → `auth.session(accessKey)` (§3.1) → `workspace.ensureSample("local-user")` (sample mode only, §4.3) → `agent.ensure("local-user")` → if sample mode `agent.refreshIdeas("local-user")` → return session JSON. Errors: 401 `Access key is incorrect` (live), 429.

**#4 GET /api/google/callback** — if query `error` present: `400` HTML `<h1>Google connection cancelled</h1><p>You can return to OpenMuse.</p>`. If missing `state` or `code`: AppError 400 `Google callback is incomplete` (JSON). Else `google.callback(state, code)` (§9.2), success HTML 200: `<h1>Google is connected</h1><p>Return to OpenMuse and refresh your workspace.</p>`. Errors from callback are JSON (onError). HTML responses: `Content-Type: text/html; charset=UTF-8`.

**#5 GET /api/workspace** — `snapshot(owner, q)` (§4.4) concurrently with `browser.reachable()` (§7.2). Then every `browsers[i]` decorated with signed `consoleUrl`/`previewUrl`; if connection `browser` has status `connected` and worker unreachable → status `unavailable`.

**#7** — after parsing, if both timeMin and timeMax present, apply calendarRange check (422). Returns `workspace.events` (empty array if Google disconnected).

**#8** — 409 `Google is disconnected` / 404 `Mail thread not found` (§4.5).

**#9 POST /api/actions** — parse proposal; if `email.send`, each `attachmentIds` must be an owned file (`files.get` → 404 `File not found`); then `actions.propose(owner,input)` → 201.

**#12 POST /api/drafts** — if `id` given and no existing draft → 404 `Draft not found`. Stored & returned record = parsed draft (defaults applied, subject trimmed) + `id` (given or uuid) + `createdAt` (existing createdAt preserved, else now ISO). Status 201 for both create and update.

**#13 GET /api/main-thread** — `insertIfAbsent(conversation-settings,{id:"main",threadId:uuid(),existing:false})`; read back (missing → 503 `Main conversation could not be loaded`); call CopilotKit Intelligence `getOrCreateThread({threadId, userId:owner, agentId:"default"})`; failure → 502 `Main conversation is unavailable. Check the Rich Threads connection and try again.` Return `{threadId, existing:true}` (literal true).

**#15 PUT /api/conversation** — `messages` must be array ≤1000 and each element must validate as an AG-UI `Message` (@ag-ui/core MessageSchema: discriminated on `role` ∈ developer/system/assistant/user/tool/activity/reasoning…, `id` string, `content`, tool calls, etc.). Store `{id:"default", messages}`. If body lacks `messages` → 422.

**#16 POST /api/files** — multipart; field `file` must be a file part, else 400 `Choose a PDF file`. `files.import(owner, filename, bytes, "Uploaded by you")` (§5) → 201.

**#17 GET /api/files/:id/content** — `files.get` (404 for non-uuid or unknown). Headers `Content-Type: application/pdf`, `Content-Disposition: inline; filename*=UTF-8''<encodeURIComponent(name)>`. Body = stored bytes. (encodeURIComponent: escape everything except `A-Z a-z 0-9 - _ . ! ~ * ' ( )`.)

**#18** — §5.4. **#19** — §4.6.

**#20 POST /api/google/connect** — sample mode: `put settings {id:"google", enabled:true, connectionId:uuid()}` → `{url:null, connected:true}`. Live: `google.connect(owner, capability=="write")` → `{url}` (§9.1); 503 if not configured.

**#21** — sample: `put settings {id:"google", enabled:false}`; live: `google.disconnect(owner)` (§9.4).

**#27 reopen** — read raw text; empty → `{}`; else JSON.parse (SyntaxError → 400); `{url?: url ≤4096}`.

**#29 preview** — `Content-Type: image/png`, body = worker PNG bytes.

**#30 console GET** — first `browser.get` (404 if not owned). Header `Content-Security-Policy: default-src 'self'; img-src 'self' blob:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'`. Body = §7.5 HTML.

**#31 console POST** — `browser.input(owner,id, json)`: body must be a non-array object else 422 `A JSON object is required for browser input`. Response `{ok:true}`.

---------------------------------------------------------------------------------------------------

## 3. Authentication & signing (auth.ts)

### 3.1 Session tokens
`session(accessKey?)`:
- live mode: reject (401 `Access key is incorrect`) unless accessKey present AND config.accessKey present AND `constant_time_eq(sha256(accessKey), sha256(config.accessKey))` (hash both first so lengths match).
- sample mode: any/no key accepted.
- `token = base64url_nopad(random 32 bytes)` (43 chars).
- `put("system","sessions",{id: sha256hex(token), owner:"local-user", expiresAt: now_ms + 86400000})` (24 h).
- returns `{token, mode}`. Sessions are never deleted/revoked (no logout endpoint).

`owner(authorizationHeader)`:
- header missing or not starting with exact `"Bearer "` → 401 `Sign in to OpenMuse`.
- lookup `system/sessions/sha256hex(header[7:])`; missing or `expiresAt < now` → 401 `Session expired. Sign in again.`
- return `owner` field.

### 3.2 Signing key file
`${DATA_DIR}/session-signing-key`:
- `mkdir -p DATA_DIR` mode 0700.
- Read the file as UTF-8 string (exact content, no trim). If ENOENT: `key = base64_std_padded(random 32 bytes)` (44 chars); write to `${path}.${hex(random16)}.tmp` with mode 0600 and O_EXCL; `link(tmp, path)` (hard link, atomic publish without overwriting); on EEXIST read the existing file instead; always unlink tmp.
- **The HMAC key is the UTF-8 bytes of the 44-char base64 text, NOT the decoded 32 bytes.** Erlang: `crypto:mac(hmac, sha256, KeyText, Msg)` with `KeyText` the file binary.
- Any other read error is fatal at startup.

### 3.3 Signed URLs
`sign(owner, path)`:
```
expires   = integer_to_list(now_ms + 900000)        % 15 min, decimal ms
signature = hex_lower(HMAC_SHA256(key, owner ++ "\n" ++ path ++ "\n" ++ expires))
url       = publicUrl ++ path ++ "?owner=" ++ encodeURIComponent(owner) ++ "&expires=" ++ expires ++ "&signature=" ++ signature
```
Paths signed: `/api/files/<id>/content`, `/api/browsers/<id>/console`, `/api/browsers/<id>/preview`.

`verify(url)` (invoked by auth middleware only when the request path matches
`^/api/files/[^/]+/content$` or `^/api/browsers/[^/]+/(?:preview|console)$` **and** the `signature` query param is non-empty; otherwise bearer auth):
- `owner` = query owner (URL-decoded), `expires`, `signature` (missing → "").
- Fail with 401 `Document link expired; refresh the workspace` if owner empty, expires not `^\d+$`, `expires < now_ms`, or signature not `^\w{64}$`.
- expected = HMAC over `owner\n<request pathname>\n<expires>` (pathname = raw path of the incoming request URL, no query).
- constant-time compare of the hex strings (64 bytes each) → mismatch 403 `Invalid access link`.
- returns owner (authorizes as that owner).
Consequence: if the server sits behind a path-prefixing proxy, signatures break (signer uses `path`, verifier uses the server-visible pathname). Methods are not bound: the signed console URL authorizes both GET and POST on that path.

---------------------------------------------------------------------------------------------------

## 4. Workspace (workspace.ts)

### 4.1 What it is
A façade over "the user's Google account" with two backends selected by `WORKSPACE_MODE`:
- **sample**: a fictional local mailbox/calendar stored in the records table (`mail`, `events`, `settings/google`), seeded on first sign-in. Google "connection" is a toggle in `settings/google`. Writes (send email, calendar CRUD) are applied locally.
- **live**: real Gmail + Google Calendar via OAuth tokens (§9). Mail/events fetched are cached into `mail`/`events` records (cache is write-only for live reads except `importAttachment` which needs the cached mail).

### 4.2 Connection helpers
- `connection(owner)`:
  - sample: `s = settings/google`; if `s.enabled === false` → null; else `{id: s.connectionId ?? "sample-google", account:"alex@example.com"}` (connected even when record missing).
  - live: tokens = decrypted credential; `{id: tokens.connectionId, account: tokens.account}` or null.
- `connected(owner)`: sample → `settings/google.enabled !== false`; live → tokens exist.

### 4.3 Sample seed (`ensureSample`, sample mode only, run on every POST /api/session)
De-duplicated per owner in-process (concurrent callers await the same promise). If `settings/seeded` exists → no-op. Otherwise, in order:
1. Import the generated sample PDF (§5.5) via `files.import(owner, "Field trip permission slip.pdf", bytes, "Gmail · Lincoln Middle School")` → `file` (random uuid id).
2. `at(h,m)` = today (server local TZ) at h:m:00.000, as ISO UTC.
3. Put 4 mails (all `to:["alex@example.com"]`):

| id | threadId | sender | from | subject | date | unread | label | attachments |
|---|---|---|---|---|---|---|---|---|
| mail-fieldtrip | trip-thread | Lincoln Middle School | office@lincoln.example | A little reminder: permission slips are due Friday | at(8,42) | true | School | [file.id] |
| mail-design | design-thread | Jamie Chen | jamie@example.com | Coffee and a catch-up? | at(8,15) | true | Personal | [] |
| mail-stay | stay-thread | The Seabird | stay@seabird.example | Your weekend, all sorted | at(7,30) | false | Travel | [] |
| mail-studio | studio-thread | Studio North | hello@studionorth.example | Notes from our last conversation | now − 86400000 ms | false | Work | [] |

Bodies (verbatim, `\n` newlines, curly apostrophes U+2019 preserved):
- fieldtrip: `Hi Alex,\n\nOur class is heading to the aquarium this Friday. Please complete the attached permission slip and send it back when you have a moment.\n\nWe’ll leave school at 8:15 AM and return by 4:30 PM. Please pack lunch and a water bottle.\n\nThank you!\nMs. Rivera\n\nThis message is included with your local workspace.`
- design: `Hey Alex,\n\nWould love to catch up this week. I’m free Thursday afternoon. How does 3 PM at Bluebird Coffee sound?\n\nJamie\n\nThis invitation is part of your local workspace.`
- stay: `Your reservation is confirmed.\n\nCheck-in: Friday, 3 PM\nCheck-out: Sunday, 11 AM\n\nThis fictional reservation demonstrates how OpenMuse can organize travel details.`
- studio: `Thanks for a thoughtful conversation yesterday. Let’s use our next session to review the prototype and pick the three flows for testing.\n\nThis project is part of your local workspace.`

Note in sample mode `attachments` holds an **artifact id**, not a Gmail reference.

4. Put 3 events; common base `{calendarId:"primary", allDay:false, timeZone:<server IANA TZ>, description:"A little time to catch up", attendees:[]}`:

| id | title | start | end | location |
|---|---|---|---|---|
| event-standup | A slow start · morning walk | at(9) | at(9,30) | Neighborhood |
| event-review | Design catch-up | at(11) | at(11,45) | Studio North |
| event-lunch | Lunch with Maya | at(13) | at(14) | Little Saint |

5. `actions.propose(owner, {kind:"calendar.create", data:{...base, title:"Coffee with Jamie", start:at(15), end:at(16), location:"Bluebird Coffee", description:"Catch up over coffee", attendees:["jamie@example.com"]}})` — a pending approval card.
6. `put settings {id:"google", enabled:true}`; `put settings {id:"seeded", value:true}`.

Fixtures are **code, not files**: mails/events in `apps/server/src/workspace.ts::seed`, PDF in `packages/integrations/src/pdf.ts::createSamplePdf`. (Demo-only fixtures in `apps/server/src/demo/` are not used by this path.)

### 4.4 `snapshot(owner, q?)`
`sourceSections(owner, wantMail=true, wantEvents=true, q)`:
- live & connected: `connection` (null → 409 `Google is disconnected`); in parallel `google.listMail(q)` (q undefined → `in:inbox`) and `google.listEvents()` (default window §9.6); mail → `cacheMail`; each event `put events`.
- sample & connected: mail = all `mail` records; if q non-empty filter case-insensitive substring of `"${sender} ${subject} ${body}"` (whole q as one substring; note: different from searchMail); events = all `events` records (unfiltered by time).
- disconnected: both empty.
Result:
```
{ mode,
  profile: {name: sample?"Alex":"You", email: tokens.account ?? (sample?"alex@example.com":"")},
  mail: sorted by date desc (string compare), events: sorted by start asc (string compare),
  files: files.list(owner) (signed urls), browsers: list browsers, actions: list actions, activity: list activity,
  connections: [
    {id:"google", name:"Google", status: connected ? (sample?"sample":"connected") : "disconnected",
     account: tokens.account ?? (sample?"alex@example.com": omitted), capabilities: sample?["Gmail","Calendar"]:(tokens.scopes ?? [])},
    {id:"browser", name:"Browser", status: workerUrl&&workerToken ? "connected":"unconfigured", capabilities:["Persistent sessions","PDF downloads"]},
    {id:"openbot", name:"OpenBot", status:"unconfigured", capabilities:["Integration adapter available"]}],
  runtime: {provider: agentBackend=="sample"?"sample":"model", configured: agentConfigured, openbotConfigured:false, richThreads:true} }
```
(live capabilities are full scope URLs.)

`sectionSnapshot(owner, section ∈ mail|calendar|files|all)` (agent tool `read_workspace`): same sources without query; returns `{mail?, events?, files?}` where files omit `url`; absent sections are omitted.

### 4.5 Mail & calendar reads
- `cacheMail(owner, mail[], connId)`: load all `imports`; for each message replace each attachment reference `ref` by `imports[ref].artifactId` when that import's `connectionId == connId`; `put mail {...message, connectionId}`; return mapped messages (without connectionId).
- `thread(owner, id)`: no connection → 409 `Google is disconnected`. sample: mail records with `threadId==id`; live: `google.getThread(id)` → cacheMail. Empty → 404 `Mail thread not found`. Sorted date asc.
- `searchMail(owner, query)` (agent): 409 if disconnected. live: `listMail(query || "in:inbox")` → cacheMail. sample: words = lowercase(trim(query)) split on whitespace; keep mails whose label does not match `^Sent\b` (case-insens.) and whose lowercase `"${sender} ${from} ${subject} ${body}"` contains every word; sort date desc. Agent tool returns `{matches: first 20 as {id,threadId,sender,from,subject,date,snippet: body[0:240]}, truncated: n>20}`.
- `calendars(owner)`: none → `[]`; sample → `[{id:"primary", name:"Personal", timeZone:<server TZ>, accessRole:"owner"}]`; live → `listCalendars()`.
- `eventsPage(owner, {calendarId?, timeMin?, timeMax?})` → null if disconnected; live → `google.listEventsPage(opts)`; sample:
  - candidates: `events` records with `calendarId == (calendarId ?? "primary")`.
  - timed: keep if `(!timeMax || start < timeMax) && (!timeMin || end > timeMin)` (compare as instants).
  - all-day: `lastIncluded = timeMax − 1 ms`; keep if `(!timeMax || date(start) <= localDate(lastIncluded, event.timeZone)) && (!timeMin || date(end) > localDate(timeMin, event.timeZone))` where `localDate(i, tz)` = calendar date of instant i in tz (`YYYY-MM-DD`, years outside 0..9999 as `±YYYYYY`), compared as parsed dates.
  - sort by start asc (string); `{events, truncated:false}`.
  - `events()` = `eventsPage(...).events ?? []`.
  Agent tool `read_calendar(range)` returns `{calendarId:"primary", timeMin, timeMax, events: first 20 without attendees with title≤500, location≤500, description≤2000 chars (drop a dangling high surrogate), truncated}` or `{error}`.

### 4.6 `importAttachment(owner, reference)`
1. No connection → 409 `Google is disconnected`.
2. `imports/<reference>` exists with same connectionId → return its artifact (signed).
3. `[messageId, attachmentId, filename] = reference.split(":")` (any missing → 400 `Attachment reference is invalid`). In sample mode references are artifact ids → always 400 here (sample PDFs are already Files).
4. `mail/<messageId>` must exist, include `reference` in `attachments`, and have `connectionId == connection.id`, else 404 `Attachment not found. Refresh the current account's inbox.`
5. `bytes = google.getAttachment(messageId, attachmentId)`; `files.import(owner, decodeURIComponent(filename), bytes, "Gmail · " ++ mail.subject, parentId=undefined, operationKey = JSON.stringify(["attachment", connection.id, reference]))` (deterministic id §5.2).
6. `put imports {id:reference, artifactId:file.id, connectionId}` → return file.

### 4.7 Action prepare/execute (called by ActionService)
`prepare(owner, input, connId)`:
- email.send: every attachmentId must be an owned file (404) → `{input}`.
- calendar.create, or sample mode → `{input}`.
- live update/delete: `google.reviewEvent(calendarId, eventId)` → `{input (delete: data.title replaced by reviewed title), target: event, targetVersion: etag}`.

`execute(owner, input, connId, targetVersion)` → result string:
- sample:
  - email.send: id=uuid; `put mail {id, threadId: data.threadId ?? id, sender:"You", from:"alex@example.com", to, subject, body, date:now, unread:false, label:"Sent · local", attachments: attachmentIds}` → `Saved to local sent mail · <id>`.
  - calendar.delete: remove event → `Removed from local calendar`.
  - create/update: id = update ? eventId : uuid; `put events {...data, id}` → `Saved to local calendar · <id>`.
- live:
  - tokens missing → 409 `Google is disconnected`.
  - required scope `https://www.googleapis.com/auth/` + (`gmail.send` for email, else `calendar.events`) not in tokens.scopes → 403 `Enable Google write access in Connections before approving`.
  - `tokens.connectionId != connId` → 409 `Google account or connection changed. Prepare a new action.`
  - update/delete without targetVersion → 409 `This calendar review predates target-version checks. Prepare a new review.`
  - email: attachments = `{name, mimeType, bytes}` of each file → `sendEmail` → `Gmail sent message · <id>`.
  - delete: `deleteEvent(calId, eventId, targetVersion)`; remove local event → `Deleted Google Calendar event · <eventId>`.
  - create → `createEvent`; update → `updateEvent(eventId, data, targetVersion)`; `put events` → `Google Calendar event · <id>`.

---------------------------------------------------------------------------------------------------

## 5. Files / documents store (files.ts, pdf.ts)

### 5.1 Layout
- Metadata: records `owner/files/<id>` = Artifact with `url:""` (signed URL added on read).
- Bytes: `${DATA_DIR}/files/<id>.pdf`, directory mode 0700, files mode 0600. Shared by API and task worker.
- id regex (v1–v8 UUID): `^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` (case-insens.); else 404 `File not found`. Resolved path must stay inside `${DATA_DIR}/files/`.
- Only PDFs are stored. Limits: bytes ≤ 10 MiB (10485760) else 413 `PDFs must be 10 MB or smaller`; pages ≤ 500 (`PDFs must have 500 pages or fewer`, 422 – normally pre-empted by PdfError).

### 5.2 `import(owner, name, bytes, source, parentId?, operationKey?)`
1. id = operationKey absent ? uuid() : `deterministicFileId(owner, operationKey)`:
   `b = sha256(JSON.stringify([owner, operationKey]))[0:16]; b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80;` format as 8-4-4-4-12 lowercase hex. (JSON.stringify of a 2-string array: `["owner","key"]`, standard JSON escaping, no spaces.)
2. keyed and record exists → return it signed (idempotent).
3. size check (413), `inspectPdf(bytes)` (§5.3, may raise PdfError 422), page check.
4. Write bytes: un-keyed → create exclusive (`wx`). Keyed → write `<path>.<uuid>.tmp` exclusive, `link(tmp, path)`; on EEXIST re-read existing file bytes and re-inspect; always remove tmp.
5. Artifact `{id, name: sanitizeFileName(name), mimeType:"application/pdf", size: byte length, pageCount, fields, url:"", createdAt: now ISO, source, parentId?}`.
6. un-keyed → `put`; keyed → `insertIfAbsent` (if lost race, return the existing one). Return signed.

`sanitizeFileName(name)`: take the last segment after `/` or `\`; drop code points whose first UTF-16 unit < 32 or == 127; keep first 180 code points; empty → `document.pdf`.
`signed(owner, f)` = f with `url = auth.sign(owner, "/api/files/<id>/content")`.
`list(owner)` → all records signed (order: updated_at desc). `get` → unsigned record or 404. `bytes` → get then read file.

### 5.3 PDF operations required (pdf-lib today)
Load (`loadPdf`):
- reject if empty, > 10 MiB, or `%PDF-` not found within the first 1024 bytes → PdfError `Invalid PDF: expected nonempty PDF bytes up to 10 MiB`.
- parse strictly (invalid objects throw); encrypted → `Encrypted PDFs are not supported` (also if any parse error message matches /encrypt/i); `/Root /AcroForm` dict containing `/XFA` → `Unsupported XFA PDF form`; page count must be 1..500 → `PDF must contain between 1 and 500 pages`; any other parse failure → `Invalid or malformed PDF`.

`inspectPdf(bytes)` → `{pageCount, fields:[{name, value, type}]}` for every AcroForm terminal field (fully-qualified name, dotted):
- Text field (`/FT /Tx`): if `/V` exists and is not a string (literal or hex) → PdfError `Cannot inspect PDF: a text field contains a malformed value`; value = decoded text or "" ; type `text`.
- Checkbox (`/FT /Btn` without radio/pushbutton flags): value `"true"`/`"false"` (checked = `/V` equals the on-state name, i.e. not `/Off`); type `checkbox`.
- Dropdown/listbox (`/FT /Ch`): value = selected values joined `", "`; radio group: selected option or ""; other (signature, pushbutton): ""; type `unsupported`.
- Any other failure → `Cannot inspect PDF: the document contains malformed or unsupported form fields`.

`fillPdf(bytes, values: name → string|bool)`:
- for each entry: unknown name → `Unknown PDF field: <name>`; text field needs string (`PDF text field requires a string: <name>`), length ≤ 10000 UTF-16 units (`PDF text field value is too long: <name>`), set `/V` (pdf-lib `setText` also clears `/RV` rich text and marks dirty); checkbox needs boolean (`PDF checkbox requires a boolean: <name>`), check → `/V` and `/AS` = on-state name, uncheck → `/Off`; any other type → `Unsupported PDF field: <name>`.
- **Strip actions**: walk every indirect object (recursively through dicts/arrays, cycle-safe) and delete keys `OpenAction`, `AA`, `A`, `JS`, `JavaScript` from every dictionary.
- Regenerate appearance streams for dirty fields using embedded standard font **Helvetica** (WinAnsi encoding; characters outside it fail) and save (full rewrite, pdf-lib default object streams). Failure here → `Could not render PDF field values; use characters supported by this form's font or choose a compatible PDF form`.
- Other failures → `Could not fill PDF: the document contains malformed or unsupported form fields`.
- All PdfErrors → HTTP 422 with the message.

Erlang recommendation: there is no mature Erlang PDF form library. Use a sidecar/port program (e.g. a tiny Node script reusing `pdf.ts` verbatim — simplest and byte-compatible; or Python `pikepdf`/`pypdf`; or `qpdf` + custom code). Interface suggestion: port/CLI with JSON in/out: `inspect(bytes) → {pageCount, fields}`, `fill(bytes, values) → bytes`, `sample() → bytes`, with errors returned as `{error:"PdfError", message}`.

### 5.4 `fill(owner, id, values, operationKey?)`
`file = get`; `out = fillPdf(bytes(file), values)`; `import(owner, name', out, "Filled from " ++ file.name, parentId=id, key')` where `name' = file.name with trailing /\.pdf$/i removed ++ " — filled.pdf"` (space, EM DASH U+2014, space) and `key' = JSON.stringify(["fill", operationKey, id, sortedEntries])` with `sortedEntries` = `[[name, value], …]` sorted by name (JS default sort = UTF-16 code unit order) — only when operationKey provided (agent tool passes `model:<taskId>:fill_pdf`; HTTP route passes none → new random id every time).

### 5.5 Sample PDF (`createSamplePdf`)
Two US-Letter pages (612×792 pt). Title `Community visit - permission form`, Author `OpenMuse`. Fonts Helvetica & Helvetica-Bold. Colors: ink rgb(0.12,0.19,0.2), teal rgb(0.18,0.4,0.4).
Each page: header rect (0,682,612,110) fill rgb(0.9,0.95,0.93); `OPENMUSE / COMMUNITY VISIT` bold 10 teal at (48,750); heading bold 28 ink at (48,710): page1 `Community visit`, page2 `Permission & contacts`; line (48,55)-(564,55) rgb(0.8,0.85,0.83) 1pt; footer `EXAMPLE FORM - no real participant or organization` 9 teal at (48,35); `1 / 2` / `2 / 2` at (535,35).
Page 1: `A day of discovery at the community museum` bold 16 at (48,640); lines (11pt, y = 606 − i·25): `Please complete both pages of this permission form.` / `The visit, organization, and schedule below are fictional.` / `Schedule: Saturday, October 10, 2026 / 10:00-14:00` / `Activities: guided exhibits, a sketching workshop, and a lunch break.` / `Bring: a packed lunch, water, and comfortable shoes.`; text fields (label bold 11 at y+40; widget x=48 w=516 h=30, border 1 rgb(0.65,0.75,0.71), white bg, font size 12): `participant_name` "Participant name" y=395; `guardian_name` "Parent or guardian name (if applicable)" y=305; note `Continue to page 2 for emergency contacts and permission.` 11 teal at (48,210).
Page 2: `emergency_contact` "Emergency contact name" y=580; `emergency_phone` "Emergency contact phone" y=490; `additional_notes` "Additional notes (optional)" y=375 multiline (h=62, label at y+72); checkbox `permission_granted` at (48,290) 18×18 border teal; text `I give permission for the participant to attend the community visit.` 11 at (78,295); `This checkbox records permission; it is not a digital signature.` 10 teal at (48,235).
Resulting inspection: 6 fields — 5 text (empty) + 1 checkbox (`"false"`), pageCount 2. Easiest Erlang path: generate once with the TS code and ship the bytes as a static fixture (`priv/sample-permission-slip.pdf`); bytes need not be reproduced exactly (only fields/pages matter).

---------------------------------------------------------------------------------------------------

## 6. Computer (computer.ts, computer-backend.ts, computer-routes.ts, computer-tools.ts, apps/computer)

### 6.1 Constants
| name | value |
|---|---|
| computerOutputLimit | 131072 (128 KiB) — combined stdout+stderr budget per command |
| hard output ceiling | 15 MiB (`min(maxOutputBytes, 15*1024*1024)`) |
| fileLimit (text read/write) | 262144 (256 KiB) |
| PDF limit (import/export) | 10 MiB |
| leaseDuration | 180000 ms |
| docker control timeout | 10000 ms |
| command in-container timeout | 30 s TERM, kill after 2 s; client timeout 35000 ms |
| file op | docker: in-container `timeout --kill-after=1s 8s`, client 10000 ms |
| receipts returned | newest 100 by startedAt |
| desktop resolution | 1280×800 |
| command schema | `command` trimmed 1..16000; `cwd` default `/workspace` |
| path schema | `path` 1..2048 |
| write schema | path + `text` ≤ 262144 chars (and ≤ 262144 UTF-8 bytes, else 413 `Text files must be 256 KB or smaller`) |

### 6.2 Identity
```
deployment = sha256hex(COMPUTER_DEPLOYMENT_ID ?? publicUrl)[0:16]
ownerHash  = sha256hex(owner)[0:24]
name       = "openmuse-" ++ deployment ++ "-" ++ ownerHash
container  = name ++ "-computer";  volume = name ++ "-workspace"
labels     = {"dev.openmuse.managed":"computer-v1", "dev.openmuse.deployment":deployment, "dev.openmuse.owner":ownerHash}
```
`workspacePath(p)`: reject (422 `Choose an absolute path inside /workspace`) if contains NUL, length > 2048, does not start with `/workspace`, or any `/`-segment equals `..`; posix-normalize; result must be `/workspace` or start with `/workspace/` (rejects `/workspacefoo`).

### 6.3 Docker runner
Spawn `docker` with an argv array (never a shell), env limited to the 7 passthrough vars, stdin = `input` or empty (closed after write), stdout/stderr captured into a shared byte budget (§6.1): each chunk takes `min(remaining, len)` bytes; if a chunk exceeds remaining → `truncated=true`. On timeout: `timedOut=true`, SIGKILL docker client. On abort signal (HTTP client disconnected / agent cancelled): `interrupted=true`, SIGKILL. Spawn failure: append to stderr `Docker CLI could not be started. Install Docker and start its engine.`, exitCode null. Result `{stdout(utf8), stderr(utf8), exitCode|null, timedOut, interrupted, truncated}`.
`checked(args)` (control ops, 10 s): timedOut → 503 `Docker did not respond within 10 seconds. Check the Docker engine.`; interrupted/exit≠0/truncated → 503 `Docker operation failed. Check that the engine is running and the computer image is built locally.`

### 6.4 Exact docker argv
Find container:
`["container","ls","--all","--filter","name=^/<container>$","--format","{{.ID}}"]` → empty trimmed stdout = missing.
Inspect: `["container","inspect","<container>"]` → JSON array of exactly 1, then isolation check (all must hold, else 409 `Computer ownership or isolation does not match this deployment; refusing to attach`; schema mismatch → 409 `Computer isolation inspection failed; refusing to attach`):
- `Name == "/<container>"`, `Config.Image == image`, `Config.User == "1000:1000"`, `Config.WorkingDir == "/workspace"`, all 3 labels equal;
- every `Config.Env` var name ∈ {PATH, HOME, LANG, NODE_VERSION, YARN_VERSION};
- `Entrypoint == ["/usr/bin/sleep"]`, `Cmd == ["infinity"]`;
- HostConfig: `ReadonlyRootfs`, `!Privileged`, `CapDrop` contains `ALL`, `CapAdd` empty/null, `SecurityOpt == ["no-new-privileges"]`, `NetworkMode=="none"`, `0 < Memory ≤ 536870912`, `MemorySwap == Memory`, `0 < PidsLimit ≤ 128`, `0 < NanoCpus ≤ 1e9`, Binds/Devices/DeviceRequests empty, no PortBindings, `PidMode==""`, `IpcMode=="private"`, `RestartPolicy.Name=="no"`, Tmpfs exactly `{"/tmp":"rw,nosuid,nodev,noexec,size=67108864,mode=1777"}`;
- exactly one mount: `Type volume, Name <volume>, Destination /workspace, RW true`; all network names == `none`;
- then verify volume.
Verify volume: `["volume","inspect","<volume>"]` → array of 1 with `Name==volume`, `Driver=="local"`, `Scope=="local"`, Options empty/null, all 3 labels → else 409 `Computer workspace ownership or isolation does not match` (schema mismatch: `Computer workspace ownership inspection failed`).
State: missing / running (`State.Running`) / stopped.

Start (container missing):
1. `["volume","ls","--filter","name=^<volume>$","--format","{{.Name}}"]`; if empty → `["volume","create","--label","dev.openmuse.managed=computer-v1","--label","dev.openmuse.deployment=<d>","--label","dev.openmuse.owner=<o>","<volume>"]`; verify volume.
2. Create:
```
["container","create","--pull","never","--name","<container>",
 "--label","dev.openmuse.managed=computer-v1","--label","dev.openmuse.deployment=<d>","--label","dev.openmuse.owner=<o>",
 "--user","1000:1000","--workdir","/workspace","--read-only","--cap-drop","ALL",
 "--security-opt","no-new-privileges","--network","none","--ipc","private",
 "--memory","512m","--memory-swap","512m","--cpus","1","--pids-limit","128","--restart","no",
 "--tmpfs","/tmp:rw,nosuid,nodev,noexec,size=67108864,mode=1777",
 "--mount","type=volume,source=<volume>,target=/workspace",
 "--env","HOME=/workspace","--env","LANG=C.UTF-8",
 "--entrypoint","/usr/bin/sleep","<image>","infinity"]
```
3. inspect (isolation check) → `["container","start","<container>"]`.
Start (exists, stopped): `["container","start","<container>"]`. Exists & running: no-op.
Stop: if inspect says running: `["container","stop","--time","2","<container>"]`.
Exec (command) — requires running (else 409 `Start the computer before using its terminal or files`):
```
["exec","--user","1000:1000","--workdir","<cwd>","<container>",
 "/usr/bin/timeout","--signal=TERM","--kill-after=2s","30s",
 "/bin/bash","--noprofile","--norc","-c","<command>"]      timeout 35000 ms, output cap 128 KiB
```
File op:
```
["exec","-i","--user","1000:1000","<container>",
 "/usr/bin/timeout","--kill-after=1s","8s","/usr/bin/python3","-I","/opt/openmuse/files.py"]
 stdin = JSON request; timeout 10000 ms; maxOutputBytes = read_pdf ? 15 MiB : 2 MiB
```
Session stop (cleanup after timeout/interrupt): `["container","stop","--time","2","<container>"]` (checked).

### 6.5 Image (apps/computer/Dockerfile)
`FROM node:22.22.0-bookworm-slim`; apt install `bash python3 git coreutils`; `mkdir -p /opt/openmuse /workspace && chown 1000:1000 /workspace`; `COPY files.py /opt/openmuse/files.py` chmod 0555; `ENV HOME=/workspace LANG=C.UTF-8`; `WORKDIR /workspace`; `USER 1000:1000`; `VOLUME /workspace`; `ENTRYPOINT ["/usr/bin/sleep"]`; `CMD ["infinity"]`. Built as `openmuse-computer:local`. Keep as-is.

### 6.6 files.py protocol (stdin JSON → stdout JSON, exit 0; on error message to stderr, exit 1)
Request: `{"operation": op, "path": "/workspace/...", "text"?: string, "base64"?: string}` (keys with undefined values are omitted by JSON.stringify). Max stdin read 15 MiB.
Path rules: string, no NUL, no `..` segment, must start with segments `["", "workspace"]`; empty and `.` segments dropped. Every directory component opened with `O_RDONLY|O_DIRECTORY|O_NOFOLLOW` relative to the previous fd (symlinks rejected at every level).
Result always contains `"path": "/workspace" + ("/" + parts.join("/") if parts)`.

| op | behaviour | extra result fields |
|---|---|---|
| `list` | traverse all parts as dirs; scandir; > 1000 entries → error; entry type via lstat: symlink/directory/file (anything else = file); sort: directories first, then by name (Python str order) | `entries:[{name, path: <path>/<name>, type, size: st_size}]` |
| `mkdir` | for each part: `mkdir(part, 0700)` ignoring EEXIST, then open it (no-follow) | — |
| `read` | parent dirs traversed; open last part `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`; must be regular file; read ≤ 256 KiB (+1 to detect) else error; strict UTF-8 decode | `text` |
| `read_pdf` | same, limit 10 MiB, must start with `%PDF-` | `base64` (standard, padded) |
| `write` | content = text UTF-8; ≤ 256 KiB | — |
| `write_pdf` | content = base64 decode (strict `validate=True`); must start `%PDF-`; ≤ 10 MiB | — |
write semantics: if target exists and is not a regular file (lstat) → error; write to `.openmuse-<uuid4 hex>` in same dir (`O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, 0600), fsync, `os.replace` onto target, best-effort unlink temp.
Empty `parts` for read/write → `Choose a file`. Unknown op → `Unsupported file operation`. Caught: OSError, ValueError, KeyError, TypeError (UnicodeDecodeError is a ValueError).

Server side (`file()`): path validated by workspacePath; text byte check; runs under the lease (§6.7); if `exitCode≠0 || timedOut || interrupted || truncated` → 422 `Computer file operation failed. Check the path, permissions and file size; symlinks cannot be opened.`; stdout not JSON → 502 `Computer returned an invalid file response`. (E2B provider computes timeout `seconds = 8 + ceil(max(len(input), read_pdf ? 15MiB : 0)/1MiB)`; docker ignores it and uses 8 s.)
Wrappers: `list(path="/workspace")`, `read → {path,text}`, `write → {path}`, `mkdir → {path}`, `writePdf(path, bytes)`: bytes ≤10 MiB and first 5 bytes `%PDF-` else 422 `Choose a PDF of 10 MB or smaller`; op `write_pdf` with base64; `pdfBytes(path)` → op `read_pdf` → `{name: basename(path), bytes}`.

### 6.7 Lease (cross-process mutual exclusion; record `computer-state/lease`)
```
Lease = {id:"lease", token:uuid, expiresAt:ms, stopping:bool, stopInFlight:bool, stopAttempt:string,
         stopConfirmed:bool, executorDone:bool, operation:"command"|"operation"}
```
`enabled()` check first everywhere: not COMPUTER_ENABLED → 503 `Computer is not configured. Enable COMPUTER_ENABLED and build the local computer image.` (docker) / `… and configure the desktop provider.` (e2b).

acquire(kind):
```
prev = get lease
new = {token: uuid, expiresAt: now+180000, stopping:false, stopInFlight:false, stopAttempt:"", stopConfirmed:false,
       executorDone: kind != "command", operation: kind}
if prev && prev.expiresAt > now: 409 "Computer is busy. Wait for the current operation to finish."
claimed = prev ? CAS(expected {token:prev.token, expiresAt:prev.expiresAt}, patch new) : insertIfAbsent(new)
if !claimed: 409 (same message)
```
exclusive(kind, op): acquire; run op; finally:
1. if kind=="command": `CAS({token}, {executorDone:true})`
2. `CAS({token, stopping:false}, {expiresAt:0})`  (normal release)
3. releaseStopped: `CAS({token, stopping:true, stopConfirmed:true, executorDone:true, stopInFlight:false}, {expiresAt:0})`
Leases are never renewed: an op lasting > 180 s loses exclusivity.

stop(owner):
```
enabled()
lease = get; if !lease || lease.expiresAt <= now: lease = acquire("operation")
elif (lease.operation != "command" && !lease.stopping) || lease.stopInFlight:
     409 "Computer is busy with another operation. Try Stop again shortly."
attempt = uuid
ok = CAS({token, stopping: lease.stopping, stopAttempt: lease.stopAttempt},
         {stopping:true, stopInFlight:true, stopAttempt:attempt, stopConfirmed:false, expiresAt: now+180000})
if !ok: 409 "Computer is busy with another Stop request"
try:
   for each receipt with status running: CAS({status:"running"}, {status:"interrupted", completedAt:now,
        stderr:"Stopped by the user. Inspect the workspace before repeating this command."})
   backend.stop(owner)
   CAS({token, stopAttempt:attempt}, {stopInFlight:false, stopConfirmed:true}); releaseStopped(token)
except: CAS({token, stopAttempt:attempt}, {stopInFlight:false, stopConfirmed:false}); rethrow
return snapshot
```
Note stop() never releases a lease it acquired itself through the normal path; release happens via releaseStopped (executorDone is true for "operation" leases). When stopping a running command, the lease is released when the command's `exclusive` finally runs releaseStopped.

### 6.8 Command execution (`execute(owner, {command,cwd}, {idempotencyKey?, signal?})`)
```
enabled(); args = parse; cwd = workspacePath(args.cwd)
id = idempotencyKey ? sha256hex("computer-command:" ++ key) : uuid
prev = get receipt id
if prev: if prev.command != args.command || prev.cwd != cwd: 409 "This operation ID already belongs to a different command"
         commands(owner) (to mark stale running→interrupted); return fresh get(id) ?? prev
exclusive("command"):
  session = backend.running(owner)          (409 if not running)
  if signal aborted: 409 "Computer command was interrupted before execution"
  cmd = {id, command, cwd, status:"running", stdout:"", stderr:"", truncated:false, startedAt: now}
  if !insertIfAbsent(cmd): return existing (or 500 "Computer receipt could not be saved")
  active = get lease
  if !active || active.token != lease.token || active.stopping || active.expiresAt <= now:
       CAS(receipt {status:"running"} → {status:"interrupted", stderr:"Stopped before execution", completedAt}) ; return it
  if receipt.status != "running": return it
  result = session.exec(command, cwd, signal)  (exception → {stderr:"Execution was interrupted; inspect the workspace before retrying.", exitCode:null, interrupted:true})
  timedOut = result.timedOut || result.exitCode == 124
  if result.timedOut || result.interrupted:      # whole sandbox stop
      attempt = uuid
      if CAS(lease {token, stopping:false} → {stopping:true, stopInFlight:true, stopAttempt:attempt, stopConfirmed:false, expiresAt: now+180000}):
          try session.stop(); CAS({token, stopAttempt} → {stopInFlight:false, stopConfirmed:true})
          except CAS(→ {stopInFlight:false, stopConfirmed:false}); result.stderr += "\nCould not confirm the computer stopped. It remains locked; retry Stop after checking the computer provider."
  status = interrupted ? "interrupted" : timedOut ? "timed_out" : exitCode==0 ? "succeeded" : "failed"
  final = {...cmd, status, exitCode (omit if null), stdout, stderr, truncated, completedAt: now}
  finished = CAS(receipt {status:"running"} → final); if finished return it
  else (a Stop marked it interrupted): put {...final, status:"interrupted", stderr: join_nonempty([result.stderr, stored.stderr], "\n")}
```
`commands(owner)`: list receipts; if no live lease, every `running` receipt is CAS-ed to `{status:"interrupted", completedAt:now, stderr:"Execution was interrupted. Its outcome is unknown; inspect files before running it again."}`; sort by startedAt desc; first 100.

`snapshot(owner)`: base `{enabled, provider, workspacePath:"/workspace", network: docker?"disabled":"enabled", commands}`; disabled → `status:"unconfigured", message:` docker: `Enable the Docker computer on the server to use its terminal and workspace files.` / e2b: `Enable the E2B desktop computer on the server to use its desktop, terminal and workspace files.`; else running/stopped from backend.state (missing ⇒ stopped); error → `status:"error", message: AppError message or "Computer inspection failed. Check the computer provider setup."`.
`start(owner)`: exclusive("operation", backend.start) → snapshot.

### 6.9 Computer HTTP routes (prefix `/api/computer`, bearer)
| Method path | Body / query | Response |
|---|---|---|
| `GET /` | — | ComputerSnapshot |
| `POST /start` | — | ComputerSnapshot |
| `POST /stop` | — | ComputerSnapshot |
| `GET /desktop` | — | `{url}` (e2b only; docker → 404 `This computer has no desktop. Set COMPUTER_PROVIDER=e2b-desktop.`) |
| `POST /desktop/actions` | desktop action JSON (§6.11) | `{receipt, width, height, warning}` |
| `GET /desktop/screenshot?receipt=` | — | image bytes, `Content-Type` = stored mime (`image/jpeg`), `Cache-Control: no-store`; 404 `No desktop screenshot yet` |
| `POST /commands` | `{command, cwd?}` | ComputerCommand (200; signal = HTTP request abort) |
| `GET /files?path=` | path default `/workspace` | ComputerDirectory |
| `POST /files/read` | `{path}` | `{path, text}` |
| `POST /files/write` | `{path, text}` | `{path}` |
| `POST /files/mkdir` | `{path}` | `{path}` |
| `POST /files/import` | `{path, fileId}` | `{path}` (copies owned app PDF into workspace) |
| `POST /files/export` | `{path}` | **201** Artifact (`files.import(owner, basename, bytes, "Computer: " ++ path)`) |

Agent tools (computer-tools.ts; errors returned as `{error: message}` instead of thrown): `computer_status`, `start_computer`, `stop_computer`, `run_computer_command {command, cwd?, operationId 1..120}` (idempotencyKey = `<scope>:<operationId>`), `list_computer_files {path}`, `read_computer_file`, `write_computer_file`, `mkdir_computer`, `import_computer_pdf {path,fileId}`, `export_computer_pdf {path}`, and e2b-only `use_desktop` (action + operationId; returns a text part JSON `{status, action, receiptId, screen:{width,height}, screenshot:"attached as an image for this step only"|"unavailable", warning}` plus an image part). The long system-prompt strings `dockerInstructions`/`desktopInstructions` are in computer-tools.ts lines 13–17 (copy verbatim).

### 6.10 E2B desktop provider (summary only)
`computer-e2b-desktop.ts` (667 lines) drives `@e2b/desktop` 2.4.0 (JS SDK; no Erlang SDK — would need E2B REST + envd gRPC/Connect, or keep a Node sidecar). Key facts:
- One sandbox per owner, found by `Sandbox.list({metadata: labels, state:[running,paused]})`; >1 match or metadata/template mismatch → refuse. Template `COMPUTER_E2B_TEMPLATE` (default `desktop`), created with metadata=labels, `timeoutMs` 15 min idle (auto-pause), resolution 1280×800, request timeouts 10 s control / 60 s create.
- Stop = `Sandbox.pause(keepMemory:false)`. Start = create-or-connect (connect resumes), then as root `mkdir -p /workspace /opt/openmuse && chown user:user /workspace`, write `files.py` to `/opt/openmuse/files.py`, then start Xvfb `:0` + xfce4 as `user` if not running.
- Commands: wrapped bash script (`desktopCommand`) running `timeout --signal=TERM --kill-after=2s 30s bash -c "$1"` in background with output files, DISPLAY set; output ceiling 1 MiB, stdin chunks 1 MiB, disk ceiling 32 MiB. Receipts kind `computer-desktop-commands`.
- Desktop stream: `box.stream.getUrl({authKey})` (VNC password in URL), cached; viewer keep-alive 30 min.
- Desktop actions: zod schema `{action: screenshot|left_click|double_click|right_click|mouse_move|type|key|scroll|wait, coordinate?:[x,y] ints < 1280/800, text? 1..1000 (key: ^[A-Za-z0-9_+ -]+$), scroll_direction?, scroll_amount? 1..15 (default 3), duration? 0.1..10 (default 1)}`; executed as xdotool commands (release all modifiers first, 0.5 s settle) then `scrot --pointer --quality 80 --overwrite /tmp/openmuse-screenshot.jpg`; exit 3 = input failed, 4 = screenshot failed. Receipts `computer-desktop-actions` (id = sha256hex(`computer-desktop-action:` ++ key) or uuid; `actionHash = sha256hex(JSON(action))`; receipt `command` = `describeDesktopAction`, e.g. `desktop left_click (640, 400)`); intent persisted as `interrupted` before dispatch. Latest screenshot stored at `${DATA_DIR}/desktop-screens/<sha256hex(owner)>.jpg` (tmp `<receiptId>.tmp` + rename) with record `computer-desktop-screens/latest {id:"latest", receiptId, mimeType, blob, takenAt}` (legacy `data` base64 accepted).
Recommendation: implement docker provider natively; treat e2b-desktop as optional/phase 2.

---------------------------------------------------------------------------------------------------

## 7. Browser

### 7.1 Worker HTTP API contract (apps/worker, keep as Node service)
Listen `WORKER_HOST:8790` (fixed port). `requestTimeout 30 s`, `headersTimeout 10 s`, `keepAliveTimeout 5 s`, `maxRequestsPerSocket 100`. Every response: `cache-control: no-store`, `x-content-type-options: nosniff`. JSON responses `content-type: application/json; charset=utf-8`.
Auth: all routes except `GET /health` require `Authorization: Bearer <WORKER_TOKEN>` (compared as sha256 of the full header value, constant time). Token < 32 chars → worker refuses to start.
Request bodies (POST): `content-type` must start with `application/json` (else 400 INVALID_BODY), ≤ 64 KiB (413 BODY_TOO_LARGE), must be a JSON object (400 INVALID_BODY `A JSON object is required.`).
Session ids: v1–v8 UUID regex (case-insens., lowercased) else 400 `INVALID_SESSION` `A valid UUID session ID is required.`
Errors: `{"error":{"code":CODE,"message":MSG}}` with status; unknown exceptions → 500 `WORKER_FAILURE` `The browser operation failed. Check worker health and reopen the session.`

```
WorkerSession = {id, title(≤300), url, status:"active"|"closed"|"error", updatedAt:ISO}
```
| Method path | Body | 2xx response | notable errors |
|---|---|---|---|
| `GET /health` | — | 200 `{"status":"ok"}` | — |
| `GET /sessions` | — | 200 `[WorkerSession]` | 401 |
| `POST /sessions` | `{id:uuid, url:string≤8192}` | **201** WorkerSession (create-or-navigate: if already running → navigate) | 400 INVALID_URL (`A URL of at most 8192 characters is required.`), 400 BLOCKED_URL, 502 DNS_UNAVAILABLE, 409 SESSION_LIMIT (`Close an active session before opening another (limit 3).`), 409 PROFILE_LIMIT (`The worker has reached its 20 saved-profile limit.`), 503 BROWSER_UNAVAILABLE, 502 NAVIGATION_FAILED |
| `POST /sessions/:id/navigate` | `{url}` | 200 WorkerSession | 409 SESSION_CLOSED (`Open this browser session before using its console.`), BLOCKED_URL, NAVIGATION_FAILED (`The page could not be loaded. It may be unreachable or contain a blocked destination.`) — **not used by the API server** |
| `POST /sessions/:id/close` | `{}` (must be JSON) | 200 WorkerSession (status closed; cookies saved) | 404 SESSION_NOT_FOUND |
| `GET /sessions/:id/read` | — | 200 `{url, title(≤300), text(≤100000), truncated}` (`document.body.innerText`) | 409 SESSION_CLOSED, 400 BLOCKED_URL |
| `GET /sessions/:id/screenshot` | — | 200 `image/png` (1280×800 viewport) with content-length | 409 |
| `POST /sessions/:id/input` | one of `{type:"click",x,y}` (0≤x<1280, 0≤y<800), `{type:"text",text≤10000}` (insertText), `{type:"key",key}` key ∈ `Enter Tab Escape Backspace Delete ArrowUp ArrowDown ArrowLeft ArrowRight Home End PageUp PageDown Control+a Meta+a Shift+Tab`, `{type:"scroll",deltaY}` (\|deltaY\|≤5000) | 200 WorkerSession (refreshed) | 400 INVALID_INPUT `Unsupported browser input or coordinates.`, 409 |
| `GET /sessions/:id/downloads` | — | 200 `{downloads:[{id,name,size,mimeType:"application/pdf"}], failures:[{id,name,code,message,createdAt}]}` (failures newest first) | 404 SESSION_NOT_FOUND, 500 DOWNLOAD_STORE_FAILED |
| `GET /sessions/:id/downloads/:downloadId` | — | 200 `application/pdf` bytes, `content-disposition: attachment; filename="<name>"` | 400 INVALID_SESSION (bad downloadId), 404 DOWNLOAD_NOT_FOUND, 413 DOWNLOAD_TOO_LARGE |
| anything else | | | 404 NOT_FOUND `Worker endpoint not found.` |

Worker behaviour essentials (for reasoning about responses): max 3 running sessions, 20 saved profiles, idle close after 30 min (sweep every 60 s); profiles at `WORKER_DATA_DIR/<id>/{profile/,session.json,storage.json,downloads/<did>.pdf|.json,download-outcomes/<did>.json}`; on restart all sessions are `closed`. URL policy: http/https only, ports 80/443, no userinfo, hostnames ending in `localhost|local|internal|home|lan` blocked, every resolved IP must be public (IPv4 deny-list: 0/8,10/8,127/8,≥224, 100.64/10, 169.254/16, 172.16/12, 192.168/16, 192.0.0/24, 192.0.2/24, 192.88.99/24, 198.18/15, 198.51.100/24, 203.0.113/24; IPv6 only 2000::/3 minus 2001::/23, 2001:db8::/32, 2002::/16, 3fff::/20), DNS timeout 5 s; Chromium forced through a local egress proxy that connects to the validated IP. Download failure codes: DOWNLOAD_INTERRUPTED, DOWNLOAD_LIMIT (20/session), UNSUPPORTED_DOWNLOAD (non-`%PDF-`), DOWNLOAD_TOO_LARGE (10 MiB). Downloaded name sanitized `[^a-zA-Z0-9._ -]`→`_`, ≤180, `.pdf` appended if missing.

### 7.2 API-side client (browser.ts)
- `reachable()`: false if not configured; else cached for 15000 ms: `GET {workerUrl}/health` with 2000 ms timeout → `response.ok`, network error → false.
- `request(path, body?, signal?)`: not configured → 503 `Browser worker is not configured. Start it using the setup guide.`; method = body===undefined ? GET : POST; headers `Authorization: Bearer <WORKER_TOKEN>`, `Content-Type: application/json` (also on GETs); JSON body; timeout 45000 ms (combined with caller abort). Network failure/timeout → 503 `Browser worker is unavailable. Check that its container is running.` (if caller aborted, propagate abort instead). Non-2xx → **502** with worker `error.message` if string else `Browser request failed` (so worker 409/404/400 all become 502 at the API).
- Per-session serialization: in-process FIFO per session id (ops on the same id never overlap; failures don't block the queue).
- `get(owner,id)`: id must match UUID regex and record `browsers/<id>` must exist else 404 `Browser session not found`. This is the ownership check.
- `decorate(owner, s)` = s + `consoleUrl: sign(owner,"/api/browsers/<id>/console")`, `previewUrl: sign(owner,"/api/browsers/<id>/preview")`.
- `save(owner, payload, expectedId)`: validate `{id,title,url,status ∈ idle|active|closed|error, updatedAt}` (extra keys dropped); `id != expectedId` → 502 `Browser worker returned a different session`; `put browsers`; return decorated.

Operations:
| op | steps |
|---|---|
| `create(owner,url)` | id=uuid; **first** `put browsers {id,url,title:"New browser session",status:"idle",updatedAt:now}`; then `reopen(owner,id,url)` |
| `reopen(owner,id,url?)` / `navigate` | serial(id): `v=get`; target=url ?? v.url; `POST /sessions {id, url:target}` → save. On any error: save `{...v, url:target, status:"error", updatedAt:now}` then rethrow (unless aborted) |
| `read(owner,id)` | serial(id): get; `GET /sessions/<id>/read` (validate url, title≤300, text≤100000, truncated); save `{...v, url, title, status:"active", updatedAt}`; return read result |
| `close(owner,id)` | serial(id): get; `POST /sessions/<id>/close` body `{}` → save |
| `preview(owner,id)` | get; `GET /sessions/<id>/screenshot` → bytes (not serialized) |
| `input(owner,id,obj)` | non-array object else 422; serial(id): get; `POST /sessions/<id>/input` obj → save |
| `imports(owner,id)` | serial(id): get; `GET /sessions/<id>/downloads`; for each download: if `browser-downloads/<did>` exists → existing file (signed); else `GET /sessions/<id>/downloads/<did>` bytes → `files.import(owner, name, bytes, "Browser · <id>")` → `put browser-downloads {id:did, fileId}`; return `{files, failures}` |
| `observe(owner,url,existingId?)` (agent `read_web`) | id = existingId ?? create(owner,url).id; serial(id): if existingId reopen-unserialized(id,url); read → `{sessionId:id, url, title, text, truncated}` (tool trims text to 30000) |
| `observeForThread(owner,threadId,url)` (chat `browse_web`) | association = get `chat-browsers/<threadId>` ?? insertIfAbsent `{id:threadId, sessionId:uuid}` ?? get (else 500 `Could not reserve the chat browser session`); insertIfAbsent `browsers {id:sessionId,url,title:"New browser session",status:"idle",updatedAt}`; serial: open (POST /sessions) then read; return `{sessionId, url, title, text: text[0:30000], truncated: truncated \|\| len>30000}` |
| `console(owner,id)` | HTML with signed preview URL (§7.5) |

### 7.3 Ownership records summary
`browsers/<uuid>` (BrowserSession without urls; written before contacting the worker), `chat-browsers/<chatThreadId> → sessionId` (one browser per chat thread), `browser-downloads/<downloadId> → fileId` (import idempotency), tasks store `state.browserId`.

### 7.4 Signed pages
`GET /api/browsers/:id/preview?owner&expires&signature` → PNG proxied from worker. `GET/POST /api/browsers/:id/console?...` → HTML page / input proxy.

### 7.5 Console HTML (browser-console.ts) — reproduce byte-for-byte
`P = JSON-encode(signedPreviewUrl)` with every `<` replaced by `<`. Template (substitute `${P}` once):
```html
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenMuse browser</title><style>
*{box-sizing:border-box}body{margin:0;background:#fcfcfc;color:#172125;font:14px -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
header{padding:12px;display:flex;align-items:center;justify-content:space-between;gap:12px}#status{color:#697176;font-size:12px}#status.live{color:#248258}
button,input{font:inherit;border:1px solid #e9edef;border-radius:24px;padding:10px 14px;background:white;color:inherit;min-height:42px}
button{cursor:pointer}button:hover{background:#edf7fd}button:disabled{opacity:.45;cursor:default}button:focus-visible,input:focus-visible{outline:2px solid #1473c8;outline-offset:2px}
form{padding:0 12px 10px;display:flex;gap:8px}input{flex:1;min-width:0;background:#f1f3f4;border-color:transparent}#type{background:#c8e7ff}
nav{display:flex;gap:6px;padding:0 12px 12px;flex-wrap:wrap}nav button{font-size:12px;min-height:36px;padding:7px 12px}
#stage{overflow:hidden;background:#eef1f3;border-radius:18px;min-height:160px;margin:0 8px}img{display:block;width:100%;height:auto;cursor:crosshair;touch-action:pan-y}img.stale{opacity:.45;pointer-events:none}
#error{margin:0 12px 12px;color:#984a41;background:#fbefed;padding:12px;border-radius:14px}#error:empty{display:none}footer{padding:12px;color:#697176;font-size:12px;line-height:1.5}
</style><header><strong>Browser</strong><span id="status" role="status">Connecting…</span><button id="refresh" aria-label="Refresh browser preview">↻</button></header>
<form><input id="text" aria-label="Text to type in browser" placeholder="Type into the selected field" autocomplete="off"><button id="type" type="submit">Send text</button></form>
<nav aria-label="Browser keyboard"><button data-key="Enter">Enter ↵</button><button data-key="Tab">Tab ⇥</button><button data-key="Backspace">Delete ⌫</button><button id="up">Scroll ↑</button><button id="down">Scroll ↓</button></nav>
<div id="error" role="alert"></div><div id="stage"><img id="screen" class="stale" alt="Live browser session, click to interact" draggable="false"></div>
<footer>Tap the page to select a field, then send text above. You’re controlling the agent’s browser.</footer><script>
const image=document.querySelector('#screen'),error=document.querySelector('#error'),status=document.querySelector('#status'),field=document.querySelector('#text');
let refreshing=false,sending=false,imageUrl,live=false,previewError=false;
function controls(){document.querySelectorAll('nav button,#type').forEach(button=>button.disabled=sending||!live);image.classList.toggle('stale',!live||sending);}
async function refresh(){if(refreshing||sending||document.hidden)return;refreshing=true;try{
const r=await fetch(${P},{cache:'no-store',signal:AbortSignal.timeout(20000)});
if(!r.ok)throw new Error(r.status===401?'Session access expired. Close this view and open the browser again.':'Browser disconnected. Reopen the session from OpenMuse.');
const blob=await r.blob();const next=URL.createObjectURL(blob);await new Promise((resolve,reject)=>{const probe=new Image();probe.onload=resolve;probe.onerror=()=>{URL.revokeObjectURL(next);reject(new Error('The browser preview could not be displayed.'));};probe.src=next;});
if(imageUrl)URL.revokeObjectURL(imageUrl);imageUrl=next;image.src=next;live=true;status.textContent='Live';status.className='live';if(previewError){error.textContent='';previewError=false;}
}catch(e){live=false;previewError=true;status.textContent='Disconnected';status.className='';error.textContent=e.message;}finally{refreshing=false;controls();}}
async function input(body){if(sending||!live)return false;sending=true;controls();error.textContent='';status.textContent='Updating…';let ok=false;try{
const r=await fetch(location.href,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(45000)});
if(!r.ok){const data=await r.json();throw new Error(typeof data.error==='string'?data.error:'Browser action failed. Your text is still here.');}ok=true;
}catch(e){error.textContent=e.message;}finally{sending=false;controls();await refresh();}return ok;}
image.onclick=e=>{if(!live||sending)return;const r=image.getBoundingClientRect();input({type:'click',x:Math.min(1279,Math.max(0,Math.floor((e.clientX-r.left)*1280/r.width))),y:Math.min(799,Math.max(0,Math.floor((e.clientY-r.top)*800/r.height)))});};
document.querySelector('form').onsubmit=async e=>{e.preventDefault();const text=field.value;if(text&&await input({type:'text',text})&&field.value===text)field.value='';};
document.querySelectorAll('[data-key]').forEach(b=>b.onclick=()=>input({type:'key',key:b.dataset.key}));
document.querySelector('#up').onclick=()=>input({type:'scroll',deltaY:-600});document.querySelector('#down').onclick=()=>input({type:'scroll',deltaY:600});
document.querySelector('#refresh').onclick=()=>{error.textContent='';refresh();};document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
controls();refresh();const timer=setInterval(refresh,2000);window.addEventListener('pagehide',()=>{clearInterval(timer);if(imageUrl)URL.revokeObjectURL(imageUrl);});
</script></html>
```
(Source: `apps/server/src/browser-console.ts`; copy that file's template literal rather than this transcription when porting.) The page POSTs inputs to its own signed URL (`location.href`) — the console POST route must accept signed auth. Preview polled every 2 s.

---------------------------------------------------------------------------------------------------

## 8. Web search (search.ts) — Parallel MCP

- Enabled unless `WEB_SEARCH_ENABLED=false`; keyless (no API key).
- Endpoint: `https://search.parallel.ai/mcp`, MCP **Streamable HTTP** transport, client info `{name:"openmuse", version:"0.1.0"}` (root package.json), extra header `User-Agent: openmuse/0.1.0`. Redirects are errors. Response body cap 1 MiB per HTTP response (`Search response exceeded 1 MiB`). Overall deadline 45000 ms. No reconnection retries. Client closed after each call (fresh connection per search).
- Wire sequence an Erlang client must perform (JSON-RPC 2.0 over HTTP POST; headers `Content-Type: application/json`, `Accept: application/json, text/event-stream`; response may be `application/json` or an SSE stream whose `data:` lines carry the JSON-RPC response):
  1. `initialize` `{protocolVersion: <SDK latest, MCP SDK ^1.30 → "2025-06-18" or newer>, capabilities:{}, clientInfo:{name:"openmuse",version:"0.1.0"}}` → remember `Mcp-Session-Id` response header if present and negotiated `protocolVersion`.
  2. notification `notifications/initialized` (expect 202). Subsequent requests carry `Mcp-Session-Id` (if any) and `MCP-Protocol-Version: <negotiated>`.
  3. `tools/call` `{name:"web_search", arguments:{objective, search_queries:[…], session_id}}`.
  (The SDK may also open a GET SSE stream; not required.)
- Input schema (agent tool `search_web`): `objective` trimmed 1..2000; `search_queries` 1..5 strings each trimmed 1..200.
- `session_id`: stable random uuid per conversation key, record `search-sessions/<key>` (`chat:<chatThreadId>` or `task:<taskId>`), created with get → insertIfAbsent → get (else `Could not reserve the search session`).
- Result handling:
  - `isError` → error message = first text block text[0:500] or `Search tool failed`.
  - payload = `structuredContent` ?? JSON.parse(first text block). Must be `{results: [any], warnings?: [string | {type,message}] | null}` else `Parallel returned an invalid search result`.
  - each result validated as `{url: http(s) URL ≤4096, title?: string|null, excerpts:[string], publish_date?: string≤100|null}`; invalid ones dropped (count `dropped`; warning `Dropped N invalid search result entries` unshifted).
  - keep first 10 sources; shared excerpt budget 30000 chars across all excerpts in order (each excerpt sliced to remaining; empty ones removed); title sliced to 300.
  - `truncated = dropped>0 || sources>10 || warnings>10 || any excerpt cut || any title>300 || any warning text>500`.
  - Output: `{provider:"parallel", results:[{url, title|null, excerpts:[…], publish_date|null}], warnings: first 10 as strings ("type: message" for objects) each ≤500, truncated}`.
- Errors: deadline → `Parallel search timed out after 45 seconds`; other → `Parallel search failed: <message[0:500]>`; caller abort propagates. Tools convert errors to `{error}`.
- Task tool additionally appends each new result url as evidence `{id, kind:"web", title: title ?? url, url, excerpt: excerpts.join("\n")[0:500]}`.

---------------------------------------------------------------------------------------------------

## 9. Google (google-auth.ts, packages/integrations/src/google.ts)

### 9.1 OAuth connect (`connect(owner, write)`)
- Requires clientId, clientSecret, encryptionKey else 503 `Configure GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET and TOKEN_ENCRYPTION_KEY to connect Google`.
- `state = base64url(random 32)`, `verifier = base64url(random 48)` (64 chars).
- **Generation rotation** (`rotateGeneration(owner, disconnect=false)`): `g = uuid()`; loop: `prev = get credentials/google`; if none → `insertIfAbsent {id:"google", generation:g, connectionId:null, secret:null}` → done(prev=null); else `CAS(expected = entire prev record, patch {generation:g} (+ {connectionId:null, secret:null} if disconnect))` → done(prev); retry on CAS failure.
- `existing = decrypt(prev)`; scopes = ordered unique of:
  `https://www.googleapis.com/auth/gmail.readonly`, `https://www.googleapis.com/auth/calendar.events.readonly`, `https://www.googleapis.com/auth/calendar.calendarlist.readonly`, then existing.scopes…, then if write: `https://www.googleapis.com/auth/gmail.send`, `https://www.googleapis.com/auth/calendar.events`.
- `put system/oauth {id:state, owner, expiresAt: now+600000, verifier, scopes, generation:g}`.
- URL: `https://accounts.google.com/o/oauth2/v2/auth?` + form-urlencoded (URLSearchParams: space→`+`) in this order: `client_id`, `redirect_uri` (= `${PUBLIC_API_URL}/api/google/callback`), `response_type=code`, `scope` (space-joined), `state`, `access_type=offline`, `prompt=consent`, `include_granted_scopes=true`, `code_challenge_method=S256`, `code_challenge = base64url_nopad(sha256(verifier ASCII))`.
- Returns `{url}`.

### 9.2 Callback (`callback(state, code)`)
1. `st = take(system/oauth/state)`; missing/expired → 400 `Google sign-in expired. Connect again.`
2. `cred = get(st.owner credentials/google)`; `!st.generation || cred.generation != st.generation` → 409 `Google sign-in changed or was disconnected. Connect again.`
3. POST `https://oauth2.googleapis.com/token` (`application/x-www-form-urlencoded`; timeout 15 s): `client_id, client_secret, redirect_uri, grant_type=authorization_code, code, code_verifier`. Non-2xx → 502 `Google could not complete sign-in. Connect again.` Parse `{access_token (nonempty), refresh_token?, expires_in:number, scope?}` (fail → 422 zod).
4. GET `https://gmail.googleapis.com/gmail/v1/users/me/profile` with Bearer access token (15 s). Non-2xx → 403 `Google did not grant Gmail read access. Connect again.` Parse `{emailAddress: email}`.
5. `prev = tokens(owner)`; save Tokens:
   `{connectionId: uuid(), accessToken, refreshToken: refresh_token ?? (prev.account == emailAddress ? prev.refreshToken : undefined), expiresAt: now + expires_in*1000, scopes: scope ? scope.split(" ") : st.scopes, account: emailAddress}`
   via `CAS(credentials/google, expected {generation: st.generation}, patch {generation: uuid(), connectionId, secret: encrypt(JSON(tokens))})`; fail → 409 (same message as step 2).
Every successful connect yields a new `connectionId` (invalidates pending actions bound to the old one).

### 9.3 Access token (`accessToken(owner, expectedConnId?)`)
- tokens missing → 409 `Google is disconnected`; expectedConnId mismatch → 409 `Google account or connection changed. Prepare a new action.`
- if `expiresAt > now + 60000` → accessToken.
- else refresh (single-flight per `owner:connectionId` in-process): no refreshToken → 401 `Google session expired. Connect again.`; POST token endpoint `client_id, client_secret, grant_type=refresh_token, refresh_token` (15 s); non-2xx → 401 same message; new tokens = old with `accessToken`, `expiresAt = now + expires_in*1000` (scopes/refreshToken unchanged); `updateCredential(owner, connectionId, encrypt(JSON))` false → 409 `Google account changed or was disconnected during refresh`. Missing encryption key → 503 `Token encryption is not configured`.
- `tokens(owner)`: credential with non-null secret → decrypt (missing key → 503 `TOKEN_ENCRYPTION_KEY is not configured`) → JSON.

Tokens JSON (plaintext inside vault): `{"connectionId","accessToken","refreshToken"?,"expiresAt","scopes":[…],"account"}`.

### 9.4 Disconnect
`rotateGeneration(owner, disconnect=true)` (clears connectionId & secret); if previous tokens existed: POST `https://oauth2.googleapis.com/revoke` form `token = refreshToken ?? accessToken` (15 s). Response not ok and status ≠ 400 → 502 `Disconnected locally. Google revocation failed; remove access in your Google account settings.`

### 9.5 Google API client — request rules
Bases: `GMAIL = https://gmail.googleapis.com/gmail/v1/users/me`, `CALENDAR = https://www.googleapis.com/calendar/v3`.
Every request: get token (credential failures propagate unchanged); token empty or containing CR/LF → Error `Google access token is missing or invalid; reconnect Google`. Headers `Authorization: Bearer`, `Accept: application/json`, `Content-Type: application/json` when body; extra conditional headers (If-Match). Timeout 30 s; **redirects are errors**.
- write = method ≠ GET. Network failure: write → OutcomeUnknownError (`Google may have completed this action. Check Google before trying again.`); read → Error `Could not reach Google; check the connection and try again`.
- write with status ≥ 500 or 408 → OutcomeUnknownError.
- non-2xx → `GoogleApiError(status, detail)` where detail = `body.error.message[0:500]` if JSON has it else statusText or `Request failed`. Message `Google API (<status>): <detail>` → HTTP 502.
- DELETE 204 → no body.
- Response JSON size cap `MAX_JSON_BYTES = ceil(10MiB*4/3) + 1MiB` = 14,729,560 bytes (via Content-Length and streaming); exceed/invalid JSON: write → OutcomeUnknownError, read → `Google returned an invalid or oversized response`.
- `idPath(id)`: must match `^[A-Za-z0-9_-]+$` else Error `Invalid Google resource ID`.
- `calendarPath(calId)`: nonempty, ≤1024, no char ≤ 0x20 or 0x7F, not `.`/`..` else `Invalid Google calendar ID`; → `${CALENDAR}/calendars/${encodeURIComponent(calId)}/events`.

### 9.6 Calls used
| Function | HTTP | Notes |
|---|---|---|
| `listMail(q="in:inbox")` | `GET {GMAIL}/messages?maxResults=30&q=<q>` then per id `GET {GMAIL}/messages/<id>?format=full` (parallel) | ≤30, each mapped (§9.7) |
| `getThread(threadId)` | `GET {GMAIL}/threads/<id>?format=full` | thread.id must equal and all messages' threadId equal, else Error `Google returned messages from a different thread` |
| `getAttachment(msgId, attId)` | `GET {GMAIL}/messages/<msg>/attachments/<att>` → `{data, size?}` | size >10 MiB → error; strict base64url decode (§9.7) ; size must equal decoded length |
| profile | `GET {GMAIL}/profile` → `{emailAddress}` | used by sendEmail |
| `sendEmail` | `GET {GMAIL}/messages/<replyTo>?format=metadata&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=Subject` (reply only); `POST {GMAIL}/messages/send` `{raw, threadId?}` | §9.8 |
| `listCalendars()` | `GET {CALENDAR}/users/me/calendarList?maxResults=250[&pageToken=]` | follow nextPageToken; >10 distinct tokens or repeat → `Google calendar list exceeded the pagination limit`; item → `{id, name: summaryOverride ?? summary ?? "(Untitled calendar)", timeZone ?? "UTC", accessRole}` |
| `listEventsPage({calendarId="primary", timeMin, timeMax})` | `GET <calendarPath>?maxResults=100&singleEvents=true&orderBy=startTime&timeMin=&timeMax=` | default timeMin = server-local midnight today (ISO); default timeMax = timeMin + 31 days; both must be ISO-with-offset (`Invalid calendar timeMin: use a date-time with an explicit offset` / `…timeMax…`) and pass calendarRange; returns `{events: first 100 mapped with fallback tz = response.timeZone ?? "UTC", truncated: nextPageToken present \|\| items>100}` |
| `readSingleEvent(cal, ev)` | `GET <calendarPath>/<ev>` | id must equal (`Google returned a different event`); recurrence or recurringEventId present → RecurringEventError (422, `Recurring events cannot be changed here yet. Open Google Calendar to choose one occurrence or the whole series.`) |
| `reviewEvent(cal, ev)` | readSingleEvent; if event start.timeZone missing: `GET {CALENDAR}/users/me/calendarList/<encodeURIComponent(cal)>` → timeZone (default UTC) | returns `{event: mapped, version: etag}`; etag missing/blank → Error `Google event has no ETag; prepare a fresh review`; etag must be single-line |
| `createEvent(draft)` | `POST <calendarPath>?sendUpdates=all` body eventBody(draft) | map failure → OutcomeUnknown |
| `updateEvent(id, draft, expectedVersion)` | readSingleEvent; etag ≠ expected → GoogleApiError(409,`This event changed since review. Prepare a new action.`); `PATCH <calendarPath>/<id>?sendUpdates=all` body eventBody(draft, patch=true), header `If-Match: <etag>` | |
| `deleteEvent(cal, id, expectedVersion)` | readSingleEvent + etag check; `DELETE <calendarPath>/<id>?sendUpdates=all` with `If-Match` | |

eventBody(draft, patch):
```
{summary: title,
 start: allDay ? {date: start, (patch: dateTime:null)} : {dateTime: start, timeZone, (patch: date:null)},
 end:   same with end,
 location, description, attendees: [{email}]}
```
Event mapping (`mapEvent(raw, calendarId, fallbackTz)`): schema `{id, etag?, recurrence?, recurringEventId?, summary="(Untitled event)", start:{date?,dateTime?,timeZone?}, end:{date?,dateTime?}, location="", description="", attendees=[{email}]}`; `allDay = start.date present`; start/end = date or dateTime (must parse, else `Invalid Google event time range`); → CalendarEvent `{id, calendarId, title:summary, start, end, allDay, timeZone: start.timeZone ?? fallbackTz, location, description, attendees: emails}`. (For create/update the fallback is draft.timeZone.)

### 9.7 Gmail message parsing (`mapMessage`)
Message schema: `{id, threadId, snippet="", internalDate?: string(ms), labelIds=[], payload?: Part}`; Part = `{mimeType?, filename?, headers?:[{name,value}], body?:{data?, size?, attachmentId?}, parts?:[Part]}`.
1. **Hydration** (before mapping, depth ≤30 else `Gmail message MIME nesting exceeds the limit`): any part with no filename, mimeType text/plain|text/html, `body.data` absent but `body.attachmentId` present → if body.size > 1 MiB error `Gmail message text exceeds the 1 MiB limit`; fetch via getAttachment; >1 MiB error; set `body.data = base64url(bytes)`.
2. **Walk** (depth ≤ 30): `attached = filename nonempty || mimeType == "message/rfc822"`.
   - if filename and body.attachmentId: push reference `"<msgId>:<attachmentId>:" ++ encodeURIComponent(wellFormed(filename))` (wellFormed replaces lone surrogates with U+FFFD).
   - if !attached and mimeType text/plain|text/html and body.data: charset = part's `Content-Type` header `charset=["']?([^;"'\s]+)` (case-insens.) else utf-8; bytes = strict base64url decode (limit 1 MiB); decode with charset (unknown charset → UTF-8; invalid bytes → U+FFFD); plain → list P; html → htmlToPlainText → list H.
   - recurse into children only if !attached.
3. Headers (top-level payload, names lowercased): `from = decodeHeader(from ?? "")`; `address = first addresses(from) ?? from`; `displayName = from contains "<" ? trim(from[0:index("<")]) with one leading/trailing `"` stripped : ""`; `sender = displayName || address`.
4. `time = internalDate ? Number(internalDate) : Date.parse(Date header)`; `date = finite ? ISO : ""`.
5. `body = P nonempty ? join(P,"\n\n") : H nonempty ? join(H,"\n\n") : decodeSnippet(snippet)`; length > 1048576 → error `Gmail message text exceeds the 1 MiB limit`.
6. Mail: `{id, threadId, from: address, sender, to: addresses(to header ?? ""), subject: decodeHeader(subject ?? "(No subject)"), body, date, unread: "UNREAD" ∈ labelIds, label: "INBOX"∈ ? "Inbox" : "SENT"∈ ? "Sent" : "Mail", attachments: refs}`.

Helpers:
- `decodeBase64url(s, limit=10MiB)`: `len(s) > ceil(limit*4/3)+4` → `Attachment or message body exceeds the size limit`; must match `^[A-Za-z0-9_-]*={0,2}$` else `Invalid base64url attachment or message body`; decoded > limit → `…is too large`; re-encoding (no pad) must equal input with trailing `=` stripped (canonical) else invalid.
- `decodeHeader` (RFC 2047): first remove whitespace (`[ \t]` or `\r\n[ \t]`, repeated) between `?=` and `=?`; then replace each `=\?([^?]+)\?([bq])\?([^?]*)\?=` (case-insens.): B → base64 decode; Q → `_`→space, `=XX` → byte, rest latin1 bytes; decode bytes with charset (strip RFC 2231 `*lang` suffix); on failure keep original text.
- `addresses(v)`: remove quoted display names `"(?:[^"\\]|\\.)*"\s*(?=<)` (replace by space), then all matches of `[A-Za-z0-9.!#$%&'*+/=?^_\`{|}~-]+@[A-Za-z0-9.-]+`.
- `decodeSnippet`: HTML entities `&amp; &lt; &gt; &quot; &apos; &nbsp;`(→space) and numeric `&#NN;`/`&#xHH;` (≤0x10FFFF), case-insens.; others unchanged.
- `htmlToPlainText(html)`: parse as HTML5 fragment (parse5; Erlang: mochiweb_html / floki-like parser acceptable); depth-first traversal; skip subtrees of `script style head template noscript iframe object svg math`; `br` → "\n"; block tags (`address article aside blockquote div footer form h1-h6 header hr li main ol p pre section table tr ul`) emit "\n" before and after; `td`/`th` emit "\t" after; text nodes verbatim (entities decoded by parser); comments contribute their text? (parse5 comment nodes have `data`, not `value` → ignored). Post-process: `[\t  ]+` → " "; ` *\n *` → "\n"; `\n{3,}` → "\n\n"; trim.

### 9.8 sendEmail (MIME construction)
Validation: emailDraft schema; subject & every recipient single-line (no char <0x20 or 0x7F → `Invalid <field>: header control characters are not allowed`); attachments ≤10 (`Attachment count exceeds the limit of 10`), name single-line, 1..180 UTF-8 bytes (`Invalid attachment name length`), mimeType `^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$`, each ≤10 MiB, total ≤20 MiB (`Total attachment size exceeds the 20 MiB limit`). `threadId` without `replyToMessageId` → `Replies require replyToMessageId to resolve the source message headers`.
Reply: fetch source metadata; threadId mismatch → `Reply thread does not match the source message`; Message-ID must match `^<[^<>\s]+@[^<>\s]+>$` (`Source message has no valid Message-ID for reply threading`); normalized subjects (decodeHeader, strip repeated leading `re:` case-insens., trim) must be equal (`Reply subject must match the source message subject`); References (if any) must match `^(?:<[^<>\s]+@[^<>\s]+>\s*)+$`; chain = unique([...refs, messageId]) joined by " " ≤ 950 chars; headers `In-Reply-To: <mid>`, `References: <chain>`; send with source threadId.
Message (CRLF line endings):
```
From: <profile emailAddress>
To: a,\r\n b               (joined ",\r\n ")
Cc: …                      (only if any)
Bcc: …                     (only if any)
Subject: =?UTF-8?B?…?=\r\n =?UTF-8?B?…?=   (subject split into chunks whose UTF-8 length ≤ 42 bytes without splitting code points, each base64 encoded)
Date: <JS toUTCString(), e.g. "Tue, 21 Oct 2026 10:00:00 GMT">
Message-ID: <uuid@openmuse.invalid>
[In-Reply-To / References]
MIME-Version: 1.0
```
Text part: `Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n` + base64(body with all newlines normalized to CRLF) wrapped at 76 chars with CRLF.
No attachments: headers + text part joined by CRLF (text part follows directly; no blank line between headers and text-part headers).
With attachments: boundary `openmuse_<uuid>`; headers + `Content-Type: multipart/mixed; boundary="<b>"` + "" + each `--<b>\r\n<part>` + `--<b>--` + "" joined by CRLF. Attachment part: `Content-Type: <mime>\r\nContent-Disposition: attachment; filename*=UTF-8''<encodeURIComponent(name) with ' ( ) * also %-escaped uppercase>\r\nContent-Transfer-Encoding: base64\r\n\r\n<wrapped base64>`.
POST `{raw: base64url_nopad(mime), threadId?}`; response must have `{id, threadId?}` else OutcomeUnknownError. Returns `{id, threadId}`.

### 9.9 Data returned to agent tools (shapes)
- `read_workspace {section}` → `{mail?:[Mail], events?:[CalendarEvent], files?:[Artifact without url]}`.
- `read_mail_thread {threadId}` (task) → `[Mail]`; chat version → `{messages: last 20 with body[0:12000], truncated}`.
- `search_mail {query≤500}` → `{matches:[{id,threadId,sender,from,subject,date,snippet}], truncated}`.
- `read_calendar {timeMin,timeMax}` → §4.5.
- `import_pdf {reference}` → `{id, name, fields}`; `inspect_pdf {fileId}` → `{id,name,fields,pageCount}`; `fill_pdf {fileId, fields}` → `{id,name,fields}`.
- `search_web` → §8; `read_web {url}` → `{sessionId,url,title,text≤30000,truncated}`; `browse_web {url≤4096}` → same.

---------------------------------------------------------------------------------------------------

## 10. Vault (packages/integrations/src/vault.ts)

Key: `TOKEN_ENCRYPTION_KEY` must be canonical standard base64 (padded) of exactly 32 bytes: `decode(key)` length 32 AND `encode(decode(key)) == key` byte-for-byte, else Error `Credential encryption requires a 32-byte base64 key`.
Cipher: AES-256-GCM, 12-byte random nonce, 16-byte tag, AAD = ASCII `openmuse:credential:v1`.
Envelope string: `"v1." ++ b64url(nonce) ++ "." ++ b64url(tag) ++ "." ++ b64url(ciphertext)` — base64url **without padding**.
Decrypt: split on `.` → exactly 4 parts with first == `v1` else `Invalid encrypted secret`; decode each of the 3 b64url parts; nonce len 12, tag len 16, and each part must round-trip canonically (re-encode == original) else `Invalid encrypted secret`; GCM auth failure → `Unable to authenticate or decrypt credential`. Plaintext UTF-8.
Erlang:
```erlang
{CT, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Plain, <<"openmuse:credential:v1">>, 16, true),
Plain = crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, CT, <<"openmuse:credential:v1">>, Tag, false). % returns error on bad tag
```
(base64url no-pad: `base64:encode(B, #{mode => urlsafe, padding => false})`, OTP 26+.) Existing DBs remain readable if the format is matched exactly.

---------------------------------------------------------------------------------------------------

## 11. Logging (log.ts)
- `backgroundFailure(phase, err)`: stderr object `{timestamp: ISO, context:{phase}, error: err.name | "Background operation failed", code?}` where code included only if `err.code` is a string matching `^[A-Za-z0-9_.-]{1,64}$`.
- `providerFailure(phase, err)`: `{timestamp, context:{phase, status? (number), requestId? (string)}, error: err.name | "Provider request failed"}`.
- Never log messages, bodies, URLs with credentials. HTTP 502 fallthrough logs `[OpenMuse] <name>`. Postgres pool errors → backgroundFailure("postgres pool").

---------------------------------------------------------------------------------------------------

## 12. Porting notes / gotchas

1. HMAC signing key is the base64 *text*, not decoded bytes (§3.2).
2. Signed-URL auth is chosen only if the path matches AND `signature` param is present; otherwise falls back to bearer. Console POST must accept signed auth.
3. Browser worker errors (incl. 409 limits) surface as **502** at the API; network failure → 503.
4. The API never calls worker `/navigate`; create, navigate and reopen all go through `POST /sessions {id,url}`. Browser `status:"idle"` exists only in API-side records.
5. Login limiter is global (not per IP) and counts successful logins.
6. `ALLOWED_ORIGINS` entries are not trimmed — `"a, b"` breaks the second origin.
7. `POST /api/drafts` returns 201 even for updates. `POST /api/files/:id/fill` over HTTP is not idempotent (new file each call); agent fill is keyed.
8. Many in-process single-flights (browser per-session queue, Google refresh, sample seeding) assume a single API process; cross-process safety comes only from DB CAS (computer lease, OAuth generation, credentials). Erlang: per-key gen_server/`global` locks give the same in-node behaviour.
9. Sample mode mail attachments are artifact ids; live are `msgId:attId:encodedName` references rewritten to artifact ids after import (cacheMail).
10. `timeZone` for sample events/calendars = server process TZ (`Intl…resolvedOptions().timeZone`); `at(h,m)` uses server-local time. Erlang: read `TZ`/system zone (e.g. via `tzdata`/`qdate`) consistently.
11. String comparisons for sorting dates are lexicographic on ISO strings (works because all are `…Z` ISO; mixed-offset live events sort lexically, not chronologically).
12. Docker file ops use fixed 8 s in-container timeout regardless of payload size (only E2B scales it) — a 10 MiB PDF over slow docker may hit it.
13. Leases are not renewed; a > 180 s op loses exclusivity (commands are bounded at ~35 s, so fine).
14. Everything external (Google, Parallel, worker, docker) is called with explicit timeouts: Google 30 s (OAuth 15 s), Parallel 45 s, worker 45 s (health 2 s), docker control 10 s / exec 35 s / file 10 s.
15. CopilotKit Intelligence (`/api/main-thread`, `/api/copilotkit/*`, CPK key required at boot) has no Erlang SDK — decide early whether to keep a Node shim or drop it.
