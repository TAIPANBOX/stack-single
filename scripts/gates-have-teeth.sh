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

	# Exit code first, then wording. Checking the needle before the expectation
	# turns "it did not fail at all" into "it failed for the wrong reason",
	# which sends the reader to look at prose when the gate is toothless.
	if [ "$expect" = fail ] && [ "$rc" -ne 0 ] && [ -n "$needle" ] &&
		! printf '%s' "$out" | grep -qF -- "$needle"; then
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

py() { printf 'def edit(p, a, b):\n    s = open(p).read()\n    assert a in s, "pattern not found in " + p\n    open(p, "w").write(s.replace(a, b, 1))\n%s\n' "$1"; }

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
	"$(py 'edit("compose.yaml",
     "- records:/var/lib/stack/records",
     "- events:/var/lib/stack/records")')" \
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
	"$(py 'edit("compose.yaml", "for f in tokenfuse.ndjson tokenfuse-cloud.ndjson wardryx.ndjson; do", "for f in tokenfuse.ndjson wardryx.ndjson; do")')" \
	"does not pre-create tokenfuse-cloud.ndjson"

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
	"$(py 'edit("compose.yaml", "chown 65532:65532 /vol/scopyx", "chown 10001:10001 /vol/scopyx")')" \
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
	"$(py 'edit("compose.yaml", "command: [\"/usr/local/bin/tokenfuse\"]", "command: [\"/usr/local/bin/tokenfuse\", \"serve\"]")')" \
	"measured NOTHING"

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
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/wardryx:v1.0.3", "ghcr.io/taipanbox/wardryx:v1.0.9")')" \
	"an image it pulls"

echo
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
