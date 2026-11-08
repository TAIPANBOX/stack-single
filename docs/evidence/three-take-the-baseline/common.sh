#!/usr/bin/env bash
# The lab behind CLAUDE.md invariant 72: init-volumes, keyryx and vouchryx take the baseline under keyryx
# v0.1.4, on Compose 2.26.1, in a project of its own (g312lab), test values only, nothing published. The
# live stack (project agent-stack) is never named here. Run, with R a scratch directory holding old/
# (the previous release's compose.yaml) and new/ (this tree):
#   R=... bash prep.sh; R=... bash upgrade.sh; R=... bash measure.sh; R=... bash again.sh
# then `docker compose -p g312lab --profile delegation down -v` from $R/lab/box.
R="${R:?R is the run root}"
L="$R/lab/box"
P=g312lab
NET="${P}_core"
DC=(docker compose -p "$P" --profile delegation)
BB=busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
EV="$R/lab/evidence"
mkdir -p "$EV"
ts() { date -u +%H:%M:%S; }
say() { printf '\n=== %s %s\n' "$(ts)" "$*" | tee -a "$EV/run.log"; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$EV/run.log"; }
inside() { docker run --rm --network "$NET" "$BB" wget -q -T5 -O - "$1" 2>/dev/null; }
status_of() { docker run --rm --network "$NET" "$BB" sh -c "wget -q -T5 -S -O /dev/null '$1' 2>&1 | sed -n 's/^ *HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | tail -1"; }
keys() { # label: GET /v1/keys into the evidence, and a one-line summary of vouchryx's keys
  inside http://keyryx:4340/v1/keys >"$EV/keys-$1.json"
  python3 - "$EV/keys-$1.json" "$1" <<'PY' | tee -a "$EV/run.log"
import json, sys, time
d = json.load(open(sys.argv[1]))["keys"]
v = [k for k in d if k.get("name") == "vouchryx"]
live = [k for k in v if k.get("state") not in ("retired", "revoked", "expired")]
now = int(time.time())
rows = ", ".join(f'{k["kid"][:8]} {k.get("state")} nb{k.get("not_before",0)-now:+d}s' for k in sorted(v, key=lambda k: k.get("created", 0)))
print(f"keys {sys.argv[2]}: vouchryx {len(v)} in all, {len(live)} live: {rows}")
PY
}
vcount() { inside http://keyryx:4340/v1/keys | python3 -c 'import json,sys; print(sum(k.get("name")=="vouchryx" for k in json.load(sys.stdin)["keys"]))'; }
wait_healthz() { # seconds: waits for vouchryx /healthz 200, prints seconds taken or "never"
  local left="$1" t0; t0=$(date +%s)
  while [ "$left" -gt 0 ]; do
    if [ "$(status_of http://vouchryx:4310/healthz)" = 200 ]; then echo $(( $(date +%s) - t0 )); return 0; fi
    sleep 5; left=$((left - 5))
  done
  echo never; return 1
}
