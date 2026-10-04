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
	"$(py 'edit("compose.yaml", "for f in tokenfuse.ndjson tokenfuse-cloud.ndjson tokenfuse-mcp.ndjson wardryx.ndjson typryx.ndjson vouchryx.ndjson; do", "for f in tokenfuse.ndjson tokenfuse-mcp.ndjson wardryx.ndjson typryx.ndjson vouchryx.ndjson; do")')" \
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
	"$(py 'edit("compose.yaml", "command: [\"/usr/local/bin/tokenfuse\"]", "command: [\"/usr/local/bin/tokenfuse\", \"serve\"]")')" \
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
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/wardryx:v1.1.3", "ghcr.io/taipanbox/wardryx:v1.0.9")')" \
	"an image it pulls"

# invariant 15: the delegation plane's default is byte-for-byte what it was
# before this plane existed: vouchryx off, and the gateway's six
# TOKENFUSE_DELEGATION_* variables all defaulting to empty.
run_case "delegation-off-by-default: a delegation variable gets a literal default" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("compose.yaml", "TOKENFUSE_DELEGATION_AUDIENCE: ${TOKENFUSE_DELEGATION_AUDIENCE:-}", "TOKENFUSE_DELEGATION_AUDIENCE: stack-single")')" \
	"not the empty-default form"

run_case "delegation-off-by-default: install.sh starts the profile unconditionally" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("install.sh", "[ -z \"${WITH_DELEGATION:-}\" ] || UP_PROFILES+=(--profile delegation)", "UP_PROFILES+=(--profile delegation)")')" \
	"no WITH_DELEGATION guard"

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

# The training log and the pin (typryx v0.3.0). Each case plants the fault the
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

run_case "typed-data-mode: compose still pins the typryx that has no training log" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("compose.yaml", "ghcr.io/taipanbox/typryx:v0.3.0}", "ghcr.io/taipanbox/typryx:v0.2.0}")')" \
	"compose.yaml pins typryx v0.2.0"

run_case "typed-data-mode: components.json keeps the old typryx pin" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("components.json", "ghcr.io/taipanbox/typryx:v0.3.0", "ghcr.io/taipanbox/typryx:v0.2.0")')" \
	"components.json names typryx:v0.2.0"

run_case "typed-data-mode: the README names a typryx tag compose does not pin" fail \
	'./scripts/typed-data-mode.sh' \
	"$(py 'edit("README.md", "this launcher pins typryx v0.3.0, the first", "this launcher pins ghcr.io/taipanbox/typryx:v0.2.0, the first")')" \
	"README.md names typryx:v0.2.0"

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
s = re.sub(r"(?m)^\s*chown 65532:65532 delegation\s*\n", "", s)
open("install.sh", "w").write(s)')" \
	"never gives ./delegation to uid 65532"

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
	"$(py 'edit("compose.yaml", "      GENARYX_COPILOT_API_KEY_REF: env:GENARYX_COPILOT_KEY\n", "      GENARYX_COPILOT_API_KEY_REF: env:GENARYX_COPILOT_KEY\n      GENARYX_COPILOT_ALLOW_REMOTE: \"1\"\n")')" \
	"would skip the residency check"

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
	"$(py 'edit("compose.yaml", "image: ${TYPRYX_IMAGE:-ghcr.io/taipanbox/typryx:v0.3.0}", "image: ${TYPRYX_IMAGE:-registry.invalid/typryx}")')" \
	"names no ghcr.io/taipanbox/typryx"

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
