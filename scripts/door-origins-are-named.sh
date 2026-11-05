#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 64: each tokenfuse door accepts a proof for its own addresses and
# no other door's, and wardryx, which checks either door's proof, takes the union of the two.
#
# WHAT IT CHECKS
#   A. COMPOSE, RESOLVED (--profile typed, with the lines install.sh writes). The gateway's
#      TOKENFUSE_DELEGATION_ORIGINS is its .env line; the broker's TOKENFUSE_DELEGATION_ORIGINS
#      and TOKENFUSE_MCP_PROOF_ORIGINS are both MCP_BROKER_DELEGATION_ORIGINS. No default is
#      baked into compose.yaml: a default there would name an address the box does not have.
#   B. install.sh. Each list is written from GATEWAY_PROBE, the bind this box has (invariant 11),
#      never from GATEWAY_BIND, whose 0.0.0.0 is no address at all. Each list names its own
#      service name and its own bind origin, and wardryx's WARDRYX_AGENT_TOKEN_DOOR_ORIGINS is
#      exactly the union. Both lists are forgotten with WITH_AGENT_TOKENS=0.
#   C. NO TODO LEFT. No TODO(D13) in install.sh or compose.yaml.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
  echo "door-origins-are-named: no compose.yaml or install.sh, so nothing was measured"
  exit 1
fi

GW='http://tokenfuse-gateway:4100,http://$GATEWAY_PROBE:4100'
BR='http://tokenfuse-mcp-broker:4200,http://$GATEWAY_PROBE:4200'

# ---- A. compose, resolved ---------------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "A. no docker compose here, so the origins could not be read from the resolved configuration"
else
  cdir="$(mktemp -d)"
  trap 'rm -rf "$cdir"' EXIT
  cp compose.yaml "$cdir/compose.yaml"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/.env"
  cp "$cdir/.env" "$cdir/.env.none"
  printf '%s\n' 'TOKENFUSE_DELEGATION_ORIGINS=gw-list' 'MCP_BROKER_DELEGATION_ORIGINS=br-list' >>"$cdir/.env"
  if docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" --profile typed config --format json >"$cdir/typed.json" 2>"$cdir/err" \
     && docker compose --project-directory "$cdir" --env-file "$cdir/.env.none" -f "$cdir/compose.yaml" --profile typed config --format json >"$cdir/none.json" 2>>"$cdir/err"; then
    python3 - "$cdir/typed.json" "$cdir/none.json" <<'PY' || problems=$((problems + 1))
import json
import sys

svc = json.load(open(sys.argv[1]))["services"]
none = json.load(open(sys.argv[2]))["services"]
problems = []
if not svc.get("tokenfuse-gateway") or not svc.get("tokenfuse-mcp-broker"):
    print("FAIL: A. the typed profile renders no tokenfuse-gateway or no tokenfuse-mcp-broker: this gate measured NOTHING")
    sys.exit(1)
gw = svc["tokenfuse-gateway"].get("environment") or {}
br = svc["tokenfuse-mcp-broker"].get("environment") or {}
if gw.get("TOKENFUSE_DELEGATION_ORIGINS") != "gw-list":
    problems.append("A. tokenfuse-gateway resolves TOKENFUSE_DELEGATION_ORIGINS as %r, not its .env line" % gw.get("TOKENFUSE_DELEGATION_ORIGINS"))
for var in ("TOKENFUSE_DELEGATION_ORIGINS", "TOKENFUSE_MCP_PROOF_ORIGINS"):
    if br.get(var) != "br-list":
        problems.append("A. tokenfuse-mcp-broker resolves %s as %r, not MCP_BROKER_DELEGATION_ORIGINS" % (var, br.get(var)))
for name, var in (("tokenfuse-gateway", "TOKENFUSE_DELEGATION_ORIGINS"), ("tokenfuse-mcp-broker", "TOKENFUSE_DELEGATION_ORIGINS"), ("tokenfuse-mcp-broker", "TOKENFUSE_MCP_PROOF_ORIGINS")):
    if ((none[name].get("environment") or {}).get(var) or "") != "":
        problems.append("A. %s has a default %s baked into compose.yaml: it would name an address this box may not have" % (name, var))
for p in problems:
    print("FAIL: " + p)
sys.exit(1 if problems else 0)
PY
  else
    fail "A. docker compose config --profile typed failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
  fi
fi

# ---- B. install.sh ------------------------------------------------------------------------------
grep -qF "identity_env_set TOKENFUSE_DELEGATION_ORIGINS \"$GW\"" install.sh \
  || fail "B. install.sh does not write the gateway's own two origins from GATEWAY_PROBE: $GW"
grep -qF "identity_env_set MCP_BROKER_DELEGATION_ORIGINS \"$BR\"" install.sh \
  || fail "B. install.sh does not write the broker's own two origins from GATEWAY_PROBE: $BR"
UNION="$(grep -E '^[[:space:]]*identity_env_set WARDRYX_AGENT_TOKEN_DOOR_ORIGINS ' install.sh | sed -E 's/^[^"]*"([^"]*)".*$/\1/')"
if [ -z "$UNION" ]; then
  fail "B. install.sh writes no WARDRYX_AGENT_TOKEN_DOOR_ORIGINS, so wardryx refuses both doors' proofs"
else
  want="$(printf '%s,%s' "$GW" "$BR" | tr ',' '\n' | sort)"
  have="$(printf '%s' "$UNION" | tr ',' '\n' | sort)"
  [ "$want" = "$have" ] || fail "B. wardryx's door origins are not exactly the union of the two lists: $UNION"
fi
FORGET="$(sed -n '/for v in VOUCHRYX_AGENTS VOUCHRYX_ALLOWED_AUDIENCES/,/; do$/p' install.sh)"
for v in TOKENFUSE_DELEGATION_ORIGINS MCP_BROKER_DELEGATION_ORIGINS; do
  printf '%s\n' "$FORGET" | grep -q "$v" || fail "B. WITH_AGENT_TOKENS=0 leaves $v in .env"
done

# ---- C. no TODO left ----------------------------------------------------------------------------
if grep -q 'TODO(.*D13' compose.yaml install.sh; then fail "C. a TODO for D13 is still in compose.yaml or install.sh: the origins are set now"; fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 64."
  exit 1
fi
echo "OK: the gateway and the broker each list their own two addresses, from the bind this box has, and wardryx takes exactly the union."
