#!/usr/bin/env bash
# Phase 3. Process and memory peaks of keyryx and vouchryx under load, and init-volumes' capabilities,
# each taken out in turn, and its process limit.
set -uo pipefail
. "$(dirname "$0")/common.sh"
cd "$L" || exit 1
cg() { echo "/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' "${P}-$1-1").scope"; }
say "load: 6 rounds of 360 parallel requests at keyryx and vouchryx"
for r in 1 2 3 4 5 6; do
  docker run --rm --network "$NET" "$BB" sh -c '
    i=0; while [ $i -lt 120 ]; do
      wget -q -T10 -O /dev/null http://keyryx:4340/v1/keys &
      wget -q -T10 -O /dev/null http://keyryx:4340/v1/jwks/vouchryx &
      wget -q -T10 -O /dev/null http://vouchryx:4310/.well-known/jwks.json &
      i=$((i+1)); done; wait' >/dev/null 2>&1
done
for s in keyryx vouchryx; do
  c="$(cg "$s")"
  log "$s pids.peak $(cat "$c/pids.peak" 2>/dev/null || echo ?) pids.max $(cat "$c/pids.max") memory.peak $(( $(cat "$c/memory.peak" 2>/dev/null || echo 0) / 1048576 ))MiB restarts $(docker inspect -f '{{.RestartCount}}' "${P}-$s-1")"
done
log "vouchryx /healthz after the load: $(status_of http://vouchryx:4310/healthz)"

say "init-volumes: each capability taken out, on volumes the services have written"
try() { # name, override yaml body
  printf 'services:\n  init-volumes:\n%s\n' "$2" >compose.exp.yaml
  out="$(docker compose -p "$P" -f compose.yaml -f compose.exp.yaml run --rm --no-deps init-volumes 2>&1)"; rc=$?
  log "$1: exit $rc: $(printf '%s' "$out" | grep -vE '^ *Container|Creating|Created' | tail -1 | cut -c1-200)"
}
try "as written (CHOWN DAC_OVERRIDE FOWNER, read_only, pids 32)" "    pids_limit: 32"
try "without CHOWN" "    cap_add: !override [DAC_OVERRIDE, FOWNER]"
try "without DAC_OVERRIDE" "    cap_add: !override [CHOWN, FOWNER]"
try "without FOWNER" "    cap_add: !override [CHOWN, DAC_OVERRIDE]"
try "with pids_limit 4" "    pids_limit: 4"
rm -f compose.exp.yaml
