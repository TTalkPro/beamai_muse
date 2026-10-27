#!/bin/sh
# Vendor the noVNC client (the live remote screens, muse.js `muse-vnc`) into
# apps/muse_web/priv/static/novnc: core/ and vendor/ of the npm package
# @novnc/novnc, unchanged, as ES modules loaded straight by the browser (no
# bundler). Needs npm and network at vendoring time only.
#   scripts/vendor-novnc.sh [version]     (default 1.7.0)
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:-1.7.0}
DEST=apps/muse_web/priv/static/novnc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && npm pack --silent "@novnc/novnc@$VERSION" >/dev/null && tar xzf novnc-novnc-*.tgz)
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/package/core" "$TMP/package/vendor" "$TMP/package/LICENSE.txt" "$TMP/package/AUTHORS" "$DEST/"
printf 'noVNC %s (npm @novnc/novnc), core/ and vendor/ unchanged; MPL-2.0 (LICENSE.txt),\npako under vendor/pako/LICENSE. Refresh with scripts/vendor-novnc.sh.\n' "$VERSION" >"$DEST/SOURCE.txt"
echo "noVNC $VERSION -> $DEST"
