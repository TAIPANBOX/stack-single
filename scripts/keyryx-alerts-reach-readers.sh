#!/usr/bin/env bash
#
# Enforces: the Keyryx witness's findings reach heraldyx and the console, the
# readers see them read only, and the witness never writes the bus it witnesses
# (CLAUDE.md invariant 54).
#
# WHY
#
# The witness exists to notice when a stream on the bus, or a sealed record, was
# rewritten after it was seen. If it could write the bus, a compromised witness
# could add lines to the very record it vouches for, and its own findings would
# sit in a directory every plane's reader trusts. So its findings go to a file of
# their own, on a volume of their own, and the two readers that turn a finding
# into a mail or an incident mount that volume read only. Until this, the file
# sat on the witness's private state volume and nothing read it at all.
#
# WHAT IT JUDGES
#
# On the resolved compose.yaml (a fake .env, placeholders only, every profile):
#
#   1. the witness names its findings file in KEYRYX_WITNESS_ALERTS, the file is
#      called keyryx.ndjson (the stem heraldyx 0.8.0 reads as source keyryx), it
#      is not under the bus directory the witness reads, and it sits on a named
#      volume the witness mounts read-write that is neither the bus, the
#      checkpoints, nor the witness's own state volume;
#   2. every mount of the bus and of the checkpoints in the witness is read only,
#      and the witness mounts nothing else read-write but its state and that
#      findings volume;
#   3. every service but the witness and the root one-shots that mounts the
#      findings volume mounts it read only;
#   4. heraldyx and the console each mount it read only, and each is told to
#      read the file there: heraldyx by an entry of HERALDYX_EVENTS, the console
#      by an entry of GENARYX_EVENTS_EXTRA. The entry must be the file itself:
#      a reader handed the directory would read any *.ndjson in it;
#   5. a reader with a `user:` line runs in the group that owns the findings
#      directory.
#
# Then it RUNS init-volumes's script in a sandbox with chown and chmod recorded,
# as no-plane-writes-another-planes-stream.sh does, and requires:
#
#   6. the findings file is pre-created, owned by the witness's uid, mode 0640,
#      and given to the witness with `chown -h`; a symlink planted at its name
#      before the run is gone after it (the sandbox plants one);
#   7. its directory is owned by root (uid 0), never by the witness, so the
#      witness cannot add or swap an entry beside its file; its group is the
#      bus group (10001, the readers' group), and it has no group or other
#      write bit and nothing for other.
#
# It refuses to report OK when its subjects are gone: "measured nothing".
#
# Scenarios: features/the-witness-findings-reach-their-readers.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "keyryx-alerts".

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "keyryx-alerts: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/keyryx-alerts.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, posixpath, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
BUS_GROUP = 10001
ALERTS_NAME = "keyryx.ndjson"
WITNESS, READERS = "keyryx-witness", {"heraldyx": "HERALDYX_EVENTS", "console": "GENARYX_EVENTS_EXTRA"}

def bad(msg):
    print("FAIL keyryx-alerts: " + msg)
    sys.exit(1)

text = open("compose.yaml").read()
required = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", text)))
envfile = os.path.join(work, ".env")
with open(envfile, "w") as f:
    for name in required:
        f.write("%s=placeholder\n" % name)
clean = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSE_")}
r = subprocess.run(
    ["docker", "compose", "--project-directory", root, "--env-file", envfile,
     "-f", os.path.join(root, "compose.yaml"), "--profile", "*", "config", "--format", "json"],
    capture_output=True, text=True, env=clean, cwd=root)
if r.returncode != 0:
    bad("docker compose config failed: %s" % ((r.stderr.strip().splitlines() or ["?"])[-1]))
services = json.loads(r.stdout).get("services", {})
for name in [WITNESS] + sorted(READERS):
    if name not in services:
        bad("the resolved configuration has no %s service; measured nothing" % name)

def is_root(d):
    return str(d.get("user", "")) in ("0:0", "0")

def ids(d):
    m = re.match(r"^(\d+)(?::(\d+))?", str(d.get("user", "")))
    if not m:
        return None, None
    return int(m.group(1)), (int(m.group(2)) if m.group(2) else None)

def mounts(d):
    return [v for v in d.get("volumes", [])]

def under(path, base):
    base = base.rstrip("/")
    return path == base or path.startswith(base + "/")

def holder(d, path):
    """The mount of d whose target holds path (the longest such target)."""
    best = None
    for v in mounts(d):
        t = v.get("target", "")
        if t and under(path, t) and (best is None or len(t) > len(best.get("target", ""))):
            best = v
    return best

problems = []
wit = services[WITNESS]
wenv = wit.get("environment") or {}
alerts = str(wenv.get("KEYRYX_WITNESS_ALERTS") or "")
if not alerts:
    bad("the witness names no KEYRYX_WITNESS_ALERTS: keyryx then writes into the bus it reads; measured nothing else")
bus = str(wenv.get("KEYRYX_WITNESS_EVENTS") or "/var/lib/stack/events")
data = str(wenv.get("KEYRYX_WITNESS_DATA") or "")

# 1. where the findings file is
if under(alerts, bus):
    problems.append("the witness writes its findings to %s, on the bus it witnesses" % alerts)
h = holder(wit, alerts)
avol = None
if h is None or h.get("type") != "volume":
    problems.append("the witness's findings file %s is on no named volume of its own" % alerts)
else:
    avol = h.get("source")
    if h.get("read_only"):
        problems.append("the witness mounts its findings volume %s read only, so it cannot write them" % avol)
    if avol in ("events", "checkpoints"):
        problems.append("the witness's findings are on the %s volume: it writes the bus it witnesses" % avol)
    dh = holder(wit, data) if data else None
    if dh is not None and dh.get("source") == avol:
        problems.append("the witness's findings are on its state volume %s, which no reader may mount" % avol)
if posixpath.basename(alerts) != ALERTS_NAME:
    problems.append("the findings file is %s, not %s: heraldyx reads source keyryx only from a file of that stem"
                    % (posixpath.basename(alerts), ALERTS_NAME))

# 2. the witness writes nothing else
dvol = (holder(wit, data) or {}).get("source") if data else None
for v in mounts(wit):
    src, ro = v.get("source"), bool(v.get("read_only"))
    if src in ("events", "checkpoints") and not ro:
        problems.append("the witness mounts the %s volume read-write: it writes the bus it witnesses" % src)
    elif v.get("type") == "volume" and not ro and src not in (avol, dvol):
        problems.append("the witness mounts %s read-write, beside its state and its findings" % src)

# 3. nobody else writes the findings
if avol:
    for svc, d in sorted(services.items()):
        if svc == WITNESS or is_root(d):
            continue
        for v in mounts(d):
            if v.get("type") == "volume" and v.get("source") == avol and not v.get("read_only"):
                problems.append("%s mounts the witness's findings volume %s read-write: only the witness writes it, readers read only" % (svc, avol))

# 4. and 5. the readers read it
rel = posixpath.relpath(alerts, h.get("target")) if h is not None else None
for svc, var in sorted(READERS.items()):
    d = services[svc]
    mine = [v for v in mounts(d) if avol and v.get("type") == "volume" and v.get("source") == avol]
    if not mine:
        problems.append("%s does not mount the witness's findings volume, so %s does not read them" % (svc, svc))
        continue
    v = mine[0]
    if not v.get("read_only"):
        continue  # named in 3
    there = posixpath.join(v.get("target"), rel) if rel else None
    entries = [e.strip() for e in str((d.get("environment") or {}).get(var) or "").split(",") if e.strip()]
    if not there or there not in entries:
        problems.append("%s does not read the witness's findings: %s names %s, not %s"
                        % (svc, var, ", ".join(entries) or "nothing", there))

# 6. and 7. who owns the file and its directory, by running init-volumes
inits = {s: d for s, d in services.items() if is_root(d)}
init = inits.get("init-volumes")
if init is None:
    bad("no init-volumes one-shot prepares the volumes; measured nothing")
itarget = None
for v in mounts(init):
    if avol and v.get("source") == avol:
        itarget = v.get("target")
if avol and itarget is None:
    problems.append("init-volumes does not mount the findings volume %s, so nothing prepares its owner" % avol)
elif avol:
    sandbox = os.path.join(work, "sandbox")
    shims = os.path.join(work, "shims")
    log = os.path.join(work, "calls.log")
    os.makedirs(sandbox, exist_ok=True)
    os.makedirs(shims, exist_ok=True)
    # Plant a link at the findings file's name, to a file outside the volume,
    # as a witness could have while it owned the directory.
    sdir = itarget.replace("/vol", sandbox, 1)
    sfile = posixpath.join(sdir, rel) if rel else None
    decoy = os.path.join(work, "decoy")
    open(decoy, "w").close()
    if sfile:
        os.makedirs(posixpath.dirname(sfile), exist_ok=True)
        os.symlink(decoy, sfile)
    for tool in ("chown", "chmod"):
        p = os.path.join(shims, tool)
        with open(p, "w") as f:
            f.write('#!/bin/sh\necho "%s $*" >> "%s"\n' % (tool, log))
        os.chmod(p, 0o755)
    env = dict(clean)
    env["PATH"] = shims + os.pathsep + env.get("PATH", "/usr/bin:/bin")
    cmd = init.get("command") or []
    if len(cmd) < 3 or cmd[0] != "sh":
        bad("init-volumes: its command is not a shell script; measured nothing")
    script = cmd[-1].replace("$$", "$").replace("/vol", sandbox)
    rr = subprocess.run(["sh"] + cmd[1:-1] + [script], env=env, capture_output=True, text=True)
    if rr.returncode != 0:
        bad("init-volumes did not run in the sandbox: %s" % (rr.stderr or rr.stdout).strip()[-200:])
    final, hflag = {}, {}
    if os.path.exists(log):
        for line in open(log):
            parts = line.split()
            flags = [x for x in parts[1:] if x.startswith("-")]
            args = [x for x in parts[1:] if not x.startswith("-")]
            if len(args) < 2:
                continue
            cur = final.get(args[1], (None, None))
            final[args[1]] = (args[0], cur[1]) if parts[0] == "chown" else (cur[0], args[0])
            if parts[0] == "chown":
                hflag[args[1]] = any("h" in x for x in flags)
    wuid = ids(wit)[0]

    def uid_gid(owner):
        m = re.match(r"^(\d+)(?::(\d+))?$", owner or "")
        return (int(m.group(1)), int(m.group(2)) if m.group(2) else None) if m else (None, None)

    if sfile and os.path.islink(sfile):
        problems.append("init-volumes leaves a symlink at the findings file %s and works through it: root then follows a link the witness planted" % rel)
    elif not sfile or not os.path.isfile(sfile):
        problems.append("init-volumes does not pre-create the findings file %s" % (rel or "?"))
    else:
        if not hflag.get(sfile):
            problems.append("init-volumes gives the findings file to the witness without chown -h, which follows a link")
        fo, fm = final.get(sfile, (None, None))
        if uid_gid(fo)[0] != wuid:
            problems.append("the findings file is owned by %s, want the witness's uid %s" % (fo, wuid))
        if fm is None or int(fm, 8) != 0o640:
            problems.append("the findings file is mode %s, want 0640 (the witness writes, the readers' group reads)" % fm)
    do, dm = final.get(sdir, (None, None))
    du, dg = uid_gid(do)
    if du != 0:
        problems.append("the findings directory is owned by %s, want root (0): a witness that owns it can add or swap an entry beside its file" % do)
    if dg != BUS_GROUP:
        problems.append("the findings directory's group is %s, want the bus group %d that the readers run in" % (dg, BUS_GROUP))
    if dm is None or int(dm, 8) & 0o027:
        problems.append("the findings directory is mode %s: a group write bit, or anything for other, lets more than the witness and its readers in" % dm)
    for svc in sorted(READERS):
        g = ids(services[svc])[1]
        adds = {int(x) for x in (services[svc].get("group_add") or []) if str(x).isdigit()}
        if g is not None and g != BUS_GROUP and BUS_GROUP not in adds:
            problems.append("%s runs in group %s, not the bus group %d that owns the findings directory" % (svc, g, BUS_GROUP))

if problems:
    for p in problems:
        print("FAIL keyryx-alerts: " + p)
    sys.exit(1)
print("OK: the witness writes %s on volume %s, which heraldyx and the console mount read only and read;"
      % (alerts, avol))
print("    the witness mounts the bus and the checkpoints read only, and nothing else writes its findings")
PY
