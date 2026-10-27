# Browser image (BROWSER_ENABLED=true): one per user, started by
# muse_browser_docker. A real, headful Chromium (Debian's package, from
# apt: bookworm-security carries the current stable) on a virtual X display,
# driven without CDP: an MV3 extension (force-installed by managed policy)
# talks to the in-container daemon through native messaging, and
# xdotool provides OS-level mouse and keyboard input. All web traffic goes
# through the in-container egress proxy (public addresses only). The
# console's live view is x11vnc in inetd mode (behind a socketpair relay), started per viewer with
# `docker exec -i` (muse_docker:vnc_args/2): no port is opened.
# See browser/README.md and designs/04-integrations.md §4.
#
# Build: make browser-image (tag muse-browser:local).
FROM debian:bookworm-slim

# /usr/bin/chromium is Debian's wrapper: it sources /etc/chromium.d (the
# API keys, so no "Google API keys are missing" bar; default flags) and
# execs the browser. chromium-l10n carries the UI locales (Debian's chromium
# has en-US only; without zh-CN, --lang=zh-CN falls back to English and so
# does the Accept-Language sites see). Its `extensions` hook (--enable-remote-extensions plus
# an empty --load-extension= for system-wide extensions) is removed: ours is
# force-installed by policy, and init.sh passes --enable-remote-extensions
# itself (without it the wrapper turns off background networking, so the
# extension updater would never fetch the policy's extension).
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates python3 python3-cryptography procps tzdata locales \
       chromium chromium-l10n \
       xvfb openbox xdotool xclip scrot x11-utils x11vnc \
       fonts-dejavu-core fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/chromium.d/extensions \
    && sed -i 's/^# *\(zh_CN.UTF-8\)/\1/; s/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && echo Asia/Shanghai > /etc/timezone \
    && useradd -m -u 1000 -s /bin/sh muse \
    && mkdir -p /opt/muse-browser/ext /data && chown 1000:1000 /data

COPY extension /opt/muse-browser/extension-src
COPY init.sh browserd.py egress.py native-host ctl.py crxpack.py openbox.xml policies.json native-host.json \
     /opt/muse-browser/

# The extension is packed here with a fresh key (thrown away in the same
# layer): the key only fixes the extension id, which the policy and the
# native host manifest name.
RUN cd /opt/muse-browser \
    && EXT_ID=$(python3 -I crxpack.py extension-src /tmp/ext.pem ext 1.0.0 http://muse-browser.invalid/ext) \
    && rm -f /tmp/ext.pem && rm -rf ext/unpacked \
    && mkdir -p /etc/chromium/policies/managed /etc/chromium/native-messaging-hosts \
    && sed "s/@EXT_ID@/$EXT_ID/g; s|@DOWNLOADS@|/data/downloads|" policies.json > /etc/chromium/policies/managed/muse.json \
    && sed "s/@EXT_ID@/$EXT_ID/g" native-host.json > /etc/chromium/native-messaging-hosts/dev.openmuse.browser.json \
    && rm policies.json native-host.json \
    && chmod 0555 init.sh browserd.py egress.py native-host ctl.py \
    && chmod -R a+rX /opt/muse-browser /etc/chromium

ENV HOME=/data/home LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh TZ=Asia/Shanghai DISPLAY=:0
WORKDIR /data
USER 1000:1000
VOLUME ["/data"]
ENTRYPOINT ["/opt/muse-browser/init.sh"]
