#!/usr/bin/env bash
#
# Enforces: the bus has a writer, and every volume a non-root service writes
# has an owner.
#
# WHAT THIS IS ABOUT
#
# Two faults of the same shape were found by the 1.0 proving run on
# 2026-09-13, on a box every install check had passed:
#
#   1. The gateway never exported an agent event. `TOKENFUSE_EVENTS_PATH` was
#      not in its environment, tokenfuse's exporter is off without it, and the
#      file init-volumes pre-creates for idryx stayed at 0 bytes. idryx loaded
#      an empty log, heraldyx had nothing from the money plane to alert on, the
#      record sealed none of it. The half of this stack that is the point of
#      it was dead, and nothing said so.
#
#   2. Two profiles could not write their volumes. init-volumes chowned
#      /vol/records but never mounted `records`, and did nothing for
#      `scopyxevents` at all, so on a fresh box scopyx (65532) crash-looped on
#      "permission denied" and record-seal (10001) ran, read the bus and stored
#      nothing, printing "nothing sealed here to pack yet" as if the bus were
#      quiet. A fresh named volume is root:root 0755; init-volumes' own
#      comments describe the trap for the volumes it did prepare.
#
# So this holds two things about compose.yaml, both structural:
#
#   A. `tokenfuse-gateway` sets `TOKENFUSE_EVENTS_PATH`, the file sits inside a
#      volume that service mounts read-write, and every `--load tokenfuse:<path>`
#      in compose.yaml (idryx, at start and on demand) names that same file.
#      A bus with a reader and no writer is the fault above.
#
#   B. Every named volume that a service running as a non-root `user:` mounts
#      read-write is mounted by `init-volumes` and given to that uid or gid by
#      a `chown` line there. Root services are skipped: root writes anything.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway service, no init-volumes service, or no non-root service with a
# writable volume left to judge: each is reported and fails. A gate whose
# subject has been deleted must not read as a clean bill of health.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-compose.yaml}" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()

# Two-space-indented service blocks, as record-is-not-on-the-bus.sh reads them:
# compose.yaml is hand-written and a YAML library would be a dependency the box
# that runs this does not have.
blocks = {}
top_volumes = set()
section = None
current = None
for line in text.split("\n"):
    top = re.match(r"^([a-z-]+):\s*$", line)
    if top:
        section = top.group(1)
        current = None
        continue
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m:
        if section == "services":
            current = m.group(1)
            blocks[current] = []
        elif section == "volumes":
            top_volumes.add(m.group(1))
        continue
    if section == "services" and current is not None:
        blocks[current].append(line)

problems = []
def note(msg):
    problems.append(msg)
    print("FAIL: " + msg)

def field(block, key):
    for line in block:
        m = re.match(r"^\s+" + re.escape(key) + r":\s*(.+?)\s*$", line)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    return None

def volume_mounts(block):
    """(name, target, ro) for every named-volume mount under the block's volumes: key."""
    out = []
    in_volumes = False
    for line in block:
        if re.match(r"^    volumes:\s*$", line):
            in_volumes = True
            continue
        if in_volumes:
            m = re.match(r"^      - ([A-Za-z0-9_-]+):(/[^:\s]+)(?::(ro|rw))?\s*$", line)
            if m:
                out.append((m.group(1), m.group(2), m.group(3) == "ro"))
                continue
            if re.match(r"^    \S", line) or not line.strip():
                in_volumes = False
    return out

# ---- A. the bus has a writer ------------------------------------------------
gateway = blocks.get("tokenfuse-gateway")
if gateway is None:
    note("no tokenfuse-gateway service in compose.yaml: nothing to hold the bus writer on, so this gate measured nothing")
    events_path = None
else:
    events_path = field(gateway, "TOKENFUSE_EVENTS_PATH")
    if not events_path:
        note("tokenfuse-gateway sets no TOKENFUSE_EVENTS_PATH: the gateway exports no agent events, the bus has readers and no writer")
    else:
        mounts = volume_mounts(gateway)
        inside = [(n, t) for n, t, ro in mounts if not ro and events_path.startswith(t.rstrip("/") + "/")]
        if not inside:
            note(f"TOKENFUSE_EVENTS_PATH {events_path} is not inside a volume tokenfuse-gateway mounts read-write: the export lands in the container and dies with it")

loads = re.findall(r"--load\s*\n?\s*-?\s*tokenfuse:(/\S+)|tokenfuse:(/var/lib/stack/events/\S+)", text)
load_paths = sorted({a or b for a, b in loads})
if not load_paths:
    note("nothing in compose.yaml loads tokenfuse:<path>: idryx has no bus to read, so the reader half of this gate measured nothing")
elif events_path:
    for p in load_paths:
        if p != events_path:
            note(f"a service loads tokenfuse:{p} but the gateway writes {events_path}: reader and writer disagree on the file")

# ---- B. every volume a non-root service writes has an owner ----------------
init = blocks.get("init-volumes")
if init is None:
    note("no init-volumes service in compose.yaml: nothing prepares the named volumes, so this gate measured nothing")
init_mounts = {n: t for n, t, ro in (volume_mounts(init) if init else [])}
init_text = "\n".join(init or [])
judged = 0
for name, block in blocks.items():
    if name == "init-volumes":
        continue
    user = field(block, "user")
    if not user or user.startswith("0:") or user == "0":
        continue
    uid, _, gid = user.partition(":")
    for vol, target, ro in volume_mounts(block):
        if ro or vol not in top_volumes:
            continue
        judged += 1
        if vol not in init_mounts:
            note(f"{name} (user {user}) writes volume {vol} at {target}, and init-volumes never mounts it: a fresh named volume is root:root 0755, so the service cannot write")
            continue
        path = init_mounts[vol]
        owned = re.search(r"chown\s+([0-9]+):([0-9]+)\s+([^\n&]*" + re.escape(path) + r"(?=[\s&]|$))", init_text)
        if not owned:
            note(f"{name} (user {user}) writes volume {vol}, mounted by init-volumes at {path}, but no chown line there names {path}")
            continue
        cuid, cgid = owned.group(1), owned.group(2)
        if cuid != uid and cgid != gid:
            note(f"{name} runs as {user} but init-volumes gives {vol} ({path}) to {cuid}:{cgid}: neither the uid nor the gid matches")
if judged == 0:
    note("no non-root service with a writable named volume was found: the owner half of this gate measured nothing")

if problems:
    print(f"{len(problems)} problem(s)")
    sys.exit(1)
print(f"OK: the gateway exports to {events_path}, {len(load_paths)} reader(s) load the same file, and every one of {judged} writable volume mount(s) of a non-root service is prepared by init-volumes")
PY
