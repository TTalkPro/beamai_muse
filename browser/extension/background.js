// beamai_muse browser bridge (Firefox, MV2 persistent background page).
//
// Talks only to its native messaging host (dev.openmuse.browser), which
// relays to browserd in the container; pages cannot reach it (no
// externally_connectable, no web_accessible_resources, no content scripts
// declared). Never uses a remote protocol (Marionette, WebDriver BiDi, CDP).
//
// One browser session = one browser window holding one tab. The session ->
// window/tab map lives in storage.session (survives a background reload,
// not a browser restart: after one, every session answers SESSION_CLOSED and
// the server re-opens it at its last URL).
//
// The WebExtension APIs are used through `B`: Firefox's promise-based
// `browser` namespace (the same API surface as Chrome's `chrome`).
'use strict';

var B = globalThis.browser || globalThis.chrome;

const HOST = 'dev.openmuse.browser';
const VIEW_W = 1280, VIEW_H = 800;
const MAX_DOWNLOAD = 10 * 1024 * 1024;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const withTimeout = (p, ms, what) => Promise.race([
  p, new Promise((_, rej) => setTimeout(() => rej(fail('TIMEOUT', `timeout after ${ms} ms: ${what}`)), ms)),
]);
function fail(code, message) { const e = new Error(message); e.code = code; return e; }

// ------------------------------------------------------------ state

const sessions = new Map(); // sid -> {windowId, tabId, layout, pending: {url, at}, downloadAt}
const downloadSession = new Map(); // download id -> sid
const cancelReason = new Map(); // download id -> too_large | limit
let lastActive = null;
let loading = null;

function load() {
  if (!loading) {
    loading = B.storage.session.get(['sessions', 'downloads', 'lastActive']).then(s => {
      for (const [k, v] of Object.entries(s.sessions || {})) sessions.set(k, v);
      for (const [k, v] of Object.entries(s.downloads || {})) downloadSession.set(Number(k), v);
      lastActive = s.lastActive || null;
    });
  }
  return loading;
}

function persist() {
  return B.storage.session.set({
    sessions: Object.fromEntries([...sessions].map(([k, v]) => [k, { windowId: v.windowId, tabId: v.tabId }])),
    downloads: Object.fromEntries(downloadSession),
    lastActive,
  });
}

async function live(sid) {
  await load();
  const s = sessions.get(sid);
  if (!s) throw fail('SESSION_CLOSED', 'session not open');
  try {
    const tab = await B.tabs.get(s.tabId);
    s.windowId = tab.windowId;
    return { s, tab };
  } catch (e) {
    sessions.delete(sid);
    await persist();
    throw fail('SESSION_CLOSED', 'session not open');
  }
}

// ------------------------------------------------------------ native port

let port = null;
function post(message) {
  try { if (port) port.postMessage(message); } catch (e) { /* reconnects */ }
}

function connect() {
  if (port) return;
  try {
    port = B.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    setTimeout(connect, 1000);
    return;
  }
  port.onMessage.addListener(m => { if (m && m.type === 'command') run(m); });
  port.onDisconnect.addListener(() => { port = null; setTimeout(connect, 1000); });
  post({ type: 'hello', version: B.runtime.getManifest().version, ua: navigator.userAgent });
}

async function run(m) {
  let reply;
  try {
    await load();
    const fn = OPS[m.op];
    if (!fn) throw fail('UNKNOWN_OP', 'unknown op ' + m.op);
    reply = { type: 'result', id: m.id, ok: true, result: await withTimeout(fn(m), m.timeoutMs || 45000, m.op) };
  } catch (e) {
    reply = { type: 'result', id: m.id, ok: false, code: (e && e.code) || 'EXTENSION_ERROR', error: String((e && e.message) || e) };
  }
  post(reply);
}

// ------------------------------------------------------------ windows

// `viewport` layout (the browser image): size the window so its page area
// is exactly width x height. `screen` layout (the browser inside a desktop
// computer): the window fills the screen, the page area is what is left.
async function fitViewport(windowId, tabId, layout) {
  const mode = (layout && layout.mode) || 'viewport';
  const W = (layout && layout.width) || VIEW_W, H = (layout && layout.height) || VIEW_H;
  for (let i = 0; i < 8; i++) {
    const [w, t] = await Promise.all([B.windows.get(windowId), B.tabs.get(tabId)]);
    if (!t.width || !t.height) { await sleep(100); continue; }
    if (mode === 'screen') {
      if (w.width === W && w.height === H && w.left === 0 && w.top === 0) return;
      await B.windows.update(windowId, { left: 0, top: 0, width: W, height: H });
    } else {
      if (t.width === W && t.height === H && w.left === 0 && w.top === 0) return;
      await B.windows.update(windowId, {
        left: 0, top: 0, width: w.width + W - t.width, height: w.height + H - t.height,
      });
    }
    await sleep(150);
  }
}

// Wait for the main frame's navigation that starts after `start()`.
// An aborted load: Chrome's net::ERR_ABORTED, Firefox's NS_BINDING_ABORTED
// (0x804B0002, reported as "Error code 2152398850").
const aborted = e => e === 'net::ERR_ABORTED' || /2152398850|NS_BINDING_ABORTED/.test(String(e || ''));

function navigation(tabId, sid, waitMs, start) {
  return new Promise(resolve => {
    let begun = false, done = false;
    const finish = r => {
      if (done) return;
      done = true;
      B.webNavigation.onBeforeNavigate.removeListener(onBefore);
      B.webNavigation.onDOMContentLoaded.removeListener(onLoaded);
      B.webNavigation.onReferenceFragmentUpdated.removeListener(onLoaded);
      B.webNavigation.onErrorOccurred.removeListener(onError);
      clearTimeout(timer);
      resolve(r);
    };
    const mine = d => d.tabId === tabId && d.frameId === 0;
    const onBefore = d => { if (mine(d)) begun = true; };
    const onLoaded = d => { if (mine(d) && begun) finish({ ok: true }); };
    const onError = async d => {
      if (!mine(d) || !begun) return;
      if (aborted(d.error)) {
        // a navigation that became a download
        for (let i = 0; i < 10; i++) {
          const s = sessions.get(sid);
          if (s && s.downloadAt && s.downloadAt >= startedAt) return finish({ ok: true, download: true });
          await sleep(100);
        }
        // Firefox also reports the previous page's pending load as aborted
        // on the main frame once the new navigation has begun: not ours,
        // keep waiting for the new page (or the timeout)
        return;
      }
      finish({ error: d.error });
    };
    const startedAt = Date.now();
    B.webNavigation.onBeforeNavigate.addListener(onBefore);
    B.webNavigation.onDOMContentLoaded.addListener(onLoaded);
    B.webNavigation.onReferenceFragmentUpdated.addListener(onLoaded);
    B.webNavigation.onErrorOccurred.addListener(onError);
    const timer = setTimeout(() => {
      const s = sessions.get(sid);
      finish(s && s.downloadAt && s.downloadAt >= startedAt ? { ok: true, download: true } : { error: 'timeout' });
    }, waitMs);
    start().catch(e => finish({ error: String(e && e.message || e) }));
  });
}

// "The page is shown": the tab finished loading (status complete, the load
// event fired) and its network has been quiet for quietMs (no request
// started or finished; a request open for over 5 s, a long poll or a
// stream, does not count). Judged from outside the page, through the tabs
// API and B.webRequest (observing only): nothing is injected while the
// page loads, and page-markdown.js is injected only once this holds (or
// maxMs passed).
const net = new Map(); // tabId -> {open: Map(requestId -> start ms), last: ms}
function netOf(tabId) {
  let n = net.get(tabId);
  if (!n) net.set(tabId, n = { open: new Map(), last: 0 });
  return n;
}
const ALL = { urls: ['<all_urls>'] };
B.webRequest.onBeforeRequest.addListener(d => {
  if (d.tabId < 0) return;
  const n = netOf(d.tabId);
  if (d.type === 'main_frame') n.open.clear();
  n.open.set(d.requestId, Date.now()); n.last = Date.now();
}, ALL);
const netDone = d => {
  if (d.tabId < 0) return;
  const n = netOf(d.tabId);
  n.open.delete(d.requestId); n.last = Date.now();
};
B.webRequest.onCompleted.addListener(netDone, ALL);
B.webRequest.onErrorOccurred.addListener(netDone, ALL);
B.tabs.onRemoved.addListener(tabId => { net.delete(tabId); pdfTabs.delete(tabId); });

async function displayed(tabId, quietMs, maxMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < maxMs) {
    const t = await B.tabs.get(tabId);
    if (t.status === 'complete') {
      const now = Date.now(), n = netOf(tabId);
      const busy = [...n.open.values()].some(start => now - start < 5000);
      if (!busy && now - n.last >= quietMs) return true;
    }
    await sleep(100);
  }
  return false;
}

// The main-frame responses that are PDFs, by tab (their Content-Type header;
// nothing is injected to find out).
const pdfTabs = new Map(); // tabId -> url
B.webRequest.onHeadersReceived.addListener(d => {
  if (d.tabId < 0) return;
  const type = (d.responseHeaders || []).find(h => h.name.toLowerCase() === 'content-type');
  if (type && /^\s*application\/pdf/i.test(type.value || '')) pdfTabs.set(d.tabId, d.url);
  else pdfTabs.delete(d.tabId);
}, { urls: ['<all_urls>'], types: ['main_frame'] }, ['responseHeaders']);

// A PDF the session shows (Chrome's viewer) is also downloaded once, so it
// can be imported into Files: the PDF viewer stays enabled (disabling it
// with AlwaysOpenPdfExternally would empty navigator.plugins, a bot tell).
const pdfSeen = new Map(); // sid + url -> time
async function downloadIfPdf(sid, tabId) {
  const url = pdfTabs.get(tabId);
  if (!url || !/^https?:/.test(url)) return false;
  const key = sid + ' ' + url;
  if (Date.now() - (pdfSeen.get(key) || 0) < 60000) return true;
  pdfSeen.set(key, Date.now());
  const s = sessions.get(sid);
  if (s) s.pending = { url, at: Date.now() };
  try { await B.downloads.download({ url, conflictAction: 'uniquify' }); } catch (e) { return false; }
  return true;
}

B.webNavigation.onDOMContentLoaded.addListener(async d => {
  if (d.frameId !== 0) return;
  await load();
  for (const [sid, s] of sessions) if (s.tabId === d.tabId) downloadIfPdf(sid, d.tabId);
});

let lastCapture = 0;
let captureChain = Promise.resolve();

// ------------------------------------------------------------ operations

const OPS = {
  async list() {
    return { sessions: [...sessions.keys()] };
  },

  async ensure({ session, layout }) {
    const s = sessions.get(session);
    if (s) {
      try {
        const tab = await B.tabs.get(s.tabId);
        return { windowId: tab.windowId, tabId: tab.id, created: false };
      } catch (e) { sessions.delete(session); }
    }
    const screen = layout && layout.mode === 'screen';
    const w = await B.windows.create({
      url: 'about:blank', left: 0, top: 0, focused: true, type: 'normal',
      width: screen ? layout.width : VIEW_W, height: screen ? layout.height : VIEW_H + 90,
    });
    const tabId = w.tabs[0].id;
    sessions.set(session, { windowId: w.id, tabId, layout: layout || null });
    lastActive = session;
    await persist();
    await fitViewport(w.id, tabId, layout);
    return { windowId: w.id, tabId, created: true };
  },

  async navigate({ session, url, waitMs = 25000 }) {
    const { s, tab } = await live(session);
    s.pending = { url, at: Date.now() };
    lastActive = session;
    persist();
    const r = await navigation(tab.id, session, waitMs, () => B.tabs.update(tab.id, { url }));
    if (r.ok && !r.download && await downloadIfPdf(session, tab.id)) {
      for (let i = 0; i < 30 && !(s.downloadAt && s.downloadAt >= s.pending.at); i++) await sleep(100);
      r.download = true;
    }
    if (r.ok && !r.download) { try { await displayed(tab.id, 800, 10000); } catch (e) { /* page moved on */ } }
    const t = await B.tabs.get(tab.id);
    return { url: t.url || t.pendingUrl || 'about:blank', title: t.title || '', error: r.error || null, download: !!r.download };
  },

  async blank({ session }) {
    const { tab } = await live(session);
    await B.tabs.update(tab.id, { url: 'about:blank' });
    return true;
  },

  async info({ session }) {
    const { tab } = await live(session);
    return { url: tab.url || tab.pendingUrl || 'about:blank', title: tab.title || '' };
  },

  async read({ session, maxChars = 100000 }) {
    const { tab } = await live(session);
    lastActive = session;
    if (!/^https?:/.test(tab.url || '')) return { url: tab.url || 'about:blank', title: tab.title || '', markdown: '', truncated: false };
    // the extractor goes in only once the page is shown (see displayed)
    try { await displayed(tab.id, 800, 10000); } catch (e) { /* tab gone: the injection reports it */ }
    await B.scripting.executeScript({ target: { tabId: tab.id }, files: ['page-markdown.js'] });
    const [r] = await B.scripting.executeScript({
      target: { tabId: tab.id },
      args: [maxChars],
      func: maxChars => {
        const out = window.__webchatMarkdown.extract({ maxChars });
        return { url: location.href, title: document.title, markdown: out.markdown, truncated: !!out.truncated };
      },
    });
    return r.result;
  },

  async capture({ session }) {
    const { tab } = await live(session);
    const shoot = async () => {
      // captureVisibleTab allows two calls per second
      const wait = lastCapture + 550 - Date.now();
      if (wait > 0) await sleep(wait);
      lastCapture = Date.now();
      return B.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
    };
    const p = captureChain.then(shoot, shoot);
    captureChain = p.catch(() => {});
    const dataUrl = await p;
    return { data: dataUrl.slice(dataUrl.indexOf(',') + 1) };
  },

  async geometry({ session }) {
    const { s, tab } = await live(session);
    let w = await B.windows.get(tab.windowId);
    if (w.state !== 'normal') {
      await B.windows.update(w.id, { state: 'normal' });
      await fitViewport(w.id, tab.id, s.layout);
      w = await B.windows.get(tab.windowId);
    }
    const t = await B.tabs.get(tab.id);
    lastActive = session;
    return {
      windowId: w.id,
      window: { left: w.left, top: w.top, width: w.width, height: w.height },
      tab: { width: t.width, height: t.height },
    };
  },

  // Whether the page (not the address bar) has the keyboard focus.
  async hasfocus({ session }) {
    const { tab } = await live(session);
    const [r] = await B.scripting.executeScript({ target: { tabId: tab.id }, func: () => document.hasFocus() });
    return !!r.result;
  },

  async focus({ session }) {
    const { tab } = await live(session);
    await B.windows.update(tab.windowId, { focused: true });
    return true;
  },

  async close({ session }) {
    await load();
    const s = sessions.get(session);
    if (!s) return { closed: false };
    sessions.delete(session);
    await persist();
    const all = await B.windows.getAll();
    if (all.length <= 1) await B.windows.create({ url: 'about:blank', focused: false });
    try { await B.windows.remove(s.windowId); } catch (e) { /* already gone */ }
    return { closed: true };
  },

  // Diagnostics for the real-browser test suite.
  async diag({ session, what, url }) {
    const { tab } = await live(session);
    const target = { tabId: tab.id };
    if (what === 'probe') {
      const [r] = await B.scripting.executeScript({ target, world: 'MAIN', func: probe });
      return r.result;
    }
    if (what === 'fetch') {
      const [r] = await B.scripting.executeScript({
        target, world: 'MAIN', args: [url],
        func: url => Promise.race([
          fetch(url, { mode: 'no-cors', cache: 'no-store' }).then(r => ({ ok: true, type: r.type, status: r.status }),
            e => ({ ok: false, error: String(e) })),
          new Promise(r => setTimeout(() => r({ ok: false, error: 'timeout' }), 15000)),
        ]),
      });
      return r.result;
    }
    if (what === 'assign') {
      const r = await navigation(tab.id, session, 20000, () => B.scripting.executeScript({
        target, world: 'MAIN', args: [url], func: url => { location.href = url; },
      }));
      const t = await B.tabs.get(tab.id);
      return { url: t.url, title: t.title, error: r.error || null };
    }
    if (what === 'active') {
      const [r] = await B.scripting.executeScript({
        target, func: () => {
          const e = document.activeElement;
          return { tag: e ? e.tagName.toLowerCase() : null, value: e && 'value' in e ? e.value : null, focus: document.hasFocus() };
        },
      });
      return r.result;
    }
    if (what === 'clicks') {
      const [r] = await B.scripting.executeScript({
        target, func: () => {
          if (!window.__museClicks) {
            window.__museClicks = [];
            addEventListener('mousedown', e => window.__museClicks.push({ x: e.clientX, y: e.clientY, sx: e.screenX, sy: e.screenY, trusted: e.isTrusted }), true);
          }
          return window.__museClicks;
        },
      });
      return r.result;
    }
    if (what === 'rect') {
      const [r] = await B.scripting.executeScript({
        target, args: [url], func: selector => {
          const e = document.querySelector(selector);
          if (!e) return null;
          e.scrollIntoView({ block: 'center' });
          const b = e.getBoundingClientRect();
          return { x: b.x, y: b.y, w: b.width, h: b.height };
        },
      });
      return r.result;
    }
    if (what === 'geometry') return OPS.geometry({ session });
    throw fail('UNKNOWN_DIAG', what);
  },
};

// Fingerprint probe (browser spike probe.js, trimmed): runs in the page's
// MAIN world, only reads.
async function probe() {
  const n = navigator;
  const o = {
    webdriver: n.webdriver, ua: n.userAgent, languages: (n.languages || []).join(','),
    plugins: n.plugins.length, platform: n.platform, hasFocus: document.hasFocus(),
    visibility: document.visibilityState, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    screen: [screen.width, screen.height].join('x'), inner: [innerWidth, innerHeight].join('x'),
    windowChrome: typeof window.chrome,
  };
  try {
    const gl = document.createElement('canvas').getContext('webgl');
    const d = gl.getExtension('WEBGL_debug_renderer_info');
    o.webglRenderer = gl.getParameter(d.UNMASKED_RENDERER_WEBGL);
  } catch (e) { o.webglRenderer = 'error'; }
  let cdp = false;
  const err = new Error('probe');
  Object.defineProperty(err, 'stack', { configurable: true, get() { cdp = true; return ''; } });
  console.debug(err);
  await new Promise(r => setTimeout(r, 50));
  o.cdpRuntimeTrace = cdp;
  return o;
}

// ------------------------------------------------------------ popups

// A new tab or popup of a session (target=_blank, window.open) is closed and
// its address opened in the session's own tab: a session stays one window
// with one tab, which is what the console shows and the person controls.
B.tabs.onCreated.addListener(async tab => {
  await load();
  const owner = [...sessions].find(([, s]) =>
    s.tabId !== tab.id && (s.windowId === tab.windowId || (tab.openerTabId && s.tabId === tab.openerTabId)));
  if (!owner) return;
  const [sid, s] = owner;
  let url = tab.pendingUrl || tab.url;
  for (let i = 0; i < 30 && (!url || url === 'about:blank'); i++) {
    await sleep(100);
    try { const t = await B.tabs.get(tab.id); url = t.pendingUrl || t.url; } catch (e) { return; }
  }
  try { await B.tabs.remove(tab.id); } catch (e) { /* gone */ }
  if (/^https?:/.test(url || '')) {
    s.pending = { url, at: Date.now() };
    lastActive = sid;
    B.tabs.update(s.tabId, { url, active: true }).catch(() => {});
  }
});

B.windows.onRemoved.addListener(async windowId => {
  await load();
  let changed = false;
  for (const [sid, s] of sessions) if (s.windowId === windowId) { sessions.delete(sid); changed = true; }
  if (changed) persist();
});

// ------------------------------------------------------------ downloads

async function attribute(item) {
  const urls = [item.url, item.finalUrl].filter(Boolean);
  let best = null;
  for (const [sid, s] of sessions) {
    if (s.pending && urls.includes(s.pending.url) && Date.now() - s.pending.at < 120000
        && (!best || s.pending.at > best.at)) best = { sid, at: s.pending.at };
  }
  if (best) return best.sid;
  if (item.referrer) {
    for (const [sid, s] of sessions) {
      try { if ((await B.tabs.get(s.tabId)).url === item.referrer) return sid; } catch (e) { /* closed */ }
    }
  }
  return lastActive && sessions.has(lastActive) ? lastActive : null;
}

let sizeWatch = null;
function watchSizes() {
  if (sizeWatch) return;
  sizeWatch = setInterval(async () => {
    const running = await B.downloads.search({ state: 'in_progress' });
    if (!running.length) { clearInterval(sizeWatch); sizeWatch = null; return; }
    for (const d of running) {
      if (d.bytesReceived > MAX_DOWNLOAD || d.totalBytes > MAX_DOWNLOAD) {
        cancelReason.set(d.id, 'too_large');
        B.downloads.cancel(d.id).catch(() => {});
      }
    }
  }, 300);
}

B.downloads.onCreated.addListener(async item => {
  await load();
  const sid = await attribute(item);
  downloadSession.set(item.id, sid);
  const s = sid && sessions.get(sid);
  if (s) s.downloadAt = Date.now();
  persist();
  if ((item.totalBytes || 0) > MAX_DOWNLOAD || (item.fileSize || 0) > MAX_DOWNLOAD) {
    cancelReason.set(item.id, 'too_large');
    B.downloads.cancel(item.id).catch(() => {});
  }
  watchSizes();
});

B.downloads.onChanged.addListener(async delta => {
  if (!delta.state || !['complete', 'interrupted'].includes(delta.state.current)) return;
  await load();
  const [item] = await B.downloads.search({ id: delta.id });
  if (!item) return;
  post({
    type: 'download', session: downloadSession.get(delta.id) || null, state: delta.state.current,
    filename: item.filename, url: item.finalUrl || item.url, mime: item.mime,
    reason: cancelReason.get(delta.id) || null,
  });
  downloadSession.delete(delta.id);
  cancelReason.delete(delta.id);
  persist();
  B.downloads.erase({ id: delta.id }).catch(() => {});
});

// ------------------------------------------------------------ lifecycle

// An open native messaging port keeps the service worker alive (Chrome
// 105+); the alarm reconnects if it was recycled anyway.
B.alarms.create('keepalive', { periodInMinutes: 0.5 });
B.alarms.onAlarm.addListener(() => connect());
B.runtime.onStartup.addListener(() => connect());
B.runtime.onInstalled.addListener(() => connect());
connect();
