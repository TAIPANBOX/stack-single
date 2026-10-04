#!/usr/bin/env bash
#
# Enforces invariant 21 of CLAUDE.md: the on-box chain verifier can read every
# stream on the bus and write exactly one file on it, its own.
#
# WHAT THIS IS ABOUT
#
# Every writer on the events bus chains its lines (`prev_hash`), and until
# agent-stack-go#66 nothing on a box checked. `agent-conform watch-dir` is the
# check as a loop. Its output has to land ON the bus (heraldyx and the console
# read that directory and nothing else), so the bus volume is mounted
# read-write, and compose cannot mount one file of a named volume. That makes
# the account it runs as the whole of its containment, and an account is a
# property that fails quietly: add one `group_add: ["10001"]` and the verifier
# can write every plane's stream; give it the bus uid and the same; put its
# state file inside the bus and it reads its own memory as a stream, and an
# operator clearing the bus deletes the memory and re-sends every alert.
#
# So this holds, structurally, about compose.yaml:
#
#   1. The service exists and runs `watch-dir` with a loop (`-every`, at least
#      10s: the image is distroless, there is no shell to loop in), writes
#      `-out` to a file named agent-conform.ndjson INSIDE the bus volume it
#      mounts (the tool refuses any other name: it is the source its events
#      claim) and keeps `-state` on a DIFFERENT volume, outside the directory
#      it walks. The last argument is the bus directory.
#   2. Its account is outside the bus: numeric uid:gid, neither 0, neither of
#      the bus's own uid families (10001, 65532), the gid not the bus group
#      (10001), and no `group_add` at all. The bus directory is root:10001
#      2775 and the other planes' files are 0664 owned by 10001, so an account
#      outside group 10001 reads through the "other" bits and can write nothing
#      it does not own and create nothing.
#   3. The one file it owns is pre-created by init-volumes by name in that
#      volume, given to exactly that uid:gid, and not writable by group or
#      other; its state volume is mounted and given to it there too.
#   4. Nothing else names agent-conform.ndjson: one appender per file.
#   5. `read_only`, `cap_drop: ALL`, `no-new-privileges`, and an image pinned
#      to a released tag.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No verifier service, no init-volumes service, or no compose.yaml to read:
# each is reported and fails. Silence here is not health.
#
# NOT COVERED: that a break on a live bus is announced (the live bus is not
# here), and that the account really cannot write (install.sh asks a throwaway
# busybox run as that uid against the live volume, at the end of every run).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-compose.yaml}" <<'PY'
import os
import re
import sys

path = sys.argv[1]
if not os.path.isfile(path):
    print(f"FAIL: {path} is not there, so this gate measured NOTHING.")
    sys.exit(1)
text = open(path).read()
blocks, top_volumes, section, current = {}, set(), None, None
for line in text.split("\n"):
    top = re.match(r"^([a-z-]+):\s*$", line)
    if top:
        section, current = top.group(1), None
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
        m = re.match(r"^    " + re.escape(key) + r":\s*(.+?)\s*$", line)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    return None


def listing(block, key):
    """Items of a block-style list under `    key:` (the compose file's own style)."""
    out, on = [], False
    for line in block:
        if re.match(r"^    " + re.escape(key) + r":\s*$", line):
            on = True
            continue
        if on:
            m = re.match(r"^      - (.+?)\s*$", line)
            if m:
                out.append(m.group(1).strip().strip('"').strip("'"))
                continue
            if re.match(r"^    \S", line) or line.strip() == "":
                on = False
    return out


def volume_mounts(block):
    out = []
    for item in listing(block, "volumes"):
        m = re.match(r"^([A-Za-z0-9_-]+):(/[^:\s]+)(?::(ro|rw))?$", item)
        if m:
            out.append((m.group(1), m.group(2), m.group(3) == "ro"))
    return out


subjects = [
    n
    for n, b in blocks.items()
    if any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/agent-conform:", l) for l in b)
]
init = blocks.get("init-volumes")
if not subjects:
    print("FAIL: no service in compose.yaml runs ghcr.io/taipanbox/agent-conform, so this gate")
    print("      measured NOTHING about the chain verifier. Silence here is not health.")
    sys.exit(1)
if init is None:
    print("FAIL: no init-volumes service in compose.yaml, so nothing prepares the verifier's")
    print("      file and volume, and this gate measured nothing about them.")
    sys.exit(1)
init_text = "\n".join(init)
init_mounts = {n: t for n, t, ro in volume_mounts(init)}

BUS_GID, BUS_UIDS = "10001", {"10001", "65532"}

for name in sorted(subjects):
    b = blocks[name]
    # ---- 1. the command
    cmd = listing(b, "command")
    if not cmd or cmd[0] != "watch-dir":
        note(f"{name}: command does not begin with watch-dir ({cmd[:1]}), so it is not the chain verifier")
        continue
    flags = {}
    i = 1
    while i < len(cmd) - 1:
        if cmd[i].startswith("-") and not cmd[i + 1].startswith("-"):
            flags[cmd[i]] = cmd[i + 1]
            i += 2
        else:
            i += 1
    bus_dir = cmd[-1]
    every = flags.get("-every", "")
    m = re.match(r"^([0-9]+)(s|m|h)$", every)
    secs = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)] if m else 0
    if secs < 10:
        note(f"{name}: -every is {every or 'missing'}; the loop needs at least 10s (the image has no shell to loop in)")
    out = flags.get("-out", "")
    if os.path.basename(out) != "agent-conform.ndjson":
        note(f"{name}: -out is {out or 'missing'}; it must be a file named agent-conform.ndjson, the source its events claim")
    elif os.path.dirname(out) != bus_dir:
        note(f"{name}: -out {out} is not in the directory it verifies ({bus_dir}), so heraldyx would never read its alerts")
    state = flags.get("-state", "")
    if not state:
        note(f"{name}: no -state, so its default would put the memory beside -out, ON the bus, where the walk reads it")
    elif state.startswith(bus_dir.rstrip("/") + "/") or state.endswith(".ndjson"):
        note(f"{name}: -state {state} is inside the bus directory or looks like a stream, so it would be read as one and an operator clearing the bus would delete it")
    mounts = volume_mounts(b)
    bus_mount = [(n, t, ro) for n, t, ro in mounts if bus_dir.rstrip("/") + "/" == t.rstrip("/") + "/"]
    state_mount = [(n, t, ro) for n, t, ro in mounts if state and (state + "/").startswith(t.rstrip("/") + "/") and t.rstrip("/") != bus_dir.rstrip("/")]
    if not bus_mount:
        note(f"{name}: no volume is mounted at the bus directory {bus_dir}")
        continue
    bus_vol, bus_target, bus_ro = bus_mount[0]
    if bus_ro:
        note(f"{name}: the bus is mounted read-only, so it cannot write its own stream there")
    if not state_mount:
        note(f"{name}: -state {state} is not on a volume of its own mounted read-write")
        state_vol = None
    else:
        state_vol, state_target, state_ro = state_mount[0]
        if state_vol == bus_vol:
            note(f"{name}: its state is on the bus volume {bus_vol}")
        if state_ro:
            note(f"{name}: its state volume is mounted read-only")

    # ---- 2. the account
    user = field(b, "user") or ""
    um = re.match(r"^([0-9]+):([0-9]+)$", user)
    if not um:
        note(f"{name}: user is {user or 'unset'}; it needs a numeric uid:gid so a kubelet-style check and this gate can both read it")
        uid = gid = None
    else:
        uid, gid = um.groups()
        if uid == "0" or gid == "0":
            note(f"{name}: runs as {user}, root writes anything on the bus")
        if uid in BUS_UIDS:
            note(f"{name}: uid {uid} is one of the bus's writer uids ({', '.join(sorted(BUS_UIDS))}); it would own or share another plane's files")
        if gid == BUS_GID:
            note(f"{name}: gid {gid} is the bus group: the bus directory is group-writable and every plane's file is 0664 in that group")
    if field(b, "group_add") is not None or listing(b, "group_add"):
        note(f"{name}: has group_add, which can put it in the bus group and let it write every plane's stream")

    # ---- 5. hardening and pin
    if field(b, "read_only") != "true":
        note(f"{name}: root filesystem is not read_only")
    if "ALL" not in listing(b, "cap_drop"):
        note(f"{name}: does not cap_drop ALL")
    if "no-new-privileges:true" not in listing(b, "security_opt"):
        note(f"{name}: no no-new-privileges")
    img = field(b, "image") or ""
    if not re.search(r"ghcr\.io/taipanbox/agent-conform:v[0-9]+\.[0-9]+\.[0-9]+\}?$", img):
        note(f"{name}: image {img} is not pinned to a released vX.Y.Z tag")

    # ---- 3. init-volumes prepares exactly its file and its state volume
    if bus_vol not in init_mounts:
        note(f"init-volumes never mounts {bus_vol}, so it cannot pre-create {os.path.basename(out)}")
    else:
        d = re.escape(init_mounts[bus_vol].rstrip("/"))
        base = re.escape(os.path.basename(out) or "agent-conform.ndjson")
        creates = re.search(r":\s*>\s*" + d + "/" + base, init_text)
        chown = re.search(r"chown\s+([0-9]+):([0-9]+)\s+" + d + "/" + base, init_text)
        chmod = re.search(r"chmod\s+([0-7]{3,4})\s+" + d + "/" + base, init_text)
        if not creates:
            note(f"init-volumes does not pre-create {os.path.basename(out)}: the verifier cannot create a file in a directory it has no write access to")
        if not chown:
            note(f"init-volumes does not chown {os.path.basename(out)}: the verifier could not append to it")
        elif uid is not None and (chown.group(1), chown.group(2)) != (uid, gid):
            note(f"init-volumes gives {os.path.basename(out)} to {chown.group(1)}:{chown.group(2)} but the verifier runs as {user}")
        if not chmod:
            note(f"init-volumes sets no mode on {os.path.basename(out)}")
        elif int(chmod.group(1)[-2:], 8) & 0o22:
            note(f"init-volumes makes {os.path.basename(out)} {chmod.group(1)}: writable by group or other, so another plane could append in the verifier's name")
    if state_vol:
        if state_vol not in init_mounts:
            note(f"init-volumes never mounts {state_vol}, so a fresh named volume (root:root 0755) is one the verifier cannot write its state to")
        else:
            d = re.escape(init_mounts[state_vol].rstrip("/"))
            chown = re.search(r"chown\s+([0-9]+):([0-9]+)\s+" + d + r"(?=[\s&]|$)", init_text)
            if not chown:
                note(f"init-volumes does not chown {init_mounts[state_vol]}, the verifier's state volume")
            elif uid is not None and (chown.group(1), chown.group(2)) != (uid, gid):
                note(f"init-volumes gives {init_mounts[state_vol]} to {chown.group(1)}:{chown.group(2)} but the verifier runs as {user}")

    # ---- 4. one appender per file
    for other, ob in blocks.items():
        if other in (name, "init-volumes"):
            continue
        for l in ob:
            if "agent-conform.ndjson" in l and not l.lstrip().startswith("#"):
                note(f"{other} names agent-conform.ndjson ({l.strip()}): two appenders on one file with no lock, and the verifier's own stream would no longer be its own")

if problems:
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 21.")
    sys.exit(1)
print(f"OK: {', '.join(sorted(subjects))} runs watch-dir in a loop as an account outside the bus group with no group_add,")
print("    owns the one file init-volumes pre-created for it (not group- or other-writable), keeps its")
print("    state on a volume of its own, and nothing else names its stream.")
PY
