#!/usr/bin/env bash
#
# Enforces invariant 22 of CLAUDE.md: the typed risk signal is off unless the
# operator asks, is refused when typed answers are off, reaches only the MCP
# broker's policy client, and runs behind a network that holds nobody else.
#
# WHAT THIS IS ABOUT
#
# wardryx 1.2.0 can hold a tool call for a person when a typed signal about it
# says so (`hold_if_signal`), and typryx 0.4.0 ships the proxy that adds the
# signal (`typryx wardryx-proxy`, asking `action.risk_class`). This launcher
# wires them only on request: TYPED_RISK_SIGNAL=1, with typed answers on.
#
# Three things about that wiring are quiet when wrong, and this holds each:
#
#   THE PROXY HAS NO CREDENTIAL, so the network is its credential. The broker
#   cannot send an X-Typryx-Key to wardryx's decide route, so the proxy runs
#   with TYPRYX_ALLOW_OPEN_BIND=1 and no TYPRYX_KEYS. Anything that reaches it
#   can spend this box's ask budget, so it must be on a network of its own
#   (`risk-signal`) holding only the proxy, the broker and wardryx, publish no
#   port, and never join `default`. One line moving it onto `default` leaves
#   everything working and opens it to every container on the box.
#
#   ONLY THE BROKER IS POINTED AT IT. The LLM gateway keeps asking wardryx
#   directly: a model call has no pending tool call to classify, and the
#   proxy's ask would put typryx's latency in front of a path with a 250 ms
#   deadline (J2-DESIGN). Pointing the gateway at the proxy too would work in a
#   demo and refuse real calls under load.
#
#   ONE RULE IS SEEDED, AND ONLY WITH THE FLAG. A tool call that arrives with no
#   signal is held for a person, and so is one the classifier marks destructive,
#   external_send or financial at 0.8 or more (`when_absent: hold`, invariant 54,
#   the rule stack-up seeds). A read_only or reversible_change answer holds
#   nothing. Any other class or threshold is the operator's own `hold_if_signal`
#   rule, written from the README example.
#
# WHAT THIS CHECKS
#
#   A. BEHAVIOUR. The functions between `# typed-mode: begin` and `end` are
#      lifted out and run in a scratch STACK_DIR: nothing set writes nothing; the
#      flag with typed answers off refuses (naming what to set) before touching
#      the box; with the stub, jev or own-model it writes exactly three lines;
#      a re-run changes nothing; a change of mode keeps it; `0` removes those
#      three lines and only them; a value that is neither 1 nor 0 refuses; a
#      saved flag does nothing while typed answers are off.
#   B. COMPOSE, resolved: without the flag no proxy exists and the broker's
#      policy client asks wardryx directly (invariant 36); with it the proxy, its network, its lack of a port
#      and of a key, the broker's URL and the gateway's untouched URL are each
#      what is said above, and the network has exactly three members.
#   C. STATIC. install.sh passes `--profile typed-risk-signal` only on a line
#      TYPED_PLANE decides and only with the flag on; the starter policy.yaml
#      heredoc carries no hold_if_signal; the README shows one.
#   E. THE SEEDED HOLD. The `# typed-risk-policy:` block is lifted and run in
#      scratch boxes: nothing is seeded with the flag off; with it on, one
#      managed rule holds a call with no signal and the three high-risk classes
#      at 0.8, and no other class; a re-run changes no byte; turning the flag
#      off removes that rule and only that rule, and an operator's own lines
#      survive both ways.
#   D. THE PINS the feature needs: typryx >= 0.4.0 (the proxy), wardryx >= 1.2.0
#      (reads signals), wardryx >= 1.4.0 (when_absent: hold, which the README
#      example uses to hold a call no signal answered), tokenfuse >= 1.5.0 (sends
#      the tool call). An older pin
#      does not fail, it silently adds no signal.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No block, no functions, no proxy service in the resolved configuration, no
# --profile line, or no Docker: each is reported and fails.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

FAKEKEY="tj_test_FAKE_not_a_real_key_9f3a1c77d20b"

# ---- A. behaviour ------------------------------------------------------------
BLOCK="$(sed -n '/^# typed-mode: begin$/,/^# typed-mode: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# typed-mode: begin' .. '# typed-mode: end' block, so this measured nothing about the risk signal"
elif ! printf '%s' "$BLOCK" | grep -q '^typed_resolve()' || ! printf '%s' "$BLOCK" | grep -q '^typed_apply()'; then
  fail "the typed-mode block defines no typed_resolve or no typed_apply, so this measured nothing"
elif ! printf '%s' "$BLOCK" | grep -q 'TYPED_RISK_SIGNAL'; then
  fail "the typed-mode block never reads TYPED_RISK_SIGNAL, so there is no flag to check"
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  mk() {
    local d
    d="$(mktemp -d "$scratch/box.XXXXXX")"
    printf 'SENTINEL=1\n' >"$d/.env"
    chmod 600 "$d/.env"
    printf '%s' "$d"
  }
  run() {
    local d="$1"
    shift
    (
      cd "$d" || exit 99
      env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" "$@" bash -c '
        set -euo pipefail
        say() { :; }
        note() { printf "note: %s\n" "$*"; }
        die() { printf "die: %s\n" "$*"; exit 1; }
        chown() { :; }
        eval "$BLOCK"
        typed_resolve
        typed_apply
        printf "plane=%s\nrisk=%s\n" "$TYPED_PLANE" "$TYPED_RISK_ON"'
      printf 'rc=%s\n' "$?"
    ) 2>&1
  }
  rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
  risk_of() { printf '%s' "$1" | sed -n 's/^risk=//p'; }
  riskenv() { grep -c "^TYPED_RISK_" "$1/.env" || true; }
  printf '%s\n' "$FAKEKEY" >"$scratch/jev.key"

  # 1. off unless asked: no line, whatever the typed mode.
  for args in "" "WITH_TYPED=1" "TYPED_MODE=own-model TYPED_MODEL_URL=http://h:8000/v1 TYPED_MODEL_NAME=m"; do
    d="$(mk)"
    # shellcheck disable=SC2086
    out="$(run "$d" $args)"
    [ "$(rc_of "$out")" = 0 ] || fail "[$args] without the flag was refused: $out"
    [ "$(riskenv "$d")" = 0 ] || fail "[$args] without TYPED_RISK_SIGNAL wrote a TYPED_RISK_ line, so the signal would be on by default"
    [ "$(risk_of "$out")" = 0 ] || fail "[$args] without the flag, the run reports the proxy on"
  done

  # 2. the flag with typed answers off refuses, names what to set, touches nothing.
  refuses() { # label needle VAR=...
    local label="$1" needle="$2" d out
    shift 2
    d="$(mk)"
    out="$(run "$d" "$@")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "$label: it was accepted, and it must refuse"
    elif ! printf '%s' "$out" | grep -qF -- "$needle"; then
      fail "$label: it refused, but not saying '$needle'"
    elif [ "$(cat "$d/.env")" != "SENTINEL=1" ] || [ -e "$d/typed" ]; then
      fail "$label: it refused AFTER touching the box (.env or typed/ changed), which is half a job"
    fi
  }
  refuses "the flag with typed answers off (nothing set)" "WITH_TYPED=1" TYPED_RISK_SIGNAL=1
  refuses "the flag with TYPED_MODE=off" "typed answers are off" TYPED_RISK_SIGNAL=1 TYPED_MODE=off
  refuses "the flag with TYPED_MODE=off and WITH_TYPED=1" "typed answers are off" TYPED_RISK_SIGNAL=1 TYPED_MODE=off WITH_TYPED=1
  refuses "TYPED_RISK_SIGNAL=yes" "TYPED_RISK_SIGNAL must be" WITH_TYPED=1 TYPED_RISK_SIGNAL=yes
  refuses "TYPED_RISK_SIGNAL=2" "TYPED_RISK_SIGNAL must be" WITH_TYPED=1 TYPED_RISK_SIGNAL=2

  # 3. on: three lines, for each mode that has a typryx.
  for case in "stub|WITH_TYPED=1" "jev|TYPED_MODE=jev TYPED_JEV_KEY_FILE=$scratch/jev.key" "own-model|TYPED_MODE=own-model TYPED_MODEL_URL=http://h:8000/v1 TYPED_MODEL_NAME=m"; do
    label="${case%%|*}"
    args="${case#*|}"
    d="$(mk)"
    # shellcheck disable=SC2086
    out="$(run "$d" $args TYPED_RISK_SIGNAL=1)"
    [ "$(rc_of "$out")" = 0 ] || { fail "$label with the flag was refused: $out"; continue; }
    [ "$(risk_of "$out")" = 1 ] || fail "$label with the flag: the run does not report the proxy on"
    grep -qx "TYPED_RISK_SIGNAL='1'" "$d/.env" || fail "$label: TYPED_RISK_SIGNAL is not saved in .env"
    grep -qx "TYPED_RISK_WARDRYX_MODE='enforce'" "$d/.env" || fail "$label: the broker's policy client is not set to enforce"
    grep -qx "TYPED_RISK_WARDRYX_URL='http://typryx-wardryx-proxy:4330'" "$d/.env" || fail "$label: the broker's policy client does not point at the proxy"
    [ "$(riskenv "$d")" = 3 ] || fail "$label: the flag wrote $(riskenv "$d") TYPED_RISK_ lines, not three"
    printf '%s' "$out" | grep -q 'hold_if_signal' || fail "$label: the run does not say that nothing seeds a hold_if_signal policy"
    if grep -qF -- "$FAKEKEY" "$d/.env"; then fail "$label: the key's bytes are in .env"; fi
    before="$(cat "$d/.env")"
    # A re-run says nothing about the flag, and nothing about the mode either: all
    # three planes are remembered in .env, the stub included (TYPED_MODE=stub).
    out="$(run "$d")"
    [ "$(rc_of "$out")" = 0 ] && [ "$(cat "$d/.env")" = "$before" ] && [ "$(risk_of "$out")" = 1 ] \
      || fail "$label: a re-run with nothing set changed the box or turned the signal off: $out"
  done

  # 4. it is the operator's own choice: a mode change keeps it, 0 turns it off, only it.
  d="$(mk)"
  run "$d" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/jev.key" TYPED_RISK_SIGNAL=1 >/dev/null
  out="$(run "$d" TYPED_MODE=own-model TYPED_MODEL_URL=http://h:8000/v1 TYPED_MODEL_NAME=m)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(riskenv "$d")" = 3 ] && [ "$(risk_of "$out")" = 1 ] \
    || fail "switching mode lost the signal the operator asked for: $out"
  grep -q "^TYPRYX_BACKEND='openai-logprobs'" "$d/.env" || fail "switching mode did not apply the new mode"
  out="$(run "$d" TYPED_RISK_SIGNAL=0)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(riskenv "$d")" = 0 ] && [ "$(risk_of "$out")" = 0 ] \
    || fail "TYPED_RISK_SIGNAL=0 did not remove the three lines: $out"
  grep -q "^TYPRYX_BACKEND='openai-logprobs'" "$d/.env" || fail "TYPED_RISK_SIGNAL=0 removed the mode's own lines"
  grep -qx "SENTINEL=1" "$d/.env" || fail "TYPED_RISK_SIGNAL=0 removed lines it does not own"

  # 5. a saved flag does nothing while typed answers are off.
  d="$(mk)"
  run "$d" WITH_TYPED=1 TYPED_RISK_SIGNAL=1 >/dev/null
  out="$(run "$d" TYPED_MODE=off)"
  [ "$(rc_of "$out")" = 0 ] || fail "turning typed answers off over a saved signal was refused: $out"
  [ "$(risk_of "$out")" = 0 ] || fail "a saved signal still reports the proxy on after typed answers were turned off"
fi

# ---- D. the pins the feature needs ---------------------------------------------
ver() { sed -n "s/.*ghcr\.io\/taipanbox\/$1:v\([0-9][0-9.]*\)[^0-9.-].*/\1/p" compose.yaml | head -1; }
atleast() { # have want: dotted versions
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}
for pair in "typryx 0.4.0 the proxy (wardryx-proxy) does not exist before it" \
            "wardryx 1.2.0 hold_if_signal and signals on /v1/decide do not exist before it" \
            "wardryx 1.4.0 when_absent: hold, the missing-signal hold the README example shows, does not exist before it" \
            "tokenfuse 1.5.0 the broker sends no tool_call to the policy plane before it"; do
  # shellcheck disable=SC2086
  set -- $pair
  name="$1"
  want="$2"
  shift 2
  have="$(ver "$name")"
  if [ -z "$have" ]; then
    fail "compose.yaml names no ghcr.io/taipanbox/$name:vX.Y.Z image, so this measured nothing about its pin"
  elif ! atleast "$have" "$want"; then
    fail "compose.yaml pins $name at v$have, and the typed risk signal needs v$want or later: $*"
  fi
done

# ---- C. static ------------------------------------------------------------------
hits="$(grep -n -- '--profile typed-risk-signal' install.sh | grep -v '^[0-9]*:[[:space:]]*#' || true)"
if [ -z "$hits" ]; then
  fail "install.sh never passes --profile typed-risk-signal, so this measured nothing about how it is gated"
else
  while IFS= read -r l; do
    case "$l" in
      *TYPED_PLANE*TYPED_RISK_ON*) ;;
      *) fail "install.sh:${l%%:*} passes --profile typed-risk-signal on a line that is not decided by both TYPED_PLANE and TYPED_RISK_ON: ${l#*:}" ;;
    esac
  done <<<"$hits"
fi
seeded="$(sed -n "/cat > policy.yaml <<'EOF'/,/^EOF\$/p" install.sh)"
if [ -z "$seeded" ]; then
  fail "install.sh seeds no policy.yaml heredoc, so this measured nothing about what it seeds"
elif printf '%s' "$seeded" | grep -q 'hold_if_signal'; then
  fail "install.sh seeds a hold_if_signal policy: a classifier would hold tool calls on a box whose operator never chose that"
fi
grep -q 'hold_if_signal' README.md || fail "README.md shows no hold_if_signal example, and the signal does nothing until the operator writes one"
grep -q 'when_absent: hold' README.md || fail "README.md shows no when_absent: hold on its example, so a tool call that arrives with no signal passes"

# ---- E. the seeded hold (invariant 54) ----------------------------------------
# With the flag on, policy.yaml carries one managed rule that holds a tool call
# with no risk signal (wardryx 1.4.0's `when_absent: hold`); with it off, none.
# The block is lifted and run in scratch boxes; the rule is read back as text.
PBLOCK="$(sed -n '/^# typed-risk-policy: begin$/,/^# typed-risk-policy: end$/p' install.sh)"
if [ -z "$PBLOCK" ]; then
  fail "install.sh has no '# typed-risk-policy: begin' .. '# typed-risk-policy: end' block, so the seeded hold was not measured"
elif ! printf '%s' "$PBLOCK" | grep -q '^typed_risk_policy_apply()' || ! printf '%s' "$PBLOCK" | grep -q '^typed_risk_policy_block()'; then
  fail "the typed-risk-policy block defines no typed_risk_policy_apply or no typed_risk_policy_block, so the seeded hold was not measured"
else
  escratch="$(mktemp -d)"
  trap 'rm -rf "${scratch:-}" "$escratch"' EXIT
  STARTER="$(sed -n "/cat > policy.yaml <<'EOF'/,/^EOF\$/p" install.sh | sed '1d;$d')"
  if [ -z "$STARTER" ]; then
    fail "install.sh has no starter policy.yaml heredoc, so the seeded hold has nothing to be written into"
  fi
  erun() { # DIR ARGS...: resolve the flag, then apply the policy block, in DIR
    local d="$1"
    shift
    (
      cd "$d" || exit 99
      env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" PBLOCK="$PBLOCK" "$@" bash -c '
        set -euo pipefail
        say() { :; }
        note() { :; }
        die() { printf "die: %s\n" "$*"; exit 1; }
        chown() { :; }
        eval "$BLOCK"
        eval "$PBLOCK"
        typed_resolve
        typed_apply
        typed_risk_policy_apply
        printf "risk=%s changed=%s\n" "$TYPED_RISK_ON" "${TYPED_RISK_POLICY_CHANGED:-0}"'
      printf 'rc=%s\n' "$?"
    ) 2>&1
  }
  ebox() { # a fresh box holding the starter policy and one line of .env
    local d
    d="$(mktemp -d "$escratch/box.XXXXXX")"
    printf 'SENTINEL=1\n' >"$d/.env"
    printf '%s\n' "$STARTER" >"$d/policy.yaml"
    printf '%s' "$d"
  }
  starter_file="$escratch/starter.yaml"
  printf '%s\n' "$STARTER" >"$starter_file"

  # E1. flag off: the rule is not there, and the starter is untouched byte for byte.
  d="$(ebox)"
  out="$(erun "$d" WITH_TYPED=1)"
  [ "$(printf '%s' "$out" | sed -n 's/^rc=//p' | tail -1)" = 0 ] || fail "E1: a run with the flag off was refused: $out"
  cmp -s "$d/policy.yaml" "$starter_file" || fail "E1: with the flag off policy.yaml differs from the starter, so a rule was seeded without the flag"
  printf '%s' "$out" | grep -q 'changed=0' || fail "E1: with the flag off the run reports a policy change"

  # E2. flag on: exactly one managed rule, after the starter's rules: it holds a call with
  # no signal and the three high-risk classes at 0.8, and nothing else.
  d="$(ebox)"
  out="$(erun "$d" WITH_TYPED=1 TYPED_RISK_SIGNAL=1)"
  [ "$(printf '%s' "$out" | sed -n 's/^rc=//p' | tail -1)" = 0 ] || fail "E2: the flag on was refused: $out"
  printf '%s' "$out" | grep -q 'changed=1' || fail "E2: with the flag on the run does not report that policy.yaml changed"
  n="$(grep -c '^- name: typed-risk-hold-when-absent$' "$d/policy.yaml" || true)"
  [ "$n" = 1 ] || fail "E2: the flag on wrote $n typed-risk-hold-when-absent rules, not one"
  grep -q '^# typed-risk-hold: begin' "$d/policy.yaml" && grep -q '^# typed-risk-hold: end' "$d/policy.yaml" \
    || fail "E2: the managed rule has no begin and end marker, so a later run cannot find it"
  head -n "$(wc -l <"$starter_file")" "$d/policy.yaml" | cmp -s - "$starter_file" \
    || fail "E2: the starter rules changed, so the seeded rule is not an addition to them"
  block="$(sed -n '/^# typed-risk-hold: begin/,/^# typed-risk-hold: end/p' "$d/policy.yaml")"
  printf '%s\n' "$block" | grep -q '^  target: "agent://\*"$' || fail "E2: the seeded rule does not target every agent (agent://*)"
  printf '%s\n' "$block" | grep -q '^    name: action.risk_class$' || fail "E2: the seeded rule reads a signal other than action.risk_class"
  printf '%s\n' "$block" | grep -q '^    when_absent: hold$' || fail "E2: the seeded rule does not hold when the signal is absent"
  vals="$(printf '%s\n' "$block" | sed -n 's/^    values: \[\(.*\)\]$/\1/p')"
  [ -n "$vals" ] || fail "E2: the seeded rule has no values line in the form wardryx reads"
  vals_set="$(printf '%s' "$vals" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort | paste -sd, -)"
  [ "$vals_set" = "destructive,external_send,financial" ] \
    || fail "E2: the seeded rule holds on $vals; it must hold on destructive, external_send and financial, the classes stack-up's rule holds, and no other"
  printf '%s\n' "$block" | grep -q '^    min_probability: 0.8$' \
    || fail "E2: the seeded rule's min_probability is not 0.8, the threshold stack-up's rule uses"

  # E3. a re-run with the same answers changes no byte.
  before="$(cat "$d/policy.yaml")"
  out="$(erun "$d" WITH_TYPED=1 TYPED_RISK_SIGNAL=1)"
  [ "$(printf '%s' "$out" | sed -n 's/^rc=//p' | tail -1)" = 0 ] && [ "$(cat "$d/policy.yaml")" = "$before" ] \
    && printf '%s' "$out" | grep -q 'changed=0' \
    || fail "E3: a re-run with the flag on changed policy.yaml or reported a change: $out"

  # E4. the operator's own rule survives, and turning the flag off removes the managed rule only.
  printf -- '- name: operator-own-rule\n  target: "agent://ops.example/*"\n  deny_tool:\n    - drop_table\n' >>"$d/policy.yaml"
  out="$(erun "$d" WITH_TYPED=1 TYPED_RISK_SIGNAL=0)"
  [ "$(printf '%s' "$out" | sed -n 's/^rc=//p' | tail -1)" = 0 ] || fail "E4: turning the flag off was refused: $out"
  if grep -q 'typed-risk-hold' "$d/policy.yaml"; then fail "E4: turning the flag off left the managed rule in policy.yaml"; fi
  grep -q '^- name: operator-own-rule$' "$d/policy.yaml" || fail "E4: turning the flag off removed the operator's own rule"
  head -n "$(wc -l <"$starter_file")" "$d/policy.yaml" | cmp -s - "$starter_file" \
    || fail "E4: turning the flag off did not restore the starter rules"
  printf '%s' "$out" | grep -q 'changed=1' || fail "E4: turning the flag off does not report that policy.yaml changed"
fi

# ---- B. compose ------------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d)"
  cp compose.yaml "$cdir/compose.yaml"
  mkdir -p "$cdir/typed" "$cdir/delegation-public" "$cdir/environments"
  : >"$cdir/policy.yaml"
  printf '%s\n' "$FAKEKEY" >"$cdir/typed/jev-key"
  {
    grep -o '\${[A-Z_]*:?' compose.yaml | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/'
    echo "TYPRYX_KEYS=fake-door-key=agent://local.invalid/default-agent"
  } >"$cdir/base.env"
  check_cfg() { # name, python snippet, compose args; stdin = env lines
    local name="$1" snippet="$2" cfg
    shift 2
    cat "$cdir/base.env" - >"$cdir/.env"
    if ! cfg="$(docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" "$@" config --format json 2>"$cdir/err")"; then
      fail "compose: $name: docker compose config failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
      return
    fi
    if ! printf '%s' "$cfg" | FAKEKEY="$FAKEKEY" python3 -c "
import json, os, sys
cfg = json.load(sys.stdin)
raw = json.dumps(cfg)
svc = cfg['services']
nets = cfg.get('networks', {})
$snippet
" 2>"$cdir/pyerr"; then
      fail "compose: $name: $(tail -1 "$cdir/pyerr")"
    fi
  }

  # Without the flag the broker still asks the policy plane, directly: since
  # invariant 36 its hook is on by default. What the flag changes is where it asks.
  check_cfg "without the flag there is no proxy, and the broker asks wardryx directly" "
assert 'tokenfuse-mcp-broker' in svc, 'no broker in the resolved configuration with --profile typed, so this measured nothing'
assert 'typryx-wardryx-proxy' not in svc, 'the proxy is in the set without the typed-risk-signal profile'
e = svc['tokenfuse-mcp-broker']['environment']
assert e.get('TOKENFUSE_WARDRYX_URL') == 'http://wardryx:8090', 'without the flag the broker asks ' + repr(e.get('TOKENFUSE_WARDRYX_URL')) + ', not wardryx directly'
assert 'typryx-wardryx-proxy' not in json.dumps(e), 'the broker names the proxy without the flag'
" --profile typed </dev/null

  check_cfg "default set has no proxy and no broker" "
assert 'typryx-wardryx-proxy' not in svc, 'the proxy is in the default set'
assert 'tokenfuse-mcp-broker' not in svc, 'the broker is in the default set'
" </dev/null

  check_cfg "with the flag: the proxy sits where it must, and only the broker points at it" "
assert 'typryx-wardryx-proxy' in svc, 'no proxy in the resolved configuration with --profile typed-risk-signal, so this measured nothing'
p = svc['typryx-wardryx-proxy']
e = p['environment']
assert p['image'] == svc['typryx']['image'], 'the proxy is not the typryx image the typed plane pins: ' + p['image'] + ' vs ' + svc['typryx']['image']
assert p.get('command') == ['wardryx-proxy'], 'the proxy command is ' + repr(p.get('command'))
assert set(p.get('networks', {})) == {'risk-signal'}, 'the proxy is on ' + repr(sorted(p.get('networks', {}))) + ', it must be on risk-signal and nowhere else (an open proxy on default is reachable by every container)'
assert not p.get('ports'), 'the proxy publishes a port: ' + repr(p.get('ports'))
assert e.get('TYPRYX_ALLOW_OPEN_BIND') == '1', 'the proxy does not say it runs open on purpose'
assert not e.get('TYPRYX_KEYS'), 'the proxy has TYPRYX_KEYS, which would demand a header the broker cannot send'
assert e.get('TYPRYX_PROXY_UPSTREAM') == 'http://wardryx:8090', 'the proxy upstream is ' + repr(e.get('TYPRYX_PROXY_UPSTREAM'))
assert e.get('TYPRYX_PROXY_ADDR', '').endswith(':4330'), 'the proxy address is ' + repr(e.get('TYPRYX_PROXY_ADDR'))
assert not e.get('TYPRYX_EVENTS') and not e.get('TYPRYX_LEDGER_DIR') and not e.get('TYPRYX_TRAINING_DIR'), 'the proxy names a journal, ledger or training log: a second appender on typryx\'s files, and a bus file name the source rule would refuse'
assert p.get('read_only') is True, 'the proxy root filesystem is writable'
b = svc['tokenfuse-mcp-broker']['environment']
assert b['TOKENFUSE_WARDRYX_URL'] == 'http://typryx-wardryx-proxy:4330', 'the broker policy client points at ' + repr(b.get('TOKENFUSE_WARDRYX_URL'))
assert b['TOKENFUSE_WARDRYX_MODE'] == 'enforce', 'the broker mode is ' + repr(b.get('TOKENFUSE_WARDRYX_MODE'))
assert b['TOKENFUSE_WARDRYX_FAILMODE'] == 'closed', 'the broker fails open: ' + repr(b.get('TOKENFUSE_WARDRYX_FAILMODE'))
assert int(b['TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS']) >= 5500, 'the broker decide deadline is shorter than the proxy\\'s longest ask: ' + b['TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS']
assert svc['tokenfuse-gateway']['environment']['TOKENFUSE_WARDRYX_URL'] == 'http://wardryx:8090', 'the LLM gateway no longer asks wardryx directly'
# nobody else reaches for the proxy, and nobody else is open-bind
for name, s in svc.items():
    if name in ('typryx-wardryx-proxy', 'tokenfuse-mcp-broker'):
        continue
    assert 'typryx-wardryx-proxy' not in json.dumps(s), name + ' names the proxy'
    assert 'TYPRYX_ALLOW_OPEN_BIND' not in s.get('environment', {}), name + ' runs open'
# the risk-signal network holds exactly the proxy, the broker and wardryx
members = sorted(n for n, s in svc.items() if 'risk-signal' in s.get('networks', {}))
assert members == ['tokenfuse-mcp-broker', 'typryx-wardryx-proxy', 'wardryx'], 'the risk-signal network has members ' + repr(members)
assert 'risk-signal' in nets, 'the risk-signal network is not defined'
assert not nets['risk-signal'].get('external'), 'the risk-signal network is external'
" --profile typed --profile typed-risk-signal <<'EOF'
TYPED_RISK_SIGNAL='1'
TYPED_RISK_WARDRYX_MODE='enforce'
TYPED_RISK_WARDRYX_URL='http://typryx-wardryx-proxy:4330'
EOF

  check_cfg "the proxy gets the backend config the typed plane has, a key as a file path, and no key value" "
assert 'typryx-wardryx-proxy' in svc, 'no proxy in the resolved configuration, so this measured nothing'
p, t = svc['typryx-wardryx-proxy'], svc['typryx']
for k in ('TYPRYX_BACKEND', 'TYPRYX_JEV_KEY_FILE', 'TYPRYX_OPENAI_URL', 'TYPRYX_OPENAI_MODEL', 'TYPRYX_OPENAI_KEY_FILE', 'TYPRYX_TIMEOUT_MS'):
    assert p['environment'].get(k) == t['environment'].get(k), k + ' differs: proxy ' + repr(p['environment'].get(k)) + ', typryx ' + repr(t['environment'].get(k))
assert p['environment']['TYPRYX_BACKEND'] == 'jev'
m = [v for v in p.get('volumes', []) if v.get('target') == '/run/typed']
assert m and m[0].get('read_only') is True and m[0].get('type') == 'bind', 'the key directory is not a read-only bind mount: ' + str(m)
assert os.environ['FAKEKEY'] not in raw, 'the key file content appears in the resolved configuration'
" --profile typed --profile typed-risk-signal <<'EOF'
TYPED_MODE='jev'
TYPRYX_BACKEND='jev'
TYPRYX_JEV_KEY_FILE='/run/typed/jev-key'
TYPED_RISK_SIGNAL='1'
TYPED_RISK_WARDRYX_MODE='enforce'
TYPED_RISK_WARDRYX_URL='http://typryx-wardryx-proxy:4330'
EOF
  rm -rf "$cdir"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 22."
  exit 1
fi
echo "OK: the typed risk signal is off unless TYPED_RISK_SIGNAL=1 (refused with typed answers off), writes exactly three"
echo "    .env lines and keeps them across a mode change, the proxy is on a network of its own holding only itself, the"
echo "    broker and wardryx with no port and no key, only the broker's policy client points at it, no hold_if_signal"
echo "    policy is seeded, and the pins that give it an effect (typryx, wardryx, tokenfuse) are recent enough."
