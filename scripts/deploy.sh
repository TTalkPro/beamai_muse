#!/bin/sh
# Build a production release (ERTS included) and install it into APP_DIR,
# default $HOME/apps/muse:
#
#   APP_DIR/rel/       the release (replaced on every deploy)
#   APP_DIR/bin/muse   control script (deploy/muse)
#   APP_DIR/sidecars/  PDF helper and mail helper, with node_modules
#   APP_DIR/systemd/   unit files for APP_DIR and this user (not installed)
#   APP_DIR/.env       created from deploy/.env.example once, then left alone
#   APP_DIR/data/      DATA_DIR, left alone
#
# A running instance is stopped for the swap and started again afterwards.
# Usage: scripts/deploy.sh [APP_DIR]
set -eu
cd "$(dirname "$0")/.."
APP_DIR="${1:-$HOME/apps/muse}"
mkdir -p "$APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd -P)"
VSN=$(sed -n 's/.*{release, {beamai_muse, "\([^"]*\)"}.*/\1/p' rebar.config)

[ -d sidecars/pdf/node_modules ] && [ -d sidecars/mail/node_modules ] || make sidecars
rebar3 compile
./scripts/build-css.sh
rebar3 as prod tar
TAR="_build/prod/rel/beamai_muse/beamai_muse-$VSN.tar.gz"

was_running=false
if [ -x "$APP_DIR/bin/muse" ] && [ -f "$APP_DIR/.env" ] && "$APP_DIR/bin/muse" status | grep -q "muse: running"; then
    was_running=true
    "$APP_DIR/bin/muse" stop
fi

mkdir -p "$APP_DIR/bin" "$APP_DIR/scripts" "$APP_DIR/sidecars" "$APP_DIR/systemd" \
         "$APP_DIR/data" "$APP_DIR/logs" "$APP_DIR/run"
rm -rf "$APP_DIR/rel.new"
mkdir "$APP_DIR/rel.new"
tar -xzf "$TAR" -C "$APP_DIR/rel.new"
rm -rf "$APP_DIR/rel.old"
[ ! -d "$APP_DIR/rel" ] || mv "$APP_DIR/rel" "$APP_DIR/rel.old"
mv "$APP_DIR/rel.new" "$APP_DIR/rel"
rm -rf "$APP_DIR/rel.old"

rsync -a --delete --exclude tests sidecars/pdf sidecars/mail "$APP_DIR/sidecars/"
# the browser worker of older versions (the browser is a Chrome container now)
rm -rf "$APP_DIR/sidecars/browser-worker" "$APP_DIR/sidecars/webchat-browser" \
       "$APP_DIR/scripts/run-browser-worker.sh" "$APP_DIR/systemd/muse-browser-worker.service"
cp deploy/muse "$APP_DIR/bin/muse"
chmod +x "$APP_DIR/bin/muse"
for unit in deploy/systemd/*.service; do
    sed -e "s#/home/david/app/muse#$APP_DIR#g" -e "s#^User=.*#User=$(id -un)#" \
        -e "s#^Group=.*#Group=$(id -gn)#" "$unit" >"$APP_DIR/systemd/$(basename "$unit")"
done

if [ ! -f "$APP_DIR/.env" ]; then
    secret() { openssl rand -hex "$1"; }
    (umask 077
     sed -e "s#@APP_DIR@#$APP_DIR#g" \
         -e "s#@ACCESS_KEY@#$(secret 16)#" \
         -e "s#@ENCRYPTION_KEY@#$(openssl rand -base64 32)#" \
         -e "s#@UI_SECRET@#$(secret 32)#" \
         -e "s#@COOKIE@#$(secret 16)#" \
         deploy/.env.example >"$APP_DIR/.env")
    echo "Created $APP_DIR/.env with fresh secrets: set the model and PUBLIC_API_URL, then $APP_DIR/bin/muse start"
fi

echo "Installed beamai_muse $VSN into $APP_DIR"
if grep -q "^[[:space:]]*BROWSER_ENABLED[[:space:]]*=[[:space:]]*true" "$APP_DIR/.env" 2>/dev/null; then
    img=$(sed -n "s/^[[:space:]]*BROWSER_IMAGE[[:space:]]*=[[:space:]]*//p" "$APP_DIR/.env" | tail -n 1)
    docker image inspect "${img:-muse-browser:local}" >/dev/null 2>&1 \
        || echo "warning: BROWSER_ENABLED=true but image ${img:-muse-browser:local} is missing: run make browser-image" >&2
fi
if $was_running; then "$APP_DIR/bin/muse" start; fi
