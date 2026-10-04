#!/usr/bin/env bash
#
# Enforces invariant 23 of CLAUDE.md: every stream file this launcher puts on
# the bus is named so that heraldyx and idryx accept the source its lines claim.
#
# WHAT THIS IS ABOUT
#
# heraldyx 0.3.0 and idryx 1.1.0 refuse an event whose `source` is not allowed
# for the FILE it was read from (bus layer 2, heraldyx#85 and idryx#91). The
# default is `<source>.ndjson` carries `<source>` for fourteen registered
# sources, plus `tokenfuse-cloud.ndjson` and `tokenfuse-mcp.ndjson` carrying
# `tokenfuse`. A line in any other file is counted, named once and never
# processed as that plane. Nothing fails loudly: a writer whose file name does
# not match is a plane whose alerts stop arriving, on a box where every check is
# green, which is the shape of the 2026-09-13 bus faults.
#
# So this derives, from compose.yaml, every file this launcher writes to the
# bus and every file a reader is told to load, and requires each one to match:
#
#   - every service's events path (`*_EVENTS`, `*_EVENTS_PATH` under the bus
#     directory, wardryx's `-events`, the chain verifier's `-out`): the file's
#     stem, with the source that service's image claims, is an allowed pair;
#   - every `--load <source>:<path>` (idryx at start and on demand): the same;
#   - every file init-volumes pre-creates on the bus: its stem is allowed
#     for some source, so no file sits there that a reader would call unknown;
#   - nothing sets HERALDYX_STREAMS or IDRYX_STREAMS. The preferred repair for
#     a mismatch is to rename the file, and a declaration widens what a box
#     accepts from a co-tenant of the bus directory (heraldyx's own note).
#
# The allowed table below is a COPY of the one heraldyx 0.3.0 and idryx 1.1.0
# each carry (`internal/stream/stream.go` and idryx's own); nothing holds the
# three equal. The claimed source per image is read from each producer's own
# constant (tokenfuse `agent_event.rs` SOURCE, wardryx `api.go`, typryx
# `record.go`, vouchryx `api.go`, agent-conform `watchdir.go`), which this gate
# cannot see, so it is a table here too.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No bus file found, no `--load` found, or no compose.yaml: each fails.
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

# What heraldyx 0.3.0 and idryx 1.1.0 allow by default.
KNOWN = {
    "agent-conform", "console", "costcrew", "engram", "heraldyx", "idryx",
    "mockryx", "qryx", "scopyx", "tokenfuse", "typryx", "vouchryx", "verdryx",
    "wardryx",
}
ALLOWED = {s: {s} for s in KNOWN}
ALLOWED["tokenfuse-cloud"] = {"tokenfuse"}
ALLOWED["tokenfuse-mcp"] = {"tokenfuse"}

# The source each image's lines claim.
CLAIMS = {
    "tokenfuse": "tokenfuse",
    "tokenfuse-control-plane": "tokenfuse",
    "wardryx": "wardryx",
    "typryx": "typryx",
    "vouchryx": "vouchryx",
    "agent-conform": "agent-conform",
}

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

BUS = "/var/lib/stack/events/"
problems = []


def note(msg):
    problems.append(msg)
    print("FAIL: " + msg)


def image_repo(block):
    for l in block:
        m = re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/([a-z-]+):", l)
        if m:
            return m.group(1)
    return None


def bus_files(block):
    """Files a service writes on the bus: (path, how)."""
    out = []
    for l in block:
        if l.lstrip().startswith("#"):
            continue
        m = re.match(r"^\s*([A-Z_]*EVENTS(?:_PATH)?):\s*(\S+)\s*$", l)
        if m and m.group(2).startswith(BUS):
            out.append((m.group(2), m.group(1)))
        m = re.match(r"^\s*- (" + re.escape(BUS) + r"\S+\.ndjson)\s*$", l)
        if m:
            out.append((m.group(1), "a command argument"))
    return out


rows = []
for name in sorted(blocks):
    block = blocks[name]
    repo = image_repo(block)
    for fpath, how in bus_files(block):
        stem = os.path.basename(fpath)[: -len(".ndjson")] if fpath.endswith(".ndjson") else os.path.basename(fpath)
        # idryx and heraldyx READ their bus; only a producer's own image claims a source.
        claim = CLAIMS.get(repo or "")
        if claim is None:
            continue
        rows.append((name, os.path.basename(fpath), claim, "writes"))
        if stem not in ALLOWED:
            note(f"{name} writes {os.path.basename(fpath)} (via {how}): `{stem}` is not a stream name heraldyx 0.3.0 or idryx 1.1.0 know, so its lines are an unknown stream there and a line claiming any other source is refused")
        elif claim not in ALLOWED[stem]:
            note(f"{name} writes {os.path.basename(fpath)} claiming source `{claim}`, and that file may carry only {sorted(ALLOWED[stem])}: heraldyx and idryx refuse every line of it")

# every reader --load
load_re = re.compile(r"(?:--load\s*\n\s*-\s*|--load\s+|^\s*- )([a-z-]+):(" + re.escape(BUS) + r"\S+)", re.M)
loads = []
for name in sorted(blocks):
    joined = "\n".join(l for l in blocks[name] if not l.lstrip().startswith("#"))
    for src, fpath in load_re.findall(joined):
        loads.append((name, src, fpath))
        stem = os.path.basename(fpath).removesuffix(".ndjson")
        rows.append((name, os.path.basename(fpath), src, "loads"))
        if stem not in ALLOWED or src not in ALLOWED[stem]:
            note(f"{name} loads {src}:{fpath}, but {stem}.ndjson may carry only {sorted(ALLOWED.get(stem, []))}: idryx refuses every line it would ingest")

# every file init-volumes pre-creates
pre = set()
init = "\n".join(blocks.get("init-volumes", []))
for m in re.finditer(r"for\s+\w+\s+in\s+([^;\n]+);\s*do", init):
    for item in m.group(1).split():
        if item.endswith(".ndjson"):
            pre.add(item)
for m in re.finditer(r":\s*>\s*\"?/vol/events/([A-Za-z0-9._-]+\.ndjson)", init):
    pre.add(m.group(1))
for f in sorted(pre):
    stem = f.removesuffix(".ndjson")
    rows.append(("init-volumes", f, "-", "pre-creates"))
    if stem not in ALLOWED:
        note(f"init-volumes pre-creates {f} on the bus, and `{stem}` is a stream name nothing accepts by default: a reader would call it unknown")

# nothing widens the rule
for m in re.finditer(r"\b(HERALDYX_STREAMS|IDRYX_STREAMS)\b", "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))):
    note(f"compose.yaml sets {m.group(1)}: rename the stream file instead, a declaration widens what the box accepts from anything that can create a file in the bus directory")

if not any(r[3] == "writes" for r in rows):
    print("FAIL: no service in compose.yaml writes a bus file under " + BUS + " with a source this gate knows,")
    print("      so it measured NOTHING about the writers. Silence here is not health.")
    sys.exit(1)
if not loads:
    print("FAIL: nothing in compose.yaml loads <source>:<path>, so this gate measured NOTHING about idryx's")
    print("      files. Silence here is not health.")
    sys.exit(1)
if not pre:
    print("FAIL: init-volumes pre-creates no *.ndjson on the bus, so this gate measured NOTHING about it.")
    sys.exit(1)

if problems:
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 23.")
    sys.exit(1)
print("OK: every stream file on this bus is one heraldyx 0.3.0 and idryx 1.1.0 accept for the source its writer claims:")
for who, f, src, how in rows:
    print(f"    {how:<11} {f:<24} {src:<14} ({who})")
PY
