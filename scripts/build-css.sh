#!/bin/sh
# Build the UI stylesheet into apps/muse_web/priv/static/css/muse.css.
# Needs Node at build time only; run after `rebar3 compile` (it reads the
# aihtml dependency from _build). muse_ui_assets adds a content hash to the
# URL at runtime, so no manifest is needed.
set -eu
cd "$(dirname "$0")/.."
[ -d node_modules/@tailwindcss/cli ] || npm install --no-audit --no-fund
mkdir -p apps/muse_web/priv/static/css
npx tailwindcss -i assets/muse.css -o apps/muse_web/priv/static/css/muse.css --minify
