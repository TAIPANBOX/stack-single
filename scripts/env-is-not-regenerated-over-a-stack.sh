#!/usr/bin/env bash
# CLAUDE.md invariant 81 (stack-single#62): a run that finds no .env never writes a fresh one over a
# stack whose volumes are already on the box, unless the operator says so with FRESH_ENV=1.
#
# WHY
#
# .env holds the policy database's password and pgdata knows only the one it was created with. With
# .env gone, a re-run wrote a new one: wardryx restart-looped on `open postgres` and both doors failed
# closed (measured 2026-09-17 on the appliance run).
#
# WHAT THIS CHECKS
#
#   A. the `# env-guard:` block, lifted out of install.sh and run under `set -euo pipefail`, as install.sh
#      runs it (a grep that finds nothing fails a pipeline there), against a stub `docker` in a scratch
#      STACK_DIR, case by case:
#        no .env, this project's volumes present            -> refuses, names .env and the volumes, exit != 0
#        no .env, volumes found only by name (no label)     -> refuses
#        no .env, Docker does not answer                    -> refuses
#        no .env, no volumes                                -> goes on
#        no .env, only another project's volume named *agent-stack_* -> goes on
#        no .env, no docker on PATH (a fresh box)           -> goes on
#        an empty .env, volumes present                     -> refuses (empty is no .env)
#        a .env with content                                -> goes on, and asks Docker nothing
#        FRESH_ENV=1 with volumes, and with Docker down     -> goes on, saying what it skipped
#      and in every refusal nothing was created in STACK_DIR;
#   B. order: install.sh calls env_guard_check after the distro check and before the first package
#      install, the tree copy and the first write of .env;
#   C. the README says what to back up and what a re-run without it does.
#
# It refuses to report OK when it measured nothing: no block, no function, no call.
#
# Scenarios: features/a-lost-env-is-not-regenerated-over-a-stack.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "env-guard".
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/env-guard.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail=0
bad() { printf 'FAIL env-guard: %s\n' "$*"; fail=1; }

block="$(sed -n '/^# env-guard: begin$/,/^# env-guard: end$/p' install.sh)"
if [ -z "$block" ]; then
	echo "FAIL env-guard: install.sh has no '# env-guard: begin' .. 'end' block; measured nothing"
	exit 1
fi
grep -q '^env_guard_check() {' <<<"$block" || { echo "FAIL env-guard: the block defines no env_guard_check(); measured nothing"; exit 1; }
grep -qx 'env_guard_check' install.sh || { echo "FAIL env-guard: install.sh never calls env_guard_check; measured nothing"; exit 1; }

# The stub docker: STUB_STATE says what the box holds.
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'SH'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
case "$1" in
  info) [ "$STUB_STATE" = down ] && exit 1; exit 0 ;;
  volume)
    [ "$STUB_STATE" = down ] && exit 1
    case "$*" in
      *label=com.docker.compose.project=agent-stack*)
        [ "$STUB_STATE" = labelled ] && printf 'agent-stack_pgdata\nagent-stack_events\n'; exit 0 ;;
      *name=agent-stack_*)
        case "$STUB_STATE" in labelled|unlabelled) printf 'agent-stack_pgdata\n' ;; foreign) printf 'foo-agent-stack_data\n' ;; esac; exit 0 ;;
    esac ;;
esac
exit 0
SH
chmod +x "$work/bin/docker"

# run <name> <state> <env content or -none-> <path: with|without docker> [extra env]
run() {
	local name="$1" state="$2" envc="$3" path="$4"
	shift 4
	local dir="$work/$name"
	mkdir -p "$dir"
	[ "$envc" = -none- ] || printf '%s' "$envc" >"$dir/.env"
	: >"$work/$name.log"
	local p="$work/bin:/usr/bin:/bin"
	[ "$path" = without ] && p="/usr/bin:/bin"
	if [ "$path" = without ] && PATH="$p" command -v docker >/dev/null 2>&1; then
		echo "SKIP $name: this machine has a docker in /usr/bin or /bin, so a box without one cannot be stood in for" >&2
		return 2
	fi
	out="$(env -i PATH="$p" STACK_DIR="$dir" STUB_STATE="$state" STUB_LOG="$work/$name.log" "$@" \
		bash -c 'set -euo pipefail; say() { :; }; note() { printf "   %s\n" "$*"; }; die() { printf "!! %s\n" "$*" >&2; exit 1; }
'"$(grep -vx env_guard_check <<<"$block")"'
env_guard_check
echo REACHED-THE-END' 2>&1)" && rc=0 || rc=$?
	listing="$(cd "$dir" && ls -A)"
}

expect_refuse() {
	local name="$1"
	if [ "$rc" = 0 ] || grep -q REACHED-THE-END <<<"$out"; then bad "$name: the run went on; it must refuse"; return; fi
	grep -q '\.env' <<<"$out" || bad "$name: the refusal does not name .env, the file to restore"
	grep -q 'Nothing was changed' <<<"$out" || bad "$name: the refusal does not say nothing was changed"
	grep -q 'FRESH_ENV=1' <<<"$out" || bad "$name: the refusal does not name FRESH_ENV=1, the way to mean it"
}
expect_go() {
	local name="$1"
	grep -q REACHED-THE-END <<<"$out" || bad "$name: the run stopped; it must go on: $out"
}

run refuse-labelled labelled -none- with; expect_refuse refuse-labelled
grep -q 'agent-stack_pgdata' <<<"$out" || bad "refuse-labelled: the refusal does not name the volumes it found"
[ "$listing" = "" ] || bad "refuse-labelled: the refusal left files in STACK_DIR: $listing"

run refuse-unlabelled unlabelled -none- with; expect_refuse refuse-unlabelled

run refuse-down down -none- with; expect_refuse refuse-down

run refuse-empty labelled "" with; expect_refuse refuse-empty

run go-none none -none- with; expect_go go-none

run go-foreign foreign -none- with; expect_go go-foreign

if run go-no-docker labelled -none- without; then :; fi
[ "${rc:-}" = 2 ] || expect_go go-no-docker

run go-env labelled "POLICY_DB_PASSWORD=x
" with; expect_go go-env
[ -s "$work/go-env.log" ] && bad "go-env: with a .env present the check asked Docker: $(tr '\n' ' ' <"$work/go-env.log")"

run go-fresh labelled -none- with FRESH_ENV=1; expect_go go-fresh
grep -q 'FRESH_ENV=1' <<<"$out" || bad "go-fresh: FRESH_ENV=1 went on without saying what it skipped"

run go-fresh-down down -none- with FRESH_ENV=1; expect_go go-fresh-down

# B. the order in install.sh: the call before the first package install, the tree copy, and .env's first write
line_of() { grep -n -m1 -E "$1" install.sh | cut -d: -f1; }
call="$(line_of '^env_guard_check$')"
distro="$(line_of 'this expects Debian or Ubuntu; found')"
apt="$(line_of '^[[:space:]]*apt-get (update|install)')"
copy="$(line_of 'cp -a ')"
write="$(line_of 'cat > \.env <<EOF')"
if [ -z "$call" ] || [ -z "$distro" ] || [ -z "$apt" ] || [ -z "$copy" ] || [ -z "$write" ]; then
	bad "the order could not be read (call ${call:-?}, distro ${distro:-?}, apt ${apt:-?}, copy ${copy:-?}, .env ${write:-?}); measured nothing"
else
	[ "$call" -gt "$distro" ] || bad "env_guard_check runs before the distro check"
	[ "$call" -lt "$apt" ] || bad "env_guard_check runs after the first apt-get (line $apt), so a refusal leaves the box half changed"
	[ "$call" -lt "$copy" ] || bad "env_guard_check runs after the tree copy (line $copy)"
	[ "$call" -lt "$write" ] || bad "env_guard_check runs after .env is written (line $write)"
fi

# C. the README
grep -q '^## Back up \.env$' README.md || bad "README.md has no '## Back up .env' section"
sec="$(sed -n '/^## Back up \.env$/,/^## /p' README.md)"
grep -q 'agent-stack_pgdata' <<<"$sec" || bad "the README's backup section does not say why: the database knows only its own password"
grep -q 'FRESH_ENV=1' <<<"$sec" || bad "the README's backup section does not name FRESH_ENV=1"

[ "$fail" = 0 ] || exit 1
echo "OK: env-guard (invariant 81): with no .env, a box holding this stack's volumes, or a Docker that cannot say, is refused before anything changes; FRESH_ENV=1 from the environment is the only way through"
