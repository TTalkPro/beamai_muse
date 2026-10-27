"""End-to-end acceptance checks over HTTP (see scripts/acceptance.sh)."""
import re, json, os, sys, time, urllib.request, urllib.error, http.cookiejar, hashlib
BASE = sys.argv[1]
def req(method, path, body=None, token=None, raw=False, headers=None, url=None, data=None):
    h = {"Origin": BASE}
    if token: h["Authorization"] = "Bearer " + token
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
# --- browser (the user's real Chrome container: extension + xdotool, no CDP) ---
s, b, _ = req("POST", "/api/browsers", {"url": "https://example.com"}, T)
check("open example.com in real Chrome", s == 201 and b.get("status") == "active", (s, b if s != 201 else b.get("title")))
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
# navigation takes a moment; the browser answers an error while it is under way
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
# the egress proxy refuses private and loopback destinations
for blocked in ["http://127.0.0.1:%d/" % int(BASE.rsplit(":", 1)[1]), "http://169.254.169.254/latest/meta-data/"]:
    s, b, _ = req("POST", "/api/browsers", {"url": blocked}, T)
    check("blocked destination " + blocked, s >= 400 or (isinstance(b, dict) and b.get("status") != "active"), (s, b))
# --- Docker computer (desktop variant): every conversation has its own ---
s, th, _ = req("POST", "/api/threads", {"title": "acceptance computer"}, T)
check("create a conversation", s == 201, (s, th))
C = "?thread=" + th["id"]
s, b, _ = req("GET", "/api/computer", None, T)
check("no default computer", s == 400, (s, b))
s, b, _ = req("POST", "/api/computer/start" + C, None, T)
check("start desktop computer", s == 200 and b.get("status") == "running", (s, b))
s, b, _ = req("POST", "/api/computer/commands" + C, {"command": "ls -la /workspace && echo DISPLAY=$DISPLAY"}, T)
check("run ls /workspace", s == 200 and b.get("exitCode") == 0 and "DISPLAY=:0" in b.get("stdout", ""), (b.get("exitCode"), b.get("stdout", "")[-80:]))
s, b, _ = req("POST", "/api/computer/files/write" + C, {"path": "/workspace/accept.txt", "text": "你好 acceptance\n"}, T)
check("write file", s == 200, b)
s, b, _ = req("POST", "/api/computer/files/read" + C, {"path": "/workspace/accept.txt"}, T)
check("read file back", s == 200 and b.get("text") == "你好 acceptance\n", b)
s, b, _ = req("GET", "/api/computer/desktop" + C, None, T)
check("desktop status", s == 200, b)
s, b, _ = req("POST", "/api/computer/desktop/actions" + C, {"action": "screenshot"}, T)
check("desktop screenshot action", s == 200 and b.get("receipt", {}).get("status") == "succeeded", (s, b if s != 200 else b.get("receipt", {}).get("command")))
s, b, _ = req("POST", "/api/computer/desktop/actions" + C, {"action": "key", "text": "shift exec touch x"}, T)
check("xdotool command injection refused", s == 422, (s, b))
s, html, _ = req("GET", "/computer", None, None, raw=True, headers={"Cookie": "muse_session=" + T})
m = re.search(rb'href="/computer/([0-9a-f]{16})"', html)
check("UI computer list shows the conversation's computer", s == 200 and m is not None and "acceptance computer".encode() in html, s)
cid = m.group(1).decode() if m else "none"
cookie_h = {"Cookie": "muse_session=" + T}
s, html, _ = req("GET", "/computer/" + cid, None, None, raw=True, headers=cookie_h)
check("UI computer page: read-only desktop, no terminal", s == 200 and b"comp-desktop-shot" in html and b"comp-term" not in html, s)
s, data, hd = req("GET", "/computer-files/%s/download?path=%%2Fworkspace%%2Faccept.txt" % cid, None, None, raw=True, headers=cookie_h)
check("download a workspace file", s == 200 and data == "你好 acceptance\n".encode() and "attachment" in (hd.get("content-disposition") or ""), (s, data[:60]))
boundary = "acceptb0undary"
blob = bytes(range(256)) * 8
mp = (("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"blob.bin\"\r\n"
       "Content-Type: application/octet-stream\r\n\r\n") % boundary).encode() + blob + ("\r\n--%s--\r\n" % boundary).encode()
s, b, _ = req("POST", "/computer-files/%s/upload?dir=%%2Fworkspace" % cid, None, None, raw=True,
              headers=dict(cookie_h, **{"Content-Type": "multipart/form-data; boundary=" + boundary}), data=mp)
check("upload a binary file", s == 201, (s, b[:120]))
s, data, _ = req("GET", "/computer-files/%s/download?path=%%2Fworkspace%%2Fblob.bin" % cid, None, None, raw=True, headers=cookie_h)
check("uploaded bytes come back intact", s == 200 and data == blob, (s, len(data)))
s, b, _ = req("POST", "/api/computer/stop" + C, None, T)
check("stop computer", s == 200 and b.get("status") == "stopped", b)
passed = sum(1 for _, ok in results if ok)
print("SUMMARY %d/%d passed" % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
