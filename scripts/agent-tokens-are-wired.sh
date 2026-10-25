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
  for want in \
      'identity_env_set WARDRYX_AGENT_TOKEN_ISSUER http://vouchryx:4310' \
      'identity_env_set WARDRYX_AGENT_TOKEN_AUDIENCES "$AGENT_AUDIENCE"' \
      'identity_env_set WARDRYX_AGENT_TOKEN_JWKS_URL http://vouchryx:4310/.well-known/jwks.json' \
      'identity_env_set WARDRYX_AGENT_TOKEN_REVOCATION_URL http://vouchryx:4310/v1/revocations'; do
    printf '%s\n' "$BLOCK" | grep -qF "$want" \
      || fail "the agent-tokens block does not write '$want': wardryx would verify a token against the wrong key set, audience or revocation list (invariant 47)"
  done
  printf '%s\n' "$BLOCK" | grep -qF 'http://tokenfuse-gateway:4100,http://tokenfuse-mcp-broker:4200' \
    || fail "wardryx's door origins do not name the gateway and the broker: a proof addressed to either is refused (invariant 47)"
  # 1.3.1: upstream_put takes the owner, so the broker's key is written for its uid in one step.
  printf '%s\n' "$BLOCK" | grep -qF 'upstream_put "$broker" "$STACK_DIR/broker" 20012' \
    || fail "the broker's key is not owned by uid 20012, the uid the broker runs as: it cannot read its taint-gateway key and refuses to start (invariant 47)"
  printf '%s\n' "$BLOCK" | grep -qF 'TOKENFUSE_AGENT_TOKENS_STATIC_KEYS TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS; do' \
    || fail "the off path does not clear the static-key lists: tokenfuse 1.19.0 refuses a list under any mode but require (invariant 47)"
  # Any write of a name that carries a secret into .env, in either spelling: the
  # NAME=value form printf writes, and the identity_env_set / add_env_default call.
  if printf '%s\n' "$BLOCK" | grep -E '^[[:space:]]*(add_env_default|identity_env_set)[[:space:]]+[A-Z_]*(SECRET|_KEY)([[:space:]]|$)' >/dev/null \
     || printf '%s\n' "$BLOCK" | grep -E '^[[:space:]]*(printf|echo)[^#]*(SECRET|_KEY)=' >/dev/null; then
    fail "the agent-tokens block writes an enrolment secret into .env; only the digest belongs there"
  fi
fi

# H. THE ALLOW-LIST, RUN FOR REAL. The installer's own helpers are lifted out of install.sh and
# run against scratch .env files. A static key is named only when the box holds it (tokenfuse
# 1.19.0 refuses a listed id the gateway does not hold); felyx and broker are named when held;
# an id this box had before stays named on a re-run; STATIC_KEY_IDS naming a key it does not
# hold is refused, not silently dropped.
lib="$scratch/allowlist.sh"
for fn in client_key_ids identity_env_get identity_env_set static_keep_ok agent_static_keys_apply; do
  awk -v n="$fn" 'index($0, n "() {") == 1 { p = 1 } p { print } p && /^}$/ { exit }' install.sh
done >"$lib"
if ! grep -q '^agent_static_keys_apply() {' "$lib"; then
  fail "H. agent_static_keys_apply is not in install.sh, so the allow-list was not measured"
else
  allow_case() { # NAME KEYS STATIC_KEY_IDS EXISTING_GATEWAY MCP_KEYS EXISTING_MCP WANT_GATEWAY WANT_MCP
    local name="$1" d out rc
    d="$(mktemp -d "$scratch/allow.XXXXXX")"
    printf "GATEWAY_CLIENT_KEYS='%s'\nTOKENFUSE_MCP_KEYS='%s'\n" "$2" "$5" >"$d/.env"
    out="$(bash -c '
      set -euo pipefail
      STACK_DIR="$1"; AGENT_TOKENS_ON=1
      STATIC_KEY_IDS_LIST="$2"; EXISTING_GATEWAY_IDS="$3"; EXISTING_MCP_IDS="$4"; PRIOR_GW_PRESENT="$6"; REMOVED_STATIC_IDS=""
      die() { echo "DIE: $*"; exit 3; }
      note() { :; }
      . "$5"
      agent_static_keys_apply
      printf "GW=%s\nMCP=%s\n" "$(identity_env_get TOKENFUSE_AGENT_TOKENS_STATIC_KEYS)" "$(identity_env_get TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS)"
    ' _ "$d" "$3" "$4" "$6" "$lib" "${9:-0}" 2>&1)" && rc=0 || rc=$?
    if [ "$8" = DIE ]; then
      [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'DIE: STATIC_KEY_IDS names' \
        || fail "H. $name: a STATIC_KEY_IDS entry the box does not hold was not refused ($out)"
      return 0
    fi
    [ "$rc" -eq 0 ] || { fail "H. $name: agent_static_keys_apply failed: $out"; return 0; }
    printf '%s\n' "$out" | grep -qx "GW=$7" \
      || fail "H. $name: the gateway's allow-list is $(printf '%s' "$out" | grep '^GW=') and should be GW=$7; a listed id the box does not hold, or a held id it dropped, is wrong"
    printf '%s\n' "$out" | grep -qx "MCP=$8" \
      || fail "H. $name: the broker's allow-list is $(printf '%s' "$out" | grep '^MCP=') and should be MCP=$8"
  }
  # (name, held keys, STATIC_KEY_IDS, existing gateway ids, broker keys, existing broker ids, want gw, want mcp, prior list present)
  allow_case "a fresh box names felyx and broker, and no broker static key" \
    'S1:felyx,S2:broker,S3:agents' '' '' 'S9:stack-single' '' 'felyx,broker' 'stack-single'
  # 1.4.0 (CLAUDE.md invariant 53): a re-run keeps EXACTLY the list the last run wrote. The installer's own
  # agents and fire-drills keys are held on the box but were never on the list, so they must not join it.
  allow_case "a re-run keeps exactly the list it had, and never adds a key the installer minted" \
    'S1:felyx,S2:broker,S3:agents,S4:drills' '' 'felyx broker' 'S9:stack-single' 'stack-single' 'felyx,broker' 'stack-single' 1
  # 1.4.0 (supervisor review of f39c64b): felyx and the broker are named whenever the box holds them, on every
  # run. A box whose list was written empty (it held neither) and that later gets a felyx key must not be refused.
  allow_case "felyx and the broker are named on a re-run when the box holds them, even if the list was empty" \
    'S1:felyx,S2:broker' '' '' 'S9:stack-single' '' 'felyx,broker' 'stack-single' 1
  # 1.4.0 (decision of the supervisor): a list a 1.3.1 re-run widened loses the installer's own agents and
  # drills keys, unless the operator names them in STATIC_KEY_IDS. The broker's list is cut the same way.
  allow_case "a list widened by a 1.3.1 re-run loses agents and drills, on both doors" \
    'S1:felyx,S2:broker,S3:agents,S4:drills' '' 'felyx broker agents drills' 'S9:stack-single,S3:agents,S4:drills' 'stack-single agents drills' 'felyx,broker' 'stack-single' 1
  allow_case "an operator who names agents in STATIC_KEY_IDS keeps it on both doors" \
    'S1:felyx,S2:broker,S3:agents,S4:drills' 'agents' 'felyx broker agents drills' 'S9:stack-single,S3:agents,S4:drills' 'stack-single agents drills' 'felyx,broker,agents' 'stack-single,agents' 1
  allow_case "a box from before the list keeps its own keys, not the minted agents or drills" \
    'S1:felyx,S2:broker,S3:agents,S4:drills,S5:ops' '' 'ops' 'S9:stack-single' 'stack-single' 'felyx,broker,ops' 'stack-single'
  allow_case "a key the box does not hold is never named, and a re-run never keeps the installer's agents key" \
    'S1:felyx,S3:agents' '' 'agents ghost' 'S9:stack-single' '' 'felyx' 'stack-single'
  allow_case "a box without a broker key does not name broker" \
    'S1:felyx,S3:agents' '' '' 'S9:stack-single' '' 'felyx' 'stack-single'
  allow_case "STATIC_KEY_IDS naming a key the box does not hold is refused" \
    'S1:felyx,S3:agents' 'ghost' '' 'S9:stack-single' '' '' DIE
fi

# I. TWO RUNS ON ONE BOX (CLAUDE.md invariant 53, 1.4.0). The installer runs twice against one .env: the
# first run mints felyx, broker, agents and drills, and writes the list; the second reads the list back
# and must write the same one. A run that widens the list on its second pass admits, without a token, the
# keys the installer minted for the agents and the fire drills: the defect this section exists to catch.
lib2="$scratch/tworuns.sh"
for fn in client_key_ids identity_env_get identity_env_set identity_env_has static_keep_ok agent_tokens_resolve agent_static_keys_apply; do
  awk -v n="$fn" 'index($0, n "() {") == 1 { p = 1 } p { print } p && /^}$/ { exit }' install.sh
done >"$lib2"
if ! grep -q '^agent_tokens_resolve() {' "$lib2" || ! grep -q '^agent_static_keys_apply() {' "$lib2"; then
  fail "I. agent_tokens_resolve or agent_static_keys_apply is not in install.sh, so two runs were not measured"
else
  twod="$(mktemp -d "$scratch/two.XXXXXX")"
  # Run one: a fresh box, so no key is in .env when the run starts. The installer mints the four keys
  # after its resolve step (mint_prepare) and before the allow-list is written, which is what is emulated.
  # Run two: the same .env, now holding the keys and the list run one wrote.
  two_run() { # MINT: 1 on the first run (the keys appear between resolve and the allow-list), 0 on the second
    bash -c '
      set -euo pipefail
      STACK_DIR="$1"; MINT_ON=1; WITH_AGENT_TOKENS=""; WITH_DELEGATION=""; STATIC_KEY_IDS=""
      AGENT_TOKENS_ON=0; DELEGATION_ON=0; STATIC_KEY_IDS_LIST=""; EXISTING_GATEWAY_IDS=""; EXISTING_MCP_IDS=""
      STATIC_GATEWAY_LIST=""; STATIC_MCP_LIST=""; PRIOR_GW_PRESENT=0
      die() { echo "DIE: $*"; exit 3; }
      note() { :; }
      . "$2"
      agent_tokens_resolve
      if [ "$3" = 1 ]; then identity_env_set GATEWAY_CLIENT_KEYS "$4"; fi
      agent_static_keys_apply
      printf "GW=%s\n" "$(identity_env_get TOKENFUSE_AGENT_TOKENS_STATIC_KEYS)"
    ' _ "$twod" "$lib2" "$1" 'S1:felyx,S2:broker,S3:agents,S4:drills' 2>&1
  }
  first="$(two_run 1)" || first="DIE on run one: $first"
  second="$(two_run 0)" || second="DIE on run two: $second"
  printf '%s\n' "$first" | grep -qx 'GW=felyx,broker' \
    || fail "I. the first run's allow-list is $(printf '%s' "$first" | grep -E '^(GW=|DIE)' | head -1), and should be GW=felyx,broker"
  printf '%s\n' "$second" | grep -qx 'GW=felyx,broker' \
    || fail "I. the second run widened the allow-list to $(printf '%s' "$second" | grep -E '^(GW=|DIE)' | head -1); a re-run must keep exactly the list the first run wrote"
fi

# J. A WIDENED .ENV, RUN THROUGH THE INSTALLER'S OWN RESOLVE AND ALLOW-LIST (CLAUDE.md invariant 53, 1.4.0).
# A 1.3.1 re-run wrote agents and drills onto both static lists. The next run must drop them, unless the
# operator names them in STATIC_KEY_IDS, and it must say so. Run twice on the same .env, as the installer does.
if [ -f "${lib2:-}" ]; then
  wide="$(mktemp -d "$scratch/wide.XXXXXX")"
  printf "%s\n" \
    "GATEWAY_CLIENT_KEYS='S1:felyx,S2:broker,S3:agents,S4:drills'" \
    "TOKENFUSE_AGENT_TOKENS_STATIC_KEYS='felyx,broker,agents,drills'" \
    "TOKENFUSE_MCP_KEYS='S9:stack-single,S3:agents,S4:drills'" \
    "TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS='stack-single,agents,drills'" >"$wide/.env"
  wide_run() { # STATIC_KEY_IDS value (may be empty)
    bash -c '
      set -euo pipefail
      STACK_DIR="$1"; MINT_ON=1; WITH_AGENT_TOKENS=""; WITH_DELEGATION=""; STATIC_KEY_IDS="$3"
      AGENT_TOKENS_ON=0; DELEGATION_ON=0; STATIC_KEY_IDS_LIST=""; EXISTING_GATEWAY_IDS=""; EXISTING_MCP_IDS=""
      STATIC_GATEWAY_LIST=""; STATIC_MCP_LIST=""; PRIOR_GW_PRESENT=0; REMOVED_STATIC_IDS=""
      die() { echo "DIE: $*"; exit 3; }
      note() { :; }
      . "$2"
      agent_tokens_resolve
      agent_static_keys_apply
      printf "GW=%s\nMCP=%s\nREMOVED=%s\n" "$(identity_env_get TOKENFUSE_AGENT_TOKENS_STATIC_KEYS)" \
        "$(identity_env_get TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS)" "$REMOVED_STATIC_IDS"
    ' _ "$wide" "$lib2" "$1" 2>&1
  }
  out="$(wide_run "")" || out="DIE: $out"
  printf '%s\n' "$out" | grep -qx 'GW=felyx,broker' \
    || fail "J. a .env widened by a 1.3.1 re-run keeps agents and drills on the gateway list: $(printf '%s' "$out" | grep -E '^(GW=|DIE)' | head -1); the upgrade must drop them unless STATIC_KEY_IDS names them"
  printf '%s\n' "$out" | grep -qx 'MCP=stack-single' \
    || fail "J. a .env widened by a 1.3.1 re-run keeps agents and drills on the broker's list: $(printf '%s' "$out" | grep -E '^MCP=' | head -1)"
  printf '%s\n' "$out" | grep -q '^REMOVED=.*agents' \
    || fail "J. the run does not report that it removed agents from the static lists, so the closing report cannot say so"
  out="$(wide_run "agents")" || out="DIE: $out"
  printf '%s\n' "$out" | grep -qx 'GW=felyx,broker,agents' \
    || fail "J. STATIC_KEY_IDS=agents does not keep agents on the gateway list: $(printf '%s' "$out" | grep -E '^(GW=|DIE)' | head -1)"
  printf '%s\n' "$out" | grep -qx 'MCP=stack-single,agents' \
    || fail "J. STATIC_KEY_IDS=agents does not keep agents on the broker's list: $(printf '%s' "$out" | grep -E '^MCP=' | head -1)"
else
  fail "J. the two-run section did not lift the installer's functions, so the widened .env was not measured"
fi
# J, the report: the closing report says what the run removed, and how to keep one.
printf '%s\n' "$BLOCK" | grep -q 'Removed from the static allow-lists on this run' \
  || fail "J. the closing report does not say which keys this run removed from the static allow-lists"
printf '%s\n' "$BLOCK" | grep -q 'To keep one, name it in STATIC_KEY_IDS' \
  || fail "J. the closing report does not say how to keep a removed key (STATIC_KEY_IDS)"

# K. THE DOOR ORIGINS FOLLOW THE BIND THE BOX HAS (CLAUDE.md invariants 11 and 40, 1.4.0, D16). A re-run takes
# GATEWAY_BIND from .env only when section 3 sources .env, and the agent-tokens block runs before that, writing
# the doors' DPoP origins from the bind. Measured on forge 2026-10-25, GATEWAY_BIND=192.168.1.10 in .env and
# nothing in the environment: the origins named 127.0.0.1, where the gateway is not published, so an agent's
# valid token was refused at both doors, and a proof addressed to 127.0.0.1 passed. 0.0.0.0 maps to loopback,
# so that bind is the case that must stay green.
PROBE_BLOCK="$(sed -n '/^# gateway-probe: begin$/,/^# gateway-probe: end$/p' install.sh)"
if [ -z "$PROBE_BLOCK" ] || [ -z "$BLOCK" ]; then
  fail "K. install.sh has no '# gateway-probe:' or '# agent-tokens:' block, so the door origins were not measured against the bind"
else
  printf '%s\n' "$PROBE_BLOCK" >"$scratch/k-probe.sh"
  printf '%s\n' "$BLOCK" >"$scratch/k-block.sh"
  cat >"$scratch/k-stubs.sh" <<'STUBS'
die()  { echo "DIE: $*"; exit 3; }
note() { :; }
gen() { head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "$1"; }
identity_entry_why() { :; }
identity_env_get() {
  local v=""
  [ -f "$STACK_DIR/.env" ] && v="$(sed -n "s/^$1='\(.*\)'\$/\1/p" "$STACK_DIR/.env" | tail -1)"
  printf '%s' "$v"
}
identity_env_set() {
  local f="$STACK_DIR/.env"
  touch "$f"
  grep -v "^$1=" "$f" >"$f.tmp" || true
  printf "%s='%s'\n" "$1" "$2" >>"$f.tmp"
  mv -f "$f.tmp" "$f"
}
mint_env_forget() { local f="$STACK_DIR/.env"; [ -f "$f" ] && { grep -v "^$1=" "$f" >"$f.tmp" || true; mv -f "$f.tmp" "$f"; }; return 0; }
mint_env_secret() { [ -n "$(identity_env_get "$1")" ] || identity_env_set "$1" "$(gen 40)"; }
upstream_put() { mkdir -p "$2"; printf '%s' "$1" >"$2/key"; }
STUBS
  for bind in 192.168.1.10 0.0.0.0; do
    d="$(mktemp -d "$scratch/k.XXXXXX")"
    printf "GATEWAY_BIND='%s'\nRECORD_TRUST_DOMAIN='home.example'\n" "$bind" >"$d/.env"
    if out="$(env -u GATEWAY_BIND bash -c '
      set -euo pipefail
      STACK_DIR="$1"; MINT_ON=1; WITH_AGENT_TOKENS=""; WITH_DELEGATION=""; STATIC_KEY_IDS=""
      GATEWAY_BIND="${GATEWAY_BIND:-127.0.0.1}"
      . "$2/k-stubs.sh"
      . "$2/k-probe.sh"
      gateway_probe_resolve
      . "$2/k-block.sh"
      agent_tokens_resolve
      agent_tokens_apply
      printf "URL=%s\nBROKER_URL=%s\nORIGINS=%s\n" "$(identity_env_get TOKENFUSE_DELEGATION_URL)" \
        "$(identity_env_get MCP_BROKER_DELEGATION_URL)" "$(identity_env_get WARDRYX_AGENT_TOKEN_DOOR_ORIGINS)"
    ' _ "$d" "$scratch" 2>&1)"; then
      case "$bind" in 0.0.0.0) host=127.0.0.1 ;; *) host="$bind" ;; esac
      printf '%s\n' "$out" | grep -qx "URL=http://$host:4100" \
        || fail "K. with GATEWAY_BIND=$bind in .env, the gateway's delegation origin is $(printf '%s' "$out" | grep '^URL=') and should be http://$host:4100: the block took the bind this run started with, not the one the box has"
      printf '%s\n' "$out" | grep -qx "BROKER_URL=http://$host:4200" \
        || fail "K. with GATEWAY_BIND=$bind in .env, the broker's delegation origin is $(printf '%s' "$out" | grep '^BROKER_URL=') and should be http://$host:4200"
      printf '%s\n' "$out" | grep '^ORIGINS=' | grep -q "http://$host:4100" \
        || fail "K. with GATEWAY_BIND=$bind in .env, wardryx's door origins do not name http://$host:4100"
    else
      fail "K. with GATEWAY_BIND=$bind in .env, the agent-tokens block did not run: $out"
    fi
  done
fi

if [ "$problems" -ne 0 ]; then
  printf 'agent-tokens-are-wired: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: agent-tokens-are-wired (invariants 40 and 47)"
