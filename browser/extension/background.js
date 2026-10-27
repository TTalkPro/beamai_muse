// beamai_muse browser bridge (MV3 service worker).
//
// Talks only to its native messaging host (dev.openmuse.browser), which
// relays to browserd in the container; pages cannot reach it (no
// externally_connectable, no web_accessible_resources, no content scripts
// declared). Never uses chrome.debugger (that would be CDP).
//
// One browser session = one Chrome window holding one tab. The session ->
// window/tab map lives in chrome.storage.session (survives a service worker
// restart, not a browser restart: after one, every session answers
// SESSION_CLOSED and the server re-opens it at its last URL).
'use strict';

const HOST = 'dev.openmuse.browser';
const VIEW_W = 1280, VIEW_H = 800;
const MAX_DOWNLOAD = 10 * 1024 * 1024;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const withTimeout = (p, ms, what) => Promise.race([
  p, new Promise((_, rej) => setTimeout(() => rej(fail('TIMEOUT', `timeout after ${ms} ms: ${what}`)), ms)),
]);
function fail(code, message) { const e = new Error(message); e.code = code; return e; }

// ------------------------------------------------------------ state

const sessions = new Map(); // sid -> {windowId, tabId, pending: {url, at}, downloadAt}
const downloadSession = new Map(); // download id -> sid
const cancelReason = new Map(); // download id -> too_large | limit
let lastActive = null;
let loading = null;

function load() {
  if (!loading) {
    loading = chrome.storage.session.get(['sessions', 'downloads', 'lastActive']).then(s => {
      for (const [k, v] of Object.entries(s.sessions || {})) sessions.set(k, v);
      for (const [k, v] of Object.entries(s.downloads || {})) downloadSession.set(Number(k), v);
      lastActive = s.lastActive || null;
    });
  }
  return loading;
}

function persist() {
  return chrome.storage.session.set({
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
    const tab = await chrome.tabs.get(s.tabId);
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
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    setTimeout(connect, 1000);
    return;
  }
  port.onMessage.addListener(m => { if (m && m.type === 'command') run(m); });
  port.onDisconnect.addListener(() => { port = null; setTimeout(connect, 1000); });
  post({ type: 'hello', version: chrome.runtime.getManifest().version, ua: navigator.userAgent });
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

async function fitViewport(windowId, tabId) {
  for (let i = 0; i < 8; i++) {
    const [w, t] = await Promise.all([chrome.windows.get(windowId), chrome.tabs.get(tabId)]);
    if (t.width === VIEW_W && t.height === VIEW_H && w.left === 0 && w.top === 0) return;
    if (!t.width || !t.height) { await sleep(100); continue; }
    await chrome.windows.update(windowId, {
      left: 0, top: 0, width: w.width + VIEW_W - t.width, height: w.height + VIEW_H - t.height,
    });
    await sleep(150);
  }
}

// Wait for the main frame's navigation that starts after `start()`.
function navigation(tabId, sid, waitMs, start) {
  return new Promise(resolve => {
    let begun = false, done = false;
    const finish = r => {
      if (done) return;
      done = true;
      chrome.webNavigation.onBeforeNavigate.removeListener(onBefore);
      chrome.webNavigation.onDOMContentLoaded.removeListener(onLoaded);
      chrome.webNavigation.onReferenceFragmentUpdated.removeListener(onLoaded);
      chrome.webNavigation.onErrorOccurred.removeListener(onError);
      clearTimeout(timer);
      resolve(r);
    };
    const mine = d => d.tabId === tabId && d.frameId === 0;
    const onBefore = d => { if (mine(d)) begun = true; };
    const onLoaded = d => { if (mine(d) && begun) finish({ ok: true }); };
    const onError = async d => {
      if (!mine(d) || !begun) return;
      if (d.error === 'net::ERR_ABORTED') {
        // a navigation that became a download (PDFs: AlwaysOpenPdfExternally)
        for (let i = 0; i < 10; i++) {
          const s = sessions.get(sid);
          if (s && s.downloadAt && s.downloadAt >= startedAt) return finish({ ok: true, download: true });
          await sleep(100);
        }
      }
      finish({ error: d.error });
    };
    const startedAt = Date.now();
    chrome.webNavigation.onBeforeNavigate.addListener(onBefore);
    chrome.webNavigation.onDOMContentLoaded.addListener(onLoaded);
    chrome.webNavigation.onReferenceFragmentUpdated.addListener(onLoaded);
    chrome.webNavigation.onErrorOccurred.addListener(onError);
    const timer = setTimeout(() => {
      const s = sessions.get(sid);
      finish(s && s.downloadAt && s.downloadAt >= startedAt ? { ok: true, download: true } : { error: 'timeout' });
    }, waitMs);
    start().catch(e => finish({ error: String(e && e.message || e) }));
  });
}

// Network-idle-ish settle in the isolated world: no new resources and no
// DOM mutations for quietMs, capped at maxMs (browser spike).
async function settle(tabId, quietMs, maxMs) {
  await withTimeout(chrome.scripting.executeScript({
    target: { tabId },
    args: [quietMs, maxMs],
    func: (quietMs, maxMs) => new Promise(resolve => {
      const t0 = performance.now();
      let last = t0, res = performance.getEntriesByType('resource').length;
      const mo = new MutationObserver(() => { last = performance.now(); });
      mo.observe(document, { subtree: true, childList: true, characterData: true });
      const iv = setInterval(() => {
        const n = performance.getEntriesByType('resource').length;
        if (n !== res) { res = n; last = performance.now(); }
        const now = performance.now();
        if ((now - last >= quietMs && document.readyState === 'complete') || now - t0 >= maxMs) {
          clearInterval(iv); mo.disconnect(); resolve(true);
        }
      }, 100);
    }),
  }), maxMs + 2000, 'settle');
}

// A PDF the session shows (Chrome's viewer) is also downloaded once, so it
// can be imported into Files: the PDF viewer stays enabled (disabling it
// with AlwaysOpenPdfExternally would empty navigator.plugins, a bot tell).
const pdfSeen = new Map(); // sid + url -> time
async function downloadIfPdf(sid, tabId) {
  let pdf = false, url = null;
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId }, func: () => ({ type: document.contentType, url: location.href }),
    });
    pdf = r.result.type === 'application/pdf';
    url = r.result.url;
  } catch (e) { return false; }
  if (!pdf || !/^https?:/.test(url)) return false;
  const key = sid + ' ' + url;
  if (Date.now() - (pdfSeen.get(key) || 0) < 60000) return true;
  pdfSeen.set(key, Date.now());
  const s = sessions.get(sid);
  if (s) s.pending = { url, at: Date.now() };
  try { await chrome.downloads.download({ url, conflictAction: 'uniquify' }); } catch (e) { return false; }
  return true;
}

chrome.webNavigation.onDOMContentLoaded.addListener(async d => {
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

  async ensure({ session }) {
    const s = sessions.get(session);
    if (s) {
      try {
        const tab = await chrome.tabs.get(s.tabId);
        return { windowId: tab.windowId, tabId: tab.id, created: false };
      } catch (e) { sessions.delete(session); }
    }
    const w = await chrome.windows.create({
      url: 'about:blank', left: 0, top: 0, width: VIEW_W, height: VIEW_H + 90, focused: true, type: 'normal',
    });
    const tabId = w.tabs[0].id;
    sessions.set(session, { windowId: w.id, tabId });
    lastActive = session;
    await persist();
    await fitViewport(w.id, tabId);
    return { windowId: w.id, tabId, created: true };
  },

  async navigate({ session, url, waitMs = 25000 }) {
    const { s, tab } = await live(session);
    s.pending = { url, at: Date.now() };
    lastActive = session;
    persist();
    const r = await navigation(tab.id, session, waitMs, () => chrome.tabs.update(tab.id, { url }));
    if (r.ok && !r.download && await downloadIfPdf(session, tab.id)) {
      for (let i = 0; i < 30 && !(s.downloadAt && s.downloadAt >= s.pending.at); i++) await sleep(100);
      r.download = true;
    }
    if (r.ok && !r.download) { try { await settle(tab.id, 500, 4000); } catch (e) { /* page moved on */ } }
    const t = await chrome.tabs.get(tab.id);
    return { url: t.url || t.pendingUrl || 'about:blank', title: t.title || '', error: r.error || null, download: !!r.download };
  },

  async blank({ session }) {
    const { tab } = await live(session);
    await chrome.tabs.update(tab.id, { url: 'about:blank' });
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
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['page-markdown.js'] });
    const [r] = await chrome.scripting.executeScript({
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
      return chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
    };
    const p = captureChain.then(shoot, shoot);
    captureChain = p.catch(() => {});
    const dataUrl = await p;
    return { data: dataUrl.slice(dataUrl.indexOf(',') + 1) };
  },

  async geometry({ session }) {
    const { tab } = await live(session);
    let w = await chrome.windows.get(tab.windowId);
    if (w.state !== 'normal') {
      await chrome.windows.update(w.id, { state: 'normal' });
      await fitViewport(w.id, tab.id);
      w = await chrome.windows.get(tab.windowId);
    }
    const t = await chrome.tabs.get(tab.id);
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
    const [r] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => document.hasFocus() });
    return !!r.result;
  },

  async focus({ session }) {
    const { tab } = await live(session);
    await chrome.windows.update(tab.windowId, { focused: true });
    return true;
  },

  async close({ session }) {
    await load();
    const s = sessions.get(session);
    if (!s) return { closed: false };
    sessions.delete(session);
    await persist();
    const all = await chrome.windows.getAll();
    if (all.length <= 1) await chrome.windows.create({ url: 'about:blank', focused: false });
    try { await chrome.windows.remove(s.windowId); } catch (e) { /* already gone */ }
    return { closed: true };
  },

  // Diagnostics for the real-browser test suite.
  async diag({ session, what, url }) {
    const { tab } = await live(session);
    const target = { tabId: tab.id };
    if (what === 'probe') {
      const [r] = await chrome.scripting.executeScript({ target, world: 'MAIN', func: probe });
      return r.result;
    }
    if (what === 'fetch') {
      const [r] = await chrome.scripting.executeScript({
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
      const r = await navigation(tab.id, session, 20000, () => chrome.scripting.executeScript({
        target, world: 'MAIN', args: [url], func: url => { location.href = url; },
      }));
      const t = await chrome.tabs.get(tab.id);
      return { url: t.url, title: t.title, error: r.error || null };
    }
    if (what === 'active') {
      const [r] = await chrome.scripting.executeScript({
        target, func: () => {
          const e = document.activeElement;
          return { tag: e ? e.tagName.toLowerCase() : null, value: e && 'value' in e ? e.value : null, focus: document.hasFocus() };
        },
      });
      return r.result;
    }
    if (what === 'clicks') {
      const [r] = await chrome.scripting.executeScript({
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
      const [r] = await chrome.scripting.executeScript({
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
chrome.tabs.onCreated.addListener(async tab => {
  await load();
  const owner = [...sessions].find(([, s]) =>
    s.tabId !== tab.id && (s.windowId === tab.windowId || (tab.openerTabId && s.tabId === tab.openerTabId)));
  if (!owner) return;
  const [sid, s] = owner;
  let url = tab.pendingUrl || tab.url;
  for (let i = 0; i < 30 && (!url || url === 'about:blank'); i++) {
    await sleep(100);
    try { const t = await chrome.tabs.get(tab.id); url = t.pendingUrl || t.url; } catch (e) { return; }
  }
  try { await chrome.tabs.remove(tab.id); } catch (e) { /* gone */ }
  if (/^https?:/.test(url || '')) {
    s.pending = { url, at: Date.now() };
    lastActive = sid;
    chrome.tabs.update(s.tabId, { url, active: true }).catch(() => {});
  }
});

chrome.windows.onRemoved.addListener(async windowId => {
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
      try { if ((await chrome.tabs.get(s.tabId)).url === item.referrer) return sid; } catch (e) { /* closed */ }
    }
  }
  return lastActive && sessions.has(lastActive) ? lastActive : null;
}

let sizeWatch = null;
function watchSizes() {
  if (sizeWatch) return;
  sizeWatch = setInterval(async () => {
    const running = await chrome.downloads.search({ state: 'in_progress' });
    if (!running.length) { clearInterval(sizeWatch); sizeWatch = null; return; }
    for (const d of running) {
      if (d.bytesReceived > MAX_DOWNLOAD || d.totalBytes > MAX_DOWNLOAD) {
        cancelReason.set(d.id, 'too_large');
        chrome.downloads.cancel(d.id).catch(() => {});
      }
    }
  }, 300);
}

chrome.downloads.onCreated.addListener(async item => {
  await load();
  const sid = await attribute(item);
  downloadSession.set(item.id, sid);
  const s = sid && sessions.get(sid);
  if (s) s.downloadAt = Date.now();
  persist();
  if ((item.totalBytes || 0) > MAX_DOWNLOAD || (item.fileSize || 0) > MAX_DOWNLOAD) {
    cancelReason.set(item.id, 'too_large');
    chrome.downloads.cancel(item.id).catch(() => {});
  }
  watchSizes();
});

chrome.downloads.onChanged.addListener(async delta => {
  if (!delta.state || !['complete', 'interrupted'].includes(delta.state.current)) return;
  await load();
  const [item] = await chrome.downloads.search({ id: delta.id });
  if (!item) return;
  post({
    type: 'download', session: downloadSession.get(delta.id) || null, state: delta.state.current,
    filename: item.filename, url: item.finalUrl || item.url, mime: item.mime,
    reason: cancelReason.get(delta.id) || null,
  });
  downloadSession.delete(delta.id);
  cancelReason.delete(delta.id);
  persist();
  chrome.downloads.erase({ id: delta.id }).catch(() => {});
});

// ------------------------------------------------------------ lifecycle

// An open native messaging port keeps the service worker alive (Chrome
// 105+); the alarm reconnects if it was recycled anyway.
chrome.alarms.create('keepalive', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => connect());
chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(() => connect());
connect();
