#!/usr/bin/python3 -I
"""One request to browserd, for `docker exec -i <container> ctl.py`.

Reads one JSON request on stdin, sends it to the daemon's unix socket
/tmp/muse/ctl.sock, prints the daemon's one-line JSON reply. While the
container is starting (no socket yet) it waits up to 30 s. Exit status 0
when a reply was printed, 3 when the daemon could not be reached.
"""
import json
import os
import socket
import sys
import time

SOCKET = os.environ.get("MUSE_CTL_SOCKET", "/tmp/muse/ctl.sock")


def main():
    request = sys.stdin.buffer.read()
    try:
        json.loads(request)
    except ValueError:
        print(json.dumps({"ok": False, "status": 400, "code": "INVALID_REQUEST",
                          "message": "A JSON request is required."}))
        return 0
    deadline = time.time() + 30
    while True:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.connect(SOCKET)
            break
        except OSError:
            conn.close()
            if time.time() > deadline:
                print(json.dumps({"ok": False, "status": 503, "code": "BROWSER_STARTING",
                                  "message": "The browser is not ready yet. Try again in a moment."}))
                return 3
            time.sleep(0.2)
    conn.sendall(request.strip() + b"\n")
    with conn.makefile("rb") as reply:
        line = reply.readline()
    if not line:
        print(json.dumps({"ok": False, "status": 503, "code": "BROWSER_UNAVAILABLE",
                          "message": "The browser daemon closed the connection."}))
        return 3
    sys.stdout.buffer.write(line)
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
