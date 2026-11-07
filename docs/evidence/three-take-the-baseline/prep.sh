#!/usr/bin/env bash
# Phase 1: the v1.7.0 compose.yaml in project g312lab, keyryx v0.1.3 custody, vouchryx in keyryx mode,
# and four vouchryx starts so custody holds four live keys of the name, the bound.
set -uo pipefail
. "$(dirname "$0")/common.sh"
docker compose version | tee "$EV/compose-version.txt"
"${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
[ -d "$L" ] && docker run --rm -v "$R/lab:/w" "$BB" rm -rf /w/box
mkdir -p "$L" && cd "$L" || exit 1
cp "$R/old/compose.yaml" compose.yaml
grep -oE '\$\{[A-Za-z0-9_]+:\?' compose.yaml | sed 's/^\${//;s/:?$//' | sort -u | sed 's/$/=lab-test-value/' >.env
cat >>.env <<'E'
VOUCHRYX_SIGNER=keyryx
VOUCHRYX_KEYRYX_URL=http://keyryx:4340
VOUCHRYX_KEYRYX_CONSUMER=vouchryx
VOUCHRYX_KEYRYX_SOCKET=/run/keyryx/sock/vouchryx/keyryx.sock
VOUCHRYX_TRUSTED_ISSUERS='https://idp.stack-single.local|stack-single|/etc/vouchryx/idp.jwks.json|unbound'
E
# keyryx's policy as install.sh writes it, the record seal's digest a test value
sed -n "/cat >\"\$kdir\/policy.json.tmp\" <<'POLICY'/,/^POLICY\$/p" "$R/new/install.sh" | sed '1d;$d' \
  | sed "s/__RECORD_SEAL_DIGEST__/sha256:$(printf lab | sha256sum | cut -c1-64)/" >policy.json.in
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' policy.json.in || { echo "policy did not parse"; exit 1; }
VIMG="$(grep -oE 'ghcr.io/taipanbox/vouchryx:v[^}]+' compose.yaml | head -1)"
mkdir -p delegation
docker run --rm --user 0:0 -v "$L/delegation:/out" --entrypoint vouchryx-demo "$VIMG" keygen -out /out/signing >/dev/null
docker run --rm --user 0:0 -v "$L/delegation:/out" --entrypoint vouchryx-demo "$VIMG" keygen -out /out/idp -kid stack-single-demo-idp >/dev/null
docker run --rm -v "$L:/w" "$BB" sh -euc '
  mkdir -p /w/keyryx/sock/wardryx /w/keyryx/sock/vouchryx /w/keyryx/sock/record-seal
  head -c 32 /dev/urandom | od -An -v -tx1 | tr -d " \n" >/w/keyryx/root.key
  head -c 32 /dev/urandom | od -An -v -tx1 | tr -d " \n" >/w/keyryx/witness-root.key
  chown 20101:20101 /w/keyryx/root.key && chmod 0400 /w/keyryx/root.key
  chown 20100:20100 /w/keyryx/witness-root.key && chmod 0400 /w/keyryx/witness-root.key
  cp /w/policy.json.in /w/keyryx/policy.json && chmod 0444 /w/keyryx/policy.json
  chown 20101:20001 /w/keyryx/sock/wardryx && chown 20101:20002 /w/keyryx/sock/vouchryx && chown 20101:30001 /w/keyryx/sock/record-seal
  chmod 0750 /w/keyryx/sock/wardryx /w/keyryx/sock/vouchryx /w/keyryx/sock/record-seal
  chmod 0700 /w/keyryx
  chown 20002:20002 /w/delegation/signing.pem /w/delegation/signing.jwks.json /w/delegation/idp.pem /w/delegation/idp.jwks.json
  chmod 600 /w/delegation/signing.pem /w/delegation/idp.pem'

say "old tree up: init-volumes and keyryx (v1.7.0 compose.yaml)"
"${DC[@]}" up -d keyryx 2>&1 | tail -3 | tee -a "$EV/run.log"
for _ in $(seq 1 30); do inside http://keyryx:4340/healthz >/dev/null && break; sleep 1; done
body="$(inside http://keyryx:4340/v1/jwks/keyryx.delegation-root)"
pieces="$(printf '%s' "$body" | sed 's/[{}]/\n/g')"
es="$(printf '%s\n' "$pieces" | grep -E '"alg" *: *"ES384"' | sed -n 's/.*"kid" *: *"\([^"]*\)".*/\1/p')"
ml="$(printf '%s\n' "$pieces" | grep -E '"alg" *: *"ML-DSA-65"' | sed -n 's/.*"kid" *: *"\([^"]*\)".*/\1/p')"
[ -n "$es" ] && [ -n "$ml" ] || { log "no delegation root served"; exit 1; }
pin="$({ printf '%s\n' "$es"; printf '%s\n' "$ml"; } | sed '/^$/d' | tr '\n' ',' | sed 's/,$//')"
echo "VOUCHRYX_KEYRYX_ROOT_PIN=$pin" >>.env
log "root pin taken from the lab's keyryx: $(printf '%s' "$pin" | tr ',' '\n' | wc -l) kids"
docker inspect -f '{{.Config.Image}}' "${P}-keyryx-1" | tee -a "$EV/run.log"

for i in 1 2 3 4; do
  say "vouchryx start $i"
  if [ "$i" = 1 ]; then "${DC[@]}" up -d vouchryx 2>&1 | tail -1 | tee -a "$EV/run.log"; else docker restart "${P}-vouchryx-1" >/dev/null; fi
  for _ in $(seq 1 60); do [ "$(vcount)" -ge "$i" ] && break; sleep 2; done
  keys "start$i"
done
date -u +%s >"$EV/start4.epoch"
log "four starts done; healthz after the fourth: $(wait_healthz 180)s"
