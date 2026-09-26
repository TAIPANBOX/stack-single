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
#   3. (2026-09-17, #57) The control plane wrote nothing either. It had no
#      `TOKENFUSE_EVENTS_PATH`, and even with one it could not have created the
#      file: the tokenfuse images run as uid 10001 with gid 999 against an
#      `events` directory that is root:10001 2775, and the exporter swallows
#      the open error. So budget_exhausted (critical), sustained_loop and the
#      other Cloud detectors stayed inside /v1/incidents and the console,
#      invisible to heraldyx, idryx and record-seal, on every install.
#
# So this holds two things about compose.yaml, both structural:
#
#   A. Each money-plane writer, `tokenfuse-gateway` and `tokenfuse-cloud`, sets
#      `TOKENFUSE_EVENTS_PATH`, the file sits inside a volume that service
#      mounts read-write, the two name different files (one bus file, two
#      appenders, no lock), and `init-volumes` pre-creates each file by name
#      in that volume, since neither uid can. Every `--load tokenfuse:<path>`
#      in compose.yaml (idryx, at start and on demand) names the gateway's
#      file. A bus with a reader and no writer is the fault above.
#
#   B. Every named volume that a service running as a non-root `user:` mounts
#      read-write is mounted by `init-volumes` and given to that uid or gid by
#      a `chown` line there. Root services are skipped: root writes anything.
#
# typryx (profile typed) joined the same bus 2026-09-26, once agent-passport
# registered its four event types: it names its own file, TYPRYX_EVENTS, so
# the writer table below carries a var name per service rather than assuming
# TOKENFUSE_EVENTS_PATH for everyone. That does not mean record-seal SEALS
# typryx's events: it counts all four refused (agent-event v1.0 is a schema
# trailryx 1.0 does not read, and its mapper refuses the four by name on
# purpose, trailryx#81).
# What moving the journal here buys is heraldyx alerting on them, since
# heraldyx reads the whole directory.
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
init = blocks.get("init-volumes")
init_mounts = {n: t for n, t, ro in (volume_mounts(init) if init else [])}
init_text = "\n".join(init or [])


def precreated(dirpath):
    """File names init-volumes creates under dirpath: the items of every
    `for f in ...; do` loop whose body writes `dirpath/$$f`, plus any direct
    `: > dirpath/<name>`. compose doubles the `$`, so `$$f` is what the text
    holds."""
    names = set()
    d = re.escape(dirpath.rstrip("/"))
    for m in re.finditer(r"for\s+(\w+)\s+in\s+([^;\n]+);\s*do(.*?)\bdone\b", init_text, re.S):
        var, items, body = m.groups()
        if re.search(d + r'/"?\$\$?\{?' + re.escape(var) + r"\b", body):
            names.update(items.split())
    for m in re.finditer(r":\s*>\s*\"?" + d + r"/([A-Za-z0-9._-]+)", init_text):
        names.add(m.group(1))
    return names


# Each writer's own env var name differs (typryx and the broker do not read
# TOKENFUSE_EVENTS_PATH), so the table carries the var name beside the
# consequence rather than assuming one name for every writer.
WRITERS = {
    "tokenfuse-gateway": ("TOKENFUSE_EVENTS_PATH", "the gateway exports no agent events, the bus has readers and no writer"),
    "tokenfuse-cloud": ("TOKENFUSE_EVENTS_PATH", "the control plane's incidents (a budget gone, a sustained loop) never leave /v1/incidents for the notifier, the identity plane or the record"),
    "typryx": ("TYPRYX_EVENTS", "typryx's typed_answer, typed_unanswered, typed_refused and calibration_drift events never reach heraldyx or the record"),
}
written = {}
for name, (envvar, consequence) in WRITERS.items():
    svc = blocks.get(name)
    if svc is None:
        note(f"no {name} service in compose.yaml: nothing to hold the bus writer on, so this gate measured nothing")
        continue
    path = field(svc, envvar)
    if not path:
        note(f"{name} sets no {envvar}: {consequence}")
        continue
    written[name] = path
    inside = [(n, t) for n, t, ro in volume_mounts(svc) if not ro and path.startswith(t.rstrip("/") + "/")]
    if not inside:
        note(f"{envvar} {path} is not inside a volume {name} mounts read-write: the export lands in the container and dies with it")
        continue
    vol, target = inside[0]
    if vol not in init_mounts:
        note(f"{name} writes {path} on volume {vol}, and init-volumes never mounts it: nothing can pre-create the file, and uid 10001 with gid 999 cannot")
        continue
    base = path[len(target.rstrip("/")) + 1:]
    if base not in precreated(init_mounts[vol]):
        note(f"init-volumes does not pre-create {base} in {init_mounts[vol]}: {name} may not be able to create it there, and {consequence.split(',')[0]}")
if len(set(written.values())) < len(written):
    note("two writers name the same events path: two appenders on one file with no lock")
events_path = written.get("tokenfuse-gateway")

loads = re.findall(r"--load\s*\n?\s*-?\s*tokenfuse:(/\S+)|tokenfuse:(/var/lib/stack/events/\S+)", text)
load_paths = sorted({a or b for a, b in loads})
if not load_paths:
    note("nothing in compose.yaml loads tokenfuse:<path>: idryx has no bus to read, so the reader half of this gate measured nothing")
elif events_path:
    for p in load_paths:
        if p != events_path:
            note(f"a service loads tokenfuse:{p} but the gateway writes {events_path}: reader and writer disagree on the file")

# ---- B. every volume a non-root service writes has an owner ----------------
if init is None:
    note("no init-volumes service in compose.yaml: nothing prepares the named volumes, so this gate measured nothing")
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
print(f"OK: the gateway exports to {events_path}, the control plane to {written.get('tokenfuse-cloud')}, and typryx to {written.get('typryx')}, every one pre-created by init-volumes; {len(load_paths)} reader(s) load the gateway's file, and every one of {judged} writable volume mount(s) of a non-root service is prepared by init-volumes")
PY
