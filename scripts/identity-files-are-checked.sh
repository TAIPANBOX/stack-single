#!/usr/bin/env bash
#
# Enforces invariant 29 of CLAUDE.md: the installer takes the gateway's client
# keys and identity map as files, keeps them across re-runs, and lets nothing
# restart before the gateway image itself has read them.
#
# WHAT THIS IS ABOUT
#
# tokenfuse's gateway can authenticate its callers (TOKENFUSE_CLIENT_KEYS,
# `secret:key_id,...`, presented as `x-fuse-key`) and bind each key to the agent
# ids it may speak as and the unit its spend lands in (TOKENFUSE_IDENTITY_MAP, a
# JSON file; tokenfuse docs/20). Both are off unless set, and both are easy to
# get silently wrong: a malformed key entry is skipped without a word, an empty
# map reads as no map at all, a map key_id no secret carries can never match,
# and a key the map does not bind is refused 403 on every call under the strict
# mode tokenfuse defaults to. @decided 2026-10-13 (paraphrased): the installer
# takes both as files a person or an onboarding agent prepares, keeps them across
# re-runs, checks them before anything restarts, mounts the map read only into
# the gateway, and says at the end which header an agent sends. This gate is that
# decision, held where a later edit would break it.
#
# ONE BLOCK, EVERY DOOR
#
# The OpenAI door (CLAUDE.md invariant 32) is a second gateway with a keys file
# and a map of its own, checked by the same block run for that door by name
# (`identity_door main`, `identity_door openai`). So the doors are read from the
# block itself, from identity_door's own case labels, with the names it gives
# each one (the service, the two input variables, the two .env lines, the
# directory), and every half below runs once per door. A door added to the block
# is checked here without this file naming it; a gateway in compose.yaml that no
# door names is a failure, because nothing would check its files.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. The subjects are derived from compose.yaml's own image and
#      command lines, like gateway-cache-is-off.sh: every service whose image is
#      the tokenfuse gateway image and whose command is the bare binary. Each is
#      the service of exactly one door, and sets TOKENFUSE_CLIENT_KEYS to its
#      door's keys line, required (`${<keys line>:?...}`) on a gateway that starts on
#      every box (invariant 35: the installer writes the line, minted or given) and
#      `${<keys line>:-}` on one behind a profile (compose reads a profile's
#      variables on every box, so `:?` there would stop every box that never asked
#      for it), TOKENFUSE_IDENTITY_MAP to `${<its map line>:-}` (an operator may
#      bring keys with no map) and mounts `./<its directory>:/etc/tokenfuse/identity:ro`,
#      read only. No other service names a door's keys or its directory, and the
#      path install.sh writes into .env is the file inside that mount.
#   B. THE INSTALLER'S FIRST HALF, `# identity-files: begin` .. `end` lifted out
#      of install.sh and run in a scratch STACK_DIR, identity_resolve alone, as
#      section 0f runs it before any package, for each door: a usable keys file
#      (comments, blank lines, CRLF, surrounding spaces) is read into the spec and
#      nothing is written; every hostile or unusable file refuses, names the
#      door's variable, leaves .env alone, runs nothing it was given and never
#      echoes a secret; a bad value an earlier run left in .env refuses too; a
#      relative map path is resolved where the operator stood. And the two doors
#      keep apart: switching from one to the other and back loses nothing.
#   C. THE INSTALLER'S SECOND HALF, the same block through identity_check and
#      identity_apply, with the gateway image compose.yaml pins, for each door
#      (the OpenAI door's check serves the openai wire, with an upstream it never
#      dials): a valid pair is written (one quoted .env line each, a 0444 map,
#      nothing staged left over, no other door's line touched); a re-run that
#      names nothing changes nothing; the same map again changes nothing, a new
#      one is installed and flagged for a restart; a new keys file replaces the
#      old line and is checked against the kept map; and the gateway's refusals
#      and its three warnings refuse with .env untouched; and an image with no
#      ENTRYPOINT, the shape BUILD_FROM_SOURCE builds, works too.
#   D. ORDER, in install.sh: the first half before the first package install, the
#      second after the images are on the box and before anything is started; a
#      changed map restarts the gateway after `up`; section 8 reads the running
#      gateway; the end of the run names x-fuse-key and x-fuse-agent-id. The
#      OpenAI door's own order is scripts/openai-door.sh's.
#   E. RESOLVED. `docker compose config`, with every profile a gateway sits
#      behind, for a default box (the always-on gateway's keys as the installer
#      writes them, every other value empty) and for a .env that
#      sets every door's pair (each door's values arrive at that door's gateway
#      only, and each mount is a read-only bind of its own directory).
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway service, no installer block, no functions in it, no door in it, no
# Docker, or no gateway image: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

MAP_PATH=/etc/tokenfuse/identity/identity.json
# The upstream the OpenAI door's check starts with. It is never dialled: the
# check container has no network.
DOOR_UP=https://api.openai.com/v1/chat/completions

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# ---- the block, and the doors it names ----------------------------------------
BLOCK="$(sed -n '/^# identity-files: begin$/,/^# identity-files: end$/p' install.sh)"
block_ok=0
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# identity-files: begin' .. '# identity-files: end' block, so this measured nothing about the installer's half"
elif ! grep -q '^identity_door()' <<<"$BLOCK" || ! grep -q '^identity_resolve()' <<<"$BLOCK" || ! grep -q '^identity_check()' <<<"$BLOCK" || ! grep -q '^identity_apply()' <<<"$BLOCK"; then
  fail "the identity-files block defines no identity_door, identity_resolve, identity_check or identity_apply, so this measured nothing"
elif ! grep -q '^identity_resolve$' install.sh || ! grep -q '^identity_check "\$IDENTITY_IMAGE"$' install.sh || ! grep -q '^identity_apply$' install.sh; then
  fail "install.sh never calls identity_resolve, identity_check and identity_apply, so the block is dead text"
else
  block_ok=1
fi

# DOOR: the names identity_door gives DOOR, one per line: service, keys file
# variable, map file variable, keys .env line, map .env line, directory.
names_of() {
  env -i PATH="$PATH" BLOCK="$BLOCK" DOOR="$1" DOOR_UPSTREAM="$DOOR_UP" bash -c '
    set -euo pipefail
    note() { :; }
    die() { printf "die: %s\n" "$*"; exit 1; }
    eval "$BLOCK"
    identity_door "$DOOR"
    printf "%s\n" "$ID_SERVICE" "$ID_KEYS_FILE_VAR" "$ID_MAP_FILE_VAR" "$ID_KEYS_ENV" "$ID_MAP_ENV" "$ID_DIR"' 2>&1
}

DOORS=""
: >"$scratch/doors"
if [ "$block_ok" = 1 ]; then
  DOORS="$(sed -n '/^identity_door() {/,/^}/p' <<<"$BLOCK" | sed -n 's/^    \([a-z][a-z0-9]*\))$/\1/p' | tr '\n' ' ')"
  if [ -z "${DOORS// /}" ]; then
    fail "identity_door names no door (no '    <name>)' case in it), so this measured nothing about which gateway the block checks"
    block_ok=0
  fi
  # A door the block does not know is an internal error, never a quiet default.
  grep -q '^die: internal: identity_door' <<<"$(names_of gate-no-such-door)" \
    || fail "identity_door accepts a door it does not know, so a misspelt door name would check the files of whichever door its names were left at"
  for door in $DOORS; do
    names="$(names_of "$door")"
    if [ "$(printf '%s\n' "$names" | grep -c .)" != 6 ] || grep -q '^die:' <<<"$names"; then
      fail "identity_door $door did not name its service, variables, .env lines and directory: $names"
      block_ok=0
      continue
    fi
    printf '%s %s\n' "$door" "$(printf '%s' "$names" | tr '\n' ' ')" >>"$scratch/doors"
  done
fi
# door_field DOOR N: the Nth name of DOOR (1 service, 2 keys file var, 3 map file
# var, 4 keys .env line, 5 map .env line, 6 directory).
door_field() { awk -v d="$1" -v n="$2" '$1 == d { print $(n + 1) }' "$scratch/doors"; }

# ---- A. compose --------------------------------------------------------------
python3 - compose.yaml install.sh "$scratch/doors" <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()
installer = open(sys.argv[2]).read()
doors = []
for line in open(sys.argv[3]).read().split("\n"):
    f = line.split()
    if len(f) == 7:
        doors.append(dict(zip(["door", "service", "keys_file", "map_file", "keys_env", "map_env", "dir"], f)))

# Two-space-indented service blocks, the same reader firewall-is-enforce.sh uses:
# compose.yaml is hand-written and hand-indented.
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


def env_value(block, name):
    for s in keyed(block, "environment"):
        m = re.match(re.escape(name) + r":\s*(.+?)\s*$", s)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    return None


def code_lines(block):
    return [l for l in block if l.strip() and not l.strip().startswith("#")]


def profiled(block):
    return any(re.match(r"^    profiles:", l) for l in block)


subjects = sorted(n for n, b in blocks.items() if is_gateway(b))
if not subjects:
    print("FAIL: no service in compose.yaml both uses the tokenfuse gateway image and runs it")
    print("      with no subcommand, so this gate measured NOTHING about client keys or the")
    print("      identity map. Silence here is not health.")
    sys.exit(1)
if not doors:
    print("FAIL: install.sh's identity block names no door, so no gateway's client keys or map")
    print("      can be judged against it. This gate measured NOTHING.")
    sys.exit(1)

bad = 0
by_service = {}
for d in doors:
    by_service.setdefault(d["service"], []).append(d)
    if d["service"] not in subjects:
        print(f"FAIL: install.sh checks the files of its {d['door']} door for {d['service']}, and compose.yaml runs")
        print("      no such gateway, so what it writes into .env reaches nothing.")
        bad += 1
for name in subjects:
    mine = by_service.get(name, [])
    if len(mine) != 1:
        print(f"FAIL: {name} runs the gateway, and {len(mine)} door(s) of install.sh's identity block name it.")
        print("      Its client keys and identity map are checked by exactly one door, or by nothing.")
        bad += 1
        continue
    d = mine[0]
    keys_re = r"\$\{%s:-\}" % d["keys_env"] if profiled(blocks[name]) else r"\$\{%s:\?[^}]*\}" % d["keys_env"]
    keys_want = "${%s:-}" % d["keys_env"] if profiled(blocks[name]) else "${%s:?...}" % d["keys_env"]
    got = env_value(blocks[name], "TOKENFUSE_CLIENT_KEYS")
    if got is None:
        print(f"FAIL: {name} sets no TOKENFUSE_CLIENT_KEYS, so what install.sh writes into .env never reaches it.")
        bad += 1
    elif not re.fullmatch(keys_re, got):
        print(f"FAIL: {name} sets TOKENFUSE_CLIENT_KEYS: {got}, not {keys_want}.")
        if profiled(blocks[name]):
            print("      It sits behind a profile, and compose reads a profile's variables on every box, so")
            print("      `:?` would stop every box that never asked for it; a literal or another variable")
            print("      makes install.sh's line do nothing.")
        else:
            print("      It starts on every box, and the installer always writes its keys (invariant 35), so")
            print("      a box whose .env lacks them must not start a gateway that answers anyone; a literal")
            print("      or another variable makes install.sh's line do nothing.")
        bad += 1
    w = "${%s:-}" % d["map_env"]
    got = env_value(blocks[name], "TOKENFUSE_IDENTITY_MAP")
    if got is None:
        print(f"FAIL: {name} sets no TOKENFUSE_IDENTITY_MAP, so what install.sh writes into .env never reaches it.")
        bad += 1
    elif got != w:
        print(f"FAIL: {name} sets TOKENFUSE_IDENTITY_MAP: {got}, not {w}. An operator may bring keys")
        print("      with no map, and a literal or another variable makes install.sh's line do nothing.")
        bad += 1
    mount = "./%s:/etc/tokenfuse/identity:ro" % d["dir"]
    mounts = [v.lstrip("-").strip().strip('"').strip("'") for v in keyed(blocks[name], "volumes")]
    if mount not in mounts:
        near = [m for m in mounts if m.endswith(":/etc/tokenfuse/identity") or m.startswith("./%s:" % d["dir"])]
        if near:
            print(f"FAIL: {name} mounts {near[0]}, not {mount}. The gateway reads the map and must")
            print("      not be able to change it, and reads its own door's map, never another's.")
        else:
            print(f"FAIL: {name} does not mount {mount}, so the map install.sh puts there is not")
            print("      the map it reads.")
        bad += 1

for name, block in blocks.items():
    joined = "\n".join(code_lines(block))
    for d in doors:
        if name == d["service"]:
            continue
        if d["keys_env"] in joined or ("./%s:" % d["dir"]) in joined:
            print(f"FAIL: {name} names {d['keys_env']} or ./{d['dir']}. The client keys and the map are")
            print(f"      {d['service']}'s; another service holding them is another place they leak from.")
            bad += 1

m = re.search(r"^IDENTITY_MAP_PATH=(\S+)", installer, re.M)
if not m:
    print("FAIL: install.sh has no IDENTITY_MAP_PATH, so the path it writes into .env is unknown.")
    bad += 1
elif m.group(1) != "/etc/tokenfuse/identity/identity.json":
    print(f"FAIL: install.sh writes GATEWAY_IDENTITY_MAP={m.group(1)}, which is not the file inside")
    print("      the read-only mount at /etc/tokenfuse/identity, so the gateway would not find it.")
    bad += 1

if bad:
    sys.exit(1)
open(sys.argv[3] + ".always", "w").write("".join(f"{d['door']}\n" for d in doors if not profiled(blocks[d["service"]])))
print("compose: " + ", ".join(f"{d['service']} ({d['door']} door, {d['keys_env']}, ./{d['dir']})" for d in doors)
      + " read their client keys and identity map from .env (keys required where the gateway starts on every box), map mounted read only")
PY

op="$scratch/op"   # where the operator stands when they run install.sh
mkdir -p "$op"

K1="gate-secret-aaaaaaaaaaaaaaaaaaaaaa1"
K2="gate-secret-bbbbbbbbbbbbbbbbbbbbbb2"
K3="gate-secret-cccccccccccccccccccccc3"
# A secret holding `:~:`: unquoted in .env, the shell that sources it expands a
# `~` between two colons into a home directory, as it does in PATH.
KT="gate-secret-tilde:~:dddddddddddddd4"
printf '# a comment: with a colon\r\n%s:treasury-bots\r\n\n   %s:research-bots   \n' "$K1" "$K2" >"$op/keys.txt"
printf '%s:treasury-bots\n%s:research-bots\n%s:treasury-bots\n' "$K1" "$K2" "$K3" >"$op/keys3.txt"
printf '%s:treasury-bots\n' "$K1" >"$op/keys-treasury-only.txt"
printf '%s:treasury-bots\n%s:research-bots\n%s:orphan\n' "$K1" "$K2" "$K3" >"$op/keys-orphan.txt"
printf '%s:tilde-bot\n%s:treasury-bots\n' "$KT" "$K1" >"$op/keys-tilde.txt"
SPEC2="$K1:treasury-bots,$K2:research-bots"
SPEC3="$K1:treasury-bots,$K2:research-bots,$K3:treasury-bots"
cat >"$op/map.json" <<'JSON'
{
  "units": [
    {"id": "treasury", "name": "Treasury", "owner": "user://bank.example/olena", "budget_usd_month": 20},
    {"id": "research", "budget_usd_month": 5}
  ],
  "keys": [
    {"key_id": "treasury-bots", "unit": "treasury", "agents": ["agent://bank.example/treasury/*"], "created": "2026-10-13"},
    {"key_id": "research-bots", "unit": "research", "agents": ["agent://bank.example/research/*"]}
  ]
}
JSON
sed 's/"budget_usd_month": 5}/"budget_usd_month": 7}/' "$op/map.json" >"$op/map2.json"
printf '{}\n' >"$op/map-empty-object.json"
printf '{"units":[{"id":"a"}],"keys":[{"key_id":"treasury-bots","unit":"nope"}]}\n' >"$op/map-unknown-unit.json"
printf '{"units":[{"id":"fleet"}],"prefixes":[{"match":"agent://bank.example/*","unit":"fleet"}]}\n' >"$op/map-prefixes.json"

mk() {
  local d
  d="$(mktemp -d "$scratch/box.XXXXXX")"
  printf 'SENTINEL=1\n' >"$d/.env"
  printf '%s' "$d"
}
# run DIR STEPS [VAR=VALUE...]: the block as install.sh runs it, for the door in
# $DOOR, from the operator's directory. STEPS is `resolve` (section 0f alone) or
# `all` (0f, then 3e's check and apply against $IMG).
run() {
  local d="$1" steps="$2"
  shift 2
  (
    cd "$op" || exit 99
    env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" STEPS="$steps" IMG="${IMG:-}" \
        DOOR="${DOOR:-main}" DOOR_UPSTREAM="$DOOR_UP" "$@" bash -c '
      set -euo pipefail
      note() { printf "note: %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      eval "$BLOCK"
      identity_door "$DOOR"
      identity_resolve
      if [ "$STEPS" = resolve ]; then
        printf "spec=%s\nsrc=%s\n" "$IDENTITY_KEYS_NEW" "$IDENTITY_MAP_SRC"
      else
        identity_check "$IMG"
        identity_apply
        printf "count=%s map_on=%s changed=%s\n" "$IDENTITY_KEYS_COUNT" "$IDENTITY_MAP_ON" "$IDENTITY_MAP_CHANGED"
      fi'
    printf 'rc=%s\n' "$?"
  ) 2>&1
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
val_of() { printf '%s' "$1" | sed -n "s/^$2=//p" | tail -1; }
lines_of() { grep -c "^$2=" "$1/.env" || true; }
sourced() { (set +u; . "$1/.env" >/dev/null 2>&1; printf '%s' "${!2:-}"); }

# select_door DOOR: the names the halves below use for DOOR. OTHERS holds every
# other door's .env lines, which a run for this door must never write.
select_door() {
  DOOR="$1"
  KF="$(door_field "$1" 2)"
  MF="$(door_field "$1" 3)"
  KE="$(door_field "$1" 4)"
  ME="$(door_field "$1" 5)"
  DIR="$(door_field "$1" 6)"
  OTHERS="$(awk -v d="$1" '$1 != d { print $5; print $6 }' "$scratch/doors" | tr '\n' ' ')"
}

# ---- B. the first half, for one door ----------------------------------------------
first_half() {
  local d out before
  d="$(mk)"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" = 0 ] || fail "$DOOR door: nothing set: it was refused: $out"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "$DOOR door: nothing set: .env was changed, so a default box would carry a line it never asked for"

  d="$(mk)"
  out="$(run "$d" resolve "$KF=keys.txt" "$MF=map.json")"
  if [ "$(rc_of "$out")" != 0 ]; then
    fail "$DOOR door: a usable keys file (a comment, a blank line, CRLF, surrounding spaces) and map, named relative to where the operator stands, were refused: $out"
  else
    [ "$(val_of "$out" spec)" = "$SPEC2" ] || fail "$DOOR door: the keys file was not read as its two secret:key_id lines, in order and trimmed"
    [ "$(val_of "$out" src)" = "$(cd "$op" && pwd -P)/map.json" ] || fail "$DOOR door: a relative $MF was not resolved where the operator stood (got '$(val_of "$out" src)')"
  fi
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "$DOOR door: the first half wrote .env, and it runs before the gateway image has read anything"

  # Every one refuses, names the variable, touches nothing, runs nothing it was
  # given and never repeats a secret.
  refuses() { # label variable file [secret that must not be echoed]
    local label="$1" var="$2" file="$3" secret="${4:-}" d out
    d="$(mk)"
    out="$(run "$d" resolve "$var=$file")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "$var ($label) was accepted"
    elif ! grep -qF "$var" <<<"$out"; then
      fail "$var ($label) was refused without naming the variable: $out"
    fi
    [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "$var ($label) was refused after .env was changed, which is half a job"
    if [ -n "$secret" ] && grep -qF -- "$secret" <<<"$out"; then
      fail "$var ($label) was refused by an answer that repeats the secret"
    fi
  }
  # The case's file, written where the operator stands; one at a time, so one name.
  kf() { printf "$@" >"$op/k.case"; printf 'k.case'; }
  long="$(printf 'a%.0s' $(seq 1 257))"
  refuses "a line with no colon" "$KF" "$(kf 'gate-secret-nocolon-aaaaaaaaaaaaa\n')" gate-secret-nocolon-aaaaaaaaaaaaa
  refuses "an empty key id" "$KF" "$(kf '%s:\n' "$K1")" "$K1"
  refuses "a key id with a space" "$KF" "$(kf '%s:treasury bots\n' "$K1")" "$K1"
  refuses "a key id with a comma" "$KF" "$(kf '%s:a,b\n' "$K1")" "$K1"
  refuses "a key id of 129 characters" "$KF" "$(kf '%s:%s\n' "$K1" "${long:0:129}")" "$K1"
  refuses "a secret of 23 characters" "$KF" "$(kf 'gate-secret-23-charsxxx:k\n')" gate-secret-23-charsxxx
  refuses "a secret of 257 characters" "$KF" "$(kf '%s:k\n' "$long")" "$long"
  refuses "a secret with a space" "$KF" "$(kf 'gate-secret with-a-space-aaaaaaa:k\n')" "gate-secret with-a-space-aaaaaaa"
  refuses "a secret with a quote" "$KF" "$(kf "gate-secret-'quote'-aaaaaaaaaaa:k\n")" "gate-secret-'quote'-aaaaaaaaaaa"
  refuses "a secret with a command substitution" "$KF" "$(kf 'gate-secret-$(touch pwned-by-identity)-a:k\n')" 'gate-secret-$(touch pwned-by-identity)-a'
  refuses "a secret with a backtick" "$KF" "$(kf 'gate-secret-`touch pwned-by-identity`-aa:k\n')" 'gate-secret-`touch pwned-by-identity`-aa'
  refuses "a secret given twice" "$KF" "$(kf '%s:a\n%s:b\n' "$K1" "$K1")" "$K1"
  refuses "comments and blank lines only" "$KF" "$(kf '# nothing here\n\n   \n')"
  refuses "an empty file" "$KF" "$(kf '')"
  refuses "a path that names nothing" "$KF" "no-such-keys-file"
  refuses "a directory" "$KF" "."
  refuses "a NUL byte" "$KF" "$(kf '%s:treasury-bots\n\0\n' "$K1")" "$K1"
  head -c 262145 /dev/zero | tr '\0' 'a' >"$op/keys-huge"
  refuses "a file over 256 KiB" "$KF" keys-huge
  [ ! -e "$op/pwned-by-identity" ] && [ ! -e "$scratch/pwned-by-identity" ] || fail "$DOOR door: a command in a keys file was executed"

  refuses "a path that names nothing" "$MF" "no-such-map.json"
  refuses "a directory" "$MF" "."
  refuses "an empty file" "$MF" "$(kf '   \n')"
  refuses "a JSON array, not an object" "$MF" "$(kf '[{"units": []}]\n')"
  refuses "a NUL byte" "$MF" "$(kf '{"units": []}\0\n')"
  { printf '{'; head -c 1048576 /dev/zero | tr '\0' ' '; printf '}'; } >"$op/map-huge.json"
  refuses "a file over 1 MiB" "$MF" map-huge.json

  # A value an earlier run left in .env is held to the same rules.
  d="$(mk)"
  printf "%s='short-secret:k'\n" "$KE" >>"$d/.env"
  before="$(cat "$d/.env")"
  out="$(run "$d" resolve)"
  if [ "$(rc_of "$out")" = 0 ]; then
    fail "$DOOR door: a $KE left in .env with a short secret was accepted on a re-run"
  elif grep -qF 'short-secret' <<<"$out"; then
    fail "$DOOR door: a bad $KE in .env was refused by an answer that repeats the secret"
  fi
  [ "$(cat "$d/.env")" = "$before" ] || fail "$DOOR door: a bad $KE in .env was refused after .env was changed"
  d="$(mk)"
  printf "%s='%s'\n" "$KE" "$SPEC2" >>"$d/.env"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" = 0 ] || fail "$DOOR door: a usable $KE kept in .env was refused on a re-run: $out"
  d="$(mk)"
  printf "%s='/somewhere/else.json'\n" "$ME" >>"$d/.env"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" != 0 ] || fail "$DOOR door: a $ME in .env that names another path was accepted"
  d="$(mk)"
  printf "%s='%s'\n" "$ME" "$MAP_PATH" >>"$d/.env"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" != 0 ] || fail "$DOOR door: a $ME in .env with no map behind it was accepted, and the gateway would refuse to start"
}

# ---- C. the second half, for one door, with the gateway image compose.yaml pins ----
c_pair() {
  local d out o
  d="$(mk)"
  out="$(run "$d" all "$KF=keys.txt" "$MF=map.json")"
  if [ "$(rc_of "$out")" != 0 ]; then
    echo "FAIL: $DOOR door: a valid keys file and map were refused by the second half: $out"
    return
  fi
  grep -qx 'count=2 map_on=1 changed=1' <<<"$out" || echo "FAIL: $DOOR door: a first install with both files did not report two keys, a map and a change: $(grep '^count' <<<"$out")"
  [ "$(lines_of "$d" "$KE")" = 1 ] && [ "$(sourced "$d" "$KE")" = "$SPEC2" ] \
    || echo "FAIL: $DOOR door: .env does not carry exactly one $KE line that reads back as the keys given"
  [ "$(lines_of "$d" "$ME")" = 1 ] && [ "$(sourced "$d" "$ME")" = "$MAP_PATH" ] \
    || echo "FAIL: $DOOR door: .env does not carry exactly one $ME=$MAP_PATH"
  cmp -s "$op/map.json" "$d/$DIR/identity.json" || echo "FAIL: $DOOR door: the installed map is not the map given"
  [ "$(ls -l "$d/$DIR/identity.json" | cut -c1-10)" = "-r--r--r--" ] || echo "FAIL: $DOOR door: the installed map is not 0444"
  ! compgen -G "$d/$DIR.check.*" >/dev/null || echo "FAIL: $DOOR door: the staging directory was left behind"
  head -n 1 "$d/.env" | grep -qx 'SENTINEL=1' || echo "FAIL: $DOOR door: writing the keys disturbed the rest of .env"
  for o in $OTHERS; do
    if grep -q "^$o=" "$d/.env"; then echo "FAIL: $DOOR door: its files wrote $o, another door's line"; fi
  done

  cp "$d/.env" "$d/.env.before"
  cp "$d/$DIR/identity.json" "$d/map.before"
  out="$(run "$d" all)"
  [ "$(rc_of "$out")" = 0 ] || { echo "FAIL: $DOOR door: a re-run that names no file was refused, so an upgrade would stop: $out"; return; }
  grep -qx 'count=2 map_on=1 changed=0' <<<"$out" || echo "FAIL: $DOOR door: a re-run that names no file did not keep both: $(grep '^count' <<<"$out")"
  cmp -s "$d/.env" "$d/.env.before" || echo "FAIL: $DOOR door: a re-run that names no file changed .env"
  cmp -s "$d/$DIR/identity.json" "$d/map.before" || echo "FAIL: $DOOR door: a re-run that names no file changed the map"

  out="$(run "$d" all "$MF=map.json")"
  grep -qx 'count=2 map_on=1 changed=0' <<<"$out" || echo "FAIL: $DOOR door: the same map given again was installed as a change, which restarts the gateway for nothing: $(grep -E '^(count|die)' <<<"$out")"

  out="$(run "$d" all "$MF=map2.json")"
  grep -qx 'count=2 map_on=1 changed=1' <<<"$out" || echo "FAIL: $DOOR door: a new map was not installed as a change: $(grep -E '^(count|die)' <<<"$out")"
  cmp -s "$op/map2.json" "$d/$DIR/identity.json" || echo "FAIL: $DOOR door: a new map did not replace the old one"
  [ "$(lines_of "$d" "$ME")" = 1 ] || echo "FAIL: $DOOR door: a new map left more than one $ME line in .env"

  out="$(run "$d" all "$KF=keys3.txt")"
  grep -qx 'count=3 map_on=1 changed=0' <<<"$out" || echo "FAIL: $DOOR door: a new keys file checked against the kept map did not pass: $(grep -E '^(count|die)' <<<"$out")"
  [ "$(lines_of "$d" "$KE")" = 1 ] && [ "$(sourced "$d" "$KE")" = "$SPEC3" ] \
    || echo "FAIL: $DOOR door: a new keys file did not REPLACE the $KE line"

  cp "$d/.env" "$d/.env.before"
  out="$(run "$d" all "$KF=keys-treasury-only.txt")"
  [ "$(rc_of "$out")" != 0 ] || echo "FAIL: $DOOR door: a keys file that drops a key the kept map binds was accepted"
  cmp -s "$d/.env" "$d/.env.before" || echo "FAIL: $DOOR door: a refused keys file still changed .env"
}
c_tilde() {
  local d out
  d="$(mk)"
  out="$(run "$d" all "$KF=keys-tilde.txt")"
  [ "$(rc_of "$out")" = 0 ] || { echo "FAIL: $DOOR door: a secret holding :~ was refused: $out"; return; }
  [ "$(sourced "$d" "$KE")" = "$KT:tilde-bot,$K1:treasury-bots" ] \
    || echo "FAIL: $DOOR door: $KE does not read back as given when .env is sourced; a value with :~ in it has to be quoted"
  grep -q "^$ME=" "$d/.env" && echo "FAIL: $DOOR door: keys alone wrote a $ME line"
  grep -qx 'count=2 map_on=0 changed=0' <<<"$out" || echo "FAIL: $DOOR door: keys alone did not report two keys and no map: $(grep '^count' <<<"$out")"
}
c_refused() { # label keysfile mapfile needle
  local d out
  d="$(mk)"
  out="$(run "$d" all ${2:+"$KF=$2"} ${3:+"$MF=$3"})"
  if [ "$(rc_of "$out")" = 0 ]; then
    echo "FAIL: $DOOR door: $1 was accepted"
  elif ! grep -qF -- "$4" <<<"$out"; then
    echo "FAIL: $DOOR door: $1 was refused, but not saying: $4 ($(grep '^die' <<<"$out"))"
  fi
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || echo "FAIL: $DOOR door: $1 was refused after .env was changed"
  [ ! -e "$d/$DIR/identity.json" ] || echo "FAIL: $DOOR door: $1 was refused after the map was put in place"
  ! compgen -G "$d/$DIR.check.*" >/dev/null || echo "FAIL: $DOOR door: $1 left the staging directory behind"
  if grep -qF -- "$K1" <<<"$out" || grep -qF -- "$K3" <<<"$out"; then echo "FAIL: $DOOR door: $1 was refused by an answer that repeats a secret"; fi
}
# The image BUILD_FROM_SOURCE builds has no ENTRYPOINT (stack-k8s
# images/tokenfuse.Dockerfile), so the check has to give the command compose
# gives the gateway. One line on top of the pinned image is that image's shape.
c_no_entrypoint() {
  local d out
  d="$(mk)"
  out="$(IMG="$NOENT" run "$d" all "$KF=keys.txt" "$MF=map.json")"
  grep -qx 'count=2 map_on=1 changed=1' <<<"$out" \
    || echo "FAIL: $DOOR door: a gateway image with no ENTRYPOINT, the shape BUILD_FROM_SOURCE builds, could not check the files: $(grep -E '^(count|die)' <<<"$out")"
}
c_prefixes() {
  local d out
  d="$(mk)"
  out="$(run "$d" all "$MF=map-prefixes.json")"
  grep -qx 'count=0 map_on=1 changed=1' <<<"$out" || echo "FAIL: $DOOR door: a map of units and prefixes alone, with no keys, was not installed: $(grep -E '^(count|die)' <<<"$out")"
}

if [ "$block_ok" = 1 ]; then
  for door in $DOORS; do
    select_door "$door"
    first_half
  done

  # The two doors keep apart: one process resolves the first door's files, then the
  # second's, then names the first again, and each still holds its own. A door's
  # state that is not saved on the way out is the first door's keys lost, or the
  # second's written over them.
  set -- $DOORS
  if [ "$#" -ge 2 ]; then
    a="$1" b="$2"
    d="$(mk)"
    out="$( (
      cd "$op" || exit 99
      env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" A="$a" B="$b" DOOR_UPSTREAM="$DOOR_UP" \
          "$(door_field "$a" 2)=keys.txt" "$(door_field "$b" 2)=keys3.txt" "$(door_field "$b" 3)=map.json" bash -c '
        set -euo pipefail
        note() { :; }
        die() { printf "die: %s\n" "$*"; exit 1; }
        eval "$BLOCK"
        identity_door "$A"; identity_resolve
        identity_door "$B"; identity_resolve
        identity_door "$A"
        printf "a_spec=%s\na_given=%s\na_src=%s\n" "$IDENTITY_KEYS_NEW" "$IDENTITY_KEYS_GIVEN" "$IDENTITY_MAP_SRC"
        bspec="IDENTITY_${B}_KEYS_NEW"; bsrc="IDENTITY_${B}_MAP_SRC"
        printf "b_spec=%s\nb_src=%s\n" "${!bspec:-}" "${!bsrc:-}"'
    ) 2>&1 )"
    [ "$(val_of "$out" a_spec)" = "$SPEC2" ] && [ "$(val_of "$out" a_given)" = 1 ] && [ -z "$(val_of "$out" a_src)" ] \
      || fail "switching from the $a door to the $b door and back lost the $a door's own state (keys '$(val_of "$out" a_spec | cut -c1-12)...', map '$(val_of "$out" a_src)'): $(grep '^die' <<<"$out")"
    [ "$(val_of "$out" b_spec)" = "$SPEC3" ] && [ "$(val_of "$out" b_src)" = "$(cd "$op" && pwd -P)/map.json" ] \
      || fail "the $b door's state was not kept under its own name when the $a door was named again"
  fi

  IMG="$(sed -n 's/^    image: \${TOKENFUSE_IMAGE:-\(ghcr\.io\/taipanbox\/tokenfuse:[^}]*\)}$/\1/p' compose.yaml | head -n 1)"
  if [ -z "$IMG" ]; then
    fail "compose.yaml names no \${TOKENFUSE_IMAGE:-ghcr.io/taipanbox/tokenfuse:...} image, so the second half could not be run"
  elif ! docker version >/dev/null 2>&1; then
    fail "no Docker here, so the gateway image could not read anything. This gate does not pass on a box that cannot run it."
  elif ! docker image inspect "$IMG" >/dev/null 2>&1 && ! docker pull -q "$IMG" >/dev/null 2>&1; then
    fail "could not pull $IMG, so the second half could not be run"
  else
    export IMG
    NOENT="stack-single-gate/tokenfuse-no-entrypoint:local"
    noent_ok=0
    if printf 'FROM %s\nENTRYPOINT []\n' "$IMG" | docker build -q -t "$NOENT" - >/dev/null 2>&1; then noent_ok=1; fi
    # Each case on its own box, every door at once: every one starts a container.
    for door in $DOORS; do
      select_door "$door"
      c_pair >"$scratch/c.$door.pair" 2>&1 &
      c_tilde >"$scratch/c.$door.tilde" 2>&1 &
      c_refused "a map that binds a key id no client key carries" keys-treasury-only.txt map.json "research-bots that no client key carries" >"$scratch/c.$door.orphan" 2>&1 &
      c_refused "a client key the map does not bind" keys-orphan.txt map.json "orphan have no keys[] binding" >"$scratch/c.$door.unbound" 2>&1 &
      c_refused "a map that configures nothing ({})" keys.txt map-empty-object.json "configures nothing" >"$scratch/c.$door.empty" 2>&1 &
      c_refused "a map naming a unit it does not declare" keys.txt map-unknown-unit.json "not declared in units[]" >"$scratch/c.$door.unknown" 2>&1 &
      c_refused "a map with key bindings and no client keys at all" "" map.json "that no client key carries" >"$scratch/c.$door.nokeys" 2>&1 &
      c_prefixes >"$scratch/c.$door.prefixes" 2>&1 &
      if [ "$noent_ok" = 1 ]; then
        c_no_entrypoint >"$scratch/c.$door.noentry" 2>&1 &
      else
        echo "FAIL: could not build a no-ENTRYPOINT image from $IMG, so the BUILD_FROM_SOURCE shape was not checked" >"$scratch/c.$door.noentry"
      fi
    done
    wait
    for f in "$scratch"/c.*; do
      while IFS= read -r line; do
        case "$line" in FAIL:*) printf '%s\n' "$line"; problems=$((problems + 1)) ;; esac
      done <"$f"
    done
  fi

  # ---- D. order -------------------------------------------------------------------
  ln_of() { grep -n -- "$1" install.sh | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1 | cut -d: -f1; }
  first_apt="$(grep -n '^[[:space:]]*apt-get ' install.sh | head -n 1 | cut -d: -f1)"
  resolve_line="$(ln_of '^identity_resolve$')"
  check_line="$(ln_of '^identity_check "\$IDENTITY_IMAGE"$')"
  apply_line="$(ln_of '^identity_apply$')"
  pull_line="$(ln_of 'config --images')"
  first_up="$(ln_of '"\${COMPOSE\[@\]}".* up -d')"
  main_up="$(ln_of 'up -d --remove-orphans')"
  # The gateway's own restart, not the OpenAI door's (`restart tokenfuse-gateway-openai`).
  restart_line="$(ln_of 'restart tokenfuse-gateway[^-]')"
  verify_line="$(ln_of '^say "verify"$')"
  if [ -n "$first_apt" ] && [ -n "$resolve_line" ] && [ "$resolve_line" -gt "$first_apt" ]; then
    fail "identity_resolve (line $resolve_line) runs after the first package install (line $first_apt), so a refused file would arrive after something was installed"
  fi
  if [ -z "$pull_line" ] || [ -z "$first_up" ] || [ -z "$check_line" ] || [ -z "$apply_line" ]; then
    fail "could not find the pull, the first 'up -d', identity_check and identity_apply in install.sh, so their order is unknown"
  else
    [ "$check_line" -gt "$pull_line" ] || fail "identity_check (line $check_line) runs before the images are pulled (line $pull_line), so it has no gateway image to ask"
    [ "$check_line" -lt "$first_up" ] || fail "identity_check (line $check_line) runs after the stack starts (line $first_up), so a bad file is found by a gateway that already restarted"
    [ "$apply_line" -gt "$check_line" ] && [ "$apply_line" -lt "$first_up" ] || fail "identity_apply (line $apply_line) does not sit between the check (line $check_line) and the first start (line $first_up)"
  fi
  if [ -z "$restart_line" ] || [ -z "$main_up" ] || [ -z "$verify_line" ] || [ "$restart_line" -lt "$main_up" ] || [ "$restart_line" -gt "$verify_line" ]; then
    fail "install.sh does not restart tokenfuse-gateway after 'up -d --remove-orphans' and before 'verify', so a new map behind the same .env line would never be read"
  elif ! grep -q 'IDENTITY_MAP_CHANGED' <<<"$(sed -n "$((restart_line - 3)),${restart_line}p" install.sh)"; then
    fail "the gateway restart is not the one IDENTITY_MAP_CHANGED asks for"
  fi
  # Here-strings, not `sed | grep -q`: under pipefail grep's early exit is a
  # SIGPIPE for sed, and the check would read a present line as missing.
  section8="$(sed -n '/^stack_checks() {$/,/^# ---- status: /p' install.sh)"
  # The checks live in stack_checks, and section 8 calls it after `say "verify"`:
  # read the function, then require the call to come after verify.
  stack_call="$(awk '/^stack_checks( |$)/{print NR; exit}' install.sh)"
  if [ -z "$stack_call" ] || [ -z "$verify_line" ] || [ "$stack_call" -lt "$verify_line" ]; then
    fail "section 8 no longer calls stack_checks after verify, so its checks do not run in the install"
  fi
  if [ -z "$verify_line" ] || ! grep -qF 'check "client keys: a call with no key is refused"' <<<"$section8" \
    || ! grep -qF 'check_log "identity map: the gateway reads it"' <<<"$section8"; then
    fail "section 8 no longer asks the running gateway whether it refuses a call with no key and reads its map, so a box whose gateway ignored both would pass"
  fi
  reach="$(sed -n '/^IDENTITY_REACH=""$/,/^fi$/p' install.sh)"
  if ! grep -qF 'x-fuse-key header' <<<"$reach" || ! grep -qF 'x-fuse-agent-id' <<<"$reach"; then
    fail "the end of the run no longer says which headers an agent sends (x-fuse-key, x-fuse-agent-id)"
  elif ! grep -q '^\$REACH\$IDENTITY_REACH' install.sh; then
    fail "the closing report does not print IDENTITY_REACH"
  fi
fi

# ---- E. resolved ------------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
elif [ ! -s "$scratch/doors" ]; then
  fail "no door to read the resolved configuration for, so its half measured nothing"
else
  cdir="$(mktemp -d "$scratch/cfg.XXXXXX")"
  cp compose.yaml "$cdir/compose.yaml"
  # Every profile a door's gateway sits behind, so the resolved configuration holds
  # every door, not only the one a default box starts.
  profiles=()
  for p in $(python3 - compose.yaml "$scratch/doors" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
services = {l.split()[1] for l in open(sys.argv[2]).read().split("\n") if l.strip()}
for s in sorted(services):
    m = re.search(r"^  " + re.escape(s) + r":\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)", text, re.M | re.S)
    if m:
        for p in re.findall(r'^    profiles:\s*\[([^\]]*)\]', m.group(1), re.M):
            for name in re.findall(r'"([a-z0-9-]+)"', p):
                print(name)
PY
  ); do profiles+=(--profile "$p"); done
  # The required variables of the file's own settings, not of its comments, and
  # never the ones this section sets itself: a comment naming
  # `${GATEWAY_CLIENT_KEYS:?...}` would otherwise hand the default box a key.
  excl=()
  for v in $(awk '{ print $5; print $6 }' "$scratch/doors"); do excl+=(-e "$v"); done
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u \
    | grep -v -x "${excl[@]}" | sed 's/$/=fake-not-a-secret/' >"$cdir/base.env"
  unset_args=()
  for v in $(awk '{ print $5; print $6 }' "$scratch/doors"); do unset_args+=(-u "$v"); done
  resolved() { # extra .env lines on stdin; prints door|service|keys|map|mount|holders per door
    cat "$cdir/base.env" - >"$cdir/.env"
    env "${unset_args[@]}" docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" "${profiles[@]}" config --format json 2>"$cdir/err" |
      python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]
for line in open(sys.argv[1]).read().split("\n"):
    f = line.split()
    if len(f) != 7:
        continue
    door, svc = f[0], f[1]
    g = s.get(svc)
    if g is None:
        print("|".join([door, svc, "<no such service>"]))
        continue
    env = g.get("environment") or {}
    mount = [v for v in g.get("volumes", []) if v.get("target") == "/etc/tokenfuse/identity"]
    m = "none"
    if mount:
        v = mount[0]
        m = "%s,%s,%s" % (v.get("type"), "ro" if v.get("read_only") else "rw", v.get("source", "").rsplit("/", 1)[-1])
    secret = "gate-resolved-secret-%s-aaaaaaaaaaaa" % door
    holders = sorted(n for n, svc_ in s.items() if secret in json.dumps(svc_.get("environment") or {}))
    print("|".join([door, svc, env.get("TOKENFUSE_CLIENT_KEYS", "<unset>"), env.get("TOKENFUSE_IDENTITY_MAP", "<unset>"), m, ",".join(holders)]))
' "$scratch/doors" 2>>"$cdir/err"
  }
  # A default box: the installer has written the keys of every gateway that starts on
  # every box (minted or given, invariant 35) and nothing else.
  always="$(cat "$scratch/doors.always" 2>/dev/null)"
  default_lines="$(awk -v al=" $(tr '\n' ' ' <<<"$always")" 'index(al, " " $1 " ") { printf "%s=\047gate-resolved-default-%s-aaaaaaaaaaaa:k1\047\n", $5, $1 }' "$scratch/doors")"
  want_default="$(awk -v al=" $(tr '\n' ' ' <<<"$always")" '{ k = index(al, " " $1 " ") ? "gate-resolved-default-" $1 "-aaaaaaaaaaaa:k1" : ""; printf "%s|%s|%s||bind,ro,%s|\n", $1, $2, k, $7 }' "$scratch/doors")"
  got="$(resolved <<<"$default_lines")"
  [ "$got" = "$want_default" ] || fail "resolved: a default box reads '$(tr '\n' ' ' <<<"$got")', not the installer's keys on the gateway every box runs, empty values on the rest, no map and a read-only bind of each door's own directory ($(head -1 "$cdir/err"))"
  set_lines="$(awk -v mp="$MAP_PATH" '{ printf "%s=\047gate-resolved-secret-%s-aaaaaaaaaaaa:k1\047\n%s=\047%s\047\n", $5, $1, $6, mp }' "$scratch/doors")"
  want_set="$(awk -v mp="$MAP_PATH" '{ printf "%s|%s|gate-resolved-secret-%s-aaaaaaaaaaaa:k1|%s|bind,ro,%s|%s\n", $1, $2, $1, mp, $7, $2 }' "$scratch/doors")"
  got="$(resolved <<<"$set_lines")"
  [ "$got" = "$want_set" ] \
    || fail "resolved: a box whose .env sets every door's pair reads '$(tr '\n' ' ' <<<"$got")', so a door's keys or map do not reach its gateway, or reach more than it"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 29."
  exit 1
fi
echo "OK: every gateway reads its door's client keys and identity map from .env, the keys required on the"
echo "    gateway every box runs, the map mounted read only; for every door ($DOORS) install.sh refuses hostile files before anything is"
echo "    installed and lets the pinned gateway image read the pair, on that door's own wire, before"
echo "    anything restarts, keeps both on a re-run, replaces rather than repeats, never echoes a secret,"
echo "    keeps each door's state apart, restarts the gateway for a new map, and names the headers."
