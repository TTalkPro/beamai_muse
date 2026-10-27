# Browser image (BROWSER_ENABLED=true): one per user, started by
# muse_browser_docker. A real, headful Firefox ESR (Debian's package) on a
# virtual X display, driven without any remote protocol (no Marionette,
# WebDriver BiDi or CDP): a WebExtension (force-installed by policy) talks to
# the in-container daemon through native messaging, and xdotool provides
# OS-level mouse and keyboard input. All web traffic goes through the
# in-container egress proxy (public addresses only). The console's live view
# is x11vnc in inetd mode (behind a socketpair relay), started per viewer
# with `docker exec -i` (muse_docker:vnc_args/2): no port is opened.
# Firefox, not Chromium (M13): sites such as WeChat's article pages send a
# fresh Chromium-family profile to a verification page and a fresh Firefox
# straight to the content. See browser/README.md and designs/04 §4.
#
# Build: make browser-image (tag muse-browser:local).
# Debian 13 (trixie), like the host: the same Mesa (25.0.7) and libpci3, so
# WebGL reads as on a normal browser there (Mesa llvmpipe on the host's
# VMware SVGA II, 15ad:0405).
FROM debian:trixie-slim

# firefox-esr-l10n-zh-cn: the zh-CN interface (and so its Accept-Language).
# Firefox's managed policy goes to the app's distribution/policies.json,
# default prefs to defaults/pref, the native messaging host manifest to
# /usr/lib/mozilla/native-messaging-hosts.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates python3 procps tzdata locales \
       firefox-esr firefox-esr-l10n-zh-cn libpci3 libgl1-mesa-dri \
       xvfb openbox xdotool xclip scrot x11-utils x11vnc \
       fonts-dejavu-core fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *\(zh_CN.UTF-8\)/\1/; s/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && echo Asia/Shanghai > /etc/timezone \
    && useradd -m -u 1000 -s /bin/sh muse \
    && mkdir -p /opt/muse-browser/ext /data && chown 1000:1000 /data

COPY extension /opt/muse-browser/extension-src
COPY init.sh browserd.py egress.py native-host ctl.py xpipack.py openbox.xml policies.json prefs.js \
     native-host.json /opt/muse-browser/

# The extension as an XPI with a fixed id in Firefox's system scope (unsigned
# is accepted there; see prefs.js), locked by the policy.
RUN cd /opt/muse-browser \
    && SYS=/usr/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384} \
    && mkdir -p $SYS \
    && python3 -I xpipack.py extension-src $SYS/bridge@beamai-muse.invalid.xpi \
    && FF=/usr/lib/firefox-esr \
    && mkdir -p $FF/distribution $FF/defaults/pref /usr/lib/mozilla/native-messaging-hosts \
    && sed "s|@DOWNLOADS@|/data/downloads|" policies.json > $FF/distribution/policies.json \
    && cp prefs.js $FF/defaults/pref/muse.js \
    && cp native-host.json /usr/lib/mozilla/native-messaging-hosts/dev.openmuse.browser.json \
    && rm policies.json prefs.js native-host.json \
    && chmod 0555 init.sh browserd.py egress.py native-host ctl.py \
    && chmod -R a+rX /opt/muse-browser $FF/distribution $FF/defaults/pref /usr/lib/mozilla /usr/share/mozilla

ENV HOME=/data/home LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh TZ=Asia/Shanghai DISPLAY=:0
WORKDIR /data
USER 1000:1000
VOLUME ["/data"]
ENTRYPOINT ["/opt/muse-browser/init.sh"]
