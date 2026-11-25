#!/usr/bin/env bash
# CLAUDE.md invariant 85: every compose service carries a memory limit of its own, and the ones that do heavy
# work are given room for it.
#
# WHY
#
# Until 1.13.0 one service of thirty-one had a mem_limit (the browser). A plane that leaked, or a query over a
# trace that grew, could take the whole box's memory, and the kernel's OOM killer then picks a victim anywhere:
# the policy database, the gateway, the tunnel. A per-service ceiling makes the runaway the one stopped.
#
# WHAT THIS CHECKS, on the configuration compose resolves with every profile on:
#
#   - every service has a mem_limit, and it is written in that service's own block (no anchor carries one, so a
#     number is chosen per service, beside its pids_limit, and not inherited by accident);
#   - every limit is at least 64 MiB and at most 4 GiB (a typo such as 64k, or a limit so large it limits
#     nothing on the boxes this runs on, is a fault);
#   - a long-running service (restart other than "no") has at least 128 MiB;
#   - the services that run a query engine over a whole trace or a database have at least 1 GiB: HEAVY below,
#     each with its reason.
#
# It refuses to report OK when it measured nothing: no services, or no Docker to resolve the file.
#
# Scenarios: features/every-service-has-a-memory-limit.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "mem-limit".
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "mem-limit: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/mem-limit.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
MIB = 1024 * 1024
HEAVY = {
    "console": "runs wardryx replay and tokenfuse backtest over the whole archive and trace (invariant 56)",
    "focus-export": "runs tokenfuse focus-export, a DataFusion query, over each door's whole trace (invariant 80)",
    "tokenfuse-gateway": "holds every in-flight request and response body of every agent",
    "tokenfuse-gateway-openai": "the same, for the OpenAI door",
    "policy-db": "Postgres: shared buffers and one backend per connection",
    "scopyx-browser": "a Chromium renders whatever page it is handed",
    "idryx": "loads the whole bus stream of every plane it reads at start (--load), and the bus is not rotated",
    "idryx-detect": "the same, as a one-shot",
    "verdryx-slo": "reads 28 days of both doors' traces every run; killed, it writes no line, which reads as none (invariant 66)",
    "verdryx-drift": "reads verdryx's whole store",
    "record-seal": "seals the whole bus into its store",
    # Measured on forge 2026-11-25, 1.14.0: the witness at 256m was killed by the kernel (exit 137) in a loop while
    # it re-hashed the bus, which forge has never rotated. Every reader of the whole bus is held to the same floor.
    "keyryx-witness": "re-hashes every stream on the bus to witness its chain (killed at 256m on forge, 2026-11-25)",
    "agent-conform": "re-reads every stream on the bus to check its prev_hash chain",
    "heraldyx": "reads every stream on the bus it alerts on",
}
text = open("compose.yaml").read()
required = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", text)))
envfile = os.path.join(work, ".env")
open(envfile, "w").write("".join("%s=placeholder\n" % n for n in required))
clean = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSE_")}
r = subprocess.run(["docker", "compose", "--project-directory", root, "--env-file", envfile, "-f",
                    os.path.join(root, "compose.yaml"), "--profile", "*", "config", "--format", "json"],
                   capture_output=True, text=True, env=clean, cwd=root)
if r.returncode != 0:
    print("FAIL mem-limit: docker compose config failed: %s" % ((r.stderr.strip().splitlines() or ["?"])[-1]))
    sys.exit(1)
svc = json.loads(r.stdout).get("services", {})
if not svc:
    print("FAIL mem-limit: the resolved configuration has no services; measured nothing")
    sys.exit(1)

def size(v):
    if v is None:
        return None
    v = str(v).strip().lower()
    m = re.fullmatch(r"(\d+)([bkmg]?)b?", v)
    if not m:
        return -1
    n, u = int(m.group(1)), m.group(2)
    return n * {"": 1, "b": 1, "k": 1024, "m": MIB, "g": 1024 * MIB}[u]

problems = []
end = text.index("\nvolumes:\n") if "\nvolumes:\n" in text else len(text)
head = text[:end]
anchors = head[:head.index("\nservices:\n")] if "\nservices:\n" in head else ""
if re.search(r"^\s+mem_limit:", anchors, re.M):
    problems.append("an anchor above the services carries mem_limit, so services inherit one number instead of each choosing its own")
for name, d in sorted(svc.items()):
    lim = size(d.get("mem_limit"))
    block = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)", head, re.M | re.S)
    if lim is None:
        problems.append("%s has no mem_limit" % name)
        continue
    if lim < 0:
        problems.append("%s has a mem_limit compose did not resolve to bytes: %r" % (name, d.get("mem_limit")))
        continue
    if block and not re.search(r"^    mem_limit: \S+", block.group(1), re.M):
        problems.append("%s takes its mem_limit from somewhere other than its own block" % name)
    if lim < 64 * MIB:
        problems.append("%s has a mem_limit of %d bytes, below 64 MiB" % (name, lim))
    if lim > 4096 * MIB:
        problems.append("%s has a mem_limit of %d MiB, above 4 GiB, which limits nothing on the boxes this runs on" % (name, lim // MIB))
    if str(d.get("restart", "")) not in ("no", "") and lim < 128 * MIB:
        problems.append("%s runs all the time and has %d MiB, below 128 MiB" % (name, lim // MIB))
    if name in HEAVY and lim < 1024 * MIB:
        problems.append("%s has %d MiB, below 1 GiB, and it %s" % (name, lim // MIB, HEAVY[name]))
for name in sorted(set(HEAVY) - set(svc)):
    problems.append("%s is named as heavy and is not a service any more; this gate's list is stale" % name)

if problems:
    for p in problems:
        print("FAIL mem-limit: " + p)
    sys.exit(1)
print("OK: mem-limit (invariant 85): %d services, each with a memory limit of its own between 64 MiB and 4 GiB, "
      "and the %d heavy ones with at least 1 GiB" % (len(svc), len(HEAVY)))
PY
