// Unit tests of the sidecar's pure parts (no network): `npm test`.
import test from "node:test";
import assert from "node:assert/strict";
import { simpleParser } from "mailparser";
import MailComposer from "nodemailer/lib/mail-composer";
import { attachmentsOf, classify, folderRole, hasTextPart, snippetOf } from "../lib.mjs";

test("attachments come from the body structure, bodies do not", () => {
  const bs = {
    type: "multipart/mixed",
    childNodes: [
      {
        type: "multipart/alternative",
        childNodes: [
          { part: "1.1", type: "text/plain", parameters: { charset: "gbk" }, size: 10 },
          {
            part: "1.2",
            type: "multipart/related",
            childNodes: [
              { part: "1.2.1", type: "text/html", size: 20 },
              { part: "1.2.2", type: "image/png", id: "<logo@x>", disposition: "inline", size: 400, encoding: "base64" },
            ],
          },
        ],
      },
      {
        part: "2",
        type: "application/pdf",
        disposition: "attachment",
        dispositionParameters: { filename: "报价.pdf" },
        size: 4000,
        encoding: "base64",
      },
      { part: "3", type: "message/rfc822", size: 900 },
    ],
  };
  const atts = attachmentsOf(bs);
  assert.deepEqual(
    atts.map((a) => [a.part, a.filename, a.inline, a.size]),
    [
      ["1.2.2", "attachment.png", true, 300],
      ["2", "报价.pdf", false, 3000],
      ["3", "message.eml", false, 900],
    ]
  );
  assert.equal(hasTextPart(bs), true);
  assert.equal(hasTextPart({ type: "text/html" }), false);
  assert.deepEqual(attachmentsOf({ type: "text/plain" }), []);
});

test("folder roles from special use and INBOX", () => {
  assert.equal(folderRole({ path: "INBOX" }), "inbox");
  assert.equal(folderRole({ path: "[Gmail]/Sent Mail", specialUse: "\\Sent" }), "sent");
  assert.equal(folderRole({ path: "已删除", specialUse: "\\Trash" }), "trash");
  assert.equal(folderRole({ path: "Projects" }), null);
});

test("snippets drop quotes and collapse space", () => {
  assert.equal(snippetOf("Hi\n\n> old text\nsee   you"), "Hi see you");
  assert.equal([...snippetOf("长".repeat(300))].length, 200);
});

test("errors are classified without leaking the request", () => {
  assert.equal(classify(Object.assign(new Error("Command failed"), { authenticationFailed: true })).code, "auth");
  assert.equal(classify(Object.assign(new Error("x"), { code: "EAUTH" })).code, "auth");
  assert.equal(classify(Object.assign(new Error("self signed certificate"), { code: "DEPTH_ZERO_SELF_SIGNED_CERT" })).code, "tls");
  assert.equal(classify(Object.assign(new Error("Connection timed out"), { code: "ETIMEDOUT" })).code, "timeout");
  assert.equal(classify(Object.assign(new Error("getaddrinfo"), { code: "ENOTFOUND" })).code, "connect");
  assert.equal(classify(new Error("weird")).code, "error");
});

test("a composed reply parses back with its threading headers and attachment", async () => {
  const compiled = new MailComposer({
    from: { name: "我", address: "me@example.com" },
    to: [{ name: "张三", address: "zhang@example.com" }],
    bcc: [{ address: "hidden@example.com" }],
    subject: "回复：季度报告",
    text: "收到，谢谢。\n\n> 原文",
    inReplyTo: "<orig@example.com>",
    references: ["<root@example.com>", "<orig@example.com>"],
    attachments: [{ filename: "数据.csv", contentType: "text/csv", content: Buffer.from("a,b\n1,2\n") }],
  }).compile();
  const id = compiled.messageId();
  const envelope = compiled.getEnvelope();
  assert.deepEqual(envelope.to.sort(), ["hidden@example.com", "zhang@example.com"]);
  const raw = await compiled.build();
  assert.ok(!raw.toString().includes("hidden@example.com"), "Bcc stays out of the headers");
  const mail = await simpleParser(raw);
  assert.equal(mail.subject, "回复：季度报告");
  assert.equal(mail.messageId, id);
  assert.equal(mail.inReplyTo, "<orig@example.com>");
  assert.deepEqual(mail.references, ["<root@example.com>", "<orig@example.com>"]);
  assert.equal(mail.attachments[0].filename, "数据.csv");
  assert.match(mail.text, /收到，谢谢。/);
});

test("HTML-only mail gets a text version", async () => {
  const raw = "From: a@b.c\r\nSubject: hi\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hello <b>world</b></p><script>x()</script>";
  const mail = await simpleParser(Buffer.from(raw));
  assert.match(mail.text, /Hello world/);
});
