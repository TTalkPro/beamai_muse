import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createBrowserManager } from "../src/browser.ts";

async function candidateUrls(): Promise<string[]> {
  const urls: string[] = [];
  for (const hostname of ["example.com", "example.org"]) {
    try {
      const response = await fetch(`https://1.1.1.1/dns-query?name=${hostname}&type=A`, {
        headers: { accept: "application/dns-json" },
      });
      const body = (await response.json()) as {
        Answer?: { data?: string }[];
      };
      for (const answer of body.Answer ?? []) {
        if (typeof answer.data === "string") urls.push(`http://${answer.data}/`);
      }
    } catch {
      // Other candidates may still resolve.
    }
  }
  return [...new Set(urls)];
}

test("closeSession releases the session slot when cookie persistence fails", {
  timeout: 120_000,
}, async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "openmuse-browser-close-"));
  const browser = await createBrowserManager({ dataDir, maxSessions: 1 });
  const urls = await candidateUrls();
  const firstUrl = urls[0];
  assert.ok(firstUrl, "no candidate navigation URLs resolved");
  const id = randomUUID();
  const next = randomUUID();
  let url = firstUrl;
  let created = false;
  for (const candidate of urls) {
    try {
      await browser.create(id, candidate);
      url = candidate;
      created = true;
      break;
    } catch (error) {
      if ((error as { code?: string })?.code !== "NAVIGATION_FAILED") throw error;
    }
  }
  assert.ok(created, "could not navigate to any candidate URL");
  try {
    await mkdir(join(dataDir, id, "storage.json"), { recursive: true });
    await browser.closeSession(id);
    assert.equal(
      browser.list().find((session) => session.id === id)?.status,
      "closed",
      "the session must read back as closed",
    );
    const reopened = await browser.create(next, url);
    assert.equal(reopened.status, "active");
    await browser.closeSession(next);
  } finally {
    await browser.close();
    await rm(dataDir, { recursive: true, force: true });
  }
});
