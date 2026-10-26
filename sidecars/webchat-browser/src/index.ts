import { createWorkerServer } from "./server.ts";

const worker = await createWorkerServer({
  token: process.env.WORKER_TOKEN ?? "",
  dataDir: process.env.WORKER_DATA_DIR ?? "/data",
  maxSessions: Number(process.env.WORKER_MAX_SESSIONS ?? "3"),
  idleTimeoutMs: Number(process.env.WORKER_IDLE_MINUTES ?? "30") * 60_000,
});
const port = Number(process.env.WORKER_PORT ?? "8790");
worker.server.listen(port, process.env.WORKER_HOST ?? "127.0.0.1", () => {
  console.log(`WebChat browser worker listening on port ${port}`);
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
process.on("SIGTERM", () => void stop());
process.on("SIGINT", () => void stop());
