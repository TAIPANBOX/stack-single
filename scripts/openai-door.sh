#!/usr/bin/env bash
#
# Enforces invariant 32 of CLAUDE.md: the OpenAI door is opt-in, a gateway like
# the first in every hardened setting, on keys and a map of its own, on the
# operator's own bind, and never on a box that did not ask for it.
#
# WHAT THIS IS ABOUT
#
# tokenfuse serves one wire per process (docs/26), so an agent whose SDK speaks
# the OpenAI wire (POST /v1/chat/completions) needs a second gateway in front of
# an upstream that speaks it. `tokenfuse-gateway-openai` is that gateway, behind
# the `openai-door` profile, started by `OPENAI_DOOR=1 ./install.sh` and by
# nothing else. It hands each caller's Authorization header to the upstream, so
# this box keeps no provider key for it and a metered upstream bills whoever's
# key the caller sends. @decided 2026-10-13 (paraphrased): the door takes a keys
# file and an identity map of its own, not the gateway's, because a unit's month
# counter lives in one gateway process and a unit in both maps would get its cap
# once on each door.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. `tokenfuse-gateway-openai` runs the gateway's own image default
#      and bare command (so every gate that derives its subjects from those lines
#      judges it too), sits behind `profiles: ["openai-door"]`, serves
#      `TOKENFUSE_WIRE: openai`, and carries every hardened line the gateway does
#      with the same value, written out in its own block and never through a YAML
#      anchor or merge (the gates read blocks line by line). Its upstream is
#      `${OPENAI_DOOR_CLIENT_KEYS:+${OPENAI_DOOR_IDENTITY_MAP:+${OPENAI_DOOR_UPSTREAM:-}}}`:
#      empty unless keys and a map are set, and tokenfuse refuses to start with no
#      upstream. Not `${...:?}`, which compose demands of a profile's services too
#      and which would stop every default box. Its one port line is exactly
#      `${GATEWAY_BIND:-127.0.0.1}:4110:4100`; its events file is
#      `tokenfuse-openai.ndjson` and its data directory is its own, made by
#      init-volumes; its map is mounted from a directory no other gateway mounts;
#      and it sets no delegation and no closure variable.
#   B. THE INSTALLER, `# openai-door: begin` .. `end` lifted out of install.sh with
#      the identity block it calls, run in a scratch STACK_DIR: nothing set
#      changes nothing; OPENAI_DOOR=1 without an upstream, a keys file or a map
#      refuses, naming what is missing, with .env untouched; a door setting with
#      the door off refuses; every unusable upstream (credentials, a query, a
#      fragment, a base URL, another scheme, a shell metacharacter) refuses and is
#      never echoed, and the usable shapes pass; a re-run keeps the door on and
#      changes nothing; OPENAI_DOOR=0 turns it off and keeps its lines; a bad saved
#      value refuses.
#   C. TWO MAPS, ONE UNIT. With the pinned gateway image and the pinned console
#      image (which has python3), door_identity_check, as section 3e runs it: two
#      maps with units of their own are both written; a door map that declares a
#      unit the gateway's map declares is refused, naming the unit, with nothing
#      written and no staging directory left; a gateway with keys and no map
#      leaves nothing to compare.
#   D. ORDER, in install.sh: the door's refusals before the first package install;
#      its files checked after the gateway's and before anything is written, and
#      written before anything starts; every `--profile openai-door` on a line
#      DOOR_ON decides; the door removed by name when it is off; a new door map
#      restarts the door; section 8 asks the running door what it asks the gateway,
#      only on a box that asked for it and never skipped there; and the closing
#      report says who pays.
#   E. RESOLVED. `docker compose config`: a default box has no door and publishes
#      no 4110; with the profile, the door's upstream is empty until keys, a map and
#      an upstream are all set, and its port follows GATEWAY_BIND.
#   F. THE IMAGE. The pinned gateway image, on the openai wire with an empty
#      upstream, refuses to start: that refusal is what makes the upstream line
#      above a hold rather than a default.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No door service, no installer block, no functions in it, no Docker, or no image:
# each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

DOOR=tokenfuse-gateway-openai
UPSTREAM_LINE='${OPENAI_DOOR_CLIENT_KEYS:+${OPENAI_DOOR_IDENTITY_MAP:+${OPENAI_DOOR_UPSTREAM:-}}}'
PORT_LINE='${GATEWAY_BIND:-127.0.0.1}:4110:4100'

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# ---- A. compose ----------------------------------------------------------------
python3 - compose.yaml "$DOOR" "$UPSTREAM_LINE" "$PORT_LINE" <<'PY' || problems=$((problems + 1))
import re
import sys

text, door, upstream_line, port_line = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3], sys.argv[4]

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


def keyed(block, key):
    """The entries under `    key:`, comments and blank lines skipped."""
    out = []
    inside = False
    for line in block:
        if re.match(r"^    " + key + r":\s*$", line):
            inside = True
            continue
        if inside:
            if re.match(r"^    \S", line):
                break
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out.append(s)
    return out


def env(block):
    out = {}
    for s in keyed(block, "environment"):
        m = re.match(r"([A-Z_][A-Z0-9_]*):\s*(.+?)\s*$", s)
        if m:
            out[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return out


def field(block, key):
    for l in block:
        m = re.match(r"^    " + re.escape(key) + r":\s*(.+?)\s*$", l)
        if m:
            return m.group(1)
    return None


def is_gateway(block):
    image = any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/tokenfuse:", l) for l in block)
    bare = any(re.match(r'^\s*command:\s*\["/usr/local/bin/tokenfuse"\]\s*$', l) for l in block)
    return image and bare


if door not in blocks:
    print(f"FAIL: compose.yaml has no {door} service, so this gate measured NOTHING about the")
    print("      OpenAI door. Silence here is not health.")
    sys.exit(1)
gw = blocks.get("tokenfuse-gateway")
if gw is None:
    print("FAIL: compose.yaml has no tokenfuse-gateway service to hold the door's settings")
    print("      against, so this gate measured NOTHING about them.")
    sys.exit(1)
b = blocks[door]
bad = 0


def no(msg, *more):
    global bad
    print("FAIL: " + msg)
    for m in more:
        print("      " + m)
    bad += 1


if field(b, "image") != field(gw, "image"):
    no(f"{door} runs image {field(b, 'image')}, not the gateway's {field(gw, 'image')}.",
       "The door is the gateway's own binary a second time; another image, or another",
       "default, is a second thing to pin and a gate subject that drifts.")
if not is_gateway(b):
    no(f"{door} does not run the gateway image with the bare command, so the gates that",
       "derive their subjects from those lines (cache, declassify key, ceiling, firewall,",
       "PII, identity files) no longer judge it.")
prof = field(b, "profiles")
if prof != '["openai-door"]':
    no(f"{door} sits behind profiles {prof}, not [\"openai-door\"]: without that one profile it",
       "starts on every box that runs `docker compose up`, the boxes that never asked for it.")

e, g = env(b), env(gw)
if e.get("TOKENFUSE_WIRE") != "openai":
    no(f"{door} sets TOKENFUSE_WIRE {e.get('TOKENFUSE_WIRE')!r}, not openai: it would serve the gateway's",
       "wire on a second port, and every OpenAI-shaped call would be refused 400.")
if e.get("TOKENFUSE_UPSTREAM") != upstream_line:
    no(f"{door} sets TOKENFUSE_UPSTREAM {e.get('TOKENFUSE_UPSTREAM')!r}, not {upstream_line}.",
       "The upstream must be empty until the door's keys and map are set, so tokenfuse",
       "refuses to start a door that would forward callers it cannot name; a default would",
       "open it, and `:?` stops every default box (compose reads a profile's variables too).")
HARDENED = [
    "TOKENFUSE_ADDR", "TOKENFUSE_ADMIN_KEYS", "TOKENFUSE_DECLASSIFY_KEY", "TOKENFUSE_MODE",
    "TOKENFUSE_FIREWALL", "TOKENFUSE_DLP_PII", "TOKENFUSE_MAX_RUN_BUDGET_USD", "TOKENFUSE_CACHE",
    "TOKENFUSE_CLOUD_URL", "TOKENFUSE_CLOUD_KEY", "TOKENFUSE_WARDRYX_MODE", "TOKENFUSE_WARDRYX_URL",
    "TOKENFUSE_WARDRYX_KEY", "TOKENFUSE_WARDRYX_FAILMODE", "TOKENFUSE_WARDRYX_TIMEOUT_MS",
    "TOKENFUSE_WARDRYX_CACHE_TTL_MS", "TOKENFUSE_IDENTITY_STRICT",
]
for k in HARDENED:
    if k not in g:
        no(f"tokenfuse-gateway sets no {k}, so the door's copy of it cannot be held to anything.")
    elif e.get(k) != g[k]:
        no(f"{door} sets {k} {e.get(k)!r}, and the gateway sets {g[k]!r}.",
           "The door is a gateway like the first in every hardened setting.")
env_lines = []
inside = False
for l in b:
    if re.match(r"^    environment:\s*$", l):
        inside = True
        continue
    if inside:
        if re.match(r"^    \S", l):
            break
        if l.strip() and not l.strip().startswith("#"):
            env_lines.append(l.strip())
if any(l.startswith("<<") or re.search(r"(^|\s)[*&][A-Za-z]", l) for l in env_lines):
    no(f"{door}'s environment takes a line through a YAML anchor or merge. The gates read each",
       "block line by line, so an anchored setting is one they cannot see. Write it out.")
for k in sorted(e):
    if k.startswith("TOKENFUSE_DELEGATION_") or k == "TOKENFUSE_CLOSURE_SECRET":
        no(f"{door} sets {k}. Delegation and closure stay off on the door: a hand-off proof's",
           "DPoP `htu` is checked against the gateway's 4100 origin, and the console closes",
           "reservations through one gateway only.")

ports = [p.lstrip("-").strip().strip('"').strip("'") for p in keyed(b, "ports")]
if ports != [port_line]:
    no(f"{door} publishes {ports}, not exactly [{port_line}].",
       "The door is on the operator's own bind, the expression the gateway's 4100 uses, so a",
       "box that never widened GATEWAY_BIND never widens this door either.")
if e.get("TOKENFUSE_ADDR") != "0.0.0.0:4100":
    no(f"{door} listens on {e.get('TOKENFUSE_ADDR')!r} inside its container, not 0.0.0.0:4100, the port 4110 maps to.")

ev = e.get("TOKENFUSE_EVENTS_PATH")
if ev != "/var/lib/stack/events/tokenfuse-openai.ndjson":
    no(f"{door} exports to {ev!r}, not /var/lib/stack/events/tokenfuse-openai.ndjson: its own file,",
       "the one stem heraldyx v0.5.0 and idryx v1.2.0 read as tokenfuse. Two gateways on one",
       "chained file fork the chain.")
dd = e.get("TOKENFUSE_DATA_DIR")
others = {n: env(x).get("TOKENFUSE_DATA_DIR") for n, x in blocks.items() if n != door}
clash = sorted(n for n, v in others.items() if v and dd and (v.rstrip("/") == dd.rstrip("/")))
if not dd:
    no(f"{door} sets no TOKENFUSE_DATA_DIR, so its retained-reservation journal lives only in its process.")
elif clash:
    no(f"{door} keeps its data in {dd}, which {', '.join(clash)} keeps too: two gateways would",
       "write one retained-reservation journal.")
elif dd.startswith("/var/lib/stack/traces/"):
    sub = dd[len("/var/lib/stack/traces/"):].rstrip("/")
    init = "\n".join(blocks.get("init-volumes", []))
    if not re.search(r"mkdir -p [^\n]*/vol/traces/" + re.escape(sub) + r"\b", init) or \
       not re.search(r"chown 10001:10001 [^\n]*/vol/traces/" + re.escape(sub) + r"\b", init):
        no(f"init-volumes does not make /vol/traces/{sub} and give it to 10001, the door's uid.")
mounts = [v.lstrip("-").strip().strip('"').strip("'") for v in keyed(b, "volumes")]
idm = [m for m in mounts if m.split(":")[1:2] == ["/etc/tokenfuse/identity"]]
host = idm[0].split(":")[0] if idm else None
if not host:
    no(f"{door} mounts no identity directory at /etc/tokenfuse/identity.")
else:
    for n, x in blocks.items():
        if n == door:
            continue
        for m in [v.lstrip("-").strip().strip('"').strip("'") for v in keyed(x, "volumes")]:
            if m.split(":")[0] == host:
                no(f"{door} mounts its map from {host}, which {n} mounts too: the door reads its own map.")

if bad:
    sys.exit(1)
print(f"compose: {door} is the gateway's image and command behind openai-door, on the openai wire, with")
print(f"         {len(HARDENED)} hardened settings equal to the gateway's, its upstream held on its keys and map,")
print(f"         {port_line}, its own stream, data directory and map, and no delegation or closure")
PY

# ---- B. the installer's block ----------------------------------------------------
DBLOCK="$(sed -n '/^# openai-door: begin$/,/^# openai-door: end$/p' install.sh)"
IBLOCK="$(sed -n '/^# identity-files: begin$/,/^# identity-files: end$/p' install.sh)"
block_ok=0
if [ -z "$DBLOCK" ]; then
  fail "install.sh has no '# openai-door: begin' .. '# openai-door: end' block, so this measured nothing about the installer's half"
elif ! grep -q '^door_resolve()' <<<"$DBLOCK" || ! grep -q '^door_apply()' <<<"$DBLOCK" || ! grep -q '^door_identity_check()' <<<"$DBLOCK" || ! grep -q '^door_units_shared()' <<<"$DBLOCK"; then
  fail "the openai-door block defines no door_resolve, door_apply, door_identity_check or door_units_shared, so this measured nothing"
elif [ -z "$IBLOCK" ]; then
  fail "install.sh has no identity-files block for the door's files to be checked by"
elif ! grep -q '^door_resolve$' install.sh || ! grep -q '^door_apply$' install.sh || ! grep -q '^door_identity_check ' install.sh || ! grep -q '^door_identity_apply$' install.sh; then
  fail "install.sh never calls door_resolve, door_apply, door_identity_check and door_identity_apply, so the block is dead text"
else
  block_ok=1
fi

op="$scratch/op"
mkdir -p "$op"
printf 'gate-door-secret-aaaaaaaaaaaaaaaa1:flint\ngate-door-secret-bbbbbbbbbbbbbbbb2:brume\n' >"$op/door-keys.txt"
cat >"$op/door-map.json" <<'JSON'
{"units": [{"id": "routers", "budget_usd_month": 3}],
 "keys": [{"key_id": "flint", "unit": "routers", "agents": ["agent://lab.invalid/flint/*"]},
          {"key_id": "brume", "unit": "routers", "agents": ["agent://lab.invalid/brume/*"]}]}
JSON
printf 'gate-main-secret-aaaaaaaaaaaaaaaa1:treasury-bots\n' >"$op/main-keys.txt"
cat >"$op/main-map.json" <<'JSON'
{"units": [{"id": "treasury", "budget_usd_month": 20}, {"id": "research", "budget_usd_month": 5}],
 "keys": [{"key_id": "treasury-bots", "unit": "treasury", "agents": ["agent://bank.example/treasury/*"]}]}
JSON
sed 's/"id": "routers"/"id": "treasury"/; s/"unit": "routers"/"unit": "treasury"/g' "$op/door-map.json" >"$op/door-map-shares.json"
UP=https://api.openai.com/v1/chat/completions

mk() {
  local d
  d="$(mktemp -d "$scratch/box.XXXXXX")"
  printf 'SENTINEL=1\n' >"$d/.env"
  printf '%s' "$d"
}
# run DIR [VAR=VALUE...]: door_resolve and door_apply as install.sh runs them, with
# the identity block beside it, from the operator's directory.
run() {
  local d="$1"
  shift
  (
    cd "$op" || exit 99
    env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" DBLOCK="$DBLOCK" IBLOCK="$IBLOCK" "$@" bash -c '
      set -euo pipefail
      note() { printf "note: %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      eval "$IBLOCK"
      eval "$DBLOCK"
      door_resolve
      door_apply
      printf "on=%s set=%s upstream=%s\n" "$DOOR_ON" "$DOOR_SET" "$DOOR_UPSTREAM"'
    printf 'rc=%s\n' "$?"
  ) 2>&1
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
on_of() { printf '%s' "$1" | sed -n 's/^on=\([01]\) .*/\1/p' | tail -1; }

if [ "$block_ok" = 1 ]; then
  # 1. nothing set: the door stays off and nothing is written.
  d="$(mk)"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] && [ "$(on_of "$out")" = 0 ] || fail "nothing set: the door was not left off: $out"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "nothing set: .env was changed, so a default box would carry a door line it never asked for"

  # 2. the door on is refused, naming what is missing, until it has all three.
  refuses() { # label needle VAR=VALUE...
    local label="$1" needle="$2" d out
    shift 2
    d="$(mk)"
    out="$(run "$d" "$@")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "$label was accepted"
    elif ! grep -qF -- "$needle" <<<"$out"; then
      fail "$label was refused without naming $needle: $(grep '^die' <<<"$out")"
    fi
    [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "$label was refused after .env was changed, which is half a job"
  }
  refuses "the door on with no upstream" OPENAI_DOOR_UPSTREAM OPENAI_DOOR=1 OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=door-map.json
  refuses "the door on with no keys file" OPENAI_DOOR_CLIENT_KEYS_FILE OPENAI_DOOR=1 OPENAI_DOOR_UPSTREAM="$UP" OPENAI_DOOR_IDENTITY_MAP_FILE=door-map.json
  refuses "the door on with no identity map" OPENAI_DOOR_IDENTITY_MAP_FILE OPENAI_DOOR=1 OPENAI_DOOR_UPSTREAM="$UP" OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt
  refuses "OPENAI_DOOR=yes" OPENAI_DOOR OPENAI_DOOR=yes
  refuses "an upstream with the door off" "OPENAI_DOOR=1" OPENAI_DOOR_UPSTREAM="$UP"
  refuses "a keys file with the door off" "OPENAI_DOOR=1" OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt

  # 3. every unusable upstream refuses and is never echoed; every usable shape passes.
  bad_up() { # label url
    local d out
    d="$(mk)"
    out="$(run "$d" OPENAI_DOOR=1 OPENAI_DOOR_UPSTREAM="$2" OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=door-map.json)"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "OPENAI_DOOR_UPSTREAM ($1) was accepted"
    elif ! grep -qF OPENAI_DOOR_UPSTREAM <<<"$out"; then
      fail "OPENAI_DOOR_UPSTREAM ($1) was refused without naming the variable"
    elif grep -qF -- "$2" <<<"$out"; then
      fail "OPENAI_DOOR_UPSTREAM ($1) was refused by an answer that echoes it"
    fi
    [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "OPENAI_DOOR_UPSTREAM ($1) was refused after .env was changed"
  }
  bad_up "credentials in it" "https://user:gate-pass-xyz@api.openai.com/v1/chat/completions"
  bad_up "a query" "https://api.openai.com/v1/chat/completions?key=gate-query-xyz"
  bad_up "a fragment" "https://api.openai.com/v1/chat/completions#gate-fragment"
  bad_up "a base URL, not the endpoint" "https://api.openai.com/v1-gate-base"
  bad_up "the Anthropic endpoint" "https://api.anthropic.com/v1/messages-gate"
  bad_up "another scheme" "ftp://gate.example/v1/chat/completions"
  bad_up "no host" "https:///v1/chat/completions-gate"
  bad_up "a space" "https://gate.example/v1 x/chat/completions"
  bad_up "a quote" "https://gate.example/v1'x/chat/completions"
  bad_up "a command substitution" 'https://gate.example/$(touch pwned-by-door)/chat/completions'
  [ ! -e "$op/pwned-by-door" ] || fail "a command in an upstream was executed"
  for good in "$UP" https://openrouter.ai/api/v1/chat/completions http://172.17.0.1:8999/v1/chat/completions "http://[::1]:11434/v1/chat/completions" http://ollama_host:11434/v1/chat/completions; do
    d="$(mk)"
    out="$(run "$d" OPENAI_DOOR=1 OPENAI_DOOR_UPSTREAM="$good" OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=door-map.json)"
    if [ "$(rc_of "$out")" != 0 ] || [ "$(on_of "$out")" != 1 ]; then
      fail "OPENAI_DOOR_UPSTREAM $good was refused and is a usable endpoint: $(grep '^die' <<<"$out")"
      continue
    fi
    grep -qx "OPENAI_DOOR='1'" "$d/.env" && grep -qxF "OPENAI_DOOR_UPSTREAM='$good'" "$d/.env" \
      || fail "the door on with $good did not write OPENAI_DOOR and the upstream into .env, quoted"
    [ "$(head -1 "$d/.env")" = "SENTINEL=1" ] || fail "turning the door on disturbed the rest of .env"
  done

  # 4. a re-run keeps the door on and changes nothing; 0 turns it off and keeps its lines.
  d="$(mk)"
  printf "OPENAI_DOOR='1'\nOPENAI_DOOR_UPSTREAM='%s'\nOPENAI_DOOR_CLIENT_KEYS='gate-door-secret-aaaaaaaaaaaaaaaa1:flint'\nOPENAI_DOOR_IDENTITY_MAP='/etc/tokenfuse/identity/identity.json'\n" "$UP" >>"$d/.env"
  cp "$d/.env" "$d/.env.before"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] && [ "$(on_of "$out")" = 1 ] || fail "a re-run that names nothing did not keep the door on: $(grep '^die' <<<"$out")"
  cmp -s "$d/.env" "$d/.env.before" || fail "a re-run that names nothing changed .env"
  out="$(run "$d" OPENAI_DOOR=0)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(on_of "$out")" = 0 ] || fail "OPENAI_DOOR=0 did not turn the door off: $(grep '^die' <<<"$out")"
  ! grep -q '^OPENAI_DOOR=' "$d/.env" || fail "OPENAI_DOOR=0 left OPENAI_DOOR in .env, so the next run turns the door back on"
  grep -q '^OPENAI_DOOR_CLIENT_KEYS=' "$d/.env" || fail "OPENAI_DOOR=0 dropped the door's keys, so turning it back on needs the files again"
  out="$(run "$d")"
  [ "$(on_of "$out")" = 0 ] || fail "a re-run after OPENAI_DOOR=0 turned the door back on"

  # 5. a saved value the door would not run with refuses on a re-run.
  d="$(mk)"
  printf "OPENAI_DOOR='yes'\n" >>"$d/.env"
  out="$(run "$d")"
  [ "$(rc_of "$out")" != 0 ] || fail "an OPENAI_DOOR='yes' left in .env was accepted"
  d="$(mk)"
  printf "OPENAI_DOOR='1'\nOPENAI_DOOR_UPSTREAM='https://api.openai.com/v1'\nOPENAI_DOOR_CLIENT_KEYS='k'\nOPENAI_DOOR_IDENTITY_MAP='m'\n" >>"$d/.env"
  out="$(run "$d")"
  [ "$(rc_of "$out")" != 0 ] || fail "a base URL left in .env as OPENAI_DOOR_UPSTREAM was accepted on a re-run"
fi

# ---- C. two maps, one unit -----------------------------------------------------------
IMG="$(sed -n 's/^    image: \${TOKENFUSE_IMAGE:-\(ghcr\.io\/taipanbox\/tokenfuse:[^}]*\)}$/\1/p' compose.yaml | head -n 1)"
CIMG="$(sed -n 's/^    image: \${CONSOLE_IMAGE:-\(ghcr\.io\/taipanbox\/genaryx-console:[^}]*\)}$/\1/p' compose.yaml | head -n 1)"
docker_ok=0
if ! docker version >/dev/null 2>&1; then
  fail "no Docker here, so the door's files could not be read by the gateway image. This gate does not pass on a box that cannot run it."
elif [ -z "$IMG" ] || [ -z "$CIMG" ]; then
  fail "compose.yaml names no pinned gateway or console image, so the two maps could not be compared as install.sh compares them"
elif { ! docker image inspect "$IMG" >/dev/null 2>&1 && ! docker pull -q "$IMG" >/dev/null 2>&1; } \
  || { ! docker image inspect "$CIMG" >/dev/null 2>&1 && ! docker pull -q "$CIMG" >/dev/null 2>&1; }; then
  fail "could not pull $IMG or $CIMG, so the two maps could not be compared"
else
  docker_ok=1
fi
# pair DIR VAR=VALUE...: both doors resolved, then section 3e's checks and writes.
pair() {
  local d="$1"
  shift
  (
    cd "$op" || exit 99
    env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" DBLOCK="$DBLOCK" IBLOCK="$IBLOCK" IMG="$IMG" CIMG="$CIMG" \
        OPENAI_DOOR=1 OPENAI_DOOR_UPSTREAM="$UP" "$@" bash -c '
      set -euo pipefail
      note() { printf "note: %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      eval "$IBLOCK"
      eval "$DBLOCK"
      door_resolve
      identity_door main
      identity_resolve
      identity_door openai
      identity_resolve
      identity_door main
      identity_check "$IMG"
      door_identity_check "$IMG" "$CIMG"
      identity_apply
      door_identity_apply
      printf "main=%s door=%s\n" "$IDENTITY_KEYS_COUNT" "$IDENTITY_openai_KEYS_COUNT"'
    printf 'rc=%s\n' "$?"
  ) 2>&1
}
if [ "$block_ok" = 1 ] && [ "$docker_ok" = 1 ]; then
  d="$(mk)"
  out="$(pair "$d" CLIENT_KEYS_FILE=main-keys.txt IDENTITY_MAP_FILE=main-map.json OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=door-map.json)"
  if [ "$(rc_of "$out")" != 0 ]; then
    fail "two maps with units of their own were refused: $(grep '^die' <<<"$out")"
  else
    grep -qx 'main=1 door=2' <<<"$out" || fail "the pair did not leave the gateway one key and the door two: $(grep '^main' <<<"$out")"
    cmp -s "$op/main-map.json" "$d/identity/identity.json" && cmp -s "$op/door-map.json" "$d/identity-openai/identity.json" \
      || fail "each door's map is not in its own directory"
    [ "$(grep -c '^OPENAI_DOOR_CLIENT_KEYS=' "$d/.env")" = 1 ] && [ "$(grep -c '^GATEWAY_CLIENT_KEYS=' "$d/.env")" = 1 ] \
      || fail "the two doors' keys are not one line each in .env"
    ! compgen -G "$d/*.check.*" >/dev/null || fail "a staging directory was left behind after the pair was written"
  fi

  d="$(mk)"
  out="$(pair "$d" CLIENT_KEYS_FILE=main-keys.txt IDENTITY_MAP_FILE=main-map.json OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=door-map-shares.json)"
  if [ "$(rc_of "$out")" = 0 ]; then
    fail "a door map that declares a unit the gateway's map declares was accepted: the unit would get its cap once on each door"
  elif ! grep -q 'both declare unit(s) treasury' <<<"$out"; then
    fail "two maps sharing a unit were refused without naming the unit: $(grep '^die' <<<"$out")"
  fi
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "two maps sharing a unit were refused after .env was changed"
  [ ! -e "$d/identity/identity.json" ] && [ ! -e "$d/identity-openai/identity.json" ] || fail "two maps sharing a unit were refused after a map was put in place"
  ! compgen -G "$d/*.check.*" >/dev/null || fail "a refusal of two maps sharing a unit left a staging directory behind"

  d="$(mk)"
  out="$(pair "$d" CLIENT_KEYS_FILE=main-keys.txt OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=door-map-shares.json)"
  [ "$(rc_of "$out")" = 0 ] || fail "a gateway with keys and no map was compared with the door's map anyway: $(grep '^die' <<<"$out")"

  # A comparison that cannot run is a refusal, never a pass: no image to read the
  # maps with means a shared unit was not ruled out.
  d="$(mk)"
  out="$(CIMG="" pair "$d" CLIENT_KEYS_FILE=main-keys.txt IDENTITY_MAP_FILE=main-map.json OPENAI_DOOR_CLIENT_KEYS_FILE=door-keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=door-map.json)"
  if [ "$(rc_of "$out")" = 0 ]; then
    fail "two maps were written although they could not be compared (no image to read them with), so a unit in both was never ruled out"
  elif ! grep -qF 'could not compare' <<<"$out"; then
    fail "two maps that could not be compared were refused without saying so: $(grep '^die' <<<"$out")"
  fi
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] && ! compgen -G "$d/*.check.*" >/dev/null \
    || fail "two maps that could not be compared were refused after .env was changed or with a staging directory left"
fi

# ---- D. order --------------------------------------------------------------------
if [ "$block_ok" = 1 ]; then
  ln_of() { grep -n -- "$1" install.sh | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1 | cut -d: -f1; }
  first_apt="$(grep -n '^[[:space:]]*apt-get ' install.sh | head -n 1 | cut -d: -f1)"
  resolve_line="$(ln_of '^door_resolve$')"
  door_id_resolve="$(awk '/^if \[ "\$DOOR_ON" = 1 \]; then$/{inside=1; next} inside && /^fi$/{inside=0} inside && /^  identity_resolve$/{print NR; exit}' install.sh)"
  env_line="$(ln_of '^  cat > \.env <<EOF$')"
  apply_line="$(ln_of '^door_apply$')"
  check_line="$(ln_of '^identity_check "\$IDENTITY_IMAGE"$')"
  dcheck_line="$(ln_of '^door_identity_check ')"
  iapply_line="$(ln_of '^identity_apply$')"
  dapply_line="$(ln_of '^door_identity_apply$')"
  first_up="$(ln_of '"\${COMPOSE\[@\]}".* up -d')"
  main_up="$(ln_of 'up -d --remove-orphans')"
  verify_line="$(ln_of '^say "verify"$')"
  [ -n "$first_apt" ] || fail "install.sh has no apt-get line, so the order of the door's refusals is unknown"
  [ -n "$resolve_line" ] && [ "$resolve_line" -lt "${first_apt:-0}" ] \
    || fail "door_resolve (line ${resolve_line:-none}) does not run before the first package install (line $first_apt), so a door refused for a missing file would arrive after something was installed"
  [ -n "$door_id_resolve" ] && [ "$door_id_resolve" -lt "${first_apt:-0}" ] && [ "$door_id_resolve" -gt "${resolve_line:-0}" ] \
    || fail "the door's own identity_resolve (an \`if [ \"\$DOOR_ON\" = 1 ]\` block after door_resolve) does not run before the first package install, so its files are read after something was installed"
  [ -n "$apply_line" ] && [ -n "$env_line" ] && [ "$apply_line" -gt "$env_line" ] || fail "door_apply (line ${apply_line:-none}) runs before .env is written (line ${env_line:-none})"
  if [ -n "$check_line" ] && [ -n "$dcheck_line" ] && [ -n "$iapply_line" ] && [ -n "$dapply_line" ] && [ -n "$first_up" ]; then
    [ "$dcheck_line" -gt "$check_line" ] && [ "$dcheck_line" -lt "$iapply_line" ] \
      || fail "door_identity_check (line $dcheck_line) does not sit between the gateway's check (line $check_line) and the first write (line $iapply_line), so one door's files could be written before the other's were refused"
    [ "$dapply_line" -gt "$iapply_line" ] && [ "$dapply_line" -lt "$first_up" ] \
      || fail "door_identity_apply (line $dapply_line) does not sit after identity_apply and before the first start (line $first_up)"
  else
    fail "could not find identity_check, door_identity_check, identity_apply, door_identity_apply and the first 'up -d' in install.sh, so their order is unknown"
  fi
  # Every line that names the door's profile is decided by DOOR_ON: on the line
  # itself, or by the nearest enclosing `if` whose condition names it.
  undecided="$(python3 - install.sh <<'PY'
import re
import sys
lines = open(sys.argv[1]).read().split("\n")
hits = 0
for i, line in enumerate(lines):
    if line.lstrip().startswith("#") or "--profile openai-door" not in line:
        continue
    hits += 1
    if "DOOR_ON" in line:
        continue
    depth, decided = 0, False
    for j in range(i - 1, -1, -1):
        t = lines[j].strip()
        if t.startswith("#"):
            continue
        if re.match(r"^fi\b", t):
            depth += 1
        elif re.match(r"^if\b.*;\s*then$", t):
            if depth == 0:
                decided = "DOOR_ON" in t
                break
            depth -= 1
    if not decided:
        print(f"{i + 1}: {line.strip()}")
if hits == 0:
    print("none")
PY
)"
  if [ "$undecided" = none ]; then
    fail "install.sh never passes --profile openai-door, so this measured nothing about how the door is started"
  elif [ -n "$undecided" ]; then
    while IFS= read -r l; do
      fail "install.sh:${l%%:*} passes --profile openai-door on a line DOOR_ON does not decide:${l#*:}"
    done <<<"$undecided"
  fi
  grep -q '^\[ "\$DOOR_ON" != 1 \] || UP_PROFILES+=(--profile openai-door)$' install.sh \
    || fail "section 5 does not start the door's profile when the door is on"
  rm_line="$(ln_of 'rm -sf tokenfuse-gateway-openai')"
  if [ -z "$rm_line" ] || ! grep -q 'DOOR_ON" != 1' <<<"$(sed -n "${rm_line}p" install.sh)" || [ "$rm_line" -lt "${main_up:-0}" ]; then
    fail "install.sh does not remove tokenfuse-gateway-openai by name after 'up' when the door is off, and 'up --remove-orphans' leaves a profile's container running: off would keep answering on 4110"
  fi
  restart_line="$(ln_of 'restart tokenfuse-gateway-openai')"
  if [ -z "$restart_line" ] || ! grep -q 'IDENTITY_openai_MAP_CHANGED' <<<"$(sed -n "$((restart_line - 2)),${restart_line}p" install.sh)" \
    || [ "$restart_line" -lt "${main_up:-0}" ] || [ "$restart_line" -gt "${verify_line:-0}" ]; then
    fail "install.sh does not restart tokenfuse-gateway-openai for a new door map after 'up' and before 'verify', so the old map stays in force"
  fi
  section8="$(sed -n '/^stack_checks() {$/,/^# ---- status: /p' install.sh)"
  # The checks live in stack_checks, and section 8 calls it after `say "verify"`:
  # read the function, then require the call to come after verify.
  stack_call="$(awk '/^stack_checks( |$)/{print NR; exit}' install.sh)"
  if [ -z "$stack_call" ] || [ -z "$verify_line" ] || [ "$stack_call" -lt "$verify_line" ]; then
    fail "section 8 no longer calls stack_checks after verify, so its checks do not run in the install"
  fi
  door8="$(awk '/^if \[ "\$DOOR_ON" = 1 \]; then$/{inside=1} inside{print} inside && /^fi$/{exit}' <<<"$section8")"
  for want in 'check "openai door answers on $GATEWAY_PROBE:4110"' 'check "openai door is NOT on loopback"' \
              'check "openai door published on $GATEWAY_BIND only"' 'check "openai door: a call with no key is refused"' \
              'check "openai door: a call with an unknown key is refused"' 'check_log "openai door serves the OpenAI wire"' \
              'check_log "openai door: identity map: the door reads it"'; do
    grep -qF "$want" <<<"$door8" \
      || fail "section 8 no longer asks the running door: $want (inside its \`if [ \"\$DOOR_ON\" = 1 ]\`)"
  done
  report="$(sed -n '/^DOOR_REACH=""$/,/^fi$/p' install.sh)"
  if ! grep -qF "bills whoever's key" <<<"$report" || ! grep -qF 'x-fuse-key' <<<"$report"; then
    fail "the closing report no longer says who pays a metered upstream and which key a call carries"
  elif ! grep -q '^\$REACH\$IDENTITY_REACH\$DOOR_REACH$' install.sh; then
    fail "the closing report does not print DOOR_REACH"
  fi
fi

# ---- E. resolved -----------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d "$scratch/cfg.XXXXXX")"
  cp compose.yaml "$cdir/compose.yaml"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/base.env"
  door_of() { # profile args...; extra .env lines on stdin; prints upstream|host_ip:published:target, or none, and every 4110
    cat "$cdir/base.env" - >"$cdir/.env"
    env -u OPENAI_DOOR_UPSTREAM -u OPENAI_DOOR_CLIENT_KEYS -u OPENAI_DOOR_IDENTITY_MAP -u GATEWAY_BIND \
      docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" "$@" config --format json 2>"$cdir/err" |
      python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]
pub = sorted("%s:%s" % (n, p.get("published")) for n, v in s.items() for p in v.get("ports", []) if str(p.get("published")) == "4110")
d = s.get(sys.argv[1])
if d is None:
    print("none|" + ",".join(pub))
else:
    ports = ",".join("%s:%s:%s" % (p.get("host_ip", ""), p.get("published"), p.get("target")) for p in d.get("ports", []))
    print("%s|%s|%s" % ((d.get("environment") or {}).get("TOKENFUSE_UPSTREAM", "<unset>"), ports, ",".join(pub)))
' "$DOOR" 2>>"$cdir/err"
  }
  got="$(door_of </dev/null)"
  [ "$got" = "none|" ] || fail "resolved: a default box reads '$got' for the door: it starts the door or publishes 4110 without being asked ($(head -1 "$cdir/err"))"
  got="$(door_of --profile openai-door </dev/null)"
  [ "$got" = "|127.0.0.1:4110:4100|$DOOR:4110" ] || fail "resolved: the door's profile with nothing set reads '$got', not an empty upstream on 127.0.0.1:4110 ($(head -1 "$cdir/err"))"
  got="$(door_of --profile openai-door <<<"OPENAI_DOOR_CLIENT_KEYS='gate-door-secret-aaaaaaaaaaaaaaaa1:flint'
OPENAI_DOOR_UPSTREAM='$UP'")"
  [ "${got%%|*}" = "" ] || fail "resolved: a door with keys and an upstream but no map has upstream '${got%%|*}', so it would start with no map"
  got="$(door_of --profile openai-door <<<"OPENAI_DOOR_IDENTITY_MAP='/etc/tokenfuse/identity/identity.json'
OPENAI_DOOR_UPSTREAM='$UP'")"
  [ "${got%%|*}" = "" ] || fail "resolved: a door with a map and an upstream but no keys has upstream '${got%%|*}', so it would start open to anyone who reaches 4110"
  got="$(door_of --profile openai-door <<<"OPENAI_DOOR_CLIENT_KEYS='gate-door-secret-aaaaaaaaaaaaaaaa1:flint'
OPENAI_DOOR_IDENTITY_MAP='/etc/tokenfuse/identity/identity.json'
OPENAI_DOOR_UPSTREAM='$UP'")"
  [ "${got%%|*}" = "$UP" ] || fail "resolved: a door with keys, a map and an upstream has upstream '${got%%|*}', not $UP"
  got="$(door_of --profile openai-door <<<"GATEWAY_BIND=192.168.1.10")"
  [ "$got" = "|192.168.1.10:4110:4100|$DOOR:4110" ] || fail "resolved: with GATEWAY_BIND=192.168.1.10 the door reads '$got', so its port does not follow the operator's bind"
fi

# ---- F. the image refuses a door with no upstream --------------------------------------
if [ "$docker_ok" = 1 ]; then
  out="$(docker run --rm --network none -e TOKENFUSE_WIRE=openai -e TOKENFUSE_UPSTREAM= "$IMG" /usr/local/bin/tokenfuse 2>&1)"
  rc=$?
  if [ "$rc" = 0 ] || ! grep -qF 'refusing to start' <<<"$out"; then
    fail "$IMG on the openai wire with an empty upstream exited $rc without refusing to start, so the door's upstream line holds nothing: $(head -2 <<<"$out" | tr '\n' ' ')"
  fi
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 32."
  exit 1
fi
echo "OK: the OpenAI door is opt-in, the gateway's own image and command with every hardened setting equal"
echo "    to the gateway's, on the openai wire, on 4110 on the operator's bind, with its own stream, data"
echo "    directory and map, its upstream held on its keys and map (the pinned image refuses to start without"
echo "    one); install.sh refuses it without an upstream, keys or a map before installing anything, never"
echo "    echoes an upstream, refuses two maps that share a unit, removes it when off, and asks it in section 8."
