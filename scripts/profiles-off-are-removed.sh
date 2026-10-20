#!/usr/bin/env bash
#
# Enforces invariant 50 of CLAUDE.md: every compose profile is one of two kinds, and the installer treats
# each kind by its own rule.
#
#   INSTALLER-MANAGED (PROFILES_INSTALLED in install.sh): this installer starts it from its own flags. When a run
#     turns it off, its containers are stopped and removed by name, under that profile.
#   OPERATOR-STARTED (PROFILES_OPERATOR in install.sh): an operator starts it with `docker compose --profile P up -d`.
#     This installer never removes it. A RUNNING container of it is re-upped at this run's pinned image, so no
#     stale image survives an upgrade (forge's costcrew stayed on v0.6.0 after 1.1.35 to 1.3.1). The closing
#     report lists each one kept, with its image.
#
# The two lists are ONE table in install.sh, between `# profile-table:` markers. A profile in compose.yaml that
# is in neither list, or in both, is refused, so a new profile cannot fall through either rule.
#
# WHY. `up --remove-orphans` does not remove a container whose profile the run does not name (measured
# 2026-10-04). The first fix removed every profile a run did not name, which also removed what the README tells
# an operator to start by hand (egress, egress-browser, finops, routines). The second fix re-upped every running
# service that `compose --profile P ps` lists, which includes the core's own services (the gateway, the console,
# wardryx), so each operator profile restarted the core.
#
# WHAT THIS CHECKS, by running the installer's own cleanup slice (lifted out of install.sh, from the up that
# starts the stack to the identity-map restart) against a stub `docker compose`. The stub knows every profile of
# this compose file, the services each names, which are running, and lists the core's services in `ps` as
# `compose` does; it logs every call, and the closing report text is captured.
#   A. a run that names record and delegation, with costcrew, scopyx and typryx running (typryx under typed, which
#      this run does not name): the installer-managed profiles that are off have their services removed by name
#      (typed, typed-risk-signal, openai-door);
#   B. the operator-started profiles are never removed, and their RUNNING services are re-upped at this run's
#      pins (finops costcrew, egress scopyx); a NOT-running operator service is neither removed nor started;
#   C. no service of a profile this run names is removed (record-seal, vouchryx);
#   D. WITH_RECORD=0 (the run names only delegation) removes record-seal, which is installer-managed;
#   E. the table: every profile of compose.yaml is in exactly one of the two lists;
#   F. the closing report says which operator-started profiles it kept, and that the installer never removes them;
#   G. no operator-started profile re-ups or lists a service of the core (the gateway, the console, wardryx), and
#      the closing report names none of them.
# It refuses to report OK when the slice, the table or the stub saw no profile at all.

set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f install.sh ] || [ ! -f compose.yaml ]; then
  fail "install.sh or compose.yaml is not there, so the profile cleanup was not measured"
  exit 1
fi

TABLE="$(sed -n '/^# profile-table: begin$/,/^# profile-table: end$/p' install.sh)"
if ! printf '%s\n' "$TABLE" | grep -q '^PROFILES_INSTALLED='; then
  fail "D. install.sh has no '# profile-table:' block with PROFILES_INSTALLED, so the two kinds are not defined"
fi
if ! printf '%s\n' "$TABLE" | grep -q '^PROFILES_OPERATOR='; then
  fail "D. install.sh's '# profile-table:' block has no PROFILES_OPERATOR, so the operator-started profiles are not defined"
fi
printf '%s\n' "$TABLE" >"$scratch/table.sh"

# The slice: from the up that starts the stack to the identity-map restart that follows the cleanup.
SLICE="$(sed -n '/"\${UP_PROFILES\[@\]}" up -d --remove-orphans$/,/gateway reads its identity map once/p' install.sh)"
if [ -z "$SLICE" ]; then
  fail "install.sh has no 'up -d --remove-orphans' slice ending at the identity-map restart, so the profile cleanup was not measured"
  exit 1
fi
printf '%s\n' "$SLICE" >"$scratch/slice.sh"

# The closing report's profile note, lifted the same way.
awk '/^profile_reach_note\(\) \{/,/^\}$/' install.sh >"$scratch/reach.sh"
if [ ! -s "$scratch/reach.sh" ]; then
  fail "G. install.sh has no profile_reach_note, so the closing report's profile note was not measured"
fi

# A stub compose. Its `ps` lists the core's services as well as the profile's, as compose does when a profile
# is named: the core is always part of a project.
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
    manual) echo idryx-detect ;;
    *) echo "" ;;
  esac
}
core_svcs="tokenfuse-gateway console wardryx"
state_of() {
  case " ${FAKE_RUNNING:-} " in *" $1 "*) echo running ;; *) echo exited ;; esac
}
case "${rest[*]:-}" in
  "config --profiles")
    printf '%s\n' egress egress-browser typed typed-risk-signal delegation openai-door finops record routines manual ;;
  "config --services")
    printf '%s\n' $core_svcs
    for p in "${profiles[@]:-}"; do [ -n "$p" ] && svc_of "$p"; done ;;
  "ps --format {{.Image}} "*)
    svc="${rest[-1]}"
    printf 'ghcr.io/taipanbox/%s:old\n' "$svc" ;;
  ps\ *)
    for s in $core_svcs; do
      printf '%s ghcr.io/taipanbox/%s:old running\n' "$s" "$s"
    done
    for p in "${profiles[@]:-}"; do
      [ -n "$p" ] || continue
      for s in $(svc_of "$p"); do
        printf '%s ghcr.io/taipanbox/%s:old %s\n' "$s" "$s" "$(state_of "$s")"
      done
    done ;;
  *)
    exit 0 ;;
esac
FAKE
chmod +x "$scratch/fakecompose"

# run_slice LOG RUNNING UPS REPORT: runs the slice once, then writes the closing report's profile note to REPORT.
# UPS is the run's `--profile P` pairs; an empty run gets a name no profile has, because bash 3.2 (this gate
# runs on a Mac) fails on an empty array under set -u.
run_slice() {
  local log="$1" running="$2" ups="$3" report="$4" out rc
  : >"$log"
  out="$(FAKE_LOG="$log" FAKE_RUNNING="$running" UPS="${ups:---profile noflag}" bash -c '
    set -euo pipefail
    COMPOSE=("$1")
    UP_PROFILES=($UPS)
    TYPED_PLANE=off; TYPED_RISK_ON=0; DOOR_ON=0; STACK_DIR="$2"
    note() { :; }; say() { :; }
    . "$3"
    . "$4"
    . "$6"
    printf "%s" "$(profile_reach_note)" >"$5"
  ' _ "$scratch/fakecompose" "$scratch" "$scratch/table.sh" "$scratch/slice.sh" "$report" "$scratch/reach.sh" 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "the cleanup slice failed under the stub compose: $out"
}

LOG_A="$scratch/calls-a.log"
LOG_B="$scratch/calls-b.log"
REPORT_A="$scratch/report-a.txt"
run_slice "$LOG_A" "costcrew scopyx typryx record-seal vouchryx" "--profile record --profile delegation" "$REPORT_A"
run_slice "$LOG_B" "record-seal vouchryx" "--profile delegation" "$scratch/report-b.txt"

removed_a="$(grep -E ' rm ' "$LOG_A" | grep -- '-sf' || true)"
up_a="$(grep -E ' up -d' "$LOG_A" || true)"

# A. installer-managed profiles that this run turns off: removed by name, under their own profile.
expect_removed() { # PROFILE SERVICE: removed under that profile
  printf '%s\n' "$removed_a" | grep -q -E -- "--profile $1 rm -sf( .*)? $2( |\$)" \
    || fail "A. the stale $2 of profile $1 is not removed by this run, and that profile is installer-managed and off"
}
expect_removed typed typryx
expect_removed typed tokenfuse-mcp-broker
expect_removed typed-risk-signal typryx-wardryx-proxy
expect_removed openai-door tokenfuse-gateway-openai

# B. operator-started profiles are never removed; a running one is re-upped at this run's pins.
for s in costcrew costcrew-init scopyx; do
  printf '%s\n' "$removed_a" | grep -q -E -- " $s( |\$)" \
    && fail "B. $s belongs to an operator-started profile, and the installer removed it"
done
printf '%s\n' "$up_a" | grep -q -E -- '--profile finops up -d( .*)? costcrew( |$)' \
  || fail "B. the running costcrew of profile finops is not re-upped at this run's pins, so an upgrade would leave its old image running"
printf '%s\n' "$up_a" | grep -q -E -- '--profile egress up -d( .*)? scopyx( |$)' \
  || fail "B. the running scopyx of profile egress is not re-upped at this run's pins, so an upgrade would leave its old image running"
for s in focus-export verdryx-drift idryx-detect; do
  printf '%s\n' "$removed_a $up_a" | grep -q -E -- " $s( |\$)" \
    && fail "B. $s is an operator-started service that is not running, and the installer removed or started it"
done

# C. a profile this run names keeps its services.
for s in record-seal vouchryx; do
  printf '%s\n' "$removed_a" | grep -q -E -- " $s( |\$)" \
    && fail "C. $s belongs to a profile this run names, and the cleanup removed it"
done

# D. WITH_RECORD=0 (the run names only delegation): record-seal is installer-managed and off, so it is removed.
grep -q -E -- '--profile record rm -sf( .*)? record-seal( |$)' "$LOG_B" \
  || fail "D. with WITH_RECORD=0 the running record-seal is not removed: the record plane would keep running after the operator turned it off"

# E. the table: every profile of compose.yaml is in exactly one list.
compose_profiles="$(grep -o 'profiles: \[[^]]*\]' compose.yaml | sed -e 's/profiles: \[//' -e 's/\]//' -e 's/"//g' -e 's/,/ /g' | tr ' ' '\n' | sed '/^$/d' | sort -u)"
if [ -z "$compose_profiles" ]; then
  fail "E. compose.yaml names no profile, so the table was not measured"
fi
for p in $compose_profiles; do
  in_i=0; in_o=0
  ( PROFILES_INSTALLED=""; PROFILES_OPERATOR=""; . "$scratch/table.sh"; case " $PROFILES_INSTALLED " in *" $p "*) exit 0 ;; *) exit 1 ;; esac ) && in_i=1 || true
  ( PROFILES_INSTALLED=""; PROFILES_OPERATOR=""; . "$scratch/table.sh"; case " $PROFILES_OPERATOR " in *" $p "*) exit 0 ;; *) exit 1 ;; esac ) && in_o=1 || true
  if [ $((in_i + in_o)) -ne 1 ]; then
    fail "E. compose.yaml's profile $p is in $([ "$in_i" = 1 ] && echo both || echo neither) of install.sh's two profile lists: a profile must be installer-managed or operator-started, and not both"
  fi
done

# F. the closing report says which operator-started profiles it kept, and that the installer never removes them.
grep -q 'This installer never removes them' install.sh \
  || fail "F. install.sh does not say in the closing report that operator-started profiles are never removed by it"
grep -q 'Operator-started profiles kept on this run' install.sh \
  || fail "F. the closing report does not list the operator-started profiles it kept"

# G. no operator-started profile re-ups or lists a service of the core, and the closing report names none of them.
for s in tokenfuse-gateway console wardryx; do
  printf '%s\n' "$up_a" | grep -q -E -- " up -d( .*)? $s( |\$)" \
    && fail "G. the core service $s is re-upped under an operator-started profile: the run would restart the gateway, the console or wardryx as if an operator had started them"
  grep -q -E -- ": $s, image" "$REPORT_A" \
    && fail "G. the closing report lists the core service $s as an operator-started service"
done
grep -q -E -- '^[[:space:]]*finops: costcrew,' "$REPORT_A" \
  || fail "G. the closing report does not list costcrew as the running finops service it kept (report: $(tr '\n' ' ' <"$REPORT_A"))"
grep -q -E -- '^[[:space:]]*egress: scopyx,' "$REPORT_A" \
  || fail "G. the closing report does not list scopyx as the running egress service it kept"

if [ "$problems" -ne 0 ]; then
  printf 'profiles-off-are-removed: %d problem(s)\n' "$problems"
  printf 'run A calls:\n%s\n' "$(grep -E ' rm | up -d' "$LOG_A" || echo '  (none)')"
  exit 1
fi
echo "OK: profiles-off-are-removed (invariant 50): installer-managed profiles that are off are removed by name; operator-started ones are kept, and a running one is re-upped at this run's pins, without the core's services; every compose profile is in exactly one list"
