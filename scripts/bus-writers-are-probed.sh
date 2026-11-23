#!/usr/bin/env bash
# CLAUDE.md invariant 83: every install asks the running box, producer by producer, that it can write its own
# stream and cannot append to, rename or link another producer's stream, or create a file on the bus.
#
# WHY
#
# Invariant 41 holds the layout in compose.yaml (scripts/no-plane-writes-another-planes-stream.sh), and nothing
# asked a live box. stack-k8s asks its cluster the same question in security-tests.sh. A chown that did not land, a
# volume an older release left with other owners, or a service whose user line moved would pass the file gate and
# be open on the box.
#
# WHAT THIS CHECKS
#
#   A. install.sh's BUS_WRITERS table against compose.yaml, resolved with every profile on: every stream a root
#      one-shot creates on the bus is a row with the uid it is given to; every row's uid:gid and extra groups are
#      the user and group_add of a service that mounts the bus read-write; no row names a stream nobody creates;
#   B. bus_writers_probe, lifted out of install.sh and run against a stub `docker` that runs the probe's own shell
#      script over a scratch bus whose modes stand in for the uids (own stream writable, the rest read only, the
#      directory closed): a healthy bus passes and asks every producer, as its uid, gid and groups, with no
#      network; another stream left writable, a directory left open, or an own stream that cannot be appended to
#      fails; a rename the probe managed is put back and nothing is left on the bus; a stream not on the box is
#      passed over;
#   C. install.sh runs the probe as an install check, and the README no longer says any writer can append to any
#      other plane's file.
#
# It refuses to report OK when it measured nothing: no table, no function, no check, no stream, no Docker.
#
# Scenarios: features/every-producer-is-asked-on-the-box.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "bus-writers".
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "bus-writers: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/bus-writers.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, re, stat, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
problems = []
def bad(m): problems.append(m)
def stop(m):
    print("FAIL bus-writers: " + m); sys.exit(1)

install = open("install.sh").read()
text = open("compose.yaml").read()
m = re.search(r"^# bus-writers: begin\n(.*?)^# bus-writers: end\n", install, re.M | re.S)
if not m:
    stop("install.sh has no '# bus-writers:' block; measured nothing")
block = m.group(1)
t = re.search(r'^BUS_WRITERS="([^"]*)"', block, re.M)
if not t or "bus_writers_probe()" not in block:
    stop("the block has no BUS_WRITERS table or no bus_writers_probe(); measured nothing")
rows = {}
for r in t.group(1).split():
    parts = r.split(":")
    if len(parts) != 4:
        bad("BUS_WRITERS row %r is not uid:gid:extra:stream" % r); continue
    uid, gid, extra, stream = parts
    rows[stream] = (uid, gid, extra)
if not rows:
    stop("BUS_WRITERS names no stream; measured nothing")

# ---- A. the table against compose.yaml -----------------------------------------------------
required = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", text)))
envfile = os.path.join(work, ".env")
open(envfile, "w").write("".join("%s=placeholder\n" % n for n in required))
clean = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSE_")}
r = subprocess.run(["docker", "compose", "--project-directory", root, "--env-file", envfile, "-f",
                    os.path.join(root, "compose.yaml"), "--profile", "*", "config", "--format", "json"],
                   capture_output=True, text=True, env=clean, cwd=root)
if r.returncode != 0:
    stop("docker compose config failed: %s" % ((r.stderr.strip().splitlines() or ["?"])[-1]))
svc = json.loads(r.stdout).get("services", {})
created = {}
for name, d in svc.items():
    if str(d.get("user", "")) not in ("0:0", "0"):
        continue
    # An optional add-on's own one-shot (it sits behind a profile): install.sh does not know the add-on
    # (invariant 24), so its stream is not the installer's to probe.
    if d.get("profiles"):
        continue
    body = "\n".join(d.get("command") or [])
    for uid, f in re.findall(r"chown (\d+):10001 /vol/events/([a-z0-9-]+\.ndjson)", body):
        created[f] = uid
if not created:
    stop("no root one-shot creates a stream on the bus; measured nothing")
for f, uid in sorted(created.items()):
    if f not in rows:
        bad("%s is created on the bus for uid %s and BUS_WRITERS does not ask about it" % (f, uid))
    elif rows[f][0] != uid:
        bad("BUS_WRITERS asks about %s as uid %s, and the bus gives it to uid %s" % (f, rows[f][0], uid))
for f in sorted(set(rows) - set(created)):
    bad("BUS_WRITERS names %s, which nothing creates on the bus" % f)
def rw_bus(d):
    return any(v.get("source") == "events" and not v.get("read_only") for v in d.get("volumes") or [])
for f, (uid, gid, extra) in sorted(rows.items()):
    want_extra = set() if extra == "-" else set(extra.split(","))
    match = [n for n, d in svc.items() if rw_bus(d) and str(d.get("user", "")) == "%s:%s" % (uid, gid)
             and set(str(x) for x in (d.get("group_add") or [])) == want_extra]
    if not match:
        bad("BUS_WRITERS asks about %s as %s:%s with groups %s, and no service that writes the bus runs as that"
            % (f, uid, gid, sorted(want_extra) or "none"))

# ---- B. the probe against a stub docker -------------------------------------------------------
bus = os.path.join(work, "bus")
stub_dir = os.path.join(work, "bin")
os.makedirs(stub_dir, exist_ok=True)
calls = os.path.join(work, "calls")
# The stub stands in for docker run: it reads --user, --group-add, --network and -v, sets the scratch bus's modes
# the way the real owners would leave them for that uid (FAULT bends one), and runs the probe's own script with /e
# pointed at the scratch bus.
open(os.path.join(stub_dir, "docker"), "w").write(r'''#!/usr/bin/env python3
import os, subprocess, sys
a = sys.argv[1:]
import json
open(os.environ["STUB_CALLS"], "a").write(json.dumps(a) + "\n")
assert a[0] == "run", a
user = groups = net = vol = None; i = 1; extra = []
while i < len(a):
    if a[i] == "--user": user = a[i+1]; i += 2
    elif a[i] == "--group-add": extra.append(a[i+1]); i += 2
    elif a[i] == "--network": net = a[i+1]; i += 2
    elif a[i] == "-v": vol = a[i+1]; i += 2
    elif a[i] == "--rm": i += 1
    else: break
image = a[i]; rest = a[i+1:]
assert rest[0] == "sh" and rest[1] == "-c", rest
script, own, names = rest[2], rest[4], rest[5:]
bus = os.environ["STUB_BUS"]; fault = os.environ.get("FAULT", "")
os.chmod(bus, 0o755)
for n in os.listdir(bus):
    p = os.path.join(bus, n)
    mode = 0o644 if n == own else 0o444
    if fault == "other-writable": mode = 0o644
    if fault == "own-closed" and n == own: mode = 0o444
    os.chmod(p, mode)
# a closed bus directory: no list, no create, no rename, files opened by name only (the same for every uid,
# so a probe that globbed the directory instead of naming the streams finds nothing to try)
os.chmod(bus, 0o755 if fault == "dir-open" else 0o111)
r = subprocess.run(["sh", "-c", script.replace("/e/", bus + "/"), "sh", own] + names)
os.chmod(bus, 0o755)
sys.exit(r.returncode)
''')
os.chmod(os.path.join(stub_dir, "docker"), 0o755)

def fresh_bus(streams):
    if os.path.exists(bus):
        os.chmod(bus, 0o755)
        for n in os.listdir(bus):
            os.chmod(os.path.join(bus, n), 0o644); os.unlink(os.path.join(bus, n))
    else:
        os.makedirs(bus)
    for s in streams:
        open(os.path.join(bus, s), "w").write("line\n")

def probe(fault="", streams=None):
    fresh_bus(sorted(rows) if streams is None else streams)
    open(calls, "w").close()
    env = dict(os.environ, PATH=stub_dir + ":" + os.environ["PATH"], STUB_BUS=bus, STUB_CALLS=calls,
               FAULT=fault, NET="agent-stack_core")
    r = subprocess.run(["bash", "-c", block + "\nbus_writers_probe"], env=env, capture_output=True, text=True, timeout=120)
    return r

if os.geteuid() == 0:
    stop("this gate stands modes in for uids and cannot do that as root; run it as a user; measured nothing")

ok = probe()
if ok.returncode != 0:
    bad("a healthy bus failed the probe: %s" % (ok.stdout + ok.stderr).strip()[-300:])
asked = [json.loads(x) for x in open(calls).read().splitlines() if x.strip()]
for f, (uid, gid, extra) in sorted(rows.items()):
    def own_of(a):
        i = next((k for k in range(len(a) - 1) if a[k] == "sh" and a[k + 1] == "-c"), None)
        return a[i + 4] if i is not None and i + 4 < len(a) else None
    line = [" ".join(a[:a.index("sh")]) for a in asked if a and own_of(a) == f]
    if not line:
        bad("the probe never asked as the writer of %s" % f); continue
    l = line[0]
    if "--user %s:%s" % (uid, gid) not in l:
        bad("the probe asked about %s not as %s:%s: %s" % (f, uid, gid, l[:120]))
    if extra != "-" and "--group-add %s" % extra not in l:
        bad("the probe asked about %s without the group %s its writer has" % (f, extra))
    if "--network none" not in l:
        bad("the probe's container for %s is on a network; it needs none" % f)
    if "agent-stack_events:/e" not in l:
        bad("the probe for %s does not mount the stack's events volume" % f)
leftover = sorted(n for n in os.listdir(bus) if not n.endswith(".ndjson"))
if leftover:
    bad("the probe left files on the bus: %s" % leftover)

for fault, needle in (("other-writable", "appended to"), ("dir-open", "renamed"), ("own-closed", "cannot append to its own")):
    r = probe(fault)
    if r.returncode == 0:
        bad("a bus with %s passed the probe" % fault)
    elif needle not in r.stdout + r.stderr:
        bad("a bus with %s failed without saying %r: %s" % (fault, needle, (r.stdout + r.stderr).strip()[-200:]))
    if fault == "dir-open":
        names = sorted(os.listdir(bus))
        if names != sorted(rows):
            bad("after a rename went through, the bus is %s, not every stream back under its own name" % names)

gone = probe("", streams=[s for s in rows if s != "wardryx.ndjson"])
if gone.returncode == 0:
    bad("a box whose wardryx.ndjson is missing passed the probe; every producer's stream must be there")
if "costcrew" in block:
    bad("the probe names the FinOps console's stream; install.sh does not know the add-on (invariant 24)")

# busybox sh ends the whole shell when a redirection on `:` fails (a special builtin), which the stub's sh does
# not: measured on a live box, 2026-11-23, the first refused append stopped every probe. So every attempt must
# run in a subshell, and that is read from the text.
for m in re.finditer(r"[^\n]*: >>?\"[^\n]*", block):
    if not re.search(r"\(\s*:\s*>>?\s*\"[^)]*\)", m.group(0)):
        bad("an attempt in the probe is not in a subshell, so busybox sh ends at the first refusal: %s" % m.group(0).strip()[:90])

# ---- C. the install check and the README ---------------------------------------------------
if not re.search(r'^install_only check "[^"]*another plane.s stream[^"]*" \\\n\s+"bus_writers_probe"', install, re.M):
    bad("install.sh does not run bus_writers_probe as an install check")
readme = open("README.md").read()
if "any writer in the bus group can append to any other plane's" in readme:
    bad("the README still says any writer in the bus group can append to any other plane's file")

if problems:
    for p in problems:
        print("FAIL bus-writers: " + p)
    sys.exit(1)
print("OK: bus-writers (invariant 83): %d streams, each asked on the box as its own writer: its own stream "
      "appends, no other stream appends, renames or links, and the bus takes no new file" % len(rows))
PY
