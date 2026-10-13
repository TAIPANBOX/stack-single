#!/usr/bin/env bash
#
# Enforces invariant 28 of CLAUDE.md: personal data in prompts and tool
# arguments is recorded in shadow by default on every box, and one installer
# variable is the only way to move it.
#
# WHAT THIS IS ABOUT
#
# tokenfuse has two PII scanners (email, card and phone numbers): the gateway
# reads TOKENFUSE_DLP_PII and the MCP broker reads TOKENFUSE_MCP_DLP_PII. Both
# read an unset value as off (crates/gateway/src/defaults.rs, dlp_pii_mode_from;
# crates/gateway/src/main.rs for the broker). From tokenfuse v1.12.0 a value they do
# not know exits at start rather than reading as off. Off finds nothing, so a box left on it looks covered
# and is not. @decided 2026-10-13 (paraphrased): this launcher runs both scanners
# in shadow by default, and an operator keeps one switch to move them to off,
# mask or block. This gate is that decision, held where a later edit would break
# it.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. The subjects are derived from compose.yaml's own image and
#      command lines: every service whose image is the tokenfuse gateway image
#      and whose command is the bare binary (a gateway), and the service whose
#      command is `mcp-broker` (the MCP broker, which this launcher runs under
#      the typed profile). Each gateway sets TOKENFUSE_DLP_PII and the broker
#      sets TOKENFUSE_MCP_DLP_PII, both to the same one switch, so each reads
#      `${TOKENFUSE_DLP_PII:-shadow}`. A missing setting is off; a literal cannot
#      be moved by the switch; a default other than shadow is the fault; a
#      setting that reads another variable makes the switch do nothing.
#   B. THE INSTALLER, `# pii-mode: begin` .. `end` lifted out of install.sh and
#      run in a scratch STACK_DIR: nothing set writes nothing; off, shadow, mask
#      and block are written; a later value REPLACES the earlier line; every
#      other value refuses before .env is touched, names the variable and never
#      echoes what it was given; a bad value already in .env refuses too.
#   C. ORDER. pii_resolve runs before the first package install, so a refusal
#      really does mean nothing was installed.
#   D. RESOLVED. `docker compose --profile typed config` with nothing set, and
#      with .env setting off and block: the gateway and the broker read the same
#      value each time.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No subject, no installer block, no functions in it, or no Docker to resolve
# the configuration with: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

# ---- A. compose --------------------------------------------------------------
python3 - "${1:-compose.yaml}" <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()

# Two-space-indented service blocks, the same reader firewall-is-enforce.sh
# uses: compose.yaml is hand-written and hand-indented.
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


def role(block):
    """'gateway' for the bare binary, 'broker' for the MCP broker, else None."""
    if not any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/tokenfuse:", l) for l in block):
        return None
    if any(re.match(r'^\s*command:\s*\["/usr/local/bin/tokenfuse"\]\s*$', l) for l in block):
        return "gateway"
    if any(re.match(r'^\s*command:\s*\["mcp-broker"\]\s*$', l) for l in block):
        return "broker"
    return None


def env_value(block, key):
    in_env = False
    for line in block:
        if re.match(r"^    environment:\s*$", line):
            in_env = True
            continue
        if in_env:
            if re.match(r"^    \S", line) or not line.strip():
                in_env = False
                continue
            m = re.match(r"^\s*" + re.escape(key) + r":\s*(.+?)\s*$", line)
            if m:
                return m.group(1).strip()
    return None


KEY = {"gateway": "TOKENFUSE_DLP_PII", "broker": "TOKENFUSE_MCP_DLP_PII"}
WANT = "${TOKENFUSE_DLP_PII:-shadow}"

subjects = sorted((n, role(b)) for n, b in blocks.items() if role(b))
if not subjects:
    print("FAIL: no service in compose.yaml uses the tokenfuse image as a gateway or as the")
    print("      MCP broker, so this gate measured NOTHING about personal-data detection.")
    print("      Silence here is not health.")
    sys.exit(1)

bad = 0
for name, kind in subjects:
    key = KEY[kind]
    value = env_value(blocks[name], key)
    if value is None:
        print(f"FAIL: {name} sets no {key}. Unset, tokenfuse runs PII detection off: it finds")
        print("      nothing and says nothing.")
        bad += 1
        continue
    v = value.strip('"').strip("'")
    if v == WANT:
        continue
    m = re.match(r"^\$\{TOKENFUSE_DLP_PII:-(off|shadow|mask|block)\}$", v)
    if m:
        print(f"FAIL: {name} defaults PII detection to {m.group(1)}. It is shadow by default on")
        print("      purpose, for every box. Moving it is a decision: change CLAUDE.md invariant")
        print("      28 and this gate together.")
        bad += 1
        continue
    print(f"FAIL: {name} sets {key}: {value}, which is not {WANT}.")
    print("      A literal cannot be moved by the one installer switch, and another")
    print("      variable makes that switch do nothing.")
    bad += 1
if bad:
    sys.exit(1)
print("compose: " + ", ".join(f"{n} ({k})" for n, k in subjects) + " read PII detection from TOKENFUSE_DLP_PII, default shadow")
PY

# ---- B. the installer's block --------------------------------------------------
BLOCK="$(sed -n '/^# pii-mode: begin$/,/^# pii-mode: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# pii-mode: begin' .. '# pii-mode: end' block, so this measured nothing about the installer's half"
elif ! printf '%s' "$BLOCK" | grep -q '^pii_valid()' || ! printf '%s' "$BLOCK" | grep -q '^pii_resolve()' || ! printf '%s' "$BLOCK" | grep -q '^pii_apply()'; then
  fail "the pii-mode block defines no pii_resolve, pii_apply or pii_valid, so this measured nothing"
elif ! grep -q '^pii_resolve$' install.sh || ! grep -q '^pii_apply$' install.sh; then
  fail "install.sh never calls pii_resolve and pii_apply, so the block is dead text"
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  mk() {
    local d
    d="$(mktemp -d "$scratch/box.XXXXXX")"
    printf 'SENTINEL=1\n' >"$d/.env"
    printf '%s' "$d"
  }
  run() {
    local d="$1"
    shift
    (
      cd "$d" || exit 99
      env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" "$@" bash -c '
        set -euo pipefail
        note() { printf "note: %s\n" "$*"; }
        die() { printf "die: %s\n" "$*"; exit 1; }
        eval "$BLOCK"
        pii_resolve
        pii_apply
        printf "set=%s\n" "$PII_SET"'
      printf 'rc=%s\n' "$?"
    ) 2>&1
  }
  rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
  lines_of() { grep -c "^TOKENFUSE_DLP_PII=" "$1/.env" || true; }

  # 1. nothing set: nothing written, the default box is untouched.
  d="$(mk)"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] || fail "nothing set: it was refused: $out"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "nothing set: .env was changed, so a default box would carry a line it never asked for"

  # 2. each usable mode is written, and the line is the one the gateway reads.
  for v in off shadow mask block; do
    d="$(mk)"
    out="$(run "$d" TOKENFUSE_DLP_PII="$v")"
    [ "$(rc_of "$out")" = 0 ] || fail "TOKENFUSE_DLP_PII=$v was refused and is a usable mode: $out"
    grep -qx "TOKENFUSE_DLP_PII=$v" "$d/.env" || fail "TOKENFUSE_DLP_PII=$v did not reach .env"
    [ "$(head -1 "$d/.env")" = "SENTINEL=1" ] || fail "TOKENFUSE_DLP_PII=$v disturbed the rest of .env"
  done

  # 3. a later value REPLACES the earlier one, and a re-run that says nothing keeps it.
  d="$(mk)"
  run "$d" TOKENFUSE_DLP_PII=shadow >/dev/null
  out="$(run "$d" TOKENFUSE_DLP_PII=block)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(lines_of "$d")" = 1 ] && grep -qx 'TOKENFUSE_DLP_PII=block' "$d/.env" \
    || fail "a second value did not replace the first (lines: $(lines_of "$d")): $out"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] && grep -qx 'TOKENFUSE_DLP_PII=block' "$d/.env" \
    || fail "a re-run with nothing set lost the value an earlier run wrote: $out"

  # 4. every other value refuses, names the variable, touches nothing, echoes nothing.
  refuses() { # label value
    local label="$1" v="$2" d out
    d="$(mk)"
    out="$(run "$d" TOKENFUSE_DLP_PII="$v")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "TOKENFUSE_DLP_PII ($label) was accepted, and tokenfuse would refuse to start on it"
    elif ! printf '%s' "$out" | grep -qF 'TOKENFUSE_DLP_PII'; then
      fail "TOKENFUSE_DLP_PII ($label) was refused without naming the variable"
    elif [ "$(cat "$d/.env")" != "SENTINEL=1" ]; then
      fail "TOKENFUSE_DLP_PII ($label) was refused AFTER touching .env, which is half a job"
    fi
    # Only a value long enough not to occur in the refusal's own wording
    # ("off, shadow, mask or block"): a short one would "echo" by coincidence.
    if [ "${#v}" -ge 7 ] && printf '%s' "$out" | grep -qF -- "$v"; then
      fail "TOKENFUSE_DLP_PII ($label) was refused by an answer that echoed the value"
    fi
  }
  refuses "capitalised" SHADOW
  refuses "a misspelling" shadowed
  refuses "a near word" blocking
  refuses "a word from another switch" enforce
  refuses "on, which is not a mode" on
  refuses "a number" 1
  refuses "a list" "shadow,off"
  refuses "a shell metacharacter" 'shadow;touch pwned-by-pii'
  refuses "a command substitution" "\$(touch $scratch/pwned-by-pii)"
  [ ! -e "$scratch/pwned-by-pii" ] || fail "a command substitution in the value was executed"

  # 5. a bad value already in .env is a gateway that reads the wrong mode.
  d="$(mk)"
  printf 'TOKENFUSE_DLP_PII=shadowed\n' >>"$d/.env"
  before="$(cat "$d/.env")"
  out="$(run "$d")"
  if [ "$(rc_of "$out")" = 0 ]; then
    fail "a TOKENFUSE_DLP_PII=shadowed left in .env was accepted: the gateway would refuse to start"
  elif [ "$(cat "$d/.env")" != "$before" ]; then
    fail "a bad value in .env was refused after .env was changed"
  fi
  d="$(mk)"
  printf "TOKENFUSE_DLP_PII='mask'\n" >>"$d/.env"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] || fail "a quoted, usable value in .env was refused: $out"

  # C. ORDER: the validation has to run before the first package install.
  first_apt="$(grep -n '^[[:space:]]*apt-get ' install.sh | head -n 1 | cut -d: -f1)"
  pii_line="$(grep -n '^pii_resolve$' install.sh | head -n 1 | cut -d: -f1)"
  if [ -n "$first_apt" ] && [ -n "$pii_line" ] && [ "$pii_line" -gt "$first_apt" ]; then
    fail "pii_resolve (line $pii_line) runs after the first package install (line $first_apt), so a refused value would arrive after something was installed"
  fi
fi

# ---- D. resolved ---------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d)"
  cp compose.yaml "$cdir/compose.yaml"
  mkdir -p "$cdir/typed" "$cdir/delegation-public" "$cdir/environments"
  : >"$cdir/policy.yaml"
  grep -o '\${[A-Z_]*:?' compose.yaml | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/base.env"
  # Prints "<gateway value> <broker value>" for the typed profile, which is the
  # profile the broker starts under.
  resolved() { # extra .env lines on stdin
    cat "$cdir/base.env" - >"$cdir/.env"
    env -u TOKENFUSE_DLP_PII -u TOKENFUSE_MCP_DLP_PII docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" --profile typed config --format json 2>"$cdir/err" |
      python3 -c "import json,sys; s=json.load(sys.stdin)['services']; print(s['tokenfuse-gateway']['environment'].get('TOKENFUSE_DLP_PII',''), s['tokenfuse-mcp-broker']['environment'].get('TOKENFUSE_MCP_DLP_PII',''))" 2>>"$cdir/err"
  }
  got="$(resolved </dev/null)"
  [ "$got" = "shadow shadow" ] || fail "resolved: a default box reads '$got' for the gateway and the broker, not 'shadow shadow' ($(head -1 "$cdir/err"))"
  got="$(resolved <<<"TOKENFUSE_DLP_PII=off")"
  [ "$got" = "off off" ] || fail "resolved: a .env that sets off reads '$got', so the one switch does not move both"
  got="$(resolved <<<"TOKENFUSE_DLP_PII=block")"
  [ "$got" = "block block" ] || fail "resolved: a .env that sets block reads '$got', so the one switch does not move both"
  rm -rf "$cdir"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 28."
  exit 1
fi
echo "OK: every gateway and the MCP broker read PII detection from TOKENFUSE_DLP_PII, default shadow; the"
echo "    installer writes only the value it was given, replaces rather than repeats, refuses every value"
echo "    tokenfuse would read as off, before touching .env and without echoing it, and runs before any"
echo "    package install; the resolved configuration moves both scanners together."
