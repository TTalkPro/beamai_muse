import assert from "node:assert/strict";
import { type ChildProcess, fork } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createBrowserManager } from "../src/browser.ts";
import { createBrowserFixture, fixtureOrigin, fixtureText, fixtureTitle } from "./fixtures.ts";
import { checkBrowserWorker, type WorkerAddress } from "./worker-checks.ts";

test("real Chromium cleans failed profiles and restores a saved UUID after worker restart", {
  timeout: 90_000,
}, async (t) => {
  const fixture = await createBrowserFixture();
  t.after(async () => {
    try {
      await fixture.close();
    } finally {
      assert.deepEqual(fixture.unexpected, []);
    }
  });
  const dataDir = await mkdtemp(join(tmpdir(), "openmuse-browser-lifecycle-"));
  const id = randomUUID();
  const failedId = randomUUID();
  let browser: Awaited<ReturnType<typeof createBrowserManager>> | undefined;
  try {
    const createProxy = fixture.createProxy;
    browser = await createBrowserManager({ dataDir }, createProxy);

    // A private destination must be rejected before the injected sender runs.
    const proxyAddress = new URL(fixture.proxyUrl);
    const blocked = await new Promise<number>((resolve, reject) => {
      const outgoing = request(
        {
          hostname: proxyAddress.hostname,
          port: proxyAddress.port,
          path: "http://127.0.0.1/blocked",
        },
        (response) => {
          response.resume();
          resolve(response.statusCode ?? 0);
        },
      );
      outgoing.on("error", reject);
      outgoing.end();
    });
    assert.equal(blocked, 403);
    assert.deepEqual(fixture.paths, [], "private requests never reach the fixture server");
    await assert.rejects(browser.create(failedId, "http://127.0.0.1/blocked"), {
      code: "BLOCKED_URL",
    });
    await assert.rejects(browser.create(failedId, `${fixtureOrigin}/redirect-private`), {
      code: "NAVIGATION_FAILED",
    });
    assert.equal(fixture.paths.filter((path) => path === "/redirect-private").length, 1);
    assert.equal(browser.list().length, 0, "failed creation must release its saved-profile slot");
    assert.equal(
      (await readdir(dataDir)).includes(failedId),
      false,
      "unclaimed profile is removed",
    );

    await browser.create(id, `${fixtureOrigin}/page`);
    assert.deepEqual(await browser.read(id), {
      url: `${fixtureOrigin}/page`,
      title: fixtureTitle,
      text: fixtureText,
      truncated: false,
    });
    await browser.navigate(id, `${fixtureOrigin}/seed`);
    await browser.closeSession(id);
    await browser.close();
    browser = await createBrowserManager({ dataDir }, createProxy);
    assert.equal(browser.list()[0]?.status, "closed");
    const reopened = await browser.create(id, `${fixtureOrigin}/page`);
    assert.equal(reopened.id, id);
    assert.equal(reopened.title, fixtureTitle);
    assert.deepEqual(await browser.read(id), {
      url: `${fixtureOrigin}/page`,
      title: fixtureTitle,
      text: fixtureText,
      truncated: false,
    });
    await browser.navigate(id, `${fixtureOrigin}/state`);
    assert.equal((await browser.read(id)).text, "retained");
    assert.equal(fixture.paths.filter((path) => path === "/seed").length, 1);

    for (const size of [100_000, 100_001]) {
      const url = `${fixtureOrigin}/large?size=${size}`;
      await browser.navigate(id, url);
      assert.deepEqual(await browser.read(id), {
        url,
        title: fixtureTitle,
        text: "x".repeat(100_000),
        truncated: size > 100_000,
      });
    }
    await browser.closeSession(id);
    const state = JSON.parse(await readFile(join(dataDir, id, "storage.json"), "utf8"));
    assert(
      state.origins
        .find((item: { origin: string }) => item.origin === fixtureOrigin)
        ?.localStorage.some(
          (item: { name: string; value: string }) =>
            item.name === "openmuse-profile-test" && item.value === "retained",
        ),
    );
  } finally {
    try {
      await browser?.close();
    } finally {
      await rm(dataDir, { recursive: true, force: true });
      for (const sessionId of [id, failedId])
        await rm(join("/tmp", `openmuse-downloads-${sessionId}`), { recursive: true, force: true });
    }
  }
});

test("real worker API preserves fixture downloads and browser storage across process restart", {
  timeout: 90_000,
}, async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "openmuse-worker-fixtures-"));
  const token = randomBytes(32).toString("hex");
  let child: ChildProcess | undefined;
  let output = "";
  async function start(): Promise<WorkerAddress> {
    child = fork(fileURLToPath(new URL("./fixture-worker.ts", import.meta.url)), [], {
      execArgv: ["--experimental-strip-types"],
      stdio: ["ignore", "pipe", "pipe", "ipc"],
      env: {
        ...process.env,
        WORKER_TOKEN: token,
        WORKER_DATA_DIR: dataDir,
        WORKER_HOST: "127.0.0.1",
        WORKER_TEST_PORT: "0",
        WORKER_FIXTURE_PORT: "0",
      },
    });
    output = "";
    for (const stream of [child.stdout, child.stderr])
      stream?.on("data", (chunk) => {
        output = `${output}${chunk}`.slice(-6000);
      });
    const [address] = await Promise.race([
      once(child, "message", { signal: AbortSignal.timeout(15_000) }),
      once(child, "exit").then(() => {
        throw new Error(`Fixture worker exited before startup: ${output}`);
      }),
    ]);
    assert(address && typeof address.base === "string" && typeof address.fixtureBase === "string");
    return address;
  }
  async function stop() {
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    const exited = once(child, "exit");
    child.kill("SIGTERM");
    const deadline = setTimeout(() => child?.kill("SIGKILL"), 35_000);
    deadline.unref();
    const [code] = await exited;
    clearTimeout(deadline);
    assert.equal(code, 0, output);
  }
  try {
    await checkBrowserWorker(token, await start(), async () => {
      await stop();
      return start();
    });
  } finally {
    try {
      await stop();
    } finally {
      for (const id of await readdir(dataDir))
        await rm(join("/tmp", `openmuse-downloads-${id}`), { recursive: true, force: true });
      await rm(dataDir, { recursive: true, force: true });
    }
  }
});
