#!/bin/sh
# Run the Playwright browser worker (sidecars/browser-worker, unchanged from
# OpenMuse). Needs WORKER_TOKEN (32+ chars); prints a fresh one if unset.
# Node 22.6+ can run the TypeScript sources natively; older Node uses tsx.
set -eu
cd "$(dirname "$0")/../sidecars/browser-worker"
if [ -z "${WORKER_TOKEN:-}" ]; then
    WORKER_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "WORKER_TOKEN=$WORKER_TOKEN" >&2
fi
export WORKER_TOKEN
export WORKER_DATA_DIR="${WORKER_DATA_DIR:-../../.muse/browser-profiles}"
major=$(node -p 'process.versions.node.split(".")[0]')
minor=$(node -p 'process.versions.node.split(".")[1]')
if [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 6 ]; }; then
    exec node --experimental-strip-types src/index.ts
else
    exec npx --yes tsx src/index.ts
fi
