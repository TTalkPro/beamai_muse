// Pure helpers of the mail sidecar (tested by tests/lib.test.mjs).

const TLS_CODES = new Set([
  "CERT_HAS_EXPIRED",
  "CERT_NOT_YET_VALID",
  "DEPTH_ZERO_SELF_SIGNED_CERT",
  "SELF_SIGNED_CERT_IN_CHAIN",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
  "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
  "ERR_TLS_CERT_ALTNAME_INVALID",
  "ETLS",
]);
const TIMEOUT_CODES = new Set(["ETIMEDOUT", "CONNECT_TIMEOUT", "GreetingTimeout", "ETIMEOUT", "SocketTimeout"]);
const CONNECT_CODES = new Set([
  "ENOTFOUND",
  "EAI_AGAIN",
  "ECONNREFUSED",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "ECONNRESET",
  "EPIPE",
  "ECONNECTION",
  "ESOCKET",
  "NoConnection",
  "EDNS",
]);

// An error as {code, message}: auth | tls | timeout | connect | notfound |
// toolarge | uidvalidity | send_failed | error. Messages are short and never
// carry credentials (servers do not echo them; the request is not included).
export function classify(err) {
  if (err && err.museError) return err.museError;
  const message = short(err);
  if (err && err.museCode) return { code: err.museCode, message };
  const code = (err && err.code) || "";
  const text = `${message} ${err && err.responseText ? err.responseText : ""}`;
  if (err && (err.authenticationFailed || err.serverResponseCode === "AUTHENTICATIONFAILED" || code === "EAUTH"))
    return { code: "auth", message };
  if (TLS_CODES.has(code) || /^ERR_TLS|^ERR_SSL|^CERT_/.test(code) || /certificate|STARTTLS|TLS/i.test(text))
    return { code: "tls", message };
  if (TIMEOUT_CODES.has(code) || /timed? ?out/i.test(text)) return { code: "timeout", message };
  if (CONNECT_CODES.has(code)) return { code: "connect", message };
  if (/AUTHENTICATE|LOGIN|credentials|password/i.test(text) && /fail|invalid|denied|incorrect/i.test(text))
    return { code: "auth", message };
  return { code: "error", message };
}

function short(err) {
  let m = err && err.message ? String(err.message) : String(err);
  if (err && err.responseText && !m.includes(err.responseText)) m = `${m}: ${err.responseText}`;
  m = m.replace(/\s+/g, " ").trim();
  return m.length > 300 ? `${m.slice(0, 297)}...` : m;
}

const ROLES = {
  "\\Inbox": "inbox",
  "\\Sent": "sent",
  "\\Drafts": "drafts",
  "\\Trash": "trash",
  "\\Junk": "junk",
  "\\Archive": "archive",
  "\\All": "all",
  "\\Flagged": "flagged",
};

// The role of a listed folder from its special-use flag (imapflow also
// recognises well-known localised names), INBOX by path.
export function folderRole(f) {
  if (f.path && f.path.toUpperCase() === "INBOX") return "inbox";
  return ROLES[f.specialUse] || null;
}

// First 200 characters of the text, quoted lines dropped, spaces collapsed.
export function snippetOf(text) {
  if (!text) return "";
  const lines = String(text)
    .split(/\r?\n/)
    .filter((l) => !/^\s*>/.test(l));
  const s = lines.join(" ").replace(/\s+/g, " ").trim();
  return [...s].slice(0, 200).join("");
}

export function uidRange(from, to) {
  return `${from}:${to}`;
}

// Attachments from a BODYSTRUCTURE: every leaf that is not the message's
// own text or HTML body. `part` is the IMAP section to download; `inline`
// marks parts the HTML refers to by Content-ID.
export function attachmentsOf(node) {
  const out = [];
  walk(node, out, true);
  return out;
}

function walk(node, out, root) {
  if (!node) return;
  const type = String(node.type || "application/octet-stream").toLowerCase();
  if (node.childNodes && node.childNodes.length && type.startsWith("multipart/")) {
    for (const child of node.childNodes) walk(child, out, false);
    return;
  }
  const disposition = node.disposition ? String(node.disposition).toLowerCase() : null;
  const filename =
    (node.dispositionParameters && node.dispositionParameters.filename) ||
    (node.parameters && node.parameters.name) ||
    null;
  const isBody = (type === "text/plain" || type === "text/html") && disposition !== "attachment" && !filename;
  if (isBody) return;
  const cid = node.id ? String(node.id).replace(/^<|>$/g, "") : null;
  const encoded = node.size || 0;
  const size = String(node.encoding || "").toLowerCase() === "base64" ? Math.floor((encoded * 3) / 4) : encoded;
  out.push({
    part: node.part || "1",
    filename: filename || defaultName(type),
    contentType: type,
    size,
    cid,
    inline: disposition === "inline" ? !!cid : !disposition && !!cid,
  });
}

// True when the message has a text/plain body part of its own.
export function hasTextPart(node) {
  if (!node) return false;
  const type = String(node.type || "").toLowerCase();
  if (node.childNodes && node.childNodes.length && type.startsWith("multipart/"))
    return node.childNodes.some(hasTextPart);
  const disposition = node.disposition ? String(node.disposition).toLowerCase() : null;
  const filename =
    (node.dispositionParameters && node.dispositionParameters.filename) || (node.parameters && node.parameters.name);
  return type === "text/plain" && disposition !== "attachment" && !filename;
}

function defaultName(type) {
  if (type === "message/rfc822") return "message.eml";
  if (type === "text/calendar") return "invite.ics";
  const sub = type.split("/")[1] || "bin";
  return `attachment.${sub.replace(/[^a-z0-9]+/g, "") || "bin"}`;
}
