#!/usr/bin/python3 -I
"""One request to browserd, for `docker exec -i <container> ctl.py`.

Reads one JSON request on stdin, sends it to the daemon's unix socket
/tmp/muse/ctl.sock, prints the daemon's one-line JSON reply. While the
container is starting (no socket yet) it waits up to 30 s. Exit status 0
when a reply was printed, 3 when the daemon could not be reached.

With --embedded (the browser inside a desktop computer, muse
muse_browser_docker): nothing runs until the first request, which starts
`init.sh --embedded` detached (once: a lock in /tmp serialises concurrent
first requests) and then waits for its socket like above. With
--if-running nothing is started or waited for: an unreachable daemon is
answered at once (exit 3).
"""
import fcntl
import json
import os
import socket
import subprocess
import sys
import time

SOCKET = os.environ.get("MUSE_CTL_SOCKET", "/tmp/muse/ctl.sock")
INIT = "/opt/muse-browser/init.sh"
START_LOCK = "/tmp/muse-browser-start.lock"


def reachable():
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(SOCKET)
        return True
    except OSError:
        return False
    finally:
        conn.close()


def start_embedded():
    """Start the embedded browser unless its daemon answers already."""
    with open(START_LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if reachable():
            return
        marker = "/tmp/muse-browser-started"
        if os.path.exists(marker):
            # started recently and still coming up: just wait for it
            try:
                if time.time() - os.path.getmtime(marker) < 30:
                    return
            except OSError:
                pass
        with open(marker, "w"):
            pass
        subprocess.Popen(["/bin/sh", INIT, "--embedded"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)


def main():
    request = sys.stdin.buffer.read()
    try:
        json.loads(request)
    except ValueError:
        print(json.dumps({"ok": False, "status": 400, "code": "INVALID_REQUEST",
                          "message": "A JSON request is required."}))
        return 0
    if "--if-running" in sys.argv[1:] and not reachable():
        # muse closing a window it moved elsewhere: nothing to close
        print(json.dumps({"ok": False, "status": 503, "code": "BROWSER_NOT_RUNNING",
                          "message": "The browser is not running."}))
        return 3
    if "--embedded" in sys.argv[1:] and not reachable():
        start_embedded()
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
