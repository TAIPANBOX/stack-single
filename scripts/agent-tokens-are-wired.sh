#!/usr/bin/env bash
#
# Enforces invariant 40 of CLAUDE.md (as amended by invariant 47): an agent presents its
# own short-lived, sender-constrained token, and the doors that take one verify it.
# Since v1.3.0 this is the DEFAULT: the gateway and the MCP broker run
# TOKENFUSE_AGENT_TOKENS=require, a static client key is admitted only when its key id
# is on the named allow-list, and wardryx verifies the token itself (WARDRYX_AGENT_TOKEN_*).
# WITH_AGENT_TOKENS=0 is the explicit way out: the doors run off, the static keys are
# what they were, and wardryx verifies nothing.
#
# WHAT THIS CHECKS, in the resolved configuration of compose.yaml three ways: with
# nothing set (the default), with TOKENFUSE_AGENT_TOKENS=off (WITH_AGENT_TOKENS=0), and
# with the token settings install.sh writes when agent tokens are on:
#
#   A. REQUIRE BY DEFAULT. With TOKENFUSE_AGENT_TOKENS unset, the gateway and the broker
#      read require, and each has its static allow-list variable (empty is a list of none).
#   A2. OFF IS EXPLICIT. With TOKENFUSE_AGENT_TOKENS=off the gateway and the broker read
#      off, vouchryx enrols nobody, and wardryx verifies no agent token (no issuer and no
#      other WARDRYX_AGENT_TOKEN_* setting).
#   B. ON, THE GATEWAY. The gateway verifies against vouchryx's own issuer and key set,
#      for its own audience, polls the revocation list from vouchryx, and that list FAILS
#      CLOSED. Its delegation origin is set, so the DPoP htu of a proof can be checked.
#   C. ON, THE BROKER. The same, for the MCP broker, with the taint gateway's key read from
#      a file the installer wrote (TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE).
#   D. ON, VOUCHRYX. Its agent registry is set, it publishes nothing to the host, and it
#      signs for the audiences the two doors name (VOUCHRYX_ALLOWED_AUDIENCES).
#   E. ONE AUDIENCE for both doors: one agent token verifies at the gateway and at the broker.
#   F. ON, WARDRYX. It verifies the token itself: its issuer is vouchryx's origin, the same
#      the gateway names, its audience is the doors' audience, its key set and revocation
#      list come from vouchryx, and its door origins name where the agent addresses each door.
#   G. THE INSTALLER. The `# agent-tokens:` block mints the enrolment secret into a 0600
#      file, writes only its digest into VOUCHRYX_AGENTS, never writes the secret itself to
#      .env, writes require (never accept), and writes the wardryx settings with the switch.
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

OFF_ENV="TOKENFUSE_AGENT_TOKENS=off"
ON_ENV="$(printf '%s\n' \
  "TOKENFUSE_AGENT_TOKENS=require" \
  "TOKENFUSE_AGENT_TOKENS_STATIC_KEYS=felyx,broker" \
  "TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS=" \
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
  "VOUCHRYX_ALLOWED_AUDIENCES=https://stack-single.gate.example" \
  "WARDRYX_AGENT_TOKEN_ISSUER=http://vouchryx:4310" \
  "WARDRYX_AGENT_TOKEN_AUDIENCES=https://stack-single.gate.example" \
  "WARDRYX_AGENT_TOKEN_JWKS_URL=http://vouchryx:4310/.well-known/jwks.json" \
  "WARDRYX_AGENT_TOKEN_REVOCATION_URL=http://vouchryx:4310/v1/revocations" \
  "WARDRYX_AGENT_TOKEN_DOOR_ORIGINS=http://tokenfuse-gateway:4100,http://tokenfuse-mcp-broker:4200,http://127.0.0.1:4100,http://127.0.0.1:4200")"
resolve "$scratch/default.json" "" || exit 1
resolve "$scratch/off.json" "$OFF_ENV" || exit 1
resolve "$scratch/on.json" "$ON_ENV" || exit 1

python3 - "$scratch/default.json" "$scratch/off.json" "$scratch/on.json" <<'PY' || problems=$((problems + 1))
import json
import sys

default = json.load(open(sys.argv[1]))["services"]
off = json.load(open(sys.argv[2]))["services"]
on = json.load(open(sys.argv[3]))["services"]

GATEWAY = "tokenfuse-gateway"
BROKER = "tokenfuse-mcp-broker"
VOUCH = "vouchryx"
WARDRYX = "wardryx"
problems = []


def env(svc, name):
    return (svc.get("environment") or {}).get(name)


def has(svc, name):
    return name in (svc.get("environment") or {})


def mounts(svc):
    return [v for v in svc.get("volumes") or [] if isinstance(v, dict)]


for cfg in (default, off, on):
    for name in (GATEWAY, BROKER, VOUCH, WARDRYX):
        if name not in cfg:
            problems.append("the resolved configuration has no %s service, so this gate measured NOTHING about it" % name)
if problems:
    for p in problems:
        print("FAIL: " + p)
    sys.exit(1)

# A. require by default, each door with its own static allow-list variable.
for name, listvar in ((GATEWAY, "TOKENFUSE_AGENT_TOKENS_STATIC_KEYS"), (BROKER, "TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS")):
    got = env(default[name], "TOKENFUSE_AGENT_TOKENS")
    if got != "require":
        problems.append("A. %s reads TOKENFUSE_AGENT_TOKENS %r with the switch unset; the default must be require (invariant 40 as amended by 47)" % (name, got))
    if not has(default[name], listvar):
        problems.append("A. %s has no %s, so static keys are not named as an allow-list" % (name, listvar))

# A2. off is explicit: nothing verifies, nothing is enrolled, wardryx verifies no token.
for name in (GATEWAY, BROKER):
    got = env(off[name], "TOKENFUSE_AGENT_TOKENS")
    if got != "off":
        problems.append("A2. %s reads TOKENFUSE_AGENT_TOKENS %r with WITH_AGENT_TOKENS=0; it must be off" % (name, got))
if env(off[VOUCH], "VOUCHRYX_AGENTS") not in (None, ""):
    problems.append("A2. vouchryx has an agent registry with agent tokens off; nobody may be enrolled")
for k in sorted(k for k in (off[WARDRYX].get("environment") or {}) if k.startswith("WARDRYX_AGENT_TOKEN_")):
    if env(off[WARDRYX], k) not in (None, ""):
        problems.append("A2. wardryx sets %s with agent tokens off; it must verify no token then" % k)

# B. the gateway verifies agent tokens against vouchryx, for its own audience, fail closed.
g = on[GATEWAY]
if env(g, "TOKENFUSE_AGENT_TOKENS") != "require":
    problems.append("B. the gateway reads TOKENFUSE_AGENT_TOKENS %r with the switch on, not require" % env(g, "TOKENFUSE_AGENT_TOKENS"))
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
if env(g, "TOKENFUSE_AGENT_TOKENS_STATIC_KEYS") is None:
    problems.append("B. the gateway names no TOKENFUSE_AGENT_TOKENS_STATIC_KEYS, so require admits no static key by a named list")

# C. the broker, the same, for its own audience and origin, and its own key.
b = on[BROKER]
if env(b, "TOKENFUSE_AGENT_TOKENS") != "require":
    problems.append("C. the broker reads TOKENFUSE_AGENT_TOKENS %r with the switch on, not require" % env(b, "TOKENFUSE_AGENT_TOKENS"))
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
if not has(b, "TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS"):
    problems.append("C. the broker names no TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS")

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

# F. wardryx verifies the token itself (wardryx 2.3.0): issuer, audience, key set, revocation, door origins.
w = on[WARDRYX]
if env(w, "WARDRYX_AGENT_TOKEN_ISSUER") != env(g, "TOKENFUSE_DELEGATION_ISSUER"):
    problems.append("F. wardryx's WARDRYX_AGENT_TOKEN_ISSUER %r is not the issuer the gateway verifies against %r" % (env(w, "WARDRYX_AGENT_TOKEN_ISSUER"), env(g, "TOKENFUSE_DELEGATION_ISSUER")))
if env(w, "WARDRYX_AGENT_TOKEN_AUDIENCES") != env(g, "TOKENFUSE_DELEGATION_AUDIENCE"):
    problems.append("F. wardryx's WARDRYX_AGENT_TOKEN_AUDIENCES %r is not the doors' audience %r" % (env(w, "WARDRYX_AGENT_TOKEN_AUDIENCES"), env(g, "TOKENFUSE_DELEGATION_AUDIENCE")))
if not str(env(w, "WARDRYX_AGENT_TOKEN_JWKS_URL") or "").startswith("http://vouchryx:4310/"):
    problems.append("F. wardryx's key set is not vouchryx's JWKS (WARDRYX_AGENT_TOKEN_JWKS_URL is %r)" % env(w, "WARDRYX_AGENT_TOKEN_JWKS_URL"))
if not str(env(w, "WARDRYX_AGENT_TOKEN_REVOCATION_URL") or "").startswith("http://vouchryx:4310/"):
    problems.append("F. wardryx polls no revocation list at vouchryx; a stopped agent keeps working at the decision")
origins = [o.strip() for o in str(env(w, "WARDRYX_AGENT_TOKEN_DOOR_ORIGINS") or "").split(",") if o.strip()]
for door in ("http://tokenfuse-gateway:4100", "http://tokenfuse-mcp-broker:4200"):
    if door not in origins:
        problems.append("F. wardryx's WARDRYX_AGENT_TOKEN_DOOR_ORIGINS does not name the door %s; a proof addressed to it is refused" % door)
if any(not o.startswith(("http://", "https://")) or o.endswith("/") or "@" in o for o in origins):
    problems.append("F. a WARDRYX_AGENT_TOKEN_DOOR_ORIGINS entry is not a bare scheme://host:port origin")

# C2. tokenfuse 1.18.0 (invariant 129) refuses a broker that names a taint gateway without the file that holds its key.
if env(b, "TOKENFUSE_MCP_TAINT_GATEWAY") and not env(b, "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE"):
    problems.append("C. the broker names a taint gateway but no TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE: tokenfuse 1.18.0 refuses to start")

for p in problems:
    print("FAIL: " + p)
if problems:
    sys.exit(1)
print("OK: by default the gateway and the broker require agent tokens, with a named static allow-list; off is explicit; with the token settings on, the doors and wardryx verify tokens against vouchryx for one audience, fail closed, and vouchryx enrols the agent and publishes nothing")
PY

# G. the installer mints the enrolment secret into a 0600 file, writes only its digest,
# and writes require (never accept) with the wardryx settings.
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
  printf '%s\n' "$BLOCK" | grep -q 'identity_env_set TOKENFUSE_AGENT_TOKENS require' \
    || fail "the agent-tokens block does not write TOKENFUSE_AGENT_TOKENS=require: the default is require (invariant 47)"
  printf '%s\n' "$BLOCK" | grep -q 'TOKENFUSE_AGENT_TOKENS accept' \
    && fail "the agent-tokens block still writes accept: a static key would be admitted without a named list"
  printf '%s\n' "$BLOCK" | grep -q 'WARDRYX_AGENT_TOKEN_ISSUER' \
    || fail "the agent-tokens block writes no WARDRYX_AGENT_TOKEN_ISSUER: wardryx would not verify the token (invariant 47)"
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
echo "OK: agent-tokens-are-wired (invariants 40 and 47)"
