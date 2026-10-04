#!/usr/bin/env bash
#
# Enforces invariant 20 of CLAUDE.md: the gateway's run-budget ceiling is set on
# every gateway definition, from one installer variable, and an unusable value
# is refused before the box is touched.
#
# WHAT THIS IS ABOUT
#
# A run's budget used to be whatever the AGENT said in `x-fuse-budget-usd`, and
# the next call of an open run could widen it, so on a box with no client keys
# and no identity map the per-run ceiling was the agent's own word. tokenfuse
# 1.5.0 (invariant 73) adds `TOKENFUSE_MAX_RUN_BUDGET_USD`, which clamps a
# budget that came from the caller header, a policy default or its built-in
# default. It is OFF unless set, so a launcher that does not set it is exactly
# as unbounded as before and nothing says so: the release notes say "the
# launchers do not set it yet". This is the gate that they do.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE, the subjects derived from compose.yaml's own image and command
#      lines like gateway-cache-is-off.sh (a service that runs the tokenfuse
#      gateway image with no subcommand): each sets
#      TOKENFUSE_MAX_RUN_BUDGET_USD to `${RUN_BUDGET_CEILING_USD:-5.00}`, the
#      one installer variable with a valid default. A literal would make the
#      ceiling impossible to move; a different variable would make the installer
#      variable do nothing; an invalid default would stop the gateway at start
#      (tokenfuse exits 2). The default is 5.00 because that is tokenfuse's own
#      DEFAULT_RUN_BUDGET, so an ordinary run is unchanged and only a caller
#      who declares more is clamped (CLAUDE.md invariant 20, @claude 2026-10-04).
#      Moving it is a decision, so this names 5.00 and fails on any other.
#   B. THE INSTALLER, `# run-budget-ceiling: begin` .. `end` lifted out of
#      install.sh and run in a scratch STACK_DIR: nothing set writes nothing and
#      leaves .env alone; a good figure is written, and a later one REPLACES it
#      rather than adding a second line; every unusable figure (zero, a sign,
#      an exponent, a trailing point, a seventh decimal, words, a command
#      substitution) refuses saying so, before touching .env, and never echoes
#      what it was given; a bad value already in .env refuses too, because that
#      is a gateway that exits 2 on every start.
#   C. RESOLVED. `docker compose config` for the default and for a box whose
#      .env sets 2.50: the gateway's value is 5.00, then 2.50.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway service, no install.sh block, no functions in it, or no Docker to
# resolve the configuration with: each is reported and fails.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

# ---- A. compose --------------------------------------------------------------
python3 - "${1:-compose.yaml}" <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()
blocks, section, current = {}, None, None
for line in text.split("\n"):
    top = re.match(r"^([a-z-]+):\s*$", line)
    if top:
        section, current = top.group(1), None
        continue
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m and section == "services":
        current = m.group(1)
        blocks[current] = []
        continue
    if section == "services" and current is not None:
        blocks[current].append(line)


def is_gateway(block):
    image = any(
        re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/tokenfuse:", l) for l in block
    )
    bare = any(
        re.match(r'^\s*command:\s*\["/usr/local/bin/tokenfuse"\]\s*$', l) for l in block
    )
    return image and bare


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


subjects = sorted(n for n, b in blocks.items() if is_gateway(b))
if not subjects:
    print("FAIL: no service in compose.yaml both uses the tokenfuse gateway image and runs")
    print("      it with no subcommand, so this gate measured NOTHING about the run-budget")
    print("      ceiling. Silence here is not health.")
    sys.exit(1)

bad = 0
VALID = re.compile(r"^\$\{RUN_BUDGET_CEILING_USD:-([0-9]{1,12}(?:\.[0-9]{1,6})?)\}$")
for name in subjects:
    value = env_value(blocks[name], "TOKENFUSE_MAX_RUN_BUDGET_USD")
    if value is None:
        print(f"FAIL: {name} sets no TOKENFUSE_MAX_RUN_BUDGET_USD. Unset, a caller chooses its own")
        print("      per-run budget and widens it on the next call: the ceiling tokenfuse 1.5.0")
        print("      added is off, and nothing on the box says so.")
        bad += 1
        continue
    m = VALID.match(value.strip('"').strip("'"))
    if not m:
        print(f"FAIL: {name} sets TOKENFUSE_MAX_RUN_BUDGET_USD: {value}, which is not")
        print("      ${RUN_BUDGET_CEILING_USD:-<a valid figure>}. A literal cannot be moved by the")
        print("      one installer variable, another variable makes that one do nothing, and an")
        print("      unreadable default makes tokenfuse exit 2 at start.")
        bad += 1
        continue
    default = m.group(1)
    if default != "5.00":
        print(f"FAIL: {name} defaults the ceiling to {default}. It is 5.00 on purpose, tokenfuse's")
        print("      own default run budget, so an ordinary run is unchanged. Moving it is a")
        print("      decision: change CLAUDE.md invariant 20 and this gate together.")
        bad += 1
if bad:
    sys.exit(1)
print(f"compose: {', '.join(subjects)} set the ceiling from RUN_BUDGET_CEILING_USD, default 5.00")
PY

# ---- B. the installer's block --------------------------------------------------
BLOCK="$(sed -n '/^# run-budget-ceiling: begin$/,/^# run-budget-ceiling: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# run-budget-ceiling: begin' .. '# run-budget-ceiling: end' block, so this measured nothing about the installer's half"
elif ! printf '%s' "$BLOCK" | grep -q '^ceiling_resolve()' || ! printf '%s' "$BLOCK" | grep -q '^ceiling_apply()' || ! printf '%s' "$BLOCK" | grep -q '^ceiling_valid()'; then
  fail "the run-budget-ceiling block defines no ceiling_resolve, ceiling_apply or ceiling_valid, so this measured nothing"
elif ! grep -q '^ceiling_resolve$' install.sh || ! grep -q '^ceiling_apply$' install.sh; then
  fail "install.sh never calls ceiling_resolve and ceiling_apply, so the block is dead text"
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
        ceiling_resolve
        ceiling_apply
        printf "set=%s\n" "$CEILING_SET"'
      printf 'rc=%s\n' "$?"
    ) 2>&1
  }
  rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
  lines_of() { grep -c "^RUN_BUDGET_CEILING_USD=" "$1/.env" || true; }

  # 1. nothing set: nothing written.
  d="$(mk)"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] || fail "nothing set: it was refused: $out"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "nothing set: .env was changed, so a default box would carry a line it never asked for"

  # 2. good figures are written, once, and the later one replaces the earlier.
  for v in 5 2.50 0.000001 999999999999 0.5; do
    d="$(mk)"
    out="$(run "$d" RUN_BUDGET_CEILING_USD="$v")"
    [ "$(rc_of "$out")" = 0 ] || fail "RUN_BUDGET_CEILING_USD=$v was refused and is a usable figure: $out"
    grep -qx "RUN_BUDGET_CEILING_USD=$v" "$d/.env" || fail "RUN_BUDGET_CEILING_USD=$v did not reach .env"
    [ "$(cat "$d/.env" | head -1)" = "SENTINEL=1" ] || fail "RUN_BUDGET_CEILING_USD=$v disturbed the rest of .env"
  done
  d="$(mk)"
  run "$d" RUN_BUDGET_CEILING_USD=2.50 >/dev/null
  out="$(run "$d" RUN_BUDGET_CEILING_USD=7)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(lines_of "$d")" = 1 ] && grep -qx 'RUN_BUDGET_CEILING_USD=7' "$d/.env" \
    || fail "a second figure did not replace the first (lines: $(lines_of "$d")): $out"
  # a re-run that says nothing keeps what was set
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] && grep -qx 'RUN_BUDGET_CEILING_USD=7' "$d/.env" \
    || fail "a re-run with nothing set lost the ceiling an earlier run wrote: $out"

  # 3. every unusable figure refuses, names the variable, touches nothing, echoes nothing.
  refuses() { # label value
    local label="$1" v="$2" d out
    d="$(mk)"
    out="$(run "$d" RUN_BUDGET_CEILING_USD="$v")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "RUN_BUDGET_CEILING_USD ($label) was accepted, and tokenfuse would exit 2 on it"
    elif ! printf '%s' "$out" | grep -qF 'RUN_BUDGET_CEILING_USD'; then
      fail "RUN_BUDGET_CEILING_USD ($label) was refused without naming the variable"
    elif [ "$(cat "$d/.env")" != "SENTINEL=1" ]; then
      fail "RUN_BUDGET_CEILING_USD ($label) was refused AFTER touching .env, which is half a job"
    fi
    # Only a figure long enough not to be a substring of the refusal's own
    # examples ("5 or 2.50", "never 0"): a one-character value would "echo"
    # whatever the message happens to say.
    if [ "${#v}" -ge 5 ] && printf '%s' "$out" | grep -qF -- "$v"; then
      fail "RUN_BUDGET_CEILING_USD ($label) was refused by an answer that echoed the value"
    fi
  }
  refuses "zero" 0
  refuses "zero with decimals" 0.00
  refuses "a minus sign" -1
  refuses "a plus sign" +1
  refuses "an exponent" 1e9
  refuses "a trailing point" 5.
  refuses "a leading point" .5
  refuses "a seventh decimal" 1.1234567
  refuses "words" ceiling
  refuses "a comma" 1,5
  refuses "a space" "5 USD"
  refuses "a thirteen digit figure" 1000000000000
  refuses "a command substitution" '$(touch pwned-by-ceiling)'
  [ ! -e "$scratch/pwned-by-ceiling" ] || fail "a command substitution in the value was executed"

  # 4. a bad figure already in .env is a gateway that exits on every start.
  d="$(mk)"
  printf "RUN_BUDGET_CEILING_USD=0\n" >>"$d/.env"
  before="$(cat "$d/.env")"
  out="$(run "$d")"
  if [ "$(rc_of "$out")" = 0 ]; then
    fail "a RUN_BUDGET_CEILING_USD=0 left in .env was accepted: the gateway would refuse to start"
  elif [ "$(cat "$d/.env")" != "$before" ]; then
    fail "a bad ceiling in .env was refused after .env was changed"
  fi
  d="$(mk)"
  printf "RUN_BUDGET_CEILING_USD='2.50'\n" >>"$d/.env"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] || fail "a quoted, usable ceiling in .env was refused: $out"
fi

# ---- C. resolved ---------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d)"
  cp compose.yaml "$cdir/compose.yaml"
  mkdir -p "$cdir/typed" "$cdir/delegation-public" "$cdir/environments"
  : >"$cdir/policy.yaml"
  grep -o '\${[A-Z_]*:?' compose.yaml | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/base.env"
  ceiling_of() { # extra .env lines on stdin
    cat "$cdir/base.env" - >"$cdir/.env"
    docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" config --format json 2>"$cdir/err" |
      python3 -c "import json,sys; print(json.load(sys.stdin)['services']['tokenfuse-gateway']['environment'].get('TOKENFUSE_MAX_RUN_BUDGET_USD',''))" 2>>"$cdir/err"
  }
  got="$(ceiling_of </dev/null)"
  [ "$got" = "5.00" ] || fail "resolved: a default box's gateway has TOKENFUSE_MAX_RUN_BUDGET_USD='$got', not 5.00 ($(head -1 "$cdir/err"))"
  got="$(ceiling_of <<<"RUN_BUDGET_CEILING_USD=2.50")"
  [ "$got" = "2.50" ] || fail "resolved: a box whose .env sets 2.50 has TOKENFUSE_MAX_RUN_BUDGET_USD='$got', so the installer variable moves nothing"
  rm -rf "$cdir"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 20."
  exit 1
fi
echo "OK: every gateway definition sets TOKENFUSE_MAX_RUN_BUDGET_USD from RUN_BUDGET_CEILING_USD (default 5.00,"
echo "    which resolves to 5.00 and moves to 2.50 with the variable), the installer writes only what it was"
echo "    given, replaces rather than repeats, and refuses every figure tokenfuse would exit on, before"
echo "    touching .env and without echoing it."
