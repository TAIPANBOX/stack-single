#!/usr/bin/env bash
#
# Enforces invariant 51 of CLAUDE.md (1.3.2, D10): the record plane is a core control, so it is ON
# by default from the pinned trailryx-node image (no build), and WITH_RECORD=0 is the explicit way off.
#
# Before 1.3.2 WITH_RECORD unset meant off, and WITH_RECORD=1 built trailryx from source; the `up`
# profile list never named `record`, so a default box had no record plane at all.
#
# WHAT THIS CHECKS.
#   A. THE SWITCH. The `# record-plane:` block of install.sh, lifted and run per case: unset and 1
#      give RECORD_ON=1; 0 gives RECORD_ON=0; any other value is refused before anything is installed.
#   B. THE PROFILE LISTS. Both lists that name the record profile (the image pulls and the `up`) name
#      it only when RECORD_ON=1, and the `up` list names it at all.
#   C. NO BUILD. WITH_RECORD builds nothing: the only build of trailryx is BUILD_FROM_SOURCE's.
#   D. THE PIN. compose.yaml's record-seal image is the pinned trailryx-node tag with a digest.
#   E. THE DOCS. README's record section states the default and WITH_RECORD=0, and no longer says the
#      plane is off unless asked for.

set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

sed -n '/^# record-plane: begin$/,/^# record-plane: end$/p' install.sh >"$scratch/block.sh"
if ! grep -q '^record_resolve() {' "$scratch/block.sh"; then
  fail "install.sh has no '# record-plane:' block with record_resolve, so the default was not measured"
else
  case_rc() { # WITH_RECORD VALUE: prints RECORD_ON or the refusal
    bash -c '
      set -euo pipefail
      die() { echo "DIE: $*"; exit 3; }
      WITH_RECORD="$1"
      . "$2"
      record_resolve
      echo "RECORD_ON=$RECORD_ON"
    ' _ "$1" "$scratch/block.sh" 2>&1 || true
  }
  for v in "" 1; do
    out="$(case_rc "$v")"
    printf '%s' "$out" | grep -qx 'RECORD_ON=1' || fail "A. WITH_RECORD='$v' does not turn the record plane on: $out"
  done
  out="$(case_rc 0)"
  printf '%s' "$out" | grep -qx 'RECORD_ON=0' || fail "A. WITH_RECORD=0 does not turn the record plane off: $out"
  out="$(case_rc yes)"
  printf '%s' "$out" | grep -q '^DIE:' || fail "A. WITH_RECORD=yes was accepted, and it is neither 0 nor 1: $out"
fi

# B. both profile lists
if grep -q 'WITH_RECORD:-}" \]  *|| profiles+=(--profile record)\|WITH_RECORD:-}" \] || profiles+=(--profile record)' install.sh; then
  fail "B. the image-pull profile list still names the record profile only when WITH_RECORD is set"
fi
grep -q 'RECORD_ON.*--profile record\|--profile record.*RECORD_ON' install.sh \
  || fail "B. no profile list names the record profile behind RECORD_ON"
if ! grep -q 'UP_PROFILES+=(--profile record)' install.sh; then
  fail "B. the up profile list never names the record profile, so a default box starts no record plane"
fi

# C. WITH_RECORD builds nothing
if grep -n 'if \[ -n "\${WITH_RECORD:-}" \]' install.sh | grep -q .; then
  fail "C. install.sh still builds trailryx when WITH_RECORD is set"
fi

# D. the pin
grep -q 'trailryx-node:v[0-9.]*@sha256:' compose.yaml \
  || fail "D. compose.yaml's record-seal image is not the pinned trailryx-node tag with a digest"

# E. the docs
sect="$(sed -n '/^## The record: what this box did, sealed$/,/^## /p' README.md)"
if [ -z "$sect" ]; then
  fail "E. README.md has no 'The record' section, so the default was not measured"
else
  printf '%s' "$sect" | grep -q 'WITH_RECORD=0' || fail "E. the README record section does not say WITH_RECORD=0 turns the plane off"
  printf '%s' "$sect" | grep -q 'Off unless you ask for it' && fail "E. the README record section still says the plane is off unless asked for"
fi

if [ "$problems" -ne 0 ]; then
  printf 'record-plane-is-on-by-default: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: record-plane-is-on-by-default (invariant 51): on from the pinned image unless WITH_RECORD=0"
