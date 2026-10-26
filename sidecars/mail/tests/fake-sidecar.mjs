// A scripted stand-in for sidecars/mail/index.mjs, for the Erlang tests
// (muse_mail_fake in apps/muse_integ/test). Same frames and ops, but the
// "servers" are a JSON state file (argv[2]) that the tests write and read:
//
//   {"accounts": {"<user>": {"password": "...", "folders": [
//       {"path","name","delimiter","specialUse","uidValidity","uidNext",
//        "messages": [{"uid","flags","date","subject","from","to","cc",
//                      "messageId","inReplyTo","references","text","html",
//                      "attachments":[{"part","filename","contentType","data"}]}]}]}},
//    "sent": [...], "fail": {"<op>": {code,message,definite}},
//    "delay": {"<op>": ms}}
//
// The file is read for every request and written (whole, then renamed) only
// by the ops that change it; requests run to completion one after another,
// apart from a scripted delay. `fail` entries are one-shot. A watch polls INBOX's uidNext every 200 ms and reports
// `exists` when it grows.
import fs from "node:fs";
import { snippetOf } from "../lib.mjs";

const STATE = process.argv[2];
console.log = console.error;

const load = () => JSON.parse(fs.readFileSync(STATE, "utf8"));
// written whole and renamed, so a reader never sees half a file
const save = (s) => {
  fs.writeFileSync(`${STATE}.tmp`, JSON.stringify(s, null, 1));
  fs.renameSync(`${STATE}.tmp`, STATE);
};
// ops that change the "servers" (the others never write the file)
const WRITES = new Set(["flags", "move", "expunge", "send"]);

let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (buffer.length >= 4) {
    const len = buffer.readUInt32BE(0);
    if (buffer.length < 4 + len) break;
    const req = JSON.parse(buffer.subarray(4, 4 + len).toString("utf8"));
    buffer = buffer.subarray(4 + len);
    handle(req);
  }
});
process.stdin.on("end", () => process.exit(0));

function send(obj) {
  const body = Buffer.from(JSON.stringify(obj), "utf8");
  const head = Buffer.alloc(4);
  head.writeUInt32BE(body.length, 0);
  process.stdout.write(Buffer.concat([head, body]));
}

class Fail extends Error {
  constructor(code, message, definite) {
    super(message);
    this.code = code;
    this.definite = definite;
  }
}

async function handle(req) {
  const { id, op } = req;
  // housekeeping frames (no reply is awaited) leave the state alone
  if (op === "close" || op === "unwatch") {
    if (op === "unwatch") OPS.unwatch(null, req);
    send({ id, ok: {} });
    return;
  }
  try {
    let s = load();
    const delay = s.delay && s.delay[op];
    if (delay) await new Promise((r) => setTimeout(r, delay));
    s = load();
    const fail = s.fail && s.fail[op];
    if (fail) {
      delete s.fail[op];
      save(s);
      throw new Fail(fail.code, fail.message || fail.code, fail.definite);
    }
    const ok = OPS[op](s, req);
    if (WRITES.has(op)) save(s);
    send({ id, ok: ok || {} });
  } catch (e) {
    const error = { code: e.code || "error", message: e.message };
    if (e.definite !== undefined) error.definite = e.definite;
    send({ id, error });
  }
}

function login(s, creds) {
  if (creds.host === "unreachable.invalid") throw new Fail("connect", "getaddrinfo ENOTFOUND unreachable.invalid");
  if (creds.host === "selfsigned.invalid" && !creds.allowSelfSigned)
    throw new Fail("tls", "self-signed certificate");
  const acc = s.accounts[creds.user];
  if (!acc || acc.password !== creds.pass) throw new Fail("auth", "Invalid credentials (Failure)");
  return acc;
}

function folder(acc, path) {
  const f = acc.folders.find((x) => x.path === path);
  if (!f) throw new Fail("error", `Mailbox doesn't exist: ${path}`);
  return f;
}

function checkValidity(f, v) {
  if (v && String(f.uidValidity) !== String(v)) throw new Fail("uidvalidity", "UIDVALIDITY changed");
}

function role(f) {
  if (f.path.toUpperCase() === "INBOX") return "inbox";
  return { "\\Sent": "sent", "\\Drafts": "drafts", "\\Trash": "trash", "\\Junk": "junk", "\\Archive": "archive", "\\All": "all" }[f.specialUse] || null;
}

function htmlText(html) {
  return (html || "").replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}

function wire(m) {
  return {
    uid: m.uid,
    flags: m.flags || [],
    size: (m.text || "").length + (m.html || "").length + 200,
    internalDate: m.date,
    date: m.date,
    subject: m.subject || "",
    messageId: m.messageId || null,
    inReplyTo: m.inReplyTo || null,
    references: m.references || [],
    from: m.from || [],
    to: m.to || [],
    cc: m.cc || [],
    replyTo: m.replyTo || [],
    // like mailparser, HTML-only mail gets a text version
    text: m.text || htmlText(m.html),
    html: m.html || "",
    hasText: !!m.text,
    snippet: snippetOf(m.text || htmlText(m.html)),
    attachments: (m.attachments || []).map((a) => ({
      part: a.part,
      filename: a.filename,
      contentType: a.contentType,
      size: Buffer.from(a.data, "base64").length,
      cid: a.cid || null,
      inline: !!a.inline,
    })),
    truncated: false,
  };
}

const OPS = {
  verify(s, { account }) {
    const res = {};
    for (const p of ["imap", "smtp"]) {
      try {
        login(s, account[p]);
        res[p] = { ok: true };
      } catch (e) {
        res[p] = { error: { code: e.code, message: e.message } };
      }
    }
    return res;
  },
  folders(s, { account }) {
    const acc = login(s, account.imap);
    return {
      folders: acc.folders.map((f) => ({
        path: f.path,
        name: f.name || f.path,
        delimiter: f.delimiter || "/",
        specialUse: f.specialUse || null,
        role: role(f),
        noselect: !!f.noselect,
        subscribed: true,
        status: {
          messages: f.messages.length,
          unseen: f.messages.filter((m) => !(m.flags || []).includes("\\Seen")).length,
          uidNext: f.uidNext,
          uidValidity: String(f.uidValidity),
        },
      })),
    };
  },
  scan(s, { account, path, known, since, max }) {
    const f = folder(login(s, account.imap), path);
    const fresh = !known || String(known.uidValidity) !== String(f.uidValidity);
    let uids;
    let flags = [];
    if (fresh) {
      uids = f.messages.filter((m) => !since || new Date(m.date) >= new Date(since)).map((m) => m.uid);
    } else {
      uids = f.messages.filter((m) => m.uid > known.lastUid).map((m) => m.uid);
      flags = f.messages
        .filter((m) => m.uid >= known.minUid && m.uid <= known.lastUid)
        .map((m) => [m.uid, m.flags || []]);
    }
    uids.sort((a, b) => a - b);
    if (max && uids.length > max) uids = uids.slice(uids.length - max);
    return { uidValidity: String(f.uidValidity), uidNext: f.uidNext, exists: f.messages.length, fresh, uids, flags };
  },
  fetch(s, { account, path, uidValidity, uids }) {
    const f = folder(login(s, account.imap), path);
    checkValidity(f, uidValidity);
    return { messages: f.messages.filter((m) => uids.includes(m.uid)).map(wire) };
  },
  attachment(s, { account, path, uidValidity, uid, part, maxBytes }) {
    const f = folder(login(s, account.imap), path);
    checkValidity(f, uidValidity);
    const m = f.messages.find((x) => x.uid === uid);
    const a = m && (m.attachments || []).find((x) => x.part === part);
    if (!a) throw new Fail("notfound", "Attachment not found");
    const size = Buffer.from(a.data, "base64").length;
    if (size > maxBytes) throw new Fail("toolarge", "Attachment is too large");
    return { filename: a.filename, contentType: a.contentType, size, data: a.data };
  },
  flags(s, { account, path, uidValidity, uids, add, remove }) {
    const f = folder(login(s, account.imap), path);
    checkValidity(f, uidValidity);
    for (const m of f.messages) {
      if (!uids.includes(m.uid)) continue;
      const set = new Set(m.flags || []);
      (add || []).forEach((x) => set.add(x));
      (remove || []).forEach((x) => set.delete(x));
      m.flags = [...set];
    }
    return {};
  },
  move(s, { account, path, uidValidity, uids, to, create }) {
    const acc = login(s, account.imap);
    const from = folder(acc, path);
    checkValidity(from, uidValidity);
    let dest = acc.folders.find((x) => x.path === to);
    if (!dest && create) {
      dest = { path: to, name: to, delimiter: "/", specialUse: null, uidValidity: 7, uidNext: 1, messages: [] };
      acc.folders.push(dest);
    }
    if (!dest) throw new Fail("error", `Mailbox doesn't exist: ${to}`);
    const map = [];
    from.messages = from.messages.filter((m) => {
      if (!uids.includes(m.uid)) return true;
      const uid = dest.uidNext++;
      dest.messages.push({ ...m, uid });
      map.push([m.uid, uid]);
      return false;
    });
    return { destination: to, uidValidity: String(dest.uidValidity), uidMap: map };
  },
  expunge(s, { account, path, uidValidity, uids }) {
    const f = folder(login(s, account.imap), path);
    checkValidity(f, uidValidity);
    f.messages = f.messages.filter((m) => !uids.includes(m.uid));
    return {};
  },
  send(s, { account, message, sentFolder }) {
    const acc = login(s, account.smtp);
    s.sent = s.sent || [];
    const n = s.sent.length + 1;
    const messageId = `<fake-${n}@muse.test>`;
    s.sent.push({
      user: account.smtp.user,
      messageId,
      from: message.from,
      to: message.to,
      cc: message.cc || [],
      bcc: message.bcc || [],
      subject: message.subject,
      text: message.text,
      inReplyTo: message.inReplyTo || null,
      references: message.references || [],
      attachments: (message.attachments || []).map((a) => ({
        filename: a.filename,
        contentType: a.contentType,
        size: Buffer.from(a.data, "base64").length,
      })),
      sentFolder: sentFolder || null,
    });
    let appended = false;
    if (sentFolder) {
      const f = folder(acc, sentFolder);
      f.messages.push({
        uid: f.uidNext++,
        flags: ["\\Seen"],
        date: new Date().toISOString(),
        subject: message.subject,
        from: [message.from],
        to: message.to,
        cc: message.cc || [],
        messageId,
        inReplyTo: message.inReplyTo || null,
        references: message.references || [],
        text: message.text,
      });
      appended = true;
    }
    const all = [...message.to, ...(message.cc || []), ...(message.bcc || [])].map((a) => a.address);
    return { messageId, accepted: all, rejected: [], appended, appendError: null };
  },
  watch(s, { watchId, account, path }) {
    const f = folder(login(s, account.imap), path);
    let last = f.uidNext;
    const timer = setInterval(() => {
      try {
        const g = load().accounts[account.imap.user].folders.find((x) => x.path === path);
        if (g && g.uidNext !== last) {
          last = g.uidNext;
          send({ event: "watch", watchId, kind: "exists" });
        }
      } catch {}
    }, 200);
    timer.unref();
    watches.set(watchId, timer);
    return { idle: true };
  },
  unwatch(s, { watchId }) {
    clearInterval(watches.get(watchId));
    watches.delete(watchId);
    return {};
  },
  close() {
    return {};
  },
};

const watches = new Map();
