#!/usr/bin/env bash
#
# Enforces invariant 75 of CLAUDE.md: the MCP broker's tool-call check fails closed, and every
# static key the broker admits is also a gateway key of the same id and secret.
#
# WHY
#
# The broker asks the gateway's `POST /v1/fuse/check-tool-call` before every tools/call. A caller
# with a static key is asked with THAT key (tokenfuse invariant 118); the gateway answers only a
# key it holds, and under TOKENFUSE_AGENT_TOKENS=require only one its static list names. Any other
# key is a 401, which is "no answer". What the broker does with no answer is decided by
# TOKENFUSE_MCP_TAINT_FAILMODE: only the word `closed` closes it, and unset reads open, so the call
# went through with nothing judging it and the only trace was a dependency_failed event. This
# launcher set the variable nowhere, and the installer's own key at the broker (`stack-single`) was
# not a gateway key, so every call it made passed only because the check was open.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. Every service that runs the tokenfuse image with the `mcp-broker` command sets
#      TOKENFUSE_MCP_TAINT_FAILMODE to exactly `closed`, as a literal: no `${...}`, so no switch an
#      operator could turn to open by accident.
#   B. THE INSTALLER, RUN. The mint block, the agent-tokens block and the drills block are lifted out
#      of install.sh and run against a scratch box with agent tokens on and the keys the installer
#      mints. Every id the installer writes to TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS must be, with
#      the same secret as the broker's own key for it: (1) an entry of GATEWAY_CLIENT_KEYS, (2) named
#      on TOKENFUSE_AGENT_TOKENS_STATIC_KEYS, (3) bound in the minted identity map to the agent ids of
#      its own caller and nothing wider (the installer's check key to agent://local.invalid/install-check,
#      the drills' key to agent://mockryx.local/*), in a unit the map declares.
#   C. TWO RUNS. A second run over the same .env writes the same spec, the same map and the same lists.
#   D. A BROKER KEY THE INSTALLER DID NOT MINT is refused on a minted box before anything is started,
#      naming the id, rather than listed without a gateway key.
#   E. THE ORDER in install.sh: the drills' key at the broker exists, then a box's own keys file is checked
#      (broker_callers_apply), then the minted keys are composed (mint_prepare), then the static lists are
#      written; and `status` reads the mode and the callers (broker_callers_status).
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no broker service, no installer block, or an empty broker
# list is reported as measuring nothing and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
  fail "compose.yaml or install.sh is not there, so this gate measured NOTHING about the broker's callers"
  exit 1
fi

# ---- A. compose ----------------------------------------------------------------
python3 - compose.yaml <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()
blocks = {}
section = None
current = None
for line in text.split("\n"):
    top = re.match(r"^([a-z-]+):\s*$", line)
    if top:
        section = top.group(1)
        current = None
        continue
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m and section == "services":
        current = m.group(1)
        blocks[current] = []
        continue
    if section == "services" and current is not None:
        blocks[current].append(line)

subjects = []
for name, block in blocks.items():
    image = any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/tokenfuse:", l) for l in block)
    sub = any(re.match(r'^\s*command:\s*\["mcp-broker"\]\s*$', l) for l in block)
    if image and sub:
        subjects.append((name, block))
if not subjects:
    print("FAIL: no service in compose.yaml uses the tokenfuse image with the mcp-broker command,")
    print("      so this gate measured NOTHING about the broker's failmode. Silence here is not health.")
    sys.exit(1)
bad = 0
for name, block in subjects:
    vals = []
    for line in block:
        m = re.match(r"^      TOKENFUSE_MCP_TAINT_FAILMODE:\s*(.*?)\s*$", line)
        if m:
            vals.append(m.group(1).strip('"').strip("'"))
    if len(vals) != 1:
        print(f"FAIL: {name} sets TOKENFUSE_MCP_TAINT_FAILMODE {len(vals)} time(s), not exactly once: tokenfuse reads an unset one as open")
        bad += 1
    elif vals[0] != "closed":
        print(f"FAIL: {name} sets TOKENFUSE_MCP_TAINT_FAILMODE to {vals[0]!r}, not the literal closed")
        bad += 1
sys.exit(1 if bad else 0)
PY

# ---- B, C, D. the installer, run -------------------------------------------------
GEN="$(sed -n '/^# gen: begin$/,/^# gen: end$/p' install.sh)"
IDB="$(sed -n '/^# identity-files: begin$/,/^# identity-files: end$/p' install.sh)"
MINT="$(sed -n '/^# identity-mint: begin$/,/^# identity-mint: end$/p' install.sh)"
TOK="$(sed -n '/^# agent-tokens: begin$/,/^# agent-tokens: end$/p' install.sh)"
DRL="$(sed -n '/^# drills-broker-key: begin$/,/^# drills-broker-key: end$/p' install.sh)"
for pair in "GEN:gen" "IDB:identity-files" "MINT:identity-mint" "TOK:agent-tokens" "DRL:drills-broker-key"; do
  v="${pair%%:*}"
  if [ -z "${!v}" ]; then
    fail "install.sh has no '# ${pair#*:}: begin' .. 'end' block, so this gate measured NOTHING about the broker's callers"
  fi
done
for fn in mint_prepare broker_static_ids agent_static_keys_apply broker_callers_apply; do
  grep -q "^$fn()" <<<"$MINT$TOK" || fail "install.sh defines no $fn, so this gate measured NOTHING about the broker's callers"
done
[ "$problems" -eq 0 ] || { printf 'broker-callers-are-gateway-keys: %d problem(s)\n' "$problems"; exit 1; }

fx() { local s; s="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"; printf '%s' "${s:0:40}"; }

# run DIR [VAR=VALUE...]: one run of the installer's key steps over DIR/.env, as sections 3 and 3e do them:
# mint_prepare (the spec and the map), identity_apply's write of the spec, then the static lists.
run() {
  local d="$1"
  shift
  env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" GEN="$GEN" IDB="$IDB" MINT="$MINT" TOK="$TOK" DRL="$DRL" "$@" bash -c '
    set -euo pipefail
    note() { :; }
    die() { printf "die: %s\n" "$*"; exit 1; }
    eval "$GEN"; eval "$IDB"; eval "$MINT"; eval "$TOK"; eval "$DRL"
    identity_door main
    MINT_ON=1; MINT_DOMAIN=local; AGENT_TOKENS_ON=1; COSTCREW_CEILING_SET=0
    STATIC_KEY_IDS_LIST="${GATE_STATIC:-}"; EXISTING_GATEWAY_IDS="${GATE_EXISTING_GW:-}"; EXISTING_MCP_IDS="${GATE_EXISTING_MCP:-}"
    REMOVED_STATIC_IDS=""
    mint_prepare
    cp "$IDENTITY_MAP_SRC" "$STACK_DIR/map.seen"
    identity_env_set GATEWAY_CLIENT_KEYS "$IDENTITY_KEYS_NEW"
    agent_static_keys_apply
    echo APPLIED' 2>&1
  printf 'rc=%s\n' "$?"
}

secret_in() { sed -n "s/^$2='\{0,1\}\(.*\)/\1/p" "$1/.env" | tail -1 | sed "s/'\$//"; }

mk() { # [EXTRA]: a broker key entry the installer did not mint, appended to the broker's list
  local d extra="${1:+,$1}"; d="$(mktemp -d "$scratch/box.XXXXXX")"
  {
    printf "GENARYX_COPILOT_FUSE_KEY='%s'\n" "$(fx)"
    printf "GATEWAY_AGENT_KEY='%s'\n" "$(fx)"
    printf "GATEWAY_DRILLS_KEY='%s'\n" "$(fx)"
    printf "GATEWAY_BROKER_KEY='%s'\n" "$(fx)"
    printf 'TOKENFUSE_MCP_KEYS=%s:stack-single,%s:drills-broker%s\n' "$(fx)" "$(fx)" "$extra"
  } >"$d/.env"
  printf '%s' "$d"
}

check_box() { # DIR LABEL
  local d="$1" label="$2" bl gk gl id msecret gsecret
  bl="$(secret_in "$d" TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS)"
  gk="$(secret_in "$d" GATEWAY_CLIENT_KEYS)"
  gl="$(secret_in "$d" TOKENFUSE_AGENT_TOKENS_STATIC_KEYS)"
  if [ -z "$bl" ]; then
    fail "$label: the broker's static list is empty, so this gate measured NOTHING about the broker's callers"
    return 0
  fi
  python3 - "$d/map.seen" "$bl" "$gk" "$gl" "$d/.env" "$label" <<'PY' || problems=$((problems + 1))
import json
import re
import sys

mapfile, bl, gk, gl, envfile, label = sys.argv[1:7]
m = json.load(open(mapfile))
units = {u.get("id") for u in m.get("units", [])}
keys = {k.get("key_id"): k for k in m.get("keys", [])}
gateway = {}
for e in gk.split(","):
    sec, _, kid = e.rpartition(":")
    gateway[kid] = sec
env = open(envfile).read()
mm = re.search(r"^TOKENFUSE_MCP_KEYS='?([^'\n]*)", env, re.M)
broker = {}
for e in (mm.group(1) if mm else "").split(","):
    sec, _, kid = e.rpartition(":")
    broker[kid] = sec
listed = set(gl.split(","))
narrow = {
    "stack-single": ["agent://local.invalid/install-check"],
    "drills-broker": ["agent://mockryx.local/*"],
}
bad = 0
def no(msg):
    global bad
    print(f"FAIL: {label}: {msg}")
    bad += 1
for kid in bl.split(","):
    if kid not in gateway:
        no(f"the broker admits {kid} and the gateway holds no key of that id, so the closed check refuses every call from it (401)")
        continue
    if gateway[kid] != broker.get(kid):
        no(f"the gateway's key {kid} has another secret than the broker's")
    if kid not in listed:
        no(f"the gateway holds {kid} but its static list does not name it, so under require it refuses the check")
    k = keys.get(kid)
    if k is None:
        no(f"the minted identity map does not bind {kid}, so the gateway (strict) would refuse every call with it")
        continue
    if k.get("unit") not in units:
        no(f"the map binds {kid} to unit {k.get('unit')!r}, which it does not declare")
    want = narrow.get(kid)
    if want is not None and k.get("agents") != want:
        no(f"the map binds {kid} to {k.get('agents')}, not exactly {want}: wider than its caller")
    for p in k.get("agents") or []:
        if p == "*" or p.startswith("agent://local/"):
            no(f"the map lets {kid} speak as {p}, which is an agent of the operator's domain")
sys.exit(1 if bad else 0)
PY
}

# B. a fresh minted box
d="$(mk)"
out="$(run "$d")"
if ! grep -qx 'APPLIED' <<<"$out"; then
  fail "B. a minted box with agent tokens on was not prepared: $(grep '^die' <<<"$out" | head -1)"
else
  check_box "$d" "B"
  # C. a second run over the same .env writes the same spec, map and lists
  cp "$d/.env" "$d/env.before"; cp "$d/map.seen" "$d/map.before"
  out2="$(run "$d")"
  if ! grep -qx 'APPLIED' <<<"$out2"; then
    fail "C. a second run was refused: $(grep '^die' <<<"$out2" | head -1)"
  else
    sort "$d/.env" >"$d/env.after.sorted"; sort "$d/env.before" >"$d/env.before.sorted"
    cmp -s "$d/env.after.sorted" "$d/env.before.sorted" || fail "C. a second run changed .env (a re-run must change nothing it does not have to)"
    cmp -s "$d/map.seen" "$d/map.before" || fail "C. a second run built a different identity map, which restarts the gateway for nothing"
  fi
fi

# D. a broker key this installer did not mint, on a minted box
d="$(mk "$(fx):ops")"
out="$(run "$d" GATE_EXISTING_MCP=ops)"
if grep -qx 'APPLIED' <<<"$out"; then
  fail "D. the broker admits a static key (ops) this installer did not mint, and the run listed it with no gateway key"
else
  grep -q 'ops' <<<"$out" || fail "D. the refusal does not name the id: $(grep '^die' <<<"$out" | head -1)"
fi

# E. the order, and status
ln_of() { grep -n -E "$1" install.sh | head -1 | cut -d: -f1; }
l_drills="$(ln_of '^drills_broker_key_apply$')"; l_callers="$(ln_of '^broker_callers_apply$')"; l_mint="$(ln_of '^mint_prepare$')"
l_static="$(ln_of '^agent_static_keys_apply$')"
if [ -z "$l_drills" ] || [ -z "$l_callers" ] || [ -z "$l_mint" ] || [ -z "$l_static" ]; then
  fail "E. install.sh does not call drills_broker_key_apply, broker_callers_apply, mint_prepare and agent_static_keys_apply each on a line of its own, so the order was not measured"
elif ! { [ "$l_drills" -lt "$l_callers" ] && [ "$l_callers" -lt "$l_mint" ] && [ "$l_mint" -lt "$l_static" ]; }; then
  fail "E. the order is wrong (drills key $l_drills, own keys file $l_callers, mint $l_mint, lists $l_static): a key must exist before it is checked or minted into the gateway, and the lists come last"
fi
grep -qE '^  broker_callers_status$' install.sh || fail "E. status never calls broker_callers_status, so a broker key the gateway does not hold stays unreported"
grep -q 'TOKENFUSE_MCP_TAINT_FAILMODE=closed' install.sh || fail "E. status does not read the broker's failmode off the running broker"

if [ "$problems" -ne 0 ]; then
  printf 'broker-callers-are-gateway-keys: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: broker-callers-are-gateway-keys (invariant 75): the broker's check is closed, and each static key it admits is a gateway key, listed and bound"
