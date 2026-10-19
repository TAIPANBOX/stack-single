#!/usr/bin/env bash
# Runs the request helper of install.sh, lifted between its markers and unchanged, against
# the REAL tokenfuse gateway and wardryx images that compose.yaml pins, and checks the
# answers the installer's own checks expect (policy plane: admin 200, unknown 401, gateway
# key 403; gateway: admin GET 200, no key 401, POST with no key 401, POST with a client key
# is not refused). Why this exists: the 2026-10-19 CI install legs failed every check that
# went through the helper; busybox httpd had answered, the Go servers did not (see
# CLAUDE.md invariant 46 and scripts/no-secret-on-argv.sh).
#
# Runs on a scratch INTERNAL docker network with no published port. Every container and the
# network are removed on exit. Test keys only; nothing here is a real credential.
#
# Exit: 0 every expected answer came back; 1 at least one did not; 2 not run (docker missing,
# or an image is not present locally: this script never pulls).
#
# WARDRYX_IMAGE and TOKENFUSE_IMAGE may name another local image (compose allows the same),
# so a stand-in can be used where the pinned digest is not cached. The output says which.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "NOT RUN: docker is not available"
  exit 2
fi

pin() { grep -o "$1[^}]*" compose.yaml | head -1 | sed 's/:-//'; }
WARDRYX_IMAGE="${WARDRYX_IMAGE:-$(pin 'ghcr.io/taipanbox/wardryx:')}"
TOKENFUSE_IMAGE="${TOKENFUSE_IMAGE:-$(pin 'ghcr.io/taipanbox/tokenfuse:')}"
PG_IMAGE="$(grep -o 'postgres:16-alpine@sha256:[0-9a-f]*' compose.yaml | head -1)"
for img in "$WARDRYX_IMAGE" "$TOKENFUSE_IMAGE" "$PG_IMAGE"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "NOT RUN: $img is not present locally (this script never pulls; the owner decides a pull)"
    exit 2
  fi
done

tag="$$"
NET="f015-evidence-$tag"
work="$(mktemp -d /tmp/f015-evidence.XXXXXX)"
cleanup() {
  docker rm -f "f015-ev-gw-$tag" "f015-ev-wd-$tag" "f015-ev-pg-$tag" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# The policy file is the one install.sh writes (its heredoc, extracted, not retyped).
awk "/cat > policy.yaml <<'EOF'/{f=1;next} /^EOF\$/{if(f){exit}} f" install.sh > "$work/policy.yaml"
if [ ! -s "$work/policy.yaml" ]; then
  echo "NOT RUN: install.sh has no policy.yaml heredoc to read"
  exit 2
fi

# The request helper, lifted unchanged.
sed -n '/argv-free-http: begin/,/argv-free-http: end/p' install.sh > "$work/helper.sh"
if ! grep -q 'mkfifo' "$work/helper.sh"; then
  echo "FAIL: the request helper in install.sh has no FIFO; this measures the old pipe, not the fix"
  exit 1
fi

docker network create --internal "$NET" >/dev/null || { echo "NOT RUN: could not create $NET"; exit 2; }

ADMIN=TESTADMIN-0123456789abcdef0123456789
WADMIN=TESTWADMIN-0123456789abcdef0123456789
GWKEY=TESTWGW-0123456789abcdef0123456789
CLIENT=TESTCLIENT-0123456789abcdef0123456789
DECL=TESTDECL-0123456789abcdef0123456789
PGPW=TESTPG-0123456789abcdef

docker run -d --name "f015-ev-pg-$tag" --network "$NET" \
  -e POSTGRES_PASSWORD="$PGPW" -e POSTGRES_DB=wardryx -e POSTGRES_USER=wardryx "$PG_IMAGE" >/dev/null

for _ in $(seq 1 60); do
  docker exec "f015-ev-pg-$tag" pg_isready -U wardryx -d wardryx >/dev/null 2>&1 && break
  perl -e 'select(undef, undef, undef, 0.5)'
done

docker run -d --name "f015-ev-wd-$tag" --network "$NET" \
  -v "$work/policy.yaml:/etc/wardryx/policy.yaml:ro" \
  -e WARDRYX_KEYS="$WADMIN:default:admin,$GWKEY:default:pep" \
  -e WARDRYX_DB="postgres://wardryx:$PGPW@f015-ev-pg-$tag:5432/wardryx?sslmode=disable" \
  -e WARDRYX_APPROVAL_SECRET=TESTAPPROVAL-0123456789abcdef0123456789 \
  "$WARDRYX_IMAGE" serve -addr 0.0.0.0:8090 -events /tmp/wardryx.ndjson -policy /etc/wardryx/policy.yaml >/dev/null

docker run -d --name "f015-ev-gw-$tag" --network "$NET" \
  -e TOKENFUSE_ADDR=0.0.0.0:4100 \
  -e TOKENFUSE_ADMIN_KEYS="$ADMIN" \
  -e TOKENFUSE_DECLASSIFY_KEY="$DECL" \
  -e TOKENFUSE_MODE=enforce -e TOKENFUSE_CACHE=off \
  -e TOKENFUSE_CLIENT_KEYS="$CLIENT:felyx" \
  -e TOKENFUSE_CLOUD_URL=http://nowhere.invalid:8080 -e TOKENFUSE_CLOUD_KEY=TESTCLOUD-0123456789abcdef0123456789 \
  -e TOKENFUSE_WARDRYX_URL="http://f015-ev-wd-$tag:8090" -e TOKENFUSE_WARDRYX_KEY="$GWKEY" \
  -e TOKENFUSE_WARDRYX_MODE=enforce -e TOKENFUSE_WARDRYX_FAILMODE=closed \
  -e TOKENFUSE_UPSTREAM=http://nowhere.invalid/v1/messages -e TOKENFUSE_DATA_DIR=/tmp/traces \
  "$TOKENFUSE_IMAGE" /usr/local/bin/tokenfuse >/dev/null

# Wait until both answer through the helper itself.
ready=0
for _ in $(seq 1 60); do
  if [ "$(NET="$NET" bash -c 'source "$1"; status_of "$(http_request GET http://f015-ev-gw-'"$tag"':4100/healthz "" "")"' bash "$work/helper.sh")" = 200 ] \
     && [ "$(NET="$NET" bash -c 'source "$1"; status_of "$(http_request GET http://f015-ev-wd-'"$tag"':8090/healthz "" "")"' bash "$work/helper.sh")" = 200 ]; then
    ready=1
    break
  fi
  perl -e 'select(undef, undef, undef, 0.5)'
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: the gateway or wardryx did not answer /healthz through the helper within 30 s"
  docker logs "f015-ev-gw-$tag" 2>&1 | tail -3
  docker logs "f015-ev-wd-$tag" 2>&1 | tail -3
  exit 1
fi

B='{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'
ok=0; bad=0
check() { # label, expectation (exact|not-401), want, got
  local label="$1" how="$2" want="$3" got="$4" verdict=FAIL
  if [ "$how" = exact ] && [ "$got" = "$want" ]; then verdict=ok; fi
  if [ "$how" = not-401 ] && [ "$got" != 401 ] && [ "$got" != 0 ]; then verdict=ok; fi
  printf '  %-4s %-46s want %-7s got %s\n' "$verdict" "$label" "$([ "$how" = exact ] && echo "$want" || echo "not 401")" "$got"
  if [ "$verdict" = ok ]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
}
script="$work/run.sh"
cat > "$script" <<EOF
NET="$NET"
source "$work/helper.sh"
echo "POLICY_ADMIN=\$(status_of "\$(http_request GET http://f015-ev-wd-$tag:8090/v1/policies "Authorization: Bearer $WADMIN"\$'\r\n' "")")"
echo "POLICY_UNKNOWN=\$(status_of "\$(http_request GET http://f015-ev-wd-$tag:8090/v1/policies "Authorization: Bearer nonsense-not-a-key"\$'\r\n' "")")"
echo "POLICY_GATEWAY=\$(status_of "\$(http_request GET http://f015-ev-wd-$tag:8090/v1/policies "Authorization: Bearer $GWKEY"\$'\r\n' "")")"
echo "GW_ADMIN=\$(status_of "\$(http_request GET http://f015-ev-gw-$tag:4100/v1/runs "Authorization: Bearer $ADMIN"\$'\r\n' "")")"
echo "GW_NOKEY=\$(status_of "\$(http_request GET http://f015-ev-gw-$tag:4100/v1/runs "Authorization: Bearer "\$'\r\n' "")")"
echo "GW_POST_NOKEY=\$(status_of "\$(http_request POST http://f015-ev-gw-$tag:4100/v1/messages "Content-Type: application/json"\$'\r\n' '$B')")"
echo "GW_POST_CLIENT=\$(status_of "\$(http_request POST http://f015-ev-gw-$tag:4100/v1/messages "Content-Type: application/json"\$'\r\n'"x-fuse-key: $CLIENT"\$'\r\n'"x-fuse-run-id: evidence"\$'\r\n' '$B')")"
EOF
result="$(perl -e 'alarm 240; exec @ARGV' bash "$script" 2>&1)"
get() { printf '%s\n' "$result" | sed -n "s/^$1=//p" | tail -1; }
echo "== wardryx ($WARDRYX_IMAGE)"
check "policy: admin key GET /v1/policies" exact 200 "$(get POLICY_ADMIN)"
check "policy: unknown key GET /v1/policies" exact 401 "$(get POLICY_UNKNOWN)"
check "policy: gateway key GET /v1/policies" exact 403 "$(get POLICY_GATEWAY)"
echo "== tokenfuse gateway ($TOKENFUSE_IMAGE)"
check "gateway: admin key GET /v1/runs" exact 200 "$(get GW_ADMIN)"
check "gateway: no key GET /v1/runs" exact 401 "$(get GW_NOKEY)"
check "gateway: POST /v1/messages, no key" exact 401 "$(get GW_POST_NOKEY)"
check "gateway: POST /v1/messages with a body and a client key" not-401 "" "$(get GW_POST_CLIENT)"
echo "RESULT: $ok ok, $bad not as expected"
[ "$bad" -eq 0 ]
