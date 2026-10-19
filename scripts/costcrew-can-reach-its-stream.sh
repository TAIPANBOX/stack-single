#!/usr/bin/env bash
#
# Enforces invariant 52 of CLAUDE.md (1.4.0, D11): the FinOps console (costcrew, uid 10003, profile
# finops) can reach the one file it writes on the bus. The bus directory is `root:10001`, and a
# directory is entered by the `x` bit, so the directory needs the other-execute bit for a uid that is
# not in the bus group. Mode 0750 gave costcrew "permission denied" on open, measured on gcp2
# 2026-10-19 (costcrew-init had already created costcrew.ndjson, owned 10003:10001 0640, so the file
# was right and the directory above it was not). The fix keeps every other property: no uid but the
# setup script creates a file in the directory (no write bit for others), and costcrew joins no group.
#
# WHAT THIS CHECKS.
#   A. THE DIRECTORY. The mode init-volumes gives /vol/events has the other-execute bit (0751 or
#      wider in the last digit), and the group and the write bits are not widened.
#   B. THE STREAM. costcrew-init gives costcrew.ndjson to 10003 with group 10001, mode 0640, and
#      creates it, so the file exists before costcrew opens it.
#   C. NO GROUP. costcrew has no group_add and runs as 10003:10003, so it reads no other plane's
#      stream through the group bits (invariants 24 and 41).
#   D. MEASURED SOMETHING. Refuses to report OK when the events chmod or costcrew-init is not found.

set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

[ -f compose.yaml ] || { fail "compose.yaml is not there"; exit 1; }

# A. the bus directory's mode, from the one-shot that creates it.
mode="$(grep -o 'chmod [0-7]\{3,4\} /vol/events\b' compose.yaml | head -1 | awk '{print $2}')"
if [ -z "$mode" ]; then
  fail "D. init-volumes sets no mode on /vol/events, so the bus directory's traversal was not measured"
else
  digits="${mode: -3}"
  owner="${digits:0:1}"; group="${digits:1:1}"; other="${digits:2:1}"
  [ $((other & 1)) -eq 1 ] || fail "A. the bus directory is mode $mode: others have no execute bit, so a uid outside group 10001 cannot reach costcrew.ndjson (permission denied)"
  [ $((other & 6)) -eq 0 ] || fail "A. the bus directory is mode $mode: others can read or write it, which invariant 41 forbids"
  [ $((group & 2)) -eq 0 ] || fail "A. the bus directory is mode $mode: the bus group can create files in it, which invariant 41 forbids"
fi

# B. the stream, given to costcrew and created before it starts.
grep -q '\[ -e /vol/events/costcrew.ndjson \] || : > /vol/events/costcrew.ndjson' compose.yaml \
  || fail "B. costcrew-init does not create costcrew.ndjson"
grep -q 'chown 10003:10001 /vol/events/costcrew.ndjson && chmod 0640 /vol/events/costcrew.ndjson' compose.yaml \
  || fail "B. costcrew-init does not give costcrew.ndjson to 10003:10001 at 0640"

# C. no group, outside the bus
costcrew="$(sed -n '/^  costcrew:$/,/^  [a-z][a-z0-9-]*:$/p' compose.yaml)"
[ -n "$costcrew" ] || { fail "D. costcrew's service block was not found, so its groups were not measured"; }
if printf '%s' "$costcrew" | grep -q 'group_add'; then
  fail "C. costcrew has a group_add, so it could read the bus streams through the group bits"
fi

if [ "$problems" -ne 0 ]; then
  printf 'costcrew-can-reach-its-stream: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: costcrew-can-reach-its-stream (invariant 52): costcrew can enter the bus directory and reach its own file, and joins no group"
