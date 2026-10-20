#!/usr/bin/env bash
# Checks that the gates in `scripts/` still FAIL on the faults they exist to
# catch, still PASS on what they must not catch, and REFUSE to report success
# when they measured nothing at all.
#
# WHY
#
# Every gate here parses text, and a text parser does not break loudly: it
# stops matching and reports success. The mutants that proved each one existed
# as prose, in commit messages and in the `*(gate: ...)*` markers in CLAUDE.md,
# which is a record of what was true once. Nothing ran them again.
#
# A gate that has quietly stopped catching anything looks exactly like a gate
# with nothing to catch, and stays that way until the fault it guards ships.
#
# WHY THE THIRD PROPERTY IS SEPARATE FROM THE FIRST
#
# Because here too it found a real hole, the second in the estate on the same
# day, and the same shape as stack-k8s's.
#
# `build-context-complete.sh` printed "OK: 0 build-context path(s) across 5
# Dockerfiles, every one present" and exited 0 when no COPY or ADD source
# matched the `images/` prefix. The count was already only 1, so ONE Dockerfile
# refactor in stack-k8s emptied the check without touching this repository.
# That seam, between two repositories neither of which knows the other exists,
# is the exact thing the gate was written for. Fixed in the commit before this
# one; the case below is what keeps it fixed.
#
# None of the four gates here said anything about measuring nothing before
# today, which is why all four were checked by hand for that property rather
# than trusted.
#
# HOW IT MUTATES WITHOUT LEAVING A MESS
#
# It edits tracked files in place, so it refuses to start unless the tree is
# clean, restores with `git checkout` after every case, restores again from a
# trap on any exit path including a kill, and asserts the tree is clean before
# reporting success.
#
#
# A GATE THAT IS ALREADY FAILING CANNOT BE JUDGED
#
# No case proves anything if the gate was already failing before the mutation.
# So every case runs the gate on the UNMUTATED tree first and reports
# UNJUDGEABLE. Found on 2026-08-09 in it-rat, where one gate was legitimately
# red and a case against it would have been indistinguishable from a working
# one.
#
# It covered only the fail-cases at first, which left the mirror of the same
# bug: on a red gate a pass-case reports OVEREAGER, "the gate failed on
# something it must not catch", and sends the reader to look at a harmless
# mutation. The verdict was being given without the predicate it depends on.
#
# A MUTATION THAT DID NOT APPLY PROVES NOTHING
#
# Every edit asserts it changed the file. A case whose edit applied nothing is
# a failure here, not a pass. That is not hypothetical: five such mutations
# were caught across idryx and tokenfuse on 2026-08-09, and three of the five
# had been verified BY HAND against the same gate minutes earlier. The hand
# version and the harness version differ only in how many layers of quoting sit
# between the text and python, which is exactly the difference nobody sees.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

if [ -n "$(git status --porcelain)" ]; then
	printf 'this script mutates tracked files, so it needs a clean tree.\n'
	printf 'commit or stash first; it restores with `git checkout` and cannot\n'
	printf 'tell your edits from its own.\n'
	exit 1
fi

# Untracked files too: a mutation may RENAME a tracked file, and `git checkout`
# restores the original while leaving the new name behind. And the INDEX, since
# a gate may read `git ls-files` rather than the disk, so a mutation has to move
# the file in both. Safe because this
# script refuses to start unless the tree is clean, so anything untracked
# during a run was created by the run. `-x` is deliberately absent: ignored
# build output is not ours to delete.
# Two cases mutate the stack-k8s TREE rather than this repository, because that
# is what build-context-complete.sh reads. The tree is resolved once here, the
# same three ways the gate itself resolves it, so a run costs at most one fetch
# and every case copies from the same base. On CI there is no sibling checkout,
# so this is the tarball path, which is also what the gate does there.
TEETH_BASE_SRC="${SRC:-}"
if [ -z "$TEETH_BASE_SRC" ] && [ -d ../stack-k8s/images ]; then
	TEETH_BASE_SRC="$(cd ../stack-k8s && pwd)"
fi
if [ -z "$TEETH_BASE_SRC" ]; then
	TEETH_BASE_SRC="$(mktemp -d)"
	if ! curl -fsSL "https://codeload.github.com/TAIPANBOX/stack-k8s/tar.gz/refs/heads/main" |
		tar -xz -C "$TEETH_BASE_SRC" --strip-components=1; then
		printf 'could not fetch the stack-k8s tree, and two cases here mutate it.\n'
		printf 'they would fail for that reason rather than the one they are about,\n'
		printf 'so this refuses rather than reporting on four gates and calling it\n'
		printf 'five. Pass SRC=/path/to/stack-k8s to use a local checkout.\n'
		exit 1
	fi
fi
export TEETH_BASE_SRC

restore() {
	git reset -q --hard HEAD 2>/dev/null
	git clean -fdq 2>/dev/null
}
baseline_dir="$(mktemp -d)"

# One trap for both, because a second `trap ... EXIT` REPLACES the first
# rather than adding to it. Writing them separately disarmed `restore` on
# every interrupt path, which would leave a mutated tree behind on Ctrl-C.
cleanup() {
	restore
	rm -rf "$baseline_dir"
}
trap cleanup EXIT INT TERM


failures=0
cases=0

# run_case <name> <expect: fail|pass> <gate> <python edit> [required output]
#
# The needle separates "it failed" from "it failed for the reason this case is
# about". Without it, a case expecting failure is satisfied by any failure,
# including one this harness caused itself.
run_case() {
	local name="$1" expect="$2" gate="$3" edit="$4" needle="${5:-}"
	# TEETH_ONLY=REGEX runs only the cases whose name matches REGEX (1.4.0): a change runs the cases it
	# touches, and CI runs the whole list. Unset, every case runs, as before.
	if [ -n "${TEETH_ONLY:-}" ] && ! printf '%s' "$name" | grep -q -E -- "$TEETH_ONLY"; then
		return 0
	fi
	cases=$((cases + 1))

	# The baseline applies to EVERY case, not only the ones expecting a failure.
	# It was `fail`-only until 2026-08-09, which left the mirror of the bug it was
	# written for: on a gate that is already red, a `pass` case reports OVEREAGER,
	# "the gate failed on something it must not catch", and sends the reader to
	# look at a harmless mutation while the gate was failing without it. Neither
	# verdict means anything on a red gate, so neither is given.
	skip_baseline=0
	if [ "$expect" = fail_env ]; then
		# `fail` with the baseline skipped, for cases whose fault IS the command
		# rather than a mutation: red before and after is the point there.
		expect=fail
		skip_baseline=1
	fi

	if [ "$skip_baseline" = 0 ]; then
		local key base_out
		key="$baseline_dir/$(printf '%s' "$gate" | cksum | tr -d ' ')"
		if [ ! -f "$key" ]; then
			if eval "$gate" >/dev/null 2>&1; then printf 'green' >"$key"; else printf 'red' >"$key"; fi
		fi
		base_out="$(cat "$key")"
		if [ "$base_out" = red ]; then
			printf 'UNJUDGEABLE  %s\n             the gate is already failing on a clean tree, so neither a\n             failure nor a pass after the mutation would prove anything\n' "$name"
			failures=$((failures + 1))
			return
		fi
	fi

	if ! python3 -c "$edit"; then
		printf 'BROKEN  %s\n        its mutation did not apply, so this case proved nothing\n' "$name"
		failures=$((failures + 1))
		restore
		return
	fi

	local out rc
	out=$(eval "$gate" 2>&1)
	rc=$?
	restore

	# The wording is looked up in a here-string, not `printf | grep -q`: with
	# pipefail on, grep -q exits at its first match, printf can then die of
	# SIGPIPE, and a gate that failed for the right reason is reported as
	# failing for the wrong one (seen 2026-09-30, a pass and then a miss on the
	# same unchanged case).
	# Exit code first, then wording. Checking the needle before the expectation
	# turns "it did not fail at all" into "it failed for the wrong reason",
	# which sends the reader to look at prose when the gate is toothless.
	if [ "$expect" = fail ] && [ "$rc" -ne 0 ] && [ -n "$needle" ] &&
		! grep -qF -- "$needle" <<<"$out"; then
		printf 'WRONG REASON  %s\n              it failed, but not saying: %s\n' "$name" "$needle"
		failures=$((failures + 1))
		return
	fi
	if [ "$expect" = fail ] && [ "$rc" -eq 0 ]; then
		printf 'TOOTHLESS  %s\n           the gate passed on a fault it exists to catch\n' "$name"
		failures=$((failures + 1))
	elif [ "$expect" = pass ] && [ "$rc" -ne 0 ]; then
		printf 'OVEREAGER  %s\n           the gate failed on something it must not catch\n' "$name"
		failures=$((failures + 1))
		printf '%s\n' "$out" | head -4 | sed 's/^/           /'
	else
		printf 'ok  %-58s (%s)\n' "$name" "$expect"
	fi
}

# edit: the first occurrence. edit_all: every one, for a fault that has to reach
# both gateways (the OpenAI door, CLAUDE.md invariant 32, runs the same image and
# command). door: the first occurrence inside the OpenAI door's own block, for a
# fault on the door alone where the gateway carries the same line.
py() { printf 'def edit(p, a, b):\n    s = open(p).read()\n    assert a in s, "pattern not found in " + p\n    open(p, "w").write(s.replace(a, b, 1))\ndef edit_all(p, a, b):\n    s = open(p).read()\n    assert a in s, "pattern not found in " + p\n    open(p, "w").write(s.replace(a, b))\ndef door(a, b):\n    s = open("compose.yaml").read()\n    i = s.index("  tokenfuse-gateway-openai:\\n")\n    assert a in s[i:], "pattern not found in the OpenAI door"\n    open("compose.yaml", "w").write(s[:i] + s[i:].replace(a, b, 1))\n%s\n' "$1"; }

echo "=== faults each gate must catch ==="

# invariant: the gateway binds loopback unless the operator says otherwise.
# Publishing by default makes a security decision on somebody's behalf.
run_case "closed-by-default: the gateway starts binding the world" fail \
	'./scripts/closed-by-default.sh' \
	"$(py 'edit("install.sh", "GATEWAY_BIND=\"${GATEWAY_BIND:-127.0.0.1}\"", "GATEWAY_BIND=\"${GATEWAY_BIND:-0.0.0.0}\"")')" \
	"FAIL"

# invariant: a fetch whose failure is not fatal leaves the machine half-built.
run_case "fail-before-half-the-job: a fetch loses its || die" fail \
	'./scripts/fail-before-half-the-job.sh' \
	"$(py 'edit("install.sh", "  || die \"could not fetch the image definitions from stack-k8s\"", "")')" \
	"|| die"

# invariant 5: every file an image copies is a file this installer fetched.
# This gate reads the stack-k8s TREE rather than install.sh, so the mutation
# copies that tree and removes one copied file. `.teeth-src` is untracked and
# `restore`\x27s `git clean` takes it away after the case.
run_case "build-context-complete: an image copies a file nobody fetched" fail \
	'SRC=$(cat .teeth-src) ./scripts/build-context-complete.sh' \
	"$(py 'import os, re, glob, shutil, tempfile, pathlib
src = os.environ["TEETH_BASE_SRC"]
assert os.path.isdir(src + "/images"), "the resolved stack-k8s tree has no images/"
tmp = tempfile.mkdtemp()
shutil.copytree(src + "/images", tmp + "/images")
removed = 0
for f in sorted(glob.glob(tmp + "/images/*.Dockerfile")):
    for m in re.finditer(r"(?im)^\s*(?:COPY|ADD)\s+(images/\S+)", open(f).read()):
        target = tmp + "/" + m.group(1)
        if os.path.exists(target):
            # A COPY source can be a directory (images/uapi-proxy is one), and
            # os.remove refuses those.
            shutil.rmtree(target) if os.path.isdir(target) else os.remove(target)
            removed += 1
            break
    if removed:
        break
assert removed, "no copied file under images/ to remove"
pathlib.Path(".teeth-src").write_text(tmp)')" \
	"is not in the stack-k8s tarball"

run_case "record-is-not-on-the-bus: the seal gets the bus writable" fail \
	'./scripts/record-is-not-on-the-bus.sh' \
	"$(py 'edit("compose.yaml",
     "# the mount says so rather than the code being trusted to.\n      - events:/var/lib/stack/events:ro",
     "# the mount says so rather than the code being trusted to.\n      - events:/var/lib/stack/events")')" \
	"WRITABLE"

# The failure this gate was actually written for, and the one that looks like
# nothing is wrong: the record kept on the volume its own inputs live in, where
# an operator clearing space on the bus deletes the evidence about it.
run_case "record-is-not-on-the-bus: the record is written to the bus volume" fail \
	'./scripts/record-is-not-on-the-bus.sh' \
	"$(py 'edit("compose.yaml", "      - records:/var/lib/stack/records\n      - ./keyryx/record-seal.key", "      - events:/var/lib/stack/records\n      - ./keyryx/record-seal.key")')" \
	"FAIL"

# Two writers of one store. It takes no cross-process lock, so this is not a
# race that shows up under load; it is two minters of one shard.
run_case "record-is-not-on-the-bus: a second service writes the record store" fail \
	'./scripts/record-is-not-on-the-bus.sh' \
	"$(py 'edit("compose.yaml",
     "      - events:/var/lib/stack/events\n      - ./environments",
     "      - events:/var/lib/stack/events\n      - records:/var/lib/stack/records\n      - ./environments")')" \
	"is also written by"

# invariant 10: the bus has a writer, and every volume a non-root service
# writes has an owner. Both faults were live on every install until 2026-09-13.
run_case "bus-has-a-writer: the gateway stops exporting events" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/tokenfuse.ndjson\n", "")')" \
	"no TOKENFUSE_EVENTS_PATH"

# The control plane's half of the bus (#57): with no TOKENFUSE_EVENTS_PATH
# its detectors stay inside /v1/incidents, and the notifier and the record
# never hear of a budget gone.
run_case "bus-has-a-writer: the control plane stops exporting events" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/tokenfuse-cloud.ndjson\n", "")')" \
	"tokenfuse-cloud sets no TOKENFUSE_EVENTS_PATH"

# Named but not pre-created: uid 10001 with gid 999 cannot create a file in a
# root:10001 2775 directory, the exporter swallows the error, and the variable
# reads as wired while the file never exists.
run_case "bus-has-a-writer: the control plane's file is not pre-created" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "        [ -e /vol/events/tokenfuse-cloud.ndjson ] || : > /vol/events/tokenfuse-cloud.ndjson\n", "")')" \
	"does not pre-create tokenfuse-cloud.ndjson"

# typryx joined the bus 2026-09-26; its writer entry has its own env var name
# (TYPRYX_EVENTS, not TOKENFUSE_EVENTS_PATH) and its own note text, so this
# proves the generalised table still catches its own fault rather than only
# the two money-plane ones it was written for first.
run_case "bus-has-a-writer: typryx stops exporting to the shared bus" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "      TYPRYX_EVENTS: /var/lib/stack/events/typryx.ndjson\n", "")')" \
	"typryx sets no TYPRYX_EVENTS"

# The reader and the writer name different files: idryx would load one file
# forever while the gateway fills another.
run_case "bus-has-a-writer: idryx loads a file the gateway does not write" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "      - tokenfuse:/var/lib/stack/events/tokenfuse.ndjson\n", "      - tokenfuse:/var/lib/stack/events/gateway.ndjson\n")')" \
	"reader and writer disagree"

# The fault as found: a volume a non-root profile writes, never mounted by
# init-volumes, so it comes up root:root 0755 and the service cannot write.
run_case "bus-has-a-writer: a written volume is not mounted by init-volumes" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "      - scopyxevents:/vol/scopyx\n", "")')" \
	"init-volumes never mounts it"

# Mounted but given to the wrong owner: the same symptom with a subtler cause.
run_case "bus-has-a-writer: a volume is owned by somebody else" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "chown -R 65532:65532 /vol/scopyx", "chown 10001:10001 /vol/scopyx")')" \
	"neither the uid nor the gid matches"

# A read-only mount is not a write, and must not be asked for an owner.
run_case "bus-has-a-writer: a read-only mount is left alone" pass \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "      - events:/var/lib/stack/events:ro\n      - heraldyxstate:/var/lib/stack/heraldyx", "      - events:/var/lib/stack/events:ro\n      - pgdata:/var/lib/stack/pgdata-peek:ro\n      - heraldyxstate:/var/lib/stack/heraldyx")')"

# The subject taken away: no gateway service left, and the gate must say it
# measured nothing rather than report OK.
run_case "bus-has-a-writer: no gateway service left to judge" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = s.index("  tokenfuse-gateway:")
j = s.index("\n  # ---- the console")
assert i < j
open("compose.yaml", "w").write(s[:i] + s[j:])')" \
	"measured nothing"

# invariant 11: the operator's bind is honoured end to end. Check 1 probed
# loopback whatever GATEWAY_BIND said, and a healthy appliance bound to its
# tailscale address exited 1 twice (#54, measured 2026-09-17).
run_case "bind-is-honoured: the gateway check probes loopback again" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "http://$GATEWAY_PROBE:4100/healthz", "http://127.0.0.1:4100/healthz")')" \
	"probes 127.0.0.1:4100 whatever GATEWAY_BIND says"

# Every address includes loopback; probing http://0.0.0.0:4100 is a URL, not
# a place, and it happens to work on Linux, which is how it would go unnoticed.
run_case "bind-is-honoured: 0.0.0.0 stops mapping to loopback" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "0.0.0.0) GATEWAY_PROBE=127.0.0.1 ;;", "0.0.0.0) GATEWAY_PROBE=0.0.0.0 ;;")')" \
	"no \`0.0.0.0) GATEWAY_PROBE=127.0.0.1\` arm"

# The must-fail companion taken away: a gateway published wider than the
# operator decided would read as healthy again.
run_case "bind-is-honoured: the loopback refusal is gone" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "  *) check \"gateway is NOT on loopback\" \"! curl -fsS -m3 -o /dev/null http://127.0.0.1:4100/healthz\" ;;\n", "")')" \
	"never shown to refuse loopback"

# The refusal kept, but run for every bind: on the default box it would then
# fail on a gateway that is exactly where it should be.
run_case "bind-is-honoured: the loopback refusal runs for every bind" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "  127.0.0.1|localhost|::1|0.0.0.0) ;;\n  *) check \"gateway is NOT on loopback\"", "  localhost|::1) ;;\n  *) check \"gateway is NOT on loopback\"")')" \
	"no arm that skips both 127.0.0.1 and 0.0.0.0"

# The same invariant, on the host side (#56): a gateway bound to one address
# came back from a reboot as Exited (128) and was never retried, until
# ip_nonlocal_bind and a docker-after-tailscaled drop-in were written by hand.
run_case "bind-is-honoured: the sysctl for a reboot names the wrong key" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "net.ipv4.ip_nonlocal_bind = 1\\n", "net.ipv4.ip_forward = 1\\n")')" \
	"never writes net.ipv4.ip_nonlocal_bind"

# The write kept, the refusal dropped: a box that could not be prepared would
# look installed until its first reboot.
run_case "bind-is-honoured: the sysctl write stops refusing" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "      || die \"could not write /etc/sysctl.d/90-agent-stack-bind.conf: a gateway bound to $GATEWAY_BIND would not come back after a reboot\"", "      || true")')" \
	"has no \`|| die\`"

run_case "bind-is-honoured: docker is no longer ordered after tailscaled" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "[Unit]\\nAfter=tailscaled.service\\nWants=tailscaled.service\\n", "[Unit]\\nWants=tailscaled.service\\n")')" \
	"does not carry After=tailscaled.service"

# The host block run for every bind: the default box would get a sysctl and
# a drop-in it never needed, and a refusal on a box with no /etc/sysctl.d.
run_case "bind-is-honoured: the reboot block runs for every bind" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "  127.0.0.1|localhost|::1|0.0.0.0) ;;\n  *)\n    say \"bind on", "  localhost|::1) ;;\n  *)\n    say \"bind on")')" \
	"no arm that skips both 127.0.0.1 and 0.0.0.0"

# `Started` believed again: the check that asks Docker about the port is gone.
run_case "bind-is-honoured: Started is believed about the port" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "check \"gateway has a port mapping\"", "check \"gateway has a port\"")')" \
	"is believed"

# invariant 11, the probe follows the bind the box HAS (2026-10-13): GATEWAY_PROBE
# was worked out once, before .env was read, so a re-run with GATEWAY_BIND only in
# .env probed loopback on a healthy box published on one other address and
# minted TOKENFUSE_DELEGATION_URL from the same stale value.
run_case "bind-is-honoured: the probe is not recomputed after .env is first read" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "# given (see gateway_probe_resolve at the top).\ngateway_probe_resolve\n", "# given (see gateway_probe_resolve at the top).\n")')" \
	"reads .env and is not followed by gateway_probe_resolve"

run_case "bind-is-honoured: the probe is not recomputed after .env is read again" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "  . ./.env\n  gateway_probe_resolve\nfi\n", "  . ./.env\nfi\n")')" \
	"reads .env and is not followed by gateway_probe_resolve"

run_case "bind-is-honoured: the probe is never worked out before .env is read" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "# gateway-probe: end\ngateway_probe_resolve\n", "# gateway-probe: end\n")')" \
	"before gateway_probe_resolve has ever been called"

run_case "bind-is-honoured: a second copy of the probe mapping appears" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "say()  {", "GATEWAY_PROBE=127.0.0.1\nsay()  {")')" \
	"assigns GATEWAY_PROBE outside gateway_probe_resolve"

run_case "bind-is-honoured: the probe function maps every bind to loopback" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "    *)       GATEWAY_PROBE=\"$GATEWAY_BIND\" ;;", "    *)       GATEWAY_PROBE=127.0.0.1 ;;")')" \
	"gateway_probe_resolve gave"

run_case "bind-is-honoured: the probe function keeps the first bind it saw" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "    *)       GATEWAY_PROBE=\"$GATEWAY_BIND\" ;;", "    *)       GATEWAY_PROBE=\"${GATEWAY_PROBE:-$GATEWAY_BIND}\" ;;")')" \
	"does not follow the bind the box has"

run_case "bind-is-honoured: the probe function is renamed away" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "gateway_probe_resolve() {", "gateway_probe_pick() {")')" \
	"install.sh has no gateway_probe_resolve()"

run_case "bind-is-honoured: the probe function has no markers to lift it by" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "# gateway-probe: begin\n", "# gateway-probe: start\n")')" \
	"no '# gateway-probe: begin'"

# invariant 12: the package step never takes Docker away, and never asks apt
# for what the box already has. On Debian 13 with Docker CE, the distro's
# docker-buildx resolves to `Remv docker-ce` (#55, measured 2026-09-17).
run_case "apt-never-removes-docker: an apt line loses --no-remove" fail \
	'./scripts/apt-never-removes-docker.sh' \
	"$(py 'edit("install.sh", "apt-get install -y -qq --no-remove git curl >/dev/null 2>&1 || true", "apt-get install -y -qq git curl >/dev/null 2>&1 || true")')" \
	"has no --no-remove"

# The guard taken away: buildx asked for on every box that has docker, which
# on a Docker CE box is the exact line that removes it.
run_case "apt-never-removes-docker: buildx is asked for though the box has it" fail \
	'./scripts/apt-never-removes-docker.sh' \
	"$(py 'edit("install.sh", "if ! docker buildx version >/dev/null 2>&1; then", "if true; then")')" \
	"though the box already has it"

# The repository choice taken away: a Docker CE box asked for the distro's
# package, which is the one that conflicts with docker-ce-cli.
run_case "apt-never-removes-docker: a Docker CE box is offered the distro's buildx" fail \
	'./scripts/apt-never-removes-docker.sh' \
	"$(py 'edit("install.sh", "apt-get install -y -qq --no-remove docker-buildx-plugin >/dev/null 2>&1 || true", "apt-get install -y -qq --no-remove docker-buildx >/dev/null 2>&1 || true")')" \
	"expected docker-buildx-plugin"

# invariant 13: the gateway's semantic cache is off, explicitly. Unset,
# tokenfuse defaults it to shadow mode, one global mutex and up to 10,000
# cosine-similarity comparisons on every call (tokenfuse#319).
run_case "gateway-cache-is-off: TOKENFUSE_CACHE goes missing" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_CACHE: \"off\"\n", "")')" \
	"sets no TOKENFUSE_CACHE"

# Turned on rather than removed: the same fault, a different way to arrive at
# it, and the gate has to read the value, not just its presence.
run_case "gateway-cache-is-off: TOKENFUSE_CACHE flips to on" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_CACHE: \"off\"", "TOKENFUSE_CACHE: \"on\"")')" \
	'not "off"'

# The subject taken away: the gateway service renamed out from under the
# check (its image and bare-binary command line are how the gate finds it),
# and it must say it measured nothing rather than report OK on an empty list.
run_case "gateway-cache-is-off: no gateway service left to judge" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit_all("compose.yaml", "command: [\"/usr/local/bin/tokenfuse\"]", "command: [\"/usr/local/bin/tokenfuse\", \"serve\"]")')" \
	"measured NOTHING"

# invariant 19: the gateway's declassify key is minted per install and reaches
# the container from .env. Unset, POST /v1/fuse/declassify is open to anything
# that reaches the port and records only `authenticated: false`.
run_case "declassify-is-keyed: TOKENFUSE_DECLASSIFY_KEY goes missing" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_DECLASSIFY_KEY: ${GATEWAY_DECLASSIFY_KEY:?set by install.sh}\n", "")')" \
	"sets no TOKENFUSE_DECLASSIFY_KEY"

# A literal in the compose file: a key committed to a public repository.
run_case "declassify-is-keyed: the key becomes a literal" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_DECLASSIFY_KEY: ${GATEWAY_DECLASSIFY_KEY:?set by install.sh}", "TOKENFUSE_DECLASSIFY_KEY: change-me")')" \
	"which is not a"

# An empty default: the gateway starts with the endpoint open on any box whose
# .env lacks the variable, which is the fault the key exists to close.
run_case "declassify-is-keyed: the key gets an empty default" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("compose.yaml", "${GATEWAY_DECLASSIFY_KEY:?set by install.sh}", "${GATEWAY_DECLASSIFY_KEY:-}")')" \
	"which is not a"

# The other half: compose reads a variable nothing mints.
run_case "declassify-is-keyed: install.sh stops minting the key" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("install.sh", "add_env_default GATEWAY_DECLASSIFY_KEY \"$(gen 40)\"\n", "")')" \
	"never mints it"

# Minted, but not random: one key for every install is a published key.
run_case "declassify-is-keyed: install.sh mints a fixed key" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("install.sh", "add_env_default GATEWAY_DECLASSIFY_KEY \"$(gen 40)\"", "add_env_default GATEWAY_DECLASSIFY_KEY \"fixed-key\"")')" \
	"not with the gen helper"

# The subject taken away: the gateway service no longer has the shape the gate
# finds it by, and it must say it measured nothing, never OK.
run_case "declassify-is-keyed: no gateway service left to judge" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit_all("compose.yaml", "command: [\"/usr/local/bin/tokenfuse\"]", "command: [\"/usr/local/bin/tokenfuse\", \"serve\"]")')" \
	"measured NOTHING"

# The second subject taken away: no installer to read the mint from.
run_case "declassify-is-keyed: no install.sh left to read" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'import os
os.rename("install.sh", "install.sh.gone")')" \
	"measured NOTHING about"

# invariant: components.json says what this launcher actually installs.
#
# The compose half of the same idea stack-up carries. Two cases: ordinary drift,
# and the reader losing its subject.
run_case "manifest-is-true: a compose service is started and not declared" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json
p = "components.json"
d = json.load(open(p))
c = d["components"][0]["checked"]
before = len(c["installs_services"])
c["installs_services"] = [s for s in c["installs_services"] if s != "caddy"]
assert len(c["installs_services"]) == before - 1, "caddy was not in the declared list"
json.dump(d, open(p, "w"), indent=2)')" \
	"and components.json does not say so"

# The service keys are the names ABOVE the volumes block, so losing that block
# means the reader cannot tell a service from a volume. It must say it measured
# nothing rather than compare two lists it no longer understands.
run_case "manifest-is-true: compose.yaml loses the block that bounds the services" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("compose.yaml", "\nvolumes:", "\nVOLUMES:")')" \
	"measured NOTHING"

# It declares that it schedules nothing, and that has to be checked rather than
# assumed: the day a routine arrives, this file has to say what it runs.
# It declared that it schedules nothing until 2026-08-28, and now declares four.
# Either way the check has to be able to see a routine arrive that the manifest
# does not claim: a governance routine running unrecorded is the same problem in
# both directions.
run_case "manifest-is-true: a routine arrives and the manifest does not claim it" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("install.sh", "say \"building images", "say \"qryx-trend building images")')" \
	"does not"

# A pinned tag bumped in compose.yaml and nowhere else. This is the failure the
# pulls list exists for and it is not hypothetical: the estate has already spent
# a session where one launcher pulled a version another still named, and the
# symptom is a container that works until something restarts it. The mutation
# is one character in one tag, which is exactly how it would arrive.
run_case "manifest-is-true: a pulled tag moves in compose and not in the manifest" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/wardryx:v2.3.0", "ghcr.io/taipanbox/wardryx:v1.0.9")')" \
	"an image it pulls"

# invariant 15: the delegation plane's default is byte-for-byte what it was
# before this plane existed: vouchryx off, and the gateway's six
# TOKENFUSE_DELEGATION_* variables all defaulting to empty.
run_case "delegation-off-by-default: a delegation variable gets a literal default" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_DELEGATION_AUDIENCE: ${TOKENFUSE_DELEGATION_AUDIENCE:-}", "TOKENFUSE_DELEGATION_AUDIENCE: stack-single")')" \
	"not the empty-default form"

run_case "delegation-off-by-default: the profile starts when DELEGATION_ON is not 1" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("install.sh", "if [ \"${DELEGATION_ON:-0}\" = 1 ]; then UP_PROFILES+=(--profile delegation); fi", "[ \"${DELEGATION_ON:-0}\" = 1 ] || UP_PROFILES+=(--profile delegation)")')" \
	"an inverted test that starts vouchryx on a default box"

run_case "delegation-off-by-default: DELEGATION_ON is set to 1 with no switch above it" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("install.sh", "DELEGATION_ON=0          # 1 when vouchryx runs this run: WITH_DELEGATION or agent tokens\n", "DELEGATION_ON=0          # 1 when vouchryx runs this run: WITH_DELEGATION or agent tokens\nDELEGATION_ON=1\n")')" \
	"sets DELEGATION_ON=1 with no WITH_DELEGATION or WITH_AGENT_TOKENS switch"

run_case "delegation-off-by-default: install.sh starts the profile unconditionally" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("install.sh", "if [ \"${DELEGATION_ON:-0}\" = 1 ]; then UP_PROFILES+=(--profile delegation); fi", "UP_PROFILES+=(--profile delegation)")')" \
	"no WITH_DELEGATION guard"

# invariant 26: closing a retained reservation is off by default, and on, the
# gateway and the console hold the same secret bytes, never printed.
run_case "closure-off-by-default: the gateway's secret gets a required form" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_CLOSURE_SECRET: ${CLOSURE_SECRET:-}", "TOKENFUSE_CLOSURE_SECRET: ${CLOSURE_SECRET:?set by install.sh}")')" \
	"not the empty-default form"

run_case "closure-off-by-default: the console's file gets a literal" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("compose.yaml", "GENARYX_CLOSURE_SECRET_FILE: ${CLOSURE_SECRET_FILE:-}", "GENARYX_CLOSURE_SECRET_FILE: /run/closure/secret")')" \
	"not the empty-default"

run_case "closure-off-by-default: install.sh mints the secret unconditionally" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("install.sh", "if [ \"${WITH_CLOSURE:-}\" = \"1\" ]; then", "if true; then")')" \
	"no WITH_CLOSURE guard"

run_case "closure-off-by-default: the console's copy gets a trailing newline" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("install.sh", "printf \x27%s\x27 \"$closure_secret\" >closure/secret.tmp", "printf \x27%s\\n\x27 \"$closure_secret\" >closure/secret.tmp")')" \
	"other than printf"

run_case "closure-off-by-default: the secret is printed" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("install.sh", "  note \"closing retained reservations is on: one secret, in .env and in ./closure/secret\"", "  note \"closing retained reservations is on: one secret, in .env and in ./closure/secret\"\n  note \"the secret is $closure_secret\"")')" \
	"which can print it"

run_case "closure-off-by-default: a comment near it is reworded" pass \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("install.sh", "# the console, with no trailing newline:", "# the console, without a trailing newline:")')"

run_case "closure-off-by-default: no console variable left to judge" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_CLOSURE_SECRET_FILE: ${CLOSURE_SECRET_FILE:-}\n", "")')" \
	"measured nothing"

# The signing key and the revoke key never reach a printed line.
run_case "delegation-key-not-printed: the revoke key is expanded into a print call" fail \
	'./scripts/delegation-key-not-printed.sh' \
	"$(py 'edit("install.sh", "add_env_default VOUCHRYX_REVOKE_KEYS \"$(gen 40)\"", "add_env_default VOUCHRYX_REVOKE_KEYS \"$(gen 40)\"\nnote \"debug: $VOUCHRYX_REVOKE_KEYS\"")')" \
	"expands \$VOUCHRYX_REVOKE_KEYS"

# The signing key and the revoke key are reused, never regenerated, on a
# re-run: installer second-run faults are a known class in this estate.
run_case "delegation-key-reused-on-rerun: the signing key is minted on every run" fail \
	'./scripts/delegation-key-reused-on-rerun.sh' \
	"$(py 'edit("install.sh", "if [ ! -f delegation/signing.pem ]; then", "if true; then")')" \
	"regenerated the signing key"

# The origin the delegation plane is told to check a hand-off proof against has
# to follow the bind in .env on a re-run, not the one the run started with.
run_case "delegation-key-reused-on-rerun: the delegation origin is minted from a stale probe" fail \
	'./scripts/delegation-key-reused-on-rerun.sh' \
	"$(py 'edit("install.sh", "# given (see gateway_probe_resolve at the top).\ngateway_probe_resolve\n", "# given (see gateway_probe_resolve at the top).\n")')" \
	"TOKENFUSE_DELEGATION_URL was minted as http://127.0.0.1:4100"

# invariant 18: typed answers come from the place the operator chose. Each
# case below breaks one thing a wrong default or a careless edit would break,
# and the gate has to say which.
run_case "typed-data-mode: jev stops refusing when it has no key file" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "die \"TYPED_MODE=jev needs TYPED_JEV_KEY_FILE=", "note \"TYPED_MODE=jev needs TYPED_JEV_KEY_FILE=")')" \
	"jev with no key file: it was accepted"

run_case "typed-data-mode: a missing or empty key file is believed" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  [ -n \"$1\" ] && [ -f \"$1\" ] && [ -r \"$1\" ] && LC_ALL=C grep -q \x27[^[:space:]]\x27 \"$1\"", "  true")')" \
	"it was accepted"

run_case "typed-data-mode: a refusal echoes the key it was given" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "die \"TYPED_MODE=jev: TYPED_JEV_KEY_FILE does not name", "die \"TYPED_MODE=jev: TYPED_JEV_KEY_FILE=$TYPED_JEV_KEY_FILE does not name")')" \
	"echoed the key it was given"

run_case "typed-data-mode: installing the key prints it" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "note \"key file installed at $dir/$2 (read only; its contents are never shown)\"", "note \"key file installed at $dir/$2: $(cat \"$1\")\"")')" \
	"bytes were printed"

run_case "typed-data-mode: the key becomes an environment value in .env" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "        [ -z \"${TYPED_JEV_KEY_FILE:-}\" ] || typed_install_key \"$TYPED_JEV_KEY_FILE\" jev-key\n", "        [ -z \"${TYPED_JEV_KEY_FILE:-}\" ] || typed_install_key \"$TYPED_JEV_KEY_FILE\" jev-key\n        typed_set_env TYPRYX_JEV_KEY \"$(cat \"$TYPED_JEV_KEY_FILE\")\"\n")')" \
	"bytes are in .env"

run_case "typed-data-mode: own-model accepts a URL that is not /v1" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  [[ \"$1\" =~ $re ]]", "  true")')" \
	"a URL not ending in /v1: it was accepted"

run_case "typed-data-mode: own-model stops requiring a model name" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "|| die \"TYPED_MODE=own-model needs TYPED_MODEL_NAME", "|| note \"TYPED_MODE=own-model needs TYPED_MODEL_NAME")')" \
	"own-model with no model name: it was accepted"

# The default. A box that set nothing must not acquire a third-party-facing
# service because a default moved.
run_case "typed-data-mode: nothing set installs typryx" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  else\n    mode=off\n  fi", "  else\n    mode=stub\n  fi")')" \
	"nothing set: the plane is"

# Back-compat: WITH_TYPED=1 alone was the stub and stays it.
run_case "typed-data-mode: WITH_TYPED=1 alone stops being the stub" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "    mode=stub\n  else", "    mode=off\n  else")')" \
	"WITH_TYPED=1 alone: the plane is"

run_case "typed-data-mode: the typed profile is brought up unconditionally" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "[ \"$TYPED_PLANE\" = off ]      || UP_PROFILES+=(--profile typed)", "UP_PROFILES+=(--profile typed)")')" \
	"TYPED_PLANE does not decide"

run_case "typed-data-mode: the key directory is mounted writable" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "      - ./typed:/run/typed:ro", "      - ./typed:/run/typed")')" \
	"not a read-only bind"

run_case "typed-data-mode: typryx leaves its profile and is in every install" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "    <<: *restart\n    profiles: [\"typed\"]\n    image: ${TYPRYX_IMAGE", "    <<: *restart\n    image: ${TYPRYX_IMAGE")')" \
	"typryx is in the default set"

# Invariant 2 for this block: a re-run that chose nothing must keep what the
# first run chose. A saved mode that is not read back turns the plane off on
# the next plain `./install.sh`, which looks like an upgrade that removed it.
run_case "typed-data-mode: a re-run forgets the saved mode" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  elif [ \"$TYPED_SAVED_MODE\" = jev ] || [ \"$TYPED_SAVED_MODE\" = own-model ]; then", "  elif false; then")')" \
	"jev re-run with nothing set"

run_case "typed-data-mode: switching mode leaves the old mode's lines" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "        typed_forget_env \"${TYPED_OWNED[@]}\"\n        typed_set_env TYPED_MODE jev", "        typed_set_env TYPED_MODE jev")')" \
	"left the own-model lines"

# The stub is recorded, so a plain re-run keeps it (invariant 18). Each case plants
# the fault that would bring back the downgrade: the stub not written down, a
# saved stub not read back, an explicit off that does not stick, and the same
# read-back for own-model, which had none.
run_case "typed-data-mode: WITH_TYPED=1 stops recording the stub" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "        typed_set_env TYPED_MODE stub", "        :")')" \
	"WITH_TYPED=1 alone: TYPED_MODE='stub' is not the one line written to .env"

run_case "typed-data-mode: a plain re-run forgets a saved stub" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  elif [ -n \"${WITH_TYPED:-}\" ] || [ \"$TYPED_SAVED_MODE\" = stub ]; then", "  elif [ -n \"${WITH_TYPED:-}\" ]; then")')" \
	"stub re-run with nothing set: the plane is"

run_case "typed-data-mode: an explicit TYPED_MODE=off does not stick over a stub" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "      [ \"$TYPED_EXPLICIT\" = 0 ] || typed_set_env TYPED_MODE off", "      :")')" \
	"TYPED_MODE=off over a stub box was not recorded"

run_case "typed-data-mode: a re-run forgets a saved own-model" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  elif [ \"$TYPED_SAVED_MODE\" = jev ] || [ \"$TYPED_SAVED_MODE\" = own-model ]; then", "  elif [ \"$TYPED_SAVED_MODE\" = jev ]; then")')" \
	"own-model re-run with a new URL"

# The training log and the pin (typryx; the log needs v0.3.0 or later, and the
# risk-signal proxy v0.4.0, and v0.4.1 is the pin now). Each case plants the fault the
# matching check in scripts/typed-data-mode.sh exists for.
run_case "typed-data-mode: the training log is on when nobody asked" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  case \"$TYPED_TRAIN\" in\n    1)\n      typed_set_env TYPRYX_TRAINING_DIR", "  case \"$TYPED_TRAIN\" in\n    \"\"|1)\n      typed_set_env TYPRYX_TRAINING_DIR")')" \
	"names a training log in .env"

run_case "typed-data-mode: training is accepted with typryx off" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "  if [ \"$TYPED_TRAIN\" = 1 ] && [ \"$mode\" = off ]; then", "  if false; then")')" \
	"it was accepted, and it must refuse"

run_case "typed-data-mode: a value that is not a switch is believed" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "    *) die \"TYPED_TRAINING must be 1 (log on) or 0 (log off). Nothing was installed.\" ;;", "    *) ;;")')" \
	"TYPED_TRAINING=yes"

run_case "typed-data-mode: TYPED_TRAINING=0 does not turn the log off" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "    0) typed_forget_env TYPRYX_TRAINING_DIR ;;", "    0) : ;;")')" \
	"left TYPRYX_TRAINING_DIR in .env"

run_case "typed-data-mode: switching mode drops the training log" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "TYPRYX_OPENAI_KEY_FILE TYPRYX_TIMEOUT_MS)", "TYPRYX_OPENAI_KEY_FILE TYPRYX_TIMEOUT_MS TYPRYX_TRAINING_DIR)")')" \
	"silently turned the training log off"

run_case "typed-data-mode: compose stops passing the training dir to typryx" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "      TYPRYX_TRAINING_DIR: ${TYPRYX_TRAINING_DIR:-}\n", "")')" \
	"would not reach typryx"

run_case "typed-data-mode: the volume the training log sits on is read only" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "      - typryxdata:/var/lib/typryx\n      # The shared bus, read-write", "      - typryxdata:/var/lib/typryx:ro\n      # The shared bus, read-write")')" \
	"not a writable volume"

run_case "typed-data-mode: the installer points the training log outside the volume" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "typed_set_env TYPRYX_TRAINING_DIR /var/lib/typryx/training", "typed_set_env TYPRYX_TRAINING_DIR /srv/training")')" \
	"did not write TYPRYX_TRAINING_DIR"

run_case "typed-data-mode: no volume is mounted where the training log lives" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "      - typryxdata:/var/lib/typryx\n      # The shared bus, read-write", "      - typryxdata:/var/lib/typryx-data\n      # The shared bus, read-write")')" \
	"no volume holds"

run_case "typed-data-mode: compose still pins a typryx older than the pin" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/typryx:v0.5.0@sha256:c9278289b3722d3e89fd90f4834666c295ee0c83b4b014c0df160500f2b57a20}", "ghcr.io/taipanbox/typryx:v0.2.0}")')" \
	"compose.yaml pins typryx v0.2.0"

run_case "typed-data-mode: components.json keeps the old typryx pin" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("components.json", "ghcr.io/taipanbox/typryx:v0.5.0", "ghcr.io/taipanbox/typryx:v0.2.0")')" \
	"components.json names typryx:v0.2.0"

run_case "typed-data-mode: the README names a typryx tag compose does not pin" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("README.md", "this launcher pins typryx v0.5.0, so it is there", "this launcher pins ghcr.io/taipanbox/typryx:v0.2.0, so it is there")')" \
	"README.md names typryx:v0.2.0"

# ---- run-budget-ceiling (invariant 20): tokenfuse 1.5.0's ceiling is OFF unless
# every gateway sets it, and nothing on a box says so when it is not set.
run_case "run-budget-ceiling: the gateway loses its ceiling" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MAX_RUN_BUDGET_USD: ${RUN_BUDGET_CEILING_USD:-5.00}\n", "")')" \
	"sets no TOKENFUSE_MAX_RUN_BUDGET_USD"

run_case "run-budget-ceiling: the ceiling becomes a literal" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MAX_RUN_BUDGET_USD: ${RUN_BUDGET_CEILING_USD:-5.00}", "TOKENFUSE_MAX_RUN_BUDGET_USD: \"5.00\"")')" \
	"A literal cannot be moved by the"

run_case "run-budget-ceiling: the ceiling reads a variable the installer does not set" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MAX_RUN_BUDGET_USD: ${RUN_BUDGET_CEILING_USD:-5.00}", "TOKENFUSE_MAX_RUN_BUDGET_USD: ${BUDGET_CEILING:-5.00}")')" \
	"A literal cannot be moved by the"

run_case "run-budget-ceiling: the default ceiling drifts" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("compose.yaml", "${RUN_BUDGET_CEILING_USD:-5.00}", "${RUN_BUDGET_CEILING_USD:-50.00}")')" \
	"defaults the ceiling to 50.00"

# Zero is a valid-looking default that tokenfuse refuses to start on.
run_case "run-budget-ceiling: the default ceiling is zero" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("compose.yaml", "${RUN_BUDGET_CEILING_USD:-5.00}", "${RUN_BUDGET_CEILING_USD:-0}")')" \
	"defaults the ceiling to 0"

run_case "run-budget-ceiling: the installer accepts zero" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", " && [[ \"$1\" =~ [1-9] ]]\n", "\n")')" \
	"was accepted, and tokenfuse would exit 2 on it"

# No brace in the pattern: macOS bash 3.2 brace-expands a `{1,12}` inside
# "$(py '...')", the pattern is then not found and the case reads BROKEN.
run_case "run-budget-ceiling: the installer accepts an exponent" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", "  [[ \"$1\" =~ ^[0-9]", "  [[ \"$1\" =~ ^[0-9eE.+-]+$ ]] && return 0\n  [[ \"$1\" =~ ^[0-9]")')" \
	"was accepted, and tokenfuse would exit 2 on it"

run_case "run-budget-ceiling: the refusal echoes the value" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", "die \"RUN_BUDGET_CEILING_USD must be a positive number", "die \"RUN_BUDGET_CEILING_USD=$CEILING_SET must be a positive number")')" \
	"echoed the value"

run_case "run-budget-ceiling: a second figure is appended instead of replacing the first" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", "  { grep -v \"^RUN_BUDGET_CEILING_USD=\" \"$STACK_DIR/.env\" || true; } >\"$tmp\"", "  cat \"$STACK_DIR/.env\" >\"$tmp\"")')" \
	"did not replace the first"

run_case "run-budget-ceiling: a bad ceiling left in .env is accepted" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", "  if [ -n \"$saved\" ] && ! ceiling_valid \"$saved\"; then", "  if false; then")')" \
	"left in .env was accepted"

run_case "run-budget-ceiling: the installer never writes the figure" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", "# The ceiling on a run budget (section 0c): written only when this run set it.\nceiling_apply\n", "# The ceiling on a run budget (section 0c): written only when this run set it.\n")')" \
	"never calls ceiling_resolve and ceiling_apply"

run_case "run-budget-ceiling: no gateway service left to judge" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit_all("compose.yaml", "    command: [\"/usr/local/bin/tokenfuse\"]\n", "    command: [\"/usr/local/bin/tokenfuse\", \"serve\"]\n")')" \
	"measured NOTHING about the run-budget"

run_case "run-budget-ceiling: the installer block is gone" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", "# run-budget-ceiling: begin\n", "# run-budget-ceiling: start\n")')" \
	"measured nothing about the installer's half"

# ---- firewall-is-enforce (invariant 27): tokenfuse ignores a mode it does not
# know and runs shadow, which refuses nothing. Every gateway defaults the
# firewall to enforce, one installer value moves it, and nothing else may.
run_case "firewall-is-enforce: the gateway loses its firewall setting" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_FIREWALL: ${TOKENFUSE_FIREWALL:-enforce}\n", "")')" \
	"sets no TOKENFUSE_FIREWALL"

run_case "firewall-is-enforce: the default becomes shadow" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("compose.yaml", "${TOKENFUSE_FIREWALL:-enforce}", "${TOKENFUSE_FIREWALL:-shadow}")')" \
	"defaults the agent firewall to shadow"

run_case "firewall-is-enforce: the default becomes off" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("compose.yaml", "${TOKENFUSE_FIREWALL:-enforce}", "${TOKENFUSE_FIREWALL:-off}")')" \
	"defaults the agent firewall to off"

run_case "firewall-is-enforce: the setting becomes a literal" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_FIREWALL: ${TOKENFUSE_FIREWALL:-enforce}", "TOKENFUSE_FIREWALL: enforce")')" \
	"A literal cannot be moved by the one installer switch"

run_case "firewall-is-enforce: the setting reads another variable" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_FIREWALL: ${TOKENFUSE_FIREWALL:-enforce}", "TOKENFUSE_FIREWALL: ${FIREWALL_MODE:-enforce}")')" \
	"A literal cannot be moved by the one installer switch"

# A second start is the case a hard-coded name would miss: the subjects come
# from the file, so a new gateway service that defaults to shadow is judged.
run_case "firewall-is-enforce: a second gateway start defaults to shadow" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("compose.yaml", "  tokenfuse-gateway:\n    <<: *restart\n", "  tokenfuse-gateway-canary:\n    image: ${TOKENFUSE_IMAGE:-ghcr.io/taipanbox/tokenfuse:v1.15.0}\n    command: [\"/usr/local/bin/tokenfuse\"]\n    environment:\n      TOKENFUSE_FIREWALL: ${TOKENFUSE_FIREWALL:-shadow}\n  tokenfuse-gateway:\n    <<: *restart\n")')" \
	"defaults the agent firewall to shadow"

run_case "firewall-is-enforce: no gateway service left to judge" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit_all("compose.yaml", "    command: [\"/usr/local/bin/tokenfuse\"]\n", "    command: [\"/usr/local/bin/tokenfuse\", \"serve\"]\n")')" \
	"measured NOTHING about the agent"

run_case "firewall-is-enforce: the installer accepts a value tokenfuse ignores" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("install.sh", "off|shadow|enforce) return 0 ;;\n    *) return 1 ;;", "off|shadow|enforce) return 0 ;;\n    *) return 0 ;;")')" \
	"was accepted, and tokenfuse would refuse to start on it"

run_case "firewall-is-enforce: the installer writes a second line instead of replacing" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("install.sh", "  { grep -v \"^TOKENFUSE_FIREWALL=\" \"$STACK_DIR/.env\" || true; } >\"$tmp\"", "  cat \"$STACK_DIR/.env\" >\"$tmp\"")')" \
	"did not replace the first"

run_case "firewall-is-enforce: a bad mode left in .env is accepted" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("install.sh", "  if [ -n \"$saved\" ] && ! firewall_valid \"$saved\"; then", "  if false; then")')" \
	"left in .env was accepted"

run_case "firewall-is-enforce: the refusal echoes the value" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("install.sh", "die \"TOKENFUSE_FIREWALL must be enforce", "die \"TOKENFUSE_FIREWALL=$FIREWALL_SET must be enforce")')" \
	"echoed the value"

run_case "firewall-is-enforce: the installer block is gone" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("install.sh", "# firewall-mode: begin\n", "# firewall-mode: start\n")')" \
	"measured nothing about the installer's half"

run_case "firewall-is-enforce: the installer never writes the mode" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("install.sh", "(section 0d): written only when this run set it.\nfirewall_apply\n", "(section 0d): written only when this run set it.\n")')" \
	"never calls firewall_resolve and firewall_apply"

# A comment that names the setting and a mode is not the setting.
run_case "firewall-is-enforce: a comment that names shadow is not the setting" pass \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_FIREWALL: ${TOKENFUSE_FIREWALL:-enforce}\n", "      # e.g. TOKENFUSE_FIREWALL: shadow in .env, see the README.\n      TOKENFUSE_FIREWALL: ${TOKENFUSE_FIREWALL:-enforce}\n")')"

# ---- pii-is-shadow (invariant 28): personal data is recorded in shadow by
# default, on the gateway and on the MCP broker, and one installer value moves
# both. tokenfuse refuses to start on an unknown value (v1.12.0 on), and the
# installer must refuse one before a box is touched.
run_case "pii-is-shadow: the gateway loses its PII setting" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}\n", "")')" \
	"sets no TOKENFUSE_DLP_PII"

run_case "pii-is-shadow: the gateway defaults PII detection to off" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}", "TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-off}")')" \
	"defaults PII detection to off"

run_case "pii-is-shadow: the gateway defaults PII detection to block" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}", "TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-block}")')" \
	"defaults PII detection to block"

run_case "pii-is-shadow: the gateway's setting becomes a literal" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}", "TOKENFUSE_DLP_PII: shadow")')" \
	"A literal cannot be moved by the one installer switch"

run_case "pii-is-shadow: the gateway's setting reads another variable" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}", "TOKENFUSE_DLP_PII: ${PII_MODE:-shadow}")')" \
	"A literal cannot be moved by the one installer switch"

run_case "pii-is-shadow: the broker loses its PII setting" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MCP_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}\n", "")')" \
	"sets no TOKENFUSE_MCP_DLP_PII"

run_case "pii-is-shadow: the broker defaults PII detection to off" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MCP_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}", "TOKENFUSE_MCP_DLP_PII: ${TOKENFUSE_DLP_PII:-off}")')" \
	"defaults PII detection to off"

run_case "pii-is-shadow: the broker reads its own switch, not the one the gateway reads" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MCP_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}", "TOKENFUSE_MCP_DLP_PII: ${TOKENFUSE_MCP_DLP_PII:-shadow}")')" \
	"A literal cannot be moved by the one installer switch"

# A second gateway start is the case a hard-coded name would miss: the subjects
# come from the file, so a new gateway that defaults to off is judged.
run_case "pii-is-shadow: a second gateway start defaults to off" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "  tokenfuse-gateway:\n    <<: *restart\n", "  tokenfuse-gateway-canary:\n    image: ${TOKENFUSE_IMAGE:-ghcr.io/taipanbox/tokenfuse:v1.15.0}\n    command: [\"/usr/local/bin/tokenfuse\"]\n    environment:\n      TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-off}\n  tokenfuse-gateway:\n    <<: *restart\n")')" \
	"defaults PII detection to off"

# Both subjects renamed away: nothing is judged, and the gate must say so.
run_case "pii-is-shadow: no gateway and no broker left to judge" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit_all("compose.yaml", "    command: [\"/usr/local/bin/tokenfuse\"]\n", "    command: [\"/usr/local/bin/tokenfuse\", \"serve\"]\n")
edit("compose.yaml", "    command: [\"mcp-broker\"]\n", "    command: [\"mcp-broker\", \"serve\"]\n")')" \
	"measured NOTHING"

run_case "pii-is-shadow: the installer accepts a value tokenfuse reads as off" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("install.sh", "off|shadow|mask|block) return 0 ;;\n    *) return 1 ;;", "off|shadow|mask|block) return 0 ;;\n    *) return 0 ;;")')" \
	"was accepted, and tokenfuse would refuse to start on it"

run_case "pii-is-shadow: the installer writes a second line instead of replacing" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("install.sh", "  { grep -v \"^TOKENFUSE_DLP_PII=\" \"$STACK_DIR/.env\" || true; } >\"$tmp\"", "  cat \"$STACK_DIR/.env\" >\"$tmp\"")')" \
	"did not replace the first"

run_case "pii-is-shadow: a bad value left in .env is accepted" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("install.sh", "  if [ -n \"$saved\" ] && ! pii_valid \"$saved\"; then", "  if false; then")')" \
	"left in .env was accepted"

run_case "pii-is-shadow: the refusal echoes the value" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("install.sh", "die \"TOKENFUSE_DLP_PII must be off", "die \"TOKENFUSE_DLP_PII=$PII_SET must be off")')" \
	"echoed the value"

run_case "pii-is-shadow: the installer block is gone" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("install.sh", "# pii-mode: begin\n", "# pii-mode: start\n")')" \
	"measured nothing about the installer's half"

run_case "pii-is-shadow: the installer never writes the value" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("install.sh", "# The PII switch (section 0e): written only when this run set it.\npii_apply\n", "# The PII switch (section 0e): written only when this run set it.\n")')" \
	"never calls pii_resolve and pii_apply"

# The refusal means nothing was installed only if the check runs before the
# first package install. Moved behind it, a refused value arrives too late.
run_case "pii-is-shadow: the validation runs after the first package install" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("install.sh", "# pii-mode: end\npii_resolve\n", "# pii-mode: end\n")
edit("install.sh", "  apt-get update -qq\n", "  apt-get update -qq\npii_resolve\n")')" \
	"runs after the first package install"

# A comment that names the setting and a mode is not the setting.
run_case "pii-is-shadow: a comment that names off is not the setting" pass \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}\n", "      # e.g. TOKENFUSE_DLP_PII: off in .env, see the README.\n      TOKENFUSE_DLP_PII: ${TOKENFUSE_DLP_PII:-shadow}\n")')"

# ---- identity-files-are-checked (invariant 29): client keys and the identity
# map come in as files, are read by the gateway image before anything restarts,
# and survive a re-run. Several cases run the real gateway image, so each takes
# a few seconds. A single quote inside a mutation is written \x27: the python
# sits inside a shell single-quoted string.
run_case "identity-files: the gateway loses its client keys setting" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:?set by install.sh, which mints them when no keys file is given}\n", "")')" \
	"sets no TOKENFUSE_CLIENT_KEYS"

# Invariant 35 turned this case around: the gateway every box runs requires its keys,
# so an empty default is the fault now (a box whose .env lost them would answer anyone).
run_case "identity-files: the gateway's client keys get an empty default" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:?set by install.sh, which mints them when no keys file is given}", "TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:-}")')" \
	"not \${GATEWAY_CLIENT_KEYS:?...}"

run_case "identity-files: the gateway loses its identity map setting" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_IDENTITY_MAP: ${GATEWAY_IDENTITY_MAP:-}\n", "")')" \
	"sets no TOKENFUSE_IDENTITY_MAP"

run_case "identity-files: the map is mounted writable" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("compose.yaml", "      - ./identity:/etc/tokenfuse/identity:ro\n", "      - ./identity:/etc/tokenfuse/identity\n")')" \
	"The gateway reads the map and must"

run_case "identity-files: another service is handed the client keys" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n      TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:-}\n")')" \
	"console names GATEWAY_CLIENT_KEYS"

run_case "identity-files: no gateway service left to judge" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit_all("compose.yaml", "    command: [\"/usr/local/bin/tokenfuse\"]\n", "    command: [\"/usr/local/bin/tokenfuse\", \"serve\"]\n")')" \
	"measured NOTHING about client keys"

run_case "identity-files: the map path in .env is not the file inside the mount" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "IDENTITY_MAP_PATH=/etc/tokenfuse/identity/identity.json  #", "IDENTITY_MAP_PATH=/etc/tokenfuse/identity.json  #")')" \
	"which is not the file inside"

run_case "identity-files: the installer accepts a short secret" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "elif [ \"${#secret}\" -lt 24 ]", "elif [ \"${#secret}\" -lt 2 ]")')" \
	"(a secret of 23 characters) was accepted"

run_case "identity-files: the installer lets a quote or a dollar into a secret" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "re_chars=\x27^[A-Za-z0-9._~+/=@:-]+$\x27", "re_chars=\x27^[^[:space:]]+$\x27")')" \
	"(a secret with a quote) was accepted"

run_case "identity-files: the installer keeps a secret given twice" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", ") die \"$ID_KEYS_FILE_VAR: line $n gives a secret", ") note \"$ID_KEYS_FILE_VAR: line $n gives a secret")')" \
	"(a secret given twice) was accepted"

run_case "identity-files: a refusal repeats the secret" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "die \"$ID_KEYS_FILE_VAR: line $n $why.", "die \"$ID_KEYS_FILE_VAR: line $n ($line) $why.")')" \
	"repeats the secret"

run_case "identity-files: a keys file of comments alone is accepted" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "[ \"$count\" -gt 0 ] || die", "[ \"$count\" -ge 0 ] || die")')" \
	"(comments and blank lines only) was accepted"

run_case "identity-files: a NUL byte in a file is let through" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "printf \x27names a file holding a NUL byte\x27; return 0;", ":;")')" \
	"(a NUL byte) was accepted"

run_case "identity-files: a map that is not a JSON object passes the first half" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "[ \"$first\" = \"{\" ] || die", "[ -n \"$first\" ] || die")')" \
	"(a JSON array, not an object) was accepted"

run_case "identity-files: a bad key left in .env is accepted on a re-run" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "[ -z \"$why\" ] || die \".env holds a $ID_KEYS_ENV whose", "[ -z \"$why\" ] || note \".env holds a $ID_KEYS_ENV whose")')" \
	"with a short secret was accepted"

run_case "identity-files: the gateway's own refusal is not heard" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "    *\"tokenfuse gateway listening\"*) ;;\n", "    *) ;;\n")')" \
	"refused, but not saying: not declared in units[]"

run_case "identity-files: a map that configures nothing is accepted" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "grep -qF \x27identity map: ON (\x27 <<<\"$logs\" || {", "true || {")')" \
	"a map that configures nothing ({}) was accepted"

run_case "identity-files: a map that binds a key with no secret is accepted" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "  if [ -n \"$orphans\" ]; then", "  if false; then")')" \
	"a map that binds a key id no client key carries was accepted"

run_case "identity-files: a client key the map does not bind is accepted" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "  if [ -n \"$unbound\" ]; then", "  if false; then")')" \
	"a client key the map does not bind was accepted"

run_case "identity-files: the keys are written into .env unquoted" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "printf \"%s=\x27%s\x27\\n\" \"$1\" \"$2\" >>\"$tmp\"", "printf \"%s=%s\\n\" \"$1\" \"$2\" >>\"$tmp\"")')" \
	"has to be quoted"

run_case "identity-files: a new file adds a second line instead of replacing" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "  { grep -v \"^$1=\" \"$STACK_DIR/.env\" || true; } >\"$tmp\"\n  printf \"%s=\x27%s\x27\\n\" \"$1\" \"$2\"", "  cat \"$STACK_DIR/.env\" >\"$tmp\"\n  printf \"%s=\x27%s\x27\\n\" \"$1\" \"$2\"")')" \
	"did not REPLACE"

run_case "identity-files: a re-run that names no file loses the kept keys" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "[ \"$IDENTITY_KEYS_GIVEN\" = 1 ] || spec=\"$(identity_env_get \"$ID_KEYS_ENV\")\"", "[ \"$IDENTITY_KEYS_GIVEN\" = 1 ] || spec=\"\"")')" \
	"a re-run that names no file was refused"

run_case "identity-files: the same map again restarts the gateway" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "    if cmp -s \"$stage/identity.json\" \"$STACK_DIR/$ID_DIR/identity.json\"; then", "    if false; then")')" \
	"the same map given again was installed as a change"

run_case "identity-files: the map is installed writable" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "chmod 0444 \"$stage/identity.json\"", "chmod 0644 \"$stage/identity.json\"")')" \
	"the installed map is not 0444"

run_case "identity-files: the files are checked after a package is installed" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "door_resolve\nidentity_door main\nidentity_resolve\n", "door_resolve\nidentity_door main\n"); edit("install.sh", "|| die \"docker did not start.\"\n", "|| die \"docker did not start.\"\nidentity_resolve\n")')" \
	"runs after the first package install"

run_case "identity-files: the gateway reads the files after the stack starts" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "identity_check \"$IDENTITY_IMAGE\"\n", ""); edit("install.sh", "say \"verify\"\n", "identity_check \"$IDENTITY_IMAGE\"\nsay \"verify\"\n")')" \
	"runs after the stack starts"

run_case "identity-files: the installer never asks the gateway image" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "identity_check \"$IDENTITY_IMAGE\"\n", "\n")')" \
	"block is dead text"

run_case "identity-files: the check gives the image no command" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "\"$img\" /usr/local/bin/tokenfuse >/dev/null", "\"$img\" >/dev/null")')" \
	"the shape BUILD_FROM_SOURCE builds, could not check"

run_case "identity-files: a new map does not restart the gateway" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "\"${COMPOSE[@]}\" restart tokenfuse-gateway >/dev/null", "\"${COMPOSE[@]}\" ps tokenfuse-gateway >/dev/null")')" \
	"does not restart tokenfuse-gateway"

run_case "identity-files: section 8 stops asking the running gateway" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "check \"client keys: a call with no key is refused\"", "check \"client keys: configured\"")')" \
	"section 8 no longer asks"

run_case "identity-files: the end of the run stops naming the header" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "  x-fuse-key header (the secret", "  client key header (the secret")')" \
	"which headers an agent sends"

run_case "identity-files: the installer block is gone" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "# identity-files: begin\n", "# identity-files: start\n")')" \
	"measured nothing about the installer's half"

# A comment that names a required form of the setting is not the setting, and a
# reworded refusal still refuses.
run_case "identity-files: a comment that names another form of the setting is not the setting" pass \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:?set by install.sh, which mints them when no keys file is given}\n", "      # never TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:-}, which answers anyone.\n      TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:?set by install.sh, which mints them when no keys file is given}\n")')"

run_case "identity-files: a reworded refusal still refuses" pass \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "Each line is secret:key_id. Nothing was installed.", "Each line holds one secret:key_id. Nothing was installed.")')"

# invariant 30: a check reports the box, not which of a producer and its reader
# finished first. `grep -q` exits at its first match, `docker compose logs` is
# still writing, exits 255 on the closed pipe, and under pipefail a healthy box
# read FAIL (measured 2026-10-13) and a negated check read ok with the bad line
# present. Each case breaks one thing a careless edit would break.
run_case "checks-survive-a-closed-pipe: check() counts a producer's broken pipe again" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "( set +o pipefail; eval \"$2\" ) >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; else", "eval \"$2\" >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; else")')" \
	"reported ok although the log holds the line the install must refuse"

run_case "checks-survive-a-closed-pipe: check_log() counts a producer's broken pipe again" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "( set +o pipefail; eval \"$2\" ) >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; return 0; fi", "eval \"$2\" >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; return 0; fi")')" \
	"reported FAIL although its line is there"

# The over-correction: a "fix" that makes every check ok would pass a gate that
# only looked at healthy boxes.
run_case "checks-survive-a-closed-pipe: check() reports ok on anything" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "( set +o pipefail; eval \"$2\" ) >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; else", "( set +o pipefail; eval \"$2\" || true ) >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; else")')" \
	"reported ok although the log holds the line the install must refuse"

run_case "checks-survive-a-closed-pipe: check_log() reports ok on anything" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "( set +o pipefail; eval \"$2\" ) >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; return 0; fi", "( set +o pipefail; eval \"$2\" || true ) >/dev/null 2>&1; then printf \x27   ok    %s\\n\x27 \"$1\"; return 0; fi")')" \
	"reported ok although the log holds nothing it looks for"

run_case "checks-survive-a-closed-pipe: compose_has pipes the list into grep again" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "  local out\n  out=\"$(\"${COMPOSE[@]}\" ps --services 2>/dev/null)\" || return 1\n  grep -qx -- \"$1\" <<<\"$out\"\n", "  \"${COMPOSE[@]}\" ps --services 2>/dev/null | grep -qx -- \"$1\"\n")')" \
	"compose_has console said"

run_case "checks-survive-a-closed-pipe: a service test goes back to the pipe" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "if compose_has tokenfuse-mcp-broker; then", "if \"${COMPOSE[@]}\" ps --services 2>/dev/null | grep -qx tokenfuse-mcp-broker; then")')" \
	"pipes \`compose logs\` or \`compose ps\` into an early-exit reader"

run_case "checks-survive-a-closed-pipe: a log check is added with no case" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "check \"cloud answers inside\"", "check_log \"extra log check\" \"$DC logs wardryx 2>&1 | grep -q x\"\ncheck \"cloud answers inside\"")')" \
	"has no case in this gate"

run_case "checks-survive-a-closed-pipe: a log check is renamed" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "check_log \"gateway exports agent events\"", "check_log \"gateway exports events\"")')" \
	"install.sh has no check named that any more"

run_case "checks-survive-a-closed-pipe: the check helpers have no markers to lift them by" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "# check-helpers: begin\n", "# check-helpers: start\n")')" \
	"measured nothing"

run_case "checks-survive-a-closed-pipe: compose_has has no markers to lift it by" fail \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "# compose-has: begin\n", "# compose-has: start\n")')" \
	"measured nothing"

# ---- gen-is-bounded (invariant 31): a secret is minted from a bounded read, so
# minting one ends on its own with SIGPIPE ignored, as under git's pre-push hook.
# The line install.sh had until 2026-10-14, put back.
run_case "gen-is-bounded: install.sh's gen reads /dev/urandom with no bound again" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "v=\"$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc \x27A-Za-z0-9\x27)\" || v=\"\"", "v=\"$( set +o pipefail; LC_ALL=C tr -dc \x27A-Za-z0-9\x27 </dev/urandom | head -c \"$n\" )\"")')" \
	"reads /dev/urandom with no bound"

# The copy delegation-key-reused-on-rerun.sh carried, which hung the hook.
run_case "gen-is-bounded: a gate mints with its own unbounded copy again" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("scripts/delegation-key-reused-on-rerun.sh", "# pre-push hook).\n. \"$3\"\n", "# pre-push hook).\ngen() { LC_ALL=C tr -dc \x27A-Za-z0-9\x27 </dev/urandom | head -c \"${1:-40}\"; }\n")')" \
	"scripts/delegation-key-reused-on-rerun.sh:"

# Any reader taken to the end of a stream that has none, not only tr.
run_case "gen-is-bounded: the urandom read goes through cat" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "v=\"$(head -c 4096 /dev/urandom | LC_ALL=C", "v=\"$(cat /dev/urandom | head -c 4096 | LC_ALL=C")')" \
	"reads /dev/urandom with no bound"

# A bound too small for the longest secret install.sh asks for.
run_case "gen-is-bounded: the read is too small for the longest secret" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "v=\"$(head -c 4096 /dev/urandom |", "v=\"$(head -c 64 /dev/urandom |")')" \
	"could not generate"

run_case "gen-is-bounded: gen prints the same value every time" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "  v=\"${v:0:$n}\"\n", "  v=\"$(printf \x27%*s\x27 \"$n\" \"\" | tr \" \" a)\"\n")')" \
	"the same value twice"

run_case "gen-is-bounded: gen leaves the alphabet" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "LC_ALL=C tr -dc \x27A-Za-z0-9\x27)\" || v=\"\"", "LC_ALL=C tr -dc \x27A-Za-z0-9!\x27)\" || v=\"\"")')" \
	"not exactly"

run_case "gen-is-bounded: install.sh defines no gen" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "# gen: begin\ngen() {", "# gen: begin\nmint() {")')" \
	"measured NOTHING"

run_case "gen-is-bounded: install.sh asks gen for no length" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 's = open("install.sh").read()
assert "$(gen " in s, "no caller of gen in install.sh"
open("install.sh", "w").write(s.replace("$(gen ", "$(mint "))')" \
	"measured NOTHING"

run_case "delegation-key-reused-on-rerun: install.sh's gen has no markers to lift it by" fail \
	'./scripts/delegation-key-reused-on-rerun.sh' \
	"$(py 'edit("install.sh", "# gen: begin\n", "# gen: start\n")')" \
	"measured NOTHING"

# ---- chain-verifier (invariant 21): the account is the whole containment.
run_case "chain-verifier: the verifier gets a group_add" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "      - \"10001\"\n    command:\n      - watch-dir", "      - \"10001\"\n      - \"20010\"\n    command:\n      - watch-dir")')" \
	"group_add is"

run_case "chain-verifier: the verifier joins the bus group" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "    user: \"10002:10002\"", "    user: \"10002:10001\"")')" \
	"is the bus group"

run_case "chain-verifier: the verifier takes a plane's uid" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "    user: \"10002:10002\"", "    user: \"65532:10002\"")')" \
	"one of the bus's writer uids"

run_case "chain-verifier: its state moves onto the bus" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "      - /var/lib/agent-conform/state.json\n", "      - /var/lib/stack/events/state.json\n")')" \
	"is inside the bus directory"

run_case "chain-verifier: its stream is named for something else" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "      - /var/lib/stack/events/agent-conform.ndjson\n", "      - /var/lib/stack/events/verifier.ndjson\n")')" \
	"it must be a file named agent-conform.ndjson"

run_case "chain-verifier: init-volumes stops pre-creating its stream" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "        [ -e /vol/events/agent-conform.ndjson ] || : > /vol/events/agent-conform.ndjson\n", "")')" \
	"does not pre-create agent-conform.ndjson"

run_case "chain-verifier: its stream becomes group-writable" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "chmod 0640 /vol/events/agent-conform.ndjson", "chmod 0664 /vol/events/agent-conform.ndjson")')" \
	"writable by group or other"

run_case "chain-verifier: its stream is given to another uid" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "chown 10002:10001 /vol/events/agent-conform.ndjson", "chown 10001:10001 /vol/events/agent-conform.ndjson")')" \
	"gives agent-conform.ndjson to 10001:10001"

run_case "chain-verifier: its state volume has no owner" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "        chown -R 10002:10002 /vol/conform && chmod 0775 /vol/conform\n", "")')" \
	"does not chown /vol/conform"

run_case "chain-verifier: another plane is told to write its stream" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "TYPRYX_EVENTS: /var/lib/stack/events/typryx.ndjson", "TYPRYX_EVENTS: /var/lib/stack/events/agent-conform.ndjson")')" \
	"names agent-conform.ndjson"

run_case "chain-verifier: its root filesystem becomes writable" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "    read_only: true\n    cap_drop:\n      - ALL\n    security_opt:\n      - no-new-privileges:true\n    volumes:\n      - events:/var/lib/stack/events\n      - conformstate", "    cap_drop:\n      - ALL\n    security_opt:\n      - no-new-privileges:true\n    volumes:\n      - events:/var/lib/stack/events\n      - conformstate")')" \
	"root filesystem is not read_only"

run_case "chain-verifier: its image is unpinned" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/agent-conform:v2.0.1@sha256:445608e976247b94f4c3877541fdd4ae3f2aa623b18365ee7215a99f75b85e4c}", "ghcr.io/taipanbox/agent-conform:latest}")')" \
	"is not pinned to a released"

run_case "chain-verifier: its loop is removed" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "      - -every\n      - 5m\n", "")')" \
	"-every is missing"

run_case "chain-verifier: no verifier service left to judge" fail \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "${AGENT_CONFORM_IMAGE:-ghcr.io/taipanbox/agent-conform:v2.0.1@sha256:445608e976247b94f4c3877541fdd4ae3f2aa623b18365ee7215a99f75b85e4c}", "${AGENT_CONFORM_IMAGE:-registry.invalid/agent-conform}")')" \
	"measured NOTHING about the chain verifier"

# The bus gate's own half: a shared volume is written through ONE FILE a service
# owns, so a file given to nobody it runs as is a volume nobody can write.
run_case "bus-has-a-writer: the verifier's stream is given to no one it runs as" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "chown 10002:10001 /vol/events/agent-conform.ndjson", "chown 10003:10003 /vol/events/agent-conform.ndjson")')" \
	"no file under it is given to 10002"

# ---- record-is-signed-by-keyryx (CLAUDE.md invariant 59) ------------------
run_case "record-is-signed-by-keyryx: the seal does not sign through keyryx" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("compose.yaml", "      TRAILRYX_SIGNER: keyryx\n", "")')" \
	"resolves TRAILRYX_SIGNER"

run_case "record-is-signed-by-keyryx: the witness reads no records" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("compose.yaml", "      KEYRYX_WITNESS_RECORDS: acme|/var/lib/stack/records\n", "")')" \
	"resolves KEYRYX_WITNESS_RECORDS"

run_case "record-is-signed-by-keyryx: the credential is readable by every user" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("install.sh", "chmod 0400 \"$key\"; }", "chmod 0444 \"$key\"; }")')" \
	"not set mode 0400"

run_case "record-is-signed-by-keyryx: the credential is written with a newline" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("install.sh", "printf '"'"'%s'"'"' \"$(gen 48)\"", "printf '"'"'%s\n'"'"' \"$(gen 48)\"")')" \
	"trailing newline"

run_case "record-is-signed-by-keyryx: the custody holds the socket, not the digest" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("install.sh", "\"key_digest\": \"__RECORD_SEAL_DIGEST__\"", "\"socket\": \"record-seal\"")')" \
	"digest is not the sha256"

run_case "record-is-signed-by-keyryx: the root pin is set before it is released" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("compose.yaml", "      TRAILRYX_KEYRYX_CREDENTIAL_FILE: /run/keyryx/record-seal.key\n", "      TRAILRYX_KEYRYX_CREDENTIAL_FILE: /run/keyryx/record-seal.key\n      TRAILRYX_KEYRYX_KID: pinned-fake\n")')" \
	"sets TRAILRYX_KEYRYX_KID"

run_case "record-is-signed-by-keyryx: the credential is printed when it is minted" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("install.sh", "mv -f \"$tmp\" \"$key\" || die \"could not put the record seal", "mv -f \"$tmp\" \"$key\" && cat \"$key\" || die \"could not put the record seal")')" \
	"prints the credential"

run_case "record-is-signed-by-keyryx: the seal reads attestations that keyryx writes 0600" fail \
	'./scripts/record-is-signed-by-keyryx.sh' \
	"$(py 'edit("compose.yaml", "      TRAILRYX_KEYRYX_CREDENTIAL_FILE: /run/keyryx/record-seal.key\n", "      TRAILRYX_KEYRYX_CREDENTIAL_FILE: /run/keyryx/record-seal.key\n      TRAILRYX_WITNESS_ATTESTATIONS: /var/lib/keyryx-witness/attestations\n")')" \
	"sets TRAILRYX_WITNESS_ATTESTATIONS"

# ---- approver-key-is-wired (CLAUDE.md invariant 58) -----------------------
run_case "approver-key-is-wired: the approver key is not PKCS#8" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("install.sh", "openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out \"$tmp\"", "openssl ecparam -name prime256v1 -genkey -noout -out \"$tmp\"")')" \
	"not PKCS#8"

run_case "approver-key-is-wired: the approver key is left world-readable" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("install.sh", "chmod 0600 \"$key\"; } || die", "chmod 0644 \"$key\"; } || die")')" \
	"is mode 644, not 600"

run_case "approver-key-is-wired: a re-run replaces the approver key" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("install.sh", "  if [ -s \"$key\" ]; then", "  if false; then")')" \
	"replaced the approver key"

run_case "approver-key-is-wired: the key set is switched on without a console that can print it" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("install.sh", "2>/dev/null)\" \\\n     && printf '"'"'%s'"'"' \"$json\" | grep -q '"'"'\"keys\"'"'"'; then", "2>/dev/null; true)\" \\\n     ; then")')" \
	"turned the approver check on"

run_case "approver-key-is-wired: the bare-key switch is set" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("compose.yaml", "      WARDRYX_APPROVER_JWKS: ${WARDRYX_APPROVER_JWKS:-}\n", "      WARDRYX_APPROVER_JWKS: ${WARDRYX_APPROVER_JWKS:-}\n      WARDRYX_ALLOW_KEY_APPROVALS: \"1\"\n")')" \
	"WARDRYX_ALLOW_KEY_APPROVALS"

run_case "approver-key-is-wired: wardryx is pinned back to 2.3.0" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("compose.yaml", "wardryx:v2.4.0@sha256:8a110dec", "wardryx:v2.3.0@sha256:8a110dec")')" \
	"does not pin wardryx to v2.4.0"

run_case "approver-key-is-wired: the console loses its key mount" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("compose.yaml", "      - ./approver:/run/approver:ro\n", "")')" \
	"does not mount ./approver"

run_case "approver-key-is-wired: the private key reaches wardryx" fail \
	'./scripts/approver-key-is-wired.sh' \
	"$(py 'edit("compose.yaml", "      - ./approver-public:/etc/wardryx/approver:ro\n", "      - ./approver-public:/etc/wardryx/approver:ro\n      - ./approver:/run/approver:ro\n")')" \
	"private approver key reaches wardryx"

# ---- costcrew-runner-spends-through-the-gateway (CLAUDE.md invariant 57) -----
run_case "costcrew-runner-spends-through-the-gateway: the runner starts with the add-on's profile" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "profiles: [\"crew\"]", "profiles: [\"finops\", \"crew\"]")')" \
	"--profile finops renders the runner"

run_case "costcrew-runner-spends-through-the-gateway: the runner joins the edge network" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "    networks:\n      - agents\n    user: \"10003:10003\"\n    restart: \"no\"", "    networks:\n      - agents\n      - edge\n    user: \"10003:10003\"\n    restart: \"no\"")')" \
	"the runner is on"

run_case "costcrew-runner-spends-through-the-gateway: the runner holds a provider key" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      ANTHROPIC_API_KEY: ${GATEWAY_COSTCREW_KEY:-}\n", "      OPENROUTER_API_KEY: ${GATEWAY_COSTCREW_KEY:-}\n      ANTHROPIC_API_KEY: ${GATEWAY_COSTCREW_KEY:-}\n")')" \
	"a credential it must not hold"

run_case "costcrew-runner-spends-through-the-gateway: the runner loses its gateway" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      - -gateway\n      - http://tokenfuse-gateway:4100\n      - -stack-events", "      - -stack-events")')" \
	"would leave the box"

run_case "costcrew-runner-spends-through-the-gateway: the default ceiling spends" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "${COSTCREW_CEILING:-0}", "${COSTCREW_CEILING:-25}")')" \
	"must spend nothing"

run_case "costcrew-runner-spends-through-the-gateway: the runner runs live" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      - -due\n      - -data\n      - /var/lib/costcrew\n      # The ceiling", "      - -due\n      - -live\n      - -data\n      - /var/lib/costcrew\n      # The ceiling")')" \
	"passes -live"

run_case "costcrew-runner-spends-through-the-gateway: the runner writes the console's stream" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      - http://tokenfuse-gateway:4100\n      # No -stack-events", "      - http://tokenfuse-gateway:4100\n      - -stack-events\n      - /var/lib/stack/events/costcrew.ndjson\n      # No -stack-events")')" \
	"writes an events stream"

run_case "costcrew-runner-spends-through-the-gateway: the crew's key is minted on a zero ceiling" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "case \"${COSTCREW_CEILING_SET:-0}\" in *[1-9]*) costcrew_on=1 ;; esac", "costcrew_on=1")')" \
	"only when the ceiling is above 0"

run_case "costcrew-runner-spends-through-the-gateway: the crew's key is kept on a zero ceiling" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "mint_env_forget GATEWAY_COSTCREW_KEY", ":")')" \
	"drop GATEWAY_COSTCREW_KEY on a zero ceiling"

run_case "costcrew-runner-spends-through-the-gateway: the ceiling test accepts zero" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "*[1-9]*) costcrew_on=1", "*[0-9]*) costcrew_on=1")')" \
	"only when the ceiling is above 0"

run_case "costcrew-runner-spends-through-the-gateway: the ceiling accepts a sign" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "costcrew_ceiling_valid() { # VALUE", "costcrew_ceiling_valid() { return 0; # VALUE")')" \
	"is accepted"

run_case "costcrew-runner-spends-through-the-gateway: the crew's key is not minted" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "  mint_env_secret GATEWAY_COSTCREW_KEY\n", "")')" \
	"does not mint GATEWAY_COSTCREW_KEY"

run_case "costcrew-runner-spends-through-the-gateway: the crew's key is bound to every agent" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "agents\": [\"agent://%s/costcrew/*\"]}", "agents\": [\"agent://%s/*\"]}")')" \
	"does not bind the crew"

run_case "costcrew-runner-spends-through-the-gateway: the console is given a gateway" fail \
	'./scripts/costcrew-runner-spends-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      - -insecure-http\n", "      - -gateway\n      - http://tokenfuse-gateway:4100\n      - -insecure-http\n")')" \
	"the console carries -gateway"

# ---- console-password-is-not-printed (CLAUDE.md invariant 56) ----------------
run_case "console-password-is-not-printed: the password file is made without umask 077" fail \
	'./scripts/console-password-is-not-printed.sh' \
	"$(py 'edit("install.sh", "( umask 077; { gen 28", "( umask 022; { gen 28")')" \
	"does not make its file under umask 077"

run_case "console-password-is-not-printed: the password file is not set 0600" fail \
	'./scripts/console-password-is-not-printed.sh' \
	"$(py 'edit("install.sh", "{ chmod 0600 \"$tmp\"", "{ chmod 0644 \"$tmp\"")')" \
	"does not set its file 0600"

run_case "console-password-is-not-printed: the closing report names the value again" fail \
	'./scripts/console-password-is-not-printed.sh' \
	"$(py 'edit("install.sh", "      user      $CONSOLE_USER\n      file      $CONSOLE_SIGNIN_FILE", "      user      $CONSOLE_USER\n      password  $CONSOLE_PASSWORD\n      file      $CONSOLE_SIGNIN_FILE")')" \
	"still names CONSOLE_PASSWORD"

run_case "console-password-is-not-printed: set-password takes the password on an argument list" fail \
	'./scripts/console-password-is-not-printed.sh' \
	"$(py 'edit("install.sh", "set-password --username \"$CONSOLE_USER\" <\"$STACK_DIR/console-password\" >", "set-password --username \"$CONSOLE_USER\" \"$(cat \"$STACK_DIR/console-password\")\" >")')" \
	"passes a command substitution"

run_case "console-password-is-not-printed: the helper prints the password it writes" fail \
	'./scripts/console-password-is-not-printed.sh' \
	"$(py 'edit("install.sh", "{ chmod 0600 \"$tmp\" && mv -f \"$tmp\" \"$1\"; }", "{ chmod 0600 \"$tmp\" && mv -f \"$tmp\" \"$1\" && cat \"$1\"; }")')" \
	"printed the password on its own output"

# ---- typed-risk-signal (invariant 22).
run_case "typed-risk-signal: the signal is on when nobody asked" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "  TYPED_RISK=\"${TYPED_RISK_SIGNAL:-}\"", "  TYPED_RISK=\"${TYPED_RISK_SIGNAL:-1}\"")')" \
	"without the flag was refused"

run_case "typed-risk-signal: the flag is accepted with typed answers off" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "  if [ \"$TYPED_RISK\" = 1 ] && [ \"$mode\" = off ]; then", "  if false; then")')" \
	"it was accepted, and it must refuse"

run_case "typed-risk-signal: a value that is not a switch is believed" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "    *) die \"TYPED_RISK_SIGNAL must be 1 (signal on) or 0 (signal off). Nothing was installed.\" ;;", "    *) ;;")')" \
	"TYPED_RISK_SIGNAL=yes"

run_case "typed-risk-signal: TYPED_RISK_SIGNAL=0 does not turn it off" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "    0) typed_forget_env \"${TYPED_RISK_OWNED[@]}\" ;;", "    0) : ;;")')" \
	"did not remove the three lines"

run_case "typed-risk-signal: switching mode drops the signal" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "TYPRYX_OPENAI_KEY_FILE TYPRYX_TIMEOUT_MS)", "TYPRYX_OPENAI_KEY_FILE TYPRYX_TIMEOUT_MS TYPED_RISK_SIGNAL TYPED_RISK_WARDRYX_MODE TYPED_RISK_WARDRYX_URL)")')" \
	"switching mode lost the signal"

run_case "typed-risk-signal: the broker is pointed past the proxy" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "typed_set_env TYPED_RISK_WARDRYX_URL http://typryx-wardryx-proxy:4330", "typed_set_env TYPED_RISK_WARDRYX_URL http://wardryx:8090")')" \
	"does not point at the proxy"

run_case "typed-risk-signal: the proxy joins the default network" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "    networks:\n      - risk-signal\n    read_only: true", "    networks:\n      - default\n      - risk-signal\n    read_only: true")')" \
	"it must be on risk-signal and nowhere else"

run_case "typed-risk-signal: the proxy publishes a port" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "    command: [\"wardryx-proxy\"]\n", "    command: [\"wardryx-proxy\"]\n    ports:\n      - \"4330:4330\"\n")')" \
	"publishes a port"

run_case "typed-risk-signal: the proxy is given a key" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "      TYPRYX_ALLOW_OPEN_BIND: \"1\"\n", "      TYPRYX_ALLOW_OPEN_BIND: \"1\"\n      TYPRYX_KEYS: ${TYPRYX_KEYS:-}\n")')" \
	"has TYPRYX_KEYS"

run_case "typed-risk-signal: the LLM gateway is pointed at the proxy" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_WARDRYX_URL: http://wardryx:8090\n", "      TOKENFUSE_WARDRYX_URL: http://typryx-wardryx-proxy:4330\n")')" \
	"no longer asks wardryx directly"

run_case "typed-risk-signal: another service is pointed at the proxy" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "      WARDRYX_URL: http://wardryx:8090\n", "      WARDRYX_URL: http://typryx-wardryx-proxy:4330\n")')" \
	"names the proxy"

run_case "typed-risk-signal: a fourth service joins the proxy's network" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "      - edge\n      - core\n", "      - edge\n      - core\n      - risk-signal\n")')" \
	"the risk-signal network has members"

# No brace in the inserted text: macOS bash 3.2 expands `{name: a, values: [b]}`
# inside "$(py '...')" into several words and shifts the arguments.
run_case "typed-risk-signal: a hold_if_signal policy is seeded" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "  deny_tool:\n    - shell_exec\nEOF", "  deny_tool:\n    - shell_exec\n- name: x\n  target: agent://*\n  hold_if_signal:\n    name: a\n    values: [b]\n    min_probability: 0.5\nEOF")')" \
	"seeds a hold_if_signal policy"

run_case "typed-risk-signal: the seeded hold is written with the flag off" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "  if [ \"$TYPED_RISK_ON\" = 1 ]; then\n    if [ -s", "  if true; then\n    if [ -s")')" \
	"a rule was seeded without the flag"

run_case "typed-risk-signal: the managed hold survives the flag going off" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "awk \x27/^# typed-risk-hold: begin/ { skip = 1; next }", "awk \x27/^# typed-risk-hold: begin/ { skip = 0; next }")')" \
	"left the managed rule"

run_case "typed-risk-signal: the seeded hold holds a class that carries no risk" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "    '"'"'    values: [destructive, external_send, financial]'"'"' \\", "    '"'"'    values: [read_only, destructive, external_send, financial]'"'"' \\")')" \
	"must hold on destructive, external_send and financial"

run_case "typed-risk-signal: the seeded hold drops a high-risk class" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "values: [destructive, external_send, financial]", "values: [destructive, external_send]")')" \
	"must hold on destructive, external_send and financial"

run_case "typed-risk-signal: the seeded hold's threshold is lowered" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "min_probability: 0.8", "min_probability: 0.5")')" \
	"min_probability is not 0.8"

run_case "typed-risk-signal: the seeded hold narrows its target" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "target: \"agent://*\"", "target: \"agent://local/*\"")')" \
	"does not target every agent"

run_case "typed-risk-signal: the seeded hold does not hold on absence" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "when_absent: hold", "when_absent: allow")')" \
	"does not hold when the signal is absent"

run_case "typed-risk-signal: the policy block is gone" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "# typed-risk-policy: begin", "# typed-risk-policy: began")')" \
	"typed-risk-policy: begin"

run_case "typed-risk-signal: the README loses its example policy" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 's = open("README.md").read()
assert "hold_if_signal" in s
open("README.md", "w").write(s.replace("hold_if_signal", "hold_if_a_signal"))')" \
	"shows no hold_if_signal example"

run_case "typed-risk-signal: the README drops when_absent from its example" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 's = open("README.md").read()
assert "when_absent: hold" in s
open("README.md", "w").write(s.replace("when_absent: hold", "when_absent_gone: hold"))')" \
	"shows no when_absent: hold"

run_case "typed-risk-signal: typryx is pinned before the proxy existed" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/typryx:v0.5.0@sha256:c9278289b3722d3e89fd90f4834666c295ee0c83b4b014c0df160500f2b57a20}", "ghcr.io/taipanbox/typryx:v0.3.0}")')" \
	"the proxy (wardryx-proxy) does not exist before it"

run_case "typed-risk-signal: wardryx is pinned before it read signals" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/wardryx:v2.3.0@sha256:eaa8cff9fe3722f7040e9f9b3aac2f57c5e66afb7a012a0eda1a62e63b647543}", "ghcr.io/taipanbox/wardryx:v1.1.3}")')" \
	"hold_if_signal and signals on /v1/decide do not exist before it"

run_case "typed-risk-signal: wardryx is pinned before when_absent" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/wardryx:v2.3.0@sha256:eaa8cff9fe3722f7040e9f9b3aac2f57c5e66afb7a012a0eda1a62e63b647543}", "ghcr.io/taipanbox/wardryx:v1.3.2}")')" \
	"needs v1.4.0 or later"

run_case "typed-risk-signal: tokenfuse is pinned before it sent the tool call" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/tokenfuse:v1.19.0@sha256:32139654fc63ebc3026720413f1a9c16f07fb2507509714d946f50ffcf2a2434}", "ghcr.io/taipanbox/tokenfuse:v1.4.1}")')" \
	"the broker sends no tool_call to the policy plane before it"

run_case "typed-risk-signal: install.sh starts the proxy profile unconditionally" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "if [ \"$TYPED_PLANE\" != off ] && [ \"$TYPED_RISK_ON\" = 1 ]; then UP_PROFILES+=(--profile typed-risk-signal); fi", "UP_PROFILES+=(--profile typed-risk-signal)")')" \
	"not decided by both TYPED_PLANE and TYPED_RISK_ON"

run_case "typed-risk-signal: the broker's decide deadline is shorter than the proxy's ask" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS: \"7000\"", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS: \"250\"")')" \
	"decide deadline is shorter"

run_case "typed-risk-signal: the broker fails open" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_WARDRYX_FAILMODE: closed\n      # A decide that carries", "      TOKENFUSE_WARDRYX_FAILMODE: open\n      # A decide that carries")')" \
	"the broker fails open"

run_case "typed-risk-signal: no proxy service left to judge" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "  typryx-wardryx-proxy:\n    <<: *restart", "  typryx-wardryx-prox:\n    <<: *restart")')" \
	"so this measured nothing"

run_case "typed-risk-signal: a plain re-run of the stub turns the signal off" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("install.sh", "        typed_set_env TYPED_MODE stub", "        :")')" \
	"a re-run with nothing set changed the box or turned the signal off"

run_case "typed-risk-signal: the typed-mode block never reads the flag" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 's = open("install.sh").read()
b0, b1 = s.index("# typed-mode: begin\n"), s.index("# typed-mode: end\n")
blk = s[b0:b1]
assert "TYPED_RISK_SIGNAL" in blk
open("install.sh", "w").write(s[:b0] + blk.replace("TYPED_RISK_SIGNAL", "TYPED_RISK_FLAG") + s[b1:])')" \
	"never reads TYPED_RISK_SIGNAL"

# ---- bus-names (invariant 23).
run_case "bus-names: a writer's file is renamed to nothing anyone reads" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/tokenfuse-mcp.ndjson", "TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/mcp-events.ndjson")')" \
	"is not a stream name heraldyx 0.3.0 or idryx 1.1.0 know"

run_case "bus-names: wardryx writes a file named for another plane" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "      - /var/lib/stack/events/wardryx.ndjson\n", "      - /var/lib/stack/events/typryx.ndjson\n")')" \
	"claiming source \`wardryx\`, and that file may carry only ['typryx']"

run_case "bus-names: idryx loads a file for a source it does not carry" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "      - tokenfuse:/var/lib/stack/events/tokenfuse.ndjson", "      - wardryx:/var/lib/stack/events/tokenfuse.ndjson")')" \
	"loads wardryx:/var/lib/stack/events/tokenfuse.ndjson"

run_case "bus-names: init-volumes pre-creates a stream nobody accepts" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "        [ -e /vol/events/tokenfuse.ndjson ] || : > /vol/events/tokenfuse.ndjson\n", "        [ -e /vol/events/events.ndjson ] || : > /vol/events/events.ndjson\n        [ -e /vol/events/tokenfuse.ndjson ] || : > /vol/events/tokenfuse.ndjson\n")')" \
	"pre-creates events.ndjson on the bus"

run_case "bus-names: a declaration widens the rule" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "      HERALDYX_STATE: /var/lib/stack/heraldyx/state.json\n", "      HERALDYX_STATE: /var/lib/stack/heraldyx/state.json\n      HERALDYX_STREAMS: events=tokenfuse|wardryx\n")')" \
	"sets HERALDYX_STREAMS"

run_case "bus-names: nothing loads a stream any more" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 's = open("compose.yaml").read()
assert "tokenfuse:/var/lib/stack/events/" in s
open("compose.yaml", "w").write(s.replace("tokenfuse:/var/lib/stack/events/", "/var/lib/stack/events/"))')" \
	"measured NOTHING about idryx"

# ---- features-are-bound: the binding is held both ways.
run_case "features-are-bound: a binding names a case that was renamed" fail \
	'./scripts/features-are-bound.sh' \
	"$(py 'edit("features/the-declassify-key-is-minted.feature", "declassify-is-keyed: install.sh stops minting the key\"", "declassify-is-keyed: install.sh stopped minting the key\"")')" \
	"has no such run_case"

run_case "features-are-bound: a scenario has no binding" fail \
	'./scripts/features-are-bound.sh' \
	"$(py 'open("features/the-declassify-key-is-minted.feature", "a").write("\n  Scenario: a promise with no test\n    Given a gate\n    When nothing runs it\n    Then nothing fails\n")')" \
	"is bound to no test"

run_case "features-are-bound: the feature files are gone" fail \
	'./scripts/features-are-bound.sh' \
	"$(py 'import os
os.rename("features", "feature-files")')" \
	"there is no features/*.feature"

echo
# ---- the OpenAI door (invariant 32): opt-in, a gateway like the first in every
# hardened setting, on keys and a map of its own, on the operator's bind. Several
# cases run the gateway and console images, so each takes a few seconds. A
# single quote inside a mutation is written \x27.
run_case "openai-door: the door loses its profile" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("    profiles: [\"openai-door\"]\n", "")')" \
	"starts on every box"

run_case "openai-door: the door serves the Anthropic wire" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_WIRE: openai\n", "      TOKENFUSE_WIRE: anthropic\n")')" \
	"not openai"

run_case "openai-door: the door's upstream gets a default" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("${OPENAI_DOOR_UPSTREAM:-}}}", "${OPENAI_DOOR_UPSTREAM:-https://api.openai.com/v1/chat/completions}}}")')" \
	"must be empty until the door's keys and map are set"

run_case "openai-door: the door's upstream no longer waits for its keys" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_UPSTREAM: ${OPENAI_DOOR_CLIENT_KEYS:+${OPENAI_DOOR_IDENTITY_MAP:+${OPENAI_DOOR_UPSTREAM:-}}}\n", "      TOKENFUSE_UPSTREAM: ${OPENAI_DOOR_UPSTREAM:-}\n")')" \
	"must be empty until the door's keys and map are set"

run_case "openai-door: the door is published on every address" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      - \"${GATEWAY_BIND:-127.0.0.1}:4110:4100\"\n", "      - \"0.0.0.0:4110:4100\"\n")')" \
	"not exactly"

run_case "openai-door: the door loses its policy plane fail mode" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_WARDRYX_FAILMODE: closed\n", "")')" \
	"and the gateway sets 'closed'"

run_case "openai-door: the door's policy plane runs in shadow" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_WARDRYX_MODE: enforce\n", "      TOKENFUSE_WARDRYX_MODE: shadow\n")')" \
	"TOKENFUSE_WARDRYX_MODE 'shadow'"

run_case "openai-door: the door loses its admin key" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_ADMIN_KEYS: ${GATEWAY_ADMIN:?set by install.sh}\n", "")')" \
	"sets TOKENFUSE_ADMIN_KEYS None"

run_case "openai-door: the door's environment comes through a YAML anchor" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_CACHE: \"off\"\n", "      <<: *door-hardening\n")')" \
	"YAML anchor"

run_case "openai-door: the door carries delegation" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_WIRE: openai\n", "      TOKENFUSE_WIRE: openai\n      TOKENFUSE_DELEGATION_ISSUER: ${TOKENFUSE_DELEGATION_ISSUER:-}\n")')" \
	"Delegation and closure stay off"

run_case "openai-door: the door writes the gateway's stream" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/tokenfuse-openai.ndjson", "TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/tokenfuse.ndjson")')" \
	"not /var/lib/stack/events/tokenfuse-openai.ndjson"

run_case "openai-door: the door shares the gateway's data directory" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("TOKENFUSE_DATA_DIR: /var/lib/stack/traces/gateway-openai", "TOKENFUSE_DATA_DIR: /var/lib/stack/traces/gateway")')" \
	"keeps too"

run_case "openai-door: the door reads the gateway's map" fail \
	'./scripts/openai-door.sh' \
	"$(py 'door("      - ./identity-openai:/etc/tokenfuse/identity:ro\n", "      - ./identity:/etc/tokenfuse/identity:ro\n")')" \
	"mounts too"

run_case "openai-door: install.sh opens the door with no keys file" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "|| die \"OPENAI_DOOR=1 needs OPENAI_DOOR_CLIENT_KEYS_FILE", "|| note \"OPENAI_DOOR=1 needs OPENAI_DOOR_CLIENT_KEYS_FILE")')" \
	"the door on with no keys file was accepted"

run_case "openai-door: install.sh opens the door with no upstream" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "  [ -n \"$DOOR_UPSTREAM\" ] || DOOR_UPSTREAM=\"$(door_env_get OPENAI_DOOR_UPSTREAM)\"\n", "  [ -n \"$DOOR_UPSTREAM\" ] || DOOR_UPSTREAM=\"$(door_env_get OPENAI_DOOR_UPSTREAM)\"\n  [ -n \"$DOOR_UPSTREAM\" ] || DOOR_UPSTREAM=https://api.openai.com/v1/chat/completions\n")')" \
	"the door on with no upstream was accepted"

run_case "openai-door: install.sh takes a base URL as the upstream" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "(/[A-Za-z0-9._~+-]+)*/chat/completions$\x27", "(/[A-Za-z0-9._~+-]+)*(/chat/completions)?$\x27")')" \
	"(a base URL, not the endpoint) was accepted"

run_case "openai-door: a refusal echoes the upstream" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "die \"OPENAI_DOOR_UPSTREAM must be an http or https URL", "die \"OPENAI_DOOR_UPSTREAM ($DOOR_UPSTREAM) must be an http or https URL")')" \
	"echoes it"

run_case "openai-door: two maps sharing a unit are accepted" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "  if [ -n \"$shared\" ]; then\n", "  if false; then\n")')" \
	"the unit would get its cap once on each door"

run_case "openai-door: two maps that cannot be compared are let through" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "  if ! shared=\"$(door_units_shared \"$2\" \"$a\" \"$b\")\"; then\n", "  if ! shared=\"$(door_units_shared \"$2\" \"$a\" \"$b\" || true)\"; then\n")')" \
	"could not be compared"

run_case "openai-door: the door's refusals come after a package install" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "# openai-door: end\ndoor_resolve\n", "# openai-door: end\n"); edit("install.sh", "|| die \"docker did not start.\"\n", "|| die \"docker did not start.\"\ndoor_resolve\n")')" \
	"does not run before the first package install"

run_case "openai-door: the door's profile is passed whatever DOOR_ON says" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "[ \"$DOOR_ON\" != 1 ] || UP_PROFILES+=(--profile openai-door)", "UP_PROFILES+=(--profile openai-door)")')" \
	"on a line DOOR_ON does not decide"

run_case "openai-door: the door is left running when it is turned off" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "\nprofiles_off_remove\n", "\n")')" \
	"does not remove tokenfuse-gateway-openai"

run_case "openai-door: a new door map does not restart the door" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "\"${COMPOSE[@]}\" --profile openai-door restart tokenfuse-gateway-openai >/dev/null", "\"${COMPOSE[@]}\" --profile openai-door ps tokenfuse-gateway-openai >/dev/null")')" \
	"does not restart tokenfuse-gateway-openai"

run_case "openai-door: section 8 stops asking the door for a key" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "check \"openai door: a call with no key is refused\"", "check \"openai door: configured\"")')" \
	"section 8 no longer asks the running door"

run_case "openai-door: the closing report stops saying who pays" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "a metered upstream bills whoever\x27s key that is.", "a metered upstream bills the caller.")')" \
	"who pays"

run_case "openai-door: no door service left to judge" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("compose.yaml", "  tokenfuse-gateway-openai:\n", "  tokenfuse-gateway-opena1:\n")')" \
	"measured NOTHING about the"

run_case "openai-door: the installer block is gone" fail \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "# openai-door: begin\n", "# openai-door: start\n")')" \
	"measured nothing about the installer's half"

run_case "openai-door: a comment beside the door's upstream is not a setting" pass \
	'./scripts/openai-door.sh' \
	"$(py 'door("      TOKENFUSE_UPSTREAM: ${OPENAI_DOOR_CLIENT_KEYS", "      # never TOKENFUSE_UPSTREAM: ${OPENAI_DOOR_UPSTREAM:-https://api.openai.com/v1/chat/completions}\n      TOKENFUSE_UPSTREAM: ${OPENAI_DOOR_CLIENT_KEYS")')"

run_case "openai-door: a reworded refusal still refuses" pass \
	'./scripts/openai-door.sh' \
	"$(py 'edit("install.sh", "Set OPENAI_DOOR=1 with it. Nothing was installed.", "Set OPENAI_DOOR=1 alongside it. Nothing was installed.")')"

# The door dimension of invariant 29's block, run once per door.
run_case "identity-files: the OpenAI door's check runs on the Anthropic wire" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "ID_WIRE=openai ID_ROUTE=/v1/chat/completions", "ID_WIRE=anthropic ID_ROUTE=/v1/chat/completions")')" \
	"did not serve its wire"

run_case "identity-files: switching doors loses the first door's state" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "      printf -v \"IDENTITY_${IDENTITY_DOOR}_$f\" \x27%s\x27 \"${!v}\"\n", "      :\n")')" \
	"lost the main door's own state"

run_case "identity-files: an unknown door is taken quietly" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "    *) die \"internal: identity_door was given", "    *) : \"internal: identity_door was given")')" \
	"accepts a door it does not know"

run_case "identity-files: a gateway that no door names" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("install.sh", "ID_SERVICE=tokenfuse-gateway-openai", "ID_SERVICE=tokenfuse-gateway-ai")')" \
	"0 door(s) of install.sh's identity block name it"

run_case "identity-files: the door is handed the gateway's client keys" fail \
	'./scripts/identity-files-are-checked.sh' \
	"$(py 'door("      TOKENFUSE_CLIENT_KEYS: ${OPENAI_DOOR_CLIENT_KEYS:-}\n", "      TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:-}\n")')" \
	"tokenfuse-gateway-openai names GATEWAY_CLIENT_KEYS"

# The resolved halves read every gateway with the door's profile on; a door they
# cannot see is a failure, not a smaller subject.
run_case "firewall-is-enforce: the resolved read misses the OpenAI door" fail \
	'./scripts/firewall-is-enforce.sh' \
	"$(py 'door("    profiles: [\"openai-door\"]\n", "    profiles: [\"openai-doors\"]\n")')" \
	"not enforce on each of"

run_case "pii-is-shadow: the resolved read misses the OpenAI door" fail \
	'./scripts/pii-is-shadow.sh' \
	"$(py 'door("    profiles: [\"openai-door\"]\n", "    profiles: [\"openai-doors\"]\n")')" \
	"for the gateways, not shadow on each of"

run_case "run-budget-ceiling: the resolved read misses the OpenAI door" fail \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'door("    profiles: [\"openai-door\"]\n", "    profiles: [\"openai-doors\"]\n")')" \
	"not 5.00 on each of"

# The door's stream: written, pre-created, loaded, accepted.
run_case "bus-has-a-writer: idryx stops loading the OpenAI door's file" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit_all("compose.yaml", "      - --load\n      - tokenfuse:/var/lib/stack/events/tokenfuse-openai.ndjson\n", "")')" \
	"does not load tokenfuse:/var/lib/stack/events/tokenfuse-openai.ndjson"

run_case "bus-has-a-writer: the OpenAI door writes the gateway's file" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'door("TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/tokenfuse-openai.ndjson", "TOKENFUSE_EVENTS_PATH: /var/lib/stack/events/tokenfuse.ndjson")')" \
	"name the same events path"

run_case "bus-has-a-writer: the OpenAI door's file is not pre-created" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "        [ -e /vol/events/tokenfuse-openai.ndjson ] || : > /vol/events/tokenfuse-openai.ndjson\n", "")')" \
	"does not pre-create tokenfuse-openai.ndjson"

run_case "bus-names: the idryx pin goes back before the OpenAI door's row" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit_all("compose.yaml", "ghcr.io/taipanbox/idryx:v1.3.0", "ghcr.io/taipanbox/idryx:v1.1.0")')" \
	"older than v1.2.0"

run_case "bus-names: the heraldyx pin goes back before the OpenAI door's row" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/heraldyx:v0.8.0", "ghcr.io/taipanbox/heraldyx:v0.4.0")')" \
	"older than v0.5.0"

echo "=== and what they must NOT catch ==="

# A shellcheck directive with its reason beside it is the documented way to
# silence a finding here. A gate that flagged one would be flagging the
# convention its own header describes.
run_case "shell-lint: another silenced finding with its reason" pass \
	'./scripts/shell-lint.sh' \
	"$(py 'edit("install.sh", "die()  {", "# shellcheck disable=SC2317  # reachable, called from a trap\ndie()  {")')"

# The sysctl file's own name is the installer's to choose; the key is not.
run_case "bind-is-honoured: the sysctl file is renamed" pass \
	'./scripts/bind-is-honoured.sh' \
	"$(py 's = open("install.sh").read()
a, b = "/etc/sysctl.d/90-agent-stack-bind.conf", "/etc/sysctl.d/90-agent-stack.conf"
assert s.count(a) >= 2, "expected the sysctl file named more than once"
open("install.sh", "w").write(s.replace(a, b))')"

# A quieter apt-get update changes nothing about what is installed or removed.
run_case "apt-never-removes-docker: apt-get update gets a different flag" pass \
	'./scripts/apt-never-removes-docker.sh' \
	"$(py 'edit("install.sh", "apt-get update -qq >/dev/null 2>&1 || true", "apt-get update -q >/dev/null 2>&1 || true")')"

# A longer timeout on the probe is a tuning, not a change of where it probes.
run_case "bind-is-honoured: the probe's timeout changes" pass \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "curl -fsS -m5 -o /dev/null http://$GATEWAY_PROBE", "curl -fsS -m9 -o /dev/null http://$GATEWAY_PROBE")')"

# focus-export runs the same image as the gateway, but as `tokenfuse
# focus-export`, a subcommand, never the bare serve binary. It must stay
# outside this gate's subject list whatever its own command line does.
run_case "gateway-cache-is-off: focus-export's command changes" pass \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("compose.yaml", "ROUTINE_INTERVAL: ${ROUTINE_INTERVAL:-3600}", "ROUTINE_INTERVAL: ${ROUTINE_INTERVAL:-7200}")')"

# tokenfuse-mcp-broker (2026-09-26) is the same image again, running the
# `mcp-broker` subcommand, never the bare gateway. It must stay outside this
# gate's subject list too, whatever its own configuration does.
run_case "gateway-cache-is-off: the mcp broker's configuration changes" pass \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MCP_ADDR: 0.0.0.0:4200", "TOKENFUSE_MCP_ADDR: 0.0.0.0:4201")')"

# The declassify gate's subject is the serve-mode gateway only: the broker
# runs the same image on a subcommand and never serves that route.
run_case "declassify-is-keyed: the mcp broker's configuration changes" pass \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MCP_ADDR: 0.0.0.0:4200", "TOKENFUSE_MCP_ADDR: 0.0.0.0:4201")')"

# The message after `:?` is wording, not the rule. A gate that fired on it
# would be edited out by whoever hit it.
run_case "declassify-is-keyed: the required-variable message is reworded" pass \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("compose.yaml", "${GATEWAY_DECLASSIFY_KEY:?set by install.sh}", "${GATEWAY_DECLASSIFY_KEY:?run install.sh first}")')"

# A wording change beside the delegation section is not a change to whether
# the profile is off by default, whether a secret is printed, or whether a
# key is reused.
run_case "delegation-off-by-default: a comment near it is reworded" pass \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("compose.yaml", "root:10001 2775, and this is how it can append there.", "root:10001 2775, which is how it can append there.")')"

# Naming the variable in prose, with no $ in front of it, is not an expansion:
# it prints nothing but the sentence itself.
run_case "delegation-key-not-printed: a comment names the variable with no \$" pass \
	'./scripts/delegation-key-not-printed.sh' \
	"$(py 'edit("install.sh", "add_env_default VOUCHRYX_REVOKE_KEYS \"$(gen 40)\"", "# VOUCHRYX_REVOKE_KEYS is a bearer key, not a spec.\nadd_env_default VOUCHRYX_REVOKE_KEYS \"$(gen 40)\"")')"

run_case "delegation-dirs-are-split: the gateway mounts vouchryx's private directory" fail \
	'./scripts/delegation-dirs-are-split.sh' \
	"$(py 'edit("compose.yaml", "      - ./delegation-public:/etc/tokenfuse/delegation:ro", "      - ./delegation:/etc/tokenfuse/delegation:ro")')" \
	"that directory holds vouchryx's signing key"

run_case "delegation-dirs-are-split: ./delegation left to root" fail \
	'./scripts/delegation-dirs-are-split.sh' \
	"$(py 'import re
s = open("install.sh").read()
s = re.sub(r"(?m)^\s*chown 20002:20002 delegation\s*\n", "", s)
open("install.sh", "w").write(s)')" \
	"never gives ./delegation to uid 20002"

run_case "delegation-dirs-are-split: a comment in the gateway block changes" pass \
	'./scripts/delegation-dirs-are-split.sh' \
	"$(py 'edit("compose.yaml", "# ./delegation, which holds vouchryx", "# ./delegation, the directory that holds vouchryx")')"

run_case "env-sources-cleanly: a default goes back to an unquoted pipe" fail \
	'./scripts/env-sources-cleanly.sh' \
	"$(py 'edit("install.sh", "add_env_default TOKENFUSE_MCP_SECRET_SCOPES \"$(sq_ \x27typryx_key=tools:ask|ask_freeform|list_questions\x27)\"", "add_env_default TOKENFUSE_MCP_SECRET_SCOPES \"typryx_key=tools:ask|ask_freeform|list_questions\"")')" \
	"writes an unquoted value the shell would act on"

run_case "env-sources-cleanly: the repair stops quoting" fail \
	'./scripts/env-sources-cleanly.sh' \
	"$(py 'edit("install.sh", "print name \"=\\047\" val \"\\047\"; fixed++; next", "print name \"=\" val; fixed++; next")')" \
	"does not source cleanly"

run_case "env-sources-cleanly: the repair call removed" fail \
	'./scripts/env-sources-cleanly.sh' \
	"$(py 'edit("install.sh", "repair_env_quoting .env || die", "true || die")')" \
	"does not call repair_env_quoting"

run_case "env-sources-cleanly: a plain default added" pass \
	'./scripts/env-sources-cleanly.sh' \
	"$(py 'edit("install.sh", "add_env_default ALERT_MIN_SEVERITY high\n", "add_env_default ALERT_MIN_SEVERITY high\nadd_env_default EXTRA_PLAIN value-1\n")')"

run_case "felyx-through-the-gateway: the base URL points past the gateway" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_BASE_URL: http://tokenfuse-gateway:4100\n", "      GENARYX_COPILOT_BASE_URL: https://api.anthropic.com\n")')" \
	"would not reach its model through this box's gateway"

run_case "felyx-through-the-gateway: the remote opt-in comes back" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_API_KEY_REF: env:GENARYX_COPILOT_FUSE_KEY\n", "      GENARYX_COPILOT_API_KEY_REF: env:GENARYX_COPILOT_FUSE_KEY\n      GENARYX_COPILOT_ALLOW_REMOTE: \"1\"\n")')" \
	"would skip the residency check"

run_case "felyx-through-the-gateway: Felyx's client key reference is dropped" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_FUSE_KEY_REF: env:GENARYX_COPILOT_FUSE_KEY\n", "")')" \
	"would not present its own gateway client key"

run_case "felyx-through-the-gateway: Felyx's client key is written into compose.yaml" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n", "      GENARYX_COPILOT_FUSE_KEY: planted\n")')" \
	"must be read from .env and empty by default"

run_case "felyx-through-the-gateway: Felyx's client key becomes required" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:?set it in .env}\n")')" \
	"must be read from .env and empty by default"

# The closing report's note about Felyx. It said "sends no x-fuse-key" whatever
# the box held, including on a box that had given Felyx a key.
run_case "felyx-through-the-gateway: the closing report says Felyx sends no key though it has one" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "  elif [ -n \"${GENARYX_COPILOT_FUSE_KEY:-}\" ]; then\n    printf \x27\\n  Felyx", "  elif false; then\n    printf \x27\\n  Felyx")')" \
	"although GENARYX_COPILOT_FUSE_KEY is set"

run_case "felyx-through-the-gateway: the closing report stops saying a keyless Felyx is refused" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "  are refused 401. To give it a key of its own", "  are turned away. To give it a key of its own")')" \
	"no longer says its calls are refused 401"

run_case "felyx-through-the-gateway: the closing report prints Felyx's key" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "    printf \x27  (README, \"Client keys and the identity map\").\x27\n  else", "    printf \x27  (README, \"Client keys and the identity map\"). key=%s\x27 \"$GENARYX_COPILOT_FUSE_KEY\"\n  else")')" \
	"printed the value of GENARYX_COPILOT_FUSE_KEY"

run_case "felyx-through-the-gateway: the closing report speaks of Felyx with client keys off" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "felyx_gateway_note() {\n  [ \"$IDENTITY_KEYS_COUNT\" -gt 0 ] || return 0\n", "felyx_gateway_note() {\n")')" \
	"with client keys off"

run_case "felyx-through-the-gateway: the closing report never calls the note" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "IDENTITY_REACH=\"$IDENTITY_REACH$(felyx_gateway_note)$(upstream_reach_note)$(agent_tokens_reach_note)$(profile_reach_note)\"", "IDENTITY_REACH=\"$IDENTITY_REACH$(upstream_reach_note)$(agent_tokens_reach_note)$(profile_reach_note)\"")')" \
	"does not call felyx_gateway_note exactly once"

run_case "felyx-through-the-gateway: a comment about Felyx changes" pass \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "# Felyx, the console\x27s copilot, talks to its model THROUGH", "# Felyx, the console\x27s copilot, reaches its model THROUGH")')"

run_case "delegation-key-reused-on-rerun: the reused-message wording changes" pass \
	'./scripts/delegation-key-reused-on-rerun.sh' \
	"$(py 'edit("install.sh", "vouchryx: signing key already present, reused", "vouchryx: signing key present already, reusing it")')"

# A comment inside the block changes nothing the gate is about.
run_case "typed-data-mode: a comment inside the typed block is left alone" pass \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "# typed-mode: begin\n", "# typed-mode: begin\n# a comment that changes no behaviour\n")')"

# The training log's own path is the ONE value a pin-style edit must not trip:
# moving the README's prose about the log around changes no behaviour.
run_case "typed-data-mode: a wording change in the training paragraph is left alone" pass \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("README.md", "The log has no rotation or retention", "The log has no rotation and no retention")')"

run_case "run-budget-ceiling: the refusal is reworded" pass \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("install.sh", "RUN_BUDGET_CEILING_USD must be a positive number of US dollars with at most six decimals (5 or 2.50", "RUN_BUDGET_CEILING_USD has to be a positive number of US dollars with at most six decimals (5 or 2.50")')"

run_case "run-budget-ceiling: the broker's configuration changes" pass \
	'./scripts/run-budget-ceiling.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MCP_ADDR: 0.0.0.0:4200", "      TOKENFUSE_MCP_ADDR: 0.0.0.0:4201")')"

run_case "chain-verifier: the interval changes" pass \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "      - -every\n      - 5m\n", "      - -every\n      - 10m\n")')"

run_case "chain-verifier: the state file is renamed" pass \
	'./scripts/chain-verifier-is-contained.sh' \
	"$(py 'edit("compose.yaml", "      - /var/lib/agent-conform/state.json\n", "      - /var/lib/agent-conform/memory.json\n")')"

run_case "typed-risk-signal: the broker's deadline is raised" pass \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS: \"7000\"", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS: \"9000\"")')"

run_case "typed-risk-signal: the proxy's ask deadline default moves" pass \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "${TYPED_RISK_ASK_TIMEOUT_MS:-3000}", "${TYPED_RISK_ASK_TIMEOUT_MS:-2000}")')"

run_case "bus-names: a comment in init-volumes changes" pass \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "# The chain verifier (agent-conform) runs 10002:10002, NEITHER of the", "# The chain verifier (agent-conform) runs as 10002:10002, NEITHER of the")')"

echo
echo "=== and the one this estate learned the hard way ==="
echo "    a gate whose subject is gone must SAY so, not report OK on nothing"

run_case "record-is-not-on-the-bus: no record-seal service left to judge" fail \
	'./scripts/record-is-not-on-the-bus.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = s.index("  record-seal:")
j = s.index("\nvolumes:")
assert i < j
open("compose.yaml", "w").write(s[:i] + s[j:])')" \
	"measured NOTHING"

# build-context-complete derives its subject list from install.sh since
# 2026-08-28. A derived list can derive to nothing: rename the invocations and
# the check sweeps an empty set. It used to be a hand-written list, with a
# comment claiming an unlisted image would be visible, and scopyx-browser had
# been missing from it for as long as both existed.
run_case "build-context-complete: install.sh stops naming its Dockerfiles" fail \
	'./scripts/build-context-complete.sh' \
	"$(py 's = open("install.sh").read()
a, b = "-f stack-k8s/images/", "-f stack-k8s/IMAGES/"
n = s.count(a)
assert n > 1, "expected several build invocations, found " + str(n)
open("install.sh", "w").write(s.replace(a, b))')" \
	"measured NOTHING"

# THE HOLE. Rewriting the COPY prefix in stack-k8s emptied this check while it
# reported every path present. This is the case that keeps the fix in place.
run_case "build-context-complete: no build-context path left to check" fail \
	'SRC=$(cat .teeth-src) ./scripts/build-context-complete.sh' \
	"$(py 'import os, re, glob, shutil, tempfile, pathlib
src = os.environ["TEETH_BASE_SRC"]
assert os.path.isdir(src + "/images"), "the resolved stack-k8s tree has no images/"
tmp = tempfile.mkdtemp()
shutil.copytree(src + "/images", tmp + "/images")
n = 0
for f in glob.glob(tmp + "/images/*.Dockerfile"):
    t = open(f).read()
    out = re.sub(r"(?im)^(\s*(?:COPY|ADD)\s+)images/", r"\1vendor/", t)
    if out != t:
        open(f, "w").write(out); n += 1
assert n, "no COPY under images/ to rewrite"
pathlib.Path(".teeth-src").write_text(tmp)')" \
	"measured nothing"

run_case "closed-by-default: the bind default is gone from install.sh" fail \
	'./scripts/closed-by-default.sh' \
	"$(py 'edit("install.sh", "GATEWAY_BIND=\"${GATEWAY_BIND:-127.0.0.1}\"", "GATEWAY_BIND_ADDR=\"127.0.0.1\"")')" \
	"could not find the GATEWAY_BIND default"

# The package step's own anchor renamed: the slice matches nothing, runs
# nothing, and would pass every assertion about what it did not ask for.
run_case "apt-never-removes-docker: the package step's anchor is gone" fail \
	'./scripts/apt-never-removes-docker.sh' \
	"$(py 'edit("install.sh", "say \"installing docker and git\"", "say \"installing docker, git\"")')" \
	"measured NOTHING"

run_case "bind-is-honoured: the gateway check itself is gone" fail \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'import re
s = open("install.sh").read()
n = len(re.findall(r"(?m)^check \"gateway answers on .*\n", s))
assert n == 1, "expected one gateway check, found " + str(n)
open("install.sh", "w").write(re.sub(r"(?m)^check \"gateway answers on .*\n", "", s))')" \
	"measured nothing"

# A manual job an install starts is not one. The category has two halves and
# either alone is satisfiable while the job still comes up on somebody's box:
# it has to sit behind a profile, and no install may pass that profile.
#
# The job in question could not start at ALL until 2026-09-01. It was a shell
# loop on a distroless image, so any attempt gave `stat /bin/sh: no such file or
# directory`, and nothing noticed because the profile it sat behind was never
# enabled either. Two ways of being invisible at once.
run_case "manifest-is-true: a manual job stops sitting behind a profile" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("compose.yaml", "    profiles: [\"manual\"]\n", "")')" \
	"sits behind no profile"

run_case "manifest-is-true: the installer starts the job a person should start" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("install.sh", "say \"pulling published images\"", "say \"pulling images\" --profile manual")')" \
	"A manual job an install starts is not one"

run_case "manifest-is-true: a manual job with no reason beside it" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json, collections
p = "components.json"
d = json.load(open(p), object_pairs_hook=collections.OrderedDict)
d["components"][0]["checked"]["manual_jobs"]["idryx-detect"] = ""
json.dump(d, open(p, "w"), indent=2)')" \
	"gives no reason"

run_case "delegation-off-by-default: no vouchryx service left to judge" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = s.index("  vouchryx:")
j = s.index("\n  # ---- money: the control API")
assert i < j
open("compose.yaml", "w").write(s[:i] + s[j:])')" \
	"measured nothing about it"

run_case "delegation-key-not-printed: VOUCHRYX_REVOKE_KEYS is gone from install.sh" fail \
	'./scripts/delegation-key-not-printed.sh' \
	"$(py 'edit("install.sh", "add_env_default VOUCHRYX_REVOKE_KEYS \"$(gen 40)\"\n", "")')" \
	"measured nothing"

run_case "delegation-key-reused-on-rerun: both anchors are gone" fail \
	'./scripts/delegation-key-reused-on-rerun.sh' \
	"$(py 'edit("install.sh", "add_env_default VOUCHRYX_REVOKE_KEYS \"$(gen 40)\"", "VOUCHRYX_REVOKE_KEYS_LINE_REMOVED=1")')" \
	"measured NOTHING"

run_case "typed-data-mode: the typed-mode block is gone" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("install.sh", "# typed-mode: begin\n", "# typed-mode: start\n")')" \
	"measured nothing about the typed data mode"

run_case "typed-data-mode: install.sh passes no typed profile at all" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 's = open("install.sh").read()
assert "--profile typed" in s
open("install.sh", "w").write(s.replace("--profile typed", "--profile other"))')" \
	"measured nothing about how it is gated"

run_case "typed-data-mode: no typryx service left to read" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "  typryx:\n    <<: *restart", "  typryz:\n    <<: *restart")
edit("compose.yaml", "      typryx:\n        condition: service_started", "      typryz:\n        condition: service_started")')" \
	"so this measured nothing"

run_case "typed-data-mode: compose names no typryx image to read a pin from" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 's = open("compose.yaml").read()
a = "image: ${TYPRYX_IMAGE:-ghcr.io/taipanbox/typryx:v0.5.0@sha256:c9278289b3722d3e89fd90f4834666c295ee0c83b4b014c0df160500f2b57a20}"
assert s.count(a) == 2, "expected the typryx service and the risk-signal proxy to name the image"
open("compose.yaml", "w").write(s.replace(a, "image: ${TYPRYX_IMAGE:-registry.invalid/typryx}"))')" \
	"names no ghcr.io/taipanbox/typryx"

echo
echo "=== the FinOps console (invariant 24): an add-on that leaves the core unchanged ==="

# A profile line alone holds none of the three things this add-on promises:
# that a box which never enables it runs what it ran without it, that as
# shipped it cannot spend, and that it can write exactly one file on the bus.
run_case "finops: the console leaves its profile" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    profiles: [\"finops\"]\n    image: ${COSTCREW_IMAGE", "    image: ${COSTCREW_IMAGE")')" \
	"is not behind"

run_case "finops: the one-shot leaves its profile" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "  costcrew-init:\n    profiles: [\"finops\"]\n", "  costcrew-init:\n")')" \
	"is not behind"

run_case "finops: a second profile starts the console too" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    profiles: [\"finops\"]\n    image: ${COSTCREW_IMAGE", "    profiles: [\"finops\", \"routines\"]\n    image: ${COSTCREW_IMAGE")')" \
	"is not behind"

# The easy excuse to touch the core: one volume mounted in the one-shot every
# install runs.
run_case "finops: init-volumes learns the add-on" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - checkpoints:/vol/checkpoints\n    restart: \"no\"", "      - checkpoints:/vol/checkpoints\n      - costcrewdata:/vol/costcrew\n    restart: \"no\"")')" \
	"names the add-on"

run_case "finops: a core service waits for the console" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - heraldyxstate:/var/lib/stack/heraldyx\n    depends_on:\n      init-volumes:\n        condition: service_completed_successfully\n", "      - heraldyxstate:/var/lib/stack/heraldyx\n    depends_on:\n      init-volumes:\n        condition: service_completed_successfully\n      costcrew:\n        condition: service_started\n")')" \
	"names the add-on"

# The half of the opt-in that lives in install.sh, and the case the task named:
# an install that passes the profile starts the console on every box.
run_case "finops: install.sh passes the profile" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("install.sh", "say \"pulling published images\"", "say \"pulling images\" --profile finops")')" \
	"An optional add-on an install starts is not one"

run_case "finops: install.sh passes the profile (the add-on gate)" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("install.sh", "say \"pulling published images\"", "say \"pulling images\" --profile finops")')" \
	"an install must not know about it"

run_case "finops: install.sh switches the profile on by environment" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("install.sh", "export DEBIAN_FRONTEND=noninteractive\n", "export DEBIAN_FRONTEND=noninteractive\nexport COMPOSE_PROFILES=finops\n")')" \
	"sets COMPOSE_PROFILES"

run_case "finops: install.sh names the console" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("install.sh", "say \"starting the stack\"", "say \"starting the stack and costcrew\"")')" \
	"names the add-on"

# It cannot spend as shipped. A gateway is the operator's decision.
run_case "finops: the console is given a gateway" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - -data\n      - /var/lib/costcrew\n", "      - -data\n      - /var/lib/costcrew\n      - -gateway\n      - http://tokenfuse-gateway:4100\n")')" \
	"the console would be able to spend"

run_case "finops: the console is given a gateway by environment" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    ports:\n      - \"127.0.0.1:8321:8321\"\n", "    environment:\n      COSTCREW_GATEWAY: http://tokenfuse-gateway:4100\n    ports:\n      - \"127.0.0.1:8321:8321\"\n")')" \
	"the console would be able to spend"

# The wiring that fails silently.
run_case "finops: its stream is named for something else" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - -stack-events\n      - /var/lib/stack/events/costcrew.ndjson\n", "      - -stack-events\n      - /var/lib/stack/events/finops.ndjson\n")')" \
	"must be named costcrew.ndjson"

run_case "finops: passports come without an owner" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - -stack-owner\n      - ${COSTCREW_OWNER:-${ALERT_TO:-}}\n", "")')" \
	"come as a pair"

run_case "finops: the host is not the record plane's trust domain" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - -stack-host\n      - ${RECORD_TRUST_DOMAIN:-set-me.invalid}\n", "      - -stack-host\n      - costcrew.local\n")')" \
	"not RECORD_TRUST_DOMAIN"

run_case "finops: its passports go outside its data volume" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - /var/lib/costcrew/passports\n", "      - /tmp/passports\n")')" \
	"outside its data volume"

# Its account is its containment.
run_case "finops: the console joins the bus group" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    user: \"10003:10003\"\n    # The image", "    user: \"10003:10001\"\n    # The image")')" \
	"is the bus group"

run_case "finops: the console takes a plane's uid" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    user: \"10003:10003\"\n    # The image", "    user: \"65532:10003\"\n    # The image")')" \
	"belongs to a plane that writes the bus"

run_case "finops: the console runs as root" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    user: \"10003:10003\"\n    # The image", "    user: \"0:0\"\n    # The image")')" \
	"root writes anything on the bus"

run_case "finops: the console gets a group_add" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    user: \"10003:10003\"\n    # The image", "    user: \"10003:10003\"\n    group_add:\n      - \"10001\"\n    # The image")')" \
	"has group_add"

run_case "finops: its root filesystem becomes writable" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    read_only: true\n    cap_drop:\n      - ALL\n    security_opt:\n      - no-new-privileges:true\n    depends_on:\n      costcrew-init:", "    cap_drop:\n      - ALL\n    security_opt:\n      - no-new-privileges:true\n    depends_on:\n      costcrew-init:")')" \
	"root filesystem is not read_only"

run_case "finops: its image is unpinned" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/costcrew:v0.10.0@sha256:26316b1c99706529a4589a328b2ddd3fc5f4db4cf0b5a46466e8be1ddd8f0de9}", "ghcr.io/taipanbox/costcrew:latest}")')" \
	"is not the pinned"

run_case "finops: it is published on every address" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - \"127.0.0.1:8321:8321\"", "      - \"8321:8321\"")')" \
	"reached on loopback only"

run_case "finops: it is published on the gateway's bind variable" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - \"127.0.0.1:8321:8321\"", "      - \"${GATEWAY_BIND:-127.0.0.1}:8321:8321\"")')" \
	"reached on loopback only"

# The one-shot prepares exactly its stream and its volume.
run_case "finops: its stream is no longer created" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "        [ -e /vol/events/costcrew.ndjson ] || : > /vol/events/costcrew.ndjson\n", "")')" \
	"does not create costcrew.ndjson"

run_case "finops: its stream is given to another uid" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "chown 10003:10001 /vol/events/costcrew.ndjson", "chown 10001:10001 /vol/events/costcrew.ndjson")')" \
	"gives costcrew.ndjson to 10001:10001"

run_case "finops: its stream becomes group-writable" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "chmod 0640 /vol/events/costcrew.ndjson", "chmod 0664 /vol/events/costcrew.ndjson")')" \
	"writable by group or other"

run_case "finops: its stream cannot be read by the chain verifier" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "chmod 0640 /vol/events/costcrew.ndjson", "chmod 0600 /vol/events/costcrew.ndjson")')" \
	"not readable by other"

run_case "finops: its data volume has no owner" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "        chown -R 10003:10003 /vol/costcrew && chmod 0750 /vol/costcrew\n", "")')" \
	"does not chown /vol/costcrew"

run_case "finops: the one-shot stops waiting for init-volumes" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    restart: \"no\"\n    depends_on:\n      init-volumes:\n        condition: service_completed_successfully\n\n  costcrew:", "    restart: \"no\"\n\n  costcrew:")')" \
	"does not wait for init-volumes"

run_case "finops: the console stops waiting for its one-shot" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    depends_on:\n      costcrew-init:\n        condition: service_completed_successfully\n", "")')" \
	"waits for no one-shot"

run_case "finops: no console left to judge" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "${COSTCREW_IMAGE:-ghcr.io/taipanbox/costcrew:v0.10.0@sha256:26316b1c99706529a4589a328b2ddd3fc5f4db4cf0b5a46466e8be1ddd8f0de9}", "${COSTCREW_IMAGE:-registry.invalid/costcrew}")')" \
	"measured NOTHING about the FinOps console"

# The rendering half: text a parser accepts and compose does not.
run_case "finops: compose refuses what the text read as fine" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    ports:\n      - \"127.0.0.1:8321:8321\"\n", "    bogus_key: 1\n    ports:\n      - \"127.0.0.1:8321:8321\"\n")')" \
	"docker compose config failed"

# The inventory half, in the manifest.
run_case "manifest-is-true: an add-on service stops sitting behind a profile" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'edit("compose.yaml", "  costcrew-init:\n    profiles: [\"finops\"]\n", "  costcrew-init:\n")')" \
	"sits behind no profile"

run_case "manifest-is-true: an add-on service with no reason beside it" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json, collections
p = "components.json"
d = json.load(open(p), object_pairs_hook=collections.OrderedDict)
d["components"][0]["checked"]["optional_addons"]["costcrew"] = ""
json.dump(d, open(p, "w"), indent=2)')" \
	"gives no reason"

run_case "manifest-is-true: the add-on list is emptied" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json, collections
p = "components.json"
d = json.load(open(p), object_pairs_hook=collections.OrderedDict)
d["components"][0]["checked"]["optional_addons"] = {}
json.dump(d, open(p, "w"), indent=2)')" \
	"measured NOTHING about what no install may start"

# The bus gates see the add-on's preparer as a preparer, and still judge it.
run_case "bus-has-a-writer: the add-on's data volume is prepared by nobody" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "        chown -R 10003:10003 /vol/costcrew && chmod 0750 /vol/costcrew\n", "")')" \
	"no chown line there names /vol/costcrew"

run_case "bus-has-a-writer: the add-on's stream is given to no one it runs as" fail \
	'./scripts/bus-has-a-writer.sh' \
	"$(py 'edit("compose.yaml", "chown 10003:10001 /vol/events/costcrew.ndjson", "chown 10001:10001 /vol/events/costcrew.ndjson")')" \
	"neither the uid nor the gid matches"

run_case "bus-names: the console writes a stream no reader knows" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "      - -stack-events\n      - /var/lib/stack/events/costcrew.ndjson\n", "      - -stack-events\n      - /var/lib/stack/events/finops.ndjson\n")')" \
	"is not a stream name heraldyx"

run_case "bus-names: the console is told to write another plane's file" fail \
	'./scripts/bus-names-match-their-source.sh' \
	"$(py 'edit("compose.yaml", "      - -stack-events\n      - /var/lib/stack/events/costcrew.ndjson\n", "      - -stack-events\n      - /var/lib/stack/events/wardryx.ndjson\n")')" \
	"refuse every line of it"

# A read-only root needs a writable temp: without one SQLite cannot VACUUM
# (disk I/O error 6410), found by the v0.4.0 pin (#93).
run_case "finops: the console loses its writable temp" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    tmpfs:\n      - /tmp:size=128m\n", "")')" \
	"nothing writable is mounted at /tmp"

run_case "finops: its temp has no size limit" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - /tmp:size=128m\n", "      - /tmp\n")')" \
	"has no size= limit"

run_case "finops: TMPDIR points into the read-only root" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    tmpfs:\n      - /tmp:size=128m\n", "    environment:\n      TMPDIR: /var/tmp\n")')" \
	"nothing writable is mounted at /var/tmp (TMPDIR)"

# ...and what none of them may mind.
run_case "finops: the owner default changes" pass \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "${COSTCREW_OWNER:-${ALERT_TO:-}}", "${COSTCREW_OWNER:-${ALERT_TO:-nobody}}")')"

run_case "finops: the pinned tag moves" pass \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/costcrew:v0.10.0@sha256:26316b1c99706529a4589a328b2ddd3fc5f4db4cf0b5a46466e8be1ddd8f0de9}", "ghcr.io/taipanbox/costcrew:v0.6.1}")')"

run_case "finops: the loopback port moves" pass \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - \"127.0.0.1:8321:8321\"", "      - \"127.0.0.1:18321:8321\"")')"

run_case "finops: a comment in the core mentions the console" pass \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "  # Kubernetes has `fsGroup` for exactly this", "  # costcrew is not here; Kubernetes has `fsGroup` for exactly this")')"

run_case "finops: TMPDIR inside its data volume instead of a tmpfs" pass \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "    tmpfs:\n      - /tmp:size=128m\n", "    environment:\n      TMPDIR: /var/lib/costcrew\n")')"

run_case "finops: the temp size changes" pass \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("compose.yaml", "      - /tmp:size=128m\n", "      - /tmp:size=256m\n")')"

# invariant 25: a public repository carries no quote of the owner, no owner
# provenance marker and no attribution by name. Every planted string is built
# from pieces, so this file never trips the gate it tests.
run_case "no-owner-quotes: an owner provenance marker" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("README.md", "a").write("\n`@" + "yur" + "ii 2026-10-08`: keep it.\n")')" \
	"the owner's provenance marker"

run_case "no-owner-quotes: a quote in Ukrainian" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("CLAUDE.md", "a").write("\n\"\u0440\u043e\u0431\u0438 \u0432\u0441\u0435\"\n")')" \
	"Cyrillic text"

run_case "no-owner-quotes: a quote in guillemets" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("compose.yaml", "a").write("\n# \u00abdo it all\u00bb\n")')" \
	"a guillemet"

run_case "no-owner-quotes: an attribution by name" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("install.sh", "a").write("\n# " + "Yur" + "ii asked for this.\n")')" \
	"the owner's name outside a copyright or author line"

# A hook runs with GIT_DIR set to the repository being pushed, and neither
# `git -C` nor a change of directory clears it: `git init` would reinitialise
# that repository instead of "$d", and the gate's own `git ls-files` would list
# its files, so the case would pass and read TOOTHLESS. Both calls drop the
# three variables git exports into a hook (estate-gates C9).
run_case "no-owner-quotes: no tracked text file to judge" fail_env \
	'd="$(mktemp -d)" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$d" init -q && mkdir "$d/scripts" && cp scripts/no-owner-quotes.sh "$d/scripts/" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE "$d/scripts/no-owner-quotes.sh"' \
	"$(py 'pass')" \
	"measured NOTHING"

run_case "no-owner-quotes: the owner as copyright holder" pass \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("LICENSE", "a").write("\nCopyright 2026 " + "Yur" + "ii Kost" + "iuk\n")')"

run_case "no-owner-quotes: a decision recorded as @decided and a paraphrase" pass \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("README.md", "a").write("\n`@decided 2026-10-08`: the console keeps a writable temp.\n")')"

# Rewording a comment, or adding a statement after the call, changes nothing the
# gate is about.
run_case "bind-is-honoured: the probe function's comment is reworded" pass \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "# A function, called again after every", "# It is a function, called again after every")')"

run_case "bind-is-honoured: another statement follows the probe call" pass \
	'./scripts/bind-is-honoured.sh' \
	"$(py 'edit("install.sh", "# gateway-probe: end\ngateway_probe_resolve\n", "# gateway-probe: end\ngateway_probe_resolve\n: the probe is set\n")')"

# A longer wait between a check_log's tries is a tuning, not a change of what it
# reports.
run_case "checks-survive-a-closed-pipe: the retry count changes" pass \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "local left=10", "local left=12")')"

# A check that reads no log and pipes nothing is outside this gate's subject.
run_case "checks-survive-a-closed-pipe: a check that reads no log is added" pass \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "check \"cloud answers inside\"", "check \"extra: nothing to read\" \"true\"\ncheck \"cloud answers inside\"")')"

# Matching without regard to case still finds the line and still misses its absence.
run_case "checks-survive-a-closed-pipe: a log check matches case-insensitively" pass \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "grep -q \x27NDJSON export enabled\x27", "grep -qi \x27NDJSON export enabled\x27")')"

run_case "checks-survive-a-closed-pipe: a comment is added inside the helpers" pass \
	'./scripts/checks-survive-a-closed-pipe.sh' \
	"$(py 'edit("install.sh", "# check-helpers: begin\n", "# check-helpers: begin\n# a comment that changes no behaviour\n")')"

# A message that names the file reads nothing.
run_case "gen-is-bounded: a message names /dev/urandom" pass \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "# gen: end\n", "# gen: end\nnote \"secrets are minted from /dev/urandom, 4096 bytes at a time\"\n")')"

run_case "gen-is-bounded: a comment names the unbounded idiom" pass \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "# gen: begin\n", "# gen: begin\n# never: tr -dc A-Za-z0-9 </dev/urandom | head -c N\n")')"

run_case "gen-is-bounded: the read gets larger" pass \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("install.sh", "v=\"$(head -c 4096 /dev/urandom |", "v=\"$(head -c 8192 /dev/urandom |")')"

run_case "felyx-through-the-gateway: the closing report's note is reworded" pass \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "calls this gateway too. GENARYX_COPILOT_FUSE_KEY is", "also calls this gateway. GENARYX_COPILOT_FUSE_KEY is")')"

# status: `./install.sh status` checks the installed stack and changes nothing
# (scripts/status-is-read-only.sh). Each fault is one way status could stop being a read.
run_case "status-is-read-only: status brings the stack up first" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "  status_facts\n  printf '"'"'status of the stack", "  status_facts\n  \"${COMPOSE[@]}\" up -d >/dev/null 2>&1 || true\n  printf '"'"'status of the stack")')" \
	"changed the stack"

run_case "status-is-read-only: status issues the first device" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "  status_facts\n  printf '"'"'status of the stack", "  status_facts\n  \"${COMPOSE[@]}\" exec -T console /usr/local/bin/genaryx-web issue-device >/dev/null 2>&1 || true\n  printf '"'"'status of the stack")')" \
	"changed the stack"

run_case "status-is-read-only: status runs the package step" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "  status_facts\n  printf '"'"'status of the stack", "  status_facts\n  apt-get install -y -qq jq >/dev/null 2>&1 || true\n  printf '"'"'status of the stack")')" \
	"changed the stack"

run_case "status-is-read-only: a write probe runs in status" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "install_only check \"chain verifier can write its own stream\"", "check \"chain verifier can write its own stream\"")')" \
	"changed the stack"

run_case "status-is-read-only: a refused metered call is sent by status" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "install_only check \"client keys: a call with no key is refused\"", "check \"client keys: a call with no key is refused\"")')" \
	"changed the stack"

run_case "status-is-read-only: status runs on a directory with no .env" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "  [ -f \"$STACK_DIR/.env\" ] || die \"nothing is installed", "  true || die \"nothing is installed")')" \
	"did not say that nothing is installed"

run_case "status-is-read-only: the status entry point is gone" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "if [ \"${1:-}\" = status ]; then status_main; fi", "# no status entry point")')" \
	"no status entry point"

run_case "status-is-read-only: the verdict line is reworded" fail \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "printf '"'"'\\nevery check passed\\n'"'"'; exit 0", "printf '"'"'\\nall fine\\n'"'"'; exit 0")')" \
	"does not print the success verdict"

run_case "status-is-read-only: a comment in the status block is reworded" pass \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "# check. No package, image, container or file is touched;", "# check. Nothing on the box is touched;")')"

run_case "status-is-read-only: a comment in the shared check list is reworded" pass \
	'./scripts/status-is-read-only.sh' \
	"$(py 'edit("install.sh", "# every check the verification runs, in the order it runs them.", "# every check the verification runs, in the order they run.")')"

# health-checks: Docker watches every service that exposes a health path, and no
# distroless one (scripts/health-checks-are-declared.sh).
run_case "health-checks-are-declared: the console has no healthcheck" fail \
	'./scripts/health-checks-are-declared.sh' \
	"$(py 'import sys
s = open("compose.yaml").read()
i = s.index("\n  console:\n")
j = s.index("    healthcheck:", i)
k = s.index("      start_period: 15s\n", j) + len("      start_period: 15s\n")
open("compose.yaml", "w").write(s[:j] + s[k:])')" \
	"console: no healthcheck"

run_case "health-checks-are-declared: the gateway probes the wrong port" fail \
	'./scripts/health-checks-are-declared.sh' \
	"$(py 'edit("compose.yaml", "exec 3<>/dev/tcp/127.0.0.1/4100 &&", "exec 3<>/dev/tcp/127.0.0.1/4101 &&")')" \
	"tokenfuse-gateway: healthcheck does not probe 127.0.0.1:4100"

run_case "health-checks-are-declared: the console asks for a path that is not /healthz" fail \
	'./scripts/health-checks-are-declared.sh' \
	"$(py 's = open("compose.yaml").read()
i = s.index("\n  console:\n")
j = s.index("GET /healthz", i)
open("compose.yaml", "w").write(s[:j] + "GET /status" + s[j + len("GET /healthz"):])')" \
	"console: healthcheck does not ask for /healthz"

run_case "health-checks-are-declared: a distroless service gets a healthcheck" fail \
	'./scripts/health-checks-are-declared.sh' \
	"$(py 'edit("compose.yaml", "  wardryx:\n    <<: *restart\n", "  wardryx:\n    <<: *restart\n    healthcheck:\n      test: [\"CMD\", \"/usr/local/bin/service\", \"version\"]\n      interval: 30s\n")')" \
	"wardryx is distroless"

run_case "health-checks-are-declared: the installer stops asking for the gateway's health path" fail \
	'./scripts/health-checks-are-declared.sh' \
	"$(py 'edit_all("install.sh", ":4100/healthz", ":4199/healthz")')" \
	"install.sh no longer asks for :4100/healthz"

run_case "health-checks-are-declared: compose.yaml has no services to read" fail \
	'./scripts/health-checks-are-declared.sh' \
	"$(py 'edit("compose.yaml", "\nservices:\n", "\nservicez:\n")')" \
	"measured NOTHING"

run_case "health-checks-are-declared: a comment in the healthcheck block is reworded" pass \
	'./scripts/health-checks-are-declared.sh' \
	"$(py 'edit("compose.yaml", "# bash, not curl: these images ship bash", "# bash, not curl: these images carry bash")')"

# ---- metered-doors-require-keys (invariant 35): the gateway every box runs requires
# client keys, every identity map is strict, and a box given no files gets keys the
# installer mints, each bound to its own ids. Cases that reach the minting run the
# lifted block in scratch directories; the last minting case runs the gateway image.
run_case "metered-doors-require-keys: the gateway's client keys get an empty default" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:?set by install.sh, which mints them when no keys file is given}", "TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:-}")')" \
	"not a required"

run_case "metered-doors-require-keys: TOKENFUSE_CLIENT_KEYS goes missing" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:?set by install.sh, which mints them when no keys file is given}\n", "")')" \
	"sets no TOKENFUSE_CLIENT_KEYS"

run_case "metered-doors-require-keys: a gateway's identity map is only warned about" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_IDENTITY_STRICT: enforce\n", "      TOKENFUSE_IDENTITY_STRICT: warn\n")')" \
	"TOKENFUSE_IDENTITY_STRICT: warn, not enforce"

run_case "metered-doors-require-keys: the installer stops minting the agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "  mint_env_secret GATEWAY_AGENT_KEY\n", "")')" \
	"a box given no keys file and no map was refused"

run_case "metered-doors-require-keys: a re-run mints a new secret over the kept one" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "  [ -z \"$(identity_env_get \"$1\")\" ] || return 0\n", "")')" \
	"a re-run minted a new secret over the kept one"

run_case "metered-doors-require-keys: a box with the operator's own keys gets minted keys" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "  elif [ -n \"${CLIENT_KEYS_FILE:-}\" ] || [ -n \"$keys\" ]; then\n", "  elif [ -n \"${CLIENT_KEYS_FILE:-}\" ]; then\n")')" \
	"a box with the operator's own keys in .env decided to mint"

run_case "metered-doors-require-keys: the agents' key may speak as Felyx" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "\"agents\": [\"agent://%s/agents/*\"]", "\"agents\": [\"agent://%s/*\"]")')" \
	"the agents' key may speak as Felyx"

run_case "metered-doors-require-keys: the agent key file is readable by others" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "  chmod 0600 \"$f\" || die", "  chmod 0644 \"$f\" || die")')" \
	"not 600"

run_case "metered-doors-require-keys: the closing report prints the agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "printf \x27      x-fuse-key       the secret in %s (it is not printed here)\\n\x27 \"$STACK_DIR/agent-key\"", "printf \x27      x-fuse-key       %s, the secret in %s\\n\x27 \"$(identity_env_get GATEWAY_AGENT_KEY)\" \"$STACK_DIR/agent-key\"")')" \
	"a minted secret appears"

run_case "metered-doors-require-keys: the closing report stops naming the agents' key file" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "(it is not printed here)\\n\x27 \"$STACK_DIR/agent-key\"", "(it is not printed here)\\n\x27 \".env\"")')" \
	"does not name the agents' key file"

run_case "metered-doors-require-keys: a map without keys is accepted" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "    die \"IDENTITY_MAP_FILE needs CLIENT_KEYS_FILE:", "    : \"IDENTITY_MAP_FILE needs CLIENT_KEYS_FILE:")')" \
	"a map with no keys file on a box with no keys was accepted"

run_case "metered-doors-require-keys: the minted map binds a key id nobody minted" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "{\"key_id\": \"agents\", \"unit\": \"agents\"", "{\"key_id\": \"agent\", \"unit\": \"agents\"")')" \
	"the pinned gateway image refused the pair the installer minted"

run_case "metered-doors-require-keys: no gateway is left to judge" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit_all("compose.yaml", "    command: [\"/usr/local/bin/tokenfuse\"]\n", "    command: [\"/usr/local/bin/tokenfuse\", \"serve\"]\n")')" \
	"measured NOTHING"

run_case "metered-doors-require-keys: the installer's mint block is gone" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("install.sh", "# identity-mint: begin\n", "# identity-mint: start\n")')" \
	"measured nothing about the keys"

run_case "metered-doors-require-keys: a comment beside the client keys is reworded" pass \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("compose.yaml", "      # 403 identity_mismatch. `metered-doors-require-keys.sh` and", "      # 403 identity_mismatch. `metered-doors-require-keys.sh` with")')"

# A box whose keys the installer minted: the closing note about Felyx says its key is
# minted and bound, and asks nothing of the operator.
run_case "felyx-through-the-gateway: the note asks a box with minted keys to bind Felyx by hand" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("install.sh", "  if [ \"${IDENTITY_MINTED:-0}\" = 1 ]; then\n    printf \x27\\n  Felyx, the console", "  if false; then\n    printf \x27\\n  Felyx, the console")')" \
	"asks the operator to do what the installer did"

# Without the typed risk signal the broker asks wardryx itself (invariant 36).
run_case "typed-risk-signal: the broker points at the proxy without the flag" fail \
	'./scripts/typed-risk-signal.sh' \
	"$(py 'edit("compose.yaml", "${TYPED_RISK_WARDRYX_URL:-http://wardryx:8090}", "${TYPED_RISK_WARDRYX_URL:-http://typryx-wardryx-proxy:4330}")')" \
	"not wardryx directly"

# ---- broker-blocks-raw-secrets (invariant 36): the MCP broker blocks raw secrets and
# flagged tool listings and asks wardryx about every tool call, failing closed. The
# gate runs the broker image, so these take a few seconds each.
run_case "broker-blocks-raw-secrets: secrets in tool arguments go back to shadow" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MCP_DLP: block\n", "      TOKENFUSE_MCP_DLP: shadow\n")')" \
	"TOKENFUSE_MCP_DLP: shadow, not block"

run_case "broker-blocks-raw-secrets: TOKENFUSE_MCP_DLP goes missing" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MCP_DLP: block\n", "")')" \
	"sets no TOKENFUSE_MCP_DLP"

run_case "broker-blocks-raw-secrets: the tool scan only warns" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MCP_SCAN: block\n", "      TOKENFUSE_MCP_SCAN: warn\n")')" \
	"TOKENFUSE_MCP_SCAN: warn, not block"

run_case "broker-blocks-raw-secrets: the broker's policy hook is off by default" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("compose.yaml", "${TYPED_RISK_WARDRYX_MODE:-enforce}", "${TYPED_RISK_WARDRYX_MODE:-off}")')" \
	"not enforce with nothing set"

run_case "broker-blocks-raw-secrets: the broker's policy URL is empty by default" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("compose.yaml", "${TYPED_RISK_WARDRYX_URL:-http://wardryx:8090}", "${TYPED_RISK_WARDRYX_URL:-}")')" \
	"empty with nothing set"

run_case "broker-blocks-raw-secrets: the broker fails open" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 's = open("compose.yaml").read()
i = s.index("  tokenfuse-mcp-broker:\n")
a = "      TOKENFUSE_WARDRYX_FAILMODE: closed\n"
j = s.index(a, i)
assert j < s.index("  typryx-wardryx-proxy:\n"), "no fail mode in the broker block"
open("compose.yaml", "w").write(s[:j] + "      TOKENFUSE_WARDRYX_FAILMODE: open\n" + s[j + len(a):])')" \
	"TOKENFUSE_WARDRYX_FAILMODE: open, not closed"

# The image compose resolves for the broker is what C runs, so an image that cannot
# serve it at all is a red gate, not a pass on the static half alone.
run_case "broker-blocks-raw-secrets: the broker image is one that never answers" fail_env \
	'TOKENFUSE_IMAGE=busybox:1.36 ./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'pass')" \
	"never answered as the broker"

run_case "broker-blocks-raw-secrets: no broker is left to judge" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("compose.yaml", "    command: [\"mcp-broker\"]\n", "    command: [\"mcp-broker\", \"--stdio\"]\n")')" \
	"measured NOTHING"

run_case "broker-blocks-raw-secrets: a comment in the broker's block is reworded" pass \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("compose.yaml", "(finding F-009 of the 2026-10-17 review, measured", "(finding F-009 of the 2026-10-17 review; measured")')"

run_case "wardryx-key-is-pep: a fresh .env mints the gateway's key as viewer again" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "WARDRYX_GATEWAY_SECRET:default:pep", "WARDRYX_GATEWAY_SECRET:default:viewer")')" \
	"policy-plane key the role pep"

run_case "wardryx-key-is-pep: the re-run never calls the migration" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "# wardryx-role: end\nwardryx_gateway_role\n", "# wardryx-role: end\n")')" \
	"never calls wardryx_gateway_role"

run_case "wardryx-key-is-pep: the migration is called after the stack comes up" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "# wardryx-role: end\nwardryx_gateway_role\n", "# wardryx-role: end\n")
edit("install.sh", "up -d --remove-orphans\n", "up -d --remove-orphans\nwardryx_gateway_role\n")')" \
	"after the first 'up -d'"

run_case "wardryx-key-is-pep: the migration is switched off" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "wardryx_gateway_role() {\n", "wardryx_gateway_role() {\n  return 0\n")')" \
	"did not change exactly the gateway's role"

run_case "wardryx-key-is-pep: the migration rewrites a key that is not the gateway's" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "if (index(e, gw \":\") == 1) {", "if (1) {")')" \
	"did not keep the agent list"

run_case "wardryx-key-is-pep: the migration changes the gateway's secret" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "e = gw \":\" org \":pep\" substr(tail, 7)", "e = gw \"x:\" org \":pep\" substr(tail, 7)")')" \
	"did not change exactly the gateway's role"

run_case "wardryx-key-is-pep: the migration drops an agent list the operator wrote" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "\":pep\" substr(tail, 7)", "\":pep\"")')" \
	"did not keep the agent list"

run_case "wardryx-key-is-pep: the migration block is not there" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "# wardryx-role: begin\n", "")')" \
	"re-run migration measured nothing"

run_case "wardryx-key-is-pep: a reworded note is not a fault" pass \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "(its secret is unchanged)", "(its secret stays the same)")')"


# ---- network-membership.sh (CLAUDE.md invariant 38, wave 1 S2) -------------
# Each case plants one fault in the networks, the override, the probes or the
# install workflow, and the gate must go red with the wording it names.
run_case "network-membership: idryx joins the agents network" fail \
	'./scripts/network-membership.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = re.search(r"\n  idryx:\n", s).end()
j = i + re.search(r"\n  [a-z]", s[i:]).start()
b = s[i:j]
assert "      - core\n" in b, "idryx has no core line"
open("compose.yaml", "w").write(s[:i] + b.replace("      - core\n", "      - core\n      - agents\n", 1) + s[j:])')" \
	"the agents network holds idryx"

run_case "network-membership: the browser joins core" fail \
	'./scripts/network-membership.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = re.search(r"\n  scopyx-browser:\n", s).end()
j = i + re.search(r"\n  [a-z]", s[i:]).start()
b = s[i:j]
assert "      edge:\n" in b, "scopyx-browser has no edge line"
open("compose.yaml", "w").write(s[:i] + b.replace("      edge:\n", "      edge:\n      core:\n", 1) + s[j:])')" \
	"scopyx-browser is on core"

run_case "network-membership: the console joins edge" fail \
	'./scripts/network-membership.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = re.search(r"\n  console:\n", s).end()
j = i + re.search(r"\n  [a-z]", s[i:]).start()
b = s[i:j]
assert "      - front\n" in b, "console has no front line"
open("compose.yaml", "w").write(s[:i] + b.replace("      - front\n", "      - front\n      - edge\n", 1) + s[j:])')" \
	"console is on network edge"

run_case "network-membership: agents is not internal" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "  agents:\n    internal: true\n", "  agents:\n")')" \
	"network agents must be internal"

run_case "network-membership: risk-signal is not internal" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "  risk-signal:\n    internal: true\n", "  risk-signal:\n")')" \
	"network risk-signal must be internal"

run_case "network-membership: front masquerades" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "com.docker.network.bridge.enable_ip_masquerade: \"false\"", "com.docker.network.bridge.enable_ip_masquerade: \"true\"")')" \
	"network front must not masquerade"

run_case "network-membership: wg is on the default network" fail \
	'./scripts/network-membership.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = re.search(r"\n  wg:\n", s).end()
j = i + re.search(r"\n  [a-z]", s[i:]).start()
b = s[i:j]
assert "      - edge\n" in b, "wg has no edge line"
s = s[:i] + b.replace("      - edge\n", "      - default\n", 1) + s[j:]
s = s.replace("\n  edge:\n", "\n  default:\n  edge:\n", 1)
open("compose.yaml", "w").write(s)')" \
	"wg is on the default network"

run_case "network-membership: a service the table does not name" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "\nvolumes:\n", "\n  probe:\n    image: busybox:1.36\n    networks:\n      - core\n\nvolumes:\n")')" \
	"probe is not in the table"

run_case "network-membership: typryx gets edge under the stub" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("install.sh", "  case \"${TYPED_MODE:-}\" in jev | own-model) typed=1 ;; esac", "  typed=1")')" \
	"typryx is on"

run_case "network-membership: scopyx-browser loses its agents alias" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "        aliases: [\"scopyx\"]\n", "        aliases: [\"browser\"]\n")')" \
	"lost the alias scopyx"

run_case "network-membership: install.yml loses the agents probe" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit_all(".github/workflows/install.yml", "agent-stack_agents", "agent-stack_core")')" \
	"does not probe the agents network"

run_case "network-membership: install.sh probes the default network" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("install.sh", "NET=\"agent-stack_core\"", "NET=\"agent-stack_default\"")')" \
	"install.sh names the agent-stack_default network"

run_case "network-membership: the egress block is not there" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("install.sh", "# egress-override: begin\n", "")')" \
	"measured nothing"

run_case "network-membership: a reworded comment is not a fault" pass \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "    # Agent-facing, so an agent reaches it under the name `scopyx`; edge,", "    # Agent-facing: an agent reaches it under the name `scopyx`; edge,")')"

run_case "network-membership: no services resolve, so nothing was measured" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "\nservices:\n", "\nservices: {}\nx-unused:\n")')" \
	"measured nothing"


run_case "network-membership: a third member joins the browser's network" fail \
	'./scripts/network-membership.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = re.search(r"\n  idryx:\n", s).end()
j = i + re.search(r"\n  [a-z]", s[i:]).start()
b = s[i:j]
assert "      - core\n" in b, "idryx has no core line"
open("compose.yaml", "w").write(s[:i] + b.replace("      - core\n", "      - core\n      - browser-policy\n", 1) + s[j:])')" \
	"browser-policy members are"

run_case "network-membership: the browser's network loses wardryx" fail \
	'./scripts/network-membership.sh' \
	"$(py 'import re
s = open("compose.yaml").read()
i = re.search(r"\n  wardryx:\n", s).end()
j = i + re.search(r"\n  [a-z]", s[i:]).start()
b = s[i:j]
assert "      - browser-policy\n" in b, "wardryx has no browser-policy line"
open("compose.yaml", "w").write(s[:i] + b.replace("      - browser-policy\n", "", 1) + s[j:])')" \
	"browser-policy members are"

run_case "network-membership: browser-policy is not internal" fail \
	'./scripts/network-membership.sh' \
	"$(py 'edit("compose.yaml", "  browser-policy:\n    internal: true\n", "  browser-policy:\n")')" \
	"network browser-policy must be internal"

# ---- no-provider-key-outside-the-gateway (CLAUDE.md invariant 39, wave 1 S1) ----
# The provider key is held by the gateway: read from a file mounted read only into the
# door that uses it, never a value in another service's environment, and written by the
# installer 0400 and owned by the gateway's uid.
run_case "no-provider-key-outside-the-gateway: the console gets the provider key back" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n      ANTHROPIC_API_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n")')" \
	"carries ANTHROPIC_API_KEY as an environment value"

run_case "no-provider-key-outside-the-gateway: Felyx reads the provider key by reference" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_API_KEY_REF: env:GENARYX_COPILOT_FUSE_KEY\n", "      GENARYX_COPILOT_API_KEY_REF: env:GENARYX_COPILOT_KEY\n")')" \
	"takes its key from env:GENARYX_COPILOT_KEY"

run_case "no-provider-key-outside-the-gateway: the gateway loses its key file" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_UPSTREAM_KEY_FILE: ${GATEWAY_UPSTREAM_KEY_FILE:-}\n", "")')" \
	"sets no TOKENFUSE_UPSTREAM_KEY_FILE"

run_case "no-provider-key-outside-the-gateway: the OpenAI door reads the Anthropic key file" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'door("TOKENFUSE_UPSTREAM_KEY_FILE: ${OPENAI_DOOR_UPSTREAM_KEY_FILE:-}", "TOKENFUSE_UPSTREAM_KEY_FILE: ${GATEWAY_UPSTREAM_KEY_FILE:-}")')" \
	"reads TOKENFUSE_UPSTREAM_KEY_FILE"

run_case "no-provider-key-outside-the-gateway: the gateway mounts its key directory read-write" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      - ./upstream/anthropic:/run/upstream:ro\n", "      - ./upstream/anthropic:/run/upstream:rw\n")')" \
	"does not mount ./upstream/anthropic at /run/upstream read only"

run_case "no-provider-key-outside-the-gateway: the console mounts the Anthropic key directory" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      - ./closure:/run/closure:ro\n", "      - ./closure:/run/closure:ro\n      - ./upstream/anthropic:/run/upstream:ro\n")')" \
	"mounts /run/upstream, the provider key's directory"

run_case "no-provider-key-outside-the-gateway: the installer stops writing the key file" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("install.sh", "# upstream-key: begin\n", "# upstream-key: gone\n")')" \
	"has no '# upstream-key: begin'"

run_case "no-provider-key-outside-the-gateway: the key file is readable by everyone" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("install.sh", "chmod 0400 \"$tmp\"", "chmod 0444 \"$tmp\"")')" \
	"does not set mode 0400 on the key file"

run_case "no-provider-key-outside-the-gateway: the gateway's key file goes back to uid 10001" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("install.sh", "UP_UID_ANTHROPIC=20010   # tokenfuse-gateway", "UP_UID_ANTHROPIC=10001   # tokenfuse-gateway")')" \
	"runs as uid 20010 in compose.yaml"

run_case "no-provider-key-outside-the-gateway: the gateway runs as a uid the key file is not given to" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "    user: \"20010:10001\"", "    user: \"20099:10001\"")')" \
	"runs as uid 20099 in compose.yaml"

run_case "no-provider-key-outside-the-gateway: Felyx's key is moved without the operator's word" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("install.sh", "elif [ \"$UP_ADOPT_COPILOT\" = 1 ] && [ ! -f", "elif [ ! -f")')" \
	"without the operator's GATEWAY_HOLDS_COPILOT_KEY=1"

run_case "no-provider-key-outside-the-gateway: a box with only Felyx's key is no longer stopped" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("install.sh", "the provider key Felyx used before 1.2.0", "an older key")')" \
	"does not stop a box whose only provider key is GENARYX_COPILOT_KEY"

run_case "no-provider-key-outside-the-gateway: a re-owned key file is left readable by everyone" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("install.sh", "chmod 0400 \"$1\"", "chmod 0444 \"$1\"")')" \
	"does not set mode 0400 on an existing key file it re-owns"

run_case "no-provider-key-outside-the-gateway: a harmless variable is not a fault" pass \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n", "      GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}\n      GATE_HARMLESS_NOTE: \"one\"\n")')"

run_case "no-provider-key-outside-the-gateway: no gateway left to judge" fail \
	'./scripts/no-provider-key-outside-the-gateway.sh' \
	"$(py 'edit_all("compose.yaml", "command: [\"/usr/local/bin/tokenfuse\"]", "command: [\"/usr/local/bin/tokenfuse-moved\"]")')" \
	"measured NOTHING"



# ---- agent-tokens-are-wired: vouchryx signs with keyryx (CLAUDE.md invariant 55) ----
run_case "agent-tokens-are-wired: vouchryx's default signer is the file key again" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "VOUCHRYX_SIGNER: ${VOUCHRYX_SIGNER:-keyryx}", "VOUCHRYX_SIGNER: ${VOUCHRYX_SIGNER:-file}")')" \
	"the default must be keyryx"

run_case "agent-tokens-are-wired: vouchryx does not wait for keyryx" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "      keyryx:\n        condition: service_started\n", "")')" \
	"does not wait for keyryx"

run_case "agent-tokens-are-wired: the file signer keeps a keyryx variable" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "VOUCHRYX_KEYRYX_URL: ${VOUCHRYX_KEYRYX_URL:-}", "VOUCHRYX_KEYRYX_URL: http://keyryx:4340")')" \
	"the file signer resolves VOUCHRYX_KEYRYX_URL"

run_case "agent-tokens-are-wired: vouchryx is started before its root pin is taken" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  vouchryx_signer_apply\n  \"${COMPOSE[@]}\" --profile delegation up -d vouchryx\n", "  \"${COMPOSE[@]}\" --profile delegation up -d vouchryx\n  vouchryx_signer_apply\n")')" \
	"does not call vouchryx_signer_apply before"

run_case "agent-tokens-are-wired: the file signer leaves its keyryx lines in .env" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "typed_forget_env VOUCHRYX_KEYRYX_URL VOUCHRYX_KEYRYX_CONSUMER VOUCHRYX_KEYRYX_SOCKET VOUCHRYX_KEYRYX_CREDENTIAL_FILE VOUCHRYX_KEYRYX_ROOT_PIN", ":")')" \
	"left keyryx lines in .env"

run_case "agent-tokens-are-wired: a re-run replaces the root pin" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "      if [ -z \"$(typed_env_get VOUCHRYX_KEYRYX_ROOT_PIN)\" ]; then", "      if true; then")')" \
	"replaced the root pin already in .env"

run_case "agent-tokens-are-wired: the root pin accepts an ES384 kid of the wrong length" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "[[ \"$k\" =~ $re_es ]] || return 1", "[[ -n \"$k\" ]] || return 1")')" \
	"was accepted"

run_case "agent-tokens-are-wired: the root pin accepts an ML-DSA-65 kid without its prefix" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "[[ \"$k\" =~ $re_ml ]] || return 1", "[[ -n \"$k\" ]] || return 1")')" \
	"was accepted"

# ---- agent-tokens-are-wired (CLAUDE.md invariant 40, wave 1 S4) ----------------
# The agent's own token is accepted only where it is verified: required by default (CLAUDE.md
# invariant 47), and the two doors check it against vouchryx for their own audience, against a revocation list
# that fails closed, and vouchryx publishes nothing and keeps the enrolment secret out of .env.
run_case "agent-tokens-are-wired: the switch is off by default" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit_all("compose.yaml", "TOKENFUSE_AGENT_TOKENS: ${TOKENFUSE_AGENT_TOKENS:-require}", "TOKENFUSE_AGENT_TOKENS: ${TOKENFUSE_AGENT_TOKENS:-off}")')" \
	"the default must be require"

run_case "agent-tokens-are-wired: the gateway names no static-key list" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_AGENT_TOKENS_STATIC_KEYS: ${TOKENFUSE_AGENT_TOKENS_STATIC_KEYS:-}\n", "")')" \
	"has no TOKENFUSE_AGENT_TOKENS_STATIC_KEYS"

run_case "agent-tokens-are-wired: the broker names no static-key list" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS: ${TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS:-}\n", "")')" \
	"has no TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS"

run_case "agent-tokens-are-wired: the installer writes accept again" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  identity_env_set TOKENFUSE_AGENT_TOKENS require\n", "  identity_env_set TOKENFUSE_AGENT_TOKENS accept\n")')" \
	"still writes accept"

run_case "agent-tokens-are-wired: wardryx names another audience" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  identity_env_set WARDRYX_AGENT_TOKEN_AUDIENCES \"$AGENT_AUDIENCE\"\n", "  identity_env_set WARDRYX_AGENT_TOKEN_AUDIENCES \"https://other.example\"\n")')" \
	"does not write 'identity_env_set WARDRYX_AGENT_TOKEN_AUDIENCES"

run_case "agent-tokens-are-wired: wardryx polls no revocation list" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  identity_env_set WARDRYX_AGENT_TOKEN_REVOCATION_URL http://vouchryx:4310/v1/revocations\n", "")')" \
	"WARDRYX_AGENT_TOKEN_REVOCATION_URL http://vouchryx:4310/v1/revocations"

run_case "agent-tokens-are-wired: wardryx does not name the broker's door" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", ",http://tokenfuse-mcp-broker:4200,http://$GATEWAY_PROBE:4100", ",http://$GATEWAY_PROBE:4100")')" \
	"door origins do not name the gateway and the broker"

run_case "agent-tokens-are-wired: the off path keeps its static-key list" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "TOKENFUSE_AGENT_TOKENS_STATIC_KEYS TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS; do", "TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS; do")')" \
	"does not clear the static-key lists"

run_case "agent-tokens-are-wired: the allow-list drops felyx" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "named=\"felyx broker\"", "named=\"broker\"")')" \
	"H. a fresh box names felyx"

run_case "agent-tokens-are-wired: the allow-list lists a key the box does not hold" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "    case \"$have\" in *\" $id \"*) ;; *) continue ;; esac\n", "")')" \
	"a key the box does not hold is never named"

run_case "agent-tokens-are-wired: a re-run drops an existing key id" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "for id in $named $EXISTING_GATEWAY_IDS $STATIC_KEY_IDS_LIST; do", "for id in $named $STATIC_KEY_IDS_LIST; do")')" \
	"H. a box from before the list keeps its own keys"

run_case "agent-tokens-are-wired: the gateway's audience is empty" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_DELEGATION_AUDIENCE: ${TOKENFUSE_DELEGATION_AUDIENCE:-}\n", "      TOKENFUSE_DELEGATION_AUDIENCE: \"\"\n")')" \
	"is empty"

run_case "agent-tokens-are-wired: the revocation list fails open" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit_all("compose.yaml", "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE: closed", "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE: open")')" \
	"does not fail closed"

run_case "agent-tokens-are-wired: the gateway polls no revocation list" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit_all("compose.yaml", "      TOKENFUSE_DELEGATION_REVOCATIONS: ${TOKENFUSE_DELEGATION_REVOCATIONS:-}\n", "      TOKENFUSE_DELEGATION_REVOCATIONS: \"\"\n")')" \
	"polls no revocation list"

run_case "agent-tokens-are-wired: the broker's taint-gateway key file is gone" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE: ${BROKER_GATEWAY_KEY_FILE:-}\n", "      TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE: \"\"\n")')" \
	"reads its taint-gateway key from"

run_case "agent-tokens-are-wired: the broker does not mount its key directory" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "      - ./broker:/run/broker:ro\n", "")')" \
	"does not mount ./broker at /run/broker read only"

run_case "agent-tokens-are-wired: vouchryx publishes a port" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "    environment:\n      # keyryx unless .env says file", "    ports:\n      - \"127.0.0.1:4310:4310\"\n    environment:\n      # keyryx unless .env says file")')" \
	"publishes ports"

run_case "agent-tokens-are-wired: the installer writes the enrolment secret to .env" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  identity_env_set VOUCHRYX_AGENTS \"$AGENT_TOKEN_AGENT|agents|local|sha256:$digest\"\n", "  identity_env_set VOUCHRYX_AGENTS \"$AGENT_TOKEN_AGENT|agents|local|sha256:$digest\"\n  identity_env_set ENROL_SECRET \"$secret\"\n")')" \
	"writes an enrolment secret into .env"

run_case "agent-tokens-are-wired: the broker names a different audience from the gateway" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "      TOKENFUSE_DELEGATION_AUDIENCE: ${MCP_BROKER_DELEGATION_AUDIENCE:-}\n", "      TOKENFUSE_DELEGATION_AUDIENCE: ${MCP_BROKER_DELEGATION_AUDIENCE:-}/other\n")')" \
	"must verify at both doors"

run_case "agent-tokens-are-wired: the installer names an audience that is not https" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "AGENT_AUDIENCE=\"https://stack-single.$td\"", "AGENT_AUDIENCE=\"http://stack-single.$td\"")')" \
	"names no https audience"

run_case "agent-tokens-are-wired: the installer writes the audience as a plain origin again" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  identity_env_set VOUCHRYX_ALLOWED_AUDIENCES \"$AGENT_AUDIENCE\"\n", "  identity_env_set VOUCHRYX_ALLOWED_AUDIENCES \"http://$GATEWAY_PROBE:4100\"\n")')" \
	"does not write the allowed audience from AGENT_AUDIENCE"

run_case "agent-tokens-are-wired: a reworded comment is not a fault" pass \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "# What this does NOT do, named here", "# What this does not do, named here")')"

run_case "agent-tokens-are-wired: no vouchryx service left to judge" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("compose.yaml", "  vouchryx:\n    <<: *restart\n", "  vouchryx-moved:\n    <<: *restart\n")')" \
	"measured NOTHING"

# invariant 41: no plane writes another plane's stream. Each case plants one
# fault in the compose file or the installer, and the gate must go red on it.
run_case "no-plane-writes: two producers run as one uid" fail \
	'./scripts/no-plane-writes-another-planes-stream.sh' \
	"$(py 'edit("compose.yaml", "    user: \"20010:10001\"\n", "    user: \"20013:10001\"\n")')" \
	"tokenfuse-cloud"

run_case "no-plane-writes: a stream is world-readable (0644)" fail \
	'./scripts/no-plane-writes-another-planes-stream.sh' \
	"$(py 'edit("compose.yaml", "chown 20001:10001 /vol/events/wardryx.ndjson && chmod 0640 /vol/events/wardryx.ndjson", "chown 20001:10001 /vol/events/wardryx.ndjson && chmod 0644 /vol/events/wardryx.ndjson")')" \
	"want 0640"

run_case "no-plane-writes: the bus directory is group-writable" fail \
	'./scripts/no-plane-writes-another-planes-stream.sh' \
	"$(py 'edit("compose.yaml", "chown 0:10001 /vol/events && chmod 0751 /vol/events", "chown 0:10001 /vol/events && chmod 2775 /vol/events")')" \
	"bus directory"

run_case "no-plane-writes: a reworded comment in init-volumes is not a fault" pass \
	'./scripts/no-plane-writes-another-planes-stream.sh' \
	"$(py 'edit("compose.yaml", "# Invariant 41. The bus directory is", "# Invariant 41: the bus directory is")')"

# invariant 43: the root keys are files, never environment values or .env lines.
run_case "keyryx-root: a root key is written into .env" fail \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("install.sh", "keyryx_root_key() { # FILE UID: create FILE with 32 random bytes when absent\n", "keyryx_root_key() { # FILE UID: create FILE with 32 random bytes when absent\n  add_env_default KEYRYX_ROOT_KEY \"x\"\n")')" \
	"KEYRYX_ROOT_KEY"

run_case "keyryx-root: custody interpolates its root key from .env" fail \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("compose.yaml", "      KEYRYX_DATA: /var/lib/keyryx\n", "      KEYRYX_DATA: /var/lib/keyryx\n      KEYRYX_ROOT_KEY: ${KEYRYX_ROOT_KEY:?set by install.sh}\n")')" \
	"KEYRYX_ROOT_KEY"

run_case "keyryx-root: a reworded comment in install.sh is not a fault" pass \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("install.sh", "# Two root keys, one per role, each 32 random bytes (64 hex characters), written ONCE", "# Two root keys, one for each role, each 32 random bytes (64 hex characters), written ONCE")')"

# invariant 43: the witness is a process apart from custody.
run_case "witness-is-separate: the witness runs under custody's uid" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("compose.yaml", "    user: \"20100:10001\"\n", "    user: \"20101:10001\"\n")')" \
	"same uid"

run_case "witness-is-separate: the witness mounts custody's state" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("compose.yaml", "      - keyryxwitness:/var/lib/keyryx-witness\n", "      - keyryxwitness:/var/lib/keyryx-witness\n      - keyryxstate:/var/lib/keyryx-custody-peek\n")')" \
	"share state"

run_case "witness-is-separate: the witness has a network" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("compose.yaml", "    network_mode: none\n", "    networks:\n      - core\n")')" \
	"has a network"

run_case "witness-is-separate: a reworded comment in the witness block is not a fault" pass \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("compose.yaml", "# No network at all: the witness has nothing", "# No network at all, the witness has nothing")')"

run_case "witness-is-separate: no keyryx service left to judge" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("compose.yaml", "  keyryx-witness:\n", "  keyryx-witness-moved:\n")')" \
	"measured nothing"


# ---- images-are-digest-pinned and images-are-verified (CLAUDE.md invariant 44) --
run_case "images-are-digest-pinned: a published image loses its digest" fail \
	'./scripts/images-are-digest-pinned.sh' \
	"$(py 'edit("compose.yaml", "trailryx-node:v1.4.0@sha256:79da026eab19b2b8ade994cbb65850b39f644c4b632edf1de411f70bddd047d3}", "trailryx-node:v1.4.0}")')" \
	"trailryx-node:v1.4.0 is not pinned"

run_case "images-are-digest-pinned: a digest is cut short" fail \
	'./scripts/images-are-digest-pinned.sh' \
	"$(py 'edit("compose.yaml", "trailryx-node:v1.4.0@sha256:79da026eab19b2b8ade994cbb65850b39f644c4b632edf1de411f70bddd047d3}", "trailryx-node:v1.4.0@sha256:ab305ac6a65444e08090b56d6f666498b56d560f7351c96a8a84137ece9e6d3}")')" \
	"is not pinned by a full sha256 digest"

run_case "images-are-digest-pinned: the third-party postgres loses its digest" fail \
	'./scripts/images-are-digest-pinned.sh' \
	"$(py 'edit("compose.yaml", "postgres:16-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea", "postgres:16-alpine")')" \
	"postgres:16-alpine is not pinned"

run_case "images-are-digest-pinned: the installer names a digest compose does not run" fail \
	'./scripts/images-are-digest-pinned.sh' \
	"$(py 'edit_all("install.sh", "4a2b6b31be44b5391974785bdfca597a88bcc5ddd834d50830bd6b9537e9ab3d", "1111111111111111111111111111111111111111111111111111111111111111")')" \
	"pinned to a digest compose.yaml does not run"

run_case "images-are-digest-pinned: no image line left to judge" fail \
	'./scripts/images-are-digest-pinned.sh' \
	"$(py 'edit_all("compose.yaml", "    image: ", "    imagex: ")')" \
	"measured NOTHING"

run_case "images-are-digest-pinned: a reworded comment is not a fault" pass \
	'./scripts/images-are-digest-pinned.sh' \
	"$(py 'edit("install.sh", "# ---- 3c. the images, pulled ", "# ---- 3c. the images, pulled and checked ")')"

run_case "images-are-verified: the pull comes before the check" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "        image_verify \"$img\"\n        note \"pulling $img\"\n        docker pull -q \"$img\" >/dev/null || die \"could not pull $img\"\n", "        note \"pulling $img\"\n        docker pull -q \"$img\" >/dev/null || die \"could not pull $img\"\n        image_verify \"$img\"\n")')" \
	"pulls before it verifies"

run_case "images-are-verified: a refused signature does not stop the install" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "die \x22could not check the signature of $name", "note \x22could not check the signature of $name")')" \
	"did not stop the install"

run_case "images-are-verified: the signer accepts any identity" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "TAIPANBOX/(?:", "(?:")')" \
	"not the pinned value"

run_case "images-are-verified: the signer accepts a signer from another workflow file" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "/\\.github/workflows/release\\.yml|", "/\\.github/workflows/[^@]+|")')" \
	"accepts a signer from another workflow file"

run_case "images-are-verified: the signer refuses the release workflow" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "/\\.github/workflows/release\\.yml|", "/\\.github/workflows/release-x\\.yml|")')" \
	"refuses the release identity"

run_case "images-are-verified: a refused fetch of cosign names no host" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "\x22$dest.download\x22 \x22$url\x22 2>&1)\x22", "\x22$dest.download\x22 \x22$url\x22 2>/dev/null)\x22")')" \
	"does not name the host that failed"

run_case "images-are-verified: an unreachable Sigstore trust root is not named" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "die \x22could not reach the Sigstore trust root at tuf-repo-cdn.sigstore.dev, so", "die \x22could not check, so")')" \
	"is not named as one, with its host"

run_case "images-are-verified: a missing signature is reported as having some" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "die \x22$name has no signature from a TAIPANBOX release workflow", "die \x22$name has no signed release from a TAIPANBOX release workflow")')" \
	"is not reported as having none"

run_case "images-are-verified: the signer accepts a branch ref" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "@refs/tags/v[0-9][A-Za-z0-9._+-]*$", "@refs/[^@]*$")')" \
	"accepts a branch ref"

run_case "images-are-verified: the verify call skips the transparency log" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "--certificate-oidc-issuer \"$TAIPANBOX_ISSUER\" \"$ref\"", "--certificate-oidc-issuer \"$TAIPANBOX_ISSUER\" --insecure-ignore-tlog \"$ref\"")')" \
	"weakens the check"

run_case "images-are-verified: a cosign binary with the wrong bytes is installed" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "\"$dest.download\" | sha256sum -c --status", "\"$dest.download\" | cat >/dev/null")')" \
	"was installed at bin/cosign"

run_case "images-are-verified: a third-party image goes to cosign" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "      ghcr.io/*)", "      *)")')" \
	"for the check to sit in"

run_case "images-are-verified: no image-verify block left to judge" fail \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "# image-verify: begin", "# image-verify: begun")')" \
	"measured NOTHING"

run_case "images-are-verified: a reworded comment in the block is not a fault" pass \
	'./scripts/images-are-verified.sh' \
	"$(py 'edit("install.sh", "# A signature is accepted only from", "# A signature is accepted solely from")')"


run_case "demo-issuer-and-smtp-tls: the migration rewrites any line naming the demo host" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "\x27$0 == old { print new; next } { print }\x27", "\x27$0 ~ /idp[.]stack-single[.]local/ { print new; next } { print }\x27")')" \
	"names the demo host, next to the demo line, was rewritten"

run_case "demo-issuer-and-smtp-tls: the new demo line drops |unbound" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "DEMO_ISSUER_NEW=\"$DEMO_ISSUER_OLD|unbound\"", "DEMO_ISSUER_NEW=\"$DEMO_ISSUER_OLD\"")')" \
	"DEMO_ISSUER_NEW is not the demo line with |unbound"

run_case "demo-issuer-and-smtp-tls: the delegation block stops migrating .env" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "  demo_issuer_migrate .env\n", "")')" \
	"does not call demo_issuer_migrate .env"

run_case "demo-issuer-and-smtp-tls: the mail TLS check accepts any value" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "case \"$1\" in \"\"|starttls|implicit|plain) return 0 ;; *) return 1 ;; esac", "case \"$1\" in *) return 0 ;; esac")')" \
	"was accepted"

run_case "demo-issuer-and-smtp-tls: plain is accepted for a host that is not loopback" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "if [ \"${SMTP_TLS:-}\" = plain ] && [ -n \"${SMTP_HOST:-}\" ] && ! smtp_tls_loopback \"$SMTP_HOST\"; then", "if false; then")')" \
	"was accepted for a host"

run_case "demo-issuer-and-smtp-tls: the refusal echoes the value it was given" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "SMTP_TLS must be starttls", "SMTP_TLS=$SMTP_TLS must be starttls")')" \
	"echoed the value"

run_case "demo-issuer-and-smtp-tls: SMTP_TLS is no longer written into .env" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "add_env_default SMTP_TLS   \"$(sq_ \"$SMTP_TLS\")\"\n", "")')" \
	"does not write SMTP_TLS into .env"

run_case "demo-issuer-and-smtp-tls: the demo block is gone" fail \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "# demo-issuer: begin", "# demo-issuer: begun")')" \
	"measured NOTHING"

run_case "demo-issuer-and-smtp-tls: a reworded comment is not a fault" pass \
	'./scripts/demo-issuer-and-smtp-tls.sh' \
	"$(py 'edit("install.sh", "# The demo IdP\x27s line in .env.", "# The demo IdP\x27s line in the env file.")')" \
	""


run_case "no-secret-on-argv: the request helper passes the key as an argument" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "\"${hostport##*:}\"", "\"${hostport##*:}\" \"$hdrs\"")')" \
	"puts a key on the docker argument list"

run_case "no-secret-on-argv: a header goes back on a command line" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "NET=\"agent-stack_core\"\n", "NET=\"agent-stack_core\"\nlegacy_probe() { docker run --rm --network \"$NET\" busybox:1.36 wget -q -O /dev/null --header=\"Authorization: Bearer $CONSOLE_TOKEN\" \"$1\"; }\n")')" \
	"a --header or -H flag on a command line"

run_case "no-secret-on-argv: a secret expanded into a docker command is refused" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "NET=\"agent-stack_core\"\n", "NET=\"agent-stack_core\"\ndocker run --rm -e \"CHECK_SECRET=$CONSOLE_TOKEN\" busybox:1.36 true >/dev/null 2>&1 || true\n")')" \
	"a secret is expanded on a line that runs an argument-carrying program"

run_case "no-secret-on-argv: the console clone puts the token back in its URL" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "      clone --depth 1 -q \"https://github.com/TAIPANBOX/genaryx.git\"", "      clone --depth 1 -q \"https://x-access-token:${CONSOLE_TOKEN}@github.com/TAIPANBOX/genaryx.git\"")')" \
	"carries a credential in its URL"

run_case "no-secret-on-argv: the credential helper stops handing git the token" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "printf \"password=%s\\n\" \"$CONSOLE_TOKEN\"", "printf \"password=%s\\n\" \"not-the-token\"")')" \
	"does not hand git the token"

run_case "no-secret-on-argv: the console clone no longer uses a credential helper" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "git -c credential.helper=", "git -c core.abbrev=")')" \
	"clone line, so the console's token was not measured"

run_case "no-secret-on-argv: a compose command carries a secret" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("compose.yaml", "command: [\"/usr/local/bin/tokenfuse-cloud\"]", "command: [\"/usr/local/bin/tokenfuse-cloud\", \"--token=${TOKENFUSE_CLOUD_KEYS}\"]")')" \
	"a secret is expanded into a compose command"

run_case "no-secret-on-argv: the request helper is gone" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "# argv-free-http: begin", "# argv-free-http: begun")')" \
	"no argument-free request was measured"

run_case "no-secret-on-argv: a comment naming a header flag is not a fault" pass \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "# argv-free-http: begin\n", "# argv-free-http: begin\n# A --header flag named in a comment is not a command line.\n")')" \
	""


run_case "no-secret-on-argv: the clone does not reset the credential helper list" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "git -c credential.helper= -c credential.helper=\x27!f()", "git -c credential.helper=\x27!f()")')" \
	"does not reset the credential helper list"

run_case "no-secret-on-argv: a non-ASCII body is measured in characters" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "  local LC_ALL=C\n", "")')" \
	"a Content-Length in characters, not bytes"


run_case "shell-lint: a function named code is refused" fail \
	'./scripts/shell-lint.sh' \
	"$(py 'edit("install.sh", "NET=\"agent-stack_core\"\n", "NET=\"agent-stack_core\"\ncode() { :; }\n")')" \
	"named after a developer command"

run_case "shell-lint: a function named open, with the keyword, is refused" fail \
	'./scripts/shell-lint.sh' \
	"$(py 'edit("install.sh", "NET=\"agent-stack_core\"\n", "NET=\"agent-stack_core\"\nfunction open { :; }\n")')" \
	"named after a developer command"

run_case "shell-lint: a comment naming code() is not a fault" pass \
	'./scripts/shell-lint.sh' \
	"$(py 'edit("install.sh", "NET=\"agent-stack_core\"\n", "NET=\"agent-stack_core\"\n# code() is not defined here: the name belongs to a developer command.\n")')" \
	""

run_case "no-secret-on-argv: the request helper pipes into nc and loses the answer" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("install.sh", "sh -c \x27f=/tmp/nc-in; mkfifo \"$f\" || exit 1; nc -w 10 \"$1\" \"$2\" < \"$f\" & pid=$!; exec 3>\"$f\"; cat >&3; wait \"$pid\"\x27", "sh -c \x27cat | nc -w 5 \"$1\" \"$2\"\x27")')" \
	"end of input before the server answers"


run_case "no-secret-on-argv: an evidence script passes its enrolment secret on argv" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'edit("docs/evidence/agent-token-audience/measure.sh", "\"$agent\" \"$htu_token\" \"$AUDIENCE\"", "\"$agent\" \"$ENROL_SECRET\" \"$htu_token\" \"$AUDIENCE\"")')" \
	"a secret is expanded on a line that runs an argument-carrying program"

# ---- 1.4.0: the broker line (invariant 48), the re-run allow-list (53), every profile (50), re-owned volumes (49),
# the record plane on by default (51), and the costcrew stream's directory (52). Each fault is planted and the
# named gate must go red; each pass case is a comment, which must leave the gate green.

run_case "broker-key: the README asks for broker:<secret> again" fail \
	'./scripts/broker-key-is-the-keys-file-line.sh' \
	"$(py 'edit("README.md", "`<secret>:broker` line (the secret", "`broker:<secret>` line (the secret")')" \
	"still says broker:<secret>"

run_case "broker-key: the installer refuses a keys file that holds its broker line" fail \
	'./scripts/broker-key-is-the-keys-file-line.sh' \
	"$(py 'edit("install.sh", "    if [ \"$nbl\" = 1 ]; then\n      BROKER_SOURCE=\"file\"", "    if [ \"$nbl\" = 9 ]; then\n      BROKER_SOURCE=\"file\"")')" \
	"a keys file with a '<secret>:broker' line was refused"

run_case "broker-key: ADD_BROKER_KEY=1 appends without checking the identity map" fail \
	'./scripts/broker-key-is-the-keys-file-line.sh' \
	"$(py 'edit("install.sh", "    if [ -n \"${IDENTITY_MAP_FILE:-}\" ] && ! identity_map_binds_broker", "    if false && ! identity_map_binds_broker")')" \
	"was accepted with an identity map that does not bind broker"

run_case "broker-key: a comment beside the broker refusal is not a fault" pass \
	'./scripts/broker-key-is-the-keys-file-line.sh' \
	"$(py 'edit("install.sh", "  BROKER_SOURCE=\"mint\"\n", "  # a comment that names the broker line is not a fault\n  BROKER_SOURCE=\"mint\"\n")')" \
	""

run_case "agent-tokens-are-wired: a re-run widens the static list again (the minted agents and drills join it)" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  if identity_env_has TOKENFUSE_AGENT_TOKENS_STATIC_KEYS; then\n", "  if false; then\n")
edit("install.sh", "grep -v -x -E '\''felyx|broker|agents|drills'\'' | tr", "tr")')" \
	"the second run widened the allow-list"

run_case "agent-tokens-are-wired: the agents key joins the list on the first run" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "named=\"felyx broker\"", "named=\"felyx broker\"\n  STATIC_KEY_IDS_LIST=\"$STATIC_KEY_IDS_LIST agents\"")')" \
	"a fresh box names felyx and broker"

run_case "agent-tokens-are-wired: a re-run keeps the agents key the upgrade dropped" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "    agents|drills) case \" $STATIC_KEY_IDS_LIST \" in *\" $1 \"*) return 0 ;; *) return 1 ;; esac ;;", "    agents|drills) return 0 ;;")')" \
	"loses agents and drills, on both doors"

run_case "agent-tokens-are-wired: the closing report stops saying which keys the run removed" fail \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "Removed from the static allow-lists on this run:", "Changed on this run:")')" \
	"the closing report does not say which keys this run removed"

run_case "agent-tokens-are-wired: a comment about the own agents key is not a fault" pass \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "static_keep_ok() {\n", "static_keep_ok() {\n  # a comment about the own agents key is not a fault\n")')" \
	""

run_case "agent-tokens-are-wired: a comment in the allow-list block is not a fault" pass \
	'./scripts/agent-tokens-are-wired.sh' \
	"$(py 'edit("install.sh", "  named=\"felyx broker\"\n", "  # a comment in the allow-list block is not a fault\n  named=\"felyx broker\"\n")')" \
	""

run_case "profiles-off-are-removed: the cleanup names the off profiles by hand and misses finops" fail \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "  for p in $(\"${COMPOSE[@]}\" config --profiles 2>/dev/null || true); do\n    profile_is_named \"$p\" && continue\n", "  for p in typed-risk-signal openai-door; do\n    profile_is_named \"$p\" && continue\n")')" \
	"the stale typryx of profile typed is not removed"

run_case "profiles-off-are-removed: the cleanup removes the containers of a profile this run names, with no shared-service guard" fail \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "    profile_is_named \"$p\" && continue\n    case \"$(profile_kind \"$p\")\" in", "    case \"$(profile_kind \"$p\")\" in")
edit("install.sh", "      case \" $named_svcs \" in *\" $s \"*) ;; *) off_list=\"$off_list $s\" ;; esac", "      off_list=\"$off_list $s\"")')" \
	"C. record-seal belongs to a profile this run names"

run_case "profiles-off-are-removed: a comment in the profile cleanup is not a fault" pass \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "profiles_off_remove() {\n", "profiles_off_remove() {\n  # a comment in the cleanup is not a fault\n")')" \
	""

run_case "profiles-off-are-removed: a running operator-started container is removed, not kept" fail \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "up -d \"$svc\" >/dev/null 2>&1", "rm -sf \"$svc\" >/dev/null 2>&1")')" \
	"belongs to an operator-started profile, and the installer removed it"

run_case "profiles-off-are-removed: a running operator-started container is not re-upped at this run's pins" fail \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "\"${COMPOSE[@]}\" --profile \"$p\" up -d \"$svc\"", "true")')" \
	"is not re-upped at this run"

run_case "profiles-off-are-removed: a profile the two lists leave out is refused" fail \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "PROFILES_OPERATOR=\"egress egress-browser finops routines manual\"", "PROFILES_OPERATOR=\"egress egress-browser finops manual\"")')" \
	"compose.yaml's profile routines is in neither"

run_case "profiles-off-are-removed: the record plane left out of the installer list keeps record-seal under WITH_RECORD=0" fail \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "PROFILES_INSTALLED=\"record typed typed-risk-signal delegation openai-door\"", "PROFILES_INSTALLED=\"typed typed-risk-signal delegation openai-door\"")')" \
	"D. with WITH_RECORD=0 the running record-seal is not removed"

run_case "finops-is-opt-in: the installer-managed list names the add-on, so the installer could start it" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("install.sh", "PROFILES_INSTALLED=\"record typed", "PROFILES_INSTALLED=\"finops record typed")')" \
	"names the add-on"

run_case "finops-is-opt-in: a line starts the add-on outside the table" fail \
	'./scripts/finops-is-opt-in.sh' \
	"$(py 'edit("install.sh", "profiles_off_remove\n", "profiles_off_remove\n\"${COMPOSE[@]}\" --profile finops up -d costcrew\n")')" \
	"names the add-on"

run_case "profiles-off-are-removed: the operator branch re-ups the core services that ps lists" fail \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "          case \"$own_svcs\" in *\" $svc \"*) ;; *) continue ;; esac", "          :")')" \
	"is re-upped under an operator-started profile"

run_case "profiles-off-are-removed: a comment beside the profile table is not a fault" pass \
	'./scripts/profiles-off-are-removed.sh' \
	"$(py 'edit("install.sh", "PROFILES_OPERATOR=\"egress", "# a comment beside the table is not a fault\nPROFILES_OPERATOR=\"egress")')" \
	""

run_case "volumes-are-reowned: the gateway's traces are re-owned without -R, so its old journal stays uid 10001" fail \
	'./scripts/volumes-are-reowned.sh' \
	"$(py 'edit("compose.yaml", "chown -R 20010:10001 /vol/traces", "chown 20010:10001 /vol/traces")')" \
	"tokenfuse-gateway (uid 20010) writes traces"

run_case "volumes-are-reowned: typryx's ledger volume is never re-owned" fail \
	'./scripts/volumes-are-reowned.sh' \
	"$(py 'edit("compose.yaml", "        chown -R 20005:10001 /vol/typryx && chmod 0775 /vol/typryx\n", "        chmod 0775 /vol/typryx\n")')" \
	"typryx (uid 20005) writes typryxdata"

run_case "volumes-are-reowned: a comment in init-volumes is not a fault" pass \
	'./scripts/volumes-are-reowned.sh' \
	"$(py 'edit("compose.yaml", "        chown -R 20013:10001 /vol/cloud && chmod 0775 /vol/cloud\n", "        # a comment about the cloud volume is not a fault\n        chown -R 20013:10001 /vol/cloud && chmod 0775 /vol/cloud\n")')" \
	""

run_case "record-plane-is-on-by-default: an unset WITH_RECORD turns the record plane off again" fail \
	'./scripts/record-plane-is-on-by-default.sh' \
	"$(py 'edit("install.sh", "    \"\"|1) RECORD_ON=1 ;;", "    \"\"|1) RECORD_ON=0 ;;")')" \
	"WITH_RECORD='' does not turn the record plane on"

run_case "record-plane-is-on-by-default: the up list never names the record profile" fail \
	'./scripts/record-plane-is-on-by-default.sh' \
	"$(py 'edit("install.sh", "if [ \"$RECORD_ON\" = 1 ]; then UP_PROFILES+=(--profile record); fi", ":")')" \
	"the up profile list never names the record profile"

run_case "record-plane-is-on-by-default: WITH_RECORD builds trailryx from source again" fail \
	'./scripts/record-plane-is-on-by-default.sh' \
	"$(py 'edit("install.sh", "  if [ -n \"$BUILD_FROM_SOURCE\" ]; then\n    [ -f \"$SRC_DIR/stack-k8s/images/trailryx.Dockerfile\" ]", "  if [ -n \"${WITH_RECORD:-}\" ]; then\n    [ -f \"$SRC_DIR/stack-k8s/images/trailryx.Dockerfile\" ]")')" \
	"install.sh still builds trailryx when WITH_RECORD is set"

run_case "record-plane-is-on-by-default: a comment in the record block is not a fault" pass \
	'./scripts/record-plane-is-on-by-default.sh' \
	"$(py 'edit("install.sh", "RECORD_ON=1\nrecord_resolve() {", "RECORD_ON=1\n# a comment in the record block is not a fault\nrecord_resolve() {")')" \
	""

run_case "costcrew-can-reach-its-stream: the bus directory goes back to 0750, so costcrew cannot enter it" fail \
	'./scripts/costcrew-can-reach-its-stream.sh' \
	"$(py 'edit("compose.yaml", "chown 0:10001 /vol/events && chmod 0751 /vol/events", "chown 0:10001 /vol/events && chmod 0750 /vol/events")')" \
	"others have no execute bit"

run_case "costcrew-can-reach-its-stream: costcrew joins the bus group" fail \
	'./scripts/costcrew-can-reach-its-stream.sh' \
	"$(py 'edit("compose.yaml", "    user: \"10003:10003\"", "    user: \"10003:10003\"\n    group_add: [\"10001\"]")')" \
	"has a group_add"

run_case "costcrew-can-reach-its-stream: a comment beside the bus directory is not a fault" pass \
	'./scripts/costcrew-can-reach-its-stream.sh' \
	"$(py 'edit("compose.yaml", "        chown 0:10001 /vol/events && chmod 0751 /vol/events\n", "        # a comment about the bus directory is not a fault\n        chown 0:10001 /vol/events && chmod 0751 /vol/events\n")')" \
	""

echo
if [ -n "$(git status --porcelain)" ]; then
	printf 'FAIL: this script left the tree dirty, so it cannot be trusted about anything above\n'
	git status --porcelain | head -5
	exit 1
fi

if [ "$failures" -gt 0 ]; then
	printf '%d of %d cases failed.\n' "$failures" "$cases"
	printf 'A gate that has quietly stopped catching anything looks exactly like a gate\n'
	printf 'with nothing to catch, and stays that way until the fault it guards ships.\n'
	exit 1
fi

printf 'OK: %d cases. Every gate fails on its own fault, passes on a non-fault,\n' "$cases"
printf '    and refuses to report success when it measured nothing.\n'
