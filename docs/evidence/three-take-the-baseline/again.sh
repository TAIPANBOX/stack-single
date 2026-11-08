#!/usr/bin/env bash
# Phase 4: the tree's init-volumes body changes (a refused chown stops it). An up with only init-volumes
# changed, on Compose 2.26.1, then the capabilities again on fresh volumes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"
cd "$L" || exit 1
say "an up where only init-volumes changed"
cp "$R/new/compose.yaml" compose.yaml
keys before-body
"${DC[@]}" up -d vouchryx 2>&1 | grep -E 'Recreate$|Restart|Started$' | tee -a "$EV/run.log"
log "vouchryx /healthz 200 after $(wait_healthz 900)s"
keys after-body
docker logs --since 3m "${P}-keyryx-1" 2>&1 | grep -E 'retire|refused' | tail -3 | tee -a "$EV/run.log"
bash "$HERE/caps-fresh.sh"
