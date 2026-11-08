#!/usr/bin/env bash
# Enforces that install.sh picks the browser's AppArmor line by asking the host, and picks the
# narrowest one that works.
#
# WHY
#
# Chrome's sandbox needs a user namespace, and the two hosts this installer supports answer in
# opposite ways: Debian 13's docker-default refuses it, and on Ubuntu 24.04 it is
# apparmor=unconfined that loses it. One line in compose.yaml cannot be right for both, and a
# browser without its sandbox answers `browse` with an error and fetches nothing, so the choice
# used to be the operator's to find. Now it is a measurement, and a measurement can go wrong in
# ways no reader of the file sees: the wider line tried first, or a throwaway that never started
# read as a host that refuses.
#
# HOW
#
# It runs the block from install.sh against a stand-in for `docker` that answers as each kind of
# host does, and reads what was written to .env, what was asked, and what was said.
#
# THE PROFILE OF OUR OWN (CLAUDE.md invariant 73)
#
# apparmor/scopyx-browser is asked first, where AppArmor is on and a parser is there. The same
# block runs against a host that has it on, one that has it off, one with no parser, one whose
# parser refuses the file, one that loads it and then refuses the browser, and one where the file
# changed between two runs. Each reads what was loaded, what was kept for the next boot, what was
# asked, and that a second run loads nothing again. And `status`'s line for the running browser
# runs against what Docker reports, and has to go red for an unconfined browser on a host that
# could confine it.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No block in install.sh: measured nothing. Each case has to be asked at least one question.
#
# (teeth cases: scripts/gates-have-teeth.sh, "browser-sandbox-is-measured: ...";
#  scenarios: features/the-browser-keeps-both-sandboxes.feature)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f install.sh ]; then
	echo "FAIL: install.sh is not there, so the pick measured NOTHING."
	exit 1
fi
block="$(sed -n '/^# browser-apparmor: begin$/,/^# browser-apparmor: end$/p' install.sh)"
if ! grep -q '^browser_apparmor_apply()' <<<"$block"; then
	echo "FAIL: install.sh has no browser_apparmor_apply between its '# browser-apparmor:' lines, so the pick measured NOTHING."
	exit 1
fi
if ! grep -q '^browser_apparmor_apply$' install.sh; then
	echo "FAIL: install.sh never calls browser_apparmor_apply, so no box gets the line."
	exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# Answers from the environment: CONTROL, DEFAULT and UNCONFINED are 0 or 1, as exit codes.
cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
aa=""
for a in "$@"; do
	case "$a" in apparmor=*) aa="${a#apparmor=}" ;; esac
done
printf '%s %s\n' "$aa" "${*: -1}" >>"$ASKED"
case "$*" in
	*" true") exit "$CONTROL" ;;
esac
case "$aa" in
	scopyx-browser) exit "${OWN:-1}" ;;
	docker-default) exit "$DEFAULT" ;;
	unconfined) exit "$UNCONFINED" ;;
esac
exit 1
FAKE
chmod +x "$work/bin/docker"

fail=0
ask_host() { # NAME CONTROL DEFAULT UNCONFINED WANT SAYS [NOT_ASKED]
	local name="$1" want="$5" says="$6" not_asked="${7:-}" got out
	: >"$work/asked"
	rm -f "$work/picked"
	out="$(
		PATH="$work/bin:$PATH" CONTROL="$2" DEFAULT="$3" UNCONFINED="$4" ASKED="$work/asked" STACK_DIR="$work" BROWSER_SECCOMP=x bash -c '
			set -euo pipefail
			note() { printf "%s\n" "$*"; }
			env_set_if_changed() { printf "%s" "$2" >"$STACK_DIR/picked"; }
			'"$block"'
			browser_apparmor_apply
		' 2>&1
	)" || {
		printf 'FAIL: %s: the block exited non-zero, and a host that refuses is no reason to stop an install: %s\n' "$name" "$out"
		fail=1
		return 0
	}
	got="$(cat "$work/picked" 2>/dev/null || true)"
	if [ ! -s "$work/asked" ]; then
		printf 'FAIL: %s: nothing was asked of the host, so this measured NOTHING\n' "$name"
		fail=1
	fi
	if [ "$got" != "$want" ]; then
		printf 'FAIL: %s: wrote %s to .env where %s was right\n' "$name" "${got:-nothing}" "${want:-nothing}"
		fail=1
	fi
	if ! grep -qF -- "$says" <<<"$out"; then
		printf 'FAIL: %s: did not say %s\n' "$name" "$says"
		fail=1
	fi
	if [ -n "$not_asked" ] && grep -qF -- "$not_asked" "$work/asked"; then
		printf 'FAIL: %s: asked about %s, which it had no reason to\n' "$name" "$not_asked"
		fail=1
	fi
}
ask_host "a host like Ubuntu 24.04" 0 0 1 docker-default "apparmor=docker-default" "unconfined "
ask_host "a host like Debian 13" 0 1 0 unconfined "apparmor=unconfined"
ask_host "a host that gives no namespace at all" 0 1 1 "" "fetches nothing"
ask_host "a throwaway that does not start" 1 1 1 "" "not measured" "/bin/true"
ask_host "a host that allows both" 0 0 0 docker-default "apparmor=docker-default" "unconfined "

# ---- the profile of our own, against hosts that answer for AppArmor in different ways ----------
if ! grep -q '^browser_aa_load()' <<<"$block"; then
	echo "FAIL: the block has no browser_aa_load, so the profile of our own is loaded by nothing and this measured NOTHING."
	exit 1
fi
profile_block="$(sed -n '/^# browser-profile: begin$/,/^# browser-profile: end$/p' install.sh)"
if ! grep -q '^browser_profile_status()' <<<"$profile_block"; then
	echo "FAIL: install.sh has no browser_profile_status between its '# browser-profile:' lines, so status reads nothing of the browser's profile."
	exit 1
fi
status_body="$(awk '/^status_main\(\) \{$/,/^\}$/' install.sh)"
if ! grep -q '^  browser_profile_status$' <<<"$status_body"; then
	echo "FAIL: status_main never calls browser_profile_status, so a browser under the wrong profile is a green status."
	exit 1
fi
if [ ! -f apparmor/scopyx-browser ]; then
	echo "FAIL: apparmor/scopyx-browser is not there, so the profile cases measured NOTHING."
	exit 1
fi
# A stub parser: -r FILE loads it unless PARSER_FAIL, and every call is logged.
cat >"$work/bin/apparmor_parser" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PARSERLOG"
[ "${PARSER_FAIL:-0}" = 0 ] || exit 1
case "$1" in
	-r) grep -qx 'scopyx-browser (enforce)' "$SYS/kernel/security/apparmor/profiles" 2>/dev/null || echo 'scopyx-browser (enforce)' >>"$SYS/kernel/security/apparmor/profiles" ;;
esac
FAKE
chmod +x "$work/bin/apparmor_parser"
mkdir -p "$work/sysbin"
for t in docker; do cp "$work/bin/$t" "$work/sysbin/$t"; done

# hostdir NAME ENABLED HAVE_PARSER: a stack dir with the profile, an apparmor.d, a fake /sys
hostdir() { # a directory name with no space and no colon: it goes on a PATH
	local h="$work/host-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
	rm -rf "$h"
	mkdir -p "$h/stack/apparmor" "$h/aa.d" "$h/sys/module/apparmor/parameters" "$h/sys/kernel/security/apparmor" "$h/bin"
	cp apparmor/scopyx-browser "$h/stack/apparmor/scopyx-browser"
	printf '%s\n' "$2" >"$h/sys/module/apparmor/parameters/enabled"
	: >"$h/sys/kernel/security/apparmor/profiles"
	cp "$work/bin/docker" "$h/bin/docker"
	# dockerd as the host shows it: a pid from pgrep, and the label the kernel keeps for it
	mkdir -p "$h/proc/4242/attr/apparmor"
	printf '#!/usr/bin/env bash\necho 4242\n' >"$h/bin/pgrep"
	chmod +x "$h/bin/pgrep"
	[ "${DOCKERD_LABEL:-unconfined}" = UNREADABLE ] || printf '%s\n' "${DOCKERD_LABEL:-unconfined}" >"$h/proc/4242/attr/apparmor/current"
	[ "$3" != 1 ] || cp "$work/bin/apparmor_parser" "$h/bin/apparmor_parser"
	printf '%s' "$h"
}
parser_calls() { grep -c -- '^-r ' "$1" 2>/dev/null || true; }

aa_host() { # NAME ENABLED PARSER PARSER_FAIL OWN DEFAULT UNCONFINED WANT SAYS LOADS KEPT [NOT_ASKED] [CHANGE_BETWEEN_RUNS]
	local name="$1" want="$8" says="$9" loads="${10}" kept="${11}" not_asked="${12:-}" change="${13:-}" h out got calls before
	h="$(hostdir "$name" "$2" "$3")"
	: >"$h/asked"
	: >"$h/parser.log"
	before=$fail
	out="$(
		PATH="$h/bin:/usr/bin:/bin" CONTROL=0 DEFAULT="$6" UNCONFINED="$7" OWN="$5" PARSER_FAIL="$4" ASKED="$h/asked" PARSERLOG="$h/parser.log" \
			SYS="$h/sys" BROWSER_AA_SYS="$h/sys" BROWSER_AA_PROC="$h/proc" BROWSER_AA_DIR="$h/aa.d" STACK_DIR="$h/stack" BROWSER_SECCOMP=x CHANGE="$change" bash -c '
			set -euo pipefail
			note() { printf "%s\n" "$*"; }
			env_set_if_changed() { printf "%s" "$2" >"$STACK_DIR/picked"; }
			'"$block"'
			browser_apparmor_apply
			first="$(cat "$STACK_DIR/picked" 2>/dev/null || true)"
			if [ -n "$CHANGE" ]; then printf "# changed\n" >>"$STACK_DIR/apparmor/scopyx-browser"; fi
			rm -f "$STACK_DIR/picked"
			browser_apparmor_apply
			second="$(cat "$STACK_DIR/picked" 2>/dev/null || true)"
			[ "$first" = "$second" ] || echo "the second run picked $second where the first picked $first"
		' 2>&1
	)" || {
		printf 'FAIL: %s: the block exited non-zero: %s\n' "$name" "$out"
		fail=1
		return 0
	}
	got="$(cat "$h/stack/picked" 2>/dev/null || true)"
	calls="$(parser_calls "$h/parser.log")"
	[ "$calls" = "$loads" ] || { printf 'FAIL: %s: apparmor_parser -r ran %s time(s) over two runs, %s was right\n' "$name" "$calls" "$loads"; fail=1; }
	[ "$got" = "$want" ] || { printf 'FAIL: %s: wrote %s to .env where %s was right\n' "$name" "${got:-nothing}" "$want"; fail=1; }
	grep -qF -- "$says" <<<"$out" || { printf 'FAIL: %s: did not say %s\n' "$name" "$says"; fail=1; }
	grep -q 'the second run picked' <<<"$out" && { printf 'FAIL: %s: %s\n' "$name" "$(grep 'the second run picked' <<<"$out")"; fail=1; }
	if [ "$kept" = 1 ]; then
		cmp -s "$h/stack/apparmor/scopyx-browser" "$h/aa.d/scopyx-browser" || { printf 'FAIL: %s: the profile is not in apparmor.d as the stack has it, so a reboot loses it\n' "$name"; fail=1; }
	elif [ -e "$h/aa.d/scopyx-browser" ]; then
		printf 'FAIL: %s: left a profile in apparmor.d on a host that did not load it\n' "$name"; fail=1
	fi
	[ -s "$h/asked" ] || { printf 'FAIL: %s: nothing was asked of the host, so this measured NOTHING\n' "$name"; fail=1; }
	if [ -n "$not_asked" ] && grep -qF -- "$not_asked" "$h/asked"; then
		printf 'FAIL: %s: asked about %s, which it had no reason to\n' "$name" "$not_asked"; fail=1
	fi
	# the profile of our own is the first line asked after the control, whenever it was loaded
	if [ "$kept" = 1 ] && [ "$(sed -n 2p "$h/asked" | cut -d' ' -f1)" != scopyx-browser ]; then
		printf 'FAIL: %s: the first line asked was not scopyx-browser\n' "$name"; fail=1
	fi
	[ "$fail" = "$before" ] || printf '      what the block said: %s\n' "$out"
}
#       NAME                                         EN PARSER FAIL OWN DEF UNC WANT              SAYS                                  LOADS KEPT NOT_ASKED CHANGE
aa_host "Debian 13: AppArmor on, own profile starts"  Y  1      0    0   1   0  scopyx-browser    "apparmor=scopyx-browser"             1     1    "unconfined "
aa_host "Ubuntu 24.04: both would start"              Y  1      0    0   0   1  scopyx-browser    "apparmor=scopyx-browser"             1     1    "unconfined "
aa_host "AppArmor is off in the kernel"               N  1      0    0   0   0  docker-default    "apparmor=docker-default"             0     0    "scopyx-browser"
aa_host "AppArmor on, no parser"                      Y  0      0    0   1   0  unconfined        "apparmor=unconfined"                 0     0    "scopyx-browser"
aa_host "a parser that refuses the file"              Y  1      1    0   1   0  unconfined        "would not load"                      2     0    "scopyx-browser"
aa_host "loaded, and the host still refuses it"       Y  1      0    1   0   1  docker-default    "apparmor=docker-default"             1     1
aa_host "the profile changed between two runs"        Y  1      0    0   1   0  scopyx-browser    "apparmor=scopyx-browser"             2     1    ""          1
DOCKERD_LABEL="snap.docker.dockerd (enforce)" aa_host "dockerd runs under a profile of its own" Y  1      0    0   0   1  docker-default    "dockerd runs under AppArmor profile snap.docker.dockerd" 0 0 "scopyx-browser"
DOCKERD_LABEL=UNREADABLE aa_host "dockerd's label cannot be read"              Y  1      0    0   0   1  docker-default    "unreadable"                          0     0    "scopyx-browser"
DOCKERD_LABEL=unconfined aa_host "dockerd is unconfined, as on Debian 13"        Y  1      0    0   1   0  scopyx-browser    "apparmor=scopyx-browser"             1     1    "unconfined "

# ---- what status says of the running browser --------------------------------------------------
status_host() { # NAME GOT WANT ENABLED PARSER COPY(same|differs|none) LOADED(0|1) RUNS(1|0) EXPECT(ok|FAIL|skip) [SAYS]
	local name="$1" got="$2" want="$3" copy="$6" runs="$8" expect="$9" says="${10:-}" h out line
	h="$(hostdir "st-$name" "$4" "$5")"
	case "$copy" in
		same) cp "$h/stack/apparmor/scopyx-browser" "$h/aa.d/scopyx-browser" ;;
		differs) printf '# another\n' >"$h/aa.d/scopyx-browser" ;;
	esac
	[ "$7" != 1 ] || echo 'scopyx-browser (enforce)' >"$h/sys/kernel/security/apparmor/profiles"
	cat >"$h/bin/docker" <<FAKE
#!/usr/bin/env bash
case "\$1" in
	ps) [ "$runs" = 1 ] && echo abc123 ;;
	inspect) printf '%s\n' "$got" ;;
esac
exit 0
FAKE
	chmod +x "$h/bin/docker"
	out="$(
		PATH="$h/bin:/usr/bin:/bin" SCOPYX_BROWSER_APPARMOR="$want" NET=agent-stack_core BROWSER_AA_SYS="$h/sys" BROWSER_AA_PROC="$h/proc" BROWSER_AA_DIR="$h/aa.d" STACK_DIR="$h/stack" bash -c '
			set -euo pipefail
			fail=0
			'"$block"'
			'"$profile_block"'
			browser_profile_status
			echo "fail=$fail"
		' 2>&1
	)" || { printf 'FAIL: %s: status exited non-zero: %s\n' "$name" "$out"; fail=1; return 0; }
	line="$(head -n1 <<<"$out")"
	case "$expect" in
		ok) grep -q '^   ok    browser AppArmor profile' <<<"$line" && grep -q '^fail=0$' <<<"$out" || { printf 'FAIL: %s: status said %s, ok was right\n' "$name" "$line"; fail=1; } ;;
		FAIL) grep -q '^   FAIL  browser AppArmor profile' <<<"$line" && grep -q '^fail=1$' <<<"$out" || { printf 'FAIL: %s: status said %s, and it had to be red and count one failure\n' "$name" "$line"; fail=1; } ;;
		skip) grep -q '^   skip ' <<<"$line" && grep -q '^fail=0$' <<<"$out" || { printf 'FAIL: %s: status said %s, skip was right\n' "$name" "$line"; fail=1; } ;;
	esac
	if [ -n "$says" ] && ! grep -qF -- "$says" <<<"$line"; then printf 'FAIL: %s: status did not say %s: %s\n' "$name" "$says" "$line"; fail=1; fi
}
#          NAME                                          GOT              WANT             EN PARSER COPY     LOADED RUNS EXPECT
status_host "under our profile"                          scopyx-browser   scopyx-browser   Y  1      same     1      1    ok
status_host "unconfined where ours could be loaded"      unconfined       unconfined       Y  1      none     0      1    FAIL
status_host "unconfined, and no way to load ours"        unconfined       unconfined       Y  0      none     0      1    ok
status_host "our profile, but the host's copy differs"   scopyx-browser   scopyx-browser   Y  1      differs  1      1    FAIL
status_host "our profile, but not what .env names"       scopyx-browser   docker-default   Y  1      same     1      1    FAIL
status_host "docker-default, as .env says"               docker-default   docker-default   Y  0      none     0      1    ok
status_host "no profile at all, AppArmor off"            ""               docker-default   N  0      none     0      1    ok
status_host "no profile, AppArmor on"                    ""               docker-default   Y  1      none     0      1    FAIL
DOCKERD_LABEL="snap.docker.dockerd (enforce)" status_host "unconfined, and dockerd is confined" unconfined unconfined Y 1 none 0 1 ok "dockerd runs under AppArmor profile snap.docker.dockerd"
status_host "no browser runs"                            unconfined       unconfined       Y  1      none     0      0    skip

[ "$fail" = 0 ] || exit 1
echo "OK: five kinds of host asked and ten with the profile of our own, ten status readings, the narrowest line that works is what reached .env."
