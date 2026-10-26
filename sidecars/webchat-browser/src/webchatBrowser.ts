import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import CDP from "chrome-remote-interface";
import { startEgressProxy } from "./proxy.ts";
import { validatePublicUrl } from "./network.ts";
import { WorkerError } from "./errors.ts";

export interface Session {
  id: string;
  title: string;
  url: string;
  status: "active" | "closed" | "error";
  updatedAt: string;
}

type Running = {
  child: ChildProcessByStdio<null, null, Readable>;
  client: any;
  touched: number;
};

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const VIEWPORT = { width: 1280, height: 800 };
const MAX_TEXT = 100_000;

export function validateSessionId(id: unknown): string {
  if (typeof id !== "string" || !SESSION_ID.test(id))
    throw new WorkerError("INVALID_SESSION", "A valid UUID session ID is required.", 400);
  return id.toLowerCase();
}

function nowIso() {
  return new Date().toISOString();
}

function chromiumPath() {
  return process.env.CHROMIUM_PATH ?? "/usr/bin/chromium";
}

function extractorPath() {
  return join(fileURLToPath(new URL(".", import.meta.url)), "..", "vendor", "page-markdown.js");
}

async function readExtractor() {
  try {
    return await readFile(extractorPath(), "utf8");
  } catch {
    throw new WorkerError("BROWSER_UNAVAILABLE", "The WebChat page extractor is missing.", 503);
  }
}

// `remote-debugging-port=0` exposes the browser endpoint on stderr. Page
// domains (navigation, input, screenshots, extraction) require a page target.
async function connectToPage(webSocketUrl: string) {
  const port = Number(new URL(webSocketUrl).port);
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const targets = await CDP.List({ port });
    const page = targets.find((target) => target.type === "page" && target.webSocketDebuggerUrl);
    if (page) return CDP({ target: page.webSocketDebuggerUrl! });
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new WorkerError("BROWSER_UNAVAILABLE", "Chromium could not start.", 503);
}

export async function createWebChatBrowserManager(options: {
  dataDir: string;
  maxSessions?: number;
  idleTimeoutMs?: number;
}) {
  const { dataDir, maxSessions = 3, idleTimeoutMs = 30 * 60_000 } = options;
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  const sessions = new Map<string, Session>();
  const running = new Map<string, Running>();
  const queues = new Map<string, Promise<unknown>>();
  const proxy = await startEgressProxy();
  const extractor = await readExtractor();

  for (const entry of await readdir(dataDir)) {
    if (!SESSION_ID.test(entry)) continue;
    try {
      const stored = JSON.parse(await readFile(join(dataDir, entry, "session.json"), "utf8")) as Session;
      sessions.set(entry, { ...stored, id: entry, status: "closed" });
    } catch {
      /* a failed first launch has no metadata to restore */
    }
  }

  const directory = (id: string) => join(dataDir, validateSessionId(id));

  async function persist(session: Session) {
    const path = join(directory(session.id), "session.json");
    await writeFile(`${path}.tmp`, JSON.stringify(session), { mode: 0o600 });
    await rename(`${path}.tmp`, path);
  }

  async function serial<T>(id: string, fn: () => Promise<T>): Promise<T> {
    const previous = queues.get(id) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(fn);
    queues.set(id, next);
    try {
      return await next;
    } finally {
      if (queues.get(id) === next) queues.delete(id);
    }
  }

  function active(id: string): Running {
    const value = running.get(id);
    if (!value) throw new WorkerError("SESSION_CLOSED", "Open this browser session before using its console.", 409);
    value.touched = Date.now();
    return value;
  }

  async function currentUrl(client: any) {
    const result = await client.send("Runtime.evaluate", {
      expression: "JSON.stringify({url: location.href, title: document.title.slice(0, 300)})",
      returnByValue: true,
    });
    if (result.exceptionDetails) throw new WorkerError("WORKER_FAILURE", "The browser operation failed.", 500);
    const value = JSON.parse(result.result.value ?? "{}");
    return { url: String(value.url ?? "about:blank"), title: String(value.title ?? "") };
  }

  async function refresh(id: string): Promise<Session> {
    const instance = active(id);
    const page = await currentUrl(instance.client);
    if (page.url !== "about:blank") await validatePublicUrl(page.url);
    const session: Session = {
      id,
      title: page.title,
      url: page.url,
      status: "active",
      updatedAt: nowIso(),
    };
    sessions.set(id, session);
    await persist(session);
    return session;
  }

  async function stopInstance(instance: Running | undefined) {
    if (!instance) return;
    if (instance.child.exitCode === null && !instance.child.killed) {
      // The page-level CDP connection cannot reliably issue Browser.close.
      // SIGTERM is Chromium's graceful shutdown path and also covers crashes.
      instance.child.kill("SIGTERM");
      setTimeout(() => instance.child.kill("SIGKILL"), 2_000).unref();
    }
    await Promise.race([
      new Promise<void>((resolve) => instance.child.once("exit", () => resolve())),
      new Promise<void>((resolve) => setTimeout(resolve, 3_000).unref()),
    ]);
    instance.client.close?.();
  }

  async function launch(id: string) {
    const profile = join(directory(id), "profile");
    await mkdir(profile, { recursive: true, mode: 0o700 });
    const child = spawn(chromiumPath(), [
      "--headless=new",
      "--remote-debugging-port=0",
      "--remote-allow-origins=*",
      `--user-data-dir=${profile}`,
      `--proxy-server=${proxy.url}`,
      "--proxy-bypass-list=<-loopback>",
      "--window-size=1280,800",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-dev-shm-usage",
      "--disable-quic",
      "--disable-sync",
      "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
      "--no-default-browser-check",
      "--no-first-run",
      "--no-sandbox",
      "about:blank",
    ], {
      stdio: ["ignore", "ignore", "pipe"],
      env: {
        HOME: process.env.HOME ?? "/tmp",
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        LANG: "C.UTF-8",
      },
    });

    const endpoint = new Promise<string>((resolve, reject) => {
      let text = "";
      const timer = setTimeout(() => reject(new WorkerError("BROWSER_UNAVAILABLE", "Chromium could not start.", 503)), 15_000);
      child.stderr.on("data", (chunk: Buffer | string) => {
        text += chunk.toString();
        const match = /DevTools listening on (ws:\/\/\S+)/.exec(text);
        if (match) {
          clearTimeout(timer);
          resolve(match[1]);
        }
      });
      child.once("exit", () => {
        clearTimeout(timer);
        reject(new WorkerError("BROWSER_UNAVAILABLE", "Chromium could not start.", 503));
      });
      child.once("error", (error: unknown) => {
        clearTimeout(timer);
        reject(new WorkerError("BROWSER_UNAVAILABLE", "Chromium could not start.", 503, error));
      });
    });

    try {
      const webSocketUrl = await endpoint;
      const client = await connectToPage(webSocketUrl);
      await client.send("Page.enable");
      await client.send("Runtime.enable");
      await client.send("Emulation.setDeviceMetricsOverride", {
        ...VIEWPORT,
        deviceScaleFactor: 1,
        mobile: false,
      });
      const instance: Running = { child, client, touched: Date.now() };
      running.set(id, instance);
      child.once("exit", () => {
        if (running.get(id) === instance) running.delete(id);
        client.close?.();
      });
      return instance;
    } catch (error) {
      if (child.exitCode === null && !child.killed) child.kill("SIGKILL");
      if (error instanceof WorkerError) throw error;
      throw new WorkerError("BROWSER_UNAVAILABLE", "Chromium could not start.", 503, error);
    }
  }

  async function navigate(id: string, value: string): Promise<Session> {
    const instance = active(id);
    const target = await validatePublicUrl(value);
    let loaded: Promise<void> | undefined;
    try {
      loaded = new Promise((resolve) => {
        const handler = () => {
          instance.client.off("Page.domContentEventFired", handler);
          resolve();
        };
        instance.client.on("Page.domContentEventFired", handler);
      });
      const result = await instance.client.send("Page.navigate", { url: target.url.href });
      if (result.errorText) throw new Error(result.errorText);
      await Promise.race([loaded, new Promise((resolve) => setTimeout(resolve, 8_000).unref())]);
      const page = await currentUrl(instance.client);
      await validatePublicUrl(page.url);
    } catch (error) {
      if (error instanceof WorkerError) throw error;
      throw new WorkerError(
        "NAVIGATION_FAILED",
        "The page could not be loaded. It may be unreachable or contain a blocked destination.",
        502,
        error,
      );
    } finally {
      loaded = undefined;
    }
    return refresh(id);
  }

  async function closeSession(id: string): Promise<Session> {
    const stored = sessions.get(id);
    if (!stored) throw new WorkerError("SESSION_NOT_FOUND", "Browser session not found.", 404);
    await stopInstance(running.get(id));
    running.delete(id);
    const result: Session = { ...stored, status: "closed", updatedAt: nowIso() };
    sessions.set(id, result);
    await persist(result);
    return result;
  }

  async function createSession(id: string, url: string): Promise<Session> {
    await validatePublicUrl(url);
    if (running.has(id)) return navigate(id, url);
    if (running.size >= maxSessions)
      throw new WorkerError("SESSION_LIMIT", `Close an active session before opening another (limit ${maxSessions}).`, 409);
    if (!sessions.has(id) && sessions.size >= 20)
      throw new WorkerError("PROFILE_LIMIT", "The worker has reached its 20 saved-profile limit.", 409);
    const previous = sessions.get(id);
    try {
      await launch(id);
      const initial: Session = {
        id,
        title: previous?.title ?? "New session",
        url,
        status: "active",
        updatedAt: nowIso(),
      };
      sessions.set(id, initial);
      await persist(initial);
      return await navigate(id, url);
    } catch (error) {
      await stopInstance(running.get(id));
      running.delete(id);
      if (previous) {
        const failed: Session = { ...previous, url, status: "error", updatedAt: nowIso() };
        sessions.set(id, failed);
        await persist(failed);
      } else {
        sessions.delete(id);
        await rm(directory(id), { recursive: true, force: true });
      }
      throw error;
    }
  }

  const sweeper = setInterval(() => {
    for (const [id, instance] of running) {
      if (Date.now() - instance.touched > idleTimeoutMs) {
        void serial(id, () => closeSession(id)).catch(() => {});
      }
    }
  }, 60_000);
  sweeper.unref();

  return {
    list: () => [...sessions.values()],
    create: (id: string, url: string) => serial("create", () => serial(id, () => createSession(id, url))),
    navigate: (id: string, url: string) => serial(id, () => navigate(id, url)),
    closeSession: (id: string) => serial(id, () => closeSession(id)),
    screenshot: async (id: string) => {
      const instance = active(id);
      const result = await instance.client.send("Page.captureScreenshot", { format: "png", optimizeForSpeed: true });
      return Buffer.from(result.data, "base64");
    },
    read: (id: string) =>
      serial(id, async () => {
        const instance = active(id);
        const page0 = await currentUrl(instance.client);
        if (page0.url !== "about:blank") await validatePublicUrl(page0.url);
        // Load the WebChat extractor into the page's main world. No caller
        // supplied script can enter this evaluation path.
        const injected = await instance.client.send("Runtime.evaluate", {
          expression: extractor,
          returnByValue: false,
        });
        if (injected.exceptionDetails)
          throw new WorkerError("WORKER_FAILURE", "The WebChat extractor failed.", 500, injected.exceptionDetails);
        const result = await instance.client.send("Runtime.evaluate", {
          expression: "window.__webchatMarkdown.extract({ maxChars: 100000 })",
          returnByValue: true,
        });
        if (result.exceptionDetails)
          throw new WorkerError("WORKER_FAILURE", "The WebChat extractor failed.", 500, result.exceptionDetails);
        const value = result.result.value ?? {};
        const url = String(value.url ?? page0.url);
        const title = String(value.title ?? page0.title).slice(0, 300);
        await validatePublicUrl(url);
        const text = String(value.markdown ?? "");
        const truncated = value.truncated === true || text.length > MAX_TEXT;
        const trimmed = truncated ? text.slice(0, MAX_TEXT) : text;
        const session = await refresh(id);
        return { id, url, title, text: trimmed, truncated };
      }),
    input: (id: string, input: Record<string, unknown>) =>
      serial(id, async () => {
        const instance = active(id);
        const client = instance.client;
        const { type, x, y, key, text, deltaY } = input;
        if (
          type === "click" &&
          typeof x === "number" && Number.isFinite(x) && x >= 0 && x < VIEWPORT.width &&
          typeof y === "number" && Number.isFinite(y) && y >= 0 && y < VIEWPORT.height
        ) {
          await client.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
          await client.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
          // Chromium's synthetic mouse events do not always activate a link in
          // headless mode. Activate the actual hit-test target as well; this is
          // fixed input dispatch and never evaluates caller-supplied code.
          await client.send("Runtime.evaluate", {
            expression: `(document.elementFromPoint(${x}, ${y}) ?? {click() {}}).click()`,
            returnByValue: true,
          });
        } else if (type === "text" && typeof text === "string" && text.length <= 10_000) {
          await client.send("Input.insertText", { text });
        } else if (type === "key" && typeof key === "string" && key.length <= 20) {
          const map: Record<string, [string, string, number]> = {
            Enter: ["Enter", "\r", 0], Tab: ["Tab", "\t", 0], Escape: ["Escape", "\u001b", 0],
            Backspace: ["Backspace", "\b", 0], Delete: ["Delete", "\u007f", 0],
            ArrowUp: ["ArrowUp", "", 0], ArrowDown: ["ArrowDown", "", 0],
            ArrowLeft: ["ArrowLeft", "", 0], ArrowRight: ["ArrowRight", "", 0],
            Home: ["Home", "", 0], End: ["End", "", 0], PageUp: ["PageUp", "", 0], PageDown: ["PageDown", "", 0],
          };
          const special = map[key];
          if (special) {
            const [code, textValue] = special;
            await client.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code, windowsVirtualKeyCode: 0 });
            if (textValue) await client.send("Input.dispatchKeyEvent", { type: "keyDown", key, code, text: textValue });
            await client.send("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode: 0 });
          } else if (key === "Control+a" || key === "Meta+a" || key === "Shift+Tab") {
            const [modifierName] = key.split("+");
            const code = modifierName === "Shift" ? "Shift" : modifierName === "Meta" ? "MetaLeft" : "ControlLeft";
            const modifiers = modifierName === "Shift" ? 8 : modifierName === "Meta" ? 4 : 2;
            await client.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: code, code, modifiers, windowsVirtualKeyCode: 0 });
            await client.send("Input.dispatchKeyEvent", {
              type: "keyDown", key: "a", code: "KeyA", text: "a", modifiers, windowsVirtualKeyCode: 65,
            });
            await client.send("Input.dispatchKeyEvent", { type: "keyUp", key: "a", code: "KeyA", modifiers, windowsVirtualKeyCode: 65 });
            await client.send("Input.dispatchKeyEvent", { type: "keyUp", key: code, code, modifiers, windowsVirtualKeyCode: 0 });
          } else if (key.length === 1) {
            await client.send("Input.dispatchKeyEvent", { type: "keyDown", key, text: key, windowsVirtualKeyCode: key.toUpperCase().charCodeAt(0) });
            await client.send("Input.dispatchKeyEvent", { type: "keyUp", key, windowsVirtualKeyCode: key.toUpperCase().charCodeAt(0) });
          } else {
            throw new WorkerError("INVALID_INPUT", "Unsupported browser key.", 400);
          }
        } else if (
          type === "scroll" && typeof deltaY === "number" && Number.isFinite(deltaY) && Math.abs(deltaY) <= 5000
        ) {
          await client.send("Input.dispatchMouseEvent", { type: "mouseWheel", x: 640, y: 400, deltaX: 0, deltaY });
        } else {
          throw new WorkerError("INVALID_INPUT", "Unsupported browser input or coordinates.", 400);
        }
        return refresh(id);
      }),
    downloads: async () => ({ downloads: [], failures: [] }),
    close: async () => {
      clearInterval(sweeper);
      await Promise.allSettled([...running.values()].map(stopInstance));
      await proxy.close();
    },
  };
}
