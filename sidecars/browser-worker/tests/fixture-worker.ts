import { once } from "node:events";
import { createBrowserManager } from "../src/browser.ts";
import { createWorkerServer } from "../src/server.ts";
import { createBrowserFixture } from "./fixtures.ts";

// This entrypoint is mounted read-only by run-docker, never included in the image.
const host = process.env.WORKER_HOST ?? "127.0.0.1";
const fixture = await createBrowserFixture({
  host,
  port: Number(process.env.WORKER_FIXTURE_PORT ?? 8791),
});
const worker = await createWorkerServer(
  {
    token: process.env.WORKER_TOKEN ?? "",
    dataDir: process.env.WORKER_DATA_DIR ?? ".openmuse/browser-profiles",
  },
  (options) => createBrowserManager(options, fixture.createProxy),
);
worker.server.listen(Number(process.env.WORKER_TEST_PORT ?? 8790), host);
await once(worker.server, "listening");
const address = worker.server.address();
if (!address || typeof address === "string") throw new Error("Test worker unavailable");
process.send?.({ base: `http://127.0.0.1:${address.port}`, fixtureBase: fixture.url });

let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  const deadline = setTimeout(() => process.exit(1), 30_000);
  deadline.unref();
  try {
    await worker.close();
  } finally {
    await fixture.close();
  }
  process.exit(0);
}
for (const signal of ["SIGTERM", "SIGINT"] as const)
  process.on(signal, () => {
    void stop();
  });
