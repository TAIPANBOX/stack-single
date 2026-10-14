#!/usr/bin/env bash
#
# Enforces invariant 27 of CLAUDE.md: every gateway this launcher starts runs
# tokenfuse's agent firewall in enforce by default, and one installer variable
# is the only way to run it in shadow or off.
#
# WHAT THIS IS ABOUT
#
# The agent firewall is taint tracking: it judges what a run may do after the
# run has read untrusted input. tokenfuse reads TOKENFUSE_FIREWALL as enforce,
# shadow or off, and an unset value as shadow (crates/gateway/src/firewall.rs,
# from_env, tokenfuse v1.11.0). From tokenfuse v1.11.1 a value it does not know
# exits at start instead (release notes). Shadow records what it would refuse and refuses
# nothing, so a box left on shadow looks protected in its configuration and is
# not. @decided 2026-10-13 (paraphrased): this launcher runs the firewall in
# enforce by default, and an operator keeps one switch to run it in shadow or
# off. This gate is that decision, held where a later edit would break it.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. The subjects are derived from compose.yaml's own image and
#      command lines, like gateway-cache-is-off.sh: every service whose image is
#      the tokenfuse GATEWAY image and whose command is the bare binary with no
#      subcommand. The MCP broker, focus-export and the control plane are not
#      gateways and are left out on purpose. Each subject sets TOKENFUSE_FIREWALL
#      to `${TOKENFUSE_FIREWALL:-enforce}`. A missing setting leaves the gateway
#      on shadow; a literal cannot be moved by the one switch; a default of shadow
#      or off is the fault this gate exists to catch.
#   B. THE INSTALLER, `# firewall-mode: begin` .. `end` lifted out of install.sh
#      and run in a scratch STACK_DIR: nothing set writes nothing and leaves .env
#      alone; enforce, shadow and off are written, and a later one REPLACES the
#      earlier line; every other value refuses before .env is touched, names the
#      variable, and never echoes what it was given; a bad value already in .env
#      refuses too, because tokenfuse would refuse to start on it.
#   C. RESOLVED. `docker compose config`, with the OpenAI door's profile on, for
#      a box with nothing set, and for a .env that sets shadow and then off: every
#      gateway's value is enforce, then shadow, then off, and the gateways read back
#      are the ones section A found, so the OpenAI door (CLAUDE.md invariant 32) is
#      read as well as the first.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway service, no installer block, no functions in it, or no Docker to
# resolve the configuration with: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

# ---- A. compose --------------------------------------------------------------
gwlist="$(mktemp)"
python3 - "${1:-compose.yaml}" "$gwlist" <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()

# Two-space-indented service blocks, the same reader gateway-cache-is-off.sh
# and run-budget-ceiling.sh use: compose.yaml is hand-written and hand-indented.
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
open(sys.argv[2], "w").write("".join(n + "\n" for n in subjects))
if not subjects:
    print("FAIL: no service in compose.yaml both uses the tokenfuse gateway image and runs")
    print("      it with no subcommand, so this gate measured NOTHING about the agent")
    print("      firewall. Silence here is not health.")
    sys.exit(1)

bad = 0
ENFORCE = "${TOKENFUSE_FIREWALL:-enforce}"
for name in subjects:
    value = env_value(blocks[name], "TOKENFUSE_FIREWALL")
    if value is None:
        print(f"FAIL: {name} sets no TOKENFUSE_FIREWALL. Unset, tokenfuse runs its agent")
        print("      firewall in shadow: it records what it would refuse and refuses nothing.")
        bad += 1
        continue
    v = value.strip('"').strip("'")
    if v == ENFORCE:
        continue
    m = re.match(r"^\$\{TOKENFUSE_FIREWALL:-(off|shadow)\}$", v)
    if m:
        print(f"FAIL: {name} defaults the agent firewall to {m.group(1)}. It is enforce by")
        print("      default on purpose, for every box. Moving it is a decision: change")
        print("      CLAUDE.md invariant 27 and this gate together.")
        bad += 1
        continue
    print(f"FAIL: {name} sets TOKENFUSE_FIREWALL: {value}, which is not {ENFORCE}.")
    print("      A literal cannot be moved by the one installer switch, and another")
    print("      variable makes that switch do nothing.")
    bad += 1
if bad:
    sys.exit(1)
print(f"compose: {', '.join(subjects)} set the agent firewall from TOKENFUSE_FIREWALL, default enforce")
PY

# ---- B. the installer's block --------------------------------------------------
BLOCK="$(sed -n '/^# firewall-mode: begin$/,/^# firewall-mode: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# firewall-mode: begin' .. '# firewall-mode: end' block, so this measured nothing about the installer's half"
elif ! printf '%s' "$BLOCK" | grep -q '^firewall_valid()' || ! printf '%s' "$BLOCK" | grep -q '^firewall_resolve()' || ! printf '%s' "$BLOCK" | grep -q '^firewall_apply()'; then
  fail "the firewall-mode block defines no firewall_resolve, firewall_apply or firewall_valid, so this measured nothing"
elif ! grep -q '^firewall_resolve$' install.sh || ! grep -q '^firewall_apply$' install.sh; then
  fail "install.sh never calls firewall_resolve and firewall_apply, so the block is dead text"
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
        firewall_resolve
        firewall_apply
        printf "set=%s\n" "$FIREWALL_SET"'
      printf 'rc=%s\n' "$?"
    ) 2>&1
  }
  rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
  lines_of() { grep -c "^TOKENFUSE_FIREWALL=" "$1/.env" || true; }

  # 1. nothing set: nothing written, the default box is untouched.
  d="$(mk)"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] || fail "nothing set: it was refused: $out"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "nothing set: .env was changed, so a default box would carry a line it never asked for"

  # 2. each usable mode is written, and the line is the one the gateway reads.
  for v in enforce shadow off; do
    d="$(mk)"
    out="$(run "$d" TOKENFUSE_FIREWALL="$v")"
    [ "$(rc_of "$out")" = 0 ] || fail "TOKENFUSE_FIREWALL=$v was refused and is a usable mode: $out"
    grep -qx "TOKENFUSE_FIREWALL=$v" "$d/.env" || fail "TOKENFUSE_FIREWALL=$v did not reach .env"
    [ "$(head -1 "$d/.env")" = "SENTINEL=1" ] || fail "TOKENFUSE_FIREWALL=$v disturbed the rest of .env"
  done

  # 3. a later figure REPLACES the earlier one, and a re-run that says nothing keeps it.
  d="$(mk)"
  run "$d" TOKENFUSE_FIREWALL=shadow >/dev/null
  out="$(run "$d" TOKENFUSE_FIREWALL=enforce)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(lines_of "$d")" = 1 ] && grep -qx 'TOKENFUSE_FIREWALL=enforce' "$d/.env" \
    || fail "a second mode did not replace the first (lines: $(lines_of "$d")): $out"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] && grep -qx 'TOKENFUSE_FIREWALL=enforce' "$d/.env" \
    || fail "a re-run with nothing set lost the mode an earlier run wrote: $out"

  # 4. every other value refuses, names the variable, touches nothing, echoes nothing.
  refuses() { # label value
    local label="$1" v="$2" d out
    d="$(mk)"
    out="$(run "$d" TOKENFUSE_FIREWALL="$v")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "TOKENFUSE_FIREWALL ($label) was accepted, and tokenfuse would refuse to start on it"
    elif ! printf '%s' "$out" | grep -qF 'TOKENFUSE_FIREWALL'; then
      fail "TOKENFUSE_FIREWALL ($label) was refused without naming the variable"
    elif [ "$(cat "$d/.env")" != "SENTINEL=1" ]; then
      fail "TOKENFUSE_FIREWALL ($label) was refused AFTER touching .env, which is half a job"
    fi
    # Only a value long enough not to occur in the refusal's own wording
    # ("enforce, shadow or off"): a short one would "echo" by coincidence.
    if [ "${#v}" -ge 7 ] && printf '%s' "$out" | grep -qF -- "$v"; then
      fail "TOKENFUSE_FIREWALL ($label) was refused by an answer that echoed the value"
    fi
  }
  refuses "capitalised" ENFORCE
  refuses "a misspelling" enforced
  refuses "a near word" enforcement
  refuses "a word that is not a mode" shadowed
  refuses "on, which is not a mode" on
  refuses "a number" 1
  refuses "a list" "shadow,off"
  refuses "a shell metacharacter" 'shadow;touch pwned-by-firewall'
  refuses "a command substitution" '$(touch pwned-by-firewall)'
  [ ! -e "$scratch/pwned-by-firewall" ] || fail "a command substitution in the value was executed"

  # 5. a bad mode already in .env is a gateway that runs the wrong mode.
  d="$(mk)"
  printf 'TOKENFUSE_FIREWALL=shadowed\n' >>"$d/.env"
  before="$(cat "$d/.env")"
  out="$(run "$d")"
  if [ "$(rc_of "$out")" = 0 ]; then
    fail "a TOKENFUSE_FIREWALL=shadowed left in .env was accepted: the gateway would refuse to start"
  elif [ "$(cat "$d/.env")" != "$before" ]; then
    fail "a bad mode in .env was refused after .env was changed"
  fi
  d="$(mk)"
  printf "TOKENFUSE_FIREWALL='shadow'\n" >>"$d/.env"
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] || fail "a quoted, usable mode in .env was refused: $out"
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
  # Every gateway, read back from the resolved configuration with the OpenAI
  # door's profile on (CLAUDE.md invariant 32): "service=value" for each service
  # that runs the tokenfuse gateway image with no subcommand. Compared with the
  # gateways section A derived from compose.yaml, so a gateway the resolved read
  # does not hold is a failure, not a smaller subject.
  values_of() { # KEY; extra .env lines on stdin
    cat "$cdir/base.env" - >"$cdir/.env"
    env -u TOKENFUSE_FIREWALL docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" --profile openai-door config --format json 2>"$cdir/err" |
      python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]
for n in sorted(s):
    v = s[n]
    if str(v.get("image", "")).startswith("ghcr.io/taipanbox/tokenfuse:") and v.get("command") == ["/usr/local/bin/tokenfuse"]:
        print("%s=%s" % (n, (v.get("environment") or {}).get(sys.argv[1], "")))
' "$1" 2>>"$cdir/err"
  }
  want_all() { [ -n "$gateways" ] && sed "s/\$/=$1/" <<<"$gateways"; }
  gateways="$(cat "$gwlist")"
  got="$(values_of TOKENFUSE_FIREWALL </dev/null)"
  [ "$got" = "$(want_all enforce)" ] || fail "resolved: a default box's gateways read '$(tr '\n' ' ' <<<"$got")', not enforce on each of $(tr '\n' ' ' <<<"$gateways")($(head -1 "$cdir/err"))"
  got="$(values_of TOKENFUSE_FIREWALL <<<"TOKENFUSE_FIREWALL=shadow")"
  [ "$got" = "$(want_all shadow)" ] || fail "resolved: a box whose .env sets shadow reads '$(tr '\n' ' ' <<<"$got")', so the switch does not move every gateway"
  got="$(values_of TOKENFUSE_FIREWALL <<<"TOKENFUSE_FIREWALL=off")"
  [ "$got" = "$(want_all off)" ] || fail "resolved: a box whose .env sets off reads '$(tr '\n' ' ' <<<"$got")', so the switch does not move every gateway"
  rm -rf "$cdir"
fi
rm -f "$gwlist"

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 27."
  exit 1
fi
echo "OK: every gateway definition sets TOKENFUSE_FIREWALL to enforce by default, the installer writes only"
echo "    the mode it was given, replaces rather than repeats, and refuses every value tokenfuse does not accept,"
echo "    before touching .env and without echoing it; the resolved configuration reads enforce, shadow, off."
