import assert from "node:assert/strict";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import { createServer, request } from "node:http";
import { startEgressProxy } from "../src/proxy.ts";

// Only a public URL identity: validated fixture traffic is sent to loopback.
export const fixtureOrigin = "http://1.1.1.1";
export const fixtureTitle = "OpenMuse fixture";
export const fixtureText = "Stable page text.";
export const fixturePdf = await readFile(new URL("./fixtures/document.pdf", import.meta.url));

export async function createBrowserFixture(options: { host?: string; port?: number } = {}) {
  const paths: string[] = [];
  const unexpected: string[] = [];
  const server = createServer((incoming, response) => {
    const path = incoming.url ?? "";
    if (path === "/__requests" && incoming.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ paths, unexpected }));
      return;
    }
    paths.push(path);
    if (path === "/redirect-private") {
      response.writeHead(302, { location: "http://127.0.0.1/blocked" });
      response.end();
      return;
    }
    if (path === "/download.pdf" || path === "/download.txt") {
      const pdf = path.endsWith(".pdf");
      response.writeHead(200, {
        "content-type": pdf ? "application/pdf" : "text/plain",
        "content-disposition": `attachment; filename="${pdf ? "document.pdf" : "notes.txt"}"`,
      });
      response.end(pdf ? fixturePdf : "Unsupported download.");
      return;
    }
    let body: string;
    if (path === "/page") body = fixtureText;
    else if (path === "/other") body = "Another fixture page.";
    else if (path === "/large?size=100000") body = "x".repeat(100_000);
    else if (path === "/large?size=100001") body = "x".repeat(100_001);
    else if (path === "/seed")
      body = `<script>localStorage.setItem("openmuse-profile-test", "retained");</script>`;
    else if (path === "/state")
      body = `<script>document.body.textContent = localStorage.getItem("openmuse-profile-test") ?? "missing";</script>`;
    else if (path === "/favicon.ico") {
      response.writeHead(204);
      response.end();
      return;
    } else {
      unexpected.push(`Unknown fixture path: ${path}`);
      response.writeHead(404);
      response.end();
      return;
    }
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(`<html><head><title>${fixtureTitle}</title></head><body>${body}</body></html>`);
  });
  server.listen(options.port ?? 0, options.host ?? "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert(address && typeof address !== "string");
  let proxyUrl = "";
  return {
    url: `http://127.0.0.1:${address.port}`,
    paths,
    unexpected,
    get proxyUrl() {
      return proxyUrl;
    },
    createProxy: async () => {
      const proxy = await startEgressProxy((options, onResponse) => {
        try {
          assert.equal(options.hostname, "1.1.1.1");
          assert.equal(options.family, 4);
          assert.equal(options.port, 80);
          assert.equal(options.method, "GET");
          assert(options.headers && "host" in options.headers);
          assert.equal(options.headers.host, "1.1.1.1");
        } catch (error) {
          unexpected.push(String(error));
          throw error;
        }
        return request({ ...options, hostname: "127.0.0.1", port: address.port }, onResponse);
      });
      proxyUrl = proxy.url;
      return proxy;
    },
    close: async () => {
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
    },
  };
}
