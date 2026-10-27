#!/usr/bin/python3 -I
"""browserd: the in-container daemon of the browser image.

  ctl.sock   (/tmp/muse/ctl.sock)  one JSON request per connection, from
             ctl.py, which the server runs with `docker exec`.
  host.sock  (/tmp/muse/host.sock) the extension, through the native
             messaging host (native-host), one JSON object per line.

Both sockets live in /tmp/muse (mode 0700, tmpfs). Nothing listens on TCP
except the egress proxy (egress.py); pages can reach neither socket.

Each browser session (a conversation's or a task's) is one Chrome window
holding one tab; the extension keeps the session -> window/tab map. The
daemon validates every URL we navigate to (egress rules, before and after
loading), drives the extension, maps windows to X windows for xdotool
input (humanised for the agent, direct for the person at the console),
and files PDF downloads per session under /data/sessions/<id>/.

Requests: {"op": ..., "session": <uuid>, ...}. Replies: {"ok": true,
"result": ...} or {"ok": false, "status": N, "code": ..., "message": ...}.
"""
import base64
import json
import math
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import egress  # noqa: E402

RUN = os.environ.get("MUSE_RUN_DIR", "/tmp/muse")
DATA = os.environ.get("MUSE_DATA_DIR", "/data")
DOWNLOADS = os.environ.get("MUSE_DOWNLOADS_DIR", os.path.join(DATA, "downloads"))
SESSIONS = os.path.join(DATA, "sessions")
# `viewport` (the browser image): each window is sized so its page area is
# exactly VIEW_W x VIEW_H. `screen` (the browser inside a desktop computer,
# init.sh --embedded): each window fills the screen and the page area is
# what it leaves. Input coordinates are checked against the real page area.
LAYOUT = os.environ.get("MUSE_BROWSER_LAYOUT", "viewport")
VIEW_W, VIEW_H = 1280, 800


def screen_size():
    try:
        w, h = os.environ.get("MUSE_SCREEN", "1440x900").split("x")
        return int(w), int(h)
    except ValueError:
        return 1440, 900


SCREEN_W, SCREEN_H = screen_size()  # the X display (init.sh)
MAX_DOWNLOAD = 10 * 1024 * 1024
MAX_PDFS = 20
READ_LIMIT = 100000
SESSION_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
SESSION_CLOSED = "Open this browser session before using its console."
NAV_FAILED = "The page could not be loaded. It may be unreachable or contain a blocked destination."
KEYS = {
    "Enter": "Return", "Tab": "Tab", "Escape": "Escape", "Backspace": "BackSpace",
    "Delete": "Delete", "ArrowUp": "Up", "ArrowDown": "Down", "ArrowLeft": "Left",
    "ArrowRight": "Right", "Home": "Home", "End": "End", "PageUp": "Prior", "PageDown": "Next",
    "Control+a": "ctrl+a", "Meta+a": "ctrl+a", "Shift+Tab": "shift+Tab",
}


class OpError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def log(*parts):
    try:
        with open(os.path.join(RUN, "browserd.log"), "a") as handle:
            handle.write(time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts) + "\n")
    except OSError:
        pass


def now_iso():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


# ---------------------------------------------------------------- extension link

class Extension:
    """The extension's connection (through native-host)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.conn = None
        self.pending = {}
        self.ready = threading.Event()
        self.hello = {}

    def attach(self, conn):
        with self.lock:
            old, self.conn = self.conn, conn
            self.ready.clear()
        if old is not None:
            try:
                old.close()
            except OSError:
                pass
        threading.Thread(target=self.reader, args=(conn,), daemon=True).start()

    def reader(self, conn):
        try:
            with conn.makefile("rb") as lines:
                for line in lines:
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    self.dispatch(message)
        except OSError:
            pass
        with self.lock:
            if self.conn is conn:
                self.conn = None
                self.ready.clear()
                waiting, self.pending = self.pending, {}
            else:
                waiting = {}
        for slot in waiting.values():
            slot[1] = {"ok": False, "code": "BROWSER_RESTARTED",
                       "error": "The browser extension disconnected."}
            slot[0].set()

    def dispatch(self, message):
        kind = message.get("type")
        if kind == "hello":
            self.hello = message
            self.ready.set()
            log("extension connected", message.get("version"), message.get("ua", "")[:80])
        elif kind == "result":
            slot = self.pending.get(message.get("id"))
            if slot:
                slot[1] = message
                slot[0].set()
        elif kind == "download":
            threading.Thread(target=downloads.event, args=(message,), daemon=True).start()

    def call(self, op, timeout=45.0, **args):
        if not self.ready.wait(45):
            raise OpError(503, "BROWSER_STARTING", "The browser is still starting. Try again in a moment.")
        ident = uuid.uuid4().hex
        slot = [threading.Event(), None]
        message = dict(args, type="command", id=ident, op=op, timeoutMs=int(timeout * 1000))
        with self.lock:
            conn = self.conn
            self.pending[ident] = slot
        try:
            if conn is None:
                raise OpError(503, "BROWSER_STARTING", "The browser is still starting. Try again in a moment.")
            try:
                conn.sendall(json.dumps(message, separators=(",", ":")).encode() + b"\n")
            except OSError:
                raise OpError(503, "BROWSER_RESTARTED", "The browser extension disconnected.")
            if not slot[0].wait(timeout + 5):
                raise OpError(504, "BROWSER_TIMEOUT", "The browser did not answer in time.")
        finally:
            with self.lock:
                self.pending.pop(ident, None)
        reply = slot[1]
        if not reply.get("ok"):
            code = reply.get("code") or "BROWSER_FAILURE"
            if code == "SESSION_CLOSED":
                raise OpError(409, code, SESSION_CLOSED)
            if code == "BROWSER_RESTARTED":
                raise OpError(503, code, "The browser restarted. Try again.")
            raise OpError(502, code, reply.get("error") or "The browser operation failed.")
        return reply.get("result")


extension = Extension()


# ---------------------------------------------------------------- X windows

def xdo(*args, timeout=5):
    out = subprocess.run(["xdotool", *map(str, args)], capture_output=True, text=True, timeout=timeout)
    return out.stdout


def chrome_windows():
    try:
        out = xdo("search", "--onlyvisible", "--class", "firefox")
    except (subprocess.SubprocessError, OSError):
        return set()
    return {int(w) for w in out.split() if w.strip().isdigit()}


class Windows:
    """Chrome window id -> X window id."""

    def __init__(self):
        self.map = {}
        self.create_lock = threading.Lock()
        self.input_lock = threading.Lock()

    def learn(self, window_id, before):
        deadline = time.time() + 5
        while time.time() < deadline:
            new = chrome_windows() - before
            if new:
                self.map[window_id] = max(new)
                return
            time.sleep(0.1)

    def xid(self, session, window_id):
        xid = self.map.get(window_id)
        if xid is not None and xid in chrome_windows():
            return xid
        # unknown (e.g. browserd restarted): focus it through Chrome and ask X
        extension.call("focus", 10, session=session)
        time.sleep(0.3)
        try:
            xid = int(xdo("getactivewindow").strip())
        except (ValueError, subprocess.SubprocessError, OSError):
            raise OpError(502, "INPUT_FAILED", "The browser window could not be found.")
        self.map[window_id] = xid
        return xid

    def activate(self, xid):
        try:
            xdo("windowactivate", "--sync", xid, timeout=3)
        except subprocess.TimeoutExpired:
            xdo("windowraise", xid)
            xdo("windowfocus", "--sync", xid, timeout=3)


windows = Windows()


# ---------------------------------------------------------------- input

def mouse_position():
    out = xdo("getmouselocation", "--shell")
    values = dict(line.split("=") for line in out.split() if "=" in line)
    return int(values["X"]), int(values["Y"])


def ease(t):
    return 4 * t ** 3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def human_move(x, y):
    """Eased, slightly curved path with jitter (browser spike human.py)."""
    x0, y0 = mouse_position()
    dist = math.hypot(x - x0, y - y0)
    if dist >= 2:
        steps = max(12, min(45, int(dist / 14)))
        mx, my = (x0 + x) / 2, (y0 + y) / 2
        off = random.uniform(-0.25, 0.25) * dist
        nx, ny = -(y - y0) / dist, (x - x0) / dist
        cx, cy = mx + nx * off, my + ny * off
        for i in range(1, steps + 1):
            t = ease(i / steps)
            bx = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * cx + t ** 2 * x
            by = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * cy + t ** 2 * y
            j = 1.5 if i < steps else 0
            xdo("mousemove", int(bx + random.uniform(-j, j)), int(by + random.uniform(-j, j)))
            time.sleep(random.uniform(0.004, 0.012))
    xdo("mousemove", int(x), int(y))


def click(x, y, human):
    if human:
        human_move(x, y)
        time.sleep(random.uniform(0.05, 0.15))
        xdo("mousedown", 1)
        time.sleep(random.uniform(0.04, 0.11))
        xdo("mouseup", 1)
    else:
        xdo("mousemove", int(x), int(y), "click", 1)


def drag(x0, y0, x1, y1, human):
    """Press at (x0, y0), move to (x1, y1) and release: slider captchas and
    other drag widgets need the intermediate moves. The agent's path is
    humanised; the person's (console) is a smooth straight line."""
    if human:
        human_move(x0, y0)
    else:
        xdo("mousemove", int(x0), int(y0))
    time.sleep(random.uniform(0.05, 0.12))
    xdo("mousedown", 1)
    time.sleep(random.uniform(0.06, 0.14))
    if human:
        human_move(x1, y1)
    else:
        steps = max(10, min(40, int(math.hypot(x1 - x0, y1 - y0) / 8)))
        for i in range(1, steps + 1):
            t = ease(i / steps)
            xdo("mousemove", int(x0 + (x1 - x0) * t), int(y0 + (y1 - y0) * t))
            time.sleep(0.008)
    time.sleep(random.uniform(0.06, 0.14))
    xdo("mouseup", 1)


def paste(text):
    proc = subprocess.Popen(["xclip", "-selection", "clipboard", "-i"], stdin=subprocess.PIPE)
    proc.communicate(text.encode("utf-8"), timeout=5)
    time.sleep(0.05)
    xdo("key", "--clearmodifiers", "ctrl+v")


def runs(text):
    """Split text into ASCII runs (typed key by key) and other runs (CJK,
    emoji, accents: pasted, as an input method commits them; xdotool's
    keysym remapping loses such characters in Chrome)."""
    out = []
    for ch in text:
        kind = ch.isascii() and (ch.isprintable() or ch == "\n")
        if out and out[-1][0] == kind:
            out[-1][1].append(ch)
        else:
            out.append((kind, [ch]))
    return [(kind, "".join(chars)) for kind, chars in out]


def type_text(text, human):
    if len(text) > 200:
        # long text is pasted, as people do; typing would take minutes
        return paste(text)
    deadline = time.time() + 25
    for ascii_run, chunk in runs(text):
        if not ascii_run:
            paste(chunk)
            time.sleep(random.uniform(0.1, 0.3) if human else 0.05)
            continue
        if not human:
            for index, line in enumerate(chunk.split("\n")):
                if index:
                    xdo("key", "Return")
                if line:
                    xdo("type", "--delay", "8", "--", line, timeout=30)
            continue
        for ch in chunk:
            if time.time() > deadline:
                paste(chunk[chunk.index(ch):])
                break
            if ch == "\n":
                xdo("key", "Return")
            else:
                xdo("type", "--delay", "0", "--", ch)
            delay = random.uniform(0.04, 0.14)
            if random.random() < 0.05:
                delay += random.uniform(0.15, 0.4)
            time.sleep(delay)


def focus_page(session):
    """Keys go to the page, not the address bar: a window opened by the
    extension starts with the address bar focused. F6 cycles Chrome's focus
    (address bar, toolbar, page); stop when the page has it."""
    for _ in range(4):
        try:
            if extension.call("hasfocus", 5, session=session):
                return
        except OpError:
            return  # no script access (error page): leave focus as it is
        xdo("key", "F6")
        time.sleep(0.15)


def scroll(delta, human, inside):
    x, y = mouse_position()
    if not inside(x, y):
        cx, cy = inside.center
        human_move(cx, cy) if human else xdo("mousemove", cx, cy)
    button = 5 if delta > 0 else 4
    notches = max(1, min(50, int(round(abs(delta) / 100))))
    if human:
        for _ in range(notches):
            xdo("click", button)
            time.sleep(random.uniform(0.03, 0.09))
    else:
        xdo("click", "--repeat", notches, "--delay", 15, button)


def valid_input(value, width=VIEW_W, height=VIEW_H):
    """`width` x `height`: the session's page area (coordinates are page
    pixels, as in its screenshots)."""
    if not isinstance(value, dict):
        raise OpError(400, "INVALID_INPUT", "Unsupported browser input or coordinates.")
    kind = value.get("type")
    x, y = value.get("x"), value.get("y")
    number = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
    inside = lambda a, b: number(a) and number(b) and 0 <= a < width and 0 <= b < height
    if kind == "click" and inside(x, y):
        return value
    if kind == "drag" and inside(x, y) and inside(value.get("toX"), value.get("toY")):
        return value
    if kind == "text" and isinstance(value.get("text"), str) and len(value["text"]) <= 10000:
        return value
    if kind == "key" and value.get("key") in KEYS:
        return value
    if kind == "scroll" and number(value.get("deltaY")) and abs(value["deltaY"]) <= 5000:
        return value
    raise OpError(400, "INVALID_INPUT", "Unsupported browser input or coordinates.")


class Viewport:
    def __init__(self, geometry):
        win, tab = geometry["window"], geometry["tab"]
        border = max(0, (win["width"] - tab["width"]) // 2)
        self.left = win["left"] + border
        self.top = win["top"] + win["height"] - tab["height"] - border
        self.width, self.height = tab["width"], tab["height"]
        self.center = (self.left + self.width // 2, self.top + self.height // 2)

    def __call__(self, x, y):
        return self.left <= x < self.left + self.width and self.top <= y < self.top + self.height

    def screen(self, x, y):
        return self.left + int(x), self.top + int(y)


# ---------------------------------------------------------------- downloads

class Downloads:
    def __init__(self):
        self.lock = threading.Lock()

    @staticmethod
    def folder(session, kind):
        path = os.path.join(SESSIONS, session, kind)
        os.makedirs(path, mode=0o700, exist_ok=True)
        return path

    @staticmethod
    def write_json(path, value):
        with open(path + ".tmp", "w") as handle:
            json.dump(value, handle)
        os.replace(path + ".tmp", path)

    def fail(self, session, name, code, message):
        ident = str(uuid.uuid4())
        self.write_json(os.path.join(self.folder(session, "download-outcomes"), ident + ".json"),
                        {"id": ident, "name": name, "code": code, "message": message,
                         "createdAt": now_iso()})
        failures = self.failures(session)
        for stale in failures[100:]:
            try:
                os.remove(os.path.join(self.folder(session, "download-outcomes"), stale["id"] + ".json"))
            except OSError:
                pass

    def event(self, message):
        session = message.get("session")
        source = message.get("filename") or ""
        raw_name = os.path.basename(source) or os.path.basename(message.get("url") or "") or "download"
        name = re.sub(r"[^a-zA-Z0-9._ -]", "_", raw_name)[:180] or "download"
        try:
            with self.lock:
                if not session or not SESSION_RE.match(session):
                    log("download without a session dropped", raw_name)
                    return
                if message.get("state") != "complete":
                    reason = message.get("reason")
                    if reason == "too_large":
                        self.fail(session, name, "DOWNLOAD_TOO_LARGE",
                                  "The download exceeds 10 MiB. Choose a smaller PDF.")
                    elif reason == "limit":
                        self.fail(session, name, "DOWNLOAD_LIMIT",
                                  "This session has reached its 20 PDF download limit.")
                    else:
                        self.fail(session, name, "DOWNLOAD_INTERRUPTED",
                                  "The download was interrupted or could not be retrieved. "
                                  "Try downloading it again.")
                    return
                path = os.path.realpath(source)
                if not path.startswith(os.path.realpath(DOWNLOADS) + os.sep) or not os.path.isfile(path):
                    log("download outside the download directory ignored", source)
                    return
                size = os.path.getsize(path)
                with open(path, "rb") as handle:
                    head = handle.read(5)
                if size > MAX_DOWNLOAD:
                    self.fail(session, name, "DOWNLOAD_TOO_LARGE",
                              "The download exceeds 10 MiB. Choose a smaller PDF.")
                elif head != b"%PDF-":
                    self.fail(session, name, "UNSUPPORTED_DOWNLOAD",
                              "Only PDF downloads can be imported. This file was not a PDF.")
                elif len(self.list(session)) >= MAX_PDFS:
                    self.fail(session, name, "DOWNLOAD_LIMIT",
                              "This session has reached its 20 PDF download limit.")
                else:
                    ident = str(uuid.uuid4())
                    folder = self.folder(session, "downloads")
                    shutil.copyfile(path, os.path.join(folder, ident + ".pdf"))
                    self.write_json(os.path.join(folder, ident + ".json"),
                                    {"id": ident, "name": name if name.lower().endswith(".pdf") else name + ".pdf",
                                     "size": size, "mimeType": "application/pdf"})
                    log("download filed", session, ident, size)
        finally:
            if source:
                path = os.path.realpath(source)
                if path.startswith(os.path.realpath(DOWNLOADS) + os.sep):
                    try:
                        os.remove(path)
                    except OSError:
                        pass

    def list(self, session):
        folder = self.folder(session, "downloads")
        items = []
        for name in sorted(os.listdir(folder)):
            if name.endswith(".json"):
                with open(os.path.join(folder, name)) as handle:
                    items.append(json.load(handle))
        return items

    def failures(self, session):
        folder = self.folder(session, "download-outcomes")
        items = []
        for name in os.listdir(folder):
            if name.endswith(".json"):
                with open(os.path.join(folder, name)) as handle:
                    items.append(json.load(handle))
        return sorted(items, key=lambda f: f.get("createdAt", ""), reverse=True)


downloads = Downloads()


# ---------------------------------------------------------------- operations

def session_of(request):
    session = request.get("session")
    if not isinstance(session, str) or not SESSION_RE.match(session.lower()):
        raise OpError(400, "INVALID_SESSION", "A valid UUID session ID is required.")
    return session.lower()


def public(url):
    try:
        egress.validate_url(url)
    except egress.Blocked as error:
        raise OpError(400, "BLOCKED_URL", str(error))
    except egress.DnsUnavailable as error:
        raise OpError(502, "DNS_UNAVAILABLE", str(error))


def page_result(page):
    return {"url": page.get("url") or "about:blank", "title": (page.get("title") or "")[:300]}


def op_health(request):
    return {"extension": extension.ready.is_set(), "version": extension.hello.get("version"),
            "ua": extension.hello.get("ua")}


def window_layout():
    """How the extension sizes a new session window (see LAYOUT)."""
    if LAYOUT == "screen":
        return {"mode": "screen", "width": SCREEN_W, "height": SCREEN_H}
    return {"mode": "viewport", "width": VIEW_W, "height": VIEW_H}


def op_open(request):
    session = session_of(request)
    url = request.get("url")
    public(url)
    with windows.create_lock:
        before = chrome_windows()
        ensured = extension.call("ensure", 20, session=session, layout=window_layout())
        if ensured.get("created"):
            windows.learn(ensured["windowId"], before)
    page = extension.call("navigate", 40, session=session, url=url, waitMs=25000)
    if page.get("error") and not page.get("download") and ensured.get("created"):
        # the first navigation of a window created just now (a browser that
        # has only started, e.g. in a desktop computer) has failed where the
        # same request a moment later works: one more try before giving up
        log("navigation failed in a new window, retrying", url, page.get("error"))
        time.sleep(1)
        page = extension.call("navigate", 40, session=session, url=url, waitMs=25000)
    final = page.get("url") or ""
    if page.get("error") and not page.get("download"):
        log("navigation failed", url, page.get("error"), final)
        extension.call("blank", 10, session=session)
        raise OpError(502, "NAVIGATION_FAILED", NAV_FAILED)
    if final != "about:blank":
        try:
            public(final)
        except OpError:
            log("navigation ended at a blocked destination", url, final)
            extension.call("blank", 10, session=session)
            raise OpError(502, "NAVIGATION_FAILED", NAV_FAILED)
    return page_result(page)


def op_read(request):
    session = session_of(request)
    page = extension.call("read", 30, session=session, maxChars=READ_LIMIT)
    public(page.get("url") or "about:blank")
    text = page.get("markdown") or ""
    truncated = bool(page.get("truncated")) or len(text) > READ_LIMIT
    return dict(page_result(page), text=text[:READ_LIMIT], truncated=truncated)


def op_screenshot(request):
    session = session_of(request)
    try:
        data = (extension.call("capture", 20, session=session) or {}).get("data") or ""
    except OpError as error:
        if error.code == "SESSION_CLOSED":
            raise
        data = ""
    if not data:
        # captureVisibleTab cannot capture some pages (about:blank, Chrome's
        # error pages): an X screenshot of the window's viewport instead.
        data = x_screenshot(session)
    return {"png": data}


def x_screenshot(session):
    geometry = extension.call("geometry", 10, session=session)
    view = Viewport(geometry)
    path = os.path.join(RUN, "shot-%s.png" % uuid.uuid4().hex)
    with windows.input_lock:
        windows.activate(windows.xid(session, geometry["windowId"]))
        time.sleep(0.15)
        subprocess.run(["scrot", "-o", "-a", "%d,%d,%d,%d" % (view.left, view.top, view.width, view.height),
                        path], capture_output=True, timeout=10)
    try:
        with open(path, "rb") as handle:
            return base64.b64encode(handle.read()).decode()
    except OSError:
        raise OpError(502, "SCREENSHOT_FAILED", "The screenshot could not be taken.")
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def op_input(request):
    session = session_of(request)
    if not isinstance(request.get("input"), dict):
        valid_input(None)
    human = request.get("mode", "human") != "direct"
    geometry = extension.call("geometry", 10, session=session)
    view = Viewport(geometry)
    value = valid_input(request.get("input"), view.width, view.height)
    with windows.input_lock:
        xid = windows.xid(session, geometry["windowId"])
        windows.activate(xid)
        kind = value["type"]
        if kind == "click":
            click(*view.screen(value["x"], value["y"]), human)
        elif kind == "drag":
            drag(*view.screen(value["x"], value["y"]), *view.screen(value["toX"], value["toY"]), human)
        elif kind == "text":
            focus_page(session)
            type_text(value["text"], human)
        elif kind == "key":
            focus_page(session)
            xdo("key", "--clearmodifiers", KEYS[value["key"]])
        else:
            scroll(value["deltaY"], human, view)
    time.sleep(0.3)
    page = extension.call("info", 10, session=session)
    if (page.get("url") or "about:blank") != "about:blank":
        public(page["url"])
    return page_result(page)


def op_show(request):
    """Raise the session's window for the console's live view (x11vnc, see
    muse_browser:vnc/2) and return its rectangle on the screen, clipped to
    the display: the view shows that window, Chrome's toolbar included."""
    session = session_of(request)
    geometry = extension.call("geometry", 10, session=session)
    with windows.input_lock:
        windows.activate(windows.xid(session, geometry["windowId"]))
    win = geometry["window"]
    left = min(max(0, int(win["left"])), SCREEN_W - 1)
    top = min(max(0, int(win["top"])), SCREEN_H - 1)
    return {"left": left, "top": top,
            "width": max(1, min(int(win["width"]), SCREEN_W - left)),
            "height": max(1, min(int(win["height"]), SCREEN_H - top))}


def op_close(request):
    session = session_of(request)
    extension.call("close", 15, session=session)
    return {"closed": True}


def op_downloads(request):
    session = session_of(request)
    return {"downloads": downloads.list(session), "failures": downloads.failures(session)}


def op_download(request):
    session = session_of(request)
    ident = request.get("download")
    if not isinstance(ident, str) or not SESSION_RE.match(ident):
        raise OpError(400, "INVALID_SESSION", "A valid UUID session ID is required.")
    folder = downloads.folder(session, "downloads")
    meta = os.path.join(folder, ident + ".json")
    if not os.path.isfile(meta):
        raise OpError(404, "DOWNLOAD_NOT_FOUND", "PDF download not found.")
    path = os.path.join(folder, ident + ".pdf")
    if os.path.getsize(path) > MAX_DOWNLOAD:
        raise OpError(413, "DOWNLOAD_TOO_LARGE", "The PDF exceeds 10 MiB.")
    with open(path, "rb") as handle:
        return {"name": json.load(open(meta))["name"], "data": base64.b64encode(handle.read()).decode()}


def op_sessions(request):
    return extension.call("list", 10)


# Diagnostics for the real-browser test suite (never used by the server).
def op_diag(request):
    session = session_of(request)
    what = request.get("what")
    if what not in ("probe", "fetch", "assign", "active", "clicks", "geometry", "xwindows", "egress", "rect"):
        raise OpError(400, "INVALID_REQUEST", "Unknown diagnostic.")
    if what == "xwindows":
        return {"windows": sorted(chrome_windows())}
    if what == "egress":
        try:
            with open(egress.LOG_PATH) as handle:
                return {"lines": handle.read().splitlines()[-200:]}
        except OSError:
            return {"lines": []}
    return extension.call("diag", 30, session=session, what=what, url=request.get("url"))


OPS = {"health": op_health, "open": op_open, "read": op_read, "screenshot": op_screenshot,
       "input": op_input, "show": op_show, "close": op_close, "downloads": op_downloads, "download": op_download,
       "sessions": op_sessions, "diag": op_diag}


def serve_ctl(conn):
    try:
        with conn.makefile("rb") as stream:
            line = stream.readline(1 << 20)
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError
            op = OPS.get(request.get("op"))
            if op is None:
                raise OpError(404, "NOT_FOUND", "Unknown browser operation.")
            reply = {"ok": True, "result": op(request)}
        except OpError as error:
            reply = {"ok": False, "status": error.status, "code": error.code, "message": error.message}
        except ValueError:
            reply = {"ok": False, "status": 400, "code": "INVALID_REQUEST", "message": "A JSON request is required."}
        except Exception as error:  # noqa: BLE001
            log("ctl failure", repr(error))
            reply = {"ok": False, "status": 500, "code": "BROWSER_FAILURE",
                     "message": "The browser operation failed. Reopen the session and try again."}
        conn.sendall(json.dumps(reply, separators=(",", ":")).encode() + b"\n")
    except OSError:
        pass
    finally:
        conn.close()


def listen(path, handler):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(64)

    def loop():
        while True:
            conn, _ = server.accept()
            handler(conn)

    threading.Thread(target=loop, daemon=True).start()


def main():
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    os.makedirs(DOWNLOADS, mode=0o700, exist_ok=True)
    os.makedirs(SESSIONS, mode=0o700, exist_ok=True)
    listen(os.path.join(RUN, "host.sock"), extension.attach)
    listen(os.path.join(RUN, "ctl.sock"),
           lambda conn: threading.Thread(target=serve_ctl, args=(conn,), daemon=True).start())
    log("browserd ready")
    threading.Event().wait()


if __name__ == "__main__":
    main()
