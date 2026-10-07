#!/usr/bin/env bash
#
# Enforces invariant 24 of CLAUDE.md: the FinOps console (CostCrew) is an
# optional add-on that leaves the core unchanged, cannot spend as shipped, and
# can write exactly one file on the bus.
#
# WHAT THIS IS ABOUT
#
# `costcrew` and its one-shot `costcrew-init` sit behind the `finops` profile.
# An operator turns the console on by hand, `docker compose --profile finops up
# -d costcrew`; no install does. Three things about that are quiet when wrong,
# and a profile line alone holds none of them:
#
#   THE CORE STAYS THE CORE. An add-on is the easy excuse to touch something
#   every install runs: one `costcrewdata` mount in init-volumes, one
#   `depends_on`, one flag in install.sh. Each works, and each changes a box
#   that never asked for the add-on. So this requires that nothing outside the
#   add-on's two services names it, in compose.yaml or in install.sh, and that
#   a default and a `--profile finops` rendering of compose.yaml differ by
#   exactly those two services and their volume.
#
#   IT CANNOT SPEND AS SHIPPED. The console's planning calls go through a
#   gateway it is told about with `-gateway` (or `COSTCREW_GATEWAY`), and
#   without one its own startup line says it cannot spend at all. Wiring that
#   to this box's gateway is a spending decision the operator takes, so no flag
#   or variable here names a gateway, and the crew runner in the same image is
#   not started.
#
#   ITS ACCOUNT IS ITS CONTAINMENT. The bus is mounted read-write because its
#   stream has to be on the bus for the notifier to read, and compose cannot
#   mount one file of a volume. So it runs as a uid of its own (10003), outside
#   both uid families of the bus and outside the bus group, with no group_add;
#   the bus directory is root:10001 2775, so it can create nothing there and can
#   write the one file costcrew-init made for it. That file is 0644: the chain
#   verifier reads it through the "other" bits, and a stream it could not read
#   would make the verifier exit and restart on every box that enabled this.
#
# WHAT THIS CHECKS
#
#   A. compose.yaml, by text: the two services are in profile finops and only
#      that; nothing else names them; nothing depends on them; no gateway; the
#      stream is `costcrew.ndjson` inside a bus volume mounted read-write;
#      passports and owner come as a pair; the host is RECORD_TRUST_DOMAIN; the
#      account, the hardening, the
#      pin; every published port is a literal loopback address; the one-shot
#      creates the stream (0644, the console's uid) and owns the data volume.
#   B. install.sh, by text: no non-comment line names the add-on at all.
#   C. the rendering, with Docker: the default has neither service nor volume;
#      `--profile finops` has both, published on 127.0.0.1 only.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No costcrew service, no one-shot, no install.sh, no compose.yaml, or no Docker:
# each is reported and fails. Silence here is not health.
#
# NOT COVERED: that the console starts and serves (a scratch compose project did,
# recorded in the pull request, and install.sh does not run it), and that
# anything on this box ever reads the passports it writes.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-compose.yaml}" "${2:-install.sh}" <<'PY'
import os
import re
import sys

cpath, ipath = sys.argv[1:3]
for p in (cpath, ipath):
    if not os.path.isfile(p):
        print(f"FAIL: {p} is not there, so this gate measured NOTHING.")
        sys.exit(1)
text = open(cpath).read()
install = open(ipath).read()

blocks, section, current = {}, None, None
for line in text.split("\n"):
    top = re.match(r"^([a-z-]+):\s*$", line)
    if top:
        section, current = top.group(1), None
        continue
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m and section == "services":
        current = m.group(1)
        blocks[current] = []
        continue
    if section == "services" and current is not None:
        blocks[current].append(line)

problems = []


def note(msg):
    problems.append(msg)
    print("FAIL: " + msg)


def code(block):
    return [l for l in block if not l.lstrip().startswith("#")]


def field(block, key):
    for line in block:
        m = re.match(r"^    " + re.escape(key) + r":\s*(.+?)\s*$", line)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    return None


def listing(block, key):
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


def depends(block):
    """service name -> condition, for the block-style depends_on."""
    out, on, cur = {}, False, None
    for line in block:
        if re.match(r"^    depends_on:\s*$", line):
            on = True
            continue
        if on:
            m = re.match(r"^      ([a-z0-9-]+):\s*$", line)
            if m:
                cur = m.group(1)
                out[cur] = None
                continue
            m = re.match(r"^        condition:\s*(\S+)", line)
            if m and cur:
                out[cur] = m.group(1)
                continue
            if re.match(r"^    \S", line):
                on = False
    return out


# ---- subjects, derived from the image and from what the console waits for -----
subjects = [
    n
    for n, b in blocks.items()
    if any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/costcrew:", l) for l in b)
]
if not subjects:
    print("FAIL: no service in compose.yaml runs ghcr.io/taipanbox/costcrew, so this gate")
    print("      measured NOTHING about the FinOps console. Silence here is not health.")
    sys.exit(1)
inits = sorted({d for n in subjects for d in depends(blocks[n]) if d != "init-volumes"})
if not inits or any(i not in blocks for i in inits):
    print("FAIL: the FinOps console waits for no one-shot of its own (costcrew-init), so nothing prepares")
    print("      its volume and its stream, and this gate measured NOTHING about them.")
    sys.exit(1)
addon = set(subjects) | set(inits)
if blocks.get("init-volumes") is None:
    print("FAIL: no init-volumes service in compose.yaml, so this gate cannot tell what the core is.")
    sys.exit(1)

# ---- A1. both in profile finops, and in nothing else -------------------------
for n in sorted(addon):
    prof = re.search(r"^    profiles:\s*(\[.*?\])\s*$", "\n".join(blocks[n]), re.M)
    if not prof or prof.group(1).replace(" ", "") != '["finops"]':
        note(f'{n} is not behind `profiles: ["finops"]` (found {prof.group(1) if prof else "none"}): '
             "a plain `docker compose up` would start it on every box")

# ---- A2. the core never names the add-on -------------------------------------
for n, b in sorted(blocks.items()):
    if n in addon:
        continue
    for l in code(b):
        if re.search(r"costcrew", l, re.I):
            note(f"{n} names the add-on ({l.strip()!r}): an optional add-on leaves the core unchanged, "
                 "and a box that never enables it must run what it ran without it")

# ---- A3. no gateway, so it cannot spend --------------------------------------
for n in sorted(subjects):
    b = code(blocks[n])
    for l in b:
        if re.search(r"-gateway|COSTCREW_GATEWAY", l):
            note(f"{n} names a gateway ({l.strip()!r}): the console would be able to spend. "
                 "That is the operator's decision, taken separately, never a shipped default")

# ---- per subject ----------------------------------------------------------------
BUS_GID, BUS_UIDS = "10001", {"10001", "65532", "10002"}
for n in sorted(subjects):
    b = blocks[n]
    cmd = listing(b, "command")
    flags = {}
    i = 0
    while i < len(cmd) - 1:
        if cmd[i].startswith("-") and not cmd[i + 1].startswith("-"):
            flags[cmd[i]] = cmd[i + 1]
            i += 2
        else:
            i += 1
    mounts = volume_mounts(b)

    # the stream
    ev = flags.get("-stack-events", "")
    if os.path.basename(ev) != "costcrew.ndjson":
        note(f"{n}: -stack-events is {ev or 'missing'}; the file must be named costcrew.ndjson, "
             "because genaryx keys its read offset off the stem and a stream under any other name is never read")
        bus_mount = None
    else:
        bus_mount = [(v, t, ro) for v, t, ro in mounts if ev.startswith(t.rstrip("/") + "/")]
        if not bus_mount:
            note(f"{n}: {ev} is not inside a volume the console mounts, so it lands in the container and dies with it")
            bus_mount = None
        elif bus_mount[0][2]:
            note(f"{n}: the volume holding {ev} is mounted read-only, so it cannot append there")
    # the pair
    if ("-stack-passports" in flags) != ("-stack-owner" in flags):
        note(f"{n}: -stack-passports and -stack-owner come as a pair and only one is given: "
             "the console refuses to start with passports and no owner")
    elif "-stack-passports" not in flags:
        note(f"{n}: no -stack-passports and no -stack-owner: its agents would name nobody who answers for them")
    elif not flags.get("-stack-owner"):
        note(f"{n}: -stack-owner has no value expression")
    if "RECORD_TRUST_DOMAIN" not in flags.get("-stack-host", ""):
        note(f"{n}: -stack-host is {flags.get('-stack-host') or 'missing'}, not RECORD_TRUST_DOMAIN: "
             "trailryx takes events of exactly one trust domain, the one the record plane is given, "
             "and a console under another would have every line it emits counted foreign by the seal")
    # the data volume
    data = flags.get("-data", "")
    dmount = [(v, t, ro) for v, t, ro in mounts if data and (data + "/").startswith(t.rstrip("/") + "/")]
    data_vol = None
    if not data or not dmount:
        note(f"{n}: -data {data or 'missing'} is not on a mounted volume")
    else:
        data_vol = dmount[0][0]
        if dmount[0][2]:
            note(f"{n}: its data volume is mounted read-only")
        if bus_mount and data_vol == bus_mount[0][0]:
            note(f"{n}: its data is on the bus volume {data_vol}; a database inside the directory every plane reads is read as a stream")
        pp = flags.get("-stack-passports", "")
        if pp and not (pp + "/").startswith(data.rstrip("/") + "/"):
            note(f"{n}: passports go to {pp}, outside its data volume, so they are lost when the container is recreated")

    # the account
    user = field(b, "user") or ""
    um = re.match(r"^([0-9]+):([0-9]+)$", user)
    uid = gid = None
    if not um:
        note(f"{n}: user is {user or 'unset'}; it needs a numeric uid:gid")
    else:
        uid, gid = um.groups()
        if uid == "0" or gid == "0":
            note(f"{n}: runs as {user}; root writes anything on the bus")
        if uid in BUS_UIDS:
            note(f"{n}: uid {uid} belongs to a plane that writes the bus ({', '.join(sorted(BUS_UIDS))}); "
                 "it would be able to write that plane's files")
        if gid == BUS_GID:
            note(f"{n}: gid {gid} is the bus group: the directory is group-writable and every plane's file is 0664 in that group")
    if field(b, "group_add") is not None or listing(b, "group_add"):
        note(f"{n}: has group_add, which can put it in the bus group")
    if field(b, "read_only") != "true":
        note(f"{n}: root filesystem is not read_only")
    if "ALL" not in listing(b, "cap_drop"):
        note(f"{n}: does not cap_drop ALL")
    if "no-new-privileges:true" not in listing(b, "security_opt"):
        note(f"{n}: no no-new-privileges")
    img = field(b, "image") or ""
    if not re.search(r"\$\{COSTCREW_IMAGE:-ghcr\.io/taipanbox/costcrew:v[0-9]+\.[0-9]+\.[0-9]+\}$", img):
        note(f"{n}: image {img} is not the pinned `${{COSTCREW_IMAGE:-ghcr.io/taipanbox/costcrew:vX.Y.Z}}` form")

    # published ports: loopback, written as a literal
    for item in listing(b, "ports"):
        if not re.match(r'^127\.0\.0\.1:[0-9]+:[0-9]+$', item):
            note(f"{n}: publishes {item!r}; the console is reached on loopback only (a literal 127.0.0.1), "
                 "because nothing in front of it terminates TLS or authenticates before it")

    # the one-shot prepares exactly its stream and its volume
    init_name = [d for d in depends(b) if d in inits]
    if not init_name:
        note(f"{n}: does not wait for its one-shot")
        continue
    cond = depends(b)[init_name[0]]
    if cond != "service_completed_successfully":
        note(f"{n}: waits for {init_name[0]} with condition {cond}, not service_completed_successfully")
    ib = blocks[init_name[0]]
    itext = "\n".join(ib)
    if (field(ib, "user") or "") not in ("0:0", "0"):
        note(f"{init_name[0]}: does not run as root, so it cannot give a file to another uid")
    if field(ib, "restart") != "no":
        note(f'{init_name[0]}: is not `restart: "no"`, so a one-shot would be started again and again')
    if depends(ib).get("init-volumes") != "service_completed_successfully":
        note(f"{init_name[0]}: does not wait for init-volumes, so the bus directory may not be prepared yet")
    imounts = {v: t for v, t, ro in volume_mounts(ib)}
    if bus_mount:
        bv = bus_mount[0][0]
        if bv not in imounts:
            note(f"{init_name[0]} never mounts {bv}, so it cannot create the console's stream")
        else:
            d = re.escape(imounts[bv].rstrip("/"))
            base = re.escape(os.path.basename(ev))
            if not re.search(r":\s*>\s*" + d + "/" + base, itext):
                note(f"{init_name[0]} does not create {os.path.basename(ev)}: the console cannot create a file in a directory it has no write access to")
            chown = re.search(r"chown\s+([0-9]+):([0-9]+)\s+" + d + "/" + base, itext)
            if not chown:
                note(f"{init_name[0]} does not chown {os.path.basename(ev)}, so the console could not append to it")
            elif uid is not None and (chown.group(1), chown.group(2)) != (uid, gid):
                note(f"{init_name[0]} gives {os.path.basename(ev)} to {chown.group(1)}:{chown.group(2)} but the console runs as {user}")
            chmod = re.search(r"chmod\s+([0-7]{3,4})\s+" + d + "/" + base, itext)
            if not chmod:
                note(f"{init_name[0]} sets no mode on {os.path.basename(ev)}")
            else:
                mode = int(chmod.group(1)[-3:], 8)
                if mode & 0o022:
                    note(f"{init_name[0]} makes {os.path.basename(ev)} {chmod.group(1)}: writable by group or other, so another plane could append in the console's name")
                if not mode & 0o004:
                    note(f"{init_name[0]} makes {os.path.basename(ev)} {chmod.group(1)}: not readable by other, so the chain verifier (outside the bus group) "
                         "could not read it and would exit and restart on every box that enabled this")
    if data_vol:
        if data_vol not in imounts:
            note(f"{init_name[0]} never mounts {data_vol}, so a fresh named volume (root:root 0755) is one the console cannot write")
        else:
            d = re.escape(imounts[data_vol].rstrip("/"))
            chown = re.search(r"chown\s+([0-9]+):([0-9]+)\s+" + d + r"(?=[\s&]|$)", itext)
            if not chown:
                note(f"{init_name[0]} does not chown {imounts[data_vol]}, the console's data volume")
            elif uid is not None and (chown.group(1), chown.group(2)) != (uid, gid):
                note(f"{init_name[0]} gives {imounts[data_vol]} to {chown.group(1)}:{chown.group(2)} but the console runs as {user}")

# ---- B. install.sh does not know it exists -----------------------------------
code_lines = [(i + 1, l.split("#", 1)[0]) for i, l in enumerate(install.split("\n"))]
for no, l in code_lines:
    # `finops` as the profile's own lowercase word: install.sh's closing report
    # says "FinOps export" about stack-up's routine, which is not this.
    if re.search(r"(?i:costcrew)|\bfinops\b", l):
        note(f"install.sh:{no} names the add-on ({l.strip()!r}): an install must not know about it, "
             "so that it cannot start it")

if problems:
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 24.")
    sys.exit(1)
print("compose.yaml and install.sh, by text: " + ", ".join(sorted(addon)) + " sit behind profile finops alone,")
print("    nothing else names them, no gateway is named, the stream is costcrew.ndjson in the bus,")
print("    and install.sh does not mention them.")
PY

# ---- C. the rendering ---------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  echo "FAIL: no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
  exit 1
fi
cdir="$(mktemp -d)"
trap 'rm -rf "$cdir"' EXIT
cp "${1:-compose.yaml}" "$cdir/compose.yaml"
mkdir -p "$cdir/typed" "$cdir/delegation-public" "$cdir/environments" "$cdir/delegation"
: >"$cdir/policy.yaml"
grep -o '\${[A-Z_]*:?' "${1:-compose.yaml}" | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/.env"
render() { docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" "$@" config --format json; }
if ! default="$(render 2>"$cdir/err")"; then
  echo "FAIL: docker compose config failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
  exit 1
fi
if ! withp="$(render --profile finops 2>"$cdir/err")"; then
  echo "FAIL: docker compose --profile finops config failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
  exit 1
fi
DEFAULT="$default" WITHP="$withp" python3 - <<'PY'
import json
import os
import sys

d = json.loads(os.environ["DEFAULT"])
w = json.loads(os.environ["WITHP"])
ds, ws = set(d["services"]), set(w["services"])
addon = {s for s in ws if "costcrew" in s}
bad = []
if not addon:
    print("FAIL: --profile finops renders no costcrew service, so the rendering half measured NOTHING.")
    sys.exit(1)
if {s for s in ds if "costcrew" in s}:
    bad.append("the default rendering contains " + ", ".join(sorted(s for s in ds if "costcrew" in s)) + ": a plain `docker compose up` would start it")
if "costcrewdata" in d.get("volumes", {}):
    bad.append("the default rendering lists the costcrewdata volume: a box that never enabled the add-on would create it")
if ws - addon != ds:
    bad.append("the profile changes more than the add-on: " + ", ".join(sorted((ws - addon) ^ ds)))
for s in sorted(addon):
    for p in w["services"][s].get("ports", []):
        if p.get("host_ip") != "127.0.0.1":
            bad.append(f"{s} publishes {p.get('published')} on {p.get('host_ip') or 'every address'}, not on loopback only")
# the core services themselves must render the same with and without the profile
for s in sorted(ds):
    if d["services"][s] != w["services"][s]:
        bad.append(f"{s} renders differently with --profile finops: the add-on reached into the core")
if bad:
    for b in bad:
        print("FAIL: " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 24.")
    sys.exit(1)
print(f"    rendered: the default has {len(ds)} services and none of {', '.join(sorted(addon))}; --profile finops adds exactly those,")
print("    changes none of the others, and publishes them on loopback only.")
print("OK: the FinOps console is an optional add-on that leaves the core unchanged. See CLAUDE.md invariant 24.")
PY
