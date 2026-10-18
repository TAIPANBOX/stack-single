#!/usr/bin/env bash
#
# Enforces: no plane can write another plane's stream, and no plane can create
# a file on the bus (CLAUDE.md invariant 41).
#
# WHY
#
# Until invariant 41 every plane ran as 65532 or 10001 and every stream was
# 0664 owned by 10001, so any plane could rewrite any other plane's record and
# the record said nothing about who wrote what (findings F-004 and F-021 of the
# 2026-10-17 review). Each producer now runs under its own uid, each stream is
# created by init-volumes owned by its one producer with mode 0640, and the bus
# directory is root:10001 0750, so nothing but init-volumes creates a file on it.
#
# WHAT IT JUDGES, AND HOW
#
# It resolves compose.yaml with a fake .env (every required variable set to a
# placeholder), then RUNS the init-volumes and costcrew-init scripts in a sandbox
# with chown and chmod replaced by recorders. So the owner and mode it judges are
# the ones the scripts would set, not a reading of their text. A stream is a file
# init-volumes creates under the bus directory. Its writer is the one service
# that mounts the bus read-write and names that file in its environment or
# command. Then:
#
#   1. every stream has exactly one writer, and its owner is that writer's uid;
#   2. no two streams share a writer uid, so no plane's uid can write another's;
#   3. every stream is mode 0640 (no world or group write, no world read);
#   4. the bus directory is owned by root, its group is the bus group (10001),
#      and it has no write bit for group or other, so no uid can create a file;
#   5. every per-producer checkpoint file is owned by its stream's writer, mode 0640.
#
# It refuses to report OK when it judged nothing (no stream, no writer, no
# sandbox output): an empty result is "measured nothing", not a pass.
#
# Scenarios: features/a-plane-writes-only-its-own-stream.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "no-plane-writes".

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "no-plane-writes: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/no-plane-writes.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()

def bad(msg):
    print("FAIL no-plane-writes: " + msg)
    sys.exit(1)

# A fake .env: every variable compose requires is set to a placeholder, so the
# resolved configuration is the file's own, with nothing taken from a machine.
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
cfg = json.loads(r.stdout)
services = cfg.get("services", {})
if not services:
    bad("the resolved configuration has no services; measured nothing")

def uid_of(svc):
    user = str(services[svc].get("user", ""))
    m = re.match(r"^(\d+)", user)
    return int(m.group(1)) if m else None

# The one-shot scripts that prepare the bus run as root and create streams.
inits = [s for s, d in services.items() if str(d.get("user", "")) in ("0:0", "0")]
if not inits:
    bad("no root one-shot prepares the bus; measured nothing")

# Run each one-shot's shell script in the sandbox, with chown and chmod recorded.
sandbox = os.path.join(work, "sandbox")
shims = os.path.join(work, "shims")
log = os.path.join(work, "calls.log")
os.makedirs(os.path.join(sandbox), exist_ok=True)
os.makedirs(shims, exist_ok=True)
for tool in ("chown", "chmod"):
    p = os.path.join(shims, tool)
    with open(p, "w") as f:
        f.write('#!/bin/sh\necho "%s $*" >> "%s"\n' % (tool, log))
    os.chmod(p, 0o755)
env = dict(clean)
env["PATH"] = shims + os.pathsep + env.get("PATH", "/usr/bin:/bin")
# init-volumes first: the others write into the directories it makes.
for svc in sorted(inits, key=lambda x: (x != "init-volumes", x)):
    cmd = services[svc].get("command") or []
    if len(cmd) < 3 or cmd[0] != "sh":
        bad("%s: its command is not a shell script; measured nothing" % svc)
    # `docker compose config` keeps the escape `$$` that the file wrote; the
    # container sees `$`, so the sandbox must too (or `$$1` is a PID).
    script = cmd[-1].replace("$$", "$").replace("/vol", sandbox)
    r = subprocess.run(["sh"] + cmd[1:-1] + [script], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        bad("%s did not run in the sandbox: %s" % (svc, (r.stderr or r.stdout).strip()[-200:]))

final = {}  # path -> (owner, mode)
if os.path.exists(log):
    for line in open(log):
        parts = line.split()
        if parts[0] == "chown":
            owner, target = parts[1], parts[2]
            final[target] = (owner, final.get(target, (None, None))[1])
        elif parts[0] == "chmod":
            mode, target = parts[1], parts[2]
            final[target] = (final.get(target, (None, None))[0], mode)

events = os.path.join(sandbox, "events")
ckdir = os.path.join(sandbox, "checkpoints")
streams = sorted(
    os.path.basename(p) for p in (os.path.join(events, n) for n in os.listdir(events))
    if os.path.isfile(p)) if os.path.isdir(events) else []
if not streams:
    bad("init-volumes created no stream on the bus; measured nothing")

def owner_uid(owner):
    m = re.match(r"^(\d+)", owner or "")
    return int(m.group(1)) if m else None

def writers_of(name):
    out = []
    for svc, d in services.items():
        if str(d.get("user", "")) in ("0:0", "0"):
            continue
        rw = [v for v in d.get("volumes", [])
              if v.get("source") == "events" and v.get("target", "").startswith("/var/lib/stack/events")
              and not v.get("read_only")]
        if not rw:
            continue
        blob = json.dumps({"environment": d.get("environment", {}), "command": d.get("command", [])})
        if re.search(r"(?<![A-Za-z0-9._-])" + re.escape(name) + r"(?![A-Za-z0-9._-])", blob):
            out.append(svc)
    return out

problems = []
seen_uid = {}
for name in streams:
    path = os.path.join(events, name)
    owner, mode = final.get(path, (None, None))
    ws = writers_of(name)
    if len(ws) != 1:
        problems.append("%s has %d writers (%s), want exactly one" % (name, len(ws), ", ".join(ws) or "none"))
        continue
    w = ws[0]
    if owner_uid(owner) != uid_of(w):
        problems.append("%s is owned by %s but its writer %s runs as %s" % (name, owner, w, uid_of(w)))
    if mode is None or int(mode, 8) != 0o640:
        problems.append("%s is mode %s, want 0640" % (name, mode))
    u = uid_of(w)
    if u in seen_uid and seen_uid[u] != name:
        problems.append("%s and %s are both written by uid %s: one plane could write the other's stream" % (seen_uid[u], name, u))
    seen_uid.setdefault(u, name)
    ck = os.path.join(ckdir, name + ".ckpt.ndjson")
    if os.path.exists(ck):
        cown, cmode = final.get(ck, (None, None))
        if owner_uid(cown) != u:
            problems.append("%s.ckpt.ndjson is owned by %s, want %s (its producer)" % (name, cown, u))
        if cmode is None or int(cmode, 8) != 0o640:
            problems.append("%s.ckpt.ndjson is mode %s, want 0640" % (name, cmode))

downer, dmode = final.get(events, (None, None))
if downer is None or not downer.startswith("0:"):
    problems.append("the bus directory is owned by %s, want root" % downer)
if dmode is None or int(dmode, 8) & 0o022:
    problems.append("the bus directory is mode %s: a group or other write bit lets a plane create a file" % dmode)

if problems:
    for p in problems:
        print("FAIL no-plane-writes: " + p)
    sys.exit(1)
print("OK: %d streams, each with one writer, its own uid and mode 0640; bus directory %s %s"
      % (len(streams), downer, dmode))
PY
