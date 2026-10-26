import { createWorkerServer } from "./server.ts";

const token = process.env.WORKER_TOKEN ?? "";
const worker = await createWorkerServer({
  token,
  dataDir: process.env.WORKER_DATA_DIR ?? ".openmuse/browser-profiles",
  maxSessions: 3,
  idleTimeoutMs: 30 * 60_000,
});
// WORKER_PORT is a BeamAI Muse addition (OpenMuse always uses 8790), so a
// second worker (scripts/acceptance.sh) can run beside a deployed one.
const port = Number(process.env.WORKER_PORT ?? "8790");
worker.server.listen(port, process.env.WORKER_HOST ?? "127.0.0.1", () => {
  console.log(`OpenMuse browser worker listening on port ${port}`);
});
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  const deadline = setTimeout(() => process.exit(1), 30_000);
  deadline.unref();
  await worker.close();
  process.exit(0);
}
process.on("SIGTERM", () => {
  void stop();
});
process.on("SIGINT", () => {
  void stop();
});
