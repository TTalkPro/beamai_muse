#!/usr/bin/python3 -I
"""Egress rules and the egress proxy of the browser image.

The rules are a port of the Playwright worker's network.ts (OpenMuse
browser worker), unchanged: only http/https, no credentials in the URL,
ports 80 and 443 only, no localhost/.local/.internal/.home/.lan names, and
every address the name resolves to must be global unicast (private,
loopback, link-local (cloud metadata 169.254.169.254), CGNAT, multicast,
documentation, benchmarking and transition ranges are refused).

The proxy (`egress.py proxy PORT`) carries all of the browser's HTTP(S) and
WebSocket traffic (policy ProxySettings, bypass list `<-loopback>` so even
loopback goes through it; proxied names are resolved here, not by the
browser). WebRTC's UDP (STUN/DTLS) is not proxied: the browser keeps its
default WebRTC behaviour, like a normal browser. It accepts
plain HTTP requests in absolute form and CONNECT tunnels to ports 443 and
80 (WebSockets), resolves the name once, checks every address, and connects
to the checked address, so DNS rebinding between check and connect is not
possible. It also serves the extension's update manifest and CRX at
http://muse-browser.invalid/ext/ (policy force-install) from local files,
without any network access.
"""
import asyncio
import ipaddress
import os
import re
import socket
import sys
import time
from urllib.parse import urlsplit

DNS_TIMEOUT = 5.0
EXT_HOST = "muse-browser.invalid"
EXT_DIR = os.environ.get("MUSE_EXT_DIR", "/opt/muse-browser/ext")
LOG_PATH = os.environ.get("MUSE_EGRESS_LOG", "/tmp/muse/egress.log")
BLOCKED_NAME = re.compile(r"(^|\.)(localhost|local|internal|home|lan)$")
BLOCKED_MESSAGE = "Only public HTTP(S) destinations on ports 80 and 443 are allowed."


class Blocked(Exception):
    code = "BLOCKED_URL"
    status = 400

    def __init__(self, message=BLOCKED_MESSAGE):
        super().__init__(message)


class DnsUnavailable(Exception):
    code = "DNS_UNAVAILABLE"
    status = 502

    def __init__(self, message="The destination could not be resolved."):
        super().__init__(message)


def is_public_ip(address):
    """network.ts isPublicIp: a conservative global-unicast allowlist."""
    if "%" in address:
        return False
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if ip.version == 4:
        a, b, c, _ = ip.packed
        return not (
            a == 0 or a == 10 or a == 127 or a >= 224
            or (a == 100 and 64 <= b <= 127)
            or (a == 169 and b == 254)
            or (a == 172 and 16 <= b <= 31)
            or (a == 192 and (b == 168 or (b == 0 and c in (0, 2)) or (b == 88 and c == 99)))
            or (a == 198 and (b in (18, 19) or (b == 51 and c == 100)))
            or (a == 203 and b == 0 and c == 113)
        )
    if "." in address:  # IPv4-mapped or -compatible text forms
        return False
    words = [int.from_bytes(ip.packed[i:i + 2], "big") for i in range(0, 16, 2)]
    first, second = words[0], words[1]
    return (
        0x2000 <= first <= 0x3FFF
        and not (first == 0x2001 and (second < 0x200 or second == 0xDB8))
        and first != 0x2002
        and not (first == 0x3FFF and second < 0x1000)
    )


def resolve(hostname, timeout=DNS_TIMEOUT):
    """All addresses of `hostname` (A and AAAA), or DnsUnavailable."""
    result = {}

    def lookup():
        try:
            result["value"] = socket.getaddrinfo(hostname, None, proto=socket.IPPROTO_TCP)
        except OSError as error:
            result["error"] = error

    import threading
    worker = threading.Thread(target=lookup, daemon=True)
    worker.start()
    worker.join(timeout)
    if "value" not in result:
        raise DnsUnavailable()
    seen = []
    for family, _, _, _, sockaddr in result["value"]:
        entry = (sockaddr[0], 4 if family == socket.AF_INET else 6)
        if entry not in seen:
            seen.append(entry)
    return seen


def host_of(value):
    """The URL's scheme, hostname (brackets and trailing dot removed,
    lowercase), port (None when absent) and whether it carries credentials."""
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError:
        raise Blocked()
    hostname = (parts.hostname or "").rstrip(".").lower()
    return parts.scheme.lower(), hostname, port, bool(parts.username or parts.password)


def validate_url(value, resolver=resolve):
    """network.ts validatePublicUrl: `(hostname, port, address, family)` of a
    public http(s) URL, or Blocked / DnsUnavailable."""
    if not isinstance(value, str) or len(value) > 8192 or any(c in value for c in "\r\n\t\0 "):
        raise Blocked()
    scheme, hostname, port, credentials = host_of(value)
    if scheme not in ("http", "https") or credentials:
        raise Blocked()
    if port is not None and port not in (80, 443):
        raise Blocked()
    return check_host(hostname, port or (443 if scheme == "https" else 80), resolver)


def check_host(hostname, port, resolver=resolve):
    if not hostname or BLOCKED_NAME.search(hostname):
        raise Blocked()
    try:
        ipaddress.ip_address(hostname)
        literal = True
    except ValueError:
        literal = False
    if literal:
        addresses = [(hostname, 6 if ":" in hostname else 4)]
    else:
        if not hostname.isascii():
            try:
                hostname = hostname.encode("idna").decode("ascii")
            except UnicodeError:
                raise Blocked()
        if not re.fullmatch(r"[a-z0-9_.-]{1,253}", hostname):
            # IDNs arrive punycoded from Chrome; anything else is not a name
            raise Blocked()
        addresses = resolver(hostname)
    if not addresses or any(not is_public_ip(address) for address, _ in addresses):
        raise Blocked()
    selected = next((entry for entry in addresses if entry[1] == 4), addresses[0])
    return hostname, port, selected[0], selected[1]


# ---------------------------------------------------------------- proxy

def log(*parts):
    try:
        with open(LOG_PATH, "a") as handle:
            handle.write(time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts) + "\n")
    except OSError:
        pass


async def read_head(reader, limit=65536):
    data = await reader.readuntil(b"\r\n\r\n")
    if len(data) > limit:
        raise ValueError("header too large")
    return data


IDLE = 300  # seconds without data before a connection is dropped


async def pipe(reader, writer):
    try:
        while True:
            chunk = await asyncio.wait_for(reader.read(65536), IDLE)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError, asyncio.TimeoutError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def checked(hostname, port):
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, check_host, hostname, port)


async def refuse(writer, status=403, reason="Forbidden", body=b"Destination blocked"):
    writer.write(b"HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n"
                 b"Connection: close\r\nProxy-Connection: close\r\n\r\n%s"
                 % (status, reason.encode(), len(body), body))
    try:
        await writer.drain()
    finally:
        writer.close()


async def serve_extension(path, writer):
    name = os.path.basename(path.split("?", 1)[0])
    full = os.path.join(EXT_DIR, name)
    if name not in ("update.xml", "muse.crx") or not os.path.isfile(full):
        return await refuse(writer, 404, "Not Found", b"not found")
    with open(full, "rb") as handle:
        body = handle.read()
    kind = b"text/xml" if name.endswith(".xml") else b"application/x-chrome-extension"
    writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
                 b"Cache-Control: no-store\r\nConnection: close\r\n\r\n" % (kind, len(body)) + body)
    await writer.drain()
    writer.close()


async def handle(reader, writer):
    try:
        head = await asyncio.wait_for(read_head(reader), 30)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError,
            ValueError, ConnectionError):
        writer.close()
        return
    lines = head.decode("latin-1").split("\r\n")
    try:
        method, target, version = lines[0].split(" ")
    except ValueError:
        return await refuse(writer, 400, "Bad Request", b"bad request")
    if method == "CONNECT":
        return await tunnel(target, reader, writer)
    return await forward(method, target, version, lines[1:], reader, writer)


async def tunnel(authority, reader, writer):
    match = re.fullmatch(r"(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):(443|80)", authority)
    try:
        if not match:
            raise Blocked()
        hostname = match.group(1).strip("[]").rstrip(".").lower()
        _, port, address, _ = await checked(hostname, int(match.group(2)))
    except (Blocked, DnsUnavailable) as error:
        log("blocked CONNECT", authority, error.code)
        return await refuse(writer)
    try:
        up_reader, up_writer = await asyncio.wait_for(asyncio.open_connection(address, port), 20)
    except (OSError, asyncio.TimeoutError):
        return await refuse(writer, 502, "Bad Gateway", b"upstream unreachable")
    writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    await writer.drain()
    await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))


async def forward(method, target, version, header_lines, reader, writer):
    scheme, hostname, port, credentials = None, "", None, False
    try:
        scheme, hostname, port, credentials = host_of(target)
    except Blocked:
        pass
    if scheme == "http" and hostname == EXT_HOST and method == "GET":
        return await serve_extension(urlsplit(target).path, writer)
    try:
        if scheme != "http" or credentials:
            raise Blocked()
        if port is not None and port not in (80, 443):
            raise Blocked()
        _, port, address, _ = await checked(hostname, port or 80)
    except (Blocked, DnsUnavailable) as error:
        log("blocked", method, target[:200], error.code)
        return await refuse(writer)
    parts = urlsplit(target)
    path = (parts.path or "/") + (("?" + parts.query) if parts.query else "")
    headers = []
    for line in header_lines:
        if not line:
            continue
        name = line.split(":", 1)[0].strip().lower()
        if name in ("proxy-connection", "proxy-authorization", "connection", "keep-alive", "host"):
            continue
        headers.append(line)
    host_header = hostname if port == 80 else "%s:%d" % (hostname, port)
    request = "\r\n".join(["%s %s %s" % (method, path, version), "Host: " + host_header]
                           + headers + ["Connection: close"]) + "\r\n\r\n"
    try:
        up_reader, up_writer = await asyncio.wait_for(asyncio.open_connection(address, port), 20)
    except (OSError, asyncio.TimeoutError):
        return await refuse(writer, 502, "Bad Gateway", b"upstream unreachable")
    up_writer.write(request.encode("latin-1"))
    await up_writer.drain()
    sender = asyncio.ensure_future(pipe(reader, up_writer))
    try:
        response_head = await asyncio.wait_for(read_head(up_reader), 60)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError,
            ValueError, ConnectionError):
        sender.cancel()
        up_writer.close()
        return await refuse(writer, 502, "Bad Gateway", b"bad upstream response")
    # one request per connection on both sides: the client must not reuse
    # this connection for another destination
    rlines = [l for l in response_head.decode("latin-1").split("\r\n") if l]
    kept = [l for l in rlines[1:] if l.split(":", 1)[0].strip().lower()
            not in ("connection", "proxy-connection", "keep-alive")]
    writer.write(("\r\n".join([rlines[0]] + kept + ["Connection: close", "Proxy-Connection: close"])
                  + "\r\n\r\n").encode("latin-1"))
    await pipe(up_reader, writer)
    sender.cancel()
    up_writer.close()


def serve(port):
    async def main():
        server = await asyncio.start_server(handle, "127.0.0.1", port, limit=65536)
        log("egress proxy listening on 127.0.0.1:%d" % port)
        async with server:
            await server.serve_forever()
    asyncio.run(main())


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "proxy":
        serve(int(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        try:
            print(validate_url(sys.argv[2]))
        except (Blocked, DnsUnavailable) as error:
            print(error.code, error)
            sys.exit(1)
    else:
        sys.exit("usage: egress.py proxy PORT | egress.py check URL")
