#!/usr/bin/env bash
#
# Enforces invariant 70 of CLAUDE.md: a tool call of an agent nothing grants is held for a
# person on a default box, model calls pass, only an explicit grant lifts the hold, and a box
# with a history stops the upgrade with a list before anything on it changes.
#
# WHAT THIS IS ABOUT
#
# This is the first default in the stack that can stop something that worked yesterday, and
# a wrong answer here is silent in both directions: a seed that is too wide switches the
# control off and every check stays green, and a seed that is too narrow stops an agent with
# no word. So this gate does not stop at text. It holds five things:
#
#   A. the wiring: the pin in its three places, the calls, and their order. The question is
#      asked before the package step and before the journal's first line, the block sits
#      between the two other managed blocks, a change restarts wardryx, the commands enter
#      before the preflight, and CI's own identity gets its grant from a file of its own;
#   B. the block, lifted and run in scratch boxes: the floor on "*", the seeds, a second run
#      byte for byte with the risk and budget blocks beside it, TOOL_HOLD=0 taking out all of
#      it, the operator's lines byte for byte, the web grant only under egress, a broken
#      marker refused, and a wardryx that cannot load the file leaving it alone;
#   C. the stop, on a stub docker fed replay reports: who is asked, what is printed, what is
#      never printed to paste, and that a stopped run changes no byte and writes no line;
#   D. the parsers, on a chunked response and a hostile string;
#   E. the real thing: the pinned image, serving the block this installer writes, on a network
#      of its own. Each seed is asked what it was written for, the commands go through a real
#      PUT with a shim logging every argument, and the stop reads a real replay.
#
# WHAT THIS DOES NOT SEE
#
# A real install, a real broker and a real agent token: CI's install legs run those.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No compose.yaml, no block, no call or no Docker: each fails, and says it measured nothing.
#
# (teeth cases: scripts/gates-have-teeth.sh, "tool-hold-is-seeded: ...";
#  scenarios: features/a-tool-call-nothing-grants-waits-for-a-person.feature)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

status=0
fail() {
	printf 'FAIL: %s\n' "$*"
	status=1
}

[ -f compose.yaml ] && [ -f install.sh ] || {
	printf 'FAIL: compose.yaml or install.sh is not there, so this measured NOTHING.\n'
	exit 1
}
BLOCK="$(sed -n '/^# tool-hold: begin$/,/^# tool-hold: end$/p' install.sh)"
if ! grep -q '^tool_hold_block() {$' <<<"$BLOCK" || ! grep -q '^tool_hold_upgrade_check() {$' <<<"$BLOCK"; then
	printf 'FAIL: install.sh has no tool-hold block with tool_hold_block and tool_hold_upgrade_check, so the hold was NOT measured.\n'
	exit 1
fi
HTTP="$(sed -n '/^# argv-free-http: begin$/,/^# argv-free-http: end$/p' install.sh)"
JOURNAL="$(sed -n '/^# install-journal: begin$/,/^# install-journal: end$/p' install.sh)"
RISK="$(sed -n '/^# typed-risk-policy: begin$/,/^# typed-risk-policy: end$/p' install.sh)"
SLO="$(sed -n '/^# slo-signal: begin$/,/^# slo-signal: end$/p' install.sh)"
STARTER="$(sed -n "/cat > policy.yaml <<'EOF'/,/^EOF\$/p" install.sh | sed '1d;$d')"
if [ -z "$HTTP" ] || [ -z "$JOURNAL" ] || [ -z "$RISK" ] || [ -z "$SLO" ] || [ -z "$STARTER" ]; then
	printf 'FAIL: a block this gate runs beside the hold is gone from install.sh, so the hold was NOT measured.\n'
	exit 1
fi

# ---- A. the wiring ---------------------------------------------------------------------
PIN="$(sed -nE 's/^ +image: \$\{WARDRYX_IMAGE:-(.*)\}$/\1/p' compose.yaml)"
[ -n "$PIN" ] || fail "A: compose.yaml pins no wardryx image, so the pin was not measured"
VER="$(sed -nE 's/.*wardryx:v([0-9]+\.[0-9]+)\.[0-9]+@sha256:.*/\1/p' <<<"$PIN")"
case "$VER" in
	2.[6-9] | 2.[1-9][0-9] | [3-9].*) ;;
	*) fail "A: compose.yaml pins wardryx ${VER:-?}, older than 2.6.0, which refuses when_no_grant at load" ;;
esac
OWN="$(sed -nE 's/^TOOL_HOLD_WARDRYX_IMAGE="(.*)"$/\1/p' <<<"$BLOCK")"
[ "$OWN" = "$PIN" ] || fail "A: the image install.sh names to ask with is not the one compose.yaml pins"
grep -qF "\"$PIN\"" components.json || fail "A: components.json does not carry the pin compose.yaml runs"

lineno() { grep -n -m1 -E "$1" install.sh | cut -d: -f1; }
for call in tool_hold_resolve tool_hold_upgrade_check tool_hold_apply tool_hold_policy_apply; do
	grep -q "^$call\$" install.sh || fail "A: install.sh never calls $call"
done
ask="$(lineno '^tool_hold_upgrade_check$')"
pkg="$(lineno '^say "installing docker and git"$')"
begin="$(lineno '^ +journal_begin ')"
if [ -z "$ask" ] || [ -z "$pkg" ] || [ -z "$begin" ] || [ "$ask" -ge "$pkg" ] || [ "$ask" -ge "$begin" ]; then
	fail "A: the question is not asked before the package step and the journal's first line, so a stopped run has changed the box"
fi
[ "$(lineno '^tool_hold_resolve$')" -lt "${ask:-0}" ] || fail "A: the switch is read after the question that needs it"
risk="$(lineno '^typed_risk_policy_apply$')"
hold="$(lineno '^tool_hold_policy_apply$')"
slo="$(lineno '^slo_policy_apply$')"
if [ "${risk:-0}" -ge "${hold:-0}" ] || [ "${hold:-0}" -ge "${slo:-0}" ]; then
	fail "A: the hold is not between the risk and budget blocks, so every run moves a block and restarts wardryx"
fi
grep -q 'TOOL_HOLD_POLICY_CHANGED:-0}" = 1' install.sh || fail "A: a run that changes the block does not restart wardryx, and wardryx reads policy.yaml at start"
pre="$(lineno '^# ---- 0\. preflight')"
ent="$(lineno 'agent-allow\|agent-deny\|agent-list\) tool_hold_main')"
[ -n "$ent" ] && [ "$ent" -lt "${pre:-0}" ] || fail "A: the agent commands do not enter before the preflight, which starts an install"
grep -q '^  tool_hold_status$' install.sh || fail "A: status prints no line about the hold"
grep -q '^running_images$' install.sh || fail "A: the drift check is gone from stack_checks"
grep -q '^  check "policy plane: wardryx loaded the tool hold"' install.sh || fail "A: no check reads what wardryx loaded, so a file that says on is believed"
grep -q '^## .*tool call.*' README.md || fail "A: the README has no section on an agent's tool call"
for word in 'agent-allow' 'agent-deny' 'agent-list' 'TOOL_HOLD=0'; do
	grep -qF "$word" README.md || fail "A: the README does not name $word"
done
CIGRANT=.github/ci-tool-grant.yaml
if [ ! -f "$CIGRANT" ] || ! grep -q '^  target: agent://local.invalid/ci$' "$CIGRANT"; then
	fail "A: CI's own identity has no grant in a file of its own, so its legs would be held"
fi
grep -qF "$CIGRANT" .github/workflows/install.yml || fail "A: the install workflow never reads $CIGRANT"
grep -qF 'local.invalid/ci' <<<"$BLOCK" && fail "A: the installer seeds CI's identity, which no box needs"
if [ "$status" != 0 ]; then
	printf 'the wiring is wrong, so nothing below would mean anything\n'
	exit 1
fi

# ---- the harness -----------------------------------------------------------------------
scratch="$(mktemp -d)"
live=""
cleanup() {
	if [ -n "$live" ]; then
		docker rm -f "$live-wardryx-1" >/dev/null 2>&1 || true
		docker network rm "${live}_core" >/dev/null 2>&1 || true
		docker volume rm "${live}_events" >/dev/null 2>&1 || true
	fi
	chmod -R u+rwX "$scratch" 2>/dev/null || true
	rm -rf "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/bin"
printf '%s\n' "$STARTER" >"$scratch/starter.yaml"
{
	cat <<'SH'
set -euo pipefail
say() { printf '>> %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die() { printf 'die: %s\n' "$*"; exit 1; }
EXPLAINED=0
typed_set_env() {
  local tmp; tmp="$(mktemp)"
  { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf "%s='%s'\n" "$1" "$2" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env"; rm -f "$tmp"
}
compose_image() { printf '%s' "${STUB_IMAGE:-}"; }
cosign_install() { printf 'order cosign\n' >>"$LOG"; }
image_verify() { printf 'order verify\n' >>"$LOG"; [ -z "${STUB_VERIFY_FAILS:-}" ] || die "no signature"; }
SH
	printf '%s\n%s\n%s\n%s\n%s\n' "$HTTP" "$JOURNAL" "$RISK" "$SLO" "$BLOCK"
} >"$scratch/lib.sh"

# The stub: docker as the stop sees it. A state directory says what is on the box.
cat >"$scratch/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$LOG"
case "$1 ${2:-}" in
  'image inspect') [ -f "$STATE/image" ]; exit ;;
  'image rm') rm -f "$STATE/image"; exit 0 ;;
  'pull '*) printf 'order pull\n' >>"$LOG"; touch "$STATE/image"; exit 0 ;;
  'volume inspect') [ -z "${NO_VOLUME:-}" ]; exit ;;
  'network inspect') exit 1 ;;
  'ps '*) printf '%s\n' ${RUNNING:-}; exit 0 ;;
esac
if [ "$1" = run ]; then
  case " $* " in
    *' replay '*)
      for a in "$@"; do case "$a" in *:/candidate:ro) cp -r "${a%%:*}" "$STATE/candidate" ;; esac; done
      [ -z "${REPORT:-}" ] || cat "$REPORT"
      [ -z "${REPLAY_ERR:-}" ] || printf '%s\n' "$REPLAY_ERR" >&2
      exit "${REPLAY_RC:-0}" ;;
    *' check '*) [ -z "${CHECK_ERR:-}" ] || { printf '%s\n' "$CHECK_ERR" >&2; exit 1; }; exit 0 ;;
  esac
fi
exit 0
STUB
chmod +x "$scratch/bin/docker"

box() { # [policy text]: a scratch box with an .env and the starter policy
	local d
	d="$(mktemp -d "$scratch/box.XXXXXX")"
	printf "SENTINEL=1\nRECORD_TRUST_DOMAIN='acme.example'\n" >"$d/.env"
	cp "$scratch/starter.yaml" "$d/policy.yaml"
	mkdir -p "$d/state"
	printf '%s' "$d"
}
harness() { # DIR SCRIPT ENV...: runs SCRIPT in DIR with the lifted blocks and the stub on PATH
	local d="$1" script="$2"
	shift 2
	(
		cd "$d" || exit 99
		env -i PATH="$scratch/bin:$PATH" HOME="$d" STACK_DIR="$d" STATE="$d/state" LOG="$d/state/log" "$@" \
			bash -c ". '$scratch/lib.sh'; $script"
		printf 'rc=%s\n' "$?"
	) 2>&1
}
run() { # DIR ENV...: one run of the three managed blocks, in the order install.sh runs them
	local d="$1"
	shift
	harness "$d" 'TYPED_RISK_ON=${RISK_ON:-0}; slo_resolve; tool_hold_resolve; typed_set_env SLO_SIGNAL "$SLO_SIGNAL_ON"; tool_hold_apply
		typed_risk_policy_apply; tool_hold_policy_apply; slo_policy_apply
		printf "changed=%s\n" "$TOOL_HOLD_POLICY_CHANGED"' "$@"
}
rc_of() { sed -n 's/^rc=//p' <<<"$1" | tail -1; }
block_of() { sed -n '/^# tool-hold: begin/,/^# tool-hold: end/p' "$1/policy.yaml"; }
envval() { sed -n "s/^$2='\(.*\)'\$/\1/p" "$1/.env"; }

# ---- B. the block ----------------------------------------------------------------------
d="$(box)"
out="$(run "$d")"
[ "$(rc_of "$out")" = 0 ] || fail "B1: a run with nothing said was refused: $out"
blk="$(block_of "$d")"
[ -n "$blk" ] || fail "B1: a run with nothing said wrote no block"
[ "$(grep -c '^# tool-hold: begin' "$d/policy.yaml" || true)" = 1 ] || fail "B1: policy.yaml does not carry exactly one block"
python3 - "$d/policy.yaml" <<'PY' || status=1
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r"^# tool-hold: begin.*?^# tool-hold: end", text, re.S | re.M).group(0)
rules, cur = [], None
for line in block.split("\n"):
    m = re.match(r"^- name: (\S+)$", line)
    if m:
        cur = {"name": m.group(1)}
        rules.append(cur)
    m = re.match(r"^  ([a-z_]+): (.*)$", line)
    if m and cur is not None:
        cur[m.group(1)] = m.group(2)
bad = []
by = {r["name"]: r for r in rules}
floor = by.get("tool-hold")
if floor is None or floor.get("target") != '"*"':
    bad.append('B1: the floor is not on target "*", so an agent id with no agent:// walks past it')
if floor is None or floor.get("when_no_grant") != "hold":
    bad.append("B1: the floor does not say when_no_grant: hold")
if by.get("grant-drills", {}).get("target") != "agent://mockryx.local/*" or by.get("grant-drills", {}).get("grant_tool") != '["*"]':
    bad.append("B1: grant-drills is not every tool for agent://mockryx.local/*, and the fire drills would be held")
ic = by.get("grant-install-check", {})
if ic.get("target") != "agent://local.invalid/install-check" or ic.get("grant_tool") != "[ask]":
    bad.append("B1: grant-install-check is not `ask` for the installer's own id, and its check would be held")
for r in rules:
    if "grant_tool" in r and not re.match(r"^agent://[^*?/]+(/|$)", r.get("target", "")):
        bad.append(f"B1: {r['name']} grants on a target with no trust domain, which wardryx refuses at load")
    if "grant_tool" in r and "when_no_grant" in r:
        bad.append(f"B1: {r['name']} holds and grants in one policy")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY
grep -q 'grant-operator-web' <<<"$blk" && fail "B1: a box with no egress carries the web grant, which is a surface it does not use"
grep -qE 'felyx|costcrew' <<<"$blk" && fail "B1: felyx or costcrew got a grant, and both make model calls only"
[ "$(envval "$d" TOOL_HOLD)" = 1 ] || fail "B1: the choice is not in .env"
head -n "$(wc -l <"$scratch/starter.yaml")" "$d/policy.yaml" | cmp -s - "$scratch/starter.yaml" || fail "B1: the operator's lines changed"
grep -q '^SENTINEL=1$' "$d/.env" || fail "B1: a line of .env this block does not own went away"

# B2. the second run, with all three blocks on one box: nothing moves.
d="$(box)"
run "$d" RISK_ON=1 >/dev/null
sum="$(cksum <"$d/policy.yaml")"
out="$(run "$d" RISK_ON=1)"
[ "$sum" = "$(cksum <"$d/policy.yaml")" ] || fail "B2: a second run moved policy.yaml"
grep -q '^changed=0$' <<<"$out" || fail "B2: a second run says the block changed, and restarts wardryx for nothing"
grep -q 'changed=' <<<"$out" || fail "B2: the run did not finish: $out"

# B3. off takes out the block and every grant it wrote, and nothing of the operator's.
d="$(box)"
run "$d" >/dev/null
printf -- '- name: mine\n  target: agent://acme.example/*\n  deny_tool: [rm]\n' >>"$d/policy.yaml"
out="$(run "$d" TOOL_HOLD=0)"
[ "$(rc_of "$out")" = 0 ] || fail "B3: TOOL_HOLD=0 was refused: $out"
grep -q 'changed=1' <<<"$out" || fail "B3: TOOL_HOLD=0 does not restart wardryx"
grep -qE 'when_no_grant|grant_tool|tool-hold' "$d/policy.yaml" && fail "B3: TOOL_HOLD=0 leaves the block, and an older wardryx would refuse the file"
grep -q '^- name: mine$' "$d/policy.yaml" || fail "B3: TOOL_HOLD=0 took an operator's line"
head -n "$(wc -l <"$scratch/starter.yaml")" "$d/policy.yaml" | cmp -s - "$scratch/starter.yaml" || fail "B3: the operator's lines changed"
[ "$(envval "$d" TOOL_HOLD)" = 0 ] || fail "B3: TOOL_HOLD=0 is not kept in .env"
out="$(run "$d")"
grep -q 'tool-hold' "$d/policy.yaml" && fail "B4: a re-run with nothing said turned the hold back on"
out="$(run "$d" TOOL_HOLD=1)"
grep -q '^# tool-hold: begin' "$d/policy.yaml" || fail "B4: TOOL_HOLD=1 did not bring it back"

# B5. a value that is neither.
d="$(box)"
sum="$(cksum <"$d/policy.yaml")"
out="$(run "$d" TOOL_HOLD=yes)"
[ "$(rc_of "$out")" != 0 ] || fail "B5: TOOL_HOLD=yes was taken"
[ "$sum" = "$(cksum <"$d/policy.yaml")" ] || fail "B5: a refused value changed policy.yaml"

# B6. the web grant: under egress, kept on a re-run, never with agent tokens off.
d="$(box)"
run "$d" WITH_EGRESS=1 >/dev/null
blk="$(block_of "$d")"
grep -qx '  target: agent://acme.example/agents/operator' <<<"$blk" || fail "B6: WITH_EGRESS=1 wrote no web grant for the operator in the box's trust domain"
grep -qx '  grant_tool: \[fetch_url, browse\]' <<<"$blk" || fail "B6: the web grant does not name fetch_url and browse"
grep -qx '  require_identity_source: \[agent-token, none\]' <<<"$blk" || fail "B6: the web grant must take an agent token and scopyx's empty source, and no static key"
run "$d" >/dev/null
grep -q 'grant-operator-web' "$d/policy.yaml" || fail "B6: a re-run with no flag dropped the web grant of a box that reads the web"
d="$(box)"
run "$d" RUNNING=scopyx >/dev/null
grep -q 'grant-operator-web' "$d/policy.yaml" || fail "B6: a box whose scopyx runs has no web grant"
d="$(box)"
printf "TOKENFUSE_AGENT_TOKENS='off'\n" >>"$d/.env"
run "$d" RUNNING=scopyx >/dev/null
grep -q 'grant-operator-web' "$d/policy.yaml" && fail "B6: a box with agent tokens off carries the web grant"
d="$(box)"
printf "TOKENFUSE_AGENT_TOKENS_STATIC_KEYS='felyx,agents'\n" >>"$d/.env"
run "$d" WITH_EGRESS=1 >/dev/null
grep -qx '  require_identity_source: \[agent-token, client-key, none\]' <<<"$(block_of "$d")" || fail "B6: a box that names the agents' static key has it refused by its own seed"

# B7. a begin with no end would swallow the operator's lines.
d="$(box)"
printf '# tool-hold: begin (left behind)\n- name: mine\n  target: agent://acme.example/*\n' >>"$d/policy.yaml"
sum="$(cksum <"$d/policy.yaml")"
out="$(run "$d")"
[ "$(rc_of "$out")" != 0 ] || fail "B7: a marker with no partner was taken"
[ "$sum" = "$(cksum <"$d/policy.yaml")" ] || fail "B7: a marker with no partner cost the operator lines"

# B8. a wardryx that cannot load the file leaves it as it was.
d="$(box)"
sum="$(cksum <"$d/policy.yaml")"
out="$(run "$d" CHECK_ERR='wardryx: load policy: field when_no_grant not found' STUB_IMAGE=stack/wardryx:dev)"
[ "$(rc_of "$out")" != 0 ] || fail "B8: a wardryx that cannot load the block was given it"
[ "$sum" = "$(cksum <"$d/policy.yaml")" ] || fail "B8: policy.yaml changed under a wardryx that cannot load it"
grep -qF 'when_no_grant not found' <<<"$out" || fail "B8: the refusal does not say what wardryx said"
grep -q 'tool-hold\.' <<<"$(ls "$d")" && fail "B8: a temporary file was left beside policy.yaml"
grep -q ' check /etc /etc/wardryx/policy.yaml' "$d/state/log" || fail "B8: the image was not asked"

# ---- C. the stop -----------------------------------------------------------------------
report() { # FILE TOTAL UNEXAMINED then rows as agent|tool|calls|last
	local f="$1" total="$2" unex="$3" first=1 agent tool calls last r
	shift 3
	{
		printf '{\n  "source": "x",\n  "total": %s,\n  "reproduced": %s,\n  "unexamined": %s,\n  "changed": 0,\n' "$total" "$total" "$unex"
		if [ "$#" -eq 0 ]; then printf '  "would_hold": []\n}\n'; else
			printf '  "would_hold": [\n'
			for r in "$@"; do
				IFS='|' read -r agent tool calls last <<<"$r"
				[ "$first" = 1 ] || printf ',\n'
				first=0
				printf '    {\n      "agent_id": "%s",\n      "tool": "%s",\n      "calls": %s,\n      "last": "%s"\n    }' "$agent" "$tool" "$calls" "$last"
			done
			printf '\n  ]\n}\n'
		fi
	} >"$f"
}
ask() { # DIR ENV...
	local d="$1"
	shift
	harness "$d" 'tool_hold_resolve; tool_hold_upgrade_check; printf "passed\n"' "$@"
}
snapshot() { (cd "$1" && find . -path ./state -prune -o -type f -exec cksum {} + | sort); }
docker_calls() { if [ -f "$1/state/log" ]; then grep -c '^docker ' "$1/state/log" || true; else printf 0; fi; }

# C1. who is not asked.
d="$(box)"
rm "$d/policy.yaml"
out="$(ask "$d")"
grep -q '^passed$' <<<"$out" || fail "C1: a new box did not pass: $out"
[ "$(docker_calls "$d")" = 0 ] || fail "C1: a new box was asked, and it has nothing to ask"
d="$(box)"
run "$d" >/dev/null
: >"$d/state/log"
out="$(ask "$d")"
grep -q '^passed$' <<<"$out" || fail "C1: a box that carries the block did not pass"
[ "$(docker_calls "$d")" = 0 ] || fail "C1: a box that carries the block was asked again, and its own holds would stop every re-run"
d="$(box)"
out="$(ask "$d" TOOL_HOLD=0)"
grep -q '^passed$' <<<"$out" || fail "C1: TOOL_HOLD=0 did not pass"
[ "$(docker_calls "$d")" = 0 ] || fail "C1: TOOL_HOLD=0 was asked"

# C2. a call outside the seeds stops the run, and nothing changed.
rep="$scratch/rows.json"
report "$rep" 9 0 'agent://acme.example/lab/one|fetch_url|7|2026-11-01T10:00:00.123Z' 'agent://acme.example/lab/one|browse|2|2026-11-02T10:00:00Z' 'agent://acme.example/lab/two|ask|1|2026-11-03T10:00:00Z'
d="$(box)"
printf '2026-11-01T00:00:00Z good version=1.6.4 index=1 commit=x\n' >"$d/.install-history"
before="$(snapshot "$d")"
out="$(ask "$d" REPORT="$rep")"
[ "$(rc_of "$out")" != 0 ] || fail "C2: an ungranted caller did not stop the run"
grep -q '^passed$' <<<"$out" && fail "C2: the run went on past the list"
grep -qE '^ +7 +2026-11-01T10:00:00 +fetch_url +agent://acme.example/lab/one$' <<<"$out" || fail "C2: no table row with count, last seen, tool and agent: $out"
grep -qF "./install.sh agent-allow 'agent://acme.example/lab/one' 'browse,fetch_url' --why" <<<"$out" || fail "C2: the command does not name both tools of the agent"
grep -qF 'TOOL_HOLD=0 ./install.sh' <<<"$out" || fail "C2: the stop does not say how to set TOOL_HOLD=0"
grep -q 'Nothing was changed' <<<"$out" || fail "C2: the stop does not say nothing was changed"
[ "$before" = "$(snapshot "$d")" ] || fail "C2: a stopped run changed a file on the box"
[ "$(grep -c . "$d/.install-history")" = 1 ] || fail "C2: a stopped run wrote to the journal"
grep -q '^# tool-hold: begin' "$d/state/candidate/policy.yaml" || fail "C2: the question was not about the policy this run would write"
order="$(grep '^order ' "$d/state/log" | tr '\n' ' ')"
[ "$order" = 'order cosign order verify order pull ' ] || fail "C2: the signature is not checked before the pull (invariant 44): $order"
[ ! -f "$d/state/image" ] || fail "C2: a stopped run left the image it pulled"
line="$(grep -F ' replay ' "$d/state/log" || true)"
for want in '--network none' '--read-only' '--user 20001:10001' 'agent-stack_events:/var/lib/stack/events:ro' '-format json'; do
	grep -qF -- "$want" <<<"$line" || fail "C2: the replay does not run with $want"
done

# C3. an image already on the box stays.
d="$(box)"
touch "$d/state/image"
out="$(ask "$d" REPORT="$rep")"
[ -f "$d/state/image" ] || fail "C3: a stopped run removed an image it did not pull"
grep -q ' pull ' "$d/state/log" && fail "C3: an image on the box was pulled again"

# C4. text a caller wrote is never printed to paste.
hostile="$scratch/hostile.json"
report "$hostile" 3 0 'agent://x/$(touch pwned)|ask|1|2026-11-01T10:00:00Z' 'no-scheme|ask|1|2026-11-01T10:00:00Z' "agent://x/y|a'b;id|1|2026-11-01T10:00:00Z"
d="$(box)"
out="$(ask "$d" REPORT="$hostile")"
grep -qE 'pwned|no-scheme|a.b;id' <<<"$(grep -F 'agent-allow' <<<"$out" || true)" && fail "C4: a hostile id or tool is printed as a command to paste"
grep -q '3 row(s) have no command' <<<"$out" || fail "C4: the rows with no command are not counted"
grep -q 'pwned' <<<"$out" || fail "C4: a hostile id is not in the table, so the operator does not see it"
many="$scratch/many.json"
rows=()
for i in $(seq 1 60); do rows+=("agent://x/a$i|t|1|2026-11-01T10:00:00Z"); done
report "$many" 60 0 "${rows[@]}"
d="$(box)"
out="$(ask "$d" REPORT="$many")"
grep -q 'and 20 more' <<<"$out" || fail "C4: the table has no bound, and an agent id is whatever a caller wrote"

# C5. nothing would be held: the box goes on, and keeps the image it will run.
none="$scratch/none.json"
report "$none" 9 0
d="$(box)"
out="$(ask "$d" REPORT="$none")"
grep -q '^passed$' <<<"$out" || fail "C5: a box nothing would stop was stopped: $out"
[ -f "$d/state/image" ] || fail "C5: the image a passing run needs was removed"

# C6. a history that could not be asked says nothing, and nothing is not a pass.
blind="$scratch/blind.json"
report "$blind" 9 4
d="$(box)"
out="$(ask "$d" REPORT="$blind")"
[ "$(rc_of "$out")" != 0 ] || fail "C6: unexamined decisions were read as nothing to hold"
grep -q '4 of 9 decisions' <<<"$out" || fail "C6: the stop does not say how much could not be asked"
out="$(ask "$d" REPORT="$blind" TOOL_HOLD=1)"
grep -q '^passed$' <<<"$out" || fail "C6: TOOL_HOLD=1 did not go on over a history that cannot be asked"

# C7. TOOL_HOLD=1 is said in the environment, and never by a line left in a file.
d="$(box)"
out="$(ask "$d" REPORT="$rep" TOOL_HOLD=1)"
grep -q '^passed$' <<<"$out" || fail "C7: TOOL_HOLD=1 did not go on"
grep -q 'lab/one' <<<"$out" || fail "C7: TOOL_HOLD=1 went on without showing the list"
d="$(box)"
printf "TOOL_HOLD='1'\n" >>"$d/.env"
out="$(ask "$d" REPORT="$rep")"
[ "$(rc_of "$out")" != 0 ] || fail "C7: a line in .env answered for a person"

# C8. no report and no signature each stop, with the reason.
d="$(box)"
out="$(ask "$d" REPLAY_ERR='wardryx: read events: permission denied' REPLAY_RC=1)"
[ "$(rc_of "$out")" != 0 ] || fail "C8: a replay that printed nothing was read as a pass"
grep -q 'permission denied' <<<"$out" || fail "C8: the stop does not say why wardryx could not be asked"
d="$(box)"
out="$(ask "$d" REPORT="$none" STUB_VERIFY_FAILS=1)"
[ "$(rc_of "$out")" != 0 ] || fail "C8: an image whose signature did not check was used"
grep -q ' pull ' "$d/state/log" && fail "C8: an image whose signature did not check was pulled"

# C9. a replay that exits 1 on a row it could not reproduce still printed the report.
d="$(box)"
out="$(ask "$d" REPORT="$rep" REPLAY_RC=1)"
grep -q 'lab/one' <<<"$out" || fail "C9: the report of a replay that exited 1 was thrown away"

# C10. no events volume: nothing to read, and asking must not create one.
d="$(box)"
out="$(ask "$d" NO_VOLUME=1)"
grep -q '^passed$' <<<"$out" || fail "C10: a box with no events volume was stopped"
grep -q ' replay ' "$d/state/log" && fail "C10: a run on a missing volume creates it"

# C11. the real install.sh, on stub tools: the stop comes before a package, a file or a line,
# and the three commands enter from the top of the real file.
mkdir -p "$scratch/bin2"
cp "$scratch/bin/docker" "$scratch/bin2/docker"
for tool in apt-get git curl cosign ufw sysctl systemctl; do
	printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"$LOG"\nexit 0\n' "$tool" >"$scratch/bin2/$tool"
done
printf '#!/usr/bin/env bash\necho 0\n' >"$scratch/bin2/id"
chmod +x "$scratch"/bin2/*
printf 'ID=debian\nPRETTY_NAME="a stub"\n' >"$scratch/os-release"
sed "s#/etc/os-release#$scratch/os-release#g" install.sh >"$scratch/install-copy.sh"
real() { # DIR ARGS...: the real file, with REPORT read by the stub docker
	local d="$1"
	shift
	env -i PATH="$scratch/bin2:$PATH" HOME="$d" STACK_DIR="$d" STATE="$d/state" LOG="$d/state/log" REPORT="$rep" \
		bash "$scratch/install-copy.sh" "$@" </dev/null 2>&1 || printf 'rc=%s\n' "$?"
}
d="$(box)"
touch "$d/state/image"
printf '2026-11-01T00:00:00Z good version=1.6.4 index=1 commit=x\n' >"$d/.install-history"
before="$(snapshot "$d")"
out="$(real "$d")"
grep -qE '^ +7 +2026-11-01T10:00:00 +fetch_url +agent://acme.example/lab/one$' <<<"$out" || fail "C11: the real install.sh did not stop with the list: $(tail -3 <<<"$out")"
grep -q '^apt-get ' "$d/state/log" && fail "C11: the real install.sh reached the package step before the stop"
[ "$before" = "$(snapshot "$d")" ] || fail "C11: the real install.sh changed a file before the stop"
out="$(real "$d" agent-list)"
grep -q '^   tool hold: off, grants: 0 in policy.yaml, not read through agent-allow$' <<<"$out" || fail "C11: ./install.sh agent-list did not enter: $(tail -3 <<<"$out")"
grep -q 'lab/one' <<<"$out" || fail "C11: agent-list with the hold off does not say what it would stop"
out="$(real "$d" agent-allow agent://a/b ask --why 'a reason')"
grep -q 'there is no stack here to ask' <<<"$out" || fail "C11: ./install.sh agent-allow did not enter: $(tail -3 <<<"$out")"
grep -q '^apt-get ' "$d/state/log" && fail "C11: a command reached the package step"

# ---- D. the parsers --------------------------------------------------------------------
d="$(box)"
parsed="$(harness "$d" '
  body="[{\"id\":\"a\",\"name\":\"x},{y \\\"q\\\"\",\"target\":\"agent://a/b\",\"grant_tool\":[\"t\"],\"hold_if_signal\":{\"name\":\"n\"},\"updated_at\":\"z\"},{\"id\":\"b\",\"target\":\"agent://c\"}]"
  one="${body:0:17}"; two="${body:17}"
  resp="$(printf "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n%x\r\n%s\r\n0\r\n\r\n" "${#one}" "$one" "${#two}" "$two")"
  got="$(tool_hold_body <<<"$resp")"
  [ "$got" = "$body" ] && printf "dechunked\n"
  plain="$(printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]")"
  [ "$(tool_hold_body <<<"$plain")" = "[]" ] && printf "plain\n"
  objs="$(tool_hold_objects <<<"$body")"
  printf "objects=%s\n" "$(grep -c . <<<"$objs")"
  first="$(head -n 1 <<<"$objs")"
  printf "target=%s\n" "$(tool_hold_field target "$first")"
  printf "tools=%s\n" "$(tool_hold_list grant_tool "$first")"
  printf "name=%s\n" "$(tool_hold_field name "$first")"
  printf "id-a=%s\nid-b=%s\n" "$(tool_hold_id agent://a/b-c)" "$(tool_hold_id agent://a-b/c)"
')"
grep -q '^dechunked$' <<<"$parsed" || fail "D: a chunked answer is not put back together, and wardryx sends a long list chunked: $parsed"
grep -q '^plain$' <<<"$parsed" || fail "D: a plain answer is not read"
grep -q '^objects=2$' <<<"$parsed" || fail "D: a string holding },{ splits a policy in two"
grep -q '^target=agent://a/b$' <<<"$parsed" || fail "D: the target of a policy is not read"
grep -q '^tools=t$' <<<"$parsed" || fail "D: the tools of a policy are not read"
ia="$(sed -n 's/^id-a=//p' <<<"$parsed")"
ib="$(sed -n 's/^id-b=//p' <<<"$parsed")"
[ -n "$ia" ] && [ "$ia" != "$ib" ] || fail "D: two agents share a policy id, so one grant replaces the other"

# ---- E. the real thing -----------------------------------------------------------------
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
	printf 'FAIL: no Docker, so the seeds were not put to the image and this measured NOTHING.\n'
	exit 1
fi
if [ "$status" != 0 ]; then
	printf 'the block is wrong, so asking the image about it would mean nothing\n'
	exit 1
fi
if ! docker image inspect "$PIN" >/dev/null 2>&1; then
	docker pull -q "$PIN" >/dev/null || {
		printf 'FAIL: could not pull %s, so the seeds were not put to the image and this measured NOTHING.\n' "$PIN"
		exit 1
	}
fi
live="holdgate$$"
ADMIN="holdgate-admin-$(printf '%040d' 7)"
PEP="holdgate-pep-$(printf '%040d' 9)"
REAL_DOCKER="$(command -v docker)"
mkdir -p "$scratch/shim"
cat >"$scratch/shim/docker" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$scratch/argv.log"
exec "$REAL_DOCKER" "\$@"
SHIM
chmod +x "$scratch/shim/docker"
docker network create --internal "${live}_core" >/dev/null
docker volume create "${live}_events" >/dev/null
docker run --rm -v "${live}_events:/v" busybox:1.36 chown 20001:10001 /v >/dev/null

e="$scratch/e"
mkdir -p "$e/state"
printf "WARDRYX_ADMIN=%s\nRECORD_TRUST_DOMAIN='acme.example'\n" "$ADMIN" >"$e/.env"
cp "$scratch/starter.yaml" "$e/policy.yaml"
out="$(harness "$e" 'tool_hold_resolve; tool_hold_policy_apply' WITH_EGRESS=1 STUB_IMAGE="$PIN" NET="${live}_core" PATH="$scratch/shim:$PATH")"
[ "$(rc_of "$out")" = 0 ] || fail "E: the image this box runs does not load the block: $out"
chmod 0644 "$e/policy.yaml"
docker run -d --name "$live-wardryx-1" --network "${live}_core" --network-alias wardryx --user 20001:10001 \
	-e WARDRYX_KEYS="$ADMIN:default:admin,$PEP:default:pep" -e WARDRYX_APPROVAL_SECRET=holdgate-approval-secret-0000000000000000 \
	-e WARDRYX_POLICY_ARCHIVE=/var/lib/stack/events/wardryx-policy-archive \
	-v "${live}_events:/var/lib/stack/events" -v "$e/policy.yaml:/etc/wardryx/policy.yaml:ro" "$PIN" \
	serve -addr 0.0.0.0:8090 -events /var/lib/stack/events/wardryx.ndjson -policy /etc/wardryx/policy.yaml >/dev/null
lib() { # SCRIPT ENV...: the lifted blocks against the real wardryx, every docker argument logged
	local script="$1"
	shift
	(
		cd "$e" || exit 99
		env -i PATH="$scratch/shim:$PATH" HOME="$e" STACK_DIR="$e" STATE="$e/state" LOG="$e/state/log" NET="${live}_core" \
			PEP="$PEP" HTTP_WAIT=1 "$@" bash -c ". '$scratch/lib.sh'; $script"
		printf 'rc=%s\n' "$?"
	) 2>&1
}
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
	if [ "$(lib 'tool_hold_request GET /v1/status; printf "%s\n" "$TOOL_HOLD_STATUS"' | sed -n 1p)" = 200 ]; then ready=1; break; fi
	sleep 1
done
if [ "${ready:-0}" != 1 ]; then
	docker logs "$live-wardryx-1" 2>&1 | tail -5
	printf 'FAIL: the pinned wardryx did not answer on the block, so this measured NOTHING.\n'
	exit 1
fi
cat >>"$scratch/lib.sh" <<'SH'
decide() { # AGENT TOOL SOURCE: a tools/call as the broker asks it, TOOL empty for a model call, `web` for scopyx's question
  local body
  case "$2" in
    "") body="{\"agent_id\":\"$1\",\"run_id\":\"r\",\"model\":\"m\",\"identity_source\":\"$3\"}" ;;
    web) body="{\"agent_id\":\"$1\",\"run_id\":\"r\",\"tool_names\":[\"fetch_url\"],\"domains\":[\"example.com\"]}" ;;
    *) body="{\"agent_id\":\"$1\",\"run_id\":\"r\",\"tool_names\":[\"$2\"],\"identity_source\":\"$3\",\"tool_call\":{\"name\":\"$2\",\"target\":\"t\",\"arguments\":{\"a\":1}}}" ;;
  esac
  http_request POST http://wardryx:8090/v1/decide "Authorization: Bearer $PEP"$'\r\n'"Content-Type: application/json"$'\r\n' "$body" | tool_hold_body \
    | tool_hold_objects | sed -nE 's/.*"decision":"([a-z]+)".*/\1/p'
}
SH
# Asked side by side, and read when settled: a request lasts 2 x HTTP_WAIT whatever wardryx does.
wants=()
want() { # NAME DECISION AGENT TOOL SOURCE
	local n="${#wants[@]}"
	wants+=("$1|$2")
	lib "decide '$3' '$4' '$5'" >"$scratch/want.$n" &
}
settle() {
	local n=0 one got
	wait
	for one in "${wants[@]}"; do
		got="$(head -n 1 "$scratch/want.$n")"
		[ "$got" = "${one##*|}" ] || fail "E: ${one%|*}: wardryx answered ${got:-nothing}, want ${one##*|}"
		n=$((n + 1))
	done
	wants=()
	[ "$status" = 0 ] || exit 1
}
OP=agent://acme.example/agents/operator
want "a tool call of an agent nothing grants" hold agent://acme.example/stranger ask agent-token
want "a model call of that agent" allow agent://acme.example/stranger "" agent-token
want "an egress question of that agent" allow agent://acme.example/stranger web ""
want "an id with no scheme" hold stranger ask client-key
want "the fire drill's tool" allow agent://mockryx.local/scenario lookup_order_status client-key
want "the drill's denied tool" deny agent://mockryx.local/ci shell_exec client-key
want "the installer's check through the broker's static key" allow agent://local.invalid/install-check ask client-key
want "another tool of the installer's id" hold agent://local.invalid/install-check fetch_url client-key
want "the operator's fetch" allow "$OP" fetch_url agent-token
want "scopyx's question about the operator's fetch" allow "$OP" web ""
want "the operator's name under a static key" deny "$OP" fetch_url client-key
want "the operator's other tool" hold "$OP" ask agent-token
want "the operator's model call" allow "$OP" "" agent-token
settle

# The stop on a store with nothing in it: a list of nothing is no policy file.
st="$scratch/e-empty"
mkdir -p "$st/state"
cp "$e/.env" "$st/.env"
cp "$scratch/starter.yaml" "$st/policy.yaml"
out="$(
	cd "$st" && env -i PATH="$scratch/shim:$PATH" HOME="$st" STACK_DIR="$st" STATE="$st/state" LOG="$st/state/log" NET="${live}_core" HTTP_WAIT=1 \
		bash -c ". '$scratch/lib.sh'; tool_hold_resolve; tool_hold_upgrade_check; printf 'passed\n'" 2>&1 || true
)"
grep -qE ' +ask +agent://acme.example/stranger$' <<<"$out" || fail "E: an empty store broke the question: $out"

floorput="$(lib 'tool_hold_request PUT /v1/policies/x "{\"target\":\"*\",\"when_no_grant\":\"hold\"}"; printf "%s\n" "$TOOL_HOLD_STATUS"' | sed -n 1p)"
[ "$floorput" = 400 ] || fail "E: the floor was written through the policy API: HTTP $floorput"

started="$(docker inspect --format '{{.State.StartedAt}}' "$live-wardryx-1")"
AG=agent://acme.example/lab/one
out="$(lib "tool_hold_allow '$AG' 'ask,browse' 'the gate grants this' ''")"
[ "$(rc_of "$out")" = 0 ] || fail "E: agent-allow was refused: $out"
want "a granted tool" allow "$AG" ask agent-token
want "the agent's tool nothing granted" hold "$AG" fetch_url agent-token
want "a granted name under a static key" deny "$AG" ask client-key
settle
out="$(lib "tool_hold_allow '$AG' 'fetch_url' 'one more' ''")"
want "a second grant keeps the first" allow "$AG" browse agent-token
want "a second grant adds its tool" allow "$AG" fetch_url agent-token
settle
[ "$started" = "$(docker inspect --format '{{.State.StartedAt}}' "$live-wardryx-1")" ] || fail "E: the grant needed a restart"
events="$(docker run --rm -v "${live}_events:/e:ro" busybox:1.36 cat /e/wardryx.ndjson)"
grep -q '"policy_updated"' <<<"$events" || fail "E: agent-allow left no policy_updated on the record"
listed="$(lib "tool_hold_status; tool_hold_print_grants")"
grep -qE '^ +tool hold: on, grants: [0-9]+ in policy.yaml, 1 through agent-allow$' <<<"$listed" || fail "E: status does not say the floor is on and how many grants: $listed"
grep -qF 'one more' <<<"$listed" || fail "E: agent-list does not show the reason in the grant's name"
grep -q "$AG" <<<"$listed" || fail "E: agent-list does not show the grant"
grep -q 'grant-drills' <<<"$listed" || fail "E: agent-list does not show the grants in policy.yaml"
[ "$(lib 'printf "%s\n" "$(tool_hold_loaded)"' | sed -n 1p)" = on ] || fail "E: wardryx's own start record does not say the floor is on"
# A start record 2.6.0 left on the bus names an older start, so it must not decide: one with no floor,
# planted after the real start, leaves the answer on.
docker run --rm -v "${live}_events:/e" busybox:1.36 sh -c 'printf "%s\n" "{\"type\":\"policy_loaded\",\"source\":\"wardryx\",\"data\":{\"no_grant_floors\":[]}}" >>/e/wardryx.ndjson'
[ "$(lib 'printf "%s\n" "$(tool_hold_loaded)"' | sed -n 1p)" = on ] || fail "E: a start record left on the bus by an older wardryx decides what the running one loaded"

# The stop against the real replay: the agent with a stored grant is off the list, the stranger is on it.
st="$scratch/e-old"
mkdir -p "$st/state"
cp "$e/.env" "$st/.env"
cp "$scratch/starter.yaml" "$st/policy.yaml"
out="$(
	cd "$st" && env -i PATH="$scratch/shim:$PATH" HOME="$st" STACK_DIR="$st" STATE="$st/state" LOG="$st/state/log" NET="${live}_core" HTTP_WAIT=1 \
		bash -c ". '$scratch/lib.sh'; tool_hold_resolve; tool_hold_upgrade_check; printf 'passed\n'" 2>&1 || true
)"
grep -q '^passed$' <<<"$out" && fail "E: a real history with an ungranted caller did not stop the run"
grep -qE ' +ask +agent://acme.example/stranger$' <<<"$out" || fail "E: the real replay does not list the stranger: $out"
grep -q ' ask ' <<<"$(grep -F 'agent://acme.example/lab/one' <<<"$out" || true)" && fail "E: a grant written through agent-allow is not in the question, so a granted agent is listed"
cmp -s "$scratch/starter.yaml" "$st/policy.yaml" || fail "E: the stop changed policy.yaml"

out="$(lib "tool_hold_deny '$AG' ask 'the gate takes it back'")"
want "a tool taken back" hold "$AG" ask agent-token
want "the tool left" allow "$AG" browse agent-token
settle
out="$(lib "tool_hold_deny '$AG' all 'gone'")"
want "every tool taken back" hold "$AG" browse agent-token
settle
out="$(lib "tool_hold_allow '$AG' 'ask' 'a static caller' static")"
want "a grant for a static key" allow "$AG" ask client-key
settle
out="$(lib "tool_hold_allow '$AG' all 'all of it' static")"
grep -q 'WARNING' <<<"$out" || fail "E: agent-allow all prints no warning"
want "every tool" allow "$AG" whatever client-key
settle
out="$(lib "tool_hold_deny '$AG' ask 'one of all'")"
grep -q 'holds every tool' <<<"$out" || fail "E: one tool came out of a grant of every tool"

for hostile in 'agent://*/x' 'agent://a*/x' '*' 'stranger' 'agent://a/x"y' 'agent://a/$(id)'; do
	out="$(lib "tool_hold_main agent-allow '$hostile' ask --why 'a reason'" 2>&1 || true)"
	grep -q 'trust domain' <<<"$out" || fail "E: agent-allow took $hostile"
done
for bad in 'a b' 'a;b' '"' ''; do
	out="$(lib "tool_hold_main agent-allow agent://a/b '$bad' --why 'a reason'" 2>&1 || true)"
	grep -q 'takes tools as' <<<"$out" || fail "E: agent-allow took the tool '$bad'"
done
out="$(lib "tool_hold_main agent-allow agent://a/b ask" 2>&1 || true)"
grep -q 'needs --why' <<<"$out" || fail "E: agent-allow went on with no --why"
out="$(lib "tool_hold_main agent-allow agent://a/b ask --why 'a \"quote'" 2>&1 || true)"
grep -q 'needs --why' <<<"$out" || fail "E: a quote in --why reached the JSON"

if grep -qF "$ADMIN" "$scratch/argv.log"; then
	fail "E: a key reached a docker argument list"
fi
[ -s "$scratch/argv.log" ] || fail "E: the shim logged nothing, so no argument list was read"

if [ "$status" = 0 ]; then
	printf 'OK: the floor is on "*", the seeds keep the checks working and hold nothing else, a real replay stops a box with an ungranted caller before anything changes, and one command ends a hold with no restart (invariant 70).\n'
fi
exit "$status"
