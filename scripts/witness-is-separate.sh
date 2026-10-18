#!/usr/bin/env bash
#
# Enforces: the Keyryx witness is a process apart from custody: its own uid, its
# own data volume, its own root key file, no network, and no path to custody's
# state or root key (CLAUDE.md invariant 43).
#
# WHY
#
# Custody signs approvals and seal roots. The witness is what notices when the
# record was rewritten after a root was signed, and it must not be the same
# thing that can sign. If one compromised process could both sign and witness,
# the witness proves nothing. So they are two services of one binary, and
# nothing one has, the other can read or use.
#
# WHAT IT JUDGES, on the resolved compose.yaml (a fake .env, placeholders only)
#
#   1. the two services exist and run under different uids, and no other
#      service runs under either uid;
#   2. custody's state volume and the witness's are different volumes, and each
#      is mounted only into its own service;
#   3. each root key file is mounted only into its own service, read only;
#   4. the witness has no network (network_mode: none, or no networks at all);
#   5. the witness mounts neither custody's state nor custody's root key, and
#      custody mounts neither the witness's state nor its root key.
#
# It refuses to report OK when the subjects are gone: "measured nothing".
#
# Scenarios: features/the-keyryx-witness-is-a-separate-process.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "witness-is-separate".

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "witness-is-separate: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/witness-is-separate.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
problems = []

def bad(msg):
    print("FAIL witness-is-separate: " + msg)
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
cust = services.get("keyryx")
wit = services.get("keyryx-witness")
if cust is None or wit is None:
    bad("the resolved configuration has no keyryx or keyryx-witness service; measured nothing")

def uid(d):
    m = re.match(r"^(\d+)", str(d.get("user", "")))
    return int(m.group(1)) if m else None

def mounts(d):
    return [(v.get("type"), v.get("source", ""), v.get("target", ""), bool(v.get("read_only")))
            for v in d.get("volumes", [])]

cu, wu = uid(cust), uid(wit)
if cu is None or wu is None:
    bad("keyryx or keyryx-witness runs under no explicit uid")
if cu == wu:
    problems.append("custody and witness run under the same uid %d" % cu)
for svc, d in services.items():
    if svc in ("keyryx", "keyryx-witness"):
        continue
    if uid(d) in (cu, wu):
        problems.append("%s runs under uid %s, the uid of a Keyryx role" % (svc, uid(d)))

cvols = {m[1] for m in mounts(cust) if m[0] == "volume"}
wvols = {m[1] for m in mounts(wit) if m[0] == "volume"}
shared = (cvols & wvols) - {"events", "checkpoints"}
if shared:
    problems.append("custody and witness share state: %s" % ", ".join(sorted(shared)))

keys = {"custody": "/run/keyryx/root.key", "witness": "/run/keyryx/witness-root.key"}
for label, d in (("custody", cust), ("witness", wit)):
    mine = keys[label]
    theirs = keys["witness" if label == "custody" else "custody"]
    targets = [m[2] for m in mounts(d)]
    if mine not in targets:
        problems.append("%s does not mount its own root key at %s" % (label, mine))
    if theirs in targets:
        problems.append("%s mounts the other role's root key at %s" % (label, theirs))
    for m in mounts(d):
        if m[2] == mine and not m[3]:
            problems.append("%s mounts its root key read-write" % label)

for svc, d in services.items():
    if svc in ("keyryx", "keyryx-witness"):
        continue
    for m in mounts(d):
        if m[2] in ("/run/keyryx/root.key", "/run/keyryx/witness-root.key"):
            problems.append("%s mounts a Keyryx root key (%s)" % (svc, m[2]))

if wit.get("network_mode") not in (None, "none") or (wit.get("networks") or {}):
    problems.append("the witness has a network: it must have none")
if cust.get("network_mode") not in (None, "none") and not (cust.get("networks") or {}):
    problems.append("custody has no network, and it must reach its consumers")

if problems:
    for p in problems:
        print("FAIL witness-is-separate: " + p)
    sys.exit(1)
print("OK: custody (uid %d) and witness (uid %d) share no state, no root key and no uid; the witness has no network"
      % (cu, wu))
PY
