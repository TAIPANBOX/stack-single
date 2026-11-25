#!/usr/bin/env bash
#
# Enforces invariant 86 of CLAUDE.md: Keyryx custody announces every key change on
# a stream of its own on the bus, and nothing in this launcher hands it a network
# admin key.
#
# keyryx 0.2.0 serves rotation and revocation only on its admin unix socket, to
# root and custody's own uid, and announces each change as key_rotated or
# key_revoked into the file KEYRYX_EVENTS names. It refuses to start without
# KEYRYX_EVENTS, and refuses to start with any value in KEYRYX_ADMIN_KEYS. So on
# the resolved configuration (every profile on), this requires:
#
#   - exactly one keyryx custody service (the keyryx image, command `custody`),
#     pinned at keyryx 0.2.0 or later, and the witness on the same pin;
#   - its KEYRYX_EVENTS is keyryx-custody.ndjson in the bus directory, a
#     directory the service mounts READ-WRITE from the `events` volume, and not
#     inside KEYRYX_DATA, and not the witness's keyryx.ndjson;
#   - init-volumes pre-creates that file, owned by custody's uid from its
#     `user:` line, group 10001, mode 0640 (custody writes only a file it owns);
#   - heraldyx, which renders custody's events, reads the bus directory and is
#     pinned at 0.10.0 or later;
#   - KEYRYX_ADMIN_KEYS is set in no service's environment, and no live line of
#     compose.yaml or install.sh assigns it;
#   - the README names the admin commands.
#
# It refuses to report OK when there is no custody service, no Docker, or no
# init-volumes to read: each of those is "measured nothing".
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "FAIL keyryx-custody: docker is needed to resolve compose.yaml; measured nothing"
	exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/keyryx-custody.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, posixpath, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
problems = []

def fail(msg):
    problems.append(msg)
    print("FAIL keyryx-custody: " + msg)

def nothing(msg):
    print("FAIL keyryx-custody: %s; measured nothing" % msg)
    sys.exit(1)

def version(image):
    m = re.search(r":v(\d+)\.(\d+)\.(\d+)", image or "")
    return tuple(int(x) for x in m.groups()) if m else None

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
    nothing("docker compose config failed: " + r.stderr.strip()[:300])
services = json.loads(r.stdout).get("services", {})

def cmd(svc):
    c = svc.get("command") or []
    return c if isinstance(c, list) else c.split()

def env(svc):
    return svc.get("environment") or {}

keyryx = {n: s for n, s in services.items() if "/keyryx:" in (s.get("image") or "")}
custody = [n for n, s in keyryx.items() if cmd(s)[:1] == ["custody"]]
witness = [n for n, s in keyryx.items() if cmd(s)[:1] == ["witness"]]
if not custody:
    nothing("no service runs the keyryx image with the command custody")
if len(custody) != 1:
    fail("%d custody services (%s): one custody owns one stream" % (len(custody), ", ".join(custody)))
name = custody[0]
svc = services[name]

v = version(svc.get("image"))
if v is None or v < (0, 2, 0):
    fail("%s runs %s; keyryx 0.2.0 is the first that serves rotation only on its admin socket and announces it on the bus" % (name, svc.get("image")))
for w in witness:
    if services[w].get("image") != svc.get("image"):
        fail("the witness %s runs %s and custody runs %s: one image, one pin" % (w, services[w].get("image"), svc.get("image")))

e = env(svc)
events = e.get("KEYRYX_EVENTS") or ""
data = e.get("KEYRYX_DATA") or ""
BUS = "/var/lib/stack/events"
if not events:
    fail("%s sets no KEYRYX_EVENTS, and keyryx 0.2.0 refuses to start without it" % name)
else:
    if posixpath.basename(events) != "keyryx-custody.ndjson":
        fail("%s's KEYRYX_EVENTS is %s, not keyryx-custody.ndjson, the stem heraldyx 0.10.0 reads as source keyryx" % (name, events))
    if posixpath.dirname(events) != BUS:
        fail("%s's KEYRYX_EVENTS is %s, outside the bus directory %s, where nothing reads it" % (name, events, BUS))
    if data and (events == data or events.startswith(data.rstrip("/") + "/")):
        fail("%s's KEYRYX_EVENTS %s is inside KEYRYX_DATA %s" % (name, events, data))
    mounted = [m for m in (svc.get("volumes") or [])
               if m.get("type") == "volume" and m.get("source") == "events" and m.get("target") == BUS]
    if not mounted:
        fail("%s does not mount the events volume at %s, so its stream is not on the bus" % (name, BUS))
    elif any(m.get("read_only") for m in mounted):
        fail("%s mounts the bus read only, so it cannot append its announcements" % name)

# Who owns the file: init-volumes must make it for custody's uid.
user = str(svc.get("user") or "")
uid = user.split(":")[0]
init = services.get("init-volumes")
if not init:
    nothing("no init-volumes service to read")
script = "\n".join(cmd(init)) if isinstance(init.get("command"), list) else str(init.get("command"))
fname = "keyryx-custody.ndjson"
if not re.search(r"\[ -e /vol/events/%s \] \|\| : > /vol/events/%s" % (re.escape(fname), re.escape(fname)), script):
    fail("init-volumes does not pre-create /vol/events/%s, and custody can create nothing in the root-owned bus directory" % fname)
own = re.search(r"chown (\d+):(\d+) /vol/events/%s; chmod (\d+) /vol/events/%s" % (re.escape(fname), re.escape(fname)), script)
if not own:
    fail("init-volumes does not give /vol/events/%s an owner and a mode" % fname)
else:
    if own.group(1) != uid:
        fail("init-volumes gives %s to uid %s, and custody runs as %s: custody writes only a file it owns" % (fname, own.group(1), uid or "(no user line)"))
    if own.group(2) != "10001" or own.group(3) != "0640":
        fail("init-volumes makes %s %s:%s %s, not group 10001 mode 0640" % (fname, own.group(1), own.group(2), own.group(3)))

# The reader.
h = services.get("heraldyx")
if not h:
    fail("no heraldyx service reads custody's announcements")
else:
    hv = version(h.get("image"))
    if hv is None or hv < (0, 10, 0):
        fail("heraldyx runs %s; 0.10.0 is the first that renders keyryx-custody.ndjson as source keyryx" % h.get("image"))
    reads = [p.strip() for p in (env(h).get("HERALDYX_EVENTS") or "").split(",")]
    if BUS not in reads and events not in reads:
        fail("heraldyx's HERALDYX_EVENTS names neither the bus directory nor %s" % events)

# No admin key anywhere.
for n, s in services.items():
    if "KEYRYX_ADMIN_KEYS" in env(s):
        fail("%s sets KEYRYX_ADMIN_KEYS; keyryx 0.2.0 refuses to start with it, and there is no network admin route" % n)
for path in ("compose.yaml", "install.sh"):
    for i, line in enumerate(open(path).read().split("\n"), 1):
        live = line.split("#", 1)[0]
        if re.search(r"\bKEYRYX_ADMIN_KEYS\s*[:=]", live):
            fail("%s:%d assigns KEYRYX_ADMIN_KEYS" % (path, i))

readme = open("README.md").read()
for c in ("keyryx admin rotate", "keyryx admin revoke"):
    if c not in readme:
        fail("README.md does not name `%s`, the only way to rotate or revoke a key on this box" % c)

if problems:
    print("%d problem(s). See CLAUDE.md invariant 86." % len(problems))
    sys.exit(1)
print("OK: keyryx custody (%s, %s) announces on %s, a file init-volumes gives its uid %s at 0640; heraldyx %s reads it; KEYRYX_ADMIN_KEYS is set nowhere (invariant 86)."
      % (name, svc.get("image").split("@")[0].rsplit("/", 1)[-1], events, uid, h.get("image").split("@")[0].rsplit(":", 1)[-1]))
PY
