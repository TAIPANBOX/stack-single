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
#   A. Each money-plane writer, every gateway and `tokenfuse-cloud`, sets
#      `TOKENFUSE_EVENTS_PATH`, the file sits inside a volume that service
#      mounts read-write, no two name the same file (one bus file, two
#      appenders, no lock: two gateways on one chained file fork its chain), and
#      `init-volumes` pre-creates each file by name in that volume, since no
#      tokenfuse uid can. The gateways are derived from compose.yaml's own image
#      and command lines (the tokenfuse gateway image, no subcommand), so the
#      OpenAI door (`tokenfuse-gateway-openai`, CLAUDE.md invariant 32) is judged
#      like the first without being named here. Every `--load tokenfuse:<path>`
#      in compose.yaml (idryx, at start and on demand) names a file some gateway
#      writes, and every service that loads the gateways' log loads each
#      gateway's file: a door whose events nobody reads is the fault above.
#
#   B. Every named volume that a service running as a non-root `user:` mounts
#      read-write is mounted by `init-volumes` and given to that uid or gid by
#      a `chown` line there. Root services are skipped: root writes anything.
#      A `<name>-init` one-shot (costcrew-init, the optional FinOps console's)
#      counts as a preparer too, so an add-on need not edit init-volumes.
#
# typryx (profile typed) joined the same bus 2026-09-26, once agent-passport
# registered its four event types: it names its own file, TYPRYX_EVENTS, so
# the writer table below carries a var name per service rather than assuming
# TOKENFUSE_EVENTS_PATH for everyone. That does not mean record-seal SEALS
# typryx's events. Trailryx 1.0 refused the four (agent-event v1.0 is a schema it does not
# read); trailryx 1.4.0 reads that schema, and what the record plane does with them is open.
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
# The one-shot preparers: init-volumes, and a `<name>-init` an OPTIONAL add-on
# brings for its own volumes (costcrew-init, profile finops). An add-on may not
# edit init-volumes, which every install runs, so it prepares what it writes
# itself, and this gate reads that preparer the same way: a volume or a bus
# file counts as prepared if init-volumes or such a one-shot mounts and owns it.
preparers = [n for n in blocks if n == "init-volumes" or n.endswith("-init")]
init_mounts = {}
for pn in preparers:
    for n, t, ro in volume_mounts(blocks[pn]):
        init_mounts.setdefault(n, t)
init_text = "\n".join("\n".join(blocks[pn]) for pn in preparers)


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
# consequence rather than assuming one name for every writer. The gateways are
# not named: every service that runs the tokenfuse gateway image with no
# subcommand is one, read from its own image and command lines.
def is_gateway(block):
    image = any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/tokenfuse:", l) for l in block)
    bare = any(re.match(r'^\s*command:\s*\["/usr/local/bin/tokenfuse"\]\s*$', l) for l in block)
    return image and bare


gateways = sorted(n for n, b in blocks.items() if is_gateway(b))
if "tokenfuse-gateway" not in gateways:
    note("no tokenfuse-gateway service runs the gateway image with no subcommand: nothing to hold the bus writer on, so this gate measured nothing")
WRITERS = {
    g: ("TOKENFUSE_EVENTS_PATH", f"{g} exports no agent events, so the bus has readers and no writer for it")
    for g in gateways
}
WRITERS.update({
    "tokenfuse-cloud": ("TOKENFUSE_EVENTS_PATH", "the control plane's incidents (a budget gone, a sustained loop) never leave /v1/incidents for the notifier, the identity plane or the record"),
    "typryx": ("TYPRYX_EVENTS", "typryx's typed_answer, typed_unanswered, typed_refused and calibration_drift events never reach heraldyx or the record"),
})
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
seen_paths = {}
for name, path in sorted(written.items()):
    if path in seen_paths:
        note(f"{seen_paths[path]} and {name} name the same events path {path}: two appenders on one file with no lock, and two gateways on one chained file fork its chain")
    seen_paths.setdefault(path, name)
gateway_files = {written[g] for g in gateways if g in written}

# Per reader, from its own block with comments dropped: the files it loads as tokenfuse.
load_re = re.compile(r"--load\s*\n?\s*-?\s*tokenfuse:(/\S+)|tokenfuse:(/var/lib/stack/events/\S+)")
readers = {}
for name, block in blocks.items():
    code = "\n".join(l for l in block if not l.lstrip().startswith("#"))
    found = {a or b for a, b in load_re.findall(code)}
    if found:
        readers[name] = found
load_paths = sorted(set().union(*readers.values())) if readers else []
if not load_paths:
    note("nothing in compose.yaml loads tokenfuse:<path>: idryx has no bus to read, so the reader half of this gate measured nothing")
else:
    for name, found in sorted(readers.items()):
        for p in sorted(found - gateway_files):
            note(f"{name} loads tokenfuse:{p} and no gateway writes it (they write {', '.join(sorted(gateway_files)) or 'nothing'}): reader and writer disagree on the file")
        for p in sorted(gateway_files - found):
            note(f"{name} does not load tokenfuse:{p}, which a gateway writes: that gateway's agents never reach the identity graph")

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
        # 1.4.0: a re-own is recursive (`chown -R`), and a user-only re-own names no group (keyryx).
        owned = re.search(r"chown\s+(?:-R\s+)?([0-9]+)(?::([0-9]+))?\s+([^\n&]*" + re.escape(path) + r"(?=[\s&]|$))", init_text)
        if not owned:
            note(f"{name} (user {user}) writes volume {vol}, mounted by init-volumes at {path}, but no chown line there names {path}")
            continue
        cuid, cgid = owned.group(1), (owned.group(2) or gid)
        if cuid != uid and cgid != gid:
            # A shared bus volume can also be written through ONE FILE a
            # service owns: init-volumes pre-creates it and chowns it to that
            # service's uid, and the directory stays someone else's. That is
            # how the chain verifier (agent-conform) is held to writing its own
            # stream and nothing else, so a file chowned to this uid under the
            # volume's path counts as an owner. `chain-verifier-is-contained.sh`
            # holds the rest of that shape.
            if re.search(r"chown\s+(?:-R\s+)?" + re.escape(uid) + r"(?::[0-9]+)?\s+\"?" + re.escape(path.rstrip("/")) + r"/\S", init_text):
                continue
            note(f"{name} runs as {user} but init-volumes gives {vol} ({path}) to {cuid}:{cgid}: neither the uid nor the gid matches, and no file under it is given to {uid}")
if judged == 0:
    note("no non-root service with a writable named volume was found: the owner half of this gate measured nothing")

if problems:
    print(f"{len(problems)} problem(s)")
    sys.exit(1)
gw_said = ", ".join(f"{g} to {written[g]}" for g in gateways if g in written)
print(f"OK: {len(gateways)} gateway(s) export ({gw_said}), the control plane to {written.get('tokenfuse-cloud')}, and typryx to {written.get('typryx')}, every one pre-created by init-volumes; {len(readers)} reader(s) load every gateway's file and nothing else as tokenfuse, and every one of {judged} writable volume mount(s) of a non-root service is prepared by init-volumes")
PY
