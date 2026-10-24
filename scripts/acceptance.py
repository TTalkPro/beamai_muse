"""End-to-end acceptance checks over HTTP (see scripts/acceptance.sh)."""
import json, os, sys, time, urllib.request, urllib.error, http.cookiejar, hashlib
BASE = sys.argv[1]
def req(method, path, body=None, token=None, raw=False, headers=None, url=None):
    h = {"Origin": BASE}
    if token: h["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    h.update(headers or {})
    r = urllib.request.Request(url or BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            b = resp.read(); return resp.status, (b if raw else (json.loads(b) if b else None)), resp.headers
    except urllib.error.HTTPError as e:
        b = e.read(); return e.code, b[:300], e.headers
results = []
def check(name, ok, detail=""):
    results.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + ("  " + str(detail) if detail else ""), flush=True)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
op = urllib.request.build_opener(NoRedirect)
r = urllib.request.Request(BASE + "/login", data=b"", method="POST", headers={"Origin": BASE, "Content-Type": "application/x-www-form-urlencoded"})
try: op.open(r)
except urllib.error.HTTPError as e:
    cookie = e.headers["set-cookie"].split(";")[0].split("=",1)[1]
check("form login sets session cookie", len(cookie) > 20)
T = cookie
# --- browser (real Playwright worker) ---
s, b, _ = req("POST", "/api/browsers", {"url": "https://example.com"}, T)
check("open example.com in real worker", s == 201 and b.get("status") == "active", (s, b if s != 201 else b.get("title")))
bid = b["id"]
s, b, _ = req("GET", "/api/browsers/" + bid, None, T)
preview, console = b["previewUrl"], b["consoleUrl"]
s, read1, _ = req("GET", "/api/browsers/%s/read" % bid, None, T)
check("read page text", s == 200 and isinstance(read1, dict) and "Example Domain" in read1.get("title", ""), read1)
s, png1, _ = req("GET", None, raw=True, url=preview)
check("signed screenshot is a PNG", s == 200 and png1[:8] == b"\x89PNG\r\n\x1a\n", len(png1))
for key in ["Tab", "Enter"]:
    s, b, _ = req("POST", None, {"type": "key", "key": key}, url=console)
    check("console key " + key, s == 200, b)
# navigation takes a moment; the worker answers an error while it is under way
read2 = {}
for _ in range(20):
    time.sleep(1)
    s, r2, _ = req("GET", "/api/browsers/%s/read" % bid, None, T)
    if s == 200 and isinstance(r2, dict) and r2.get("url") != read1.get("url"):
        read2 = r2
        break
check("link followed (page changed)", bool(read2), read2.get("url") if read2 else (s, r2))
s, png2, _ = req("GET", None, raw=True, url=preview)
check("screenshot updated", s == 200 and hashlib.sha256(png2).digest() != hashlib.sha256(png1).digest())
s, b, _ = req("POST", None, {"type": "click", "x": 640, "y": 400}, url=console)
check("console click", s == 200, b)
s, html, _ = req("GET", "/browser/" + bid, None, None, raw=True, headers={"Cookie": "muse_session=" + T})
check("UI console page renders", s == 200 and b"data-ah-poll" in html, s)
s, b, _ = req("POST", "/api/browsers/%s/close" % bid, {}, T)
check("close session", s == 200 and b.get("status") == "closed", b)
# --- Docker computer (desktop variant) ---
s, b, _ = req("POST", "/api/computer/start", None, T)
check("start desktop computer", s == 200 and b.get("status") == "running", (s, b))
s, b, _ = req("POST", "/api/computer/commands", {"command": "ls -la /workspace && echo DISPLAY=$DISPLAY"}, T)
check("run ls /workspace", s == 200 and b.get("exitCode") == 0 and "DISPLAY=:0" in b.get("stdout", ""), (b.get("exitCode"), b.get("stdout", "")[-80:]))
s, b, _ = req("POST", "/api/computer/files/write", {"path": "/workspace/accept.txt", "text": "你好 acceptance\n"}, T)
check("write file", s == 200, b)
s, b, _ = req("POST", "/api/computer/files/read", {"path": "/workspace/accept.txt"}, T)
check("read file back", s == 200 and b.get("text") == "你好 acceptance\n", b)
s, b, _ = req("GET", "/api/computer/desktop", None, T)
check("desktop status", s == 200, b)
s, b, _ = req("POST", "/api/computer/desktop/actions", {"action": "screenshot"}, T)
check("desktop screenshot action", s == 200 and b.get("receipt", {}).get("status") == "succeeded", (s, b if s != 200 else b.get("receipt", {}).get("command")))
s, b, _ = req("POST", "/api/computer/desktop/actions", {"action": "key", "text": "shift exec touch x"}, T)
check("xdotool command injection refused", s == 422, (s, b))
s, html, _ = req("GET", "/computer", None, None, raw=True, headers={"Cookie": "muse_session=" + T})
check("UI computer page renders desktop card", s == 200 and b"desktop" in html, s)
s, b, _ = req("POST", "/api/computer/stop", None, T)
check("stop computer", s == 200 and b.get("status") == "stopped", b)
passed = sum(1 for _, ok in results if ok)
print("SUMMARY %d/%d passed" % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
