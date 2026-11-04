#!/usr/bin/env bash
#
# Enforces: the console can reach what its two proofs run on, and can only read
# it (CLAUDE.md invariant 56).
#
# WHY
#
# The console proves a candidate policy by replaying decisions already recorded
# against wardryx's policy archive (`wardryx replay`), and a candidate budget by
# backtesting over the calls the gateway already recorded (`tokenfuse backtest`).
# Both need a path in the console's own environment and the right to read what
# is there. Measured on forge 2026-11-04 (wardryx v2.4.1): the archive was 0600
# and owned by wardryx, the console could not open one file, and `wardryx
# replay` answered "not archived" for all 490 decisions: the word wardryx uses
# for a version it never kept, said of a version the console simply could not
# read. wardryx v2.5.1 writes its directory 0750 and its files 0640, in the
# group it runs in; a version an earlier wardryx wrote stays 0600.
#
# WHAT IT JUDGES
#
# On the resolved compose.yaml (a fake .env, placeholders only, every profile):
#
#   1. the console's WARDRYX_POLICY_ARCHIVE is the directory wardryx writes
#      (its own WARDRYX_POLICY_ARCHIVE), and both sit on the same named volume
#      at the same place in it;
#   2. the console's TOKENFUSE_DATA_DIR is the Anthropic gateway's, and the
#      console mounts the gateway's volume read ONLY at a target that holds it;
#   3. the console runs in the group wardryx runs in (a file's group is the
#      group of its writer), by its own gid or by group_add; an unset `user:` is
#      the image's 10001:10001 (images/console.Dockerfile in stack-k8s);
#   4. by RUNNING init-volumes in a sandbox with chown and chmod recorded, and
#      a version an earlier wardryx wrote planted in the archive: the archive
#      directory is given to wardryx's uid and the console's group, mode with
#      group read and search, no group write and nothing for other; the planted
#      file is covered by a recursive chown to the same pair and is made 0640.
#
# It refuses to report OK when its subjects are gone: "measured nothing".
#
# Scenarios: features/the-console-reaches-what-its-proofs-run-on.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "console-proofs".

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "console-proofs: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/console-proofs.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, posixpath, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
CONSOLE, WARDRYX, GATEWAY = "console", "wardryx", "tokenfuse-gateway"
IMAGE_DEFAULT_USER = (10001, 10001)  # images/console.Dockerfile, USER 10001:10001

def bad(msg):
    print("FAIL console-proofs: " + msg)
    sys.exit(1)

def nothing(msg):
    print("FAIL console-proofs: %s; measured nothing" % msg)
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
for name in (CONSOLE, WARDRYX, GATEWAY, "init-volumes"):
    if name not in services:
        nothing("the resolved configuration has no %s service" % name)

def env_of(d):
    return d.get("environment") or {}

def mounts(d):
    return list(d.get("volumes", []))

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

def ids(d):
    m = re.match(r"^(\d+)(?::(\d+))?", str(d.get("user", "")))
    if not m:
        return None, None
    return int(m.group(1)), (int(m.group(2)) if m.group(2) else None)

def groups_of(d):
    uid, gid = ids(d)
    gs = {int(x) for x in (d.get("group_add") or []) if str(x).isdigit()}
    if uid is None and gid is None:
        gs.add(IMAGE_DEFAULT_USER[1])
    elif gid is not None:
        gs.add(gid)
    return gs

con, wd, gw = services[CONSOLE], services[WARDRYX], services[GATEWAY]
problems = []

# 1. the archive
warch = str(env_of(wd).get("WARDRYX_POLICY_ARCHIVE") or "")
if not warch:
    nothing("wardryx names no WARDRYX_POLICY_ARCHIVE, so there is no archive to read")
carch = str(env_of(con).get("WARDRYX_POLICY_ARCHIVE") or "")
if not carch:
    problems.append("the console names no WARDRYX_POLICY_ARCHIVE, so its policy proof reports itself not configured")
wh = holder(wd, warch)
if wh is None or wh.get("type") != "volume":
    problems.append("wardryx's archive %s is on no named volume" % warch)
if carch:
    ch = holder(con, carch)
    if ch is None or ch.get("type") != "volume":
        problems.append("the console's archive %s is on no named volume it mounts" % carch)
    elif wh is not None and wh.get("type") == "volume":
        wrel = posixpath.relpath(warch, wh["target"])
        crel = posixpath.relpath(carch, ch["target"])
        if ch.get("source") != wh.get("source") or crel != wrel:
            problems.append("the console reads %s on volume %s, which is not the archive wardryx writes: %s on volume %s"
                            % (crel, ch.get("source"), wrel, wh.get("source")))

# 2. the traces
gdir = str(env_of(gw).get("TOKENFUSE_DATA_DIR") or "")
if not gdir:
    nothing("the gateway names no TOKENFUSE_DATA_DIR, so there are no traces to read")
cdir = str(env_of(con).get("TOKENFUSE_DATA_DIR") or "")
if not cdir:
    problems.append("the console names no TOKENFUSE_DATA_DIR, so its budget proof reports itself not configured")
elif cdir != gdir:
    problems.append("the console's TOKENFUSE_DATA_DIR is %s, not the gateway's %s" % (cdir, gdir))
gh = holder(gw, gdir)
if gh is None or gh.get("type") != "volume":
    problems.append("the gateway's data directory %s is on no named volume" % gdir)
elif cdir:
    th = holder(con, cdir)
    if th is None or th.get("type") != "volume" or th.get("source") != gh.get("source"):
        problems.append("the console does not mount the gateway's volume %s, so it cannot read %s" % (gh.get("source"), cdir))
    else:
        if not th.get("read_only"):
            problems.append("the console mounts the trace volume %s read-write: it backtests over what the gateway wrote and must not be able to edit it" % th.get("source"))
        if posixpath.relpath(cdir, th["target"]) != posixpath.relpath(gdir, gh["target"]):
            problems.append("the console's mount of %s puts %s at a different place in it than the gateway does" % (th.get("source"), cdir))

# 3. the group
wuid, wgid = ids(wd)
if wgid is None:
    nothing("wardryx runs with no gid in compose.yaml, so the group of its files is unknown")
if wgid not in groups_of(con):
    problems.append("the console runs in groups %s, not wardryx's group %d: a version wardryx writes is 0640 in that group and the console cannot open it"
                    % (sorted(groups_of(con)), wgid))

# 4. what init-volumes does to the archive
init = services["init-volumes"]
if str(init.get("user", "")) not in ("0:0", "0"):
    nothing("init-volumes is not a root one-shot")
if wh is None or wh.get("type") != "volume":
    bad("; ".join(problems))
itarget = None
for v in mounts(init):
    if v.get("source") == wh.get("source"):
        itarget = v.get("target")
if itarget is None:
    problems.append("init-volumes does not mount the archive's volume %s, so nothing prepares the archive" % wh.get("source"))
else:
    rel = posixpath.relpath(warch, wh["target"])
    sandbox = os.path.join(work, "sandbox")
    shims = os.path.join(work, "shims")
    log = os.path.join(work, "calls.log")
    os.makedirs(shims, exist_ok=True)
    sdir = posixpath.join(itarget.replace("/vol", sandbox, 1), rel)
    os.makedirs(sdir, exist_ok=True)
    planted = posixpath.join(sdir, "0123456789ab.json")
    open(planted, "w").close()  # a version an earlier wardryx wrote, 0600 on a real box
    for tool in ("chown", "chmod"):
        p = os.path.join(shims, tool)
        with open(p, "w") as f:
            f.write('#!/bin/sh\necho "%s $*" >> "%s"\n' % (tool, log))
        os.chmod(p, 0o755)
    env = dict(clean)
    env["PATH"] = shims + os.pathsep + env.get("PATH", "/usr/bin:/bin")
    cmd = init.get("command") or []
    if len(cmd) < 3 or cmd[0] != "sh":
        nothing("init-volumes' command is not a shell script")
    script = cmd[-1].replace("$$", "$").replace("/vol", sandbox)
    rr = subprocess.run(["sh"] + cmd[1:-1] + [script], env=env, capture_output=True, text=True)
    if rr.returncode != 0:
        bad("init-volumes did not run in the sandbox: %s" % (rr.stderr or rr.stdout).strip()[-200:])

    chowns, chmods = [], []
    if os.path.exists(log):
        for line in open(log):
            parts = line.split()
            flags = [x for x in parts[1:] if x.startswith("-")]
            args = [x for x in parts[1:] if not x.startswith("-")]
            if len(args) < 2:
                continue
            rec = (args[0], args[1:], any("R" in x for x in flags))
            (chowns if parts[0] == "chown" else chmods).append(rec)

    def last(records, path):
        """The last record that reaches path, itself or, when recursive, an ancestor."""
        hit = None
        for what, targets, recursive in records:
            for t in targets:
                if t == path or (recursive and under(path, t)):
                    hit = what
        return hit

    def uid_gid(owner):
        m = re.match(r"^(\d+)(?::(\d+))?$", owner or "")
        return (int(m.group(1)), int(m.group(2)) if m.group(2) else None) if m else (None, None)

    dwho = last(chowns, sdir)
    du, dg = uid_gid(dwho)
    if du != wuid:
        problems.append("the archive directory is owned by %s, want wardryx's uid %s" % (dwho, wuid))
    if dg not in groups_of(con):
        problems.append("the archive directory's group is %s, not a group the console runs in %s" % (dg, sorted(groups_of(con))))
    dmode = last(chmods, sdir)
    if dmode is None:
        problems.append("init-volumes sets no mode on the archive directory")
    else:
        m = int(dmode, 8)
        if m & 0o027:
            problems.append("the archive directory is mode %s: a group write bit, or anything for other, lets the console change the archive or lets more than wardryx and the console in" % dmode)
        if (m & 0o050) != 0o050:
            problems.append("the archive directory is mode %s: the group needs read and search to list the versions" % dmode)
    fwho = last(chowns, planted)
    fu, fg = uid_gid(fwho)
    if (fu, fg) != (du, dg) or fu is None:
        problems.append("a version in the archive is owned by %s, not %s:%s like its directory (a recursive chown is what reaches the ones an earlier wardryx wrote)" % (fwho, du, dg))
    fmode = last(chmods, planted)
    if fmode is None:
        problems.append("init-volumes does not make a version an earlier wardryx wrote readable: it is 0600 and the console reads it as \"not archived\"")
    elif int(fmode, 8) != 0o640:
        problems.append("the versions in the archive are made mode %s, want 0640 (group read, no group write, nothing for other)" % fmode)

if problems:
    for p in problems:
        print("FAIL console-proofs: " + p)
    sys.exit(1)
print("OK: the console reads the archive wardryx writes (%s) and the gateway's traces (%s, read only);"
      % (warch, gdir))
print("    it runs in wardryx's group, and init-volumes leaves the archive 0750 and its versions 0640, nothing writable by the console")
PY
