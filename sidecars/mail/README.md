# sidecars/mail

Port program used by `muse_mail_client` (designs/04-integrations.md §7): IMAP through
[imapflow](https://github.com/postalsys/imapflow), MIME parsing through
[mailparser](https://github.com/nodemailer/mailparser), SMTP and message building through
[nodemailer](https://nodemailer.com). Versions are pinned in `package.json` and
`package-lock.json`; install with `npm ci` (or `make sidecars`; `scripts/check.sh` and
`scripts/deploy.sh` do it when `node_modules` is missing).

Frames are `{packet,4}` (4-byte big-endian length + UTF-8 JSON) on stdin/stdout; requests carry an
`id` and are answered in any order, so slow servers do not hold up others.

| op | request | reply `ok` |
|---|---|---|
| `verify` | `account` | `{imap: {ok}\|{error}, smtp: {ok}\|{error}}` |
| `folders` | `account` | `{folders: [{path, name, delimiter, specialUse, role, noselect, status}]}` |
| `scan` | `account, path, known?, since?, max` | `{uidValidity, uidNext, exists, fresh, uids, flags: [[uid, flags]]}` |
| `fetch` | `account, path, uidValidity, uids, maxSource` | `{messages: [{uid, flags, date, subject, from, to, cc, messageId, inReplyTo, references, text, html, hasText, snippet, attachments, truncated}]}` |
| `attachment` | `account, path, uidValidity, uid, part, maxBytes` | `{filename, contentType, size, data}` (base64) |
| `flags` | `account, path, uidValidity, uids, add, remove` | `{}` |
| `move` | `account, path, uidValidity, uids, to, create?` | `{destination, uidValidity, uidMap}` |
| `expunge` | `account, path, uidValidity, uids` | `{}` |
| `send` | `account, message, sentFolder?` | `{messageId, accepted, rejected, appended, appendError}` |
| `watch` / `unwatch` | `watchId, account, path` | `{idle}`; then events `{event: "watch", watchId, kind}` |
| `close` | `accountId` | `{}` |

Errors are `{"id", "error": {"code", "message", "definite"?}}` with `code` one of `auth`, `tls`,
`timeout`, `connect`, `notfound`, `toolarge`, `uidvalidity`, `send_failed`, `error`. A send error
has `definite: false` when the connection failed while the message data was on its way: the server
may have accepted it, so the caller must not send again.

An `account` is `{id, imap: {host, port, security, user, pass, allowSelfSigned}, smtp: {...}}`;
`security` is `tls` (implicit TLS) or `starttls` (the upgrade is required: a server without
STARTTLS fails, nothing goes out in cleartext). Certificates are verified unless
`allowSelfSigned`. Passwords travel only inside these frames: imapflow and nodemailer run without
loggers and nothing else is logged.

`tests/lib.test.mjs` (`npm test`) covers the pure helpers and a compose/parse round trip;
`tests/fake-sidecar.mjs` is the scripted stand-in the Erlang tests run instead of this program.
