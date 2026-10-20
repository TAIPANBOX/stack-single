#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 61: the launcher runs the released pins of the 1.5.0 wave, and the
# two tokenfuse door origin lists name every address the gateway and the broker are reached at.
#
# WHAT IT CHECKS
#   A. THE PINS, compose.yaml and components.json. Each image is pinned at its released tag and
#      digest, and the old pin is gone from both files: keyryx v0.1.2, trailryx-node v1.5.0,
#      tokenfuse and tokenfuse-control-plane v1.20.0, genaryx-console v1.6.0 (the one whose
#      approver-jwks command the console statements need). Every digest is the one the
#      registry gave on 2026-10-20 (`docker buildx imagetools inspect`), each with a .sig tag.
#   B. THE ORIGINS, resolved (--profile typed). The gateway's TOKENFUSE_DELEGATION_ORIGINS names
#      the service-name origin and the bind's origin (http://tokenfuse-gateway:4100 and
#      http://${GATEWAY_BIND}:4100); the broker's TOKENFUSE_MCP_PROOF_ORIGINS names the broker's
#      service-name origin and its bind's origin on 4200. With the bind unset, the bind's origin is
#      127.0.0.1. An operator's own list in .env replaces both.
#   C. NO TODO LEFT. compose.yaml names no TODO(D13) for the origins.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f compose.yaml ] || [ ! -f components.json ]; then
  echo "wave3-pins-are-released: no compose.yaml or components.json, so nothing was measured"
  exit 1
fi

# name, released image reference, the old reference the pin replaces (or none)
PINS=(
  "keyryx|ghcr.io/taipanbox/keyryx:v0.1.2@sha256:9b6d4e0e8988076e90843d9d1625e50a7f248f6be531e144a6950ff9233f7683|ghcr.io/taipanbox/keyryx:v0.1.1@"
  "trailryx-node|ghcr.io/taipanbox/trailryx-node:v1.5.0@sha256:f15215cd9708724e83fbd8493f2bf7d2a11980b37edf3b887081d8e17da18bab|ghcr.io/taipanbox/trailryx-node:v1.4.0@"
  "tokenfuse|ghcr.io/taipanbox/tokenfuse:v1.20.0@sha256:84f6856dcfe609410429774c965bbc531d063b29c640871dd44b1c34b07ba628|ghcr.io/taipanbox/tokenfuse:v1.19.0@"
  "tokenfuse-control-plane|ghcr.io/taipanbox/tokenfuse-control-plane:v1.20.0@sha256:ab2510b3687455341fcc207361b8ed4801c4c7460f3ddc8b243603b6a982ca88|ghcr.io/taipanbox/tokenfuse-control-plane:v1.19.0@"
  "genaryx-console|ghcr.io/taipanbox/genaryx-console:v1.6.0@sha256:b226b16fb3cd58c1ad083cea668e0367e911bc0320c3fe5fa87366251570152b|ghcr.io/taipanbox/genaryx-console:v1.1.48@"
)

# ---- A. the pins -------------------------------------------------------------------------
for entry in "${PINS[@]}"; do
  IFS='|' read -r name want old <<<"$entry"
  grep -qF "$want" compose.yaml || fail "A. compose.yaml does not pin $name at its released reference: $want"
  grep -qF "$want" components.json || fail "A. components.json does not record the $name pin the compose file has"
  if grep -qF "$old" compose.yaml components.json; then
    fail "A. the old $name pin is still in compose.yaml or components.json: ${old%@}"
  fi
done

# ---- B. the origins, resolved ----------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "B. no docker compose here, so the origins could not be read from the resolved configuration"
else
  cdir="$(mktemp -d)"
  trap 'rm -rf "$cdir"' EXIT
  cp compose.yaml "$cdir/compose.yaml"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/.env"
  if docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" --profile typed config --format json >"$cdir/typed.json" 2>"$cdir/err"; then
    python3 - "$cdir/typed.json" <<'PY' || problems=$((problems + 1))
import json
import sys

svc = json.load(open(sys.argv[1]))["services"]
problems = []
gw = (svc.get("tokenfuse-gateway") or {}).get("environment") or {}
br = (svc.get("tokenfuse-mcp-broker") or {}).get("environment") or {}
want_gw = "http://tokenfuse-gateway:4100,http://127.0.0.1:4100"
want_br = "http://tokenfuse-mcp-broker:4200,http://127.0.0.1:4200"
if gw.get("TOKENFUSE_DELEGATION_ORIGINS") != want_gw:
    problems.append("B. tokenfuse-gateway resolves TOKENFUSE_DELEGATION_ORIGINS as %r, not %r" % (gw.get("TOKENFUSE_DELEGATION_ORIGINS"), want_gw))
if br.get("TOKENFUSE_MCP_PROOF_ORIGINS") != want_br:
    problems.append("B. tokenfuse-mcp-broker resolves TOKENFUSE_MCP_PROOF_ORIGINS as %r, not %r" % (br.get("TOKENFUSE_MCP_PROOF_ORIGINS"), want_br))
if not svc.get("tokenfuse-gateway") or not svc.get("tokenfuse-mcp-broker"):
    problems.append("B. the typed profile renders no tokenfuse-gateway or no tokenfuse-mcp-broker: this gate measured nothing")
for p in problems:
    print("FAIL: " + p)
sys.exit(1 if problems else 0)
PY
  else
    fail "B. docker compose config --profile typed failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
  fi
fi

# ---- C. no TODO left --------------------------------------------------------------------------
grep -q 'TODO(D13)' compose.yaml && fail "C. compose.yaml still names TODO(D13): the origins are set now"

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 61."
  exit 1
fi
echo "OK: the 1.5.0 wave's pins are the released digests (keyryx v0.1.2, trailryx-node v1.5.0, tokenfuse and its control plane v1.20.0, genaryx-console v1.6.0), and the gateway and broker name every origin they are reached at (invariant 61)."
