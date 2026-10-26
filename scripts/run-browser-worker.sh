#!/bin/sh
# Run the WebChat/CDP browser worker container. Requires the image built by
# `make browser-image`. WORKER_TOKEN must contain at least 32 characters; a
# fresh token is printed only for standalone development.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
IMAGE="${BROWSER_WORKER_IMAGE:-beamai-muse-browser-worker:local}"
if [ -z "${WORKER_TOKEN:-}" ]; then
    WORKER_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "WORKER_TOKEN=$WORKER_TOKEN" >&2
fi
export WORKER_TOKEN
WORKER_DATA_DIR="${WORKER_DATA_DIR:-$ROOT/../../.muse/browser-profiles}"
mkdir -p "$WORKER_DATA_DIR"
chmod 700 "$WORKER_DATA_DIR" 2>/dev/null || true

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Browser worker image is missing: docker build -t $IMAGE sidecars/webchat-browser" >&2
    exit 1
fi

# One worker container runs one browser process per session; profiles remain
# separated under WORKER_DATA_DIR. Chromium's sandbox is disabled because the
# container itself is isolated and hardened below.
exec docker run --rm --init --read-only \
    --cap-drop=ALL --security-opt=no-new-privileges:true \
    --memory=2g --pids-limit=256 \
    --tmpfs=/tmp:size=256m,mode=1777 --shm-size=256m \
    --env=WORKER_TOKEN --env=HOME=/tmp \
    --volume="$WORKER_DATA_DIR:/data" \
    --publish="${WORKER_HOST:-127.0.0.1}:${WORKER_PORT:-8790}:8790" \
    "$IMAGE"
