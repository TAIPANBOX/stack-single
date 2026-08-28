#!/usr/bin/env bash
#
# Enforces: the record plane reads the bus and writes somewhere else.
#
# WHAT THIS IS ABOUT
#
# `events` is a BUS. Four components append to it, anything may read it, and an
# operator clearing disk space deletes from it: that is what a bus is for. The
# record plane writes a hash-chained store of sealed segments, their manifests
# and one cursor per source file, and the whole value of it is that nobody can
# quietly change what it says.
#
# Put the record on the bus's own volume and you have evidence an operator can
# delete while tidying up the very thing it is evidence about. Nothing would
# look wrong: the stack comes up, the seal runs, the pack verifies, and the
# only symptom is that one day the record of last month is gone along with the
# events it was about.
#
# So this holds three things about compose.yaml:
#
#   1. `record-seal` mounts the bus READ ONLY. It is a reader of events and a
#      writer of records, and the mount says so rather than the code being
#      trusted to.
#   2. It writes to a volume that is not `events`.
#   3. Nothing else writes that volume. The store takes no cross-process lock,
#      so a second writer is two minters of one shard.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# If `record-seal` is not in compose.yaml at all, this says so and fails. A
# gate whose subject has been deleted must not read as a clean bill of health;
# that is the estate's own rule and this file is not an exception to it.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - compose.yaml <<'PY'
import re
import sys

text = open(sys.argv[1]).read()

# The services block, split on two-space-indented keys. compose.yaml here is
# hand-written and hand-indented, and parsing it with a YAML library would mean
# a dependency this repository does not have on the box that runs this.
blocks = {}
current = None
for line in text.split("\n"):
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m and not line.startswith("    "):
        current = m.group(1)
        blocks[current] = []
    elif current is not None:
        if line and not line.startswith("  "):
            current = None
        else:
            blocks[current].append(line)

problems = 0

if "record-seal" not in blocks:
    print("FAIL: compose.yaml has no `record-seal` service, so this measured NOTHING.")
    print("      Either the record profile was removed, in which case delete this")
    print("      gate deliberately, or the service was renamed and this check has")
    print("      to move with it. Silence here is not health.")
    sys.exit(1)


def mounts(name):
    """The `volumes:` list of one service, as (source, target, options)."""
    out = []
    inside = False
    for line in blocks.get(name, []):
        if re.match(r"^    volumes:\s*$", line):
            inside = True
            continue
        if inside:
            if re.match(r"^    [a-z_]+:", line):
                break
            m = re.match(r"^\s*-\s+([^:\s]+):([^:\s]+)(?::(\S+))?\s*$", line)
            if m:
                out.append((m.group(1), m.group(2), m.group(3) or ""))
    return out


seal = mounts("record-seal")
if not seal:
    print("FAIL: `record-seal` declares no volumes, so this measured NOTHING.")
    sys.exit(1)

bus = [m for m in seal if m[0] == "events"]
if not bus:
    print("FAIL: `record-seal` does not mount `events`. It has no bus to read.")
    problems += 1
for source, target, opts in bus:
    if "ro" not in opts.split(","):
        print(f"FAIL: `record-seal` mounts the bus `{source}` at {target} WRITABLE.")
        print("      The record plane reads the bus and writes the record. A")
        print("      writable mount here lets the thing being recorded be edited")
        print("      by the thing recording it.")
        problems += 1

store = [m for m in seal if m[0] != "events" and "ro" not in m[2].split(",")]
if not store:
    print("FAIL: `record-seal` has no writable volume that is not the bus.")
    print("      The record would have nowhere to go but `events`.")
    problems += 1

for source, target, _ in store:
    if source == "events":
        print(f"FAIL: the record is written to the bus volume itself at {target}.")
        problems += 1
    others = [
        name
        for name in blocks
        if name != "record-seal"
        and any(s == source and "ro" not in o.split(",") for s, _, o in mounts(name))
    ]
    # init-volumes is the one legitimate other writer: it creates the directory
    # and chowns it before anything runs, and it exits before the seal starts.
    others = [n for n in others if n != "init-volumes"]
    if others:
        print(f"FAIL: `{source}` is also written by: {', '.join(sorted(others))}.")
        print("      The record store takes no cross-process lock, so a second")
        print("      writer is two minters of one shard.")
        problems += 1

if problems:
    print()
    print(f"{problems} problem(s). See CLAUDE.md, the record invariant.")
    sys.exit(1)

names = ", ".join(sorted(s for s, _, _ in store))
print(f"OK: `record-seal` reads `events` read-only and writes `{names}`,")
print("    which nothing else writes.")
PY
