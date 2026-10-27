#!/bin/sh
# Entry point of the browser image (docker-init/tini is PID 1 via --init).
#
# Starts a 1440x900 virtual display (:0, local socket only), openbox (every
# window at 0,0, undecorated), the egress proxy on 127.0.0.1:8118, browserd
# and Google Chrome with the persistent profile on the /data volume. Chrome
# is restarted when it exits; its sessions are then gone and the server
# re-opens each one at its last URL on next use.
#
# Works on a read-only root filesystem: sockets, logs and the X lock live in
# /tmp (tmpfs), HOME, the profile and downloads on /data. No CDP: no
# --remote-debugging-*, no --enable-automation, DevTools disabled by policy.
# The Chrome sandbox stays on (user namespaces; see the seccomp profile).
set -u
umask 077
export DISPLAY=:0 HOME=/data/home
RUN=/tmp/muse
mkdir -p "$RUN" /data/home /data/profile /data/downloads /data/sessions
chmod 700 "$RUN" /data/downloads /data/sessions

children=""
stop() {
    # shellcheck disable=SC2086
    kill $children ${chrome:-} 2>/dev/null
    exit 0
}
trap stop TERM INT

mkdir -p -m 1777 /tmp/.X11-unix
Xvfb :0 -screen 0 1440x900x24 -nolisten tcp -dpi 96 </dev/null >"$RUN/xvfb.log" 2>&1 &
children="$children $!"
i=0
while [ "$i" -lt 100 ]; do
    xdpyinfo -display :0 >/dev/null 2>&1 && break
    sleep 0.1
    i=$((i + 1))
done

openbox --config-file /opt/muse-browser/openbox.xml --sm-disable </dev/null >"$RUN/openbox.log" 2>&1 &
children="$children $!"
python3 -I /opt/muse-browser/egress.py proxy 8118 </dev/null >"$RUN/egress.err" 2>&1 &
children="$children $!"
python3 -I /opt/muse-browser/browserd.py </dev/null >"$RUN/browserd.err" 2>&1 &
children="$children $!"

PROFILE=/data/profile
while :; do
    # One container per profile: a lock left by a previous container (another
    # hostname) would make Chrome refuse the profile. A killed browser is not
    # a crash to restore from.
    rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"
    [ -f "$PROFILE/Default/Preferences" ] && sed -i \
        's/"exit_type":"Crashed"/"exit_type":"Normal"/; s/"exited_cleanly":false/"exited_cleanly":true/' \
        "$PROFILE/Default/Preferences"
    google-chrome-stable --user-data-dir="$PROFILE" \
        --no-first-run --no-default-browser-check --password-store=basic --hide-crash-restore-bubble \
        --disable-quic --force-webrtc-ip-handling-policy=disable_non_proxied_udp \
        --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" \
        --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
        --disable-background-timer-throttling \
        --ignore-gpu-blocklist --lang=zh-CN \
        --window-position=0,0 --window-size=1280,890 \
        about:blank </dev/null >>"$RUN/chrome.log" 2>&1 &
    chrome=$!
    wait "$chrome"
    echo "chrome exited $? at $(date)" >>"$RUN/chrome.log"
    sleep 1
done
