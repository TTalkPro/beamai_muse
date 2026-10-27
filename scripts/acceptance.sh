#!/bin/sh
# End-to-end acceptance in sample mode against real containers: the per-user
# Chrome browser (make browser-image) and the Docker desktop computer
# (make computer-desktop-image). Builds nothing: run `rebar3 release` first.
# Drives the HTTP API with scripts/acceptance.py and removes the Docker
# containers and volumes it created (its own deployment id; a deployed
# instance and its containers are left alone).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(mktemp -d)
P=18879
DEP=muse-accept-$$
cd $ROOT
DATA_DIR=$D/data PORT=$P PUBLIC_API_URL=http://127.0.0.1:$P \
  BROWSER_ENABLED=true BROWSER_IMAGE=${BROWSER_IMAGE:-muse-browser:local} \
  COMPUTER_ENABLED=true COMPUTER_DESKTOP=true COMPUTER_DEPLOYMENT_ID=$DEP \
  _build/default/rel/beamai_muse/bin/beamai_muse daemon
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$P/api/health && break; sleep 1; done
python3 "$ROOT/scripts/acceptance.py" http://127.0.0.1:$P
STATUS=$?
_build/default/rel/beamai_muse/bin/beamai_muse stop
LABEL=$(printf %s "$DEP" | sha256sum | cut -c1-16)
for c in $(docker ps -aq --filter label=dev.openmuse.deployment=$LABEL); do docker rm -f "$c" >/dev/null; done
for v in $(docker volume ls -q --filter label=dev.openmuse.deployment=$LABEL); do docker volume rm "$v" >/dev/null; done
echo "cleanup: containers=$(docker ps -aq --filter label=dev.openmuse.deployment=$LABEL | wc -l) volumes=$(docker volume ls -q --filter label=dev.openmuse.deployment=$LABEL | wc -l)"
rm -rf -- "$D"
exit $STATUS
