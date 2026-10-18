#!/usr/bin/env bash
#
# Enforces invariant 35 of CLAUDE.md: the gateway never answers an unnamed caller.
# It refuses to start without client keys, its identity map is strict, and an install
# that was given no keys file mints one key for the console's copilot (Felyx) and one
# for the operator's agents, each bound in the map to its own agent ids.
#
# WHAT THIS IS ABOUT
#
# Finding F-001 of the 2026-10-17 review: with TOKENFUSE_CLIENT_KEYS unset the gateway
# admits every caller, and `x-fuse-agent-id` is whatever the caller wrote, so one agent
# can speak as another and take its policy and its budget; a kill keyed by run id is
# evaded by a new run id. Until this change compose passed `${GATEWAY_CLIENT_KEYS:-}`
# and the installer set keys only when an operator gave a file (invariant 29), so a
# default box answered anyone who reached port 4100. @decided 2026-10-17 (paraphrased):
# close the review's findings, defaults first. So keys are on by default.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. Every service whose image is the tokenfuse gateway image and whose
#      command is the bare binary (the subjects gateway-cache-is-off.sh derives) sets
#      TOKENFUSE_IDENTITY_STRICT: enforce. One with no `profiles:` (it starts on every
#      box) sets TOKENFUSE_CLIENT_KEYS to a required `${VAR:?...}`: a `:-` default or a
#      literal fails. One behind a profile is the OpenAI door's business (openai-door.sh),
#      because compose reads a profile's variables on every box and `:?` there would stop
#      every box that never asked for it.
#   B. RESOLVED. `docker compose config` with the required secrets set and the client
#      keys left out fails and names the keys variable; with them set, each always-on
#      gateway reads them.
#   C. THE INSTALLER, `# gen:`, `# identity-files:` and `# identity-mint:` lifted out of
#      install.sh and run in scratch STACK_DIRs:
#        - a box with nothing given mints Felyx's key and the agents' key into .env (40
#          characters, two different secrets), builds the spec `<felyx>:felyx,<agents>:agents`,
#          a map binding `felyx` to exactly Felyx's id and `agents` to `agent://<td>/agents/*`
#          (a pattern that does not match Felyx's id), and writes the agents' key to
#          $STACK_DIR/agent-key, 0600, holding that secret and nothing else, and the marker;
#        - a re-run keeps every secret, the file and the map byte for byte;
#        - a Felyx key already in .env is kept, an empty one is filled;
#        - the trust domain comes from RECORD_TRUST_DOMAIN in .env, and one that is not a
#          name is refused;
#        - a box holding the operator's own keys mints nothing;
#        - a map with no keys, a map-only box, and one file of the pair on a minted box are
#          refused before .env is touched, naming what to give;
#        - the operator taking over with both files drops the marker;
#        - nothing printed holds a secret, and the closing note names the file and the
#          namespace and says the key is needed, and never prints the key.
#   D. THE GATEWAY IMAGE compose pins reads the minted pair through the identity block's
#      own check: two keys, the map on, nothing refused.
#   E. ORDER, in install.sh: mint_resolve after identity_resolve and before the first
#      package install; mint_prepare after .env is written and before the images are
#      pulled; mint_apply after identity_apply and before the first start; the closing
#      report prints mint_reach_note; compose reads before section 3e carry the keys.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway service, no mint block, no functions in it, or no Docker: each is reported
# and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# ---- A. compose ----------------------------------------------------------------
python3 - compose.yaml "$scratch/always" <<'PY' || problems=$((problems + 1))
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


def is_gateway(block):
    image = any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/tokenfuse:", l) for l in block)
    bare = any(re.match(r'^\s*command:\s*\["/usr/local/bin/tokenfuse"\]\s*$', l) for l in block)
    return image and bare


def env(block):
    out = {}
    inside = False
    for line in block:
        if re.match(r"^    environment:\s*$", line):
            inside = True
            continue
        if inside:
            if re.match(r"^    \S", line):
                break
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            m = re.match(r"([A-Z_]+):\s*(.*?)\s*$", s)
            if m:
                out[m.group(1)] = m.group(2).strip('"').strip("'")
    return out


subjects = sorted(n for n, b in blocks.items() if is_gateway(b))
if not subjects:
    print("FAIL: no service in compose.yaml both uses the tokenfuse gateway image and runs it")
    print("      with no subcommand, so this gate measured NOTHING about who may call a")
    print("      metered door. Silence here is not health.")
    sys.exit(1)
bad = 0
always = []
for name in subjects:
    b = blocks[name]
    e = env(b)
    profiled = any(re.match(r"^    profiles:", l) for l in b)
    strict = e.get("TOKENFUSE_IDENTITY_STRICT")
    if strict != "enforce":
        print(f"FAIL: {name} sets TOKENFUSE_IDENTITY_STRICT: {strict}, not enforce. Under warn or off a key")
        print("      speaking as an agent its binding does not name is only noted, and the call goes on.")
        bad += 1
    if profiled:
        continue
    keys = e.get("TOKENFUSE_CLIENT_KEYS")
    m = re.fullmatch(r"\$\{([A-Z_]+):\?[^}]*\}", keys or "")
    if keys is None:
        print(f"FAIL: {name} sets no TOKENFUSE_CLIENT_KEYS, so it answers every caller that reaches it.")
        bad += 1
    elif not m:
        print(f"FAIL: {name} sets TOKENFUSE_CLIENT_KEYS: {keys}, not a required ${{VAR:?...}}. It starts on every")
        print("      box, and with a `:-` default or a literal a box whose .env lacks the keys starts a")
        print("      gateway that answers anyone, which tokenfuse reads as client auth off.")
        bad += 1
    else:
        always.append(f"{name} {m.group(1)}")
if not always and not bad:
    print("FAIL: every gateway sits behind a profile, so no gateway starts on a default box and this")
    print("      gate measured NOTHING about the door every box runs.")
    bad += 1
open(sys.argv[2], "w").write("\n".join(always) + ("\n" if always else ""))
if bad:
    sys.exit(1)
print("compose: " + ", ".join(a.split()[0] + " requires " + a.split()[1] for a in always)
      + "; every gateway's identity map is strict")
PY

# ---- B. resolved ---------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
elif [ -s "$scratch/always" ]; then
  cdir="$scratch/cfg"
  mkdir -p "$cdir"
  cp compose.yaml "$cdir/compose.yaml"
  excl=()
  while read -r _ var; do excl+=(-e "$var"); done <"$scratch/always"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u \
    | grep -v -x "${excl[@]}" | sed 's/$/=fake-not-a-secret/' >"$cdir/base.env"
  unset_args=()
  while read -r _ var; do unset_args+=(-u "$var"); done <"$scratch/always"
  cp "$cdir/base.env" "$cdir/.env"
  if env "${unset_args[@]}" docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" config >/dev/null 2>"$cdir/err"; then
    fail "resolved: a .env with every other secret and no client keys still renders, so a box that lost its keys starts a gateway that answers anyone"
  else
    while read -r svc var; do
      grep -q "$var" "$cdir/err" || fail "resolved: compose refused a .env with no client keys, but not naming $var for $svc: $(head -1 "$cdir/err")"
    done <"$scratch/always"
  fi
  {
    cat "$cdir/base.env"
    while read -r _ var; do printf "%s='gate-resolved-%s-aaaaaaaaaaaaaaaa:k1'\n" "$var" "$var"; done <"$scratch/always"
  } >"$cdir/.env"
  if ! env "${unset_args[@]}" docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" config --format json >"$cdir/cfg.json" 2>"$cdir/err"; then
    fail "resolved: a .env with the client keys set does not render: $(head -1 "$cdir/err")"
  else
    while read -r svc var; do
      got="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1]))["services"].get(sys.argv[2], {}).get("environment") or {}).get("TOKENFUSE_CLIENT_KEYS", "<unset>"))' "$cdir/cfg.json" "$svc")"
      [ "$got" = "gate-resolved-$var-aaaaaaaaaaaaaaaa:k1" ] || fail "resolved: $svc reads TOKENFUSE_CLIENT_KEYS '$got', not the keys .env gives as $var"
    done <"$scratch/always"
  fi
fi

# ---- C. the installer's mint block ----------------------------------------------
GEN="$(sed -n '/^# gen: begin$/,/^# gen: end$/p' install.sh)"
IDB="$(sed -n '/^# identity-files: begin$/,/^# identity-files: end$/p' install.sh)"
MINT="$(sed -n '/^# identity-mint: begin$/,/^# identity-mint: end$/p' install.sh)"
mint_ok=0
if [ -z "$MINT" ]; then
  fail "install.sh has no '# identity-mint: begin' .. 'end' block, so this measured nothing about the keys a box gets when nobody gave it any"
elif [ -z "$GEN" ] || [ -z "$IDB" ]; then
  fail "install.sh has no '# gen:' or '# identity-files:' block for the mint block to run with, so this measured nothing"
else
  missing=""
  for f in mint_resolve mint_prepare mint_apply mint_reach_note; do
    grep -q "^$f()" <<<"$MINT" || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    fail "the identity-mint block defines no$missing, so this measured nothing"
  else
    mint_ok=1
  fi
fi

op="$scratch/op"
mkdir -p "$op"
K1="gate-secret-aaaaaaaaaaaaaaaaaaaaaa1"
K2="gate-secret-bbbbbbbbbbbbbbbbbbbbbb2"
printf '%s:treasury-bots\n%s:research-bots\n' "$K1" "$K2" >"$op/keys.txt"
cat >"$op/map.json" <<'JSON'
{"units":[{"id":"treasury"},{"id":"research"}],"keys":[{"key_id":"treasury-bots","unit":"treasury","agents":["agent://bank.example/treasury/*"]},{"key_id":"research-bots","unit":"research","agents":["agent://bank.example/research/*"]}]}
JSON
FELYX_SET="gate-felyx-set-by-hand-cccccccccccccc"

mk() { local d; d="$(mktemp -d "$scratch/box.XXXXXX")"; printf 'SENTINEL=1\n' >"$d/.env"; printf '%s' "$d"; }
# run DIR STEPS [VAR=VALUE...]: STEPS is resolve (section 0f), prepare (0f, then
# section 3's mint), apply (0f, 3, then the agent key file and the marker) or image
# (0f, 3, the identity block's check and apply with $IMG, then the mint's apply).
run() {
  local d="$1" steps="$2"
  shift 2
  (
    cd "$op" || exit 99
    env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" GEN="$GEN" IDB="$IDB" MINT="$MINT" STEPS="$steps" IMG="${IMG:-}" "$@" bash -c '
      set -euo pipefail
      note() { printf "note: %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      eval "$GEN"; eval "$IDB"; eval "$MINT"
      identity_door main
      identity_resolve
      mint_resolve
      printf "mint_on=%s\n" "$MINT_ON"
      [ "$STEPS" != resolve ] || exit 0
      mint_prepare
      printf "spec=%s\nmap=%s\n" "$IDENTITY_KEYS_NEW" "$IDENTITY_MAP_SRC"
      [ -z "$IDENTITY_MAP_SRC" ] || cp "$IDENTITY_MAP_SRC" "$STACK_DIR/map.seen"
      [ "$STEPS" != prepare ] || exit 0
      if [ "$STEPS" = image ]; then
        identity_check "$IMG"
        identity_apply
        printf "count=%s map_on=%s\n" "$IDENTITY_KEYS_COUNT" "$IDENTITY_MAP_ON"
      fi
      mint_apply
      printf "minted=%s\n" "${IDENTITY_MINTED:-}"
      mint_reach_note >"$STACK_DIR/reach.txt"' 2>&1
    printf 'rc=%s\n' "$?"
  )
}
rc_of() { sed -n 's/^rc=//p' <<<"$1" | tail -1; }
val_of() { sed -n "s/^$2=//p" <<<"$1" | tail -1; }
envv() { sed -n "s/^$2=//p" "$1/.env" | tail -1 | sed "s/^'//; s/'\$//"; }
mode_of() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }

if [ "$mint_ok" = 1 ]; then
  # A box with nothing given.
  d="$(mk)"
  out="$(run "$d" apply)"
  if [ "$(rc_of "$out")" != 0 ]; then
    fail "a box given no keys file and no map was refused: $(grep '^die' <<<"$out")"
  else
    fk="$(envv "$d" GENARYX_COPILOT_FUSE_KEY)"
    ak="$(envv "$d" GATEWAY_AGENT_KEY)"
    [ "$(val_of "$out" mint_on)" = 1 ] || fail "a box given no files did not decide to mint (mint_on=$(val_of "$out" mint_on))"
    [[ "$fk" =~ ^[A-Za-z0-9]{40}$ ]] || fail "the installer did not mint Felyx's key into .env as GENARYX_COPILOT_FUSE_KEY, 40 characters"
    [[ "$ak" =~ ^[A-Za-z0-9]{40}$ ]] || fail "the installer did not mint the agents' key into .env as GATEWAY_AGENT_KEY, 40 characters"
    [ "$fk" != "$ak" ] || fail "Felyx and the agents were given the same secret, so one could speak as the other"
    dk="$(envv "$d" GATEWAY_DRILLS_KEY)"
    [[ "$dk" =~ ^[A-Za-z0-9]{40}$ ]] || fail "the installer did not mint the fire drills' key into .env as GATEWAY_DRILLS_KEY, 40 characters"
    [ "$(val_of "$out" spec)" = "$fk:felyx,$ak:agents,$dk:drills" ] || fail "the minted spec is not <felyx>:felyx,<agents>:agents,<drills>:drills"
    if [ -f "$d/agent-key" ]; then
      [ "$(mode_of "$d/agent-key")" = 600 ] || fail "the agents' key file $d/agent-key is mode $(mode_of "$d/agent-key"), not 600: another account on the box could read it"
      [ "$(cat "$d/agent-key")" = "$ak" ] || fail "the agents' key file does not hold exactly the agents' key"
    else
      fail "the installer wrote no agents' key file at \$STACK_DIR/agent-key for the operator to hand out"
    fi
    [ "$(envv "$d" GATEWAY_IDENTITY_MINTED)" = 1 ] || fail "the marker GATEWAY_IDENTITY_MINTED=1 was not written, so a re-run could not tell minted keys from the operator's"
    head -n 1 "$d/.env" | grep -qx 'SENTINEL=1' || fail "minting disturbed the rest of .env"
    if [ -s "$d/map.seen" ]; then
      python3 - "$d/map.seen" <<'PY' || problems=$((problems + 1))
import fnmatch, json, sys
m = json.load(open(sys.argv[1]))
units = {u.get("id") for u in m.get("units", [])}
keys = {k.get("key_id"): k for k in m.get("keys", [])}
felyx_id = "agent://local/genaryx/felyx"
bad = 0
def no(msg):
    global bad
    print("FAIL: " + msg); bad += 1
if set(keys) != {"felyx", "agents", "drills"}:
    no(f"the minted map binds key ids {sorted(keys)}, not felyx, agents and drills")
else:
    if keys["felyx"].get("agents") != [felyx_id]:
        no(f"the minted map binds felyx to {keys['felyx'].get('agents')}, not exactly [{felyx_id}]")
    pats = keys["agents"].get("agents") or []
    if pats != ["agent://local/agents/*"]:
        no(f"the minted map binds the agents' key to {pats}, not [agent://local/agents/*]")
    for p in pats:
        if p == "*" or (p.endswith("*") and felyx_id.startswith(p[:-1])) or p == felyx_id:
            no(f"the agents' key may speak as Felyx: its pattern {p} matches {felyx_id}")
    if keys["drills"].get("agents") != ["agent://mockryx.local/*"]:
        no(f"the minted map binds the drills' key to {keys['drills'].get('agents')}, not [agent://mockryx.local/*]")
    for p in keys["drills"].get("agents") or []:
        if p == "*" or (p.endswith("*") and felyx_id.startswith(p[:-1])) or p == felyx_id:
            no(f"the drills' key may speak as Felyx: its pattern {p} matches {felyx_id}")
    for k in keys.values():
        if k.get("unit") not in units:
            no(f"the minted map binds {k.get('key_id')} to unit {k.get('unit')!r}, which it does not declare")
if any("budget_usd_month" in u for u in m.get("units", [])):
    no("the minted map gives a unit a monthly budget: attribution only, a budget is the operator's decision")
if m.get("prefixes"):
    no("the minted map has prefixes[], which attribute spend by a header the caller writes")
sys.exit(1 if bad else 0)
PY
    else
      fail "the installer composed no identity map for the minted keys"
    fi
    # What the block printed, without the spec line this harness prints itself.
    said="$(grep -v '^spec=' <<<"$out")$(cat "$d/reach.txt" 2>/dev/null)"
    for s in "$fk" "$ak"; do
      [ -z "$s" ] || ! grep -qF -- "$s" <<<"$said" || fail "a minted secret appears in what the installer printed"
    done
    reach="$(cat "$d/reach.txt" 2>/dev/null)"
    grep -qF "$d/agent-key" <<<"$reach" || fail "the closing note does not name the agents' key file ($d/agent-key), so the operator learns of the change from refused calls"
    grep -qF 'agent://local/agents/' <<<"$reach" || fail "the closing note does not say which agent ids the key may speak as (agent://local/agents/...)"
    grep -qF 'x-fuse-key' <<<"$reach" && grep -qF 'x-fuse-agent-id' <<<"$reach" || fail "the closing note does not name the x-fuse-key and x-fuse-agent-id headers"

    # A re-run keeps everything, byte for byte.
    cp "$d/.env" "$d/.env.before"; cp "$d/agent-key" "$d/key.before" 2>/dev/null; cp "$d/map.seen" "$d/map.before" 2>/dev/null
    out2="$(run "$d" apply)"
    [ "$(rc_of "$out2")" = 0 ] || fail "a re-run of a minted box was refused: $(grep '^die' <<<"$out2")"
    [ "$(envv "$d" GENARYX_COPILOT_FUSE_KEY)" = "$fk" ] && [ "$(envv "$d" GATEWAY_AGENT_KEY)" = "$ak" ] \
      || fail "a re-run minted a new secret over the kept one, so every agent holding the old key would be refused"
    cmp -s "$d/.env" "$d/.env.before" || fail "a re-run of a minted box changed .env"
    cmp -s "$d/agent-key" "$d/key.before" || fail "a re-run of a minted box changed the agents' key file"
    cmp -s "$d/map.seen" "$d/map.before" || fail "a re-run of a minted box built a different map, which restarts the gateway for nothing"
    [ "$(val_of "$out2" spec)" = "$fk:felyx,$ak:agents,$(envv "$d" GATEWAY_DRILLS_KEY):drills" ] || fail "a re-run built a different spec from the same .env"

    # The operator takes over with both files: their keys, and the marker goes.
    out3="$(run "$d" apply CLIENT_KEYS_FILE=keys.txt IDENTITY_MAP_FILE=map.json)"
    [ "$(rc_of "$out3")" = 0 ] && [ "$(val_of "$out3" mint_on)" = 0 ] || fail "a minted box given both files did not hand over to them: $(grep -E '^(die|mint_on)' <<<"$out3")"
    grep -q '^GATEWAY_IDENTITY_MINTED=' "$d/.env" && fail "the operator took over with both files and the marker was kept, so the next run would mint over their keys"
  fi

  # Felyx's key already set by hand is kept; an empty one is filled.
  d="$(mk)"
  printf "GENARYX_COPILOT_FUSE_KEY='%s'\n" "$FELYX_SET" >>"$d/.env"
  out="$(run "$d" prepare)"
  [ "$(envv "$d" GENARYX_COPILOT_FUSE_KEY)" = "$FELYX_SET" ] || fail "a GENARYX_COPILOT_FUSE_KEY already in .env was rewritten"
  [ "$(val_of "$out" spec)" = "$FELYX_SET:felyx,$(envv "$d" GATEWAY_AGENT_KEY):agents,$(envv "$d" GATEWAY_DRILLS_KEY):drills" ] || fail "a Felyx key already in .env was not the one bound as felyx"
  d="$(mk)"
  printf "GENARYX_COPILOT_FUSE_KEY=\n" >>"$d/.env"
  out="$(run "$d" prepare)"
  [[ "$(envv "$d" GENARYX_COPILOT_FUSE_KEY)" =~ ^[A-Za-z0-9]{40}$ ]] || fail "an empty GENARYX_COPILOT_FUSE_KEY in .env was left empty, so Felyx would present no key"
  [ "$(grep -c '^GENARYX_COPILOT_FUSE_KEY=' "$d/.env")" = 1 ] || fail "filling an empty GENARYX_COPILOT_FUSE_KEY left two lines in .env"

  # The trust domain comes from .env; one that is not a name is refused.
  d="$(mk)"
  printf "RECORD_TRUST_DOMAIN=acme.example\n" >>"$d/.env"
  out="$(run "$d" prepare)"
  grep -qF '"agent://acme.example/genaryx/felyx"' "$d/map.seen" 2>/dev/null || fail "RECORD_TRUST_DOMAIN in .env did not set Felyx's id in the minted map"
  d="$(mk)"
  printf "RECORD_TRUST_DOMAIN='a b'\n" >>"$d/.env"
  out="$(run "$d" prepare)"
  [ "$(rc_of "$out")" != 0 ] || fail "a RECORD_TRUST_DOMAIN with a space was put into the identity map"

  # The operator's own keys, kept from an earlier run: nothing minted.
  d="$(mk)"
  printf "GATEWAY_CLIENT_KEYS='%s:treasury-bots,%s:research-bots'\n" "$K1" "$K2" >>"$d/.env"
  cp "$d/.env" "$d/.env.before"
  out="$(run "$d" prepare)"
  [ "$(val_of "$out" mint_on)" = 0 ] || fail "a box with the operator's own keys in .env decided to mint"
  cmp -s "$d/.env" "$d/.env.before" || fail "a box with the operator's own keys got minted keys in .env"
  [ -z "$(val_of "$out" spec)" ] || fail "a box with the operator's own keys had its spec replaced by minted keys"

  # Refusals, before .env is touched.
  refused() { # label needle [VAR=VALUE...]; the box's extra .env lines on stdin
    local label="$1" needle="$2" d out
    shift 2
    d="$(mk)"
    cat >>"$d/.env"
    cp "$d/.env" "$d/.env.before"
    out="$(run "$d" resolve "$@")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "$label was accepted"
    elif ! grep -qF -- "$needle" <<<"$out"; then
      fail "$label was refused, but not naming $needle: $(grep '^die' <<<"$out")"
    fi
    cmp -s "$d/.env" "$d/.env.before" || fail "$label was refused after .env was changed"
  }
  refused "a map with no keys file on a box with no keys" CLIENT_KEYS_FILE IDENTITY_MAP_FILE=map.json </dev/null
  printf "GATEWAY_IDENTITY_MAP='/etc/tokenfuse/identity/identity.json'\n" | refused "a box with a map and no keys (map-only)" GATEWAY_IDENTITY_MAP
  printf "GATEWAY_IDENTITY_MINTED=1\nGATEWAY_CLIENT_KEYS='%s:felyx,%s:agents'\n" "$K1" "$K2" \
    | refused "a keys file alone on a box whose keys were minted" IDENTITY_MAP_FILE CLIENT_KEYS_FILE=keys.txt
  printf "GATEWAY_IDENTITY_MINTED=1\nGATEWAY_CLIENT_KEYS='%s:felyx,%s:agents'\n" "$K1" "$K2" \
    | refused "a map alone on a box whose keys were minted" CLIENT_KEYS_FILE IDENTITY_MAP_FILE=map.json
fi

# ---- D. the gateway image reads the minted pair ----------------------------------
if [ "$mint_ok" = 1 ]; then
  IMG="$(sed -n 's/^    image: \${TOKENFUSE_IMAGE:-\(ghcr\.io\/taipanbox\/tokenfuse:[^}]*\)}$/\1/p' compose.yaml | head -n 1)"
  if [ -z "$IMG" ]; then
    fail "compose.yaml names no \${TOKENFUSE_IMAGE:-ghcr.io/taipanbox/tokenfuse:...} image, so the minted pair could not be read by it"
  elif ! docker version >/dev/null 2>&1; then
    fail "no Docker here, so the gateway image could not read the minted pair. This gate does not pass on a box that cannot run it."
  elif ! docker image inspect "$IMG" >/dev/null 2>&1 && ! docker pull -q "$IMG" >/dev/null 2>&1; then
    fail "could not pull $IMG, so the minted pair could not be read by it"
  else
    d="$(mk)"
    out="$(IMG="$IMG" run "$d" image)"
    if [ "$(rc_of "$out")" != 0 ]; then
      fail "the pinned gateway image refused the pair the installer minted: $(grep '^die' <<<"$out" | cut -c1-300)"
    else
      grep -qx 'count=3 map_on=1' <<<"$out" || fail "the pinned gateway image did not hold three keys and the map for the minted set: $(grep '^count' <<<"$out")"
      [ "$(envv "$d" GATEWAY_CLIENT_KEYS)" = "$(val_of "$out" spec)" ] || fail "the identity block did not write the minted spec to GATEWAY_CLIENT_KEYS"
      cmp -s "$d/map.seen" "$d/identity/identity.json" || fail "the identity block did not install the minted map"
    fi
  fi
fi

# ---- E. order ---------------------------------------------------------------------
if [ "$mint_ok" = 1 ]; then
  ln_of() { grep -n -- "$1" install.sh | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1 | cut -d: -f1; }
  first_apt="$(grep -n '^[[:space:]]*apt-get ' install.sh | head -n 1 | cut -d: -f1)"
  resolve_line="$(ln_of '^identity_resolve$')"
  mresolve_line="$(ln_of '^mint_resolve$')"
  env_written="$(ln_of '^  chmod 600 .env$')"
  mprepare_line="$(ln_of '^mint_prepare$')"
  pull_line="$(ln_of 'config --images')"
  apply_line="$(ln_of '^identity_apply$')"
  mapply_line="$(ln_of '^mint_apply$')"
  first_up="$(ln_of '"\${COMPOSE\[@\]}".* up -d')"
  for v in first_apt resolve_line mresolve_line env_written mprepare_line pull_line apply_line mapply_line first_up; do
    [ -n "${!v}" ] || fail "could not find $v in install.sh, so the order of the mint steps is unknown"
  done
  if [ -n "$first_apt" ] && [ -n "$resolve_line" ] && [ -n "$mresolve_line" ]; then
    [ "$mresolve_line" -gt "$resolve_line" ] && [ "$mresolve_line" -lt "$first_apt" ] \
      || fail "mint_resolve (line $mresolve_line) does not sit after identity_resolve (line $resolve_line) and before the first package install (line $first_apt), so a refused pair would arrive after something was installed"
  fi
  if [ -n "$env_written" ] && [ -n "$mprepare_line" ] && [ -n "$pull_line" ]; then
    [ "$mprepare_line" -gt "$env_written" ] && [ "$mprepare_line" -lt "$pull_line" ] \
      || fail "mint_prepare (line $mprepare_line) does not sit after .env is written (line $env_written) and before the images are pulled (line $pull_line)"
  fi
  if [ -n "$apply_line" ] && [ -n "$mapply_line" ] && [ -n "$first_up" ]; then
    [ "$mapply_line" -gt "$apply_line" ] && [ "$mapply_line" -lt "$first_up" ] \
      || fail "mint_apply (line $mapply_line) does not sit after identity_apply (line $apply_line) and before the first start (line $first_up)"
  fi
  grep -q '\$(mint_reach_note)' install.sh || fail "the closing report does not print mint_reach_note, so an operator is not told their agents now need the key"
  # The two compose reads before section 3e writes the keys: each carries them, or a
  # first install's pull and image lookup read an empty configuration.
  for pat in 'config --images' '"\$@" config 2>/dev/null'; do
    l="$(grep -n -- "$pat" install.sh | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1)"
    grep -q 'GATEWAY_CLIENT_KEYS=' <<<"$l" || fail "install.sh line ${l%%:*} reads the compose configuration before section 3e writes the client keys, without giving it any"
  done
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 35."
  exit 1
fi
echo "OK: every gateway that starts on a default box requires its client keys, every identity map is strict,"
echo "    and a box given no files mints Felyx's key and the agents' key, binds each to its own ids, keeps"
echo "    them on a re-run, writes the agents' key to a 0600 file and names that file, never the key."
