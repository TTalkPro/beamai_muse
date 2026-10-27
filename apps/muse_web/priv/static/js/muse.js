// beamai_muse page controllers, loaded after the aihtml runtime (window.AH).

// Enter submits the composer, Shift+Enter adds a newline (aihtml's
// prevent_default filters by key name only, not by modifier).
AH.register("muse-composer", class extends AH.Controller {
  setup() {
    this.listen(this.element, "keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        const form = this.element.closest("form");
        if (form && this.element.value.trim() !== "") form.requestSubmit();
      }
    });
  }
});

// Keep a scroll container pinned to the bottom while new content arrives,
// unless the reader has scrolled up; then a round button takes them back.
AH.register("muse-scroll", class extends AH.Controller {
  setup() {
    const el = this.element;
    let pinned = true;
    const fab = document.createElement("button");
    fab.type = "button";
    fab.className = "muse-fab";
    fab.setAttribute("aria-label", "回到底部");
    fab.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 5v14"/><path d="m19 12-7 7-7-7"/></svg>';
    el.parentElement?.appendChild(fab);
    this.fab = fab;
    const sync = () => fab.classList.toggle("muse-fab-shown", !pinned);
    this.listen(fab, "click", () => { el.scrollTo({ top: el.scrollHeight, behavior: "smooth" }); });
    this.listen(el, "scroll", () => { pinned = el.scrollHeight - el.scrollTop - el.clientHeight < 40; sync(); });
    this.observer = new MutationObserver(() => { if (pinned) el.scrollTop = el.scrollHeight; });
    this.observer.observe(el, { childList: true, subtree: true, characterData: true });
    el.scrollTop = el.scrollHeight;
  }
  teardown() { if (this.observer) this.observer.disconnect(); this.fab?.remove(); }
});

// Copy a message (hover toolbar).
document.addEventListener("click", (e) => {
  const btn = e.target instanceof Element ? e.target.closest("[data-muse-copy]") : null;
  if (!btn) return;
  navigator.clipboard?.writeText(btn.getAttribute("data-muse-copy") || "").then(() => {
    btn.classList.add("muse-copied");
    setTimeout(() => btn.classList.remove("muse-copied"), 1200);
  });
});

// The header's sidebar button: on wide screens it folds the sidebar away
// (remembered), on narrow ones it slides it in; the scrim and Escape close
// it again (see muse.css).
const museShell = () => document.getElementById("muse-shell");
const museWide = () => window.matchMedia("(min-width: 1024px)").matches;
if (localStorage.getItem("muse.side.folded") === "1") museShell()?.classList.add("muse-side-folded");
AH.register("muse-menu", class extends AH.Controller {
  setup() {
    this.listen(this.element, "click", () => {
      const shell = museShell();
      if (!shell) return;
      if (museWide()) {
        const folded = shell.classList.toggle("muse-side-folded");
        localStorage.setItem("muse.side.folded", folded ? "1" : "0");
      } else {
        shell.classList.toggle("muse-menu-open");
      }
    });
  }
});
AH.register("muse-menu-close", class extends AH.Controller {
  setup() {
    this.listen(this.element, "click", () => museShell()?.classList.remove("muse-menu-open"));
  }
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") museShell()?.classList.remove("muse-menu-open");
});

// The conversation list is rendered once for every page; mark the open
// conversation here, again whenever the list is re-rendered.
const museMarkThread = () => {
  const path = location.pathname;
  document.querySelectorAll("#chat-threads a.muse-thread-link").forEach((a) => {
    if (a.getAttribute("href") === path) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  });
};
museMarkThread();
const museSide = document.getElementById("muse-side");
if (museSide) new MutationObserver(museMarkThread).observe(museSide, { childList: true, subtree: true });
window.addEventListener("popstate", museMarkThread);
// replace_url after the first message of a new conversation
const museReplaceState = history.replaceState.bind(history);
history.replaceState = (...args) => { museReplaceState(...args); setTimeout(museMarkThread, 0); };

// Rename: a `data-muse-rename` button fills the shell's dialog and opens it.
document.addEventListener("click", (e) => {
  const btn = e.target instanceof Element ? e.target.closest("[data-muse-rename]") : null;
  const win = document.getElementById("muse-rename");
  if (!btn || !win) return;
  document.getElementById("muse-rename-thread").value = btn.getAttribute("data-muse-rename");
  const input = document.getElementById("muse-rename-input");
  input.value = btn.getAttribute("data-title") || "";
  const pop = btn.closest(".ah-popover");
  if (pop) AH.invoke(pop, "close");
  AH.invoke(win, "open");
  setTimeout(() => { input.focus(); input.select(); }, 50);
});


// Live remote screens (the browser console, the desktop computer): noVNC
// over the same-origin WebSocket `data-ah-url` (muse_vnc_handler, an x11vnc
// in the container for this connection only). `data-ah-view-only` keeps the
// viewer's mouse and keys local; x11vnc also drops them then. The picture is
// scaled into the element. A dropped connection is retried a few times,
// then a button reconnects. Changing either attribute reconnects.
let museRFB = null;
const museNoVnc = () => (museRFB ??= import("/static/novnc/core/rfb.js").then((m) => m.default));
AH.register("muse-vnc", class extends AH.Controller {
  static attrs = { url: String, viewOnly: Boolean };
  // (not connect/disconnect: those are Stimulus's own lifecycle methods)
  setup() {
    this.screen = document.createElement("div");
    this.screen.className = "muse-vnc-screen";
    this.status = document.createElement("div");
    this.status.className = "muse-vnc-status";
    this.element.append(this.screen, this.status);
    this.tries = 0;
    this.dial();
  }
  teardown() {
    this.hangup();
    this.screen?.remove();
    this.status?.remove();
  }
  urlValueChanged() { this.restart(); }
  viewOnlyValueChanged() { this.restart(); }
  restart() {
    // both attributes may change in one update: reconnect once
    clearTimeout(this.again);
    this.again = setTimeout(() => { this.tries = 0; this.hangup(); this.dial(); }, 0);
  }
  hangup() {
    clearTimeout(this.retry);
    const rfb = this.rfb;
    this.rfb = null;
    if (rfb) { try { rfb.disconnect(); } catch { /* already closed */ } }
  }
  note(text, button) {
    this.status.replaceChildren();
    if (!text) { this.status.hidden = true; return; }
    const p = document.createElement("div");
    p.textContent = text;
    this.status.append(p);
    if (button) {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = "重新连接";
      b.addEventListener("click", () => { this.tries = 0; this.hangup(); this.dial(); });
      this.status.append(b);
    }
    this.status.hidden = false;
  }
  dial() {
    if (!this.urlValue) return;
    this.note(this.tries ? "连接已断开，正在重新连接…" : "正在连接画面…");
    const url = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + this.urlValue;
    museNoVnc().then((RFB) => {
      if (!this.element.isConnected || this.rfb) return;
      const rfb = new RFB(this.screen, url, { shared: true });
      this.rfb = rfb;
      rfb.scaleViewport = true;
      rfb.resizeSession = false;
      rfb.viewOnly = this.viewOnlyValue;
      rfb.showDotCursor = !this.viewOnlyValue;
      rfb.qualityLevel = 7;
      rfb.compressionLevel = 2;
      rfb.background = "#0B0D10";
      rfb.addEventListener("connect", () => {
        if (this.rfb !== rfb) return;
        this.tries = 0;
        this.note(null);
        if (!this.viewOnlyValue) rfb.focus();
      });
      rfb.addEventListener("disconnect", () => {
        if (this.rfb !== rfb) return;
        this.rfb = null;
        if (++this.tries <= 4) {
          this.note("连接已断开，正在重新连接…");
          this.retry = setTimeout(() => this.dial(), 1000 * 2 ** (this.tries - 1));
        } else {
          this.note("画面连接已断开。", true);
        }
      });
      rfb.addEventListener("securityfailure", () => {
        if (this.rfb === rfb) this.note("画面连接被拒绝。", true);
      });
    }).catch(() => this.note("无法加载画面组件。", true));
  }
});
