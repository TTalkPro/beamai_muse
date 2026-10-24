import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const name = `openmuse-worker-test-${randomUUID().slice(0, 8)}`;
const env = { ...process.env, WORKER_TOKEN: randomBytes(32).toString("hex") };
const run = (args, options = {}) =>
  execFileSync("docker", args, { env, stdio: "inherit", ...options });
run(["build", "-t", "openmuse-browser-worker:test", root]);
try {
  run([
    "run",
    "--detach",
    "--name",
    name,
    "--init",
    "--read-only",
    "--cap-drop=ALL",
    "--security-opt",
    "no-new-privileges:true",
    "--memory=2g",
    "--pids-limit=256",
    "--tmpfs",
    "/tmp:size=256m,mode=1777",
    "--shm-size=256m",
    "--volume",
    "/data",
    "--publish",
    "127.0.0.1::8790",
    "--publish",
    "127.0.0.1::8791",
    "--mount",
    `type=bind,source=${root}tests,target=/app/tests,readonly`,
    "--env",
    "WORKER_TOKEN",
    "openmuse-browser-worker:test",
    "node",
    "--experimental-strip-types",
    "tests/fixture-worker.ts",
  ]);
  const binding = run(["port", name, "8790"], { encoding: "utf8", stdio: "pipe" }).trim();
  const url = `http://${binding}`;
  const fixtureBinding = run(["port", name, "8791"], { encoding: "utf8", stdio: "pipe" }).trim();
  const fixtureUrl = `http://${fixtureBinding}`;
  let healthy = false;
  for (let attempt = 0; attempt < 30; attempt++) {
    if (
      await fetch(`${url}/health`)
        .then((r) => r.ok)
        .catch(() => false)
    ) {
      healthy = true;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  if (!healthy) throw new Error("Test worker did not become healthy");
  execFileSync(process.execPath, ["--experimental-strip-types", "--test", "tests/docker.test.ts"], {
    cwd: root,
    stdio: "inherit",
    env: {
      ...env,
      WORKER_TEST_URL: url,
      WORKER_FIXTURE_URL: fixtureUrl,
      WORKER_TEST_CONTAINER: name,
    },
  });
} catch (error) {
  run(["logs", name]);
  throw error;
} finally {
  run(["rm", "--force", "--volumes", name]);
}
