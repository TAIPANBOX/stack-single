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

echo
echo "=== and what they must NOT catch ==="

# A shellcheck directive with its reason beside it is the documented way to
# silence a finding here. A gate that flagged one would be flagging the
# convention its own header describes.
run_case "shell-lint: another silenced finding with its reason" pass \
	'./scripts/shell-lint.sh' \
	"$(py 'edit("install.sh", "die()  {", "# shellcheck disable=SC2317  # reachable, called from a trap\ndie()  {")')"

echo
echo "=== and the one this estate learned the hard way ==="
echo "    a gate whose subject is gone must SAY so, not report OK on nothing"

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
