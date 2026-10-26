#!/bin/sh
# End-to-end acceptance in sample mode against real sidecars: the Playwright
# browser worker (sidecars/browser-worker) and the Docker desktop computer
# (make computer-desktop-image). Builds nothing: run `rebar3 release` first.
# Drives the HTTP API with scripts/acceptance.py and removes the Docker
# container and volume it created.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(mktemp -d)
P=18879
TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d " \n")
DEP=muse-accept-$$
# its own worker port, so a deployed instance (8790) keeps running
WP=18790
(cd $ROOT && WORKER_PORT=$WP WORKER_TOKEN=$TOKEN WORKER_DATA_DIR=$D/profiles ./scripts/run-browser-worker.sh > $D/worker.log 2>&1 &)
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$WP/health && break; sleep 1; done
echo "worker: $(curl -s http://127.0.0.1:$WP/health)"
cd $ROOT
DATA_DIR=$D/data PORT=$P PUBLIC_API_URL=http://127.0.0.1:$P BROWSER_WORKER_URL=http://127.0.0.1:$WP WORKER_TOKEN=$TOKEN \
  COMPUTER_ENABLED=true COMPUTER_DESKTOP=true COMPUTER_DEPLOYMENT_ID=$DEP \
  _build/default/rel/beamai_muse/bin/beamai_muse daemon
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$P/api/health && break; sleep 1; done
python3 "$ROOT/scripts/acceptance.py" http://127.0.0.1:$P
STATUS=$?
_build/default/rel/beamai_muse/bin/beamai_muse stop
WPID=$(ss -ltnp 2>/dev/null | grep ":$WP " | sed -n "s/.*pid=\([0-9]*\).*/\1/p" | head -1)
[ -n "$WPID" ] && kill "$WPID"
LABEL=$(printf %s "$DEP" | sha256sum | cut -c1-16)
for c in $(docker ps -aq --filter label=dev.openmuse.deployment=$LABEL); do docker rm -f "$c" >/dev/null; done
for v in $(docker volume ls -q --filter label=dev.openmuse.deployment=$LABEL); do docker volume rm "$v" >/dev/null; done
echo "cleanup: containers=$(docker ps -aq --filter label=dev.openmuse.deployment=$LABEL | wc -l) volumes=$(docker volume ls -q --filter label=dev.openmuse.deployment=$LABEL | wc -l)"
rm -rf -- "$D"
exit $STATUS
