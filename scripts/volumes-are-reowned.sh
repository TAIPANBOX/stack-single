#!/usr/bin/env bash
#
# Enforces invariant 49 of CLAUDE.md (1.3.2, D7 and D8): every volume a service mounts read-write
# is given to that service's uid, recursively, by a root one-shot on every `up`. The uid is read
# from compose.yaml's own `user:` line for the service, never written into this script.
#
# WHY. A named volume keeps the owner of the files an earlier release wrote, and the one-shots
# used to give a volume to its uid only at the top directory. Measured on forge 2026-10-19
# upgrading 1.1.35 to 1.3.1: the gateway's retained-reservation journal in `traces` was still uid
# 10001 (the gateway runs 20010), so the gateway stopped; typryx's ledger in `typryxdata` was still
# uid 65532 (typryx runs 20005). A top-level chown does not reach a file inside.
#
# WHAT THIS CHECKS.
#   A. THE WRITERS. From compose.yaml: each service with a `user:` line that is not root, and each
#      of its read-write named-volume mounts (a `:ro` mount is not written and is not checked).
#   B. THE ONE-SHOTS. Every root service (`user: "0:0"`) whose command is a shell body: init-volumes
#      and any add-on one-shot such as costcrew-init. Each body is lifted out of compose.yaml and run
#      in a scratch root with chown and chmod RECORDED, not run for real.
#   C. THE RE-OWN. A writer's volume must be given to its uid by a recursive chown (`chown -R`) at
#      the one-shot path that mounts that volume, or below it. A non-recursive chown is not a re-own:
#      it leaves the files an earlier uid wrote where they were.
#   D. SHARED VOLUMES. `events` and `checkpoints` are shared bus volumes with one owner per file
#      (CLAUDE.md invariants 10 and 41, gated by bus-has-a-writer.sh and
#      no-plane-writes-another-planes-stream.sh). They are excluded here, and the exclusion is printed.
#   E. MEASURED SOMETHING. The gate refuses to report OK when it found no writer, or no one-shot body.

set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f compose.yaml ]; then
  fail "compose.yaml is not there, so the volume owners were not measured"
  exit 1
fi

# Read compose.yaml with no YAML library: the file's layout is fixed (services at two spaces, keys
# at four, list items at six). Writes mounts.json and one body file per root one-shot.
python3 - "$scratch" <<'PY'
import json, os, re, sys
out = sys.argv[1]
lines = open("compose.yaml").read().split("\n")
services = {}
section, cur, state = None, None, None
for L in lines:
    if re.match(r"^\S", L) and not L.startswith("#"):
        section, cur, state = L.split(":")[0], None, None
        continue
    if section != "services":
        continue
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", L)
    if m:
        cur, state = m.group(1), None
        services[cur] = {"user": None, "rw": [], "vol": {}, "body": []}
        body_on = False
        continue
    if cur is None:
        continue
    s = services[cur]
    m = re.match(r'^    user:\s*"?([0-9]+)', L)
    if m:
        s["user"] = int(m.group(1))
        continue
    if re.match(r"^    volumes:\s*$", L):
        state = "vol"
        continue
    if state == "vol":
        m = re.match(r"^      - ([A-Za-z0-9_-]+):(/\S+?)(:ro)?\s*$", L)
        if m:
            s["vol"][m.group(1)] = m.group(2)
            if not m.group(3):
                s["rw"].append({"volume": m.group(1), "path": m.group(2)})
            continue
        if re.match(r"^    \S", L):
            state = None
    if re.match(r"^      - \|\s*$", L):
        body_on = True
        continue
    if body_on:
        if re.match(r"^    \S", L):
            body_on = False
        else:
            s["body"].append(L[8:] if L.startswith("        ") else L.lstrip())
bodies = {}
for name, s in services.items():
    if s["user"] == 0 and any("chown" in b for b in s["body"]):
        bodies[name] = {"vol": s["vol"], "body": s["body"]}
os.makedirs(out + "/bodies", exist_ok=True)
for name, b in bodies.items():
    open(f"{out}/bodies/{name}.sh", "w").write("\n".join(b["body"]) + "\n")
json.dump({"services": services, "bodies": {n: b["vol"] for n, b in bodies.items()}},
          open(out + "/mounts.json", "w"))
PY

if [ ! -d "$scratch/bodies" ] || [ -z "$(ls -A "$scratch/bodies" 2>/dev/null)" ]; then
  fail "no root one-shot with a shell body that chowns was found in compose.yaml, so the re-own was not measured"
  exit 1
fi
if ! grep -q 'mkdir -p /vol/' "$scratch/bodies/init-volumes.sh" 2>/dev/null; then
  fail "init-volumes' command body was not found in compose.yaml, so the re-own was not measured"
  exit 1
fi

# Run each body in its own scratch root, with chown and chmod recorded and nothing owned for real.
LOG="$scratch/chown.log"
: >"$LOG"
for f in "$scratch"/bodies/*.sh; do
  root="$scratch/root-$(basename "$f" .sh)"
  mkdir -p "$root"
  # Every volume the body names is mounted in the scratch root, as compose mounts it, before the body runs.
  for v in $(grep -o '/vol/[A-Za-z0-9_-]*' "$f" | sort -u); do mkdir -p "$root$v"; done
  sed "s#/vol/#$root/vol/#g; s#/vol\([ \"]\)#$root/vol\1#g" "$f" >"$root.body"
  cat >"$root.run" <<PRELUDE
chown() { echo "\$(basename "$f" .sh) chown \$*" >>"$LOG"; }
chmod() { echo "\$(basename "$f" .sh) chmod \$*" >>"$LOG"; }
PRELUDE
  cat "$root.body" >>"$root.run"
  if ! sh -eu "$root.run" >"$root.out" 2>&1; then
    fail "the $(basename "$f" .sh) body failed in a scratch root: $(tail -2 "$root.out")"
  fi
done

python3 - "$scratch" "$LOG" <<'PY'
import json, re, sys
out, log = sys.argv[1], sys.argv[2]
m = json.load(open(out + "/mounts.json"))
services, bodies = m["services"], m["bodies"]
chowns = []
for line in open(log).read().splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[1] == "chown":
        chowns.append((parts[0], parts[2:]))

SHARED = {"events", "checkpoints"}
checked, problems, excluded = 0, [], set()
for name, s in sorted(services.items()):
    if s["user"] is None or s["user"] == 0:
        continue
    uid = s["user"]
    for rw in s["rw"]:
        vol = rw["volume"]
        if vol in SHARED:
            excluded.add(vol)
            continue
        # The one-shot that mounts this volume, and the path it mounts it at there.
        owner = [(b, bv[vol]) for b, bv in bodies.items() if vol in bv]
        if not owner:
            problems.append(f"{name} (uid {uid}) writes {vol}, which no root one-shot mounts, so nothing gives it an owner")
            continue
        checked += 1
        ok = False
        for b, target in owner:
            for oneshot, words in chowns:
                if oneshot != b or "-R" not in words:
                    continue
                owners = [w for w in words if re.match(r"^\d+(:\d+)?$", w)]
                paths = [w for w in words if w.startswith("/")]
                if not owners or owners[0].split(":")[0] != str(uid):
                    continue
                # The sandbox root is in front of the path; the volume's own path is what follows /vol/.
                norm = [p[p.find("/vol/"):] if "/vol/" in p else p for p in paths]
                if any(p == target or p.startswith(target + "/") for p in norm):
                    ok = True
        if not ok:
            target = owner[0][1]
            problems.append(f"{name} (uid {uid}) writes {vol} read-write at {rw['path']}, and no one-shot gives {target} to {uid} with a recursive chown, so a file an earlier uid wrote stays unwritable")

if checked == 0:
    print("FAIL: no read-write volume of a non-root service was found, so this gate measured nothing")
    sys.exit(2)
for p in problems:
    print("FAIL: " + p)
print(f"checked {checked} read-write volume mount(s); excluded as shared bus volumes: {', '.join(sorted(excluded)) or 'none'}")
sys.exit(1 if problems else 0)
PY
rc=$?
if [ "$rc" -eq 2 ]; then
  fail "the gate measured nothing"
elif [ "$rc" -ne 0 ]; then
  problems=$((problems + 1))
fi

if [ "$problems" -ne 0 ]; then
  printf 'volumes-are-reowned: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: volumes-are-reowned (invariant 49): every read-write volume of a non-root service is re-owned to its uid, recursively, on every up"
