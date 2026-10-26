// Mail port program for muse_mail_client (designs/04-integrations.md §7).
//
// IMAP through imapflow, MIME parsing through mailparser, SMTP and message
// building through nodemailer. The BEAM side owns all state (accounts,
// folders, messages in Mnesia); this program only talks to the servers.
//
// Framing: {packet,4} frames (4-byte big-endian length + UTF-8 JSON) on
// stdin/stdout. Requests carry an `id` and are answered in any order:
//
//   {"id":N,"op":...}  ->  {"id":N,"ok":{...}}  |  {"id":N,"error":{"code","message","definite"?}}
//
// Watches (IMAP IDLE) also send unsolicited events:
//
//   {"event":"watch","watchId":W,"kind":"exists"|"expunge"|"flags"|"closed","message"?}
//
// Every request names its account, `{id, imap:{host,port,security,user,pass,
// allowSelfSigned}, smtp:{...}}` with `security` "tls" (implicit TLS) or
// "starttls" (required upgrade; never cleartext). Certificates are verified
// unless the account allows self-signed ones. Passwords only travel in these
// frames: nothing is logged (imapflow and nodemailer run without loggers) and
// error messages never include them.
//
// One IMAP connection per account is cached for two minutes of inactivity;
// operations on one account run one at a time. `close` drops an account's
// connection (the BEAM side sends it after a timeout or an account change).
// Timeouts: connect 20 s, greeting 16 s, socket inactivity 120 s; the BEAM
// side bounds every request as well.
import net from "node:net";
import { ImapFlow } from "imapflow";
import { simpleParser } from "mailparser";
import nodemailer from "nodemailer";
import MailComposer from "nodemailer/lib/mail-composer";
import { classify, attachmentsOf, folderRole, hasTextPart, snippetOf, uidRange } from "./lib.mjs";

// stdout carries frames only; keep any library output on stderr.
console.log = console.error;
console.info = console.error;
console.warn = console.error;

const IDLE_CLOSE_MS = 120000;
const conns = new Map();
const watches = new Map();

// ---------------------------------------------------------------- framing

let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk;
  while (buffer.length >= 4) {
    const len = buffer.readUInt32BE(0);
    if (buffer.length < 4 + len) break;
    const frame = buffer.subarray(4, 4 + len);
    buffer = buffer.subarray(4 + len);
    let request;
    try {
      request = JSON.parse(frame.toString("utf8"));
    } catch {
      continue;
    }
    handle(request);
  }
});
process.stdin.on("end", () => shutdown());

function send(obj) {
  const body = Buffer.from(JSON.stringify(obj), "utf8");
  const head = Buffer.alloc(4);
  head.writeUInt32BE(body.length, 0);
  process.stdout.write(Buffer.concat([head, body]));
}

async function handle(request) {
  const { id, op } = request;
  const fn = OPS[op];
  if (!fn) {
    send({ id, error: { code: "bad_request", message: `Unknown op ${op}` } });
    return;
  }
  try {
    const ok = await fn(request);
    send({ id, ok: ok ?? {} });
  } catch (err) {
    send({ id, error: classify(err) });
  }
}

function shutdown() {
  for (const entry of conns.values()) entry.client.close();
  for (const client of watches.values()) client.close();
  process.exit(0);
}

// ---------------------------------------------------------------- IMAP

// SNI takes host names only.
const sni = (host) => (net.isIP(host) ? undefined : host);

function imapOptions(imap) {
  return {
    host: imap.host,
    port: imap.port,
    secure: imap.security === "tls",
    doSTARTTLS: imap.security === "tls" ? undefined : true,
    auth: { user: imap.user, pass: imap.pass },
    tls: { rejectUnauthorized: !imap.allowSelfSigned, servername: sni(imap.host), minVersion: "TLSv1.2" },
    logger: false,
    emitLogs: false,
    connectionTimeout: 20000,
    greetingTimeout: 16000,
    socketTimeout: 120000,
    clientInfo: { name: "BeamAI Muse" },
  };
}

function connKey(imap) {
  return JSON.stringify([imap.host, imap.port, imap.security, imap.user, imap.pass, !!imap.allowSelfSigned]);
}

async function connect(imap, extra = {}) {
  const client = new ImapFlow({ ...imapOptions(imap), ...extra });
  client.on("error", () => {});
  await client.connect();
  return client;
}

// Run `fn(client)` on the account's cached connection, one at a time.
function withImap(account, fn) {
  const key = connKey(account.imap);
  let entry = conns.get(account.id);
  if (entry && entry.key !== key) {
    entry.client?.close();
    conns.delete(account.id);
    entry = undefined;
  }
  if (!entry) {
    entry = { key, client: null, queue: Promise.resolve(), timer: null };
    conns.set(account.id, entry);
  }
  const run = async () => {
    clearTimeout(entry.timer);
    if (!entry.client || !entry.client.usable) {
      entry.client?.close();
      entry.client = null;
      const client = await connect(account.imap, { disableAutoIdle: true });
      client.on("close", () => {
        if (entry.client === client) entry.client = null;
      });
      entry.client = client;
    }
    try {
      return await fn(entry.client);
    } finally {
      clearTimeout(entry.timer);
      entry.timer = setTimeout(() => {
        if (conns.get(account.id) === entry) {
          entry.client?.logout().catch(() => {});
          entry.client = null;
          conns.delete(account.id);
        }
      }, IDLE_CLOSE_MS);
      entry.timer.unref();
    }
  };
  const result = entry.queue.then(run, run);
  entry.queue = result.catch(() => {});
  return result;
}

async function withMailbox(client, path, readOnly, fn) {
  const lock = await client.getMailboxLock(path, { readOnly });
  try {
    return await fn(client.mailbox);
  } finally {
    lock.release();
  }
}

function checkValidity(mailbox, expected) {
  if (expected && String(mailbox.uidValidity) !== String(expected)) {
    const err = new Error("UIDVALIDITY changed");
    err.museCode = "uidvalidity";
    throw err;
  }
}

// ---------------------------------------------------------------- SMTP

function smtpTransport(smtp) {
  return nodemailer.createTransport({
    host: smtp.host,
    port: smtp.port,
    secure: smtp.security === "tls",
    requireTLS: smtp.security !== "tls",
    auth: { user: smtp.user, pass: smtp.pass },
    tls: { rejectUnauthorized: !smtp.allowSelfSigned, servername: sni(smtp.host), minVersion: "TLSv1.2" },
    connectionTimeout: 20000,
    greetingTimeout: 16000,
    socketTimeout: 60000,
    logger: false,
    debug: false,
  });
}

// ---------------------------------------------------------------- ops

const OPS = {
  // Both protocols, never throws: {imap:{ok}|{error}, smtp:...}
  async verify({ account }) {
    const imap = (async () => {
      const client = await connect(account.imap, { disableAutoIdle: true });
      await client.logout();
      return { ok: true };
    })().catch((err) => ({ error: classify(err) }));
    const smtp = (async () => {
      const t = smtpTransport(account.smtp);
      try {
        await t.verify();
      } finally {
        t.close();
      }
      return { ok: true };
    })().catch((err) => ({ error: classify(err) }));
    const [i, s] = await Promise.all([imap, smtp]);
    return { imap: i, smtp: s };
  },

  async folders({ account }) {
    return withImap(account, async (client) => {
      const list = await client.list({
        statusQuery: { messages: true, unseen: true, uidNext: true, uidValidity: true },
      });
      return {
        folders: list.map((f) => ({
          path: f.path,
          name: f.name,
          delimiter: f.delimiter,
          specialUse: f.specialUse || null,
          role: folderRole(f),
          noselect: f.flags.has("\\Noselect") || f.flags.has("\\NonExistent"),
          subscribed: f.subscribed,
          status: f.status
            ? {
                messages: f.status.messages ?? null,
                unseen: f.status.unseen ?? null,
                uidNext: f.status.uidNext ?? null,
                uidValidity: f.status.uidValidity != null ? String(f.status.uidValidity) : null,
              }
            : null,
        })),
      };
    });
  },

  // What changed in a folder: the UIDs to fetch and the flags of the known
  // range. `known`: {uidValidity, lastUid, minUid} or null for a first sync;
  // `since`: ISO date of the window; `max`: newest UIDs kept.
  async scan({ account, path, known, since, max }) {
    return withImap(account, (client) =>
      withMailbox(client, path, true, async (mailbox) => {
        const uidValidity = String(mailbox.uidValidity);
        const fresh = !known || String(known.uidValidity) !== uidValidity;
        let uids = [];
        let flags = [];
        if (mailbox.exists > 0) {
          if (fresh) {
            const query = since ? { since: new Date(since) } : { all: true };
            uids = (await client.search(query, { uid: true })) || [];
          } else {
            const found = (await client.search({ uid: `${known.lastUid + 1}:*` }, { uid: true })) || [];
            uids = found.filter((u) => u > known.lastUid);
            if (known.minUid && known.lastUid >= known.minUid) {
              for await (const msg of client.fetch(
                uidRange(known.minUid, known.lastUid),
                { uid: true, flags: true },
                { uid: true }
              )) {
                flags.push([msg.uid, [...(msg.flags || [])]]);
              }
            }
          }
        }
        uids.sort((a, b) => a - b);
        if (max && uids.length > max) uids = uids.slice(uids.length - max);
        return {
          uidValidity,
          uidNext: mailbox.uidNext ?? null,
          exists: mailbox.exists,
          fresh,
          uids,
          flags,
        };
      })
    );
  },

  // Parsed messages: headers, flags, text and HTML bodies (the first
  // `maxSource` bytes of the source), attachments from the BODYSTRUCTURE.
  async fetch({ account, path, uidValidity, uids, maxSource }) {
    return withImap(account, (client) =>
      withMailbox(client, path, true, async (mailbox) => {
        checkValidity(mailbox, uidValidity);
        const out = [];
        if (!uids.length) return { messages: out };
        const raw = [];
        for await (const msg of client.fetch(
          uids.join(","),
          {
            uid: true,
            flags: true,
            size: true,
            internalDate: true,
            envelope: true,
            bodyStructure: true,
            source: { maxLength: maxSource || 1048576 },
          },
          { uid: true }
        )) {
          raw.push(msg);
        }
        for (const msg of raw) out.push(await parsed(msg, maxSource || 1048576));
        return { messages: out };
      })
    );
  },

  async attachment({ account, path, uidValidity, uid, part, maxBytes }) {
    return withImap(account, (client) =>
      withMailbox(client, path, true, async (mailbox) => {
        checkValidity(mailbox, uidValidity);
        const dl = await client.download(String(uid), part, { uid: true, maxBytes: maxBytes + 1 });
        if (!dl.content) {
          const err = new Error("Attachment not found");
          err.museCode = "notfound";
          throw err;
        }
        const chunks = [];
        let size = 0;
        for await (const c of dl.content) {
          size += c.length;
          if (size > maxBytes) {
            const err = new Error("Attachment is too large");
            err.museCode = "toolarge";
            throw err;
          }
          chunks.push(c);
        }
        return {
          filename: dl.meta.filename || null,
          contentType: dl.meta.contentType || "application/octet-stream",
          size,
          data: Buffer.concat(chunks).toString("base64"),
        };
      })
    );
  },

  async flags({ account, path, uidValidity, uids, add, remove }) {
    return withImap(account, (client) =>
      withMailbox(client, path, false, async (mailbox) => {
        checkValidity(mailbox, uidValidity);
        const range = uids.join(",");
        if (add && add.length) await client.messageFlagsAdd(range, add, { uid: true });
        if (remove && remove.length) await client.messageFlagsRemove(range, remove, { uid: true });
        return {};
      })
    );
  },

  async move({ account, path, uidValidity, uids, to, create }) {
    return withImap(account, async (client) => {
      if (create) {
        const list = await client.list();
        if (!list.some((f) => f.path === to)) await client.mailboxCreate(to);
      }
      return withMailbox(client, path, false, async (mailbox) => {
        checkValidity(mailbox, uidValidity);
        const res = await client.messageMove(uids.join(","), to, { uid: true });
        return {
          destination: to,
          uidValidity: res && res.uidValidity != null ? String(res.uidValidity) : null,
          uidMap: res && res.uidMap ? [...res.uidMap.entries()] : [],
        };
      });
    });
  },

  async expunge({ account, path, uidValidity, uids }) {
    return withImap(account, (client) =>
      withMailbox(client, path, false, async (mailbox) => {
        checkValidity(mailbox, uidValidity);
        await client.messageDelete(uids.join(","), { uid: true });
        return {};
      })
    );
  },

  // Build the message once, send it over SMTP, then (optionally) append the
  // same bytes to the Sent folder. An error after the DATA command may mean
  // the server took the message: `definite` is false then.
  async send({ account, message, sentFolder }) {
    const compiled = new MailComposer(composerOptions(message)).compile();
    const messageId = compiled.messageId();
    const envelope = compiled.getEnvelope();
    const raw = await compiled.build();
    const transport = smtpTransport(account.smtp);
    let info;
    try {
      info = await transport.sendMail({ envelope, raw });
    } catch (err) {
      const e = classify(err);
      if (!["auth", "tls", "connect"].includes(e.code)) e.code = "send_failed";
      // a server reply (4xx/5xx) is a refusal; a connection lost while or
      // after the message data went out leaves the outcome open
      const refused = typeof err.responseCode === "number" && err.responseCode >= 400;
      const duringData = err.command === "DATA" || err.command === "MESSAGE" || err.command === "message";
      e.definite = refused || !duringData;
      throw Object.assign(new Error(e.message), { museError: e });
    } finally {
      transport.close();
    }
    let appended = false;
    let appendError = null;
    if (sentFolder) {
      try {
        await withImap(account, (client) => client.append(sentFolder, raw, ["\\Seen"]));
        appended = true;
      } catch (err) {
        appendError = classify(err).message;
      }
    }
    return {
      messageId,
      accepted: (info.accepted || []).map(String),
      rejected: (info.rejected || []).map(String),
      appended,
      appendError,
    };
  },

  // IDLE on one folder through a connection of its own; events go out as
  // they come. Answered once connected.
  async watch({ watchId, account, path }) {
    const old = watches.get(watchId);
    if (old) old.close();
    const client = await connect(account.imap, { maxIdleTime: 240000 });
    watches.set(watchId, client);
    const emit = (kind, message) => send({ event: "watch", watchId, kind, message });
    client.on("exists", () => emit("exists"));
    client.on("expunge", () => emit("expunge"));
    client.on("flags", () => emit("flags"));
    client.on("close", () => {
      if (watches.get(watchId) === client) {
        watches.delete(watchId);
        emit("closed");
      }
    });
    await client.mailboxOpen(path, { readOnly: true });
    return { idle: client.capabilities.has("IDLE") };
  },

  async unwatch({ watchId }) {
    const client = watches.get(watchId);
    watches.delete(watchId);
    if (client) await client.logout().catch(() => client.close());
    return {};
  },

  async close({ accountId }) {
    const entry = conns.get(accountId);
    conns.delete(accountId);
    if (entry && entry.client) entry.client.close();
    return {};
  },
};

function composerOptions(m) {
  return {
    from: m.from,
    to: m.to,
    cc: m.cc && m.cc.length ? m.cc : undefined,
    bcc: m.bcc && m.bcc.length ? m.bcc : undefined,
    subject: m.subject,
    text: m.text,
    html: m.html || undefined,
    inReplyTo: m.inReplyTo || undefined,
    references: m.references && m.references.length ? m.references : undefined,
    date: new Date(),
    attachments: (m.attachments || []).map((a) => ({
      filename: a.filename,
      contentType: a.contentType,
      content: Buffer.from(a.data, "base64"),
    })),
    disableFileAccess: true,
    disableUrlAccess: true,
  };
}

async function parsed(msg, maxSource) {
  const env = msg.envelope || {};
  let mail = {};
  try {
    mail = await simpleParser(msg.source || Buffer.alloc(0), {
      skipImageLinks: true,
      skipTextToHtml: true,
      skipTextLinks: true,
      maxHtmlLengthToParse: 2 * 1024 * 1024,
    });
  } catch {
    mail = {};
  }
  const refs = mail.references ? [].concat(mail.references) : [];
  const text = typeof mail.text === "string" ? mail.text : "";
  const html = typeof mail.html === "string" ? mail.html : "";
  const addr = (list) => (list || []).filter((a) => a && a.address).map((a) => ({ name: a.name || "", address: a.address }));
  return {
    uid: msg.uid,
    flags: [...(msg.flags || [])],
    size: msg.size ?? null,
    internalDate: msg.internalDate ? new Date(msg.internalDate).toISOString() : null,
    date: env.date ? new Date(env.date).toISOString() : null,
    subject: env.subject || mail.subject || "",
    messageId: env.messageId || mail.messageId || null,
    inReplyTo: env.inReplyTo || mail.inReplyTo || null,
    references: refs,
    from: addr(env.from),
    to: addr(env.to),
    cc: addr(env.cc),
    replyTo: addr(env.replyTo),
    text,
    html,
    hasText: hasTextPart(msg.bodyStructure),
    snippet: snippetOf(text),
    attachments: attachmentsOf(msg.bodyStructure),
    truncated: (msg.size || 0) > maxSource,
  };
}
