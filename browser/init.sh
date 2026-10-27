#!/bin/sh
# Entry point of the browser image (docker-init/tini is PID 1 via --init),
# and, with --embedded, the browser inside a desktop computer (see below).
#
# Starts a 1440x900 virtual display (:0, local socket only), openbox (every
# window at 0,0, undecorated), the egress proxy on 127.0.0.1:8118, browserd
# and Chromium with the persistent profile on the /data volume. Chromium
# is restarted when it exits; its sessions are then gone and the server
# re-opens each one at its last URL on next use.
#
# Works on a read-only root filesystem: sockets, logs and the X lock live in
# /tmp (tmpfs), HOME, the profile and downloads on /data. No CDP: no
# --remote-debugging-*, no --enable-automation. Otherwise a normal browser:
# the managed policy (policies.json) only force-installs the bridge
# extension, sets the egress proxy and the download folder; the flags below
# only skip first-run UI, keep occluded session windows running and use the
# basic password store (no keyring in the container).
# The Chrome sandbox stays on (user namespaces; see the seccomp profile).
#
# --embedded (the desktop computer image; ctl.py --embedded starts it on the
# first browser request, detached): the desktop's own Xvfb and openbox are
# used, the data (profile, per-session files) lives in the computer's
# /workspace/.muse-browser, downloads go to /workspace/Downloads, and each
# session window fills the desktop's screen (browserd layout `screen`: the
# page area is what the window leaves, not 1280x800).
set -u
umask 077
EMBEDDED=false
[ "${1:-}" = "--embedded" ] && EMBEDDED=true
export DISPLAY=:0
RUN=/tmp/muse
if $EMBEDDED; then
    DATA=/workspace/.muse-browser
    export MUSE_DATA_DIR=$DATA MUSE_DOWNLOADS_DIR=/workspace/Downloads MUSE_BROWSER_LAYOUT=screen
    # the browser's language and time zone (the computer's shell keeps its own)
    export LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh TZ=Asia/Shanghai
    mkdir -p "$MUSE_DOWNLOADS_DIR"
else
    DATA=/data
    export MUSE_DATA_DIR=$DATA MUSE_DOWNLOADS_DIR=$DATA/downloads MUSE_BROWSER_LAYOUT=viewport
fi
export HOME=$DATA/home
mkdir -p "$RUN" "$DATA/home" "$DATA/profile" "$MUSE_DOWNLOADS_DIR" "$DATA/sessions"
chmod 700 "$RUN" "$DATA/sessions"
$EMBEDDED || chmod 700 "$MUSE_DOWNLOADS_DIR"

children=""
stop() {
    # shellcheck disable=SC2086
    kill $children ${chrome:-} 2>/dev/null
    exit 0
}
trap stop TERM INT

if ! $EMBEDDED; then
    mkdir -p -m 1777 /tmp/.X11-unix
    Xvfb :0 -screen 0 1440x900x24 -nolisten tcp -dpi 96 </dev/null >"$RUN/xvfb.log" 2>&1 &
    children="$children $!"
fi
i=0
while [ "$i" -lt 100 ]; do
    xdpyinfo -display :0 >/dev/null 2>&1 && break
    sleep 0.1
    i=$((i + 1))
done
# the screen browserd lays windows out on (and clips the live view to)
MUSE_SCREEN=$(xdpyinfo -display :0 2>/dev/null | sed -n 's/^ *dimensions: *\([0-9]*x[0-9]*\) .*/\1/p' | head -1)
export MUSE_SCREEN=${MUSE_SCREEN:-1440x900}
if $EMBEDDED; then
    WINDOW=$(echo "$MUSE_SCREEN" | tr x ,)
else
    WINDOW=1280,890
    openbox --config-file /opt/muse-browser/openbox.xml --sm-disable </dev/null >"$RUN/openbox.log" 2>&1 &
    children="$children $!"
fi
python3 -I /opt/muse-browser/egress.py proxy 8118 </dev/null >"$RUN/egress.err" 2>&1 &
children="$children $!"
python3 -I /opt/muse-browser/browserd.py </dev/null >"$RUN/browserd.err" 2>&1 &
children="$children $!"

PROFILE=$DATA/profile
while :; do
    # One container per profile: a lock left by a previous container (another
    # hostname) would make Chrome refuse the profile. A killed browser is not
    # a crash to restore from.
    rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"
    [ -f "$PROFILE/Default/Preferences" ] && sed -i \
        's/"exit_type":"Crashed"/"exit_type":"Normal"/; s/"exited_cleanly":false/"exited_cleanly":true/' \
        "$PROFILE/Default/Preferences"
    # --enable-remote-extensions: without it Debian's wrapper adds
    # --disable-background-networking and --disable-extensions-except, so
    # the policy's force-install would never be fetched (see Dockerfile).
    chromium --enable-remote-extensions --user-data-dir="$PROFILE" \
        --no-first-run --no-default-browser-check --password-store=basic --hide-crash-restore-bubble \
        --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
        --disable-background-timer-throttling \
        --ignore-gpu-blocklist --lang=zh-CN \
        --window-position=0,0 --window-size="$WINDOW" \
        about:blank </dev/null >>"$RUN/chrome.log" 2>&1 &
    chrome=$!
    wait "$chrome"
    echo "chrome exited $? at $(date)" >>"$RUN/chrome.log"
    sleep 1
done
