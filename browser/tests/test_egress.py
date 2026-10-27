"""Unit tests of browser/egress.py (the egress rules and proxy) and of the
pure parts of browserd.py. Run: python3 -m unittest discover -s browser/tests
(scripts/check.sh does). No Chrome, Docker or network needed."""
import asyncio
import http.server
import os
import socket
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
os.environ.setdefault("MUSE_EGRESS_LOG", os.path.join(tempfile.mkdtemp(), "egress.log"))
import egress  # noqa: E402
import browserd  # noqa: E402


def resolver(table):
    def resolve(hostname):
        if hostname not in table:
            raise egress.DnsUnavailable()
        return [(a, 6 if ":" in a else 4) for a in table[hostname]]
    return resolve


class PublicIp(unittest.TestCase):
    def test_v4(self):
        for blocked in ["0.0.0.0", "10.1.2.3", "127.0.0.1", "127.255.255.254", "169.254.169.254",
                        "172.16.0.1", "172.31.255.255", "192.168.3.13", "100.64.0.1", "100.127.1.1",
                        "192.0.0.8", "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.19.255.1",
                        "198.51.100.7", "203.0.113.9", "224.0.0.1", "239.1.1.1", "255.255.255.255"]:
            self.assertFalse(egress.is_public_ip(blocked), blocked)
        for public in ["1.1.1.1", "8.8.8.8", "93.184.215.14", "172.15.0.1", "172.32.0.1",
                       "100.63.0.1", "100.128.0.1", "192.169.0.1", "169.253.1.1"]:
            self.assertTrue(egress.is_public_ip(public), public)

    def test_v6(self):
        for blocked in ["::1", "::", "fe80::1", "fc00::1", "fd12::1", "ff02::1", "::ffff:127.0.0.1",
                        "::ffff:8.8.8.8", "64:ff9b::1", "2001:db8::1", "2001::1", "2002::1",
                        "3fff::1", "fe80::1%eth0", "not-an-ip"]:
            self.assertFalse(egress.is_public_ip(blocked), blocked)
        for public in ["2606:4700:4700::1111", "2001:4860:4860::8888", "2a00:1450::1"]:
            self.assertTrue(egress.is_public_ip(public), public)


class ValidateUrl(unittest.TestCase):
    table = {"example.com": ["93.184.215.14"], "rebind.test": ["93.184.215.14", "127.0.0.1"],
             "v6.test": ["2606:4700:4700::1111"], "meta.test": ["169.254.169.254"],
             "xn--fsqu00a.xn--0zwm56d": ["93.184.215.14"]}

    def check(self, url):
        return egress.validate_url(url, resolver(self.table))

    def test_allowed(self):
        self.assertEqual(("example.com", 443, "93.184.215.14", 4), self.check("https://example.com/a?b#c"))
        self.assertEqual(("example.com", 80, "93.184.215.14", 4), self.check("http://EXAMPLE.com./"))
        self.assertEqual(("example.com", 443, "93.184.215.14", 4), self.check("https://example.com:443/"))
        self.assertEqual(("v6.test", 80, "2606:4700:4700::1111", 6), self.check("http://v6.test/"))
        self.assertEqual("93.184.215.14", self.check("http://例子.测试/")[2])
        self.assertEqual("8.8.8.8", self.check("https://8.8.8.8/")[2])

    def test_blocked(self):
        for url in ["http://127.0.0.1/", "http://127.0.0.1:8118/", "http://192.168.3.13/",
                    "http://169.254.169.254/latest/meta-data/", "http://meta.test/", "http://rebind.test/",
                    "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://localhost/", "http://a.localhost/",
                    "http://printer.local/", "http://x.internal/", "http://router.lan/", "http://nas.home/",
                    "https://example.com:8443/", "http://example.com:22/", "ftp://example.com/",
                    "file:///etc/passwd", "view-source:https://example.com/", "data:text/html,hi",
                    "javascript:alert(1)", "chrome://version", "chrome-extension://abc/x.html",
                    "about:blank", "https://user:pw@example.com/", "https://user@example.com/",
                    "http:///", "not a url", "http://exa mple.com/", "http://example.com/\r\nX: y",
                    "", None, 42]:
            with self.assertRaises(egress.Blocked, msg=repr(url)):
                self.check(url)

    def test_dns_failure(self):
        with self.assertRaises(egress.DnsUnavailable):
            self.check("https://unknown.test/")


class Fixture(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        Fixture.seen.append((self.path, self.headers.get("Host"), self.headers.get("Connection")))
        body = b"fixture ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True  # the header said keep-alive; the proxy must not

    def log_message(self, *a):
        pass


class Proxy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        threading.Thread(target=cls.fixture.serve_forever, daemon=True).start()
        cls.fixture_port = cls.fixture.server_address[1]
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        cls.port = sock.getsockname()[1]
        sock.close()
        cls.ext = tempfile.mkdtemp()
        with open(os.path.join(cls.ext, "update.xml"), "w") as handle:
            handle.write("<gupdate/>")
        egress.EXT_DIR = cls.ext
        original = egress.check_host

        cls.original = original

        def check_host(hostname, port, resolver=egress.resolve):
            # "public.test" stands for a public site: the fixture
            if hostname == "public.test":
                return hostname, port, "127.0.0.1", 4
            return original(hostname, port, resolver)
        egress.check_host = check_host
        cls.loop = asyncio.new_event_loop()

        def run():
            asyncio.set_event_loop(cls.loop)
            server = cls.loop.run_until_complete(asyncio.start_server(egress.handle, "127.0.0.1", cls.port))
            cls.server = server
            cls.loop.run_forever()
        threading.Thread(target=run, daemon=True).start()
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 1).close()
                break
            except OSError:
                time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        egress.check_host = cls.original

    def send(self, raw):
        with socket.create_connection(("127.0.0.1", self.port), 5) as conn:
            conn.sendall(raw)
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            return data

    def test_blocked_destinations_never_reached(self):
        Fixture.seen.clear()
        for target in ["http://127.0.0.1:%d/x" % self.fixture_port, "http://127.0.0.1/x",
                       "http://localhost/x", "http://169.254.169.254/latest/meta-data/",
                       "http://192.168.3.13/", "http://[::1]/", "https://127.0.0.1/"]:
            reply = self.send(b"GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % target.encode())
            self.assertTrue(reply.startswith(b"HTTP/1.1 403"), (target, reply[:60]))
        for authority in ["127.0.0.1:443", "192.168.3.13:443", "169.254.169.254:443", "localhost:443",
                          "public.test:22", "[::1]:443", "127.0.0.1:%d" % self.fixture_port]:
            reply = self.send(b"CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (authority.encode(), authority.encode()))
            self.assertTrue(reply.startswith(b"HTTP/1.1 403"), (authority, reply[:60]))
        self.assertEqual([], Fixture.seen)

    def test_connect_tunnel(self):
        Fixture.seen.clear()
        port = self.fixture_port
        original = egress.check_host
        egress.check_host = lambda h, p, r=None: (h, port, "127.0.0.1", 4) if h == "public.test" else original(h, p)
        try:
            with socket.create_connection(("127.0.0.1", self.port), 5) as conn:
                conn.sendall(b"CONNECT public.test:443 HTTP/1.1\r\nHost: public.test:443\r\n\r\n")
                self.assertTrue(conn.recv(100).startswith(b"HTTP/1.1 200"))
                conn.sendall(b"GET /tunnel HTTP/1.1\r\nHost: public.test\r\nConnection: close\r\n\r\n")
                data = b""
                while not data.endswith(b"fixture ok"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
        finally:
            egress.check_host = original
        self.assertTrue(data.endswith(b"fixture ok"), data)
        self.assertEqual("/tunnel", Fixture.seen[0][0])

    def test_http_forward(self):
        Fixture.seen.clear()
        port = self.fixture_port
        original = egress.check_host
        egress.check_host = lambda h, p, r=None: (h, port, "127.0.0.1", 4) if h == "public.test" else original(h, p)
        try:
            reply = self.send(b"GET http://public.test/page?q=1 HTTP/1.1\r\nHost: public.test\r\n"
                              b"Proxy-Connection: keep-alive\r\nProxy-Authorization: secret\r\n\r\n")
        finally:
            egress.check_host = original
        self.assertTrue(reply.startswith(b"HTTP/1.0 200") or reply.startswith(b"HTTP/1.1 200"), reply[:80])
        self.assertIn(b"Connection: close", reply)
        self.assertNotIn(b"keep-alive", reply.split(b"\r\n\r\n")[0])
        self.assertTrue(reply.endswith(b"fixture ok"))
        self.assertEqual([("/page?q=1", "public.test:%d" % port, "close")], Fixture.seen)

    def test_extension_files(self):
        reply = self.send(b"GET http://muse-browser.invalid/ext/update.xml HTTP/1.1\r\nHost: muse-browser.invalid\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 200"))
        self.assertTrue(reply.endswith(b"<gupdate/>"))
        reply = self.send(b"GET http://muse-browser.invalid/ext/../../etc/passwd HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 404"))


class Daemon(unittest.TestCase):
    def test_input_validation(self):
        ok = [{"type": "click", "x": 0, "y": 0}, {"type": "click", "x": 1279.5, "y": 799},
              {"type": "text", "text": "北京"}, {"type": "key", "key": "Shift+Tab"},
              {"type": "key", "key": "Control+a"}, {"type": "scroll", "deltaY": -5000}]
        for value in ok:
            self.assertEqual(value, browserd.valid_input(value))
        bad = [None, [], {"type": "click", "x": 1280, "y": 1}, {"type": "click", "x": -1, "y": 1},
               {"type": "click", "x": True, "y": 1}, {"type": "click", "x": float("nan"), "y": 1},
               {"type": "text", "text": "x" * 10001}, {"type": "key", "key": "F5"},
               {"type": "key", "key": "ctrl+w"}, {"type": "scroll", "deltaY": 5001}, {"type": "eval"}]
        for value in bad:
            with self.assertRaises(browserd.OpError, msg=repr(value)):
                browserd.valid_input(value)

    def test_keys_map_to_xdotool(self):
        self.assertEqual("Return", browserd.KEYS["Enter"])
        self.assertEqual("ctrl+a", browserd.KEYS["Meta+a"])
        self.assertEqual("Prior", browserd.KEYS["PageUp"])

    def test_text_runs(self):
        self.assertEqual([(True, "ab "), (False, "北京"), (True, " c\nd"), (False, "😀")],
                         browserd.runs("ab 北京 c\nd😀"))

    def test_viewport_mapping(self):
        view = browserd.Viewport({"window": {"left": 0, "top": 0, "width": 1288, "height": 892},
                                  "tab": {"width": 1280, "height": 800}})
        self.assertEqual((4, 88), (view.left, view.top))
        self.assertEqual((604, 581), view.screen(600, 493))
        self.assertTrue(view(4, 88))
        self.assertFalse(view(3, 88))
        self.assertFalse(view(1284, 500))


class ConnectUpstream(unittest.TestCase):
    """connect_upstream retries an unanswered or refused connect with a new
    connection, and gives up after three attempts."""

    def run_connect(self, outcomes, timeout=0.2):
        calls = []
        real = asyncio.open_connection

        async def fake(address, port):
            outcome = outcomes[min(len(calls), len(outcomes) - 1)]
            calls.append((address, port))
            if outcome == "hang":
                await asyncio.sleep(10)
            if outcome == "refused":
                raise ConnectionRefusedError(111, "refused")
            return ("reader", "writer")

        asyncio.open_connection = fake
        try:
            result = asyncio.run(egress.connect_upstream("example.org", "203.0.113.7", 443, timeout=timeout))
        except BaseException as error:
            result = error
        finally:
            asyncio.open_connection = real
        return result, calls

    def test_unanswered_then_connects(self):
        result, calls = self.run_connect(["hang", "ok"])
        self.assertEqual(result, ("reader", "writer"))
        self.assertEqual(len(calls), 2)

    def test_refused_then_connects(self):
        result, calls = self.run_connect(["refused", "refused", "ok"])
        self.assertEqual(result, ("reader", "writer"))
        self.assertEqual(len(calls), 3)

    def test_gives_up_after_three(self):
        result, calls = self.run_connect(["hang"])
        self.assertIsInstance(result, asyncio.TimeoutError)
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
