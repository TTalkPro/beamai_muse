# Browser image (BROWSER_ENABLED=true): one per user, started by
# muse_browser_docker. A real, headful Google Chrome on a virtual X display,
# driven without CDP: an MV3 extension (force-installed by enterprise policy)
# talks to the in-container daemon through Chrome native messaging, and
# xdotool provides OS-level mouse and keyboard input. All web traffic goes
# through the in-container egress proxy (public addresses only).
# See browser/README.md and designs/04-integrations.md §4.
#
# Build: make browser-image (tag muse-browser:local).
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl python3 python3-cryptography procps tzdata locales \
       xvfb openbox xdotool xclip scrot x11-utils \
       fonts-dejavu-core fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
    && curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    && apt-get install -y --no-install-recommends /tmp/chrome.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/chrome.deb \
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
    && mkdir -p /etc/opt/chrome/policies/managed /etc/opt/chrome/native-messaging-hosts \
    && sed "s/@EXT_ID@/$EXT_ID/g" policies.json > /etc/opt/chrome/policies/managed/muse.json \
    && sed "s/@EXT_ID@/$EXT_ID/g" native-host.json > /etc/opt/chrome/native-messaging-hosts/dev.openmuse.browser.json \
    && rm policies.json native-host.json \
    && chmod 0555 init.sh browserd.py egress.py native-host ctl.py \
    && chmod -R a+rX /opt/muse-browser /etc/opt/chrome

ENV HOME=/data/home LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh TZ=Asia/Shanghai DISPLAY=:0
WORKDIR /data
USER 1000:1000
VOLUME ["/data"]
ENTRYPOINT ["/opt/muse-browser/init.sh"]
