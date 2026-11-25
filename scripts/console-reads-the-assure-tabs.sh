#!/usr/bin/env bash
#
# Enforces invariant 87 of CLAUDE.md: the console runs genaryx's own release image,
# and its three read-only Assure tabs (Notifications, Keys, Record) read what the
# planes on this box write, at the paths those planes write it, and can change none
# of it.
#
# genaryx v0.1.0 reads heraldyx's dispatch journal (GENARYX_HERALDYX_SENT), Keyryx
# custody's state and inventory (GENARYX_KEYRYX_URL), the witness's head
# (GENARYX_KEYRYX_WITNESS_URL) and the record seal's data directory
# (GENARYX_TRAILRYX_DATA_DIR, with TRAILRYX_WITNESS_ATTESTATIONS for the pack its
# Verify makes). Each tab says "not configured" without its setting, so a wrong
# path is a quiet empty tab, not an error. On the resolved configuration (every
# profile on), this requires of the console service:
#
#   - its image is ghcr.io/taipanbox/genaryx at v0.1.0 or later, and every other
#     service that runs the console's image runs the same reference;
#   - GENARYX_HERALDYX_SENT is sent.ndjson beside heraldyx's HERALDYX_STATE, and the
#     console mounts the volume heraldyx keeps it on, read only, at heraldyx's path;
#   - GENARYX_KEYRYX_URL is http://<custody service>:<custody's KEYRYX_ADDR port>,
#     and the console shares a network with custody;
#   - GENARYX_KEYRYX_WITNESS_URL is unset while the witness has no network (it could
#     reach nothing), and when set names the witness's service;
#   - GENARYX_TRAILRYX_DATA_DIR is the directory the record seal passes as --data, on
#     the seal's volume, mounted read only; TRAILRYX_WITNESS_ATTESTATIONS is the
#     seal's own path, on the seal's volume, mounted read only;
#   - no mount of heraldyx's, the record's or the attestations' volume into the
#     console is writable.
#
# It refuses to report OK when the console, heraldyx, custody or the record seal is
# missing, or when Docker cannot resolve the file: each is "measured nothing".
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "FAIL console-assure: docker is needed to resolve compose.yaml; measured nothing"
	exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/console-assure.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, posixpath, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
problems = []

def fail(msg):
    problems.append(msg)
    print("FAIL console-assure: " + msg)

def nothing(msg):
    print("FAIL console-assure: %s; measured nothing" % msg)
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

def mounts(svc):
    return [m for m in (svc.get("volumes") or []) if m.get("type") == "volume"]

def volume_at(svc, path):
    """The named-volume mount whose target holds path (longest target wins)."""
    best = None
    for m in mounts(svc):
        t = m.get("target", "").rstrip("/")
        if path == t or path.startswith(t + "/"):
            if best is None or len(t) > len(best.get("target", "")):
                best = m
    return best

con = services.get("console")
if not con:
    nothing("no console service")

# The image.
img = con.get("image") or ""
if not re.match(r"^ghcr\.io/taipanbox/genaryx:v\d", img):
    fail("the console runs %s, not genaryx's own release image ghcr.io/taipanbox/genaryx" % img)
v = version(img)
if v is None or v < (0, 1, 0):
    fail("the console runs %s; genaryx v0.1.0 is the first with the Notifications, Keys and Record tabs" % img)
for n, s in services.items():
    si = s.get("image") or ""
    if n != "console" and re.search(r"ghcr\.io/taipanbox/genaryx(-console)?:", si) and si != img:
        fail("%s runs %s and the console runs %s: the console's image is one pin" % (n, si, img))

e = env(con)

# Notifications.
h = services.get("heraldyx")
if not h:
    nothing("no heraldyx service")
state = env(h).get("HERALDYX_STATE") or ""
if not state:
    fail("heraldyx sets no HERALDYX_STATE, so where it journals cannot be derived")
else:
    want = posixpath.join(posixpath.dirname(state), "sent.ndjson")
    got = e.get("GENARYX_HERALDYX_SENT") or ""
    if got != want:
        fail("GENARYX_HERALDYX_SENT is %r, not %s, the journal beside heraldyx's state file" % (got, want))
    hm, cm = volume_at(h, want), volume_at(con, got or want)
    if not hm:
        fail("heraldyx keeps %s on no named volume" % want)
    elif not cm or cm.get("source") != hm.get("source") or cm.get("target") != hm.get("target"):
        fail("the console does not mount heraldyx's volume %s at %s" % (hm.get("source"), hm.get("target")))

# Keys.
custody = [n for n, s in services.items() if "/keyryx:" in (s.get("image") or "") and cmd(s)[:1] == ["custody"]]
witness = [n for n, s in services.items() if "/keyryx:" in (s.get("image") or "") and cmd(s)[:1] == ["witness"]]
if not custody:
    nothing("no keyryx custody service")
cn = custody[0]
port = (env(services[cn]).get("KEYRYX_ADDR") or "").rsplit(":", 1)[-1]
want = "http://%s:%s" % (cn, port)
if (e.get("GENARYX_KEYRYX_URL") or "") != want:
    fail("GENARYX_KEYRYX_URL is %r, not %s, custody's service and port" % (e.get("GENARYX_KEYRYX_URL"), want))
nets = lambda s: set((s.get("networks") or {}).keys())
if not (nets(con) & nets(services[cn])):
    fail("the console and %s share no network, so the Keys tab cannot reach custody" % cn)
wu = e.get("GENARYX_KEYRYX_WITNESS_URL")
for w in witness:
    if services[w].get("network_mode") == "none" and wu:
        fail("GENARYX_KEYRYX_WITNESS_URL is %r, and the witness %s has no network to answer on" % (wu, w))
    if wu and not re.match(r"^http://%s:\d+$" % re.escape(w), wu):
        fail("GENARYX_KEYRYX_WITNESS_URL is %r, which does not name the witness %s" % (wu, w))

# Record.
seal = services.get("record-seal")
if not seal:
    nothing("no record-seal service")
script = "\n".join(cmd(seal))
m = re.search(r"^\s*data=(\S+)\s*$", script, re.M)
if not m:
    nothing("record-seal's command names no data= directory")
data = m.group(1)
got = e.get("GENARYX_TRAILRYX_DATA_DIR") or ""
if got != data:
    fail("GENARYX_TRAILRYX_DATA_DIR is %r, not %s, the directory the seal passes as --data" % (got, data))
sm, cm = volume_at(seal, data), volume_at(con, got or data)
if not sm:
    fail("the record seal keeps %s on no named volume" % data)
elif not cm or cm.get("source") != sm.get("source") or cm.get("target") != sm.get("target"):
    fail("the console does not mount the record volume %s at %s" % (sm.get("source"), sm.get("target")))
att = env(seal).get("TRAILRYX_WITNESS_ATTESTATIONS") or ""
got = e.get("TRAILRYX_WITNESS_ATTESTATIONS") or ""
if att:
    if got != att:
        fail("the console's TRAILRYX_WITNESS_ATTESTATIONS is %r, not %s, the seal's" % (got, att))
    sa, ca = volume_at(seal, att), volume_at(con, got or att)
    if not sa or not ca or sa.get("source") != ca.get("source"):
        fail("the console does not mount the attestations volume the seal reads at %s" % att)

# Nothing writable.
for src in {(volume_at(h, state) or {}).get("source"), (sm or {}).get("source"), (volume_at(seal, att) or {}).get("source") if att else None} - {None}:
    for mm in mounts(con):
        if mm.get("source") == src and not mm.get("read_only"):
            fail("the console mounts %s at %s writable; it reads it and must not change it" % (src, mm.get("target")))

# A box built from source before 1.15.0 has CONSOLE_IMAGE=stack/genaryx-console:dev in .env, which
# add_env_default never rewrites: without the exact migration it keeps running the stale local console.
inst = open("install.sh").read()
if "sed -i 's#^CONSOLE_IMAGE=stack/genaryx-console:dev$#CONSOLE_IMAGE=stack/genaryx:dev#' .env" not in inst:
    fail("install.sh does not move CONSOLE_IMAGE=stack/genaryx-console:dev to stack/genaryx:dev, so a box built from source keeps its old console")

if problems:
    print("%d problem(s). See CLAUDE.md invariant 87." % len(problems))
    sys.exit(1)
print("OK: the console runs %s; Notifications reads heraldyx's journal, Keys reads %s, Record reads the seal's %s, each read only (invariant 87)."
      % (img.split("@")[0], want, data))
PY
