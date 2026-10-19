#!/usr/bin/env bash
#
# Enforces invariant 50 of CLAUDE.md (1.3.2, D4 generalised): every compose profile this run does
# not name is stopped and its containers removed, and no profile this run names loses a container.
#
# WHY. `up --remove-orphans` does not remove a container whose profile this run does not name
# (measured 2026-10-04). Before 1.3.2 the installer removed two profiles by hand (typed-risk-signal
# and openai-door) and left every other profile to chance: after the 1.1.35 to 1.3.1 upgrade on a
# forge box the costcrew container of profile `finops` still ran image v0.6.0 from 2026-10-14, and
# the typed plane's broker and typryx kept running stale beside a box whose typed plane was off.
#
# WHAT THIS CHECKS. The installer's own cleanup, lifted out of install.sh as the slice that runs
# after `up -d --remove-orphans` (up to the identity-map restart), run against a stub `docker
# compose` that knows every profile of this compose file, the services each one names, and logs
# every call. The run names two profiles (record and delegation), so:
#   A. every OTHER profile's services are removed by name, under their own profile
#      (egress, egress-browser, typed, typed-risk-signal, openai-door, finops, routines);
#   B. no service of a profile this run names is removed (record-seal, vouchryx);
#   C. no removal names a service that a named profile also names (a shared service is kept);
#   D. the cleanup asks compose for the profiles the file defines, not a hand-kept list, so a new
#      profile is covered without an edit here.
# It refuses to report OK when the slice cannot be found, and when the stub saw no profile at all.

set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f install.sh ]; then
  fail "install.sh is not there, so the profile cleanup was not measured"
  exit 1
fi

# The slice: from the up that starts the stack to the identity-map restart that follows the cleanup.
SLICE="$(sed -n '/"\${UP_PROFILES\[@\]}" up -d --remove-orphans$/,/gateway reads its identity map once/p' install.sh)"
if [ -z "$SLICE" ]; then
  fail "install.sh has no 'up -d --remove-orphans' slice ending at the identity-map restart, so the profile cleanup was not measured"
  exit 1
fi
printf '%s\n' "$SLICE" >"$scratch/slice.sh"

# A stub compose: knows the profiles of this file and the services each names. Logs every call.
cat >"$scratch/fakecompose" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
profiles=(); rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profiles+=("$2"); shift 2 ;;
    *) rest+=("$1"); shift ;;
  esac
done
svc_of() {
  case "$1" in
    egress) echo scopyx ;;
    egress-browser) echo scopyx-browser ;;
    typed) echo "typryx tokenfuse-mcp-broker" ;;
    typed-risk-signal) echo typryx-wardryx-proxy ;;
    delegation) echo vouchryx ;;
    openai-door) echo tokenfuse-gateway-openai ;;
    finops) echo "costcrew-init costcrew" ;;
    record) echo record-seal ;;
    routines) echo "focus-export verdryx-drift" ;;
    *) echo "" ;;
  esac
}
case "${rest[*]:-}" in
  "config --profiles")
    printf '%s\n' egress egress-browser typed typed-risk-signal delegation openai-door finops record routines ;;
  "config --services")
    printf '%s\n' tokenfuse-gateway console wardryx
    for p in "${profiles[@]:-}"; do [ -n "$p" ] && svc_of "$p"; done ;;
  rm\ *|up\ *|*)
    exit 0 ;;
esac
FAKE
chmod +x "$scratch/fakecompose"

LOG="$scratch/calls.log"
: >"$LOG"
# The run names record and delegation. Everything else is off.
out="$(bash -c '
  set -euo pipefail
  COMPOSE=("$1")
  UP_PROFILES=(--profile record --profile delegation)
  TYPED_PLANE=off; TYPED_RISK_ON=0; DOOR_ON=0; STACK_DIR="$2"; note() { :; }; say() { :; }
  export FAKE_LOG="$3"
  . "$4"
' _ "$scratch/fakecompose" "$scratch" "$LOG" "$scratch/slice.sh" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "the cleanup slice failed under the stub compose: $out"

# The calls that remove containers by name, under a profile.
removed="$(grep -E ' rm ' "$LOG" | grep -- '-sf' || true)"

expect_removed() { # PROFILE SERVICE...: each service is removed under that profile
  local p="$1" s
  shift
  for s in "$@"; do
    printf '%s\n' "$removed" | grep -q -E -- "--profile $p rm -sf( .*)? $s( |\$)" \
      || fail "A. the stale $s of profile $p is not removed by this run (the profile is off), so the container keeps running from the earlier install"
  done
}
expect_removed egress scopyx
expect_removed egress-browser scopyx-browser
expect_removed typed typryx tokenfuse-mcp-broker
expect_removed typed-risk-signal typryx-wardryx-proxy
expect_removed openai-door tokenfuse-gateway-openai
expect_removed finops costcrew-init costcrew
expect_removed routines focus-export verdryx-drift

for s in record-seal vouchryx; do
  printf '%s\n' "$removed" | grep -q -E -- " $s( |\$)" \
    && fail "B. $s belongs to a profile this run names, and the cleanup removed it"
done
for s in tokenfuse-gateway console wardryx; do
  printf '%s\n' "$removed" | grep -q -E -- " $s( |\$)" \
    && fail "B. the core service $s was removed by the profile cleanup"
done

if [ -z "$(grep -E 'config --profiles' "$LOG" || true)" ]; then
  fail "D. the cleanup does not ask compose for the profiles the file defines, so a new profile would be missed"
fi

if [ "$problems" -ne 0 ]; then
  printf 'profiles-off-are-removed: %d problem(s)\n' "$problems"
  printf 'calls the cleanup made:\n%s\n' "$(grep -E ' rm ' "$LOG" || echo '  (none)')"
  exit 1
fi
echo "OK: profiles-off-are-removed (invariant 50): every profile this run does not name is stopped and removed, by name, and none it names is touched"
