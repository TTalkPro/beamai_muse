import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { fixtureOrigin, fixturePdf, fixtureText, fixtureTitle } from "./fixtures.ts";

export type WorkerAddress = { base: string; fixtureBase: string };

// Run the same API assertions against a local process and the disposable image.
export async function checkBrowserWorker(
  token: string,
  address: WorkerAddress,
  restart: () => Promise<WorkerAddress>,
) {
  const id = randomUUID();
  const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
  async function api(path: string, body?: unknown) {
    const response = await fetch(`${address.base}${path}`, {
      headers,
      method: body === undefined ? "GET" : "POST",
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    assert(response.ok, `${path}: ${response.status} ${response.ok ? "" : await response.text()}`);
    return response;
  }
  async function requests() {
    const response = await fetch(`${address.fixtureBase}/__requests`);
    assert.equal(response.status, 200);
    const result = (await response.json()) as { paths: string[]; unexpected: string[] };
    assert.deepEqual(result.unexpected, [], "unexpected requests must not be hidden by a 403");
    return result.paths;
  }
  try {
    assert.equal((await fetch(`${address.base}/sessions`)).status, 401);
    const created = await (await api("/sessions", { id, url: `${fixtureOrigin}/page` })).json();
    assert.equal(created.status, "active");
    assert.equal(created.title, fixtureTitle);
    assert.deepEqual(await (await api(`/sessions/${id}/read`)).json(), {
      url: `${fixtureOrigin}/page`,
      title: fixtureTitle,
      text: fixtureText,
      truncated: false,
    });
    const image = Buffer.from(await (await api(`/sessions/${id}/screenshot`)).arrayBuffer());
    assert.equal(image.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
    assert.equal(image.readUInt32BE(16), 1280);
    assert.equal(image.readUInt32BE(20), 800);
    await api(`/sessions/${id}/input`, { type: "scroll", deltaY: 500 });
    const navigated = await (
      await api(`/sessions/${id}/navigate`, { url: `${fixtureOrigin}/other` })
    ).json();
    assert.equal(navigated.url, `${fixtureOrigin}/other`);
    assert.equal((await (await api(`/sessions/${id}/read`)).json()).text, "Another fixture page.");
    const blocked = await fetch(`${address.base}/sessions/${id}/navigate`, {
      headers,
      method: "POST",
      body: JSON.stringify({ url: "http://169.254.169.254/latest/meta-data" }),
    });
    assert.equal(blocked.status, 400);
    assert.equal((await blocked.json()).error.code, "BLOCKED_URL");
    const redirectSource = await fetch(`${address.fixtureBase}/redirect-private`, {
      redirect: "manual",
    });
    assert.equal(redirectSource.status, 302);
    assert.equal(redirectSource.headers.get("location"), "http://127.0.0.1/blocked");
    const redirects = (await requests()).filter((path) => path === "/redirect-private").length;
    const redirect = await fetch(`${address.base}/sessions/${id}/navigate`, {
      headers,
      method: "POST",
      body: JSON.stringify({ url: `${fixtureOrigin}/redirect-private` }),
    });
    assert.equal(redirect.status, 502);
    assert.equal((await redirect.json()).error.code, "NAVIGATION_FAILED");
    assert.equal(
      (await requests()).filter((path) => path === "/redirect-private").length,
      redirects + 1,
      "the browser must reach the actual redirect source",
    );
    await api(`/sessions/${id}/navigate`, { url: `${fixtureOrigin}/download.pdf` });
    let downloads: { id: string; name: string; mimeType: string }[] = [];
    for (let attempt = 0; attempt < 30; attempt++) {
      downloads = (await (await api(`/sessions/${id}/downloads`)).json()).downloads;
      if (downloads.length) break;
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    assert.equal(downloads.length, 1);
    const download = downloads[0];
    assert(download);
    assert.equal(download.name, "document.pdf");
    assert.equal(download.mimeType, "application/pdf");
    const pdf = Buffer.from(
      await (await api(`/sessions/${id}/downloads/${download.id}`)).arrayBuffer(),
    );
    assert.deepEqual(pdf, fixturePdf, "download bytes must match the controlled PDF");
    await api(`/sessions/${id}/navigate`, { url: `${fixtureOrigin}/download.txt` });
    let failures: { id: string; code: string; name: string }[] = [];
    for (let attempt = 0; attempt < 30; attempt++) {
      failures = (await (await api(`/sessions/${id}/downloads`)).json()).failures;
      if (failures.length) break;
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    assert.equal(failures.length, 1);
    assert.equal(failures[0]?.code, "UNSUPPORTED_DOWNLOAD");
    assert.equal(failures[0]?.name, "notes.txt");
    await api(`/sessions/${id}/navigate`, { url: `${fixtureOrigin}/seed` });
    assert.equal((await requests()).filter((path) => path === "/seed").length, 1);
    await api(`/sessions/${id}/close`, {});
    address = await restart();
    const restored = await (await api("/sessions")).json();
    assert(
      restored.some(
        (session: { id: string; status: string }) =>
          session.id === id && session.status === "closed",
      ),
    );
    const savedDownloads = await (await api(`/sessions/${id}/downloads`)).json();
    assert.deepEqual(savedDownloads.downloads, downloads);
    assert.deepEqual(savedDownloads.failures, failures);
    assert.deepEqual(
      Buffer.from(await (await api(`/sessions/${id}/downloads/${download.id}`)).arrayBuffer()),
      fixturePdf,
      "the saved PDF survives worker restart",
    );
    const reopened = await (await api("/sessions", { id, url: `${fixtureOrigin}/state` })).json();
    assert.equal(reopened.id, id);
    assert.equal(reopened.title, fixtureTitle);
    assert.equal((await (await api(`/sessions/${id}/read`)).json()).text, "retained");
    const paths = await requests();
    assert.equal(
      paths.filter((path) => path === "/seed").length,
      0,
      "restart must not reseed storage",
    );
    assert.equal(
      paths.filter((path) => path === "/download.pdf").length,
      0,
      "restart must not redownload the PDF",
    );
  } finally {
    await api(`/sessions/${id}/close`, {}).catch(() => {});
  }
  await requests();
}
