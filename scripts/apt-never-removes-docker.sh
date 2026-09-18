#!/usr/bin/env bash
#
# Enforces invariant 12 of CLAUDE.md: the package step never takes Docker
# away, and never asks apt for what the box already has.
#
# WHAT THIS IS ABOUT
#
# Measured 2026-09-17 on a Debian 13 box that already ran Docker CE 29.8.1:
# `apt-get install -s docker-buildx`, the line this installer runs on any box
# that already has docker, resolved to
#
#     Remv docker-ce [5:29.8.1-1~debian.13~trixie]
#     Remv docker-ce-cli [5:29.8.1-1~debian.13~trixie]
#     Inst docker-buildx (0.13.1+ds1-3 ...)
#     Inst docker-cli (26.1.5+dfsg1-9+deb13u1 ...)
#
# because the distro's `docker-buildx` depends on Debian's `docker-cli`, which
# conflicts with Docker's own `docker-ce-cli`. The box already had buildx, as
# `docker-buildx-plugin` from Docker's repository. The run went ahead only
# behind an `apt-mark hold` and a pin the operator wrote by hand (#55). Every
# earlier run of this installer was on Ubuntu with no Docker present, where
# the line is harmless, which is how an installer that removes Docker shipped.
#
# So this holds two things:
#
#   1. STATIC. Every `apt-get install` in install.sh carries `--no-remove`, so
#      a resolution that would remove anything is an error, never a removal,
#      whichever package is being asked for and whatever the distro's
#      dependency graph says this year.
#
#   2. BEHAVIOUR. The package step of install.sh (from `say "installing docker
#      and git"` to the line before `systemctl enable --now docker`) is run
#      under stub `apt-get`, `docker` and `dpkg`, and what it asks apt for is
#      read back: buildx is not asked for when `docker buildx version` already
#      succeeds; on a Docker CE box it is asked for as `docker-buildx-plugin`;
#      on a distro-docker box as `docker-buildx`; and an apt refusal (what
#      `--no-remove` turns the removal into) does not stop the install.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No `apt-get install` left in install.sh, or the anchors of the package step
# moved: each is reported and fails. A slice that matched nothing would run
# nothing and pass every assertion about what it did not ask for.
#
# This file is the ONE copy of this check. CI and the pre-push hook call it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

fail=0

# ---- 1. static: --no-remove on every apt-get install -------------------------
python3 - install.sh <<'PY' || fail=1
import re
import sys

problems = 0
seen = 0
for n, line in enumerate(open(sys.argv[1]).read().split("\n"), 1):
    if line.lstrip().startswith("#"):
        continue
    for m in re.finditer(r"apt-get\s+install\b([^|;&>]*)", line):
        seen += 1
        if "--no-remove" not in m.group(1):
            print(f"FAIL: install.sh:{n} `apt-get install{m.group(1).rstrip()}` has no --no-remove: on a box that"
                  f" already runs Docker CE, apt may resolve it by removing docker-ce")
            problems += 1
if seen == 0:
    print("FAIL: no `apt-get install` in install.sh at all, so the static half measured NOTHING")
    sys.exit(1)
if problems:
    sys.exit(1)
print(f"ok: {seen} apt-get install invocation(s), every one with --no-remove")
PY

# ---- 2. the package step, run under stubs -----------------------------------
start=$(grep -n '^say "installing docker and git"' install.sh | head -1 | cut -d: -f1)
end=$(grep -n '^systemctl enable --now docker' install.sh | head -1 | cut -d: -f1)
if [ -z "$start" ] || [ -z "$end" ] || [ "$end" -le "$start" ]; then
	echo "FAIL: the package step's anchors are not in install.sh (say \"installing docker and git\""
	echo "      ... systemctl enable --now docker), so the behavioural half measured NOTHING."
	exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n "${start},$((end - 1))p" install.sh >"$work/slice.sh"

# The stubs. A PATH of only these plus the three tools the slice and the stubs
# need, because a GitHub runner has a real /usr/bin/docker and the "no docker
# yet" scenario needs it absent.
mkdir -p "$work/stubs" "$work/tools"
for t in bash cp grep; do ln -s "$(command -v "$t")" "$work/tools/$t"; done
cat >"$work/stubs/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$APT_LOG"
if [ "${1:-}" = install ]; then
	for a in "$@"; do
		# Installing docker.io is what makes `docker` appear on the box.
		[ "$a" = docker.io ] && cp "$STUB_DOCKER" "$STUB_BIN/docker"
		# The removal shape: with --no-remove, a resolution that would take
		# docker-ce away is a non-zero exit. APT_REFUSES names the packages
		# apt refuses in this scenario.
		case " ${APT_REFUSES:-} " in *" $a "*) exit 100 ;; esac
	done
fi
exit 0
EOF
cat >"$work/docker.stub" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
"buildx version") [ "${STUB_BUILDX:-0}" = 1 ] ;;
*) exit 0 ;;
esac
EOF
cat >"$work/stubs/dpkg" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -s ] && [ "${2:-}" = docker-ce ] && [ "${STUB_DOCKER_CE:-0}" = 1 ]; then
	printf 'Package: docker-ce\nStatus: install ok installed\n'
	exit 0
fi
exit 1
EOF
chmod +x "$work/stubs/"* "$work/docker.stub"
# The driver: install.sh's own shell options and its three output helpers,
# then the slice, sourced so that `die` ends the run as it would there.
cat >"$work/run.sh" <<'EOF'
set -euo pipefail
say() { :; }
note() { :; }
die() { printf 'die: %s\n' "$*" >&2; exit 1; }
. "$1"
EOF

# scenario <name> <docker present> <buildx present> <docker-ce> <apt refuses>
# Runs the slice and leaves what apt was asked in $work/apt.log.
scenario() {
	local name="$1" present="$2" buildx="$3" ce="$4" refuses="$5"
	local bin="$work/bin"
	rm -rf "$bin" && mkdir -p "$bin" && cp "$work/stubs/"* "$bin/"
	[ "$present" = 1 ] && cp "$work/docker.stub" "$bin/docker"
	: >"$work/apt.log"
	if ! APT_LOG="$work/apt.log" STUB_BIN="$bin" STUB_DOCKER="$work/docker.stub" \
		STUB_BUILDX="$buildx" STUB_DOCKER_CE="$ce" APT_REFUSES="$refuses" \
		PATH="$bin:$work/tools" \
		"$work/tools/bash" "$work/run.sh" "$work/slice.sh" \
		2>"$work/err"; then
		printf 'FAIL: [%s] the package step did not complete: %s\n' "$name" "$(head -3 "$work/err")"
		fail=1
		return 1
	fi
	if grep '^install ' "$work/apt.log" | grep -qv -- '--no-remove'; then
		printf 'FAIL: [%s] apt was asked to install without --no-remove: %s\n' "$name" "$(grep '^install ' "$work/apt.log" | grep -v -- '--no-remove' | head -1)"
		fail=1
	fi
}
asked() { grep -Eq "^install .* $1( |$)" "$work/apt.log"; }

scenario "no docker yet" 0 0 0 "" &&
	if asked docker.io; then
		echo "ok: [no docker yet] docker.io is installed"
	else
		echo "FAIL: [no docker yet] docker.io was never asked for"
		fail=1
	fi

scenario "docker present, buildx present" 1 1 1 "" &&
	if asked docker-buildx || asked docker-buildx-plugin; then
		echo "FAIL: [docker present, buildx present] buildx is asked for though the box already has it, and on a Docker CE box the distro's package removes docker-ce"
		fail=1
	else
		echo "ok: [docker present, buildx present] buildx is not asked for"
	fi

scenario "Docker CE, no buildx" 1 0 1 "" &&
	if asked docker-buildx-plugin && ! asked docker-buildx; then
		echo "ok: [Docker CE, no buildx] docker-buildx-plugin is asked for, from Docker's repository"
	else
		echo "FAIL: [Docker CE, no buildx] expected docker-buildx-plugin and not the distro's docker-buildx; apt was asked: $(grep '^install ' "$work/apt.log" | tr '\n' ';')"
		fail=1
	fi

scenario "distro docker, no buildx" 1 0 0 "" &&
	if asked docker-buildx; then
		echo "ok: [distro docker, no buildx] docker-buildx is asked for"
	else
		echo "FAIL: [distro docker, no buildx] docker-buildx was never asked for"
		fail=1
	fi

# What --no-remove turns the removal into is an apt error, and the install
# must go on without buildx rather than stop: a pull needs no builder.
scenario "apt refuses buildx" 1 0 0 "docker-buildx docker-buildx-plugin" &&
	echo "ok: [apt refuses buildx] the package step completes without it"

if [ "$fail" -ne 0 ]; then
	echo
	echo "The package step must never take Docker away, and must not ask apt for what"
	echo "the box already has. See CLAUDE.md invariant 12."
	exit 1
fi
echo "OK: every apt-get install carries --no-remove, and the package step under stubs"
echo "    asks for buildx only when it is missing, from the right repository."
