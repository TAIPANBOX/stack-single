#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 57: CostCrew's runner (costcrew-run) is the only
# part of the add-on that spends, and it spends only through this box's gateway, with
# the crew's own client key, under a ceiling an operator chose. It is not started by
# any install, and its default ceiling is 0, which spends nothing.
#
# WHY THIS SHAPE. The console cannot spend (invariant 24) and the runner can. The
# runner is the one place a model call leaves the box, so each of its properties is
# checked where it is set: in the resolved compose configuration (the profile, the
# network, the gateway, the key, the ceiling, the command), in install.sh (the
# ceiling's validation, the minted key and its binding), and by running the ceiling
# functions on values a person could type.
#
# WHAT IT CHECKS
#
#   A. COMPOSE, RESOLVED. No runner in the default rendering, nor in --profile finops
#      alone. With --profile finops --profile crew: exactly one runner, running the
#      costcrew-run binary with -due and -gateway http://tokenfuse-gateway:4100; its
#      ceiling is ${COSTCREW_CEILING:-0} (0 with nothing set, 25.00 when set); no -live,
#      no -supervise; on the `agents` network and no other; no published port; a
#      read-only root; all capabilities dropped; no volume but its events stream and
#      its data; the console's image; and, in its environment, the crew's client key
#      and nothing that names a provider key.
#   B. THE CONSOLE CANNOT SPEND. The console (the other costcrew service) carries no
#      -gateway or -gateway-openai flag.
#   C. INSTALL.SH, STATIC. The `# costcrew-runner:` block defines the ceiling's three
#      functions; install.sh validates the ceiling before the first package install;
#      the identity-mint block mints GATEWAY_COSTCREW_KEY and binds it to
#      agent://<domain>/costcrew/* in unit costcrew.
#   D. INSTALL.SH, BEHAVIOUR. The block is lifted and run in a scratch directory: a
#      ceiling a person could type is accepted only when it is a decimal dollar figure
#      with at most two places, zero included; the default is written as 0; a saved
#      value that is not a figure is refused before anything is written.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no compose.yaml, no docker, no runner, no
# block or no functions are each reported and fail.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
  echo "costcrew-runner-spends-through-the-gateway: no compose.yaml or install.sh, so nothing was measured"
  exit 1
fi

# ---- A. compose, resolved ------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d)"
  trap 'rm -rf "$cdir"' EXIT
  cp compose.yaml "$cdir/compose.yaml"
  {
    grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/'
    echo "GATEWAY_COSTCREW_KEY=fake-costcrew-client-key-0123456789"
  } >"$cdir/base.env"
  render() { # OUT EXTRA-ENV-LINE PROFILE...
    local out="$1" extra="$2"
    shift 2
    { cat "$cdir/base.env"; [ -z "$extra" ] || printf '%s\n' "$extra"; } >"$cdir/.env"
    docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" "$@" config --format json >"$out" 2>"$cdir/err" \
      || { fail "docker compose config failed: $(head -2 "$cdir/err" | tr '\n' ' ')"; return 1; }
  }
  render "$cdir/default.json" "" || true
  render "$cdir/finops.json" "" --profile finops || true
  render "$cdir/runner.json" "" --profile finops --profile crew || true
  render "$cdir/cadence.json" "COSTCREW_CEILING=25.00" --profile finops --profile crew || true
  if [ -s "$cdir/runner.json" ] && [ -s "$cdir/default.json" ] && [ -s "$cdir/finops.json" ] && [ -s "$cdir/cadence.json" ]; then
    python3 - "$cdir/default.json" "$cdir/finops.json" "$cdir/runner.json" "$cdir/cadence.json" <<'PY' || problems=$((problems + 1))
import json
import sys

default, finops, runner, cadence = (json.load(open(p))["services"] for p in sys.argv[1:5])
problems = []
if any("costcrew-run" in s for s in default):
    problems.append("A1. the default rendering contains the runner: a plain `docker compose up` would start it")
if any("costcrew-run" in s for s in finops):
    problems.append("A1. --profile finops renders the runner: it is started by `crew`, not by the add-on's profile")
if "costcrew-run" not in runner:
    problems.append("A1. --profile finops --profile crew renders no costcrew-run, so this gate measured NOTHING about the runner")
else:
    r = runner["costcrew-run"]
    cmd = [str(x) for x in r.get("command") or []]
    if r.get("entrypoint") != ["/usr/local/bin/costcrew-run"]:
        problems.append("A2. the runner's entrypoint is %r, not the costcrew-run binary" % (r.get("entrypoint"),))
    if "-due" not in cmd:
        problems.append("A2. the runner does not pass -due, so it would run work that cadence did not mark due")
    for bad in ("-live", "-supervise", "-prices", "-only"):
        if bad in cmd:
            problems.append("A2. the runner passes %s, which is not the cadence-due run" % bad)
    flag = {cmd[i]: cmd[i + 1] for i in range(len(cmd) - 1) if cmd[i].startswith("-") and not cmd[i + 1].startswith("-")}
    if flag.get("-gateway") != "http://tokenfuse-gateway:4100":
        problems.append("A3. the runner's -gateway is %r, not http://tokenfuse-gateway:4100: its model calls would leave the box" % flag.get("-gateway"))
    if "-stack-events" in cmd:
        problems.append("A2. the runner writes an events stream: the console is the one writer of costcrew.ndjson (invariant 41), and a second writer forks its chain")
    if flag.get("-ceiling") != "0":
        problems.append("A4. with COSTCREW_CEILING unset the runner's ceiling is %r, not 0: the default must spend nothing" % flag.get("-ceiling"))
    if cadence["costcrew-run"]["command"][cmd.index("-ceiling") + 1] != "25.00" if "-ceiling" in cmd else True:
        problems.append("A4. with COSTCREW_CEILING=25.00 the runner's ceiling is not 25.00")
    nets = set((r.get("networks") or {}).keys())
    if nets != {"agents"}:
        problems.append("A5. the runner is on %s, it must be on agents and nothing else (invariant 38: no route out)" % sorted(nets))
    if r.get("ports"):
        problems.append("A5. the runner publishes a port: %r" % (r.get("ports"),))
    if r.get("read_only") is not True:
        problems.append("A5. the runner's root filesystem is writable")
    if "ALL" not in [str(c) for c in (r.get("cap_drop") or [])]:
        problems.append("A5. the runner does not drop all capabilities")
    if str(r.get("user")) != "10003:10003":
        problems.append("A5. the runner runs as %r, not the console's account 10003:10003" % r.get("user"))
    mounts = sorted(str(v.get("source")) for v in r.get("volumes") or [] if isinstance(v, dict))
    if mounts != ["costcrewdata"]:
        problems.append("A5. the runner mounts %s: it may mount only its costcrew store, and no bus volume" % mounts)
    env = r.get("environment") or {}
    if env.get("ANTHROPIC_API_KEY") != "fake-costcrew-client-key-0123456789":
        problems.append("A6. the runner's ANTHROPIC_API_KEY is not the crew's client key (GATEWAY_COSTCREW_KEY)")
    for k in env:
        if k != "ANTHROPIC_API_KEY" and any(w in k.upper() for w in ("KEY", "TOKEN", "SECRET", "OPENROUTER", "OPENAI")):
            problems.append("A6. the runner's environment names %s, a credential it must not hold" % k)
    if not str(r.get("image", "")).startswith("ghcr.io/taipanbox/costcrew:v0.10.0@sha256:"):
        problems.append("A7. the runner's image is %r, not the pinned costcrew v0.10.0" % r.get("image"))
    gw_nets = set((default.get("tokenfuse-gateway", {}).get("networks") or {}).keys())
    if "agents" not in gw_nets and "tokenfuse-gateway" in default:
        problems.append("A5. the gateway is not on agents, so the runner cannot reach it")
con = runner.get("costcrew") or {}
ccmd = [str(x) for x in con.get("command") or []]
for bad in ("-gateway", "-gateway-openai"):
    if bad in ccmd:
        problems.append("B. the console carries %s: the console would be able to spend, which invariant 24 forbids" % bad)
for p in problems:
    print("FAIL: " + p)
sys.exit(1 if problems else 0)
PY
  fi
fi

# ---- C. install.sh, static -----------------------------------------------------
BLOCK="$(sed -n '/^# costcrew-runner: begin$/,/^# costcrew-runner: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "C. install.sh has no '# costcrew-runner: begin' .. '# costcrew-runner: end' block, so the ceiling was not measured"
else
  for fn in costcrew_ceiling_valid costcrew_ceiling_resolve costcrew_ceiling_apply; do
    printf '%s\n' "$BLOCK" | grep -q "^$fn()" || fail "C. the costcrew-runner block defines no $fn"
  done
  first_apt="$(grep -n 'apt-get install' install.sh | head -1 | cut -d: -f1)"
  resolve_at="$(grep -n '^costcrew_ceiling_resolve$' install.sh | head -1 | cut -d: -f1)"
  if [ -z "$resolve_at" ]; then
    fail "C. install.sh never calls costcrew_ceiling_resolve, so a bad COSTCREW_CEILING would not be refused before anything is installed"
  elif [ -n "$first_apt" ] && [ "$resolve_at" -ge "$first_apt" ]; then
    fail "C. costcrew_ceiling_resolve runs at line $resolve_at, after the first package install at line $first_apt"
  fi
fi
MINT="$(sed -n '/^# identity-mint: begin$/,/^# identity-mint: end$/p' install.sh)"
printf '%s\n' "$MINT" | grep -q 'mint_env_secret GATEWAY_COSTCREW_KEY' \
  || fail "C. the identity-mint block does not mint GATEWAY_COSTCREW_KEY, so the runner would hold no client key"
printf '%s\n' "$MINT" | grep -q '"key_id": "costcrew", "unit": "costcrew", "agents": \["agent://%s/costcrew/\*"\]' \
  || fail "C. the minted map does not bind the crew's key to agent://<domain>/costcrew/* in unit costcrew"
# The key exists only when a run may spend (invariant 57): the ceiling test is one line, and the
# key is dropped on a zero ceiling, so no unused credential is ever accepted.
CEIL_LINE='case "${COSTCREW_CEILING_SET:-0}" in *[1-9]*) costcrew_on=1 ;; esac'
printf '%s\n' "$MINT" | grep -qF "$CEIL_LINE" \
  || fail "C. the identity-mint block does not mint the CostCrew key only when the ceiling is above 0 (the ceiling test is missing or changed)"
printf '%s\n' "$MINT" | grep -qF 'mint_env_forget GATEWAY_COSTCREW_KEY' \
  || fail "C. the identity-mint block does not drop GATEWAY_COSTCREW_KEY on a zero ceiling, so an unused credential would be accepted"
for v in 0 0.00 25.00; do
  got="$(bash -c "costcrew_on=0; COSTCREW_CEILING_SET='$v'; $CEIL_LINE; echo \$costcrew_on")"
  want=1; [ "$v" = 0 ] || [ "$v" = 0.00 ] && want=0
  [ "$got" = "$want" ] || fail "C. the ceiling test gives $got for a ceiling of $v, want $want"
done
got="$(bash -c "costcrew_on=0; unset COSTCREW_CEILING_SET; $CEIL_LINE; echo \$costcrew_on")"
[ "$got" = 0 ] || fail "C. the ceiling test gives $got with no ceiling set, want 0 (no spend)"

# ---- D. install.sh, behaviour ---------------------------------------------------
if [ -n "$BLOCK" ]; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "${cdir:-}" "$scratch"' EXIT
  printf '%s\n' "$BLOCK" >"$scratch/block.sh"
  valid() { bash -c 'source "$1"; costcrew_ceiling_valid "$2"' _ "$scratch/block.sh" "$1"; }
  for ok in 0 25 25.00 25.5; do
    valid "$ok" || fail "D. the ceiling $ok is refused, and a decimal dollar figure must be accepted"
  done
  for bad in 25.005 -1 1e3 abc 1,00 "25 00"; do
    if valid "$bad"; then fail "D. the ceiling '$bad' is accepted; it must be refused (a sign, an exponent, a comma, a third decimal, or a word)"; fi
  done
  mkdir -p "$scratch/box"
  printf 'SENTINEL=1\n' >"$scratch/box/.env"
  run_resolve_apply() { # EXTRA-ENV: runs resolve and apply in the box, prints the value written
    env -i PATH="$PATH" STACK_DIR="$scratch/box" COSTCREW_CEILING="${1:-}" bash -c '
      set -uo pipefail
      die() { printf "die: %s\n" "$*"; exit 1; }
      note() { :; }
      source "$1"
      costcrew_ceiling_resolve
      costcrew_ceiling_apply' _ "$scratch/block.sh" 2>&1
  }
  out="$(run_resolve_apply "")" || true
  grep -qx 'COSTCREW_CEILING=0' "$scratch/box/.env" || fail "D. a box that names no ceiling does not get COSTCREW_CEILING=0 written: $out"
  out="$(run_resolve_apply "25.00")" || true
  grep -qx 'COSTCREW_CEILING=25.00' "$scratch/box/.env" || fail "D. COSTCREW_CEILING=25.00 is not written: $out"
  before="$(cat "$scratch/box/.env")"
  out="$(run_resolve_apply "25.005")" || true
  printf '%s' "$out" | grep -q '^die: ' || fail "D. COSTCREW_CEILING=25.005 was not refused: $out"
  [ "$(cat "$scratch/box/.env")" = "$before" ] || fail "D. a refused COSTCREW_CEILING changed .env"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 57."
  exit 1
fi
echo "OK: CostCrew's runner is off unless started by hand (profile crew), spends only through the gateway with the crew's own client key, holds no provider key, runs with a ceiling that defaults to 0, and the console still cannot spend (invariant 57)."
