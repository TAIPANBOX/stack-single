#!/usr/bin/env bash
#
# Enforces invariant 66 of CLAUDE.md: an agent whose error budget is spent is held
# for a person, on a box where nobody chose anything.
#
# WHAT THIS IS ABOUT
#
# wardryx 2.5.0 can hold an agent while verdryx says its budget is spent, and for
# two releases no stack set the variable that reads the file, ran anything that
# wrote it, or carried a rule that read the signal. Every check was green, because
# each half was true on its own. Four things have to hold together, and any one of
# them gone leaves a box that reports `signal_events: ok` and never holds anybody:
#
#   A. the routine: `verdryx-slo` runs in its profile on the console's image with
#      the image's entrypoint replaced, on no network, read only, reading the
#      traces read only, under a uid nothing else runs as, and it names the event
#      file and sets holds apart (a hold must not spend the budget that caused it);
#   B. the file: init-volumes pre-creates it under that uid, mode 0640, so only the
#      routine can write it and wardryx, in the bus group, can read it;
#   C. the reader: wardryx is handed WARDRYX_SIGNAL_EVENTS and its age from .env;
#   D. the installer: lifted and run in scratch boxes. By default it writes the path
#      and one managed rule; a second run changes nothing; SLO_HOLD_TARGET narrows
#      the rule, `none` leaves it out and keeps the measuring; SLO_SIGNAL=0 removes
#      both; a bad value is refused; the operator's lines stay byte for byte.
#
# It also holds the routine's sibling to the same shape: verdryx-drift ran the
# console's image with no entrypoint, so the console server refused /bin/sh as an
# argument and the routine could never have started.
#
# WHAT THIS DOES NOT SEE
#
# Whether the pinned image can read a trace. That is pyarrow in the image, and
# stack-k8s's console-image workflow runs it where the image is built.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No compose.yaml, no such service, no slo-signal block in install.sh, or no starter
# policy: each fails.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
fail() {
	printf 'FAIL: %s\n' "$*"
	status=1
}

[ -f compose.yaml ] || {
	printf 'FAIL: compose.yaml is not there, so this measured NOTHING.\n'
	exit 1
}

python3 - compose.yaml <<'PY' || status=1
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
    if section == "services" and current is not None and not line.lstrip().startswith("#"):
        blocks[current].append(line)

bad = []
FILE = "/var/lib/stack/events/verdryx.ndjson"
slo = "\n".join(blocks.get("verdryx-slo", []))
if not slo:
    print("FAIL: compose.yaml has no verdryx-slo service, so this measured NOTHING.")
    sys.exit(1)
wants = {
    'profiles: ["slo-signal"]': "it is not in the slo-signal profile",
    'entrypoint: ["/bin/sh", "-c"]': "it does not replace the console image's entrypoint, which refuses /bin/sh as an argument",
    "VERDRYX_EVENTS_PATH: " + FILE: "it does not name " + FILE,
    "network_mode: none": "it has a network, and it calls nothing",
    "read_only: true": "its root is writable",
    "- traces:/var/lib/stack/traces:ro": "it can write the traces it reads",
    "- events:/var/lib/stack/events": "it cannot reach the bus",
    "--holds-spend-no-budget": "a hold would spend the budget that caused it, and a working agent could never earn it back",
    "--window": "it names no window, so a budget measured here is not the one the docs describe",
    "gateway-openai": "it measures the Anthropic door alone",
}
for want, why in wants.items():
    if want not in slo:
        bad.append(f"verdryx-slo: {why} (no `{want}`)")
if "|| true" in slo:
    bad.append("verdryx-slo: a failed measurement is swallowed, and a routine that cannot measure then looks like a fleet with nothing to report")

m = re.search(r'user: "(\d+):(\d+)"', slo)
uid = m.group(1) if m else None
if not m:
    bad.append("verdryx-slo: it names no user, so the file is not its alone")
elif m.group(2) != "10001":
    bad.append("verdryx-slo: its group is not the bus group")
else:
    for name, block in blocks.items():
        if name != "verdryx-slo" and any(re.search(rf'user: "{uid}:', l) for l in block):
            bad.append(f"verdryx-slo: {name} runs as the same uid {uid}, so the file is not the routine's alone")

init = "\n".join(blocks.get("init-volumes", []))
if "/vol/events/verdryx.ndjson ] || : > /vol/events/verdryx.ndjson" not in init:
    bad.append("init-volumes: it does not pre-create verdryx.ndjson, and the routine cannot create in the bus")
if uid and f"chown {uid}:10001 /vol/events/verdryx.ndjson && chmod 0640 /vol/events/verdryx.ndjson" not in init:
    bad.append(f"init-volumes: verdryx.ndjson is not {uid}:10001 0640, so the routine alone does not hold it")

ward = "\n".join(blocks.get("wardryx", []))
if "WARDRYX_SIGNAL_EVENTS: ${WARDRYX_SIGNAL_EVENTS:-}" not in ward:
    bad.append("wardryx: it is not handed WARDRYX_SIGNAL_EVENTS, so nothing reads the budget")
if "WARDRYX_SIGNAL_EVENTS_MAX_AGE: ${WARDRYX_SIGNAL_EVENTS_MAX_AGE:-}" not in ward:
    bad.append("wardryx: it is not handed WARDRYX_SIGNAL_EVENTS_MAX_AGE, so the operator cannot set how long an event signals")
if "- events:/var/lib/stack/events" not in ward:
    bad.append("wardryx: it does not mount the bus, so it cannot read the file")

drift = "\n".join(blocks.get("verdryx-drift", []))
if 'entrypoint: ["/bin/sh", "-c"]' not in drift:
    bad.append("verdryx-drift: it does not replace the console image's entrypoint, so it cannot start")

for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY

BLOCK="$(sed -n '/^# slo-signal: begin$/,/^# slo-signal: end$/p' install.sh)"
STARTER="$(sed -n "/cat > policy.yaml <<'EOF'/,/^EOF\$/p" install.sh | sed '1d;$d')"
if [ -z "$BLOCK" ] || ! grep -q '^slo_policy_apply()' <<<"$BLOCK"; then
	printf 'FAIL: install.sh has no slo-signal block with slo_policy_apply, so the installer was NOT measured.\n'
	exit 1
fi
if [ -z "$STARTER" ]; then
	printf 'FAIL: install.sh has no starter policy.yaml, so the rule has nothing to be written into and NOTHING was measured.\n'
	exit 1
fi
for call in slo_resolve slo_apply slo_policy_apply; do
	grep -q "^$call\$" install.sh || fail "install.sh never calls $call"
done
grep -q 'then UP_PROFILES+=(--profile slo-signal); fi' install.sh || fail "install.sh never starts the slo-signal profile"
grep -q '^PROFILES_INSTALLED=.* slo-signal' install.sh || fail "install.sh does not list slo-signal as a profile it starts and removes"
grep -q 'SLO_POLICY_CHANGED:-0}" = 1' install.sh || fail "a run that changes the rule does not restart wardryx, and wardryx reads policy.yaml at start"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
starter_file="$scratch/starter.yaml"
printf '%s\n' "$STARTER" >"$starter_file"
run() { # DIR ENV...: resolve, apply and manage the policy in DIR
	local d="$1"
	shift
	(
		cd "$d" || exit 99
		env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" "$@" bash -c '
			set -euo pipefail
			note() { :; }
			die() { printf "die: %s\n" "$*"; exit 1; }
			typed_set_env() {
				local tmp; tmp="$(mktemp)"
				{ grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
				printf "%s=\x27%s\x27\n" "$1" "$2" >>"$tmp"
				cat "$tmp" >"$STACK_DIR/.env"; rm -f "$tmp"
			}
			eval "$BLOCK"
			slo_resolve
			slo_apply
			slo_policy_apply
			printf "on=%s changed=%s\n" "$SLO_SIGNAL_ON" "${SLO_POLICY_CHANGED:-0}"'
		printf 'rc=%s\n' "$?"
	) 2>&1
}
box() {
	local d
	d="$(mktemp -d "$scratch/box.XXXXXX")"
	printf 'SENTINEL=1\n' >"$d/.env"
	cp "$starter_file" "$d/policy.yaml"
	printf '%s' "$d"
}
rc_of() { sed -n 's/^rc=//p' <<<"$1" | tail -1; }
envval() { sed -n "s/^$2='\(.*\)'\$/\1/p" "$1/.env"; }

# D1. nothing said: on, the path, one rule on every agent.
d="$(box)"
out="$(run "$d")"
[ "$(rc_of "$out")" = 0 ] || fail "D1: a run with nothing said was refused: $out"
[ "$(envval "$d" WARDRYX_SIGNAL_EVENTS)" = /var/lib/stack/events/verdryx.ndjson ] || fail "D1: .env does not hand wardryx the file"
[ "$(grep -c '^- name: slo-burn-hold$' "$d/policy.yaml" || true)" = 1 ] || fail "D1: policy.yaml does not carry exactly one slo-burn-hold rule"
rule="$(sed -n '/^# slo-burn-hold: begin/,/^# slo-burn-hold: end/p' "$d/policy.yaml")"
grep -q 'target: "agent://\*"' <<<"$rule" || fail "D1: the rule does not cover every agent"
grep -q '^    name: slo_burn$' <<<"$rule" || fail "D1: the rule reads no slo_burn signal"
grep -q 'values: \[exhausted, fast_burn\]' <<<"$rule" || fail "D1: the rule does not hold on exhausted and fast_burn"
grep -q 'min_probability: 1$' <<<"$rule" || fail "D1: the rule names no probability, and wardryx does nothing with a rule that has none"
grep -q 'when_absent' <<<"$rule" && fail "D1: the rule sets when_absent, and a broken file would then hold every tool call on the box"
head -n "$(wc -l <"$starter_file")" "$d/policy.yaml" | cmp -s - "$starter_file" || fail "D1: the operator's lines changed"
grep -q '^SENTINEL=1$' "$d/.env" || fail "D1: a line of .env this block does not own went away"

# D2. the second run is the real test: nothing moves.
before="$(cat "$d/policy.yaml")"
out="$(run "$d")"
[ "$(rc_of "$out")" = 0 ] && grep -q 'changed=0' <<<"$out" || fail "D2: a second run changed policy.yaml: $out"
[ "$before" = "$(cat "$d/policy.yaml")" ] || fail "D2: a second run rewrote the rule"

# D3. a narrower target is written and survives a run that says nothing.
out="$(run "$d" SLO_HOLD_TARGET='agent://acme.example/*')"
grep -q 'changed=1' <<<"$out" || fail "D3: a new target did not change policy.yaml: $out"
grep -q 'target: "agent://acme.example/\*"' "$d/policy.yaml" || fail "D3: the rule does not carry the target it was given"
out="$(run "$d")"
grep -q 'target: "agent://acme.example/\*"' "$d/policy.yaml" || fail "D3: the target did not survive a re-run"
[ "$(grep -c '^- name: slo-burn-hold$' "$d/policy.yaml" || true)" = 1 ] || fail "D3: a re-run wrote a second rule"

# D4. none: measured and recorded, and nobody held.
d="$(box)"
out="$(run "$d" SLO_HOLD_TARGET=none)"
[ "$(rc_of "$out")" = 0 ] || fail "D4: SLO_HOLD_TARGET=none was refused: $out"
cmp -s "$d/policy.yaml" "$starter_file" || fail "D4: with none the policy is not the starter"
[ "$(envval "$d" WARDRYX_SIGNAL_EVENTS)" = /var/lib/stack/events/verdryx.ndjson ] || fail "D4: with none wardryx stopped reading the file"

# D5. off: the rule and the path are both gone, and the operator's rule stays.
d="$(box)"
run "$d" >/dev/null
printf -- '- name: mine\n  target: agent://x/*\n  deny_tool: [rm]\n' >>"$d/policy.yaml"
out="$(run "$d" SLO_SIGNAL=0)"
[ "$(rc_of "$out")" = 0 ] && grep -q 'on=0' <<<"$out" || fail "D5: SLO_SIGNAL=0 was refused: $out"
grep -q 'slo-burn-hold' "$d/policy.yaml" && fail "D5: with the flag off the rule stayed"
grep -q '^- name: mine$' "$d/policy.yaml" || fail "D5: turning the flag off took an operator's rule with it"
grep -q '^WARDRYX_SIGNAL_EVENTS=' "$d/.env" && fail "D5: with the flag off wardryx still reads the file"
out="$(run "$d")"
grep -q 'on=0' <<<"$out" || fail "D5: SLO_SIGNAL=0 did not survive a re-run: $out"

# D6. what cannot be written into a YAML rule, or is not a flag, is refused.
for bad in 'SLO_SIGNAL=2' 'SLO_HOLD_TARGET=everything' 'SLO_HOLD_TARGET=agent://a"b' $'SLO_HOLD_TARGET=agent://a\nb'; do
	d="$(box)"
	out="$(run "$d" "$bad")"
	[ "$(rc_of "$out")" != 0 ] || fail "D6: ${bad//$'\n'/\\n} was accepted"
	cmp -s "$d/policy.yaml" "$starter_file" || fail "D6: a refused value changed policy.yaml"
done

[ "$status" = 0 ] || exit 1
echo "OK: the routine, the file, the reader and the rule are wired, on by default and off as a set"
