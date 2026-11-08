#!/usr/bin/env bash
# init-volumes' capabilities on FRESH volumes (root:root 0755, a first install) and then again on the
# volumes it has just re-owned (every later run), each capability taken out in turn. Project g312cap.
set -uo pipefail
. "$(dirname "$0")/common.sh"
cd "$L" || exit 1
CP=(docker compose -p g312cap -f compose.yaml -f compose.exp.yaml)
one() { # label, override body: a first run on fresh volumes, then a second run on the same volumes
  printf 'services:\n  init-volumes:\n%s\n' "$2" >compose.exp.yaml
  "${CP[@]}" down -v >/dev/null 2>&1
  printf 'services:\n  init-volumes:\n    pids_limit: 32\n' >compose.exp.yaml
  first="$( printf 'services:\n  init-volumes:\n%s\n' "$2" >compose.exp.yaml; "${CP[@]}" run --rm --no-deps init-volumes 2>&1)"; r1=$?
  printf 'services:\n  init-volumes:\n    pids_limit: 32\n' >compose.exp.yaml
  "${CP[@]}" run --rm --no-deps init-volumes >/dev/null 2>&1   # the volumes as a full run leaves them
  printf 'services:\n  init-volumes:\n%s\n' "$2" >compose.exp.yaml
  again="$("${CP[@]}" run --rm --no-deps init-volumes 2>&1)"; r2=$?
  log "$1: first run on fresh volumes exit $r1: $(printf '%s' "$first" | grep -vE '^ *Container|Creat|Network|Volume' | tail -1 | cut -c1-150) | a later run exit $r2: $(printf '%s' "$again" | grep -vE '^ *Container|Creat|Network|Volume' | tail -1 | cut -c1-150)"
}
say "init-volumes on fresh volumes, then on its own volumes"
one "as written (CHOWN DAC_OVERRIDE FOWNER)" "    pids_limit: 32"
one "without CHOWN" "    cap_add: !override [DAC_OVERRIDE, FOWNER]"
one "without DAC_OVERRIDE" "    cap_add: !override [CHOWN, FOWNER]"
one "without FOWNER" "    cap_add: !override [CHOWN, DAC_OVERRIDE]"
one "with pids_limit 4" "    pids_limit: 4"
"${CP[@]}" down -v >/dev/null 2>&1
rm -f compose.exp.yaml
log "g312cap volumes left: $(docker volume ls -q | grep -c '^g312cap_' || true)"
