#!/usr/bin/env bash
#
# Enforces invariant 40 of CLAUDE.md: an agent can present its own short-lived,
# sender-constrained token instead of a static client key, when the operator opts in
# with WITH_AGENT_TOKENS=1, and the doors that accept such a token are wired to verify
# it: against vouchryx's own issuer and key set, for their own audience, with a
# revocation list that fails closed. Off by default: a box that did not ask for it runs
# what it ran before, and nothing about it changes.
#
# WHAT THIS IS ABOUT
#
# Findings F-001 and F-005 of the 2026-10-17 review, the launcher half: a static client
# key is one shared secret per namespace, it is never revoked per agent at runtime, and
# nothing outside tokenfuse can check it. Wave 1 design section 1 (decisions D1 a, D2 a,
# D8 a) gives each enrolled agent a secret of its own, stored as a digest in vouchryx,
# exchanged for a five-minute DPoP-bound token, which the gateway and the MCP broker
# verify offline. Stopping an agent is one revocation that every door polls.
#
# WHAT THIS CHECKS, in the resolved configuration of compose.yaml with the switch on
# and with it left off, and in install.sh:
#
#   A. OFF BY DEFAULT. With TOKENFUSE_AGENT_TOKENS unset, the gateway and the broker
#      read the switch as off, and vouchryx has no agent registry (VOUCHRYX_AGENTS empty).
#   B. ON, THE GATEWAY. TOKENFUSE_AGENT_TOKENS is accept, and the delegation door it
#      verifies against is complete: the issuer is vouchryx's own origin, the key set is a
#      file, the audience is a non-empty name of its own, the origin is this gateway's,
#      the revocation list is polled from vouchryx, and the list FAILS CLOSED.
#   C. ON, THE BROKER. The same, for the MCP broker, with its own audience, its own
#      origin, and the taint gateway's key read from a file the installer wrote
#      (TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE, the broker's `broker` client key).
#   D. ON, VOUCHRYX. Its agent registry is set, it publishes nothing to the host, and it
#      signs for the audiences the two doors name (VOUCHRYX_ALLOWED_AUDIENCES).
#   E. THE INSTALLER. The `# agent-tokens:` block mints the enrolment secret into a 0600
#      file, writes only its digest into VOUCHRYX_AGENTS, and never writes the secret
#      itself to .env.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no compose file, no docker compose, no gateway
# subject, or no installer block are each reported and fail.
set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f compose.yaml ]; then
  fail "compose.yaml is not there, so this gate measured NOTHING about agent tokens"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
  exit 1
fi

# resolve OUT EXTRA: the resolved configuration of compose.yaml with every required
# variable given a fake value, the profiles the agent-token plane sits behind, and the
# EXTRA lines appended. Written to OUT as JSON.
resolve() {
  local out="$1" extra="$2" cdir="$scratch/cfg"
  mkdir -p "$cdir"
  cp compose.yaml "$cdir/compose.yaml"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u \
    | sed 's/$/=fake-not-a-secret/' >"$cdir/.env"
  [ -z "$extra" ] || printf '%s\n' "$extra" >>"$cdir/.env"
  if ! docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" \
      --profile delegation --profile openai-door --profile typed --profile finops \
      --profile record --profile egress --profile egress-browser \
      config --format json >"$out" 2>"$cdir/err"; then
    fail "resolved: docker compose config refused the compose file: $(head -1 "$cdir/err")"
    return 1
  fi
}

ON_ENV="$(printf '%s\n' \
  "TOKENFUSE_AGENT_TOKENS=accept" \
  "TOKENFUSE_DELEGATION_ISSUER=http://vouchryx:4310" \
  "TOKENFUSE_DELEGATION_JWKS=/etc/tokenfuse/delegation/vouchryx.jwks.json" \
  "TOKENFUSE_DELEGATION_AUDIENCE=https://stack-single.gate.example" \
  "TOKENFUSE_DELEGATION_URL=http://127.0.0.1:4100" \
  "TOKENFUSE_DELEGATION_REVOCATIONS=http://vouchryx:4310/v1/revocations" \
  "TOKENFUSE_DELEGATION_REVOCATIONS_INTERVAL_MS=12000" \
  "VOUCHRYX_AGENTS=agent://gate.example/agents/operator|agents|local|sha256:0000000000000000000000000000000000000000000000000000000000000000" \
  "MCP_BROKER_DELEGATION_AUDIENCE=https://stack-single.gate.example" \
  "MCP_BROKER_DELEGATION_URL=http://127.0.0.1:4200" \
  "BROKER_GATEWAY_KEY_FILE=/run/broker/key" \
  "BROKER_TAINT_GATEWAY=http://tokenfuse-gateway:4100" \
  "VOUCHRYX_ALLOWED_AUDIENCES=https://stack-single.gate.example")"
resolve "$scratch/off.json" "" || exit 1
resolve "$scratch/on.json" "$ON_ENV" || exit 1

python3 - "$scratch/off.json" "$scratch/on.json" <<'PY' || problems=$((problems + 1))
import json
import sys

off = json.load(open(sys.argv[1]))["services"]
on = json.load(open(sys.argv[2]))["services"]

GATEWAY = "tokenfuse-gateway"
BROKER = "tokenfuse-mcp-broker"
VOUCH = "vouchryx"
problems = []


def is_gateway(s):
    return str(s.get("image", "")).startswith("ghcr.io/taipanbox/tokenfuse:") and s.get("command") == ["/usr/local/bin/tokenfuse"]


def env(svc, name):
    return (svc.get("environment") or {}).get(name)


def mounts(svc):
    return [v for v in svc.get("volumes") or [] if isinstance(v, dict)]


for name in (GATEWAY, BROKER, VOUCH):
    if name not in on:
        problems.append("the resolved configuration has no %s service, so this gate measured NOTHING about it" % name)
if problems:
    for p in problems:
        print("FAIL: " + p)
    sys.exit(1)

# A. off by default.
for name in (GATEWAY, BROKER):
    got = env(off[name], "TOKENFUSE_AGENT_TOKENS")
    if got not in (None, "", "off"):
        problems.append("A. %s reads TOKENFUSE_AGENT_TOKENS %r with the switch unset; it must be off" % (name, got))
if env(off[VOUCH], "VOUCHRYX_AGENTS") not in (None, ""):
    problems.append("A. vouchryx has an agent registry with the switch unset; a default box must not enrol anyone")

# B. the gateway verifies agent tokens against vouchryx, for its own audience, fail closed.
g = on[GATEWAY]
if env(g, "TOKENFUSE_AGENT_TOKENS") != "accept":
    problems.append("B. the gateway reads TOKENFUSE_AGENT_TOKENS %r with the switch on, not accept" % env(g, "TOKENFUSE_AGENT_TOKENS"))
if env(g, "TOKENFUSE_DELEGATION_ISSUER") != "http://vouchryx:4310":
    problems.append("B. the gateway's delegation issuer is %r, not vouchryx's own origin" % env(g, "TOKENFUSE_DELEGATION_ISSUER"))
if not env(g, "TOKENFUSE_DELEGATION_JWKS"):
    problems.append("B. the gateway has no TOKENFUSE_DELEGATION_JWKS, so it cannot verify a token offline")
if not str(env(g, "TOKENFUSE_DELEGATION_AUDIENCE") or "").strip():
    problems.append("B. the gateway's TOKENFUSE_DELEGATION_AUDIENCE is empty: an empty audience accepts a token minted for any resource")
if not str(env(g, "TOKENFUSE_DELEGATION_URL") or "").startswith("http"):
    problems.append("B. the gateway has no TOKENFUSE_DELEGATION_URL origin, so the DPoP htu of a token proof cannot be checked")
if not str(env(g, "TOKENFUSE_DELEGATION_REVOCATIONS") or "").startswith("http://vouchryx:4310/"):
    problems.append("B. the gateway polls no revocation list at vouchryx, so a stopped agent keeps working here")
if env(g, "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE") != "closed":
    problems.append("B. the gateway's revocation list does not fail closed (TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE is %r)" % env(g, "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE"))

# C. the broker, the same, for its own audience and origin, and its own key.
b = on[BROKER]
if env(b, "TOKENFUSE_AGENT_TOKENS") != "accept":
    problems.append("C. the broker reads TOKENFUSE_AGENT_TOKENS %r with the switch on, not accept" % env(b, "TOKENFUSE_AGENT_TOKENS"))
if not str(env(b, "TOKENFUSE_DELEGATION_AUDIENCE") or "").strip():
    problems.append("C. the broker's TOKENFUSE_DELEGATION_AUDIENCE is empty")
if env(b, "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE") != "closed":
    problems.append("C. the broker's revocation list does not fail closed")
if not str(env(b, "TOKENFUSE_DELEGATION_REVOCATIONS") or "").startswith("http://vouchryx:4310/"):
    problems.append("C. the broker polls no revocation list at vouchryx")
if env(b, "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE") != "/run/broker/key":
    problems.append("C. the broker reads its taint-gateway key from %r, not /run/broker/key" % env(b, "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE"))
if not any(m.get("target") == "/run/broker" and m.get("read_only") is True and str(m.get("source", "")).endswith("/broker") for m in mounts(b)):
    problems.append("C. the broker does not mount ./broker at /run/broker read only, so its key file cannot be read")

# D. vouchryx: its registry is set, nothing is published to the host, and it signs for
# the audiences the two doors name.
v = on[VOUCH]
if not env(v, "VOUCHRYX_AGENTS"):
    problems.append("D. vouchryx has no VOUCHRYX_AGENTS with the switch on, so no agent can get a token")
if v.get("ports"):
    problems.append("D. vouchryx publishes ports %r; it is never published to the host (invariant 15)" % v.get("ports"))
allowed = set(str(env(v, "VOUCHRYX_ALLOWED_AUDIENCES") or "").split(","))
for aud in (env(g, "TOKENFUSE_DELEGATION_AUDIENCE"), env(b, "TOKENFUSE_DELEGATION_AUDIENCE")):
    if aud not in allowed:
        problems.append("D. vouchryx may not issue for audience %r (VOUCHRYX_ALLOWED_AUDIENCES does not name it)" % aud)
    if not str(aud or "").startswith("https://"):
        problems.append("D. audience %r is not an https URL; tokenfuse 1.17.0 refuses an agent audience that is not one" % aud)

# E. one audience for both doors. One agent token is presented at the gateway and at the broker, and it
# verifies only for the audience it was minted for, so the two must be the same identifier (tokenfuse 1.17.0
# migration: the door checks aud exactly).
if env(g, "TOKENFUSE_DELEGATION_AUDIENCE") != env(b, "TOKENFUSE_DELEGATION_AUDIENCE"):
    problems.append("E. the gateway's audience %r and the broker's %r differ: one agent token must verify at both doors" % (env(g, "TOKENFUSE_DELEGATION_AUDIENCE"), env(b, "TOKENFUSE_DELEGATION_AUDIENCE")))

# C2. tokenfuse 1.18.0 (invariant 129) refuses a broker that names a taint gateway without the file that holds its key.
if env(b, "TOKENFUSE_MCP_TAINT_GATEWAY") and not env(b, "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE"):
    problems.append("C. the broker names a taint gateway but no TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE: tokenfuse 1.18.0 refuses to start")

for p in problems:
    print("FAIL: " + p)
if problems:
    sys.exit(1)
print("OK: with the switch on, the gateway and the broker verify agent tokens against vouchryx for their own audiences, fail closed, and vouchryx enrols the agent and publishes nothing; with it off, nothing changes")
PY

# E. the installer mints the enrolment secret into a 0600 file and writes only its digest.
BLOCK="$(sed -n '/^# agent-tokens: begin$/,/^# agent-tokens: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# agent-tokens: begin' .. 'end' block, so nothing enrols an agent for a token"
else
  printf '%s\n' "$BLOCK" | grep -q 'chmod 0600' || fail "the agent-tokens block does not set mode 0600 on the enrolment secret"
  printf '%s\n' "$BLOCK" | grep -q 'sha256' || fail "the agent-tokens block writes no SHA-256 digest of the enrolment secret"
  printf '%s\n' "$BLOCK" | grep -q 'VOUCHRYX_ALLOWED_AUDIENCES "\$AGENT_AUDIENCE"' \
    || fail "the agent-tokens block does not write the allowed audience from AGENT_AUDIENCE; vouchryx refuses a plain name at startup"
  printf '%s\n' "$BLOCK" | grep -q 'AGENT_AUDIENCE="https://' \
    || fail "the agent-tokens block names no https audience: tokenfuse 1.17.0 refuses an agent audience that is not an https URL"
  # Any write of a name that carries a secret into .env, in either spelling: the
  # NAME=value form printf writes, and the identity_env_set / add_env_default call.
  if printf '%s\n' "$BLOCK" | grep -E '^[[:space:]]*(add_env_default|identity_env_set)[[:space:]]+[A-Z_]*(SECRET|_KEY)([[:space:]]|$)' >/dev/null \
     || printf '%s\n' "$BLOCK" | grep -E '^[[:space:]]*(printf|echo)[^#]*(SECRET|_KEY)=' >/dev/null; then
    fail "the agent-tokens block writes an enrolment secret into .env; only the digest belongs there"
  fi
fi

if [ "$problems" -ne 0 ]; then
  printf 'agent-tokens-are-wired: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: agent-tokens-are-wired (invariant 40)"
