import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";
import { checkBrowserWorker } from "./worker-checks.ts";

// Require the disposable fixture worker; never use saved sessions or log its token.
const base = process.env.WORKER_TEST_URL;
const fixtureBase = process.env.WORKER_FIXTURE_URL;
const token = process.env.WORKER_TOKEN;
const container = process.env.WORKER_TEST_CONTAINER;
if (!base || !fixtureBase || !token || !container)
  throw new Error("Run tests/run-docker.mjs to start a disposable fixture worker.");
const docker = (args: string[]) =>
  execFileSync("docker", args, { encoding: "utf8", stdio: "pipe", timeout: 45_000 });

test("Docker Chromium reads controlled pages, downloads and restores its saved profile", {
  timeout: 120_000,
}, async () => {
  await checkBrowserWorker(token, { base, fixtureBase }, async () => {
    docker(["restart", container]);
    const address = {
      base: `http://${docker(["port", container, "8790"]).trim()}`,
      fixtureBase: `http://${docker(["port", container, "8791"]).trim()}`,
    };
    let healthy = false;
    for (let attempt = 0; attempt < 30; attempt++) {
      if (
        await fetch(`${address.base}/health`)
          .then((response) => response.ok)
          .catch(() => false)
      ) {
        healthy = true;
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    assert(healthy, "restarted worker must become healthy");
    return address;
  });
});
