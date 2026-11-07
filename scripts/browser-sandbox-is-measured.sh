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
		PATH="$work/bin:$PATH" CONTROL="$2" DEFAULT="$3" UNCONFINED="$4" ASKED="$work/asked" STACK_DIR="$work" bash -c '
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
[ "$fail" = 0 ] || exit 1
echo "OK: five kinds of host asked, the narrowest line that works is what reached .env."
