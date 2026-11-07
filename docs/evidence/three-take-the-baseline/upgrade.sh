#!/usr/bin/env bash
# Phase 2. Control: a fifth start under keyryx v0.1.3 at the bound is refused, after the pause in which
# v0.1.4 would retire the oldest. Then the upgrade to this tree's compose.yaml, keys before and after,
# what was recreated, and a second up that recreates nothing.
set -uo pipefail
. "$(dirname "$0")/common.sh"
cd "$L" || exit 1
s4="$(cat "$EV/start4.epoch")"
# the second oldest key began two minutes after its start (publish-ahead); its overlap is ten minutes
ready=$(( s4 + 120 + 600 + 20 ))
now=$(date -u +%s)
[ "$now" -ge "$ready" ] || { log "waiting $(( ready - now ))s, until the second oldest key has signed for the overlap"; sleep $(( ready - now )); }

say "control: a fifth start under the old custody (v0.1.3), past the overlap"
keys before-control
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker restart "${P}-vouchryx-1" >/dev/null
sleep 40
log "vouchryx /healthz 40s after the fifth start: $(status_of http://vouchryx:4310/healthz)"
docker logs --since "$since" "${P}-keyryx-1" 2>&1 | grep -E 'refused|too_many|delegat' | tail -3 | tee "$EV/control-keyryx.log" | tee -a "$EV/run.log"
docker logs --since "$since" "${P}-vouchryx-1" 2>&1 | grep -iE 'key|refus' | tail -3 | tee "$EV/control-vouchryx.log" | tee -a "$EV/run.log"
keys after-control

say "upgrade: this tree's compose.yaml (keyryx v0.1.4, the three take the baseline)"
for s in init-volumes keyryx vouchryx; do docker inspect -f "$s {{.Id}}" "${P}-$s-1"; done >"$EV/ids-before.txt"
"${DC[@]}" config --hash 'init-volumes,keyryx,vouchryx' >"$EV/hash-old.txt" 2>&1
cp "$R/new/compose.yaml" compose.yaml
"${DC[@]}" config --hash 'init-volumes,keyryx,vouchryx' >"$EV/hash-new.txt" 2>&1
paste "$EV/hash-old.txt" "$EV/hash-new.txt" | tee -a "$EV/run.log"
keys before-upgrade
t0=$(date -u +%s)
"${DC[@]}" up -d vouchryx 2>&1 | tee "$EV/up1.log" | tee -a "$EV/run.log"
log "up returned after $(( $(date -u +%s) - t0 ))s; recreated: $(grep -cE 'Recreate(d)?$' "$EV/up1.log")"
docker inspect -f '{{.Config.Image}}' "${P}-keyryx-1" | tee -a "$EV/run.log"
h="$(wait_healthz 900)"
log "vouchryx /healthz 200 ${h}s after the upgrade's up returned"
keys after-upgrade
docker logs --since "$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ)" "${P}-keyryx-1" 2>&1 | grep -E 'retire|refused|delegat' | tail -5 | tee "$EV/upgrade-keyryx.log" | tee -a "$EV/run.log"

say "second up: recreates nothing, spends no key"
before="$(vcount)"
"${DC[@]}" up -d vouchryx 2>&1 | tee "$EV/up2.log" | tee -a "$EV/run.log"
log "recreated by the second up: $(grep -cE 'Recreate(d)?$' "$EV/up2.log"); vouchryx keys $before before, $(vcount) after"
for s in init-volumes keyryx vouchryx; do docker inspect -f "$s {{.Id}}" "${P}-$s-1"; done >"$EV/ids-after.txt"
paste "$EV/ids-before.txt" "$EV/ids-after.txt" | awk '{print $1, ($2==$4 ? "same container" : "recreated")}' | tee -a "$EV/run.log"

say "what Docker runs for the three"
for s in init-volumes keyryx vouchryx; do
  docker inspect -f "$s ro={{.HostConfig.ReadonlyRootfs}} drop={{.HostConfig.CapDrop}} add={{.HostConfig.CapAdd}} sec={{.HostConfig.SecurityOpt}} pids={{.HostConfig.PidsLimit}} ulimits={{.HostConfig.Ulimits}} user={{.Config.User}} exit={{.State.ExitCode}} status={{.State.Status}}" "${P}-$s-1"
done | tee "$EV/hostconfig.txt" | tee -a "$EV/run.log"
docker logs "${P}-init-volumes-1" 2>&1 | tail -2 | tee -a "$EV/run.log"
for s in keyryx vouchryx; do log "$s read-only errors in its log: $(docker logs "${P}-$s-1" 2>&1 | grep -ci 'read-only file system')"; done
