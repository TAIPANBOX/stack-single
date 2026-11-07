#!/usr/bin/env bash
# Enforces the install journal and the rollback index: a tree below the box's floor is
# refused before anything changes, the floor moves only after a run with no failed check,
# and the docs say plainly what this is and is not.
#
# WHY
#
# A box that has run a release may hold data or keys an older tree cannot read, or an
# older tree may carry a defect that has since become a reason not to run it. Running such
# a tree by accident is easy: a stale clone, the wrong tag, an old path in a script. This
# is the guard against that accident, and a guard against nothing else. The check lives
# inside the tree it checks and the tree is not signed, so an older tree simply does not
# have it. The gate holds the docs to that as firmly as it holds the code.
#
# WHY AN INTEGER
#
# A version says when a tree was cut, not whether it became unsafe, so a version floor
# would refuse every ordinary rollback, and `1.10.0 < 1.9.9` is how a bash comparison of
# dotted numbers stops every upgrade. The index goes up only when an older tree becomes
# unsafe, so releases share it and the rollback trees kept on a box still pass.
#
# HOW
#
# The `# install-journal:` block is lifted out of install.sh and run in scratch boxes, for
# each row of the behaviour: no journal, an empty one, a floor below, equal to and above the
# tree, indices that sort differently as strings, a line that cannot be read, the override
# with and without a reason, hostile reasons and hostile journals. Then section 1 of
# install.sh is lifted and run for a clone and a piped install, and a copy of the real
# install.sh is run with stub tools, to show that a refusal calls no tool and changes no
# byte, and that a tree of the same index gets past the preflight.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No block, no constant, no call in the preflight, no README section, or no case run: each
# is reported as measuring nothing.
#
# (teeth cases: scripts/gates-have-teeth.sh, "rollback-floor: ...";
#  scenarios: features/the-box-does-not-go-backwards-by-accident.feature)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [ ! -f install.sh ] || [ ! -f compose.yaml ]; then
	echo "FAIL: install.sh or compose.yaml is not there, so the rollback floor measured NOTHING."
	exit 1
fi
BLOCK="$(sed -n '/^# install-journal: begin$/,/^# install-journal: end$/p' install.sh)"
if ! grep -q '^rollback_floor_check() {$' <<<"$BLOCK"; then
	echo "FAIL: install.sh has no '# install-journal:' block with rollback_floor_check, so the rollback floor measured NOTHING."
	exit 1
fi
if ! grep -qE '^STACK_ROLLBACK_INDEX=[0-9]+$' <<<"$BLOCK"; then
	echo "FAIL: the block sets no plain STACK_ROLLBACK_INDEX=N, so the rollback floor measured NOTHING."
	exit 1
fi
SECTION1="$(sed -n '/^# ---- 1\. this repo, whether cloned or piped/,/^cd "\$STACK_DIR"$/p' install.sh)"
if ! grep -qE '^ *journal_begin ' <<<"$SECTION1"; then
	echo "FAIL: section 1 of install.sh never calls journal_begin, so the journal measured NOTHING."
	exit 1
fi
README_SECTION="$(sed -n '/^## Going backwards by mistake/,/^## /p' README.md)"
if [ -z "$README_SECTION" ]; then
	echo "FAIL: the README has no 'Going backwards by mistake' section, so what this is and is not was measured against NOTHING."
	exit 1
fi

problems=0
report() {
	printf 'FAIL: %s\n' "$1"
	problems=$((problems + 1))
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/rollback-floor.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX
OUT="$SANDBOX/out"
BOX="$SANDBOX/box"
printf '%s\n' "$BLOCK" >"$SANDBOX/block.sh"

cat >"$SANDBOX/run.sh" <<'HARNESS'
#!/usr/bin/env bash
# The lifted block, the way the installer calls it: $1 is what to run after the check.
set -euo pipefail
EXPLAINED=0
note() { printf '   %s\n' "$*"; }
die() { EXPLAINED=1; printf '\n!! %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
. "$SANDBOX/block.sh"
[ -z "${CASE_INDEX:-}" ] || STACK_ROLLBACK_INDEX="$CASE_INDEX"
fail="${CASE_FAIL:-0}"
COMPOSE=(docker compose)
rollback_floor_check
if [ "${1:-}" = run ]; then
  journal_begin "$SANDBOX/no-tree"
  journal_end
fi
HARNESS
# One stub for the versions a line records; everything real otherwise.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "version --format {{.Server.Version}}") printf '26.1.5\n' ;;
  "compose version --short") printf '2.26.1-4\n' ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/docker"

STAMP=2026-11-09T06:18:44Z
line() { # EVENT INDEX [TAIL]
	printf '%s %s version=1.7.0 index=%s commit=abc1234%s\n' "$STAMP" "$1" "$2" "${3:+ $3}"
}
fresh() {
	rm -rf "$BOX"
	mkdir -p "$BOX"
	unset CASE_INDEX CASE_FAIL ALLOW_ROLLBACK ROLLBACK_REASON
}
floor() { # N: a box whose last good run was at index N
	line attempt "$1" >>"$BOX/.install-history"
	line good "$1" >>"$BOX/.install-history"
}
cases=0
go() { # NAME [run]: the check, and with `run` the whole of a run after it
	cases=$((cases + 1))
	case_name="$1"
	set +e
	PATH="$SANDBOX/bin:$PATH" STACK_DIR="$BOX" bash "$SANDBOX/run.sh" "${2:-}" >"$OUT" 2>&1
	rc=$?
	set -e
}
passes() { # WHY
	if [ "$rc" -ne 0 ]; then
		report "$case_name: $1 (exit $rc)"
		sed 's/^/        /' "$OUT" | head -8
	fi
}
refused() { # WHY
	if [ "$rc" -ne 1 ]; then
		report "$case_name: $1 (exit $rc)"
		sed 's/^/        /' "$OUT" | head -8
	fi
}
says() { # TEXT WHY
	if ! grep -qF -- "$1" "$OUT"; then
		report "$case_name: $2"
		sed 's/^/        /' "$OUT" | head -8
	fi
}
journal_has() { # REGEX WHY
	if ! grep -qE -- "$1" "$BOX/.install-history" 2>/dev/null; then
		report "$case_name: $2"
		sed 's/^/        /' "$BOX/.install-history" 2>/dev/null | head -8
	fi
}
journal_lacks() { # REGEX WHY
	if grep -qE -- "$1" "$BOX/.install-history" 2>/dev/null; then
		report "$case_name: $2"
		sed 's/^/        /' "$BOX/.install-history" | head -8
	fi
}

# ---- the refusal ----------------------------------------------------------------
fresh
floor 5
export CASE_INDEX=4
before="$(cksum <"$BOX/.install-history")"
go "a tree below the floor"
refused "a tree below the floor is not refused"
says "ALLOW_ROLLBACK=1 ROLLBACK_REASON=" "the refusal does not give the exact way through"
says "Nothing was changed." "the refusal does not say nothing was changed"
says "rollback index 4" "the refusal does not name the tree's index"
says "has run index 5 since 1.7.0" "the refusal does not name the box's floor and where it came from"
if [ "$(cksum <"$BOX/.install-history")" != "$before" ]; then
	report "a tree below the floor: the journal changed before the refusal"
fi

fresh
floor 5
export CASE_INDEX=5
go "a tree of the same index"
passes "a tree of the same index is refused, so an ordinary rollback would not work"

fresh
floor 5
export CASE_INDEX=6
go "a tree above the floor"
passes "a tree above the floor is refused"

fresh
floor 9
export CASE_INDEX=10
go "index 10 over a floor of 9"
passes "10 is above 9 and was refused: the indices were compared as strings"

fresh
floor 10
export CASE_INDEX=9
go "index 9 under a floor of 10"
refused "9 is below 10 and passed: the indices were compared as strings"

fresh
floor 9
floor 10
export CASE_INDEX=9
go "a floor of 10 reached from 9"
refused "the floor stayed 9 after a good run at 10: the floor was taken as a string"

# ---- no floor -------------------------------------------------------------------
fresh
go "a new box" run
passes "a box with no journal is refused"
journal_has ' attempt ' "a new box does not start its journal"
journal_lacks ' first-seen ' "a box with no .env is new, and it is written down as seen before"

fresh
: >"$BOX/.env"
export CASE_INDEX=1
go "a box from before this release" run
passes "a box with no journal and a .env is refused"
journal_has ' first-seen ' "a box from before the journal is not recorded as first seen"

fresh
: >"$BOX/.install-history"
export CASE_INDEX=0
go "an empty journal"
passes "an empty journal is refused: it holds no floor"

fresh
line attempt 5 >>"$BOX/.install-history"
export CASE_INDEX=1
go "a journal with only an attempt"
passes "an attempt that never ended well moved the floor"

fresh
line attempt 5 >>"$BOX/.install-history"
line failed 5 fail=2 >>"$BOX/.install-history"
export CASE_INDEX=1
go "a journal with only a failed run"
passes "a failed run moved the floor"

# ---- the override ---------------------------------------------------------------
fresh
floor 5
export CASE_INDEX=4 ALLOW_ROLLBACK=1
go "the override with no reason"
refused "the override with no reason passed"
says "ROLLBACK_REASON" "the refusal for a missing reason does not name it"

fresh
floor 5
export CASE_INDEX=4 ALLOW_ROLLBACK=1 ROLLBACK_REASON='   '
go "the override with a blank reason"
refused "a blank reason passed"

fresh
floor 5
export CASE_INDEX=4 ROLLBACK_REASON='gateway refused keys after 1.7.0'
go "a reason with no flag"
refused "a reason alone turned the refusal off"

fresh
floor 5
export CASE_INDEX=4 ALLOW_ROLLBACK=yes ROLLBACK_REASON='gateway refused keys after 1.7.0'
go "a flag that is not 1"
refused "ALLOW_ROLLBACK=yes turned the refusal off"

fresh
floor 5
export CASE_INDEX=4 ALLOW_ROLLBACK=1 ROLLBACK_REASON='gateway refused keys after 1.7.0'
go "the override with a reason" run
passes "the override with a reason was refused"
journal_has ' rollback version=[^ ]+ index=4 commit=[^ ]+ reason="gateway refused keys after 1\.7\.0"$' "the reason is not in the journal"
journal_has ' good version=[^ ]+ index=4 ' "a run under the override that ended well is not recorded"
export ALLOW_ROLLBACK=0
unset ROLLBACK_REASON
go "the same tree again, after the override"
refused "the override moved the floor down, so the next run of that tree passed with no reason"

fresh
floor 5
export CASE_INDEX=5 ALLOW_ROLLBACK=1 ROLLBACK_REASON='left in a template'
go "the override where none is needed" run
passes "an override that is not needed stopped the run"
journal_lacks ' rollback ' "an override that was not needed is recorded as if it had been used"

# A reason is one line of a file the floor is read from.
hostile() { # NAME REASON
	fresh
	floor 5
	export CASE_INDEX=4 ALLOW_ROLLBACK=1 ROLLBACK_REASON="$2"
	go "a reason holding $1" run
	refused "a reason holding $1 went into the journal"
	if [ "$(grep -c . "$BOX/.install-history")" -ne 2 ]; then
		report "a reason holding $1 changed the journal"
	fi
}
hostile "a new line that forges a run" "x
2026-11-09T06:18:44Z good version=9.9.9 index=999 commit=abc"
hostile "a carriage return" "x$(printf '\r')y"
hostile "an escape" "x$(printf '\033')[2Jy"
hostile "a double quote" 'x" reason="y'
hostile "a backslash" 'x\y'
hostile "too many characters" "$(printf '%0301d' 0)"

fresh
floor 5
export CASE_INDEX=4 ALLOW_ROLLBACK=1 ROLLBACK_REASON='η πύλη αρνήθηκε τα κλειδιά'
go "a reason in another alphabet" run
passes "a reason in another alphabet was refused"
journal_has 'reason="η πύλη αρνήθηκε τα κλειδιά"' "a reason in another alphabet did not reach the journal as written"

# ---- the end of a run -----------------------------------------------------------
fresh
floor 1
export CASE_INDEX=3 CASE_FAIL=0
go "a run with no failed check" run
journal_has ' good version=[^ ]+ index=3 commit=' "a run with no failed check does not record a good end"
export CASE_INDEX=2
unset CASE_FAIL
go "a tree below the floor that run set"
refused "the floor did not move after a run with no failed check"

fresh
floor 1
export CASE_INDEX=3 CASE_FAIL=2
go "a run with a failed check" run
journal_lacks ' good version=[^ ]+ index=3 ' "a run with a failed check recorded a good end"
journal_has ' failed version=[^ ]+ index=3 commit=[^ ]+ fail=2$' "a run with a failed check does not record its result"
export CASE_INDEX=1 CASE_FAIL=0
go "the floor after a failed upgrade"
passes "a failed upgrade moved the floor, so going back now needs an override"

fresh
export CASE_INDEX=1
go "the lines of one run" run
journal_has '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z attempt version=[0-9.]+ index=1 commit=[^ ]+ compose=2\.26\.1-4 docker=26\.1\.5$' "an attempt does not record when, the tree, the index and the tools"
if [ "$(ls -l "$BOX/.install-history" | cut -c1-10)" != '-rw-r-----' ]; then
	report "the journal is not mode 0640"
fi

# ---- a journal that cannot be read ----------------------------------------------
garbled() { # NAME TEXT
	fresh
	floor 5
	printf '%s\n' "$2" >>"$BOX/.install-history"
	export CASE_INDEX=5
	go "a journal with $1"
	refused "a line that cannot be read was skipped ($1)"
	says "line 3" "the refusal does not name the line ($1)"
}
garbled "a line of noise" 'this is not a line of the journal'
garbled "a half-written line" "$STAMP good version=1.7.0 ind"
garbled "an index that is not a number" "$STAMP good version=1.7.0 index=nine commit=abc1234"
garbled "an index with a leading zero" "$STAMP good version=1.7.0 index=010 commit=abc1234"
garbled "an index past any real one" "$STAMP good version=1.7.0 index=99999999999999999999 commit=abc1234"
garbled "an event it does not know" "$STAMP great version=1.7.0 index=9 commit=abc1234"
garbled "a shell expansion" "$STAMP good version=\$(id) index=\$((1)) commit=abc1234"

fresh
floor 5
printf 'nonsense\n' >>"$BOX/.install-history"
export CASE_INDEX=5 ALLOW_ROLLBACK=1 ROLLBACK_REASON='the journal was cut short by a full disk'
go "the way through a line that cannot be read"
passes "a line that cannot be read leaves no way through"

fresh
mkdir "$BOX/.install-history"
go "a directory where the journal should be"
refused "something that is not a file at the journal's path reads as no journal"

# A journal of many lines, read in a time a person would not notice.
fresh
for n in $(seq 1 2000); do line good "$((n % 7))"; done >"$BOX/.install-history"
export CASE_INDEX=5
go "a journal of two thousand lines"
refused "the highest index of two thousand lines was not the floor"

# ---- status ---------------------------------------------------------------------
cat >"$SANDBOX/status.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
note() { printf '   %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
. "$SANDBOX/block.sh"
journal_status
HARNESS
status_line() { # NAME
	cases=$((cases + 1))
	case_name="$1"
	set +e
	STACK_DIR="$BOX" bash "$SANDBOX/status.sh" >"$OUT" 2>&1
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then report "$case_name: status stopped with exit $rc"; fi
	if [ "$(grep -c . "$OUT")" -ne 1 ]; then
		report "$case_name: the journal does not print one line"
		sed 's/^/        /' "$OUT" | head -6
	fi
}
fresh
floor 3
printf '2026-11-12T01:02:11Z rollback version=1.6.9 index=0 commit=def5678 reason="gateway refused keys"\n' >>"$BOX/.install-history"
before="$(cksum <"$BOX/.install-history")"
status_line "status with a good run and an override"
says "last good install $STAMP" "status does not name when the last good install was"
says "index 3" "status does not name the index of the last good install"
says 'last override 2026-11-12T01:02:11Z' "status does not name the last override"
says 'gateway refused keys' "status does not give the reason of the last override"
if [ "$(cksum <"$BOX/.install-history")" != "$before" ]; then
	report "status wrote to the journal"
fi
fresh
floor 3
status_line "status with no override"
says "last override none" "status does not say there has been no override"
fresh
status_line "status with no journal"
says "no journal on this box" "status does not say the box has no journal"
fresh
floor 3
printf 'nonsense\n' >>"$BOX/.install-history"
status_line "status with a line it cannot read"
says "line 3" "status does not name the line it cannot read"

# ---- section 1, lifted: a clone and a piped install ------------------------------
# The real lines, so what happens around `cp -a` and the download is what ships.
cat >"$SANDBOX/section1.head" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
note() { printf '   %s\n' "$*"; }
say() { printf '>> %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
HARNESS
mkdir -p "$SANDBOX/bin1"
cp "$SANDBOX/bin/docker" "$SANDBOX/bin1/docker"
cat >"$SANDBOX/bin1/curl" <<'STUB'
#!/usr/bin/env bash
# Serves the compose file of this case to whatever -o names.
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$SANDBOX/served-compose.yaml" "$2"; exit 0; fi
  shift
done
exit 1
STUB
chmod +x "$SANDBOX/bin1/curl"
version_line="$(grep -E '^x-stack-version: ' compose.yaml)"
tree_case() { # NAME DIR: runs section 1 as DIR/install-slice.sh
	cases=$((cases + 1))
	case_name="$1"
	{
		cat "$SANDBOX/section1.head"
		printf '%s\n' "$BLOCK"
		printf 'COMPOSE=(docker compose)\nrollback_floor_check\n'
		printf '%s\n' "$SECTION1"
		printf 'printf "section 1 ended in %%s\\n" "$PWD"\n'
	} >"$2/install-slice.sh"
	set +e
	PATH="$SANDBOX/bin1:$PATH" STACK_DIR="$BOX" bash "$2/install-slice.sh" >"$OUT" 2>&1
	rc=$?
	set -e
}
tree() { # DIR: a tree with a compose file of its own version
	rm -rf "$1"
	mkdir -p "$1"
	printf '%s\nservices: {}\n' "$version_line" >"$1/compose.yaml"
}
fresh
floor 1
tree "$SANDBOX/tree"
printf 'an older copy of the journal\n' >"$SANDBOX/tree/.install-history"
before="$(cksum <"$BOX/.install-history")"
tree_case "a clone that carries a journal of another box" "$SANDBOX/tree"
if [ "$rc" -ne 0 ]; then report "$case_name: section 1 stopped with exit $rc"; sed 's/^/        /' "$OUT" | head -6; fi
if grep -q 'an older copy' "$BOX/.install-history"; then
	report "$case_name: the tree's journal replaced the box's, and with it the floor"
fi
journal_has ' good version=1\.7\.0 index=1 ' "$case_name: the box's own lines did not survive the copy"
journal_has ' attempt ' "$case_name: section 1 did not record the attempt"
if [ -e "$BOX/.install-history.kept" ]; then report "$case_name: a kept copy of the journal was left behind"; fi

fresh
mkdir -p "$SANDBOX/piped"
rm -f "$SANDBOX/piped/compose.yaml"
printf 'the box as it was\n' >"$BOX/compose.yaml"
printf 'x-stack-version: "0.0.1"\nservices: {}\n' >"$SANDBOX/served-compose.yaml"
tree_case "a piped install whose compose file is another version" "$SANDBOX/piped"
if [ "$rc" -ne 1 ]; then report "$case_name: it was not refused (exit $rc)"; sed 's/^/        /' "$OUT" | head -6; fi
says "0.0.1" "$case_name: the refusal does not say what the compose file claims"
if [ "$(cat "$BOX/compose.yaml")" != 'the box as it was' ]; then report "$case_name: the box's compose.yaml was replaced before the refusal"; fi
if [ -e "$BOX/.install-history" ]; then report "$case_name: the journal was written before the refusal"; fi
if ls "$BOX"/compose.yaml.* >/dev/null 2>&1; then report "$case_name: a fetched copy was left behind"; fi

fresh
printf 'services: {}\n' >"$SANDBOX/served-compose.yaml"
tree_case "a piped install whose compose file names no version" "$SANDBOX/piped"
if [ "$rc" -ne 1 ]; then report "$case_name: it was not refused (exit $rc)"; fi

fresh
printf '%s\nservices: {}\n' "$version_line" >"$SANDBOX/served-compose.yaml"
tree_case "a piped install of one version" "$SANDBOX/piped"
if [ "$rc" -ne 0 ]; then report "$case_name: it stopped with exit $rc"; sed 's/^/        /' "$OUT" | head -6; fi
if [ ! -f "$BOX/compose.yaml" ]; then report "$case_name: the compose file did not arrive"; fi
journal_has ' attempt .* commit=piped ' "$case_name: a piped run does not say it has no commit"

# ---- the real install.sh, up to where it stops -----------------------------------
# A copy with only the path of os-release changed, on stub tools that log every call.
mkdir -p "$SANDBOX/bin2"
printf 'ID=debian\nPRETTY_NAME="a stub"\n' >"$SANDBOX/os-release"
sed "s#/etc/os-release#$SANDBOX/os-release#g" install.sh >"$SANDBOX/install-copy.sh"
export TOOL_LOG="$SANDBOX/tools.log"
for tool in apt-get docker git curl cosign ufw sysctl; do
	cat >"$SANDBOX/bin2/$tool" <<STUB
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >>"\$TOOL_LOG"
exit 0
STUB
done
# `id` says root, and systemctl fails, which ends a run that got past the preflight.
printf '#!/usr/bin/env bash\necho 0\n' >"$SANDBOX/bin2/id"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >>"$TOOL_LOG"\nexit 1\n' >"$SANDBOX/bin2/systemctl"
chmod +x "$SANDBOX"/bin2/*
index="$(sed -nE 's/^STACK_ROLLBACK_INDEX=([0-9]+)$/\1/p' <<<"$BLOCK")"
real_run() { # NAME
	cases=$((cases + 1))
	case_name="$1"
	: >"$TOOL_LOG"
	set +e
	PATH="$SANDBOX/bin2:$PATH" STACK_DIR="$BOX" bash "$SANDBOX/install-copy.sh" >"$OUT" 2>&1 </dev/null
	rc=$?
	set -e
}
fresh
floor "$((index + 1))"
printf 'GATEWAY_BIND=127.0.0.1\n' >"$BOX/.env"
before="$(find "$BOX" -type f -exec cksum {} + | sort)"
real_run "the real install.sh below the floor"
if [ "$rc" -ne 1 ]; then report "$case_name: it was not refused (exit $rc)"; sed 's/^/        /' "$OUT" | tail -6; fi
says "ALLOW_ROLLBACK=1" "$case_name: the run stopped for another reason"
if [ -s "$TOOL_LOG" ]; then
	report "$case_name: a tool ran before the refusal:"
	sed 's/^/        /' "$TOOL_LOG" | head -5
fi
if [ "$(find "$BOX" -type f -exec cksum {} + | sort)" != "$before" ]; then
	report "$case_name: a file of the box changed before the refusal"
fi

fresh
floor "$index"
real_run "the real install.sh at the floor"
says "docker did not start" "$case_name: a tree at the floor did not get past the preflight"
if ! grep -q '^apt-get ' "$TOOL_LOG"; then report "$case_name: it never reached the package step"; fi

# ---- the order in install.sh -----------------------------------------------------
python3 - <<'PY' || problems=$((problems + 1))
import re
import sys
lines = open("install.sh").read().splitlines()
def first(pat):
    for i, l in enumerate(lines, 1):
        if not l.lstrip().startswith("#") and re.search(pat, l):
            return i
    return None
check = first(r"^rollback_floor_check$")
distro = first(r'die "this expects Debian or Ubuntu')
apt = first(r"^\s*apt-get\s")
begin = first(r"^\s*journal_begin\s")
copy = first(r'cp -a "\$HERE/\." "\$STACK_DIR/"')
stack = first(r"^stack_checks\s")
end = first(r"^journal_end$")
last = max(i for i, l in enumerate(lines, 1) if l.startswith("exit "))
bad = []
if check is None or distro is None or not (distro < check):
    bad.append("the floor check does not stand right after the distro check")
if check is not None and apt is not None and check > apt:
    bad.append("the floor check comes after the first apt-get")
if check is not None and copy is not None and check > copy:
    bad.append("the floor check comes after cp -a, which replaces install.sh and compose.yaml")
if begin is None or copy is None or begin > copy:
    bad.append("the journal's first line is written after the tree is copied over the box")
if end is None or stack is None or end < stack:
    bad.append("the journal's last line is written before the checks ran")
if end is not None and last - end > 8:
    bad.append("the journal's last line is not at the end of the run")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY

# ---- what the block may not do ---------------------------------------------------
# The decision reads an integer. A version compared here is how `1.10.0 < 1.9.9` stops every upgrade.
if grep -nE 'sort -V|sort --version|\$STACK_VERSION" *-[lg][te]|version.*(-lt|-gt|-le|-ge)' <<<"$BLOCK"; then
	report "the block compares versions: the floor is an integer"
fi
# Raised only when an older tree became unsafe, and the release says so.
if [ "$index" -gt 1 ]; then
	if ! grep -lqE "^(security|irreversible): .*rollback index $index\b" docs/releases/v*.md; then
		report "STACK_ROLLBACK_INDEX is $index and no release note has a 'security:' or 'irreversible:' line naming rollback index $index"
	fi
fi

# ---- what the docs say -----------------------------------------------------------
needs() { # REGEX WHY
	if ! grep -qiE -- "$1" <<<"$README_SECTION"; then report "the README: $2"; fi
}
needs 'guard against mistakes' "it does not say this is a guard against mistakes"
needs 'not protection against an attacker' "it does not say this is not protection against an attacker"
needs 'not signed' "it does not say the tree is not signed"
needs 'inside the tree it checks' "it does not say the check lives inside the tree it checks"
needs 'older than this change has no check' "it does not say an older tree has no check at all"
needs '_IMAGE' "it does not name .env image overrides as outside this"
needs 'docker compose up' "it does not name a direct docker compose up as outside this"
needs 'ALLOW_ROLLBACK=1 ROLLBACK_REASON=' "it does not give the way through"
if grep -nEi "(cannot|can't|can not|impossible to|never) +(be +)?roll(ed)?( +|-)?back|no way back|cannot go back(wards)?" README.md; then
	report "the README claims the stack cannot be rolled back"
fi

if [ "$cases" -lt 40 ]; then
	report "only $cases case(s) ran, so this measured almost NOTHING"
fi
if [ "$problems" -gt 0 ]; then
	printf '%d problem(s) with the rollback floor.\n' "$problems"
	exit 1
fi
printf 'OK: the rollback floor held on %d cases; the tree is index %s.\n' "$cases" "$index"
