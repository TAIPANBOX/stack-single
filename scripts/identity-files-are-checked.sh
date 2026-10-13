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
# WHAT THIS CHECKS
#
#   A. COMPOSE. The subjects are derived from compose.yaml's own image and
#      command lines, like gateway-cache-is-off.sh: every service whose image is
#      the tokenfuse gateway image and whose command is the bare binary. Each sets
#      TOKENFUSE_CLIENT_KEYS to `${GATEWAY_CLIENT_KEYS:-}` and
#      TOKENFUSE_IDENTITY_MAP to `${GATEWAY_IDENTITY_MAP:-}` (empty is off, so a
#      default box is unchanged; `:?` would stop every default box) and mounts
#      `./identity:/etc/tokenfuse/identity:ro`, read only. No other service names
#      the keys or the directory, and the path install.sh writes into .env is the
#      file inside that mount.
#   B. THE INSTALLER'S FIRST HALF, `# identity-files: begin` .. `end` lifted out
#      of install.sh and run in a scratch STACK_DIR, identity_resolve alone, as
#      section 0f runs it before any package: a usable keys file (comments, blank
#      lines, CRLF, surrounding spaces) is read into the spec and nothing is
#      written; every hostile or unusable file refuses, names the variable,
#      leaves .env alone, runs nothing it was given and never echoes a secret; a
#      bad value an earlier run left in .env refuses too; a relative map path is
#      resolved where the operator stood.
#   C. THE INSTALLER'S SECOND HALF, the same block through identity_check and
#      identity_apply, with the gateway image compose.yaml pins: a valid pair is
#      written (one quoted .env line each, a 0444 map, nothing staged left over);
#      a re-run that names nothing changes nothing; the same map again changes
#      nothing, a new one is installed and flagged for a restart; a new keys file
#      replaces the old line and is checked against the kept map; and the
#      gateway's refusals and its three warnings refuse with .env untouched.
#   D. ORDER, in install.sh: the first half before the first package install, the
#      second after the images are on the box and before anything is started; a
#      changed map restarts the gateway after `up`; section 8 reads the running
#      gateway; the end of the run names x-fuse-key and x-fuse-agent-id.
#   E. RESOLVED. `docker compose config` for a default box (both values empty)
#      and for a .env that sets them (the values arrive, at the gateway only, and
#      the mount is a read-only bind).
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway service, no installer block, no functions in it, no Docker, or no
# gateway image: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

MAP_PATH=/etc/tokenfuse/identity/identity.json

# ---- A. compose --------------------------------------------------------------
python3 - compose.yaml install.sh <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()
installer = open(sys.argv[2]).read()

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


subjects = sorted(n for n, b in blocks.items() if is_gateway(b))
if not subjects:
    print("FAIL: no service in compose.yaml both uses the tokenfuse gateway image and runs it")
    print("      with no subcommand, so this gate measured NOTHING about client keys or the")
    print("      identity map. Silence here is not health.")
    sys.exit(1)

bad = 0
WANT = {
    "TOKENFUSE_CLIENT_KEYS": "${GATEWAY_CLIENT_KEYS:-}",
    "TOKENFUSE_IDENTITY_MAP": "${GATEWAY_IDENTITY_MAP:-}",
}
MOUNT = "./identity:/etc/tokenfuse/identity:ro"
for name in subjects:
    for var, want in WANT.items():
        got = env_value(blocks[name], var)
        if got is None:
            print(f"FAIL: {name} sets no {var}, so what install.sh writes into .env never reaches it.")
            bad += 1
        elif got != want:
            print(f"FAIL: {name} sets {var}: {got}, not {want}. Empty is the default that keeps")
            print("      a box that gave no file exactly as it was; `:?` would stop every such box,")
            print("      and a literal or another variable makes install.sh's line do nothing.")
            bad += 1
    mounts = [v.lstrip("-").strip().strip('"').strip("'") for v in keyed(blocks[name], "volumes")]
    if MOUNT not in mounts:
        near = [m for m in mounts if m.startswith("./identity")]
        if near:
            print(f"FAIL: {name} mounts {near[0]}, not {MOUNT}. The gateway reads the map and must")
            print("      not be able to change it.")
        else:
            print(f"FAIL: {name} does not mount {MOUNT}, so the map install.sh puts there is not")
            print("      the map it reads.")
        bad += 1

for name, block in blocks.items():
    if name in subjects:
        continue
    joined = "\n".join(code_lines(block))
    if "GATEWAY_CLIENT_KEYS" in joined or "./identity:" in joined:
        print(f"FAIL: {name} names GATEWAY_CLIENT_KEYS or ./identity. The client keys and the map")
        print("      are the gateway's; another service holding them is another place they leak from.")
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
print(f"compose: {', '.join(subjects)} read the client keys and the identity map from .env, default off, map mounted read only")
PY

# ---- B and C. the installer's block -------------------------------------------
BLOCK="$(sed -n '/^# identity-files: begin$/,/^# identity-files: end$/p' install.sh)"
block_ok=0
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# identity-files: begin' .. '# identity-files: end' block, so this measured nothing about the installer's half"
elif ! grep -q '^identity_resolve()' <<<"$BLOCK" || ! grep -q '^identity_check()' <<<"$BLOCK" || ! grep -q '^identity_apply()' <<<"$BLOCK"; then
  fail "the identity-files block defines no identity_resolve, identity_check or identity_apply, so this measured nothing"
elif ! grep -q '^identity_resolve$' install.sh || ! grep -q '^identity_check "\$IDENTITY_IMAGE"$' install.sh || ! grep -q '^identity_apply$' install.sh; then
  fail "install.sh never calls identity_resolve, identity_check and identity_apply, so the block is dead text"
else
  block_ok=1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
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
# run DIR STEPS [VAR=VALUE...]: the block as install.sh runs it, from the
# operator's directory. STEPS is `resolve` (section 0f alone) or `all` (0f, then
# 3e's check and apply against $IMG).
run() {
  local d="$1" steps="$2"
  shift 2
  (
    cd "$op" || exit 99
    env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" STEPS="$steps" IMG="${IMG:-}" "$@" bash -c '
      set -euo pipefail
      note() { printf "note: %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      eval "$BLOCK"
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

if [ "$block_ok" = 1 ]; then
  # ---- B. the first half -------------------------------------------------------
  d="$(mk)"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" = 0 ] || fail "nothing set: it was refused: $out"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "nothing set: .env was changed, so a default box would carry a line it never asked for"

  d="$(mk)"
  out="$(run "$d" resolve CLIENT_KEYS_FILE=keys.txt IDENTITY_MAP_FILE=map.json)"
  if [ "$(rc_of "$out")" != 0 ]; then
    fail "a usable keys file (a comment, a blank line, CRLF, surrounding spaces) and map, named relative to where the operator stands, were refused: $out"
  else
    [ "$(val_of "$out" spec)" = "$SPEC2" ] || fail "the keys file was not read as its two secret:key_id lines, in order and trimmed"
    [ "$(val_of "$out" src)" = "$(cd "$op" && pwd -P)/map.json" ] || fail "a relative IDENTITY_MAP_FILE was not resolved where the operator stood (got '$(val_of "$out" src)')"
  fi
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "the first half wrote .env, and it runs before the gateway image has read anything"

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
  refuses "a line with no colon" CLIENT_KEYS_FILE "$(kf 'gate-secret-nocolon-aaaaaaaaaaaaa\n')" gate-secret-nocolon-aaaaaaaaaaaaa
  refuses "an empty key id" CLIENT_KEYS_FILE "$(kf '%s:\n' "$K1")" "$K1"
  refuses "a key id with a space" CLIENT_KEYS_FILE "$(kf '%s:treasury bots\n' "$K1")" "$K1"
  refuses "a key id with a comma" CLIENT_KEYS_FILE "$(kf '%s:a,b\n' "$K1")" "$K1"
  refuses "a key id of 129 characters" CLIENT_KEYS_FILE "$(kf '%s:%s\n' "$K1" "${long:0:129}")" "$K1"
  refuses "a secret of 23 characters" CLIENT_KEYS_FILE "$(kf 'gate-secret-23-charsxxx:k\n')" gate-secret-23-charsxxx
  refuses "a secret of 257 characters" CLIENT_KEYS_FILE "$(kf '%s:k\n' "$long")" "$long"
  refuses "a secret with a space" CLIENT_KEYS_FILE "$(kf 'gate-secret with-a-space-aaaaaaa:k\n')" "gate-secret with-a-space-aaaaaaa"
  refuses "a secret with a quote" CLIENT_KEYS_FILE "$(kf "gate-secret-'quote'-aaaaaaaaaaa:k\n")" "gate-secret-'quote'-aaaaaaaaaaa"
  refuses "a secret with a command substitution" CLIENT_KEYS_FILE "$(kf 'gate-secret-$(touch pwned-by-identity)-a:k\n')" 'gate-secret-$(touch pwned-by-identity)-a'
  refuses "a secret with a backtick" CLIENT_KEYS_FILE "$(kf 'gate-secret-`touch pwned-by-identity`-aa:k\n')" 'gate-secret-`touch pwned-by-identity`-aa'
  refuses "a secret given twice" CLIENT_KEYS_FILE "$(kf '%s:a\n%s:b\n' "$K1" "$K1")" "$K1"
  refuses "comments and blank lines only" CLIENT_KEYS_FILE "$(kf '# nothing here\n\n   \n')"
  refuses "an empty file" CLIENT_KEYS_FILE "$(kf '')"
  refuses "a path that names nothing" CLIENT_KEYS_FILE "no-such-keys-file"
  refuses "a directory" CLIENT_KEYS_FILE "."
  refuses "a NUL byte" CLIENT_KEYS_FILE "$(kf '%s:treasury-bots\n\0\n' "$K1")" "$K1"
  head -c 262145 /dev/zero | tr '\0' 'a' >"$op/keys-huge"
  refuses "a file over 256 KiB" CLIENT_KEYS_FILE keys-huge
  [ ! -e "$op/pwned-by-identity" ] && [ ! -e "$scratch/pwned-by-identity" ] || fail "a command in a keys file was executed"

  refuses "a path that names nothing" IDENTITY_MAP_FILE "no-such-map.json"
  refuses "a directory" IDENTITY_MAP_FILE "."
  refuses "an empty file" IDENTITY_MAP_FILE "$(kf '   \n')"
  refuses "a JSON array, not an object" IDENTITY_MAP_FILE "$(kf '[{"units": []}]\n')"
  refuses "a NUL byte" IDENTITY_MAP_FILE "$(kf '{"units": []}\0\n')"
  { printf '{'; head -c 1048576 /dev/zero | tr '\0' ' '; printf '}'; } >"$op/map-huge.json"
  refuses "a file over 1 MiB" IDENTITY_MAP_FILE map-huge.json

  # A value an earlier run left in .env is held to the same rules.
  d="$(mk)"
  printf "GATEWAY_CLIENT_KEYS='short-secret:k'\n" >>"$d/.env"
  before="$(cat "$d/.env")"
  out="$(run "$d" resolve)"
  if [ "$(rc_of "$out")" = 0 ]; then
    fail "a GATEWAY_CLIENT_KEYS left in .env with a short secret was accepted on a re-run"
  elif grep -qF 'short-secret' <<<"$out"; then
    fail "a bad GATEWAY_CLIENT_KEYS in .env was refused by an answer that repeats the secret"
  fi
  [ "$(cat "$d/.env")" = "$before" ] || fail "a bad GATEWAY_CLIENT_KEYS in .env was refused after .env was changed"
  d="$(mk)"
  printf "GATEWAY_CLIENT_KEYS='%s'\n" "$SPEC2" >>"$d/.env"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" = 0 ] || fail "a usable GATEWAY_CLIENT_KEYS kept in .env was refused on a re-run: $out"
  d="$(mk)"
  printf "GATEWAY_IDENTITY_MAP='/somewhere/else.json'\n" >>"$d/.env"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" != 0 ] || fail "a GATEWAY_IDENTITY_MAP in .env that names another path was accepted"
  d="$(mk)"
  printf "GATEWAY_IDENTITY_MAP='%s'\n" "$MAP_PATH" >>"$d/.env"
  out="$(run "$d" resolve)"
  [ "$(rc_of "$out")" != 0 ] || fail "a GATEWAY_IDENTITY_MAP in .env with no map behind it was accepted, and the gateway would refuse to start"

  # ---- C. the second half, with the gateway image compose.yaml pins ---------------
  IMG="$(sed -n 's/^    image: \${TOKENFUSE_IMAGE:-\(ghcr\.io\/taipanbox\/tokenfuse:[^}]*\)}$/\1/p' compose.yaml | head -n 1)"
  if [ -z "$IMG" ]; then
    fail "compose.yaml names no \${TOKENFUSE_IMAGE:-ghcr.io/taipanbox/tokenfuse:...} image, so the second half could not be run"
  elif ! docker version >/dev/null 2>&1; then
    fail "no Docker here, so the gateway image could not read anything. This gate does not pass on a box that cannot run it."
  elif ! docker image inspect "$IMG" >/dev/null 2>&1 && ! docker pull -q "$IMG" >/dev/null 2>&1; then
    fail "could not pull $IMG, so the second half could not be run"
  else
    export IMG
    # Each case on its own box, all at once: every one starts a container.
    c_pair() {
      local d out
      d="$(mk)"
      out="$(run "$d" all CLIENT_KEYS_FILE=keys.txt IDENTITY_MAP_FILE=map.json)"
      if [ "$(rc_of "$out")" != 0 ]; then
        echo "FAIL: a valid keys file and map were refused by the second half: $out"
        return
      fi
      grep -qx 'count=2 map_on=1 changed=1' <<<"$out" || echo "FAIL: a first install with both files did not report two keys, a map and a change: $(grep '^count' <<<"$out")"
      [ "$(lines_of "$d" GATEWAY_CLIENT_KEYS)" = 1 ] && [ "$(sourced "$d" GATEWAY_CLIENT_KEYS)" = "$SPEC2" ] \
        || echo "FAIL: .env does not carry exactly one GATEWAY_CLIENT_KEYS line that reads back as the keys given"
      [ "$(lines_of "$d" GATEWAY_IDENTITY_MAP)" = 1 ] && [ "$(sourced "$d" GATEWAY_IDENTITY_MAP)" = "$MAP_PATH" ] \
        || echo "FAIL: .env does not carry exactly one GATEWAY_IDENTITY_MAP=$MAP_PATH"
      cmp -s "$op/map.json" "$d/identity/identity.json" || echo "FAIL: the installed map is not the map given"
      [ "$(ls -l "$d/identity/identity.json" | cut -c1-10)" = "-r--r--r--" ] || echo "FAIL: the installed map is not 0444"
      ! compgen -G "$d/identity.check.*" >/dev/null || echo "FAIL: the staging directory was left behind"
      head -n 1 "$d/.env" | grep -qx 'SENTINEL=1' || echo "FAIL: writing the keys disturbed the rest of .env"

      cp "$d/.env" "$d/.env.before"
      cp "$d/identity/identity.json" "$d/map.before"
      out="$(run "$d" all)"
      [ "$(rc_of "$out")" = 0 ] || { echo "FAIL: a re-run that names no file was refused, so an upgrade would stop: $out"; return; }
      grep -qx 'count=2 map_on=1 changed=0' <<<"$out" || echo "FAIL: a re-run that names no file did not keep both: $(grep '^count' <<<"$out")"
      cmp -s "$d/.env" "$d/.env.before" || echo "FAIL: a re-run that names no file changed .env"
      cmp -s "$d/identity/identity.json" "$d/map.before" || echo "FAIL: a re-run that names no file changed the map"

      out="$(run "$d" all IDENTITY_MAP_FILE=map.json)"
      grep -qx 'count=2 map_on=1 changed=0' <<<"$out" || echo "FAIL: the same map given again was installed as a change, which restarts the gateway for nothing: $(grep -E '^(count|die)' <<<"$out")"

      out="$(run "$d" all IDENTITY_MAP_FILE=map2.json)"
      grep -qx 'count=2 map_on=1 changed=1' <<<"$out" || echo "FAIL: a new map was not installed as a change: $(grep -E '^(count|die)' <<<"$out")"
      cmp -s "$op/map2.json" "$d/identity/identity.json" || echo "FAIL: a new map did not replace the old one"
      [ "$(lines_of "$d" GATEWAY_IDENTITY_MAP)" = 1 ] || echo "FAIL: a new map left more than one GATEWAY_IDENTITY_MAP line in .env"

      out="$(run "$d" all CLIENT_KEYS_FILE=keys3.txt)"
      grep -qx 'count=3 map_on=1 changed=0' <<<"$out" || echo "FAIL: a new keys file checked against the kept map did not pass: $(grep -E '^(count|die)' <<<"$out")"
      [ "$(lines_of "$d" GATEWAY_CLIENT_KEYS)" = 1 ] && [ "$(sourced "$d" GATEWAY_CLIENT_KEYS)" = "$SPEC3" ] \
        || echo "FAIL: a new keys file did not REPLACE the GATEWAY_CLIENT_KEYS line"

      cp "$d/.env" "$d/.env.before"
      out="$(run "$d" all CLIENT_KEYS_FILE=keys-treasury-only.txt)"
      [ "$(rc_of "$out")" != 0 ] || echo "FAIL: a keys file that drops a key the kept map binds was accepted"
      cmp -s "$d/.env" "$d/.env.before" || echo "FAIL: a refused keys file still changed .env"
    }
    c_tilde() {
      local d out
      d="$(mk)"
      out="$(run "$d" all CLIENT_KEYS_FILE=keys-tilde.txt)"
      [ "$(rc_of "$out")" = 0 ] || { echo "FAIL: a secret holding :~ was refused: $out"; return; }
      [ "$(sourced "$d" GATEWAY_CLIENT_KEYS)" = "$KT:tilde-bot,$K1:treasury-bots" ] \
        || echo "FAIL: GATEWAY_CLIENT_KEYS does not read back as given when .env is sourced; a value with :~ in it has to be quoted"
      grep -q "^GATEWAY_IDENTITY_MAP=" "$d/.env" && echo "FAIL: keys alone wrote a GATEWAY_IDENTITY_MAP line"
      grep -qx 'count=2 map_on=0 changed=0' <<<"$out" || echo "FAIL: keys alone did not report two keys and no map: $(grep '^count' <<<"$out")"
    }
    c_refused() { # label keysfile mapfile needle
      local d out
      d="$(mk)"
      out="$(run "$d" all ${2:+CLIENT_KEYS_FILE=$2} ${3:+IDENTITY_MAP_FILE=$3})"
      if [ "$(rc_of "$out")" = 0 ]; then
        echo "FAIL: $1 was accepted"
      elif ! grep -qF -- "$4" <<<"$out"; then
        echo "FAIL: $1 was refused, but not saying: $4 ($(grep '^die' <<<"$out"))"
      fi
      [ "$(cat "$d/.env")" = "SENTINEL=1" ] || echo "FAIL: $1 was refused after .env was changed"
      [ ! -e "$d/identity/identity.json" ] || echo "FAIL: $1 was refused after the map was put in place"
      ! compgen -G "$d/identity.check.*" >/dev/null || echo "FAIL: $1 left the staging directory behind"
      if grep -qF -- "$K1" <<<"$out" || grep -qF -- "$K3" <<<"$out"; then echo "FAIL: $1 was refused by an answer that repeats a secret"; fi
    }
    c_prefixes() {
      local d out
      d="$(mk)"
      out="$(run "$d" all IDENTITY_MAP_FILE=map-prefixes.json)"
      grep -qx 'count=0 map_on=1 changed=1' <<<"$out" || echo "FAIL: a map of units and prefixes alone, with no keys, was not installed: $(grep -E '^(count|die)' <<<"$out")"
    }
    c_pair >"$scratch/c.pair" 2>&1 &
    c_tilde >"$scratch/c.tilde" 2>&1 &
    c_refused "a map that binds a key id no client key carries" keys-treasury-only.txt map.json "research-bots that no client key carries" >"$scratch/c.orphan" 2>&1 &
    c_refused "a client key the map does not bind" keys-orphan.txt map.json "orphan have no keys[] binding" >"$scratch/c.unbound" 2>&1 &
    c_refused "a map that configures nothing ({})" keys.txt map-empty-object.json "configures nothing" >"$scratch/c.empty" 2>&1 &
    c_refused "a map naming a unit it does not declare" keys.txt map-unknown-unit.json "not declared in units[]" >"$scratch/c.unknown" 2>&1 &
    c_refused "a map with key bindings and no client keys at all" "" map.json "that no client key carries" >"$scratch/c.nokeys" 2>&1 &
    c_prefixes >"$scratch/c.prefixes" 2>&1 &
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
  restart_line="$(ln_of 'restart tokenfuse-gateway')"
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
  section8="$(sed -n "${verify_line:-1},\$p" install.sh)"
  if [ -z "$verify_line" ] || ! grep -qF 'check "client keys: a call with no key is refused"' <<<"$section8" \
    || ! grep -qF 'check_log "identity map: the gateway reads it"' <<<"$section8"; then
    fail "section 8 no longer asks the running gateway whether it refuses a call with no key and reads its map, so a box whose gateway ignored both would pass"
  fi
  reach="$(sed -n '/^IDENTITY_REACH=""$/,/^fi$/p' install.sh)"
  if ! grep -qF 'x-fuse-key header' <<<"$reach" || ! grep -qF 'x-fuse-agent-id' <<<"$reach"; then
    fail "the end of the run no longer says which headers an agent sends (x-fuse-key, x-fuse-agent-id)"
  elif ! grep -q '^\$REACH\$IDENTITY_REACH$' install.sh; then
    fail "the closing report does not print IDENTITY_REACH"
  fi
fi

# ---- E. resolved ------------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d "$scratch/cfg.XXXXXX")"
  cp compose.yaml "$cdir/compose.yaml"
  grep -o '\${[A-Z_]*:?' compose.yaml | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/base.env"
  resolved() { # extra .env lines on stdin; prints keys|map|mount|holders
    cat "$cdir/base.env" - >"$cdir/.env"
    env -u GATEWAY_CLIENT_KEYS -u GATEWAY_IDENTITY_MAP docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" config --format json 2>"$cdir/err" |
      python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]
g = s["tokenfuse-gateway"]
env = g.get("environment") or {}
mount = [v for v in g.get("volumes", []) if v.get("target") == "/etc/tokenfuse/identity"]
m = "none"
if mount:
    v = mount[0]
    m = "%s,%s,%s" % (v.get("type"), "ro" if v.get("read_only") else "rw", v.get("source", "").rsplit("/", 1)[-1])
secret = "gate-resolved-secret-aaaaaaaaaaaa"
holders = sorted(n for n, svc in s.items() if secret in json.dumps(svc.get("environment") or {}))
print("|".join([env.get("TOKENFUSE_CLIENT_KEYS", "<unset>"), env.get("TOKENFUSE_IDENTITY_MAP", "<unset>"), m, ",".join(holders)]))
' 2>>"$cdir/err"
  }
  got="$(resolved </dev/null)"
  [ "$got" = "||bind,ro,identity|" ] || fail "resolved: a default box reads '$got', not empty keys, no map and a read-only ./identity bind ($(head -1 "$cdir/err"))"
  got="$(printf "GATEWAY_CLIENT_KEYS='gate-resolved-secret-aaaaaaaaaaaa:k1'\nGATEWAY_IDENTITY_MAP='%s'\n" "$MAP_PATH" | resolved)"
  [ "$got" = "gate-resolved-secret-aaaaaaaaaaaa:k1|$MAP_PATH|bind,ro,identity|tokenfuse-gateway" ] \
    || fail "resolved: a box whose .env sets both reads '$got', so the keys or the map do not reach the gateway, or reach more than the gateway"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 29."
  exit 1
fi
echo "OK: every gateway reads the client keys and the identity map from .env, off by default, the map mounted"
echo "    read only; install.sh refuses hostile files before anything is installed and lets the pinned"
echo "    gateway image read the pair before anything restarts, keeps both on a re-run, replaces rather"
echo "    than repeats, never echoes a secret, restarts the gateway for a new map, and names the headers."
